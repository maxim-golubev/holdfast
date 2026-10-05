//
//  RecorderController.swift
//  QuickRecorder
//

import AVFoundation
import Foundation

/// What a recording needs from the app around it: the status bar, the windows, alerts and notifications, and the
/// work on the finished file. The app's is `RecorderEnvironment.app`; the tests use their own.
struct RecorderEnvironment {
    /// The state changed, the recovery began or ended, or quitting was asked for: the status item is built anew
    var refreshStatusItem: @MainActor () -> Void = {}
    /// Something else the status bar shows has changed (pause, warning, microphone level, progress)
    var statusChanged: @MainActor (RecorderController) -> Void = { _ in }
    var becameIdle: @MainActor () -> Void = {}
    /// A start was asked for while the previous recording is still being saved
    var startRefused: @MainActor () -> Void = {}
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

    init(queue: DispatchQueue, environment: RecorderEnvironment) {
        self.queue = queue
        self.environment = environment
        recovery.runningChanged = { environment.refreshStatusItem() }
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
    var health: RecordingSession.Health { session?.health ?? RecordingSession.Health() }
    /// Whether the status item shows the "Recovering…" pill: always while quitting waits for the recovery, so the
    /// app does not look hung, and otherwise only where it does not take the place of the menu bar icon, from which
    /// a recording can be started meanwhile.
    var showsRecovery: Bool { recovery.isRunning && (quitRequested || !AppSettings.showMenubar) }

    /// The text of the status-bar timer
    func recordingLength() -> String {
        return session?.lengthText() ?? Timeline.lengthText(0)
    }

    // MARK: - Start

    /// Whether a recording can be started now. While the previous one is still being saved the user is told so.
    func canStart() -> Bool {
        switch state {
        case .idle:
            return true
        case .starting, .recording:
            return false
        case .stopping, .finalizing:
            environment.startRefused()
            return false
        }
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

    /// Called by the status-bar timer: stops the recording when it has run for the minutes it was started with
    func stopIfDue(at now: Date) {
        guard let session = session, streamType != nil, session.autoStopIsDue(at: now) else { return }
        session.stop()
    }

    // MARK: - Idle and quit

    /// Runs `handler` once nothing is being recorded or saved any more; at once when that is so now.
    func whenIdle(_ handler: @escaping () -> Void) {
        if state == .idle { handler() } else { idleHandlers.append(handler) }
    }

    /// For `applicationShouldTerminate`. True when the app can quit now. Otherwise a recording that is starting or
    /// running is stopped, and `reply` is called, once, when its files are final, a recording of an earlier run
    /// that is being mixed is done too, and the report of any failure has been seen.
    func canQuit(orReply reply: @escaping () -> Void) -> Bool {
        if state == .idle && !recovery.isRunning { return true }
        stop()
        if !quitRequested {
            quitRequested = true
            // The pill says "Recovering…" while a recording of an earlier run keeps the app from quitting
            environment.refreshStatusItem()
            whenIdle { [self] in
                recovery.whenDone { [self] in
                    environment.whenAlertsDismissed(reply)
                }
            }
        }
        return false
    }

    private func stateChanged(of changed: RecordingSession, from old: RecordingState) {
        guard changed === session else { return }
        print("Recording state: \(old) -> \(changed.state)")
        if changed.state == .idle { session = nil }
        environment.statusChanged(self)
        environment.refreshStatusItem()
        guard state == .idle else { return }
        environment.becameIdle()
        let handlers = idleHandlers
        idleHandlers = []
        handlers.forEach { $0() }
    }

    private func statusChanged(of changed: RecordingSession) {
        guard changed === session else { return }
        environment.statusChanged(self)
    }
}
