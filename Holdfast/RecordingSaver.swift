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
        // Held until the files are final, whether or not the recording itself kept the display awake
        SleepPreventer.shared.preventSleep(reason: "Finishing a recording", display: false)
        let frame = taken.frame
        var writer = taken.writer
        if !taken.sessionStarted {
            // Nothing arrived, so there is nothing to close: the empty file is removed and the report below says so
            writer?.cancelWriting()
            writer = nil
        }
        // A writer that already failed has nothing to finish
        var closed = false
        if let writer = writer, writer.status == .writing {
            await writer.finishWriting()
            closed = writer.status == .completed
        }
        let failureTitle = earlyReason == nil ? "Failed to Save File".local : "Recording Stopped Early".local
        if session.filesDeleted {
            // The reason says it all: what was written is gone with its name, and there is no file to point to
            UserNotice.reportFailure(title: "Recording Stopped Early".local, message: earlyReason ?? "")
        } else if !taken.sessionStarted && cancelled {
            // Stopped before the first frame or the first audio arrived. Nothing was lost, so nothing is reported as failed.
            try? fd.removeItem(at: recording.rawURL)
            UserNotice.showNotification(title: "Recording Cancelled".local, body: "The recording was stopped before anything was recorded.".local, id: "holdfast.cancelled.\(UUID().uuidString)")
        } else if !recording.audioOnly {
            if !closed {
                print("Video writing failed with status: \(String(describing: writer?.status)), error: \(String(describing: writer?.error))")
                var body = earlyReason ?? ""
                if let error = writer?.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                if body.isEmpty { body = writer == nil ? "The recording did not start, nothing was written.".local : "Unknown error".local }
                if fd.fileExists(atPath: recording.rawURL.path) {
                    // The file is written in fragments, so it plays up to the last few seconds without having been closed.
                    // It leaves its temporary name; no mix is attempted on it.
                    let kept = recording.unmixedURL.map { RecordingFileStore.keep(written: recording.rawURL, as: $0) } ?? recording.rawURL
                    body += " " + String(format: "The file could not be closed. What was written before that was kept as: %@".local, kept.path)
                } else if writer != nil {
                    body += " " + movedNote(for: recording.rawURL)
                }
                UserNotice.reportFailure(title: failureTitle, message: body)
            } else {
                if recording.mixesAudio {
                    // Where the recording ends up is only known after the mix
                    await mix(session, recording: recording, frame: frame, earlyReason: earlyReason)
                } else {
                    present(recording.finalURL, image: frame, recording: recording, earlyReason: earlyReason)
                }
            }
        } else if !taken.sessionStarted {
            // No audio arrived, so the files are empty
            try? fd.removeItem(at: recording.rawURL)
            let body = (earlyReason.map { $0 + " " } ?? "") + "No audio arrived, nothing was recorded.".local
            UserNotice.reportFailure(title: failureTitle, message: body)
        } else {
            // The files are as complete as they will get: they leave their temporary name
            let kept = recording.closedURL.map { RecordingFileStore.keep(written: recording.rawURL, as: $0) } ?? recording.rawURL
            if recording.recordMic, let writer = writer, !closed {
                // The microphone file did not close: the package is kept as it is and is not mixed
                var body = earlyReason ?? ""
                if let error = writer.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                body += (body.isEmpty ? "" : " ") + keptNote(kept, "The microphone file could not be closed. The recording was kept with separate audio files: %@".local)
                UserNotice.reportFailure(title: failureTitle, message: body)
            } else {
                // The package is only read now that the microphone file is complete
                await completion { done in finishAudioRecording(recording, at: kept, earlyReason: earlyReason, completion: done) }
            }
        }
        SleepPreventer.shared.allowSleep()
    }

    /// Mixes the audio tracks of a finished video recording and presents the result. Returns when the recording has
    /// its final name. The recording as it was written is only removed or renamed after the mix has been written
    /// completely, checked against it and moved to the final name; whatever goes wrong before that, it is kept
    /// under its "(unmixed, 2 audio tracks)" name and the user is told. The work itself runs off the main thread.
    private static func mix(_ session: RecordingSession, recording: RecordingContext, frame: NSImage?, earlyReason: String?) async {
        guard let mixURL = recording.mixURL, let unmixedURL = recording.unmixedURL else { return }
        let raw = recording.rawURL
        let final = recording.finalURL
        let early = earlyReason.map { $0 + " " } ?? ""
        var failure: String?
        // The mix writes a second file of about the same size next to the recording. On a nearly full disk the
        // recording is kept as it is rather than put at risk.
        if !RecordingFileStore.hasRoomForCopy(of: raw) {
            failure = "Not enough free disk space to mix the audio tracks.".local
        } else {
            session.mixProgressed(0)
            let settings = recording.audioSettings
            do {
                try await RecordingMixer.mix(source: raw, output: mixURL, fileType: recording.fileType, audioSettings: settings) { fraction in
                    DispatchQueue.main.async { session.mixProgressed(fraction) }
                }
                try await RecordingMixer.verify(source: raw, output: mixURL)
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
                UserNotice.reportFailure(title: "Audio Mix Failed".local, message: early + String(format: "Mixing the audio failed: %@".local, failure) + " " + movedNote(for: raw))
                return
            }
            let body = early + String(format: "Mixing the audio failed: %@ Nothing is lost: the recording is kept with system audio and microphone as two separate audio tracks in: %@".local, failure, kept.path)
            UserNotice.reportFailure(title: "Audio Mix Failed".local, message: body)
            if recording.showPreview { showPreview(path: kept.path, image: frame) }
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
        if let leftover = leftover {
            let body = String(format: "The recording was mixed and saved, but its unmixed copy is still at: %@".local, leftover.path)
            UserNotice.showNotification(title: "Recording Completed".local, body: body, id: "holdfast.completed.\(UUID().uuidString)")
        }
        present(final, image: frame, recording: recording, earlyReason: earlyReason)
    }

    /// What follows an audio-only recording once its files are closed and `file` (the audio file or the package) has
    /// left its temporary name: MP3 conversion, the mix of a .qma package, or just the report. `completion` is called
    /// once, when the files are in their final state. A conversion or mix that fails leaves no partial file and is
    /// reported with where the recording is. Main thread: it shows the preview and creates the audio player that
    /// does the mix.
    private static func finishAudioRecording(_ recording: RecordingContext, at file: URL, earlyReason: String?, completion: @escaping () -> Void) {
        let early = earlyReason.map { $0 + " " } ?? ""
        let audioIcon = NSImage(named: "audioIcon")
        if recording.audioFormat == .mp3 && !recording.recordMic {
            let source = file
            let output = recording.finalURL
            Task {
                defer { completion() }
                do {
                    try await convertToMP3(source, to: output, bitrate: recording.audioQuality)
                    // Only now that the MP3 is known to be complete
                    try? fd.removeItem(at: source)
                    present(output, image: audioIcon, recording: recording, earlyReason: earlyReason)
                } catch {
                    let reason = String(format: "Converting to MP3 failed: %@".local, error.localizedDescription)
                    UserNotice.reportFailure(title: "MP3 Conversion Failed".local, message: early + reason + " " + keptNote(source, "Nothing is lost: the recording is kept as: %@".local))
                }
            }
        } else if recording.remuxAudio && recording.recordMic {
            let package = file
            func failed(_ reason: String) {
                let body = early + String(format: "Mixing the audio failed: %@".local, reason) + " " + keptNote(package, "Nothing is lost: the recording is kept with separate audio files in: %@".local)
                UserNotice.reportFailure(title: "Audio Mix Failed".local, message: body)
            }
            let player = AudioPlayerManager()
            do {
                let info = try QmaInfo.read(package: package)
                try player.loadAudioFiles(package: package, info: info)
                // With the settings the recording was started with, not the current ones
                player.saveFile(recording.finalURL, saveAsMP3: info.exportMP3, audioQuality: recording.audioQuality) { result in
                    switch result {
                    case .success(let file): present(file, image: audioIcon, recording: recording, earlyReason: earlyReason)
                    case .failure(let error): failed(error.localizedDescription)
                    }
                    completion()
                }
            } catch {
                failed(error.localizedDescription)
                completion()
            }
        } else {
            // A package when there is a microphone, a single audio file otherwise
            let icon = recording.recordMic ? NSImage(named: "qmaIcon") : audioIcon
            present(file, image: icon, recording: recording, earlyReason: earlyReason)
            completion()
        }
    }

    /// Tells the user where the finished recording is: why it ended early if it did, then its preview, or a
    /// notification when previews are off, then the trimmer of a video when it opens after every recording. A file
    /// that is not there is reported instead: the writer kept writing through its open file wherever the save folder went.
    private static func present(_ url: URL, image: NSImage?, recording: RecordingContext, earlyReason: String?) {
        guard fd.fileExists(atPath: url.path) else {
            let reason = earlyReason.map { $0 + " " } ?? ""
            UserNotice.reportFailure(title: earlyReason == nil ? "Recording Not Found".local : "Recording Stopped Early".local, message: reason + movedNote(for: url))
            return
        }
        RecLog.write("Recording saved: \(url.path)")
        if let reason = earlyReason {
            UserNotice.reportFailure(title: "Recording Stopped Early".local, message: reason + " " + String(format: "The recording up to that point is saved as: %@".local, url.path))
        }
        if recording.showPreview, let image {
            showPreview(path: url.path, image: image)
        } else {
            UserNotice.showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "holdfast.completed.\(UUID().uuidString)")
        }
        if recording.trimAfterRecord && !recording.audioOnly {
            AppDelegate.shared.openTrimmer(url)
        }
    }

    /// What to tell the user when a recording is not where it was written to: the save folder was renamed or moved
    /// (or its volume went away) while recording. The file still has the name it was written under.
    private static func movedNote(for written: URL) -> String {
        return String(format: "The recording is no longer at %@: the folder was moved or renamed, or its disk was removed, while recording. Look for the file \"%@\" where the folder is now; it holds everything that was recorded.".local, written.deletingLastPathComponent().path, written.lastPathComponent)
    }

    /// `sentence` (a format with the path) when the recording is at `url`, where it was written; where to look for it
    /// when it is not.
    private static func keptNote(_ url: URL, _ sentence: String) -> String {
        return fd.fileExists(atPath: url.path) ? String(format: sentence, url.path) : movedNote(for: url)
    }

    /// Shows the floating preview for a finished recording, in place of the one before. `image` is that recording's
    /// first frame or an icon. Each preview has a window of its own: what an earlier one has scheduled (closing
    /// itself after a few seconds) must not reach a later one.
    static func showPreview(path: String, image: NSImage?) {
        guard let previewImage = image, let screen = ScreenContent.getScreenWithMouse() else { return }
        for window in NSApp.windows(.preview) { window.close() }
        let window = PreviewWindow(contentRect: NSRect(x: screen.frame.maxX - 280, y: screen.frame.minY + 20, width: 266, height: 156),
                                   styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = .preview
        window.level = .statusBar
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
        window.orderFront(nil)
    }

    /// Converts the audio file `source` to MP3 at `bitrate` kbit/s into `output`. The MP3 is written under its
    /// staging name (`RecordingFileStore.stagingURL`) and gets `output` only once it opens and is as long as
    /// `source`; otherwise this throws and leaves nothing. A file at `output` is replaced only when `replacing` (a
    /// name confirmed in the save panel). `source` is only read.
    nonisolated static func convertToMP3(_ source: URL, to output: URL, bitrate: Int, replacing: Bool = false) async throws {
        guard RecordingFileStore.hasRoomForCopy(of: source, in: output.deletingLastPathComponent()) else {
            throw RecordingError("Not enough free disk space to convert the recording to MP3.")
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
