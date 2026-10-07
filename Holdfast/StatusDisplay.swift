//
//  StatusDisplay.swift
//  Holdfast
//

import Foundation

/// What the status item shows of the recorder: one symbol, a short title next to it and a sentence. It is worked
/// out from the recorder's state alone, so it needs no menu bar to be tested.
///
/// No state is told from another by colour only: each has a symbol of its own, and its sentence is the status
/// line of the menu and the accessibility label of the button.
struct StatusDisplay: Equatable {
    enum Kind: CaseIterable {
        case idle, starting, recording, muted, paused, warning, saving, recovering, exporting
    }

    enum Tint {
        /// The colour of the menu bar's own symbols
        case standard, red, orange
    }

    /// What of the recorder is shown. `RecorderController.statusInput` is the app's.
    struct Input {
        var state = RecordingState.idle
        var isPaused = false
        var hasMicrophone = false
        var isMicrophoneMuted = false
        /// `RecordingSession.Health.micSilent`
        var micSilent: Bool?
        var warning: String?
        /// `RecordingSession.Health.onScreen`: the part of `warning` that is also shown on screen
        var onScreen: String?
        /// `RecordingSession.Health.notice`: shown like a warning while no warning is up
        var notice: String?
        /// How far the recordings being saved are with their mix (`RecorderController.savingProgress`)
        var mixProgress: Double?
        /// How many recordings were stopped and are still being saved (`RecorderController.finishing`). With
        /// `state` starting or recording they are earlier ones, saved while the next recording runs.
        var savingCount = 0
        var isRecovering = false
        var recoveryProgress: Double?
        /// A file the user started exporting is being written
        var isExporting = false
        /// The app waits to quit until what it saves or recovers is done
        var isQuitting = false
        /// The elapsed time as text (`Timeline.lengthText`)
        var length = Timeline.lengthText(0)
    }

    let kind: Kind
    /// Next to the symbol: the elapsed time of a recording, the progress of what follows it, nothing when idle
    let title: String
    /// The status line of the menu
    let line: String
    /// The tooltip: the line, or more about it
    let detail: String
    /// While a recording starts or runs and earlier ones are still being saved: that, with how far their mix is.
    /// A line of its own in the menu, under the running recording's, which is what the item shows.
    let saving: String?
    /// The warning of a running recording that has lasted (`RecordingMonitor.announceSeconds`), or else its notice,
    /// shown on screen over every app while it is up (`WarningPanel`): a full-screen meeting hides the menu bar, and
    /// notifications may not show while the display is captured. A shorter problem is only the status item's.
    private(set) var banner: String?

    init(_ input: Input) {
        let earlier = StatusDisplay.earlier(input)
        switch input.state {
        case .starting:
            kind = .starting
            title = "Starting"
            line = "The recording is starting"
            detail = StatusDisplay.sentences(line, earlier)
            saving = earlier
        case .recording:
            title = input.length
            let microphone: String
            if !input.hasMicrophone {
                microphone = "no microphone"
            } else if input.isMicrophoneMuted {
                microphone = "microphone muted"
            } else if input.micSilent == true {
                microphone = "microphone silent"
            } else {
                microphone = "microphone OK"
            }
            if input.isPaused {
                kind = .paused
                line = "Paused" + " — " + microphone
            } else if let warning = input.warning ?? input.notice {
                kind = .warning
                line = input.isMicrophoneMuted ? warning + " — " + microphone : warning
                banner = (input.onScreen ?? input.notice).map { $0 + "." }
            } else {
                kind = input.isMicrophoneMuted ? .muted : .recording
                line = "Recording" + " — " + microphone
            }
            detail = StatusDisplay.sentences(line, earlier)
            saving = earlier
        case .stopping, .finalizing:
            kind = .saving
            // One title for the whole of it: a title that changes its length makes the item jump in the menu bar.
            // How far the mix is stands in the menu's status line.
            title = "Saving"
            if input.savingCount > 1 {
                let several = "Saving \(input.savingCount) recordings"
                line = input.mixProgress.map { StatusDisplay.percent(several, $0) } ?? several
            } else if let progress = input.mixProgress {
                line = StatusDisplay.percent("Mixing the audio tracks of the recording", progress)
            } else {
                line = "Saving the recording"
            }
            detail = line + ". " + (input.isQuitting ? "Holdfast quits when this is done." : "A new recording can be started meanwhile.")
            saving = nil
        case .idle:
            saving = nil
            if input.isRecovering {
                kind = .recovering
                title = "Recovering"
                let recovering = "Recovering a recording that was not finished"
                line = input.recoveryProgress.map { StatusDisplay.percent(recovering, $0) } ?? recovering
                detail = "A recording that an earlier run of Holdfast did not finish is being mixed. " + (input.isQuitting ? "Holdfast quits when it is done." : "Quitting waits for it.")
            } else if input.isExporting {
                kind = .exporting
                title = "Exporting"
                line = "Exporting a file"
                detail = "A file made from a recording is being written. " + (input.isQuitting ? "Holdfast quits when it is done." : "Quitting waits for it.")
            } else {
                kind = .idle
                title = ""
                line = "Ready to record"
                detail = "Holdfast"
            }
        }
    }

    /// What VoiceOver says of the button; the title next to the symbol is read after it
    var accessibilityLabel: String { "Holdfast: " + line }

    private static func percent(_ text: String, _ fraction: Double) -> String {
        return text + " — \(Int(min(1, max(0, fraction)) * 100))%"
    }

    /// "Saving the previous recording — 42%": what is still being saved of earlier recordings while one starts or
    /// runs; nil when nothing is
    private static func earlier(_ input: Input) -> String? {
        guard input.savingCount > 0 else { return nil }
        let text = input.savingCount == 1 ? "Saving the previous recording" : "Saving the \(input.savingCount) previous recordings"
        return input.mixProgress.map { percent(text, $0) } ?? text
    }

    private static func sentences(_ line: String, _ second: String?) -> String {
        return second.map { line + ". " + $0 } ?? line
    }
}

extension StatusDisplay.Kind {
    /// What the status item draws for a state
    enum Symbol: Hashable {
        /// The SF Symbol of that name
        case system(String)
        /// A ring with a dot, which the status item draws itself to the pixel
        case recordDot
    }

    var symbol: Symbol {
        switch self {
        case .idle: return .system("dot.circle.and.hand.point.up.left.fill")
        case .starting: return .system("circle.dotted")
        case .recording: return .recordDot
        case .muted: return .system("mic.slash.fill")
        case .paused: return .system("pause.circle.fill")
        case .warning: return .system("exclamationmark.triangle")
        case .saving: return .system("square.and.arrow.down")
        case .recovering: return .system("arrow.triangle.2.circlepath")
        case .exporting: return .system("square.and.arrow.up")
        }
    }

    /// The colour the symbol is drawn in
    var tint: StatusDisplay.Tint {
        switch self {
        case .recording, .muted: return .red
        case .warning: return .orange
        case .idle, .starting, .paused, .saving, .recovering, .exporting: return .standard
        }
    }

    /// The states of a recording that runs, between which it goes back and forth: the status item gives their
    /// symbols one width, so that its width and the place of the time do not change between them
    var isRunningRecording: Bool {
        switch self {
        case .recording, .muted, .paused, .warning: return true
        case .idle, .starting, .saving, .recovering, .exporting: return false
        }
    }

    /// Whether the status item keeps the width it had for `previous` when it changes to this state: only between
    /// the states of a running recording, where the time only grows. Every other state has one title of its own and
    /// gets the width it needs, so the time of a long recording leaves no space after "Saving", nor "Starting" after
    /// the time.
    func keepsWidth(after previous: StatusDisplay.Kind?) -> Bool {
        return isRunningRecording && previous?.isRunningRecording == true
    }
}

extension RecorderController {
    /// What the status item shows of the recorder now
    var statusInput: StatusDisplay.Input {
        // The warnings are the running recording's; the progress is that of the recordings being saved
        return StatusDisplay.Input(state: state, isPaused: isPaused, hasMicrophone: session?.hasMicrophone ?? false,
                                   isMicrophoneMuted: isMicrophoneMuted, micSilent: health.micSilent, warning: health.warning, onScreen: health.onScreen, notice: health.notice,
                                   mixProgress: savingProgress, savingCount: finishing.count, isRecovering: recovery.isRunning,
                                   recoveryProgress: recovery.progress, isExporting: exportsRunning > 0, isQuitting: quitRequested,
                                   length: recordingLength())
    }
}
