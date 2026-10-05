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
        var mixProgress: Double?
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

    init(_ input: Input) {
        switch input.state {
        case .starting:
            kind = .starting
            title = "Starting".local
            line = "The recording is starting".local
            detail = line
        case .recording:
            title = input.length
            let microphone: String
            if !input.hasMicrophone {
                microphone = "no microphone".local
            } else if input.isMicrophoneMuted {
                microphone = "microphone muted".local
            } else if input.micSilent == true {
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
            // One title for the whole of it: a title that changes its length makes the item jump in the menu bar.
            // How far the mix is stands in the menu's status line.
            title = "Saving".local
            if let progress = input.mixProgress {
                line = StatusDisplay.percent("Mixing the audio tracks of the recording".local, progress)
            } else {
                line = "Saving the recording".local
            }
            detail = line + ". " + (input.isQuitting ? "Holdfast quits when this is done." : "A new one can be started when this is done.")
        case .idle:
            if input.isRecovering {
                kind = .recovering
                title = "Recovering".local
                let recovering = "Recovering a recording that was not finished".local
                line = input.recoveryProgress.map { StatusDisplay.percent(recovering, $0) } ?? recovering
                detail = "A recording that an earlier run of Holdfast did not finish is being mixed. " + (input.isQuitting ? "Holdfast quits when it is done." : "Quitting waits for it.")
            } else if input.isExporting {
                kind = .exporting
                title = "Exporting".local
                line = "Exporting a file".local
                detail = "A file made from a recording is being written. " + (input.isQuitting ? "Holdfast quits when it is done." : "Quitting waits for it.")
            } else {
                kind = .idle
                title = ""
                line = "Ready to record".local
                detail = "Holdfast"
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
        case .exporting: return "square.and.arrow.up"
        }
    }

    var tint: Tint {
        switch kind {
        case .recording, .muted: return .red
        case .warning: return .orange
        case .idle, .starting, .paused, .saving, .recovering, .exporting: return .standard
        }
    }

    /// What VoiceOver says of the button; the title next to the symbol is read after it
    var accessibilityLabel: String { "Holdfast: " + line }

    private static func percent(_ text: String, _ fraction: Double) -> String {
        return text + " — \(Int(min(1, max(0, fraction)) * 100))%"
    }
}

extension RecorderController {
    /// What the status item shows of the recorder now
    var statusInput: StatusDisplay.Input {
        return StatusDisplay.Input(state: state, isPaused: isPaused, hasMicrophone: session?.hasMicrophone ?? false,
                                   isMicrophoneMuted: isMicrophoneMuted, micSilent: health.micSilent, warning: health.warning,
                                   mixProgress: health.mixProgress, isRecovering: recovery.isRunning,
                                   recoveryProgress: recovery.progress, isExporting: exportsRunning > 0, isQuitting: quitRequested,
                                   length: recordingLength())
    }
}
