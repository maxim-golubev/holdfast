//
//  InstantStartTests.swift
//  A recording starts the moment it is asked for, whatever earlier recordings are still being closed or mixed:
//  each is a session of its own with its own files (RecorderController, RecordingSession, with the real writer
//  and the real mix where files matter).
//

import AVFoundation
import Foundation

/// A recorder whose recordings are written by the real `MovieWriter` and saved like the app saves a video (closed,
/// mixed by `RecordingMixer`, checked, renamed), into one folder. A recording can be held just before its mix, and
/// its mix can be made to fail.
@MainActor
final class LiveRig {
    /// One recording: its session, its writer and the tone its system audio is (a whole number of cycles in 10 ms,
    /// so that one recording's tone measures as nothing at another's frequency)
    struct Take {
        let session: RecordingSession
        let run: TestRecording
        let frequency: Double
        var base: String { run.recording.base }
        var final: URL { run.recording.finalURL }
        var raw: URL { run.recording.rawURL }
    }

    @MainActor
    final class Saver {
        /// The recordings (by `RecordingFiles.base`) that wait before their mix until released
        var held = Set<String>()
        var gates = [String: CheckedContinuation<Void, Never>]()
        /// Those whose mix throws
        var failing = Set<String>()
        /// Final files, in the order they were finished
        var saved = [URL]()
        /// What the user would be told of a failure
        var reports = [String]()
        var awake = 0

        func save(_ session: RecordingSession, _ recording: RecordingContext, _ taken: MovieWriter.Finished) async {
            if let writer = taken.writer, writer.status == .writing { await writer.finishWriting() }
            guard taken.writer?.status == .completed, let mixURL = recording.mixURL, let unmixedURL = recording.unmixedURL else {
                reports.append("Failed to Save File: \(recording.rawURL.lastPathComponent)")
                return
            }
            if held.contains(recording.base) { await withCheckedContinuation { gates[recording.base] = $0 } }
            let raw = recording.rawURL
            do {
                if failing.contains(recording.base) { throw TestError("this mix was made to fail") }
                session.mixProgressed(0)
                let plan = try await RecordingMixer.mix(source: raw, output: mixURL, fileType: recording.fileType, audioSettings: recording.audioSettings,
                                                        separateMicrophone: recording.separatesMicrophone) { fraction in
                    DispatchQueue.main.async { session.mixProgressed(fraction) }
                }
                try await RecordingMixer.verify(source: raw, output: mixURL, plan: plan)
                try FileManager.default.moveItem(at: mixURL, to: recording.finalURL)
                _ = RecordingFileStore.keep(written: raw, as: unmixedURL)
                saved.append(recording.finalURL)
            } catch {
                try? FileManager.default.removeItem(at: mixURL)
                let kept = RecordingFileStore.keep(written: raw, as: unmixedURL)
                reports.append("Audio Mix Failed: \(kept.lastPathComponent): \(error)")
            }
        }
    }

    let name: String
    let queue = DispatchQueue(label: "HoldfastTests.live")
    let folder: URL
    let controller: RecorderController
    let saver = Saver()
    private let journal = Journal()

    init(_ name: String) throws {
        self.name = name
        folder = try Suite.folder(name)
        var environment = RecorderEnvironment()
        environment.keepAwake = { [saver] in
            saver.awake += 1
            return { saver.awake -= 1 }
        }
        environment.save = { [saver] session, recording, taken, _, _ in await saver.save(session, recording, taken) }
        controller = RecorderController(queue: queue, environment: environment)
    }

    /// What the app does from an accepted start to the running capture, with the names the recorder says are taken
    func start(frequency: Double) throws -> Take {
        let session = try require(controller.begin(.screen), "an accepted start")
        let run = try TestRecording(folder: name, settings: ["remuxAudio": true, "recordWinSound": true], reserved: controller.basesInUse)
        session.install(run.writer)
        session.attach(FakeCapture(journal))
        try run.writer.prepareVideo(width: 320, height: 240)
        session.startCapturing()
        session.enterRecording()
        return Take(session: session, run: run, frequency: frequency)
    }

    /// `seconds` of picture, system audio (the take's tone) and a quiet microphone, a tenth of a second at a time,
    /// through the session like the capture's buffers. `from` is where the take's own time goes on.
    func feed(_ take: Take, from start: Double = 0, seconds: Double) throws {
        var step = 0
        while Double(step) / 10 < seconds - 0.001 {
            let t = start + Double(step) / 10
            let pts = take.run.at(t)
            try queue.sync {
                take.session.received(CaptureSample(kind: .screen(complete: true), buffer: try videoFrame(at: pts, shade: Int(t * 50)), pts: pts))
                take.session.received(CaptureSample(kind: .audio, buffer: try toneBuffer(frequency: take.frequency, at: t, pts: pts), pts: pts))
                take.session.received(CaptureSample(kind: .microphone, buffer: try toneBuffer(frequency: 3000, at: t, pts: pts, amplitude: 0.01, channels: 1), pts: pts))
            }
            usleep(15_000)
            step += 1
        }
    }

    func hold(_ take: Take) { saver.held.insert(take.base) }

    /// Whether `take` has been closed and waits before its mix
    func isHeld(_ take: Take) async -> Bool { await wait { self.saver.gates[take.base] != nil } }

    func release(_ take: Take) {
        saver.held.remove(take.base)
        saver.gates.removeValue(forKey: take.base)?.resume()
    }

    func isFinishing(_ take: Take) -> Bool { controller.finishing.contains { $0 === take.session } }

    /// Lets the main queue and the saves run until `condition` holds; false after 20 s (a mix takes its time)
    func wait(for condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    func idle() async -> Bool { await wait { self.controller.state == .idle } }

    /// The names in the save folder
    func files() -> [String] {
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Checks that `take` is saved complete under its own name: the mixed file with one audio track of its length
    /// that holds its tone and none of `others`, its unmixed recording beside it, and no temporary file of it left
    func expectComplete(_ take: Take, seconds: Double, others: [Double]) async throws {
        let final = take.final
        expect(FileManager.default.fileExists(atPath: final.path), "\(final.lastPathComponent) is there")
        guard FileManager.default.fileExists(atPath: final.path) else { return }
        let tracks = try await TestRecording.tracks(of: final)
        expectEqual(tracks.video.count, 1, "one video track in \(final.lastPathComponent)")
        expectEqual(tracks.audio.count, 1, "one audio track in \(final.lastPathComponent)")
        expectClose(tracks.audio.first?.end ?? 0, seconds, within: 0.15, "the whole recording is in \(final.lastPathComponent)")
        let strengths = try toneStrengths(final, frequencies: [take.frequency] + others)
        func mean(_ values: [Float]) -> Float { values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count) }
        // Without the first and the last tenth of a second, where the encoder fades
        let levels = strengths.map { mean(Array($0.dropFirst(10).dropLast(10))) }
        expect(levels[0] > 0.05, "\(final.lastPathComponent) holds its own sound: \(levels)")
        for (index, other) in others.enumerated() {
            expect(levels[index + 1] < 0.005, "\(final.lastPathComponent) holds nothing of the recording with \(Int(other)) Hz: \(levels)")
        }
        let name = (take.base as NSString).lastPathComponent
        let own = files().filter { $0.hasPrefix(name + ".") || $0.hasPrefix(name + " (unmixed") }
        expectEqual(own, [name + " (unmixed, 2 audio tracks).mp4", name + ".mp4"].sorted(), "the files of \(name)")
        let unmixed = try await TestRecording.tracks(of: folder.appendingPathComponent(name + " (unmixed, 2 audio tracks).mp4"))
        expectEqual(unmixed.audio.count, 2, "the recording as it was written is kept with its two audio tracks")
    }
}

@MainActor
func instantStartTests() async {
    await test("instant start: a name taken by a recording that is not final yet is not given again") {
        let folder = try Suite.folder("instant-names")
        let store = RecordingFileStore(directory: folder.path)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = store.newBase(date: date)
        // Nothing of the first recording is in the folder yet: only the recorder knows its name
        let second = store.newBase(date: date, reserved: [first])
        expectEqual(second, first + " (2)", "the same second, another name")
        let third = store.newBase(date: date, reserved: [first, second])
        expectEqual(third, first + " (3)", "and another")
        try Data().write(to: URL(fileURLWithPath: second + ".recording.mp4"))
        expectEqual(store.newBase(date: date, reserved: [first]), first + " (3)", "names taken by files count as before")
        expectEqual(store.newBase(date: date.addingTimeInterval(1), reserved: [first, second]), RecordingFileStore.basePath(directory: folder.path, prefix: store.prefix, date: date.addingTimeInterval(1)), "another second is free")
    }

    await test("instant start: a recording starts while the one before is being mixed, and both are saved complete") {
        let rig = try LiveRig("instant-two")
        let first = try rig.start(frequency: 500)
        try rig.feed(first, seconds: 2)
        rig.hold(first)
        rig.controller.stop()
        expect(rig.controller.canStart(), "a start is possible the moment the stop was asked for")
        // Asked for at once: the first recording's capture is still being stopped
        let second = try rig.start(frequency: 1000)
        expect(rig.controller.state == .recording && rig.controller.session === second.session, "the second recording runs")
        expect(rig.isFinishing(first), "while the first is being saved")
        expect(second.base != first.base, "under a name of its own: \(second.base)")
        expectEqual(rig.controller.basesInUse, [first.base, second.base], "the recorder knows both names")
        try rig.feed(second, seconds: 1.5)
        expect(await rig.isHeld(first), "the first is closed and waits for its mix")
        expect(FileManager.default.fileExists(atPath: first.raw.path) && !FileManager.default.fileExists(atPath: first.final.path), "its recording is there, its final file not yet")
        let firstSize = (try FileManager.default.attributesOfItem(atPath: first.raw.path)[.size] as? Int) ?? 0
        try rig.feed(second, from: 1.5, seconds: 1.5)
        expectEqual(rig.saver.awake, 1, "the first keeps the Mac awake for its save")

        // The second is stopped and saved while the first still waits
        rig.controller.stop()
        expect(rig.controller.session == nil && rig.controller.finishing.count == 2, "both are being saved")
        expectEqual(rig.saver.awake, 2, "each keeps the Mac awake")
        expect(await rig.wait { !rig.isFinishing(second) }, "the second is final")
        expect(rig.isFinishing(first) && rig.controller.state == .finalizing, "the first is still being saved")
        expectEqual(rig.saver.saved, [second.final], "the second was saved, and only it")
        expectEqual(rig.saver.awake, 1, "the Mac is kept awake for the first")
        try await rig.expectComplete(second, seconds: 3, others: [500])
        expectEqual((try FileManager.default.attributesOfItem(atPath: first.raw.path)[.size] as? Int) ?? 0, firstSize, "the first recording's file was not touched")

        rig.release(first)
        expect(await rig.idle(), "idle when the first is final too")
        expectEqual(rig.saver.awake, 0, "then the Mac may sleep")
        expectEqual(rig.saver.reports, [], "nothing failed")
        try await rig.expectComplete(first, seconds: 2, others: [1000])
        expectEqual(rig.files().count, 4, "two recordings, each with its unmixed file: \(rig.files())")
    }

    await test("instant start: three recordings in a row, the earlier ones mixed while the last one runs") {
        let rig = try LiveRig("instant-three")
        let first = try rig.start(frequency: 500)
        try rig.feed(first, seconds: 1.5)
        rig.hold(first)
        rig.controller.stop()
        let second = try rig.start(frequency: 1000)
        try rig.feed(second, seconds: 2)
        rig.hold(second)
        rig.controller.stop()
        let third = try rig.start(frequency: 2000)
        expect(rig.controller.session === third.session && rig.controller.finishing.count == 2, "the third runs, two are being saved")
        expectEqual(Set([first.base, second.base, third.base]).count, 3, "three names")
        var display = StatusDisplay(rig.controller.statusInput)
        expectEqual(display.kind, .recording, "the item shows the running recording")
        expectEqual(display.saving, "Saving the 2 previous recordings", "and the menu what is being saved")
        try rig.feed(third, seconds: 1)
        expect(await rig.isHeld(first), "the first waits for its mix")
        expect(await rig.isHeld(second), "the second too")
        // Both mixes run at once while the third records
        rig.release(second)
        rig.release(first)
        try rig.feed(third, from: 1, seconds: 1.5)
        expect(await rig.wait { rig.controller.finishing.isEmpty }, "both are final")
        expect(rig.controller.state == .recording && rig.controller.session === third.session, "the third still records")
        display = StatusDisplay(rig.controller.statusInput)
        expectEqual(display.saving, nil, "nothing is being saved any more")
        rig.controller.stop()
        expect(await rig.idle(), "idle")
        expectEqual(rig.saver.reports, [], "nothing failed")
        try await rig.expectComplete(first, seconds: 1.5, others: [1000, 2000])
        try await rig.expectComplete(second, seconds: 2, others: [500, 2000])
        try await rig.expectComplete(third, seconds: 2.5, others: [500, 1000])
        expectEqual(rig.files().count, 6, "three recordings, each with its unmixed file: \(rig.files())")
    }

    await test("instant start: a mix that fails is reported for its own recording and leaves the running one alone") {
        let rig = try LiveRig("instant-failure")
        let first = try rig.start(frequency: 500)
        try rig.feed(first, seconds: 1.5)
        rig.hold(first)
        rig.saver.failing.insert(first.base)
        rig.controller.stop()
        let second = try rig.start(frequency: 1000)
        try rig.feed(second, seconds: 1)
        expect(await rig.isHeld(first), "the first waits for its mix")
        rig.release(first)
        expect(await rig.wait { !rig.isFinishing(first) }, "the first is over")
        let firstName = (first.base as NSString).lastPathComponent
        expectEqual(rig.saver.reports.count, 1, "one report")
        expect(rig.saver.reports.first?.hasPrefix("Audio Mix Failed: \(firstName) (unmixed, 2 audio tracks).mp4") == true, "which names the first recording: \(rig.saver.reports)")
        expect(rig.controller.state == .recording && rig.controller.session === second.session, "the second goes on recording")
        expect(rig.controller.health == RecordingSession.Health(), "with no warning of its own")
        expect(FileManager.default.fileExists(atPath: second.raw.path), "its file is where it was")
        try rig.feed(second, from: 1, seconds: 1)
        rig.controller.stop()
        expect(await rig.idle(), "idle")
        expectEqual(rig.saver.reports.count, 1, "the second's mix did not fail")
        try await rig.expectComplete(second, seconds: 2, others: [500])
        let secondName = (second.base as NSString).lastPathComponent
        expectEqual(rig.files(), [firstName + " (unmixed, 2 audio tracks).mp4", secondName + " (unmixed, 2 audio tracks).mp4", secondName + ".mp4"].sorted(), "the first is kept as it was recorded, under its own name")
    }

    await test("instant start: a stop reaches the running recording only, and a late failure only its own") {
        let rig = try Rig("instant-stop")
        rig.holdSave = true
        let first = try rig.start()
        rig.controller.stop()
        expect(await rig.holds(1), "the first is being saved")
        let second = try rig.start()
        expect(rig.controller.state == .recording, "the second records")
        // Whatever still reports of the first is the first's
        first.writer.fail("the first writer failed late")
        first.session.stop(earlyReason: "late")
        first.session.captureEnded(first.capture, reason: "late")
        await rig.settle()
        expect(rig.controller.state == .recording && rig.controller.session === second.session, "the second goes on")
        expectEqual(rig.journal.count("save"), 1, "and the first is not saved twice")
        rig.controller.togglePause()
        expect(rig.controller.isPaused && second.writer.isPaused && !first.writer.isPaused, "a pause is the running recording's")
        rig.controller.togglePause()
        // A report of the first one's failure says which recording it is about while the second runs
        expect(first.writer.recording.base != second.writer.recording.base, "two names, though neither has a file yet")
        let firstName = (first.writer.recording.base as NSString).lastPathComponent
        let told = rig.controller.failureMessage("Mixing the audio failed.", about: first.writer.recording)
        expectEqual(told, "This is about the earlier recording \"\(firstName)\". The recording that is running now is not affected and goes on. Mixing the audio failed.", "the report of the first one's failure")
        expectEqual(rig.controller.failureMessage("The disk is full.", about: second.writer.recording), "The disk is full.", "a report about the running recording is about it")

        rig.controller.stop()
        expect(rig.controller.session == nil, "the second is stopped")
        rig.controller.stop()
        rig.controller.stop(earlyReason: "once more")
        expect(await rig.holds(2), "both are being saved")
        expectEqual(rig.journal.count("save"), 2, "each once")
        expectEqual(rig.journal.count("capture.stop"), 2, "each capture stopped once")
        expect(rig.savedSessions.count == 2 && rig.savedSessions[0] === first.session && rig.savedSessions[1] === second.session, "each save is its own recording's")
        expect(rig.saved.allSatisfy { $0.reason == nil }, "neither is said to have ended early")
        expectEqual(rig.controller.failureMessage("Mixing the audio failed.", about: first.writer.recording), "Mixing the audio failed.", "with nothing running a report needs no such note")
        // The one stopped last may be final first
        rig.releaseOldestSave()
        expect(await rig.wait { rig.controller.finishing.count == 1 }, "one is final")
        expect(rig.controller.finishing.first === second.session && rig.controller.state == .finalizing, "the other is still being saved")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        expectEqual(rig.journal.count("idle"), 1, "idle once, when both were final")
    }

    await test("instant start: quitting waits until every recording is final, and the Mac stays awake until then") {
        let rig = try Rig("instant-quit")
        rig.holdSave = true
        try rig.start()
        rig.controller.stop()
        try rig.start()
        rig.controller.stop()
        expect(await rig.holds(2), "two are being saved")
        try rig.start()
        expectEqual(rig.awake, 2, "each recording being saved keeps the Mac awake")
        var replies = 0
        var idles = 0
        rig.controller.whenIdle { idles += 1 }
        expect(!rig.controller.canQuit { replies += 1 }, "does not quit")
        expect(rig.controller.session == nil, "the running recording is stopped")
        expectEqual(rig.controller.startRefusal, .quitting, "and none can be started")
        expect(await rig.holds(3), "three are being saved")
        expectEqual(rig.awake, 3, "and keep the Mac awake")
        rig.releaseOldestSave()
        rig.releaseOldestSave()
        expect(await rig.wait { rig.controller.finishing.count == 1 }, "two are final")
        await rig.settle()
        expectEqual(replies, 0, "no reply while one is still being saved")
        expectEqual(idles, 0, "not idle either")
        expectEqual(rig.awake, 1, "the Mac is kept awake for the last one")
        expect(StatusDisplay(rig.controller.statusInput).detail.contains("quits when this is done"), "the status item says what the app waits for")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        expectEqual(replies, 1, "one reply when all are final")
        expectEqual(idles, 1, "idle once")
        expectEqual(rig.awake, 0, "the Mac may sleep")
    }

    await test("instant start: the status item shows the running recording, the menu what is still being saved") {
        let rig = try Rig("instant-status")
        @MainActor func display() -> StatusDisplay { StatusDisplay(rig.controller.statusInput) }
        rig.holdSave = true
        let first = try rig.start(microphone: true)
        rig.controller.stop()
        expectEqual(display().kind, .saving, "nothing runs, one is being saved: Saving")
        expectEqual(display().line, "Saving the recording", "as before")
        expectEqual(display().saving, nil, "no line of its own for it")
        expect(await rig.holds(1), "the first is being saved")

        let second = try rig.start(enter: false, microphone: true)
        expectEqual(display().kind, .starting, "a start comes first")
        expectEqual(display().saving, "Saving the previous recording", "with what is being saved under it")
        second.session.enterRecording()
        expectEqual(display().kind, .recording, "then the running recording")
        expectEqual(display().line, "Recording — microphone OK", "with its own line")
        expectEqual(display().saving, "Saving the previous recording", "no percentage before the mix")
        first.session.mixProgressed(0.424)
        expectEqual(display().saving, "Saving the previous recording — 42%", "then how far the mix is")
        expectEqual(display().detail, "Recording — microphone OK. Saving the previous recording — 42%", "both in the tooltip")
        expectEqual(display().banner, nil, "nothing on screen for it")
        rig.controller.togglePause()
        expectEqual(display().kind, .paused, "paused is the running recording's")
        expectEqual(display().saving, "Saving the previous recording — 42%", "the saving goes on")
        rig.controller.togglePause()
        rig.controller.setMicrophoneMuted(true)
        expectEqual(display().kind, .muted, "so is the mute")
        rig.controller.setMicrophoneMuted(false)
        second.session.showNotice("Call audio is not being recorded")
        expectEqual(display().kind, .warning, "and a warning")
        expectEqual(display().line, "Call audio is not being recorded", "which is the running recording's line")

        rig.controller.stop()
        expect(await rig.holds(2), "both are being saved")
        expectEqual(display().kind, .saving, "nothing runs: Saving")
        expectEqual(display().line, "Saving 2 recordings — 21%", "both, the one that has not begun its mix counting as nothing")
        second.session.mixProgressed(0.8)
        expectEqual(display().line, "Saving 2 recordings — 61%", "the mean of the two")
        expect(display().detail.contains("A new recording can be started meanwhile"), "the tooltip says a start is possible")

        let third = try rig.start()
        expectEqual(display().kind, .recording, "a third runs")
        expectEqual(display().line, "Recording — no microphone", "its line is its own")
        expectEqual(display().saving, "Saving the 2 previous recordings — 61%", "two are being saved")
        rig.releaseOldestSave()
        expect(await rig.wait { rig.controller.finishing.count == 1 }, "the first is final")
        expectEqual(display().saving, "Saving the previous recording — 80%", "one left, with its own progress")
        rig.releaseSave()
        expect(await rig.wait { rig.controller.finishing.isEmpty }, "the second is final")
        expectEqual(display().kind, .recording, "the third still runs")
        expectEqual(display().saving, nil, "nothing is being saved")
        expectEqual(display().detail, "Recording — no microphone", "nor said")
        expect(rig.controller.session === third.session, "the running recording is the third")
        rig.controller.stop()
        expect(await rig.idle(), "idle")
        expectEqual(display().kind, .idle, "idle")
    }

    await test("instant start: what is being saved shows in every state of the recorder") {
        typealias Input = StatusDisplay.Input
        expectEqual(StatusDisplay(Input(state: .recording, mixProgress: 0.5, savingCount: 1)).saving, "Saving the previous recording — 50%", "while recording")
        expectEqual(StatusDisplay(Input(state: .starting, savingCount: 3)).saving, "Saving the 3 previous recordings", "while starting, several, before any mix")
        expectEqual(StatusDisplay(Input(state: .recording, isPaused: true, savingCount: 1)).saving, "Saving the previous recording", "while paused")
        let warned = StatusDisplay(Input(state: .recording, warning: "Microphone is not being recorded", onScreen: "Microphone is not being recorded", savingCount: 1))
        expectEqual(warned.kind, .warning, "a warning of the running recording stays a warning")
        expectEqual(warned.banner, "Microphone is not being recorded.", "and is shown on screen as it is")
        expectEqual(warned.saving, "Saving the previous recording", "with the saving under it")
        expectEqual(StatusDisplay(Input(state: .recording)).saving, nil, "nothing without a recording being saved")
        expectEqual(StatusDisplay(Input(state: .finalizing, savingCount: 1)).line, "Saving the recording", "one being saved, nothing running")
        expectEqual(StatusDisplay(Input(state: .finalizing, mixProgress: 0.3, savingCount: 1)).line, "Mixing the audio tracks of the recording — 30%", "its mix")
        expectEqual(StatusDisplay(Input(state: .stopping, savingCount: 2)).line, "Saving 2 recordings", "several, before any mix")
        expectEqual(StatusDisplay(Input(state: .finalizing, savingCount: 2)).title, "Saving", "one title whatever is being saved")
        expectEqual(StatusDisplay(Input(state: .finalizing, savingCount: 2, isRecovering: true)).kind, .saving, "saving comes before a recovery")
        expectEqual(StatusDisplay(Input(savingCount: 0)).kind, .idle, "idle when nothing is")
    }
}
