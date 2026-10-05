//
//  RecordingSession.swift
//  Holdfast
//

import AVFoundation
import Foundation

/// Where a recording is. `RecorderController.state` is `idle` while there is none.
enum RecordingState {
    case idle
    /// From the request to start until the capture runs
    case starting
    case recording
    /// The capture is being stopped and the writer's inputs are being finished
    case stopping
    /// The file is being closed and post-processed (audio mix, MP3 conversion)
    case finalizing
}

enum StreamType: Int { case screen, window, windows, application, screenarea, systemaudio }

/// The capture of a recording as its session uses it (`CaptureSource`). Main thread.
protocol RecordingCapture: AnyObject {
    /// `done` is called, on any thread, when no more buffers are delivered
    func stop(_ done: @escaping (Error?) -> Void)
    /// Gives up a stream that was never started or has stopped by itself
    func releaseStream()
}

/// The writer of a recording as its session and its monitor use it (`MovieWriter`). Sample queue.
protocol RecordingWriter: AnyObject {
    var recording: RecordingContext { get }
    var events: MovieWriter.Events { get set }
    var isCapturing: Bool { get }
    var isPaused: Bool { get }
    var isResume: Bool { get }
    var sessionStart: CMTime? { get }
    var clockAnchor: (raw: CMTime, uptime: UInt64)? { get }
    var audioEndPTS: CMTime? { get }
    var hasSystemAudio: Bool { get }
    var hasMicrophoneTrack: Bool { get }
    var isMicrophoneMuted: Bool { get }
    func startCapturing()
    func togglePause() -> Bool
    func setMicrophoneMuted(_ muted: Bool)
    func write(_ sample: CaptureSample)
    func checkWriter() -> Bool
    func timelineTime(_ raw: CMTime) -> CMTime
    func fillMicrophone(upTo time: CMTime)
    func fillSystemAudio(upTo time: CMTime)
    func repeatVideoFrame(at now: CMTime)
    func finish() -> MovieWriter.Finished
    func cancel()
}

extension MovieWriter: RecordingWriter {}

/// One recording, from the request to start it until its files are final: its `RecordingContext`, its capture, its
/// writer, its `RecordingMonitor` and what the status bar shows about it. `RecorderController` makes one for every
/// start and drops it when it is idle again, so the next recording begins with nothing of this one.
///
/// It lives on two threads, and each member belongs to one of them. The `@MainActor` members are the state machine
/// and what the UI reads. The writer and the monitor belong to the sample queue, the queue the capture delivers
/// its buffers on: they are only reached through `queueWriter` and the monitor's own methods, which trap anywhere
/// else, except on the path of a delivered buffer (`received`), which only assumes the queue. From the main thread the queue is entered with `queue.sync`; the queue never waits for the main thread.
/// That discipline, not the compiler, is what makes it safe to hand a session from one thread to the other.
final class RecordingSession: @unchecked Sendable {
    /// What the status bar shows about the recording besides its state
    struct Health: Equatable {
        /// Set while a track is not being recorded
        var warning: String?
        /// Nil without a microphone track; true while it delivers nothing or digital silence
        var micSilent: Bool?
        /// From 0 to 1 while the audio tracks are being mixed
        var mixProgress: Double?
    }

    private struct PendingStop {
        let reason: String?
    }

    let queue: DispatchQueue
    /// Minutes after which the recording stops by itself, 0 for never
    let autoStop: Int
    private let environment: RecorderEnvironment
    private let monitor: RecordingMonitor

    // MARK: - Main thread

    /// Only changed by `enterRecording`, `abandonStart` and `stop`
    @MainActor private(set) var state = RecordingState.starting {
        didSet {
            guard state != oldValue else { return }
            if state != .finalizing { health.mixProgress = nil }
            stateChanged(self, oldValue)
        }
    }
    /// What is recorded. Several windows of which one is left are recorded as a window.
    @MainActor var streamType: StreamType
    /// The files and settings, from the moment the writer is installed
    @MainActor private(set) var recording: RecordingContext?
    /// From the moment the stream exists until it is stopped
    @MainActor private(set) var capture: RecordingCapture?
    @MainActor private(set) var isPaused = false
    /// Every recording starts with its microphone on: a mute is this recording's and goes with it
    @MainActor private(set) var isMicrophoneMuted = false
    @MainActor private(set) var health = Health()
    /// Set when the disk watch found the recording's file deleted: there is nothing to save or to look for
    @MainActor var filesDeleted = false
    @MainActor var isMagnifierEnabled = false
    /// The wall clock of the status-bar timer and of the automatic stop, moved on by the time spent paused. It gates nothing.
    @MainActor private var startTime: Date?
    /// While paused: the time recorded up to the pause
    @MainActor private var timePassed: TimeInterval = 0
    /// A stop that was asked for while the capture was still starting, with its reason
    @MainActor private var pendingStop: PendingStop?
    /// When the capture began to run. A stop right after it that recorded nothing is a cancelled start, not a failure.
    @MainActor private var enteredRecording: Date?
    /// What was set up for the running recording and is undone when it is stopped
    @MainActor private var undo = [@MainActor () -> Void]()
    private let stateChanged: @MainActor (RecordingSession, RecordingState) -> Void
    private let statusChanged: @MainActor (RecordingSession) -> Void

    // MARK: - Sample queue

    private var writer: RecordingWriter?
    private var wantsPicture = false

    /// The writer, from `install` until the stop takes it or the start is abandoned. Sample queue only.
    private var queueWriter: RecordingWriter? {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return writer
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            writer = newValue
        }
    }

    /// `stateChanged` gets the state before the change; `statusChanged` is called when anything else the status bar
    /// shows has changed.
    @MainActor
    init(streamType: StreamType, autoStop: Int, queue: DispatchQueue, environment: RecorderEnvironment,
         stateChanged: @escaping @MainActor (RecordingSession, RecordingState) -> Void,
         statusChanged: @escaping @MainActor (RecordingSession) -> Void) {
        self.streamType = streamType
        self.autoStop = max(0, autoStop)
        self.queue = queue
        self.environment = environment
        self.stateChanged = stateChanged
        self.statusChanged = statusChanged
        monitor = RecordingMonitor(queue: queue)
        monitor.notify = environment.notify
        monitor.show = { [weak self] warning, silent in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.health.warning = warning
                self.health.micSilent = silent
                self.statusChanged(self)
            }
        }
    }

    // MARK: - Start

    /// Gives the session its writer, before any file exists: a recording that never gets as far as creating its
    /// file is stopped with a writer that has none and reports that nothing was saved.
    @MainActor
    func install(_ writer: RecordingWriter) {
        guard state == .starting, recording == nil else { return }
        recording = writer.recording
        writer.events.failed = { [weak self] reason in
            // On the sample queue. This session's stop: a late failure cannot stop the recording after it.
            DispatchQueue.main.async { self?.stop(earlyReason: reason) }
        }
        writer.events.sessionStarted = { [weak self] in
            let now = Date.now
            DispatchQueue.main.async { self?.startTime = now }
        }
        writer.events.microphoneWritten = { [monitor] end, peak in monitor.microphoneWritten(upTo: end, peak: peak) }
        writer.events.systemAudioWritten = { [monitor] end in monitor.systemAudioWritten(upTo: end) }
        queue.sync { queueWriter = writer }
    }

    @MainActor
    func attach(_ capture: RecordingCapture) {
        self.capture = capture
    }

    /// From here on the writer takes buffers. Just before the capture is started; not on the sample queue.
    func startCapturing() {
        queue.sync { queueWriter?.startCapturing() }
    }

    /// Once the capture runs: from here on the tracks are kept going and watched whether or not their sources
    /// deliver anything. Not on the sample queue.
    func startMonitor() {
        queue.sync {
            if let writer = queueWriter { monitor.start(writer) }
        }
    }

    /// starting → recording, once the capture runs. `setUp` prepares what belongs to a running recording first.
    /// A stop that was asked for in the meantime is carried out now, after everything it undoes has been set up.
    @MainActor
    func enterRecording(_ setUp: @MainActor () -> Void = {}) {
        guard state == .starting else { return }
        setUp()
        enteredRecording = Date.now
        state = .recording
        if let stop = pendingStop {
            pendingStop = nil
            self.stop(earlyReason: stop.reason)
        }
    }

    /// Registers what `stop` undoes first
    @MainActor
    func whenStopped(_ action: @escaping @MainActor () -> Void) {
        undo.append(action)
    }

    /// starting → idle, for a start that did not lead to a recording: the writer and the file it created, the
    /// stream and what a selector left on screen go. A recording that is starting cannot be stopped (a stop is put
    /// off until the capture runs), so nothing else is taking it apart.
    @MainActor
    func abandonStart() {
        guard state == .starting else { return }
        var discarded: RecordingWriter?
        queue.sync {
            discarded = queueWriter
            queueWriter = nil
            monitor.stop()
        }
        // Nothing was recorded: the writer deletes the empty file or package it created, and only that
        discarded?.cancel()
        capture?.releaseStream()
        capture = nil
        startTime = nil
        pendingStop = nil
        environment.startAbandoned()
        state = .idle
    }

    // MARK: - While it runs

    /// On the sample queue: a buffer of the capture. The writer puts it on the timeline and into its track.
    func received(_ sample: CaptureSample) {
        // Read directly: nothing on the path of a delivered buffer traps, it trusts ScreenCaptureKit to deliver
        // on the queue it was given
        let writer = self.writer
        if wantsPicture, sample.buffer.imageBuffer != nil {
            wantsPicture = false
            environment.savePicture(sample.buffer, writer?.recording.saveDirectory)
        }
        writer?.write(sample)
    }

    /// The next frame is also saved as a picture
    @MainActor
    func savePicture() {
        queue.async { self.wantsPicture = true }
    }

    /// Pauses the running recording, or resumes it. Like the mute, only in the `recording` state: not while the
    /// capture is still starting or the writer is being finished.
    @MainActor
    func togglePause() {
        guard state == .recording else { return }
        let paused: Bool? = queue.sync {
            guard let writer = queueWriter else { return nil }
            monitor.pauseToggled()
            return writer.togglePause()
        }
        guard let paused = paused else { return }
        // The writer takes the pause out of the file exactly, so the timer stands still and goes on from there
        if paused { timePassed = elapsed() } else { startTime = Date.now - timePassed }
        isPaused = paused
        statusChanged(self)
    }

    /// Whether the recording has a microphone track
    @MainActor var hasMicrophone: Bool { recording?.recordMic ?? false }

    /// Mutes the microphone track of the running recording (silence in place of the microphone, see
    /// `MovieWriter.setMicrophoneMuted`) or gives it its audio back. False when there is nothing to mute: no
    /// recording that runs, or one without a microphone track. What is shown and returned is what the writer
    /// did, not what it was asked for.
    @MainActor
    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) -> Bool {
        guard state == .recording, hasMicrophone else { return false }
        let done: Bool = queue.sync {
            guard let writer = queueWriter else { return false }
            writer.setMicrophoneMuted(muted)
            return writer.isMicrophoneMuted == muted
        }
        guard done else { return false }
        if isMicrophoneMuted != muted {
            isMicrophoneMuted = muted
            statusChanged(self)
        }
        return true
    }

    /// The stream ended without having been asked to. Any thread. `reason` is nil when the user stopped it from
    /// the system's screen sharing menu, which is a stop like any other; otherwise the file is closed and the user
    /// is told that the recording is shorter than expected.
    func captureEnded(_ ended: RecordingCapture, reason: String?) {
        DispatchQueue.main.async {
            // Not a stream that is already being stopped
            guard self.capture === ended else { return }
            // While the capture is still starting the stream stays where it is: either its start fails and the
            // start is abandoned, or the stop below is carried out once it runs
            if self.state != .starting {
                self.capture = nil
                ended.releaseStream()
            }
            self.stop(earlyReason: reason)
        }
    }

    /// The seconds recorded so far as the status item counts them: from the writer's session start, without the
    /// time spent paused
    @MainActor
    func elapsed() -> TimeInterval {
        if isPaused { return timePassed }
        return startTime.map { Date.now.timeIntervalSince($0) } ?? 0
    }

    /// "07:05" up to an hour, "1:07:05" from then on
    @MainActor
    func lengthText() -> String {
        return Timeline.lengthText(elapsed())
    }

    /// Whether the recording has run for its `autoStop` minutes: the time the status item shows, so never while
    /// paused, and time spent paused does not count
    @MainActor
    func autoStopIsDue() -> Bool {
        guard autoStop != 0, !isPaused, startTime != nil else { return false }
        return elapsed() / 60 >= Double(autoStop)
    }

    /// From the audio mix, while the recording is being finalized
    @MainActor
    func mixProgressed(_ fraction: Double) {
        guard state == .finalizing else { return }
        health.mixProgress = fraction
        statusChanged(self)
    }

    // MARK: - Stop

    /// The one way a recording ends: the Stop buttons, the hotkey, the script command, the auto-stop timer, an
    /// error (`MovieWriter.fail`, the disk guard, a stream that stopped) and quitting all come here.
    /// Returns at once; the recording is closed and post-processed in the background, and the state is idle when
    /// its files are final. Only a recording in the `recording` state is stopped: a stop while the capture is still
    /// starting is carried out as soon as it runs, and any other call is ignored, so repeated stops are harmless.
    /// `earlyReason` says why the recording ends without the user having stopped it; the user is told so.
    @MainActor
    func stop(earlyReason: String? = nil) {
        switch state {
        case .idle, .stopping, .finalizing:
            return
        case .starting:
            if pendingStop == nil { pendingStop = PendingStop(reason: earlyReason) }
            return
        case .recording:
            break
        }
        guard let recording = recording else {
            // Cannot happen: a recording in this state has its context. Without one there is nothing to close.
            state = .idle
            return
        }
        // Stopped by the user within moments of the start: when nothing was recorded by then, that is a cancelled start
        let cancelled = earlyReason == nil && Date.now.timeIntervalSince(enteredRecording ?? .distantPast) < 3
        state = .stopping
        isMagnifierEnabled = false
        let actions = undo
        undo = []
        actions.forEach { $0() }
        environment.tearDown()
        isPaused = false
        startTime = nil
        // Nil when the stream stopped by itself
        let capture = self.capture
        self.capture = nil
        statusChanged(self)

        Task { @MainActor in
            // Buffers that arrive while the capture is being stopped are still recorded
            if let capture = capture { await stopCapture(capture) }
            let finished = await takeWriter()
            state = .finalizing
            // Works from `recording` and what the writer handed over, not from settings
            await environment.save(self, recording, finished, earlyReason, cancelled)
            state = .idle
        }
    }

    /// Returns when the stream has stopped delivering buffers. A stream that does not answer is given 5 seconds;
    /// what it delivers after that is ignored, because the recording is no longer capturing by then.
    @MainActor
    private func stopCapture(_ capture: RecordingCapture) async {
        await completion { done in
            capture.stop { error in
                if let error = error { print("Stopping the capture: \(error.localizedDescription)") }
                done()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { done() }
        }
    }

    /// After the capture has stopped. The writer leaves the session on the sample queue, and its inputs are marked
    /// as finished on the queue the buffers are appended on, so no append can run alongside or after that.
    @MainActor
    private func takeWriter() async -> MovieWriter.Finished {
        return await withCheckedContinuation { (continuation: CheckedContinuation<MovieWriter.Finished, Never>) in
            queue.async {
                self.monitor.stop()
                let taken = self.queueWriter
                self.queueWriter = nil
                // Cannot be missing: a recording that is being stopped has its writer, which may have no file
                continuation.resume(returning: taken?.finish() ?? MovieWriter.Finished(writer: nil, frame: nil, sessionStarted: false))
            }
        }
    }
}

/// Suspends until `body` calls the closure it is given, on any thread. Calls after the first do nothing.
/// `body` itself runs on the main thread, like the caller: what it starts may build windows (the preview, the
/// audio player of the mix). Work that takes time has to leave the main thread inside `body`.
@MainActor
func completion(of body: @escaping (@escaping () -> Void) -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let lock = NSLock()
        var done = false
        body {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { continuation.resume() }
        }
    }
}
