//
//  RecordingSaver.swift
//  QuickRecorder
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
        let failureTitle = earlyReason == nil ? "Failed to save file".local : "Recording Stopped Early".local
        let savedSoFar = String(format: "The recording up to that point is saved as: %@".local, recording.finalURL.path)
        if !taken.sessionStarted && cancelled {
            // Stopped before the first frame or the first audio arrived. Nothing was lost, so nothing is reported as failed.
            try? fd.removeItem(at: recording.rawURL)
            UserNotice.showNotification(title: "Recording Cancelled".local, body: "The recording was stopped before anything was recorded.".local, id: "quickrecorder.cancelled.\(UUID().uuidString)")
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
                    if let reason = earlyReason { UserNotice.reportFailure(title: failureTitle, message: reason + " " + savedSoFar) }
                    let url = recording.finalURL
                    if !recording.showPreview {
                        UserNotice.showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "quickrecorder.completed.\(UUID().uuidString)")
                    } else {
                        showPreview(path: url.path, image: frame)
                    }
                    if recording.trimAfterRecord {
                        AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
                    }
                }
            }
        } else if !taken.sessionStarted {
            // No audio arrived, so the files are empty
            try? fd.removeItem(at: recording.rawURL)
            let body = (earlyReason.map { $0 + " " } ?? "") + "No audio arrived, nothing was recorded.".local
            UserNotice.reportFailure(title: failureTitle, message: body)
        } else if recording.recordMic, let writer = writer, !closed {
            // The microphone file did not close: the package is kept as it is and is not mixed
            var body = earlyReason ?? ""
            if let error = writer.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
            body += (body.isEmpty ? "" : " ") + String(format: "The microphone file could not be closed. The recording was kept with separate audio files: %@".local, recording.rawURL.path)
            UserNotice.reportFailure(title: failureTitle, message: body)
        } else {
            // The package is only read now that the microphone file is complete
            if let reason = earlyReason { UserNotice.reportFailure(title: failureTitle, message: reason + " " + savedSoFar) }
            await completion { done in finishAudioRecording(recording, completion: done) }
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
            UserNotice.showNotification(title: "Recording Completed".local, body: body, id: "quickrecorder.completed.\(UUID().uuidString)")
        }
        if let reason = earlyReason {
            UserNotice.reportFailure(title: "Recording Stopped Early".local, message: reason + " " + String(format: "The recording up to that point is saved as: %@".local, final.path))
        }
        if !recording.showPreview {
            UserNotice.showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, final.path), id: "quickrecorder.completed.\(UUID().uuidString)")
        }
        if recording.trimAfterRecord {
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: final), title: final.lastPathComponent, only: false)
        } else if recording.showPreview {
            showPreview(path: final.path, image: frame)
        }
    }

    /// What follows an audio-only recording once its files are closed: MP3 conversion, the mix of a .qma package, or just the report.
    /// `completion` is called once, when the files are in their final state. Main thread: it shows the preview
    /// and creates the audio player that does the mix.
    private static func finishAudioRecording(_ recording: RecordingContext, completion: @escaping () -> Void) {
        if recording.audioFormat == .mp3 && !recording.recordMic {
            guard let source = recording.systemAudioURL else { completion(); return }
            let output = recording.finalURL
            Task {
                defer { completion() }
                do {
                    try await m4a2mp3(inputUrl: source, outputUrl: output, bitrate: recording.audioQuality)
                    try? fd.removeItem(at: source)
                    if !recording.showPreview {
                        let title = "Recording Completed".local
                        let body = String(format: "File saved to: %@".local, output.path)
                        let id = "quickrecorder.completed.\(UUID().uuidString)"
                        UserNotice.showNotification(title: title, body: body, id: id)
                    } else {
                        DispatchQueue.main.async { showPreview(path: output.path, image: NSImage(named: "audioIcon")) }
                    }
                } catch {
                    let body = String(format: "%@ The recording was kept as: %@".local, error.localizedDescription, source.path)
                    UserNotice.showNotification(title: "Failed to save file".local, body: body, id: "quickrecorder.error.\(UUID().uuidString)")
                }
            }
        } else if recording.remuxAudio && recording.recordMic {
            let package = recording.rawURL
            if let document = try? qmaPackageHandle.load(from: package) {
                let audioPlayerManager = AudioPlayerManager()
                audioPlayerManager.loadAudioFiles(format: document.info.format, package: package, encoder: document.info.encoder, saveMP3: document.info.exportMP3)
                audioPlayerManager.sysVol = document.info.sysVol
                audioPlayerManager.micVol = document.info.micVol
                // With the settings the recording was started with, not the current ones
                audioPlayerManager.saveFile(recording.finalURL, saveAsMP3: document.info.exportMP3, audioQuality: recording.audioQuality, videoFormat: recording.videoFormat.rawValue, completion: completion)
            } else {
                let body = String(format: "The recording was kept with separate audio files: %@".local, package.path)
                UserNotice.showNotification(title: "Audio Mix Failed".local, body: body, id: "quickrecorder.error.\(UUID().uuidString)")
                completion()
            }
        } else {
            if !recording.showPreview {
                let title = "Recording Completed".local
                let body = String(format: "File saved to: %@".local, recording.rawURL.path)
                let id = "quickrecorder.completed.\(UUID().uuidString)"
                UserNotice.showNotification(title: title, body: body, id: id)
            } else {
                showPreview(path: recording.rawURL.path, image: NSImage(named: "qmaIcon"))
            }
            completion()
        }
    }

    /// What to tell the user when a recording is not where it was written to: the save folder was renamed or moved
    /// (or its volume went away) while recording. The file still has the name it was written under.
    private static func movedNote(for written: URL) -> String {
        return String(format: "The recording is no longer at %@: the folder was moved or renamed, or its disk was removed, while recording. Look for the file \"%@\" where the folder is now; it holds everything that was recorded.".local, written.deletingLastPathComponent().path, written.lastPathComponent)
    }

    /// Shows the floating preview for a finished recording. `image` is that recording's first frame or an icon.
    static func showPreview(path: String, image: NSImage?) {
        if let previewImage = image, let screen = ScreenContent.getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(nil)
        }
    }

    nonisolated static func m4a2mp3(inputUrl: URL, outputUrl: URL, bitrate: Int = AppSettings.audioQuality.rawValue) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(bitrate)),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
}
