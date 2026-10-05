//
//  RecordingRecovery.swift
//  QuickRecorder
//

import AppKit
import AVFoundation
import Foundation

// What is done at launch about the recordings an earlier run left under a temporary name

extension SCContext {
    /// Whether leftovers of an earlier run are still being dealt with. Main thread only.
    private(set) static var isRecovering = false
    /// Main thread. Set when the app was asked to quit and is waiting for its files to be final.
    static var quitRequested = false
    /// Whether the status item shows the "Recovering…" pill: always while quitting waits for the recovery, so the
    /// app does not look hung, and otherwise only where it does not take the place of the menu bar icon, from which
    /// a recording can be started meanwhile.
    static var showsRecovery: Bool { isRecovering && (quitRequested || !AppSettings.showMenubar) }
    private static var recoveredHandlers = [() -> Void]()
    
    /// Main thread. Runs `handler` once launch recovery is over; at once when it is not running.
    static func whenRecovered(_ handler: @escaping () -> Void) {
        if isRecovering { recoveredHandlers.append(handler) } else { handler() }
    }
    
    /// Main thread, once at launch. A recording that was being written or mixed when the app crashed or was killed
    /// is still in the save folder under its temporary name. Each such file gets a name that says what it is, and a
    /// recording that opens gets the audio mix it did not get (`recoverRecording`). The user is told in one report.
    /// Nothing is deleted. With another instance of the app running, the files may be its recording, so nothing is touched.
    /// This is not part of the recording state: a recording can be started while it runs, since it only works on
    /// files of an earlier run. Quitting waits for it.
    static func recoverLeftovers() {
        let instances = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        guard !isRecovering, instances.count <= 1 else { return }
        let directory = AppSettings.saveDirectory
        let found = RecordingFileStore(directory: directory).leftovers()
        guard !found.isEmpty else { return }
        // The settings such a recording was started with are not known any more, so the mix uses the current ones
        let settings = Dictionary(found.map { ($0.ending, MovieWriter.audioSettings(videoFormat: $0.ending.lowercased())) }, uniquingKeysWith: { first, _ in first })
        isRecovering = true
        updateStatusBar()
        // A token of its own: the sleep assertion of SleepPreventer belongs to the recording that may run meanwhile
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Finishing a recording from an earlier run")
        Task.detached {
            var lines = [String]()
            // What an interrupted mix wrote goes out of the way first. It says nothing about the recording it was
            // made from: the mix of a recording that was never closed is written under the same marker.
            for leftover in found where leftover.isMix {
                let target = RecordingFileStore.freeURL(base: leftover.base, label: RecoveryNames.incompleteMix, ending: leftover.ending)
                let now = RecordingFileStore.keep(written: leftover.url, as: target)
                print("Leftover \(leftover.url.lastPathComponent) -> \(now.lastPathComponent)")
                var line = String(format: "\"%@\" is what an interrupted audio mix had written. The recording it was made from is kept separately; this file can be deleted.".local, now.lastPathComponent)
                if now != target { line += " " + "It could not be renamed.".local }
                lines.append(line)
            }
            for leftover in found where !leftover.isMix {
                lines.append(await recoverRecording(leftover, audioSettings: settings[leftover.ending] ?? [:]))
            }
            let message = String(format: "Found in %@ from an earlier run of QuickRecorder that did not end normally:".local, directory) + "\n\n" + lines.joined(separator: "\n\n")
            await MainActor.run {
                ProcessInfo.processInfo.endActivity(activity)
                isRecovering = false
                RecordingHealth.shared.recoveryProgress = nil
                updateStatusBar()
                let handlers = recoveredHandlers
                recoveredHandlers = []
                reportFailure(title: "Recording Recovered".local, message: message)
                handlers.forEach { $0() }
            }
        }
    }
    
    /// Deals with one recording left under its temporary name and returns what to tell the user about it.
    /// A file that does not open becomes `X (damaged)`. One that opens is mixed under the rules of `mixRecording`:
    /// the mix is written to `X.mixing`, checked, and only then renamed, and the recording itself is only ever renamed.
    /// - Closed before the app went away (it is not in fragments any more): it is complete. Mix `X`, recording
    ///   `X (unmixed, 2 audio tracks)`. Only the file itself says so; a `.mixing` file next to it does not, because
    ///   the recovery mix of an unclosed recording leaves one too when it is interrupted.
    /// - Never closed: it plays up to its last seconds. Mix `X (recovered)`, recording `X (recovered, unmixed, 2 audio tracks)`.
    /// - The mix fails: recording `X (unmixed, 2 audio tracks)` when complete, `X (recovered)` when not.
    private static func recoverRecording(_ leftover: RecordingFileStore.Leftover, audioSettings: [String: Any]) async -> String {
        let raw = leftover.url
        let base = leftover.base
        let ending = leftover.ending
        let info = await RecordingMixer.inspect(raw)
        /// Renames the recording and says so when that fails
        func rename(_ label: String, _ line: String) -> String {
            let target = RecordingFileStore.freeURL(base: base, label: label, ending: ending)
            let now = RecordingFileStore.keep(written: raw, as: target)
            print("Leftover \(raw.lastPathComponent) -> \(now.lastPathComponent)")
            let text = String(format: line, now.lastPathComponent)
            return now == target ? text : text + " " + "It could not be renamed.".local
        }
        guard let seconds = info.seconds else {
            return rename(RecoveryNames.damaged, "\"%@\" is a recording that was not finished and cannot be opened.".local)
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        let length = formatter.string(from: seconds) ?? ""
        let complete = !info.fragmented
        let what = complete
            ? String(format: "is a complete recording (%@) whose audio had not been mixed yet when the app went away.".local, length)
            : String(format: "is a recording that was not finished (%@); its last seconds may be missing.".local, length)
        let separate = "It plays, with system audio and microphone as two separate audio tracks (many players only play the first, which is system audio).".local
        let mixURL = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.mixMarker, ending: ending)
        let final = RecordingFileStore.freeURL(base: base, label: RecoveryNames.mix(complete: complete), ending: ending)
        var failure: String?
        if !info.mixable {
            failure = "It does not have one video and two audio tracks.".local
        } else if fd.fileExists(atPath: mixURL.path) {
            // What the interrupted mix wrote could not be moved away; it is not overwritten
            failure = "The file of the interrupted mix is in the way.".local
        } else if !RecordingFileStore.hasRoomForCopy(of: raw) {
            failure = "Not enough free disk space to mix the audio tracks.".local
        } else {
            do {
                try await RecordingMixer.mix(source: raw, output: mixURL, fileType: ending.lowercased() == "mov" ? .mov : .mp4, audioSettings: audioSettings) { fraction in
                    DispatchQueue.main.async {
                        if isRecovering { RecordingHealth.shared.recoveryProgress = fraction }
                    }
                }
                try await RecordingMixer.verify(source: raw, output: mixURL)
                try fd.moveItem(at: mixURL, to: final)
            } catch {
                print("Failed to mix the leftover \(raw.lastPathComponent): \(error)")
                failure = error.localizedDescription
                // Only what this mix wrote: there was no such file before it
                try? fd.removeItem(at: mixURL)
            }
        }
        if let failure = failure {
            let line = "\"%@\" " + what + " " + String(format: "Mixing its audio now failed: %@".local, failure).replacingOccurrences(of: "%", with: "%%") + " " + separate
            return rename(RecoveryNames.recording(complete: complete, mixed: false), line)
        }
        let mixed = String(format: "\"%@\" ".local, final.lastPathComponent) + what + " " + "Its audio was mixed now.".local
        let kept = "The recording as it was written, with system audio and microphone as separate audio tracks, is kept as \"%@\".".local
        return rename(RecoveryNames.recording(complete: complete, mixed: true), mixed.replacingOccurrences(of: "%", with: "%%") + " " + kept)
    }
}
