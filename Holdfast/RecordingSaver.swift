//
//  RecordingSaver.swift
//  Holdfast
//

import AppKit
import AVFoundation
import SwiftLAME
import SwiftUI

/// What is done with a recording once its capture has stopped and its inputs are finished: closing the file, the
/// audio mix or MP3 conversion, and telling the user where it is. `RecordingSession` awaits `save` in its
/// `finalizing` state.
@MainActor
enum RecordingSaver {
    /// What follows once the inputs are finished (`taken`): the file is closed, then it is post-processed (audio
    /// mix, MP3 conversion); it returns when the files are final, and only then is the session idle. Nothing here
    /// blocks the main thread. It works from `recording` and what the writer handed over, not from settings.
    static func save(_ session: RecordingSession, recording: RecordingContext, taken: MovieWriter.Finished, earlyReason: String?, cancelled: Bool) async {
        let frame = taken.frame
        // Nil when nothing arrived: the writer has removed its empty file or package, and the report below says so
        let writer = taken.writer
        // A writer that already failed has nothing to finish
        var closed = false
        if let writer = writer, writer.status == .writing {
            await writer.finishWriting()
            closed = writer.status == .completed
        }
        let failureTitle = earlyReason == nil ? "Failed to Save File" : "Recording Stopped Early"
        // Not "Stopped Early", which says that what came before the stop was saved
        let nothingTitle = "Recording Not Saved"
        if session.filesDeleted {
            // The reason says it all: what was written is gone with its name, and there is no file to point to
            report("Recording Stopped Early", of: recording, earlyReason ?? "")
        } else if !taken.sessionStarted && cancelled {
            // Stopped before the first frame or the first audio arrived. Nothing was lost, so nothing is reported as
            // failed, and the user who stopped it needs no notification to know.
            RecLog.write("Recording cancelled: it was stopped before anything was recorded")
        } else if !taken.sessionStarted {
            // Stopped, early or by the user, before the first frame (or the first system audio of an audio-only recording)
            let nothing = recording.audioOnly ? "No audio arrived, so nothing was recorded and no file was kept." : "Nothing was recorded, so no file was kept."
            report(nothingTitle, of: recording, (earlyReason.map { $0 + " " } ?? "") + nothing)
        } else if !recording.audioOnly {
            if !closed {
                print("Video writing failed with status: \(String(describing: writer?.status)), error: \(String(describing: writer?.error))")
                var body = earlyReason ?? ""
                if let error = writer?.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                if body.isEmpty { body = "Unknown error." }
                if fd.fileExists(atPath: recording.rawURL.path) {
                    // The file is written in fragments, so it plays up to the last few seconds without having been closed.
                    // It leaves its temporary name; no mix is attempted on it.
                    let kept = recording.unmixedURL.map { RecordingFileStore.keep(written: recording.rawURL, as: $0) } ?? recording.rawURL
                    body += " " + String(format: "The file could not be closed. What was written before that was kept as: %@", kept.path)
                } else {
                    body += " " + movedNote(for: recording.rawURL)
                }
                report(failureTitle, of: recording, body)
            } else {
                if recording.mixesAudio {
                    // Where the recording ends up is only known after the mix
                    await mix(session, recording: recording, frame: frame, earlyReason: earlyReason)
                } else {
                    present(recording.finalURL, image: frame, recording: recording, earlyReason: earlyReason)
                }
            }
        } else {
            // The files are as complete as they will get: they leave their temporary name, and so does the backup of
            // the system audio when it is a file of its own
            let kept = recording.closedURL.map { RecordingFileStore.keep(written: recording.rawURL, as: $0) } ?? recording.rawURL
            if recording.micAudioURL == nil, let written = recording.backupAudioURL, let closedBackup = recording.backupClosedURL,
               fd.fileExists(atPath: written.path) {
                _ = RecordingFileStore.keep(written: written, as: closedBackup)
            }
            // And the call tap's
            if recording.micAudioURL == nil, let written = recording.callAudioURL, let closedCall = recording.callClosedURL,
               fd.fileExists(atPath: written.path) {
                _ = RecordingFileStore.keep(written: written, as: closedCall)
            }
            if recording.recordMic, let writer = writer, !closed {
                // The microphone file did not close: the package is kept as it is and is not mixed
                var body = earlyReason ?? ""
                if let error = writer.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                body += (body.isEmpty ? "" : " ") + keptNote(kept, "The microphone file could not be closed. The recording was kept with separate audio files: %@")
                report(failureTitle, of: recording, body)
            } else {
                // The package is only read now that the microphone file is complete. With the tap, its system audio
                // is first made one file from the tap's and the backup's.
                await mergeSystemAudio(recording, at: kept)
                await finishAudioRecording(recording, at: kept, earlyReason: earlyReason)
            }
        }
        // The final files are written: the taps' spans have served
        RecordingFileStore.removeTapSpans(recording.tapSpansURL)
        logCallSpans(recording.callSpansURL)
        RecordingFileStore.removeTapSpans(recording.callSpansURL)
    }

    /// What the call tap recorded, for the log, from the spans the writer kept of it: how long it delivered. A
    /// recording without a call has none.
    private static func logCallSpans(_ url: URL?) {
        guard let url, let spans = TapSpans.read(url) else { return }
        guard let last = spans.spans.last else {
            RecLog.write("Call audio: the call tap delivered nothing in this recording (no call played)")
            return
        }
        let end = last.end.isFinite ? last.end : last.start
        RecLog.write(String(format: "Call audio: the call tap delivered for %.1f s in %d %@, between %.1f s and %.1f s of the recording",
                            spans.aliveSeconds(upTo: end), spans.spans.count, spans.spans.count == 1 ? "stretch" : "stretches", spans.spans[0].start, end))
    }

    /// Reports a failure of `recording` (`UserNotice.reportFailure`). While another recording is starting or running,
    /// the report says first which recording it is about (`RecorderController.failureMessage`).
    private static func report(_ title: String, of recording: RecordingContext, _ message: String) {
        UserNotice.reportFailure(title: title, message: RecorderController.shared.failureMessage(message, about: recording))
    }

    /// Mixes the audio tracks of a finished video recording and presents the result. Returns when the recording has
    /// its final name. The recording as it was written is only removed or renamed after the mix has been written
    /// completely, checked against it and moved to the final name; whatever goes wrong before that, it is kept
    /// under its "(unmixed, N audio tracks)" name and the user is told. The work itself runs off the main thread.
    /// With the process tap the system audio of the mix comes stretch by stretch from the tap or its backup, by the
    /// tap's spans written while recording (`RecordingFiles.tapSpansURL`).
    private static func mix(_ session: RecordingSession, recording: RecordingContext, frame: NSImage?, earlyReason: String?) async {
        guard let mixURL = recording.mixURL, let unmixedURL = recording.unmixedURL else { return }
        let raw = recording.rawURL
        let final = recording.finalURL
        let early = earlyReason.map { $0 + " " } ?? ""
        var failure: String?
        // The mix writes a second file of about the same size next to the recording. On a nearly full disk the
        // recording is kept as it is rather than put at risk.
        if !RecordingFileStore.hasRoomForCopy(of: raw) {
            failure = DiskSpace.noRoom(to: "mix the audio tracks")
        } else {
            session.mixProgressed(0)
            let settings = recording.audioSettings
            let spans = recording.tapSpansURL.flatMap { TapSpans.read($0) }
            do {
                let plan = try await RecordingMixer.mix(source: raw, output: mixURL, fileType: recording.fileType, audioSettings: settings,
                                                        tapSpans: spans, separateMicrophone: recording.separatesMicrophone,
                                                        levelVoices: recording.levelVoices) { fraction in
                    DispatchQueue.main.async { session.mixProgressed(fraction) }
                }
                try await RecordingMixer.verify(source: raw, output: mixURL, plan: plan)
                // A rename within the folder: the final name appears with the complete file or not at all
                try fd.moveItem(at: mixURL, to: final)
            } catch {
                print("Failed to mix the audio tracks: \(error)")
                failure = error.localizedDescription
            }
        }
        if let failure = failure {
            // What the mix wrote is incomplete or not to be trusted, and the recording has everything
            try? fd.removeItem(at: mixURL)
            let kept = RecordingFileStore.keep(written: raw, as: unmixedURL)
            guard fd.fileExists(atPath: kept.path) else {
                // Not a place to claim the recording is: the writer kept writing through its open file, wherever that went
                report("Audio Mix Failed", of: recording, early + String(format: "Mixing the audio failed: %@", failure) + " " + movedNote(for: raw))
                return
            }
            let tracks = recording.systemAudioBackup ? "with each audio track as it was recorded (\(RecoveryNames.tapTracks(call: true, microphone: recording.recordMic)))" : "with system audio and microphone as two separate audio tracks"
            let body = early + String(format: "Mixing the audio failed: %@ Nothing is lost: the recording is kept %@ in: %@", failure, tracks, kept.path)
            report("Audio Mix Failed", of: recording, body)
            if recording.showPreview { showPreview(url: kept, image: frame) }
            return
        }
        print("Mixed recording saved to \(final.path)")
        var leftover: URL?
        if recording.keepUnmixed {
            let kept = RecordingFileStore.keep(written: raw, as: unmixedURL)
            if kept != unmixedURL { leftover = kept }
        } else {
            do {
                try fd.removeItem(at: raw)
            } catch {
                print("Failed to remove the unmixed recording: \(error.localizedDescription)")
                leftover = RecordingFileStore.keep(written: raw, as: unmixedURL)
            }
        }
        // Said in the one notification of the saved recording, when there is one, and in the log
        let note = leftover.map { String(format: "Its unmixed copy could not be renamed or removed and is still at: %@", $0.path) }
        if let note { RecLog.write(note) }
        present(final, image: frame, recording: recording, earlyReason: earlyReason, note: note)
    }

    /// The system audio of a sound-only recording made with the process tap, which has two files once it is closed
    /// (`kept`: the file, or the package): the tap's and the backup's. They are merged into one, stretch by stretch
    /// from the source the tap's spans and the sound say (`RecordingMixer.mergeSystemAudio`), written under a
    /// staging name and checked, and only then does it take the tap's file's name; the two files are kept beside it
    /// with "Keep the Unmixed Recording" (in the package `sys-tap` and `sys-backup`, else "(system audio tap)" and
    /// "(system audio backup)"), deleted otherwise. A merge that fails leaves the files as they are, the tap's as
    /// the recording's system audio, and is reported.
    private static func mergeSystemAudio(_ recording: RecordingContext, at kept: URL) async {
        guard recording.systemAudioBackup, let written = recording.systemAudioURL, let backupClosed = recording.backupClosedURL,
              let tapKept = recording.tapKeptURL else { return }
        let inPackage = recording.micAudioURL != nil
        // Inside whatever the package is called now
        let tap = inPackage ? kept.appendingPathComponent(written.lastPathComponent) : kept
        let backup = inPackage ? kept.appendingPathComponent(backupClosed.lastPathComponent)
            : (fd.fileExists(atPath: backupClosed.path) ? backupClosed : (recording.backupAudioURL ?? backupClosed))
        let keptTap = inPackage ? kept.appendingPathComponent(tapKept.lastPathComponent) : tapKept
        // The call tap's file, when there is one
        var call: URL?
        if let callClosed = recording.callClosedURL {
            let found = inPackage ? kept.appendingPathComponent(callClosed.lastPathComponent)
                : (fd.fileExists(atPath: callClosed.path) ? callClosed : (recording.callAudioURL ?? callClosed))
            if fd.fileExists(atPath: found.path) { call = found }
        }
        guard fd.fileExists(atPath: tap.path), fd.fileExists(atPath: backup.path) else {
            RecLog.write("System audio: the tap's or the backup's file is missing, nothing to merge")
            return
        }
        let staged = RecordingFileStore.stagingURL(for: tap)
        let spans = recording.tapSpansURL.flatMap { TapSpans.read($0) }
        let settings = recording.audioSettings
        do {
            try RecordingFileStore.checkFree(staging: staged)
            guard RecordingFileStore.hasRoomForCopy(of: tap) else { throw RecordingError(DiskSpace.noRoom(to: "merge the system audio")) }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    done.resume(with: Result { _ = try RecordingMixer.mergeSystemAudio(tap: tap, backup: backup, call: call, spans: spans, to: staged, settings: settings) })
                }
            }
            try RecordingFileStore.adoptMergedSystemAudio(merged: staged, tap: tap, keptTap: keptTap, backup: backup, call: call, keepSources: recording.keepUnmixed)
        } catch {
            try? fd.removeItem(at: staged)
            let body = String(format: "The system audio from the process tap and from its backup could not be merged: %@ The recording keeps the system audio of the process tap; what screen capture recorded as its backup is next to it: %@", error.localizedDescription, backup.path)
            report("System Audio Not Merged", of: recording, body)
        }
    }

    /// What follows an audio-only recording once its files are closed and `file` (the audio file or the package) has
    /// left its temporary name: MP3 conversion, the mix of a .qma package, or just the report. Returns when the files
    /// are in their final state. A conversion or mix that fails leaves no partial file and is reported with where the
    /// recording is.
    private static func finishAudioRecording(_ recording: RecordingContext, at file: URL, earlyReason: String?) async {
        let early = earlyReason.map { $0 + " " } ?? ""
        let audioIcon = NSImage(named: "audioIcon")
        if recording.audioFormat == .mp3 && !recording.recordMic {
            do {
                try await convertToMP3(file, to: recording.finalURL, bitrate: recording.audioQuality)
                // Only now that the MP3 is known to be complete
                try? fd.removeItem(at: file)
                present(recording.finalURL, image: audioIcon, recording: recording, earlyReason: earlyReason)
            } catch {
                let reason = String(format: "Converting to MP3 failed: %@", error.localizedDescription)
                report("MP3 Conversion Failed", of: recording, early + reason + " " + keptNote(file, "Nothing is lost: the recording is kept as: %@"))
            }
        } else if recording.remuxAudio && recording.recordMic {
            do {
                let info = try QmaInfo.read(package: file)
                // With the settings the recording was started with, not the current ones
                try await mixPackage(file, info: info, to: recording.finalURL, saveAsMP3: info.exportMP3, audioQuality: recording.audioQuality,
                                     levelVoices: recording.levelVoices)
                present(recording.finalURL, image: audioIcon, recording: recording, earlyReason: earlyReason)
            } catch {
                let body = early + String(format: "Mixing the audio failed: %@", error.localizedDescription) + " " + keptNote(file, "Nothing is lost: the recording is kept with separate audio files in: %@")
                report("Audio Mix Failed", of: recording, body)
            }
        } else {
            // A package when there is a microphone, a single audio file otherwise
            let icon = recording.recordMic ? NSImage(named: "qmaIcon") : audioIcon
            present(file, image: icon, recording: recording, earlyReason: earlyReason)
        }
    }

    /// Tells the user where the finished recording is: why it ended early if it did, then its preview, or else one
    /// quiet notification when the "Notifications" setting includes finished recordings (with `note` after the
    /// path), then the trimmer of a video when it opens after every recording. A file that is not there is reported
    /// instead: the writer kept writing through its open file wherever the save folder went.
    private static func present(_ url: URL, image: NSImage?, recording: RecordingContext, earlyReason: String?, note: String? = nil) {
        guard fd.fileExists(atPath: url.path) else {
            let reason = earlyReason.map { $0 + " " } ?? ""
            report(earlyReason == nil ? "Recording Not Found" : "Recording Stopped Early", of: recording, reason + movedNote(for: url))
            return
        }
        RecLog.write("Recording saved: \(url.path)")
        if let reason = earlyReason {
            report("Recording Stopped Early", of: recording, reason + " " + String(format: "The recording up to that point is saved as: %@", url.path))
        }
        if recording.showPreview, let image {
            showPreview(url: url, image: image)
        } else if earlyReason == nil {
            // After an early stop the report above has said where the recording is
            let body = String(format: "File saved to: %@", url.path) + (note.map { " " + $0 } ?? "")
            UserNotice.showNotification(.finished, title: "Recording Completed", body: body, id: "holdfast.completed.\(UUID().uuidString)")
        }
        if recording.trimAfterRecord && !recording.audioOnly {
            AppDelegate.shared.openTrimmer(url)
        }
    }

    /// What to tell the user when a recording is not where it was written to: the save folder was renamed or moved
    /// (or its volume went away) while recording. The file still has the name it was written under.
    private static func movedNote(for written: URL) -> String {
        return String(format: "The recording is no longer at %@: the folder was moved or renamed, or its disk was removed, while recording. Look for the file \"%@\" where the folder is now; it holds everything that was recorded.", written.deletingLastPathComponent().path, written.lastPathComponent)
    }

    /// `sentence` (a format with the path) when the recording is at `url`, where it was written; where to look for it
    /// when it is not.
    private static func keptNote(_ url: URL, _ sentence: String) -> String {
        return fd.fileExists(atPath: url.path) ? String(format: sentence, url.path) : movedNote(for: url)
    }

    /// Shows the floating preview for a finished recording, in place of the one before. `image` is that recording's
    /// first frame or an icon. Each preview has a window of its own: what an earlier one has scheduled (closing
    /// itself after a few seconds) must not reach a later one.
    static func showPreview(url: URL, image: NSImage?) {
        guard let previewImage = image, let screen = ScreenContent.getScreenWithMouse() else { return }
        for window in NSApp.windows(.preview) { window.close() }
        // As large as the view asks for (the picture, the file name, where it was saved and Done), at the bottom right
        let content = NSHostingView(rootView: PreviewView(frame: previewImage, fileURL: url))
        let fitting = content.fittingSize
        let size = fitting.width > 0 && fitting.height > 0 ? fitting : NSSize(width: 272, height: 210)
        let window = PreviewWindow(contentRect: NSRect(x: screen.frame.maxX - size.width - 14, y: screen.frame.minY + 20, width: size.width, height: size.height),
                                   styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = .preview
        window.level = .statusBar
        // Where the user is when the recording ends, a full-screen meeting included
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = content
        window.orderFront(nil)
    }

    /// Mixes the two files of the .qma `package`, at the volumes its `info` gives, into `output`: an audio file of the
    /// package's encoder (`QmaInfo.mixEnding`), or an MP3 when `saveAsMP3`; `output` has that extension. Everything is written under staging
    /// names first (`RecordingFileStore.stagingURL`), and `output` appears only with the complete, checked file;
    /// otherwise this throws and leaves nothing. A file at `output` is replaced only when `replacing` (a name confirmed
    /// in the save panel). `audioQuality` is the bitrate of lossy formats in kbit/s. With `levelVoices` each of the two
    /// files gets its "Level Voices" gain besides its volume, and the mix goes through the limiter
    /// (`RecordingMixer.mixPackage`). The package is only read.
    nonisolated static func mixPackage(_ package: URL, info: QmaInfo, to output: URL, saveAsMP3: Bool, replacing: Bool = false, audioQuality: Int,
                                       levelVoices: Bool) async throws {
        let ending = saveAsMP3 ? "mp3" : info.mixEnding
        guard output.pathExtension.lowercased() == ending else {
            throw RecordingError(String(format: "The name of the mixed file must end in .%@.", ending))
        }
        // The mix is about as large as one of the two files, and an MP3 is made from it next to it
        guard RecordingFileStore.hasRoomForCopy(of: package, in: output.deletingLastPathComponent()) else {
            throw RecordingError(DiskSpace.noRoom(to: "mix the audio tracks"))
        }
        let mixed = RecordingFileStore.stagingURL(for: output, ending: info.mixEnding)
        try RecordingFileStore.checkFree(staging: mixed)
        let settings = MovieWriter.audioSettings(format: info.encoder, quality: audioQuality, videoFormat: nil)
        do {
            try await RecordingMixer.mixPackage(system: info.systemAudio(in: package), microphone: info.microphone(in: package),
                                                volumes: (info.sysVol, info.micVol), levelVoices: levelVoices, to: mixed, settings: settings)
            if saveAsMP3 {
                try await convertToMP3(mixed, to: output, bitrate: audioQuality, replacing: replacing)
                try? fd.removeItem(at: mixed)
            } else {
                try RecordingFileStore.publish(mixed, as: output, replacing: replacing)
            }
        } catch {
            try? fd.removeItem(at: mixed)
            throw error
        }
    }

    /// Converts the audio file `source` to MP3 at `bitrate` kbit/s into `output`. The MP3 is written under its
    /// staging name (`RecordingFileStore.stagingURL`) and gets `output` only once it opens and is as long as
    /// `source`; otherwise this throws and leaves nothing. A file at `output` is replaced only when `replacing` (a
    /// name confirmed in the save panel). `source` is only read.
    nonisolated static func convertToMP3(_ source: URL, to output: URL, bitrate: Int, replacing: Bool = false) async throws {
        guard RecordingFileStore.hasRoomForCopy(of: source, in: output.deletingLastPathComponent()) else {
            throw RecordingError(DiskSpace.noRoom(to: "convert the recording to MP3"))
        }
        let staged = RecordingFileStore.stagingURL(for: output)
        // The encoder appends to a file that exists
        try RecordingFileStore.checkFree(staging: staged)
        do {
            let encoder = try SwiftLameEncoder(
                sourceUrl: source,
                configuration: .init(sampleRate: .custom(48000), bitrateMode: .constant(Int32(bitrate)), quality: .nearBest),
                destinationUrl: staged
            )
            try await encoder.encode(priority: .userInitiated)
            // The encoder does not report a failed write: a full disk leaves an empty or cut-off file
            try RecordingMixer.verifyConversion(source: source, output: staged)
            try RecordingFileStore.publish(staged, as: output, replacing: replacing)
        } catch {
            try? fd.removeItem(at: staged)
            throw error
        }
    }
}
