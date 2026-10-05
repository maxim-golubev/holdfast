//
//  StatusDisplay.swift
//  QuickRecorder
//

import Foundation

/// What the status item shows of the recorder: one symbol, a short title next to it and a sentence. It is worked
/// out from the recorder's state alone, so it needs no menu bar to be tested.
///
/// No state is told from another by colour only: each has a symbol of its own, and its sentence is the status
/// line of the menu and the accessibility label of the button.
struct StatusDisplay: Equatable {
    enum Kind: CaseIterable {
        case idle, starting, recording, muted, paused, warning, saving, recovering
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
        /// `RecordingSession.Health.micLevel`
        var micLevel: Int?
        var warning: String?
        var mixProgress: Double?
        var isRecovering = false
        var recoveryProgress: Double?
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

    init(_ input: Input) {
        switch input.state {
        case .starting:
            kind = .starting
            title = "Starting…".local
            line = "The recording is starting".local
            detail = line
        case .recording:
            title = input.length
            let microphone: String
            if !input.hasMicrophone {
                microphone = "no microphone".local
            } else if input.isMicrophoneMuted {
                microphone = "microphone muted".local
            } else if input.micLevel == 0 {
                microphone = "microphone silent".local
            } else {
                microphone = "microphone OK".local
            }
            if input.isPaused {
                kind = .paused
                line = "Paused".local + " — " + microphone
            } else if let warning = input.warning {
                kind = .warning
                line = input.isMicrophoneMuted ? warning + " — " + microphone : warning
            } else {
                kind = input.isMicrophoneMuted ? .muted : .recording
                line = "Recording".local + " — " + microphone
            }
            detail = line
        case .stopping, .finalizing:
            kind = .saving
            if let progress = input.mixProgress {
                title = StatusDisplay.percent("Finishing…".local, progress)
                line = "Mixing the audio tracks of the recording".local
            } else {
                title = "Saving…".local
                line = "Saving the recording".local
            }
            detail = line + ". " + "A new one can be started when this is done.".local
        case .idle:
            if input.isRecovering {
                kind = .recovering
                title = input.recoveryProgress.map { StatusDisplay.percent("Recovering…".local, $0) } ?? "Recovering…".local
                line = "Recovering a recording that was not finished".local
                detail = "A recording that an earlier run of QuickRecorder did not finish is being mixed. Quitting waits for it.".local
            } else {
                kind = .idle
                title = ""
                line = "Ready to record".local
                detail = "QuickRecorder"
            }
        }
    }

    /// The SF Symbol of the state
    var symbol: String {
        switch kind {
        case .idle: return "dot.circle.and.hand.point.up.left.fill"
        case .starting: return "circle.dotted"
        case .recording: return "record.circle"
        case .muted: return "mic.slash.fill"
        case .paused: return "pause.circle.fill"
        case .warning: return "exclamationmark.triangle"
        case .saving: return "square.and.arrow.down"
        case .recovering: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Tint {
        switch kind {
        case .recording, .muted: return .red
        case .warning: return .orange
        case .idle, .starting, .paused, .saving, .recovering: return .standard
        }
    }

    /// What VoiceOver says of the button; the title next to the symbol is read after it
    var accessibilityLabel: String { "QuickRecorder: " + line }

    private static func percent(_ text: String, _ fraction: Double) -> String {
        return text + " \(Int(min(1, max(0, fraction)) * 100))%"
    }
}

extension RecorderController {
    /// What the status item shows of the recorder now
    var statusInput: StatusDisplay.Input {
        return StatusDisplay.Input(state: state, isPaused: isPaused, hasMicrophone: session?.hasMicrophone ?? false,
                                   isMicrophoneMuted: isMicrophoneMuted, micLevel: health.micLevel, warning: health.warning,
                                   mixProgress: health.mixProgress, isRecovering: recovery.isRunning,
                                   recoveryProgress: recovery.progress, length: recordingLength())
    }
}
