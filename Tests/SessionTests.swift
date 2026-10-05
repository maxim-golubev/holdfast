//
//  SessionTests.swift
//  The state machine of a recording (RecorderController, RecordingSession) with a capture and a writer that
//  record nothing.
//

import AVFoundation
import Foundation

/// What happened, in order, whichever thread it happened on
final class Journal {
    private let lock = NSLock()
    private var entries = [String]()
    func note(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
    func count(_ entry: String) -> Int { all.filter { $0 == entry }.count }
}

final class FakeCapture: RecordingCapture {
    private let journal: Journal
    /// While set, `stop` does not answer until `answer()`
    var holdsStop = false
    private var waiting: ((Error?) -> Void)?
    init(_ journal: Journal) { self.journal = journal }

    func stop(_ done: @escaping (Error?) -> Void) {
        journal.note("capture.stop")
        if holdsStop { waiting = done } else { DispatchQueue.global().async { done(nil) } }
    }
    func answer() {
        waiting?(nil)
        waiting = nil
    }
    func releaseStream() { journal.note("capture.release") }
}

/// Traps when the session uses it anywhere but on the sample queue
final class FakeWriter: RecordingWriter {
    let recording: RecordingContext
    var events = MovieWriter.Events()
    private let queue: DispatchQueue
    private let journal: Journal
    private(set) var isCapturing = false
    private(set) var isPaused = false
    private(set) var written = 0
    private(set) var isMicrophoneMuted = false
    let isResume = false
    /// Set by a test of the monitor, which does nothing before the writer's session has started
    var sessionStart: CMTime?
    var clockAnchor: (raw: CMTime, uptime: UInt64)?
    let audioEndPTS: CMTime? = nil
    let hasSystemAudio = false
    var hasMicrophoneTrack: Bool { recording.recordMic }

    init(_ journal: Journal, queue: DispatchQueue, folder: URL, microphone: Bool = false) {
        self.journal = journal
        self.queue = queue
        recording = RecordingContext(audioOnly: false, recordMic: microphone, fastStart: false, saveDirectory: folder.path)
    }

    private func onQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    func startCapturing() { onQueue(); isCapturing = true; journal.note("writer.start") }
    func togglePause() -> Bool { onQueue(); isPaused.toggle(); return isPaused }
    /// A writer whose microphone track cannot be muted (the real one without a converter)
    var refusesMute = false
    func setMicrophoneMuted(_ muted: Bool) {
        onQueue()
        guard !refusesMute else { return }
        isMicrophoneMuted = muted
        journal.note(muted ? "writer.mute" : "writer.unmute")
    }
    func write(_ sample: CaptureSample) { onQueue(); written += 1 }
    func checkWriter() -> Bool { onQueue(); return true }
    func timelineTime(_ raw: CMTime) -> CMTime { onQueue(); return raw }
    func fillMicrophone(upTo time: CMTime) { onQueue() }
    func fillSystemAudio(upTo time: CMTime) { onQueue() }
    func repeatVideoFrame(at now: CMTime) { onQueue() }
    func finish() -> MovieWriter.Finished {
        onQueue()
        isCapturing = false
        journal.note("writer.finish")
        return MovieWriter.Finished(writer: nil, frame: nil, sessionStarted: true)
    }
    func cancel() { isCapturing = false; journal.note("writer.cancel") }
    /// What `MovieWriter.fail` does
    func fail(_ reason: String) { queue.sync { isCapturing = false; events.failed(reason) } }
}

/// A recorder whose surroundings only take notes. `holdSave` keeps a stopped recording in `finalizing` until `releaseSave()`.
@MainActor
final class Rig {
    /// What the app's save is told and when it returns
    @MainActor
    final class Saves {
        var hold = false
        var waiting: CheckedContinuation<Void, Never>?
        /// Why the recording ended early, and whether it was a cancelled start
        var all = [(reason: String?, cancelled: Bool)]()
    }

    let journal = Journal()
    let queue = DispatchQueue(label: "HoldfastTests.samples")
    let folder: URL
    let controller: RecorderController
    private let saves = Saves()
    var holdSave: Bool {
        get { saves.hold }
        set { saves.hold = newValue }
    }
    var saved: [(reason: String?, cancelled: Bool)] { saves.all }

    init(_ name: String) throws {
        folder = try Suite.folder(name)
        var environment = RecorderEnvironment()
        environment.startRefused = { [journal] reason in journal.note(reason == .quitting ? "refused: quitting" : "refused") }
        environment.startAbandoned = { [journal] in journal.note("abandoned") }
        environment.tearDown = { [journal] in journal.note("tearDown") }
        var wasIdle = true
        environment.statusChanged = { [journal] recorder in
            let isIdle = recorder.state == .idle
            if isIdle && !wasIdle { journal.note("idle") }
            wasIdle = isIdle
        }
        environment.save = { [journal, saves] session, _, _, reason, cancelled in
            journal.note("save")
            saves.all.append((reason, cancelled))
            expect(session.state == .finalizing, "the file is closed in the finalizing state")
            if saves.hold { await withCheckedContinuation { saves.waiting = $0 } }
        }
        controller = RecorderController(queue: queue, environment: environment)
    }

    func releaseSave() {
        saves.hold = false
        saves.waiting?.resume()
        saves.waiting = nil
    }

    /// What the app does between an accepted start and the running capture
    @discardableResult
    func start(autoStop: Int = 0, enter: Bool = true, microphone: Bool = false) throws -> (session: RecordingSession, capture: FakeCapture, writer: FakeWriter) {
        let session = try require(controller.begin(.screen, autoStop: autoStop), "an accepted start")
        let writer = FakeWriter(journal, queue: queue, folder: folder, microphone: microphone)
        session.install(writer)
        let capture = FakeCapture(journal)
        session.attach(capture)
        session.startCapturing()
        session.startMonitor()
        if enter { session.enterRecording { [journal] in journal.note("setUp") } }
        return (session, capture, writer)
    }

    /// Lets the main queue and the session's tasks run until `condition` holds; false after 3 s
    func wait(for condition: @MainActor () -> Bool) async -> Bool {
        return await waitUntil(condition)
    }

    func idle() async -> Bool { await wait { self.controller.state == .idle } }
    /// Long enough for anything that was wrongly set off to show
    func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
}

/// Lets the main queue and the queues of the code under test run until `condition` holds; false after 3 s
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

@MainActor
func sessionTests() async {
    await test("session: a recording passes through every state in order") {
        let rig = try Rig("session-order")
        expect(rig.controller.state == .idle, "idle before the first start")
        expect(rig.controller.canStart(), "a start is possible when idle")
        let session = try require(rig.controller.begin(.screen), "an accepted start")
        expect(rig.controller.state == .starting, "starting once the start is accepted")
        expect(rig.controller.streamType == .screen, "the UI is told what is being recorded")
        expect(!rig.controller.hasStream, "no stream yet")
        let writer = FakeWriter(rig.journal, queue: rig.queue, folder: rig.folder)
        session.install(writer)
        let capture = FakeCapture(rig.journal)
        capture.holdsStop = true
        session.attach(capture)
        expect(rig.controller.hasStream, "the stream exists")
        session.startCapturing()
        session.startMonitor()
        session.enterRecording()
        expect(rig.controller.state == .recording, "recording once the capture runs")
        let sample = CaptureSample(kind: .audio, buffer: try audioBuffer(rate: 48000, channels: 2, frames: 480, at: time(1)), pts: time(1))
        rig.queue.sync { session.received(sample) }
        expectEqual(writer.written, 1, "a buffer of the capture reaches the writer")

        rig.holdSave = true
        rig.controller.stop()
        expect(rig.controller.state == .stopping, "stopping at once")
        expect(rig.controller.isSaving, "the UI shows that the recording is being saved")
        expect(rig.controller.streamType == nil && !rig.controller.hasStream, "the recording pill is gone")
        await rig.settle()
        expect(rig.controller.state == .stopping, "the writer is not touched before the capture has stopped")
        expectEqual(rig.journal.count("writer.finish"), 0, "the inputs are not finished before the capture has stopped")
        capture.answer()
        expect(await rig.wait { rig.controller.state == .finalizing }, "finalizing once the inputs are finished")
        expect(!rig.controller.canStart(), "no start while the file is being saved")
        rig.releaseSave()
        expect(await rig.idle(), "idle when the files are final")
        expectEqual(rig.journal.all, ["writer.start", "tearDown", "capture.stop", "writer.finish", "save", "refused", "idle"], "order of a recording's end")
        expect(rig.controller.session == nil, "nothing of the recording is left")
    }

    await test("session: the next recording starts with nothing of the one before") {
        let rig = try Rig("session-clean")
        let first = try rig.start(autoStop: 7)
        first.session.togglePause()
        first.session.isMagnifierEnabled = true
        expect(rig.controller.isPaused, "paused")
        expectEqual(first.session.autoStop, 7, "its own stop time")
        rig.controller.stop()
        expect(await rig.idle(), "the first recording ends")
        let second = try rig.start()
        expect(second.session !== first.session, "a session of its own")
        expect(!rig.controller.isPaused, "not paused")
        expectEqual(second.session.autoStop, 0, "no stop time of the recording before")
        expect(!second.session.isMagnifierEnabled, "no magnifier of the recording before")
        expect(rig.controller.health == RecordingSession.Health(), "no warning of the recording before")
        // The writer of the first recording fails late: that is not this recording's failure
        first.writer.fail("the first writer failed late")
        first.session.stop(earlyReason: "late")
        first.session.captureEnded(first.capture, reason: "late")
        await rig.settle()
        expect(rig.controller.state == .recording, "the second recording goes on")
        rig.controller.stop()
        expect(await rig.idle(), "the second recording ends")
        expectEqual(rig.saved.count, 2, "each was saved once")
    }

    await test("session: a stop during starting is carried out once the capture runs") {
        let rig = try Rig("session-stop-starting")
        let (session, _, _) = try rig.start(enter: false)
        rig.controller.stop()
        rig.controller.stop(earlyReason: "a second stop while starting")
        await rig.settle()
        expect(rig.controller.state == .starting, "still starting")
        expectEqual(rig.journal.count("capture.stop"), 0, "the capture is not stopped while it starts")
        session.enterRecording { rig.journal.note("setUp") }
        expect(rig.controller.state == .stopping, "stopped as soon as the capture runs")
        expect(await rig.idle(), "idle in the end")
        expectEqual(rig.journal.all, ["writer.start", "setUp", "tearDown", "capture.stop", "writer.finish", "save", "idle"], "what the stop undoes was set up first")
        expect(rig.saved.first?.reason == nil, "the first stop asked for counts")
        expect(rig.saved.first?.cancelled == true, "stopped by the user within moments of the start")
    }

    await test("session: repeated stops close the recording once") {
        let rig = try Rig("session-repeated")
        let (session, capture, _) = try rig.start()
        capture.holdsStop = true
        rig.holdSave = true
        rig.controller.stop()
        rig.controller.stop()
        session.stop()
        expect(await rig.wait { rig.journal.count("capture.stop") == 1 }, "the capture is asked to stop")
        capture.answer()
        expect(await rig.wait { rig.controller.state == .finalizing }, "finalizing")
        rig.controller.stop()
        session.stop(earlyReason: "too late")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        rig.controller.stop()
        await rig.settle()
        for entry in ["tearDown", "capture.stop", "writer.finish", "save", "idle"] {
            expectEqual(rig.journal.count(entry), 1, entry)
        }
        expect(rig.controller.state == .idle, "a stop when idle does nothing")
    }

    await test("session: a failure while stopping does not stop twice") {
        let rig = try Rig("session-abort")
        let (session, capture, writer) = try rig.start()
        capture.holdsStop = true
        rig.controller.stop()
        // The disk guard, the writer and the stream all report while the capture is being stopped
        session.stop(earlyReason: "The disk is almost full")
        writer.fail("The recording could not be written")
        session.captureEnded(capture, reason: "The screen capture stopped")
        await rig.settle()
        expect(rig.controller.state == .stopping, "still waiting for the capture")
        capture.answer()
        expect(await rig.idle(), "idle")
        for entry in ["tearDown", "capture.stop", "writer.finish", "save"] {
            expectEqual(rig.journal.count(entry), 1, entry)
        }
        expectEqual(rig.journal.count("capture.release"), 0, "the stream that is being stopped is not given up a second time")
        expect(rig.saved.first?.reason == nil, "the stop that was carried out was the user's")
    }

    await test("session: a failing writer and a stream that ends stop the recording with the reason") {
        let rig = try Rig("session-early")
        let first = try rig.start()
        first.writer.fail("The recording could not be written: disk full")
        expect(await rig.idle(), "idle after the writer failed")
        expectEqual(rig.saved.last?.reason, "The recording could not be written: disk full", "the reason reaches the report")
        expect(rig.saved.last?.cancelled == false, "an early end is not a cancelled start")

        let second = try rig.start()
        second.session.captureEnded(second.capture, reason: "The screen capture stopped")
        expect(await rig.idle(), "idle after the stream ended")
        expectEqual(rig.saved.last?.reason, "The screen capture stopped", "the reason reaches the report")
        expectEqual(rig.journal.count("capture.release"), 1, "the stream that ended is given up")
        expectEqual(rig.journal.count("capture.stop"), 1, "and not stopped again (the one stop is the first recording's)")
    }

    await test("session: a start is refused until the previous recording is final") {
        let rig = try Rig("session-refused")
        try rig.start()
        expect(rig.controller.begin(.window) == nil, "no second start while recording")
        expectEqual(rig.journal.count("refused") + rig.journal.count("abandoned"), 0, "and what is on screen is the running recording's")
        rig.holdSave = true
        rig.controller.stop()
        expect(rig.controller.begin(.window) == nil, "no start while stopping")
        expect(await rig.wait { rig.controller.state == .finalizing }, "finalizing")
        let finishing = rig.controller.session
        expect(rig.controller.begin(.window) == nil, "no start while finalizing")
        expect(rig.controller.session === finishing && rig.controller.state == .finalizing, "the recording being saved is not disturbed")
        expectEqual(rig.journal.count("refused"), 2, "the user is told each time")
        expectEqual(rig.journal.count("abandoned"), 2, "and the selector's frame goes")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        let next = rig.controller.begin(.window)
        expect(next != nil && rig.controller.state == .starting, "a start is accepted again")
        expect(rig.controller.streamType == .window, "with its own kind")
    }

    await test("session: an abandoned start leaves nothing behind") {
        let rig = try Rig("session-abandoned")
        let bare = try require(rig.controller.begin(.screen), "an accepted start")
        bare.abandonStart()
        expect(rig.controller.state == .idle && rig.controller.session == nil, "idle after a start that failed before its writer")
        let (session, _, _) = try rig.start(enter: false)
        rig.controller.stop()
        session.abandonStart()
        expect(rig.controller.state == .idle, "idle after a start that failed with its writer")
        expectEqual(rig.journal.all, ["abandoned", "idle", "writer.start", "writer.cancel", "capture.release", "abandoned", "idle"], "the writer and the stream are discarded")
        session.enterRecording()
        session.stop()
        await rig.settle()
        expect(rig.controller.state == .idle, "an abandoned start cannot be entered or stopped")
        expectEqual(rig.journal.count("save"), 0, "nothing is saved for it")
        try rig.start()
        expect(rig.controller.state == .recording, "the stop asked of the abandoned start does not reach the next recording")
        rig.controller.stop()
        expect(await rig.idle(), "idle")
    }

    await test("session: quitting waits until the recording is final") {
        let rig = try Rig("session-quit")
        var replies = 0
        expect(rig.controller.canQuit { replies += 1 }, "quits at once when idle")
        expect(!rig.controller.quitRequested, "nothing to wait for")

        try rig.start()
        rig.holdSave = true
        expect(!rig.controller.canQuit { replies += 1 }, "does not quit while recording")
        expect(rig.controller.state == .stopping, "the recording is stopped instead")
        expect(await rig.wait { rig.controller.state == .finalizing }, "finalizing")
        expect(!rig.controller.canQuit { replies += 1 }, "does not quit while finalizing")
        await rig.settle()
        expectEqual(replies, 0, "no reply before the files are final")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        expectEqual(replies, 1, "one reply once idle, however often quitting was asked for")
        expectEqual(rig.journal.count("save"), 1, "saved once")
    }

    await test("session: no recording starts while a quit waits, and the quit goes ahead only when idle") {
        let rig = try Rig("session-quit-pending")
        try rig.start()
        rig.holdSave = true
        var replies = 0
        expect(!rig.controller.canQuit { replies += 1 }, "does not quit while recording")
        expect(await rig.wait { rig.controller.state == .finalizing }, "finalizing")
        expect(!rig.controller.canStart(), "no start while quitting")
        expectEqual(rig.journal.count("refused: quitting"), 1, "the user is told why")
        expect(StatusDisplay(rig.controller.statusInput).detail.contains("quits"), "the status item says the app will quit")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        expectEqual(replies, 1, "the quit goes ahead")
        expect(rig.controller.begin(.screen) == nil, "and nothing can be started before it does")
        expectEqual(rig.controller.state, .idle, "still idle")
    }

    await test("session: quitting while starting stops the recording when it runs, then replies") {
        let rig = try Rig("session-quit-starting")
        var replied = false
        let (session, _, _) = try rig.start(enter: false)
        expect(!rig.controller.canQuit { replied = true }, "does not quit while starting")
        expect(rig.controller.state == .starting, "the start goes on")
        session.enterRecording()
        expect(await rig.idle(), "stopped and saved")
        expect(replied, "then the app quits")
        expectEqual(rig.journal.count("save"), 1, "with its file")
    }

    await test("session: pause and the timer belong to the recording") {
        let rig = try Rig("session-pause")
        expectEqual(rig.controller.recordingLength(), "00:00", "no recording, no time")
        let (session, _, writer) = try rig.start()
        rig.controller.togglePause()
        expect(rig.controller.isPaused && writer.isPaused, "paused")
        rig.controller.togglePause()
        expect(!rig.controller.isPaused && !writer.isPaused, "resumed")
        expect(!session.autoStopIsDue(), "no automatic stop without a stop time")
        rig.controller.stop()
        expect(await rig.idle(), "idle")
        rig.controller.togglePause()
        expect(!rig.controller.isPaused, "nothing to pause when idle")
        let (starting, _, startingWriter) = try rig.start(enter: false)
        rig.controller.togglePause()
        expect(!rig.controller.isPaused && !startingWriter.isPaused, "no pause while the capture is still starting")
        starting.abandonStart()
    }

    await test("session: pausing and resuming neither moves the timer nor the automatic stop") {
        let rig = try Rig("session-pause-time")
        let (session, _, writer) = try rig.start(autoStop: 1)
        expectEqual(session.elapsed(), 0, "no time before the writer's session starts")
        writer.events.sessionStarted()
        expect(await rig.wait { session.elapsed() > 0.2 }, "the timer runs from the session's start")
        rig.controller.togglePause()
        let paused = session.elapsed()
        await rig.settle()
        expectEqual(session.elapsed(), paused, "it stands still while paused")
        expect(!session.autoStopIsDue(), "no automatic stop while paused")
        rig.controller.togglePause()
        expectClose(session.elapsed(), paused, within: 0.05, "and goes on from where it stood, with nothing added")
        for _ in 0..<5 {
            rig.controller.togglePause()
            rig.controller.togglePause()
        }
        expectClose(session.elapsed(), paused, within: 0.05, "however often it is paused")
        rig.controller.stop()
        expect(await rig.idle(), "idle")
    }

    await test("session: the microphone is muted for one recording, and only one that has a microphone") {
        let rig = try Rig("session-mute")
        expect(!rig.controller.setMicrophoneMuted(true), "nothing to mute when idle")
        let plain = try rig.start()
        expect(!rig.controller.canMuteMicrophone, "a recording without a microphone track has nothing to mute")
        expect(!rig.controller.setMicrophoneMuted(true) && !plain.writer.isMicrophoneMuted, "and is not muted")
        rig.controller.stop()
        expect(await rig.idle(), "idle")

        let (session, _, writer) = try rig.start(enter: false, microphone: true)
        expect(!rig.controller.setMicrophoneMuted(true), "not while the recording is still starting")
        session.enterRecording()
        expect(rig.controller.canMuteMicrophone && !rig.controller.isMicrophoneMuted, "a recording starts with its microphone on")
        expect(rig.controller.setMicrophoneMuted(true), "muted")
        expect(rig.controller.isMicrophoneMuted && writer.isMicrophoneMuted, "the writer is told on its queue")
        expect(rig.controller.setMicrophoneMuted(true), "muting twice is no error")
        rig.controller.toggleMicrophoneMute()
        expect(!rig.controller.isMicrophoneMuted && !writer.isMicrophoneMuted, "unmuted")
        rig.controller.toggleMicrophoneMute()
        expect(rig.controller.isMicrophoneMuted, "muted again")
        expect(rig.controller.state == .recording, "the recording goes on meanwhile")
        rig.controller.toggleMicrophoneMute()
        writer.refusesMute = true
        expect(!rig.controller.setMicrophoneMuted(true), "a mute the writer did not apply is not reported as done")
        expect(!rig.controller.isMicrophoneMuted, "and not shown")
        expect(rig.controller.setMicrophoneMuted(false), "unmuting what is not muted is no error")
        writer.refusesMute = false
        expect(rig.controller.setMicrophoneMuted(true), "muted once more")
        rig.controller.stop()
        expect(!rig.controller.setMicrophoneMuted(false), "nothing to change once the recording is stopped")
        expect(await rig.idle(), "idle")
        expect(!rig.controller.isMicrophoneMuted, "the mute went with its recording")
        let next = try rig.start(microphone: true)
        expect(!rig.controller.isMicrophoneMuted && !next.writer.isMicrophoneMuted, "the next recording has its microphone on")
        rig.controller.stop()
        expect(await rig.idle(), "idle")
    }

    await test("monitor: a muted microphone raises no warning, and takes down one that was up without calling it back") {
        let journal = Journal()
        let queue = DispatchQueue(label: "HoldfastTests.monitor")
        let writer = FakeWriter(journal, queue: queue, folder: try Suite.folder("monitor-mute"), microphone: true)
        let monitor = RecordingMonitor(queue: queue)
        let shown = Journal()
        monitor.notify = { title, _ in journal.note("notify: " + title) }
        monitor.show = { warning, level in shown.note("\(warning ?? "none") \(level.map(String.init) ?? "-")") }
        // A session that started 100 s ago, from whose microphone nothing was ever written
        writer.sessionStart = time(0)
        writer.clockAnchor = (time(100), DispatchTime.now().uptimeNanoseconds)
        queue.sync {
            writer.startCapturing()
            monitor.start(writer)
        }
        expect(await waitUntil { journal.count("notify: Microphone Is Not Being Recorded") == 1 }, "a microphone that delivers nothing is reported")
        expectEqual(shown.all.last, "Microphone is not being recorded 0", "and shown")
        queue.sync { writer.setMicrophoneMuted(true) }
        expect(await waitUntil { shown.all.last == "none 0" }, "muted: the warning goes")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        expectEqual(journal.all.filter { $0.hasPrefix("notify") }, ["notify: Microphone Is Not Being Recorded"], "nothing is reported while muted, and no \"Microphone Is Back\"")
        queue.sync { writer.setMicrophoneMuted(false) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        expectEqual(journal.all.filter { $0.hasPrefix("notify") }.count, 1, "the time muted does not count towards a warning after it")
        expectEqual(shown.all.last, "none 0", "no warning right after the mute")
        queue.sync { monitor.stop() }
    }
}
