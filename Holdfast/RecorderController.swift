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
    /// A start was asked for while the previous recording is still being saved, or while the app waits to quit
    var startRefused: @MainActor (StartRefusal) -> Void = { _ in }
    /// A start was refused or did not lead to a recording: what a selector left on screen goes
    var startAbandoned: @MainActor () -> Void = {}
    /// The recording is being stopped: what it had on screen goes
    var tearDown: @MainActor () -> Void = {}
    /// Closes what the writer left and post-processes it; returns when the files are final. The arguments after
    /// the recording: what the writer handed over, why it ended early if it did, whether it was a cancelled start.
    var save: @MainActor (RecordingSession, RecordingContext, MovieWriter.Finished, String?, Bool) async -> Void = { _, _, _, _, _ in }
    /// Title and text of a notification of the watchdog. Sample queue.
    var notify: (String, String) -> Void = { _, _ in }
    /// A frame to save as a picture, and the folder of the recording when it is known. Sample queue.
    var savePicture: (CMSampleBuffer, String?) -> Void = { _, _ in }
    /// Title and text of the report of the launch recovery
    var report: @MainActor (String, String) -> Void = { _, _ in }
    /// Runs the handler once every alert that reports a failure has been dismissed
    var whenAlertsDismissed: @MainActor (@escaping () -> Void) -> Void = { $0() }
}

/// Why a start was refused with an alert
enum StartRefusal {
    case saving, quitting
}

/// The one way into the recording side for the UI, the hotkeys, the script commands, the auto-stop timer, the
/// abort paths and quitting. It holds the current `RecordingSession`, or none while idle; whatever belongs to one
/// recording is in that session and goes with it.
@MainActor
final class RecorderController {
    /// The one queue all stream outputs are delivered on, on which every session's writer and monitor live
    let queue: DispatchQueue
    let environment: RecorderEnvironment
    let recovery = RecordingRecovery()
    /// From an accepted start until that recording's files are final
    private(set) var session: RecordingSession?
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

    var state: RecordingState { session?.state ?? .idle }
    /// Whether a stopped recording is still being closed or post-processed
    var isSaving: Bool { state == .stopping || state == .finalizing }
    /// What is being recorded, from the start until the stop
    var streamType: StreamType? {
        guard let session = session, session.state == .starting || session.state == .recording else { return nil }
        return session.streamType
    }
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

    /// Whether a recording can be started now. While the previous one is still being saved, or the app waits to
    /// quit, the user is told so: a quit that is waiting would end the new recording when it goes ahead.
    func canStart() -> Bool {
        if state == .starting || state == .recording { return false }
        if quitRequested {
            environment.startRefused(.quitting)
            return false
        }
        if state != .idle {
            environment.startRefused(.saving)
            return false
        }
        return true
    }

    /// idle → starting: the only way into a recording. Nil when one is starting, running or still being saved; a
    /// second recording cannot be started until the first one's files are final.
    /// `autoStop` (minutes, 0 for none) belongs to the recording being started, like everything else in the session.
    func begin(_ streamType: StreamType, autoStop: Int = 0) -> RecordingSession? {
        guard canStart() else {
            // A selector's dashed frame must not stay behind. While a recording is starting or running the frame
            // on screen may be that recording's, so it is left alone.
            if state != .starting && state != .recording { environment.startAbandoned() }
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

    /// Stops the current recording (`RecordingSession.stop`). Does nothing when there is none.
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
        guard let session = session, streamType != nil, session.autoStopIsDue() else { return }
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
    /// running is stopped, no new one can be started (`canStart`), and `reply` is called, once, when its files are
    /// final, a recording of an earlier run that is being mixed is done too, so are the exports, and the report of
    /// any failure has been seen.
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

    private func stateChanged(of changed: RecordingSession, from old: RecordingState) {
        guard changed === session else { return }
        print("Recording state: \(old) -> \(changed.state)")
        if changed.state == .idle { session = nil }
        environment.statusChanged(self)
        guard state == .idle else { return }
        let handlers = idleHandlers
        idleHandlers = []
        handlers.forEach { $0() }
    }

    private func statusChanged(of changed: RecordingSession) {
        guard changed === session else { return }
        environment.statusChanged(self)
    }
}
