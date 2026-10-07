//
//  RecorderController.swift
//  Holdfast
//

import AVFoundation
import Foundation

/// What a recording needs from the app around it: the status bar, the windows, alerts and notifications, and the
/// work on the finished file. The app's is `RecorderEnvironment.app`; the tests use their own.
struct RecorderEnvironment {
    /// Something the status item shows has changed: the state, the recovery, a request to quit, pause, mute,
    /// warning, microphone level, progress
    var statusChanged: @MainActor (RecorderController) -> Void = { _ in }
    /// A start was asked for while the app waits to quit (`.quitting`)
    var startRefused: @MainActor (StartRefusal) -> Void = { _ in }
    /// A start was refused or did not lead to a recording: what a selector left on screen goes
    var startAbandoned: @MainActor () -> Void = {}
    /// The recording is being stopped: what it had on screen goes
    var tearDown: @MainActor () -> Void = {}
    /// Keeps the Mac from sleeping until the closure it returns is called: each recording holds one of its own
    /// from its stop until its files are final
    var keepAwake: @MainActor () -> (@MainActor () -> Void) = { {} }
    /// Closes what the writer left and post-processes it; returns when the files are final. The arguments after
    /// the recording: what the writer handed over, why it ended early if it did, whether it was a cancelled start.
    var save: @MainActor (RecordingSession, RecordingContext, MovieWriter.Finished, String?, Bool) async -> Void = { _, _, _, _, _ in }
    /// Title and text of a notification of the watchdog. Sample queue.
    var notify: (String, String) -> Void = { _, _ in }
    /// A frame with pixels of its own to save as a picture, and the folder of the recording when it is known.
    /// Called on the sample queue, so it must not encode or write there.
    var savePicture: (CMSampleBuffer, String?) -> Void = { _, _ in }
    /// Title and text of the report of the launch recovery
    var report: @MainActor (String, String) -> Void = { _, _ in }
    /// Runs the handler once every alert that reports a failure has been dismissed
    var whenAlertsDismissed: @MainActor (@escaping () -> Void) -> Void = { $0() }
}

/// Why a recording cannot be started now (`RecorderController.startRefusal`)
enum StartRefusal {
    /// One is starting or running. Nothing offers a start then, so `canStart` says nothing.
    case recording
    /// The app waits to quit: `canStart` tells the user (`startRefused`)
    case quitting
}

/// The one way into the recording side for the UI, the hotkeys, the script commands, the auto-stop timer, the
/// abort paths and quitting. It holds the `RecordingSession` that is starting or running, if any, and those that
/// were stopped and are still being saved (`finishing`); whatever belongs to one recording is in its session and
/// goes with it. A recording that was stopped goes on closing and mixing by itself: it holds up no start, and
/// nothing asked of the recorder from then on reaches it.
@MainActor
final class RecorderController {
    /// The one queue all stream outputs are delivered on, on which every session's writer and monitor live
    let queue: DispatchQueue
    let environment: RecorderEnvironment
    let recovery = RecordingRecovery()
    /// The recording that is starting or running: from an accepted start until its stop is carried out
    private(set) var session: RecordingSession?
    /// The recordings that were stopped and whose files are not final yet, oldest first
    private(set) var finishing = [RecordingSession]()
    /// Set when the app was asked to quit and is waiting for its files to be final
    private(set) var quitRequested = false
    private var idleHandlers = [() -> Void]()
    /// Files the user is exporting (a `.qma` player's Export, a trimmed clip), which quitting waits for
    private(set) var exportsRunning = 0
    private var exportHandlers = [() -> Void]()

    init(queue: DispatchQueue, environment: RecorderEnvironment) {
        self.queue = queue
        self.environment = environment
        recovery.runningChanged = { [unowned self] in environment.statusChanged(self) }
        recovery.progressChanged = { [unowned self] in environment.statusChanged(self) }
        recovery.report = environment.report
    }

    // MARK: - State

    /// The state of the recording that is starting or running; without one, that of the recording stopped last
    /// while any is still being saved; idle only when nothing is recorded or saved
    var state: RecordingState { session?.state ?? finishing.last?.state ?? .idle }
    /// Whether a stopped recording is still being closed or post-processed
    var isSaving: Bool { !finishing.isEmpty }
    /// How far the recordings being saved are with their mix, from 0 to 1: of one, its own; of several, their
    /// mean, one that has not begun counting as 0. Nil while none is being mixed.
    var savingProgress: Double? {
        let known = finishing.compactMap { $0.health.mixProgress }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(finishing.count)
    }
    /// The paths, without extension, of the final files of every recording that is not final yet: a recording
    /// that starts gets none of these names
    var basesInUse: Set<String> {
        return Set(([session].compactMap { $0 } + finishing).compactMap { $0.recording?.base })
    }
    /// What to tell the user about a failure of `recording`, which was stopped and is being saved: `message`, and
    /// while another recording is starting or running, first that it is about the earlier one. A report that comes
    /// up during a meeting must not read as if the recording that runs had failed or stopped.
    func failureMessage(_ message: String, about recording: RecordingContext) -> String {
        guard let running = session, running.recording?.base != recording.base else { return message }
        let name = (recording.base as NSString).lastPathComponent
        return String(format: "This is about the earlier recording \"%@\". The recording that is running now is not affected and goes on.", name) + " " + message
    }

    /// What is being recorded, from the start until the stop
    var streamType: StreamType? { session?.streamType }
    /// Whether the stream of a recording exists, which is what the UI means by "recording"
    var hasStream: Bool { session?.capture != nil }
    var isPaused: Bool { session?.isPaused ?? false }
    var isMagnifierEnabled: Bool { session?.isMagnifierEnabled ?? false }
    var isMicrophoneMuted: Bool { session?.isMicrophoneMuted ?? false }
    /// Whether a recording runs that has a microphone track, which can be muted
    var canMuteMicrophone: Bool { state == .recording && (session?.hasMicrophone ?? false) }
    var health: RecordingSession.Health { session?.health ?? RecordingSession.Health() }

    /// The text of the status-bar timer
    func recordingLength() -> String {
        return session?.lengthText() ?? Timeline.lengthText(0)
    }

    // MARK: - Start

    /// Why a recording cannot be started now, nil when it can. Says nothing to the user: `canStart` does.
    var startRefusal: StartRefusal? {
        if session != nil { return .recording }
        // A quit that is waiting would end the new recording when it goes ahead
        if quitRequested { return .quitting }
        return nil
    }

    /// Whether a recording can be started now: always, unless one is starting or running or the app waits to quit
    /// (the user is then told so). Recordings that are still being saved hold up nothing.
    func canStart() -> Bool {
        guard let refusal = startRefusal else { return true }
        if refusal != .recording { environment.startRefused(refusal) }
        return false
    }

    /// → starting: the only way into a recording. Nil when one is starting or running, or the app waits to quit.
    /// Earlier recordings that are still being closed, mixed or converted do not matter: each is a session of its
    /// own with its own files, and the new one starts at once.
    /// `autoStop` (minutes, 0 for none) belongs to the recording being started, like everything else in the session.
    func begin(_ streamType: StreamType, autoStop: Int = 0) -> RecordingSession? {
        guard canStart() else {
            // A selector's dashed frame must not stay behind. While a recording is starting or running the frame
            // on screen may be that recording's, so it is left alone.
            if session == nil { environment.startAbandoned() }
            return nil
        }
        let session = RecordingSession(streamType: streamType, autoStop: autoStop, queue: queue, environment: environment,
                                       stateChanged: { [weak self] session, old in self?.stateChanged(of: session, from: old) },
                                       statusChanged: { [weak self] session in self?.statusChanged(of: session) })
        self.session = session
        stateChanged(of: session, from: .idle)
        return session
    }

    // MARK: - While it runs

    /// Stops the recording that is starting or running (`RecordingSession.stop`), and only that one: a recording
    /// that is already being saved is not touched. Does nothing when there is none.
    func stop(earlyReason: String? = nil) {
        session?.stop(earlyReason: earlyReason)
    }

    func togglePause() {
        session?.togglePause()
    }

    /// Mutes or unmutes the microphone track of the running recording. False when there is none to mute.
    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) -> Bool {
        return session?.setMicrophoneMuted(muted) ?? false
    }

    func toggleMicrophoneMute() {
        setMicrophoneMuted(!isMicrophoneMuted)
    }

    /// Called by the status item's timer: stops the recording when it has run for the minutes it was started with
    func stopIfDue() {
        guard let session = session, session.autoStopIsDue() else { return }
        session.stop()
    }

    // MARK: - Idle and quit

    /// Runs `handler` once nothing is being recorded or saved any more; at once when that is so now.
    func whenIdle(_ handler: @escaping () -> Void) {
        if state == .idle { handler() } else { idleHandlers.append(handler) }
    }

    /// An export the user started is being written: quitting waits for it. Each call is ended by one `exportEnded`.
    func exportStarted() {
        exportsRunning += 1
        environment.statusChanged(self)
    }

    /// The export is over, whatever came of it. What it has to tell the user is reported before this is called:
    /// a quit that waits for it goes ahead at once.
    func exportEnded() {
        exportsRunning = max(0, exportsRunning - 1)
        environment.statusChanged(self)
        guard exportsRunning == 0 else { return }
        let handlers = exportHandlers
        exportHandlers = []
        handlers.forEach { $0() }
    }

    private func whenExportsDone(_ handler: @escaping () -> Void) {
        if exportsRunning == 0 { handler() } else { exportHandlers.append(handler) }
    }

    /// Nothing is being recorded, saved, recovered or exported: quitting cuts nothing off
    private var isQuiet: Bool { state == .idle && !recovery.isRunning && exportsRunning == 0 }

    /// For `applicationShouldTerminate`. True when the app can quit now. Otherwise a recording that is starting or
    /// running is stopped, no new one can be started (`canStart`), and `reply` is called, once, when the files of
    /// every recording are final, a recording of an earlier run that is being mixed is done too, so are the
    /// exports, and the report of any failure has been seen.
    func canQuit(orReply reply: @escaping () -> Void) -> Bool {
        if isQuiet { return true }
        stop()
        if !quitRequested {
            quitRequested = true
            environment.statusChanged(self)
            replyWhenDone(reply)
        }
        return false
    }

    /// Calls `reply` once idle, the recovery and the exports done and the alerts dismissed, all at the same time:
    /// checked again at the end, since the waits follow each other and the reply ends whatever runs then.
    private func replyWhenDone(_ reply: @escaping () -> Void) {
        whenIdle { [self] in
            recovery.whenDone { [self] in
                whenExportsDone { [self] in
                    environment.whenAlertsDismissed { [self] in
                        if isQuiet { reply() } else { replyWhenDone(reply) }
                    }
                }
            }
        }
    }

    private func owns(_ session: RecordingSession) -> Bool {
        return session === self.session || finishing.contains { $0 === session }
    }

    /// A session of this recorder has changed its state. One that is being stopped leaves `session` for
    /// `finishing` at that moment, so the next recording can start; one that is idle is dropped.
    private func stateChanged(of changed: RecordingSession, from old: RecordingState) {
        guard owns(changed) else { return }
        print("Recording state: \(old) -> \(changed.state)\(finishing.isEmpty ? "" : " (\(finishing.count) being saved)")")
        switch changed.state {
        case .starting, .recording:
            break
        case .stopping, .finalizing:
            if changed === session {
                session = nil
                finishing.append(changed)
            }
        case .idle:
            if changed === session { session = nil }
            finishing.removeAll { $0 === changed }
        }
        environment.statusChanged(self)
        guard state == .idle else { return }
        let handlers = idleHandlers
        idleHandlers = []
        handlers.forEach { $0() }
    }

    private func statusChanged(of changed: RecordingSession) {
        guard owns(changed) else { return }
        environment.statusChanged(self)
    }
}
