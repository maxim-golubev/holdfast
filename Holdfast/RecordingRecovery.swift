//
//  RecordingRecovery.swift
//  Holdfast
//

import AppKit
import AVFoundation
import Foundation

/// What is done at launch about the recordings an earlier run left under a temporary name. `RecorderController`
/// has one. It is not part of the recording state: a recording can be started while it runs, since it only works
/// on files of an earlier run. Quitting waits for it.
@MainActor
final class RecordingRecovery {
    /// Whether leftovers of an earlier run are still being dealt with
    private(set) var isRunning = false
    /// From 0 to 1 while a recording left by an earlier run is being mixed, nil otherwise
    private(set) var progress: Double?
    private var handlers = [() -> Void]()
    /// It began or ended
    var runningChanged: @MainActor () -> Void = {}
    var progressChanged: @MainActor () -> Void = {}
    /// Title and text of the one report of what was found
    var report: @MainActor (String, String) -> Void = { _, _ in }

    /// Runs `handler` once the recovery is over; at once when it is not running.
    func whenDone(_ handler: @escaping () -> Void) {
        if isRunning { handlers.append(handler) } else { handler() }
    }

    /// Once at launch. A recording that was being written or mixed when the app crashed or was killed
    /// is still in the save folder under its temporary name. Each such file gets a name that says what it is, and a
    /// recording that opens gets the audio mix it did not get (`recover`). The user is told in one report.
    /// Nothing is deleted. With another instance of the app running, the files may be its recording, so nothing is touched.
    func start(in directory: String) {
        let instances = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        guard !isRunning, instances.count <= 1 else { return }
        let found = RecordingFileStore(directory: directory).leftovers()
        guard !found.isEmpty else { return }
        // The settings such a recording was started with are not known any more, so the mix uses the current ones
        let settings = Dictionary(found.filter { !$0.isAudio }.map { ($0.ending, MovieWriter.audioSettings(videoFormat: $0.ending.lowercased())) }, uniquingKeysWith: { first, _ in first })
        isRunning = true
        runningChanged()
        // A token of its own, like every recording's (`SleepAssertion`): a recording may run meanwhile
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Finishing a recording from an earlier run")
        Task.detached {
            let lines = await RecordingRecovery.recover(found, audioSettings: settings, separateMicrophone: !AppSettings.remuxAudio, levelVoices: AppSettings.levelVoices) { fraction in
                DispatchQueue.main.async {
                    guard self.isRunning else { return }
                    self.progress = fraction
                    self.progressChanged()
                }
            }
            let message = String(format: "Found in %@ from an earlier run of Holdfast that did not end normally:", directory) + "\n\n" + lines.joined(separator: "\n\n")
            await MainActor.run {
                ProcessInfo.processInfo.endActivity(activity)
                self.isRunning = false
                self.progress = nil
                self.progressChanged()
                self.runningChanged()
                let handlers = self.handlers
                self.handlers = []
                self.report("Recording Recovered", message)
                handlers.forEach { $0() }
            }
        }
    }

    /// Deals with every leftover and returns one paragraph about each for the report. What an interrupted mix or
    /// conversion wrote goes out of the way first: it says nothing about the recording it was made from (the mix of a
    /// recording that was never closed is written under the same marker), and it would be in the way of a new mix.
    /// `audioSettings` are those to mix a video of each ending with; `separateMicrophone` keeps the microphone of a
    /// recording made with the process tap as a track of its own ("Mix Microphone into the Main Track" off);
    /// `levelVoices` mixes with "Level Voices", as the setting is now.
    nonisolated static func recover(_ found: [RecordingFileStore.Leftover], audioSettings: [String: [String: Any]], separateMicrophone: Bool = false,
                                    levelVoices: Bool = false, progress: @escaping (Double) -> Void) async -> [String] {
        var lines = [String]()
        for leftover in found where leftover.isMix {
            lines.append(rename(leftover, RecoveryNames.incompleteMix, "\"%@\" is what an interrupted audio mix or MP3 conversion had written. The recording it was made from is kept separately; this file can be deleted."))
        }
        for leftover in found where !leftover.isMix {
            if leftover.isAudio {
                lines.append(await recoverAudio(leftover))
            } else {
                lines.append(await recover(leftover, audioSettings: audioSettings[leftover.ending] ?? [:], separateMicrophone: separateMicrophone, levelVoices: levelVoices, progress: progress))
            }
            // Its final names are given: the tap's spans next to it have served
            RecordingFileStore.removeTapSpans(RecordingFileStore.tapSpansURL(base: leftover.base))
        }
        return lines
    }

    /// Renames a leftover to `<base> (<label>).<ending>` (numbered when taken) and returns `line` with its new name
    /// in place of `%@`, saying so when it could not be renamed
    private nonisolated static func rename(_ leftover: RecordingFileStore.Leftover, _ label: String, _ line: String) -> String {
        let target = RecordingFileStore.freeURL(base: leftover.base, label: label, ending: leftover.ending)
        let now = RecordingFileStore.keep(written: leftover.url, as: target)
        print("Leftover \(leftover.url.lastPathComponent) -> \(now.lastPathComponent)")
        let text = String(format: line, now.lastPathComponent)
        return now == target ? text : text + " " + "It could not be renamed."
    }

    /// What the report says of a recording that does not open, `%@` its name
    private nonisolated static let unopenable = "\"%@\" is a recording that was not finished and cannot be opened."

    /// What it says of one that opens but was not closed, `seconds` long, after its name
    private nonisolated static func unfinished(_ seconds: Double) -> String {
        return String(format: "is a recording that was not finished (%@); its last seconds may be missing.", length(seconds))
    }

    /// An audio-only recording that was never closed: an audio file, or a .qma package of two. Nothing is mixed: a
    /// file that opens becomes `X (recovered)`, one that does not `X (damaged)`; a package is recovered when one of
    /// its files opens, and the report says which does not.
    nonisolated static func recoverAudio(_ leftover: RecordingFileStore.Leftover) async -> String {
        guard leftover.ending.lowercased() == RecordingFileStore.packageEnding else {
            guard let seconds = await RecordingMixer.inspect(leftover.url).seconds else {
                return rename(leftover, RecoveryNames.damaged, unopenable)
            }
            return rename(leftover, RecoveryNames.recovered, "\"%@\" " + unfinished(seconds).replacingOccurrences(of: "%", with: "%%"))
        }
        guard let info = try? QmaInfo.read(package: leftover.url) else {
            return rename(leftover, RecoveryNames.damaged, unopenable)
        }
        let system = await RecordingMixer.inspect(info.systemAudio(in: leftover.url)).seconds != nil
        let microphone = await RecordingMixer.inspect(info.microphone(in: leftover.url)).seconds != nil
        guard system || microphone else { return rename(leftover, RecoveryNames.damaged, unopenable) }
        var line = "\"%@\" " + "is a recording that was not finished, with system audio and microphone as separate files."
        if system && microphone {
            line += " " + "Open it in Holdfast to listen to it or to export a mix."
        } else {
            let (bad, good) = system ? ("mic", "sys") : ("sys", "mic")
            line += " " + String(format: "Its file %@ cannot be opened; %@ opens on its own (Show Package Contents in Finder).", "\(bad).\(info.format)", "\(good).\(info.format)").replacingOccurrences(of: "%", with: "%%")
        }
        return rename(leftover, RecoveryNames.recovered, line)
    }

    /// A length as the report gives it: "1h 2m 3s"
    private nonisolated static func length(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
    
    /// Deals with one recording left under its temporary name and returns what to tell the user about it.
    /// A file that does not open becomes `X (damaged)`. One that opens is mixed under the rules of `RecordingSaver.mix`:
    /// the mix is written to `X.mixing`, checked, and only then renamed, and the recording itself is only ever renamed.
    /// - Closed before the app went away (it is not in fragments any more): it is complete. Mix `X`, recording
    ///   `X (unmixed, N audio tracks)`. Only the file itself says so; a `.mixing` file next to it does not, because
    ///   the recovery mix of an unclosed recording leaves one too when it is interrupted.
    /// - Never closed: it plays up to its last seconds. Mix `X (recovered)`, recording `X (recovered, unmixed, N audio tracks)`.
    /// - The mix fails: recording `X (unmixed, N audio tracks)` when complete, `X (recovered)` when not.
    /// A recording made with the process tap is mixed by the tap's spans it left next to it (`TapSpans`), like
    /// after a stop.
    nonisolated static func recover(_ leftover: RecordingFileStore.Leftover, audioSettings: [String: Any], separateMicrophone: Bool = false,
                                    levelVoices: Bool = false, progress: @escaping (Double) -> Void) async -> String {
        let raw = leftover.url
        let base = leftover.base
        let ending = leftover.ending
        let info = await RecordingMixer.inspect(raw)
        guard let seconds = info.seconds else {
            return rename(leftover, RecoveryNames.damaged, unopenable)
        }
        let complete = !info.fragmented
        let what = complete
            ? String(format: "is a complete recording (%@) whose audio had not been mixed yet when the app went away.", length(seconds))
            : unfinished(seconds)
        let tracks = max(2, info.audioTracks)
        let separate = tracks > 2
            ? "It plays, with its \(tracks) audio tracks as they were recorded (system audio from the process tap, its backup from screen capture, the microphone); many players only play the first."
            : "It plays, with system audio and microphone as two separate audio tracks (many players only play the first, which is system audio)."
        let mixURL = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.mixMarker, ending: ending)
        let final = RecordingFileStore.freeURL(base: base, label: RecoveryNames.mix(complete: complete), ending: ending)
        var failure: String?
        if !info.mixable {
            failure = "It does not have one video and two or three audio tracks."
        } else if FileManager.default.fileExists(atPath: mixURL.path) {
            // What the interrupted mix wrote could not be moved away; it is not overwritten
            failure = "The file of the interrupted mix is in the way."
        } else if !RecordingFileStore.hasRoomForCopy(of: raw) {
            failure = DiskSpace.noRoom(to: "mix the audio tracks")
        } else {
            do {
                let spans = TapSpans.read(RecordingFileStore.tapSpansURL(base: base))
                let plan = try await RecordingMixer.mix(source: raw, output: mixURL, fileType: ending.lowercased() == "mov" ? .mov : .mp4, audioSettings: audioSettings,
                                                        tapSpans: spans, separateMicrophone: separateMicrophone, levelVoices: levelVoices, progress: progress)
                try await RecordingMixer.verify(source: raw, output: mixURL, unfinished: !complete, plan: plan)
                try FileManager.default.moveItem(at: mixURL, to: final)
            } catch {
                print("Failed to mix the leftover \(raw.lastPathComponent): \(error)")
                failure = error.localizedDescription
                // Only what this mix wrote: there was no such file before it
                try? FileManager.default.removeItem(at: mixURL)
            }
        }
        if let failure = failure {
            let line = "\"%@\" " + what + " " + String(format: "Mixing its audio now failed: %@", failure).replacingOccurrences(of: "%", with: "%%") + " " + separate
            return rename(leftover, RecoveryNames.recording(complete: complete, mixed: false, tracks: tracks), line)
        }
        let mixed = String(format: "\"%@\" ", final.lastPathComponent) + what + " " + "Its audio was mixed now."
        let kept = "The recording as it was written, with its audio tracks separate, is kept as \"%@\"."
        return rename(leftover, RecoveryNames.recording(complete: complete, mixed: true, tracks: tracks), mixed.replacingOccurrences(of: "%", with: "%%") + " " + kept)
    }
}
