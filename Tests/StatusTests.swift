//
//  StatusTests.swift
//  What the status item shows for each state of the recorder (StatusDisplay)
//

import AppKit
import Foundation

@MainActor
func statusTests() async {
    typealias Input = StatusDisplay.Input
    typealias Kind = StatusDisplay.Kind

    await test("status: every state has a symbol of its own that this system has") {
        let symbols = Kind.allCases.map { kind -> Kind.Symbol in
            // One input that leads to each kind
            var input = Input()
            switch kind {
            case .idle: break
            case .starting: input.state = .starting
            case .recording: input.state = .recording
            case .muted: input.state = .recording; input.hasMicrophone = true; input.isMicrophoneMuted = true
            case .paused: input.state = .recording; input.isPaused = true
            case .warning: input.state = .recording; input.warning = "Microphone is not being recorded"
            case .saving: input.state = .finalizing
            case .recovering: input.isRecovering = true
            case .exporting: input.isExporting = true
            }
            let display = StatusDisplay(input)
            expect(display.kind == kind, "\(kind) is shown as \(display.kind)")
            if case .system(let name) = display.kind.symbol {
                expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "no symbol named \(name)")
            }
            expect(!display.line.isEmpty && !display.detail.isEmpty, "\(kind) has a status line and a tooltip")
            expect(display.accessibilityLabel.contains(display.line), "\(kind) is spoken with its status line")
            return display.kind.symbol
        }
        expectEqual(Set(symbols).count, Kind.allCases.count, "no two states differ by colour alone")
        expectEqual(Kind.allCases.filter { $0.symbol == .recordDot }, [.recording], "the drawn record dot is a running recording's")
        expectEqual(Kind.allCases.filter { $0.isRunningRecording }, [.recording, .muted, .paused, .warning], "the states a running recording goes between")
        let lines = Set([Input(state: .recording), Input(state: .recording, isPaused: true), Input(state: .stopping), Input(state: .starting), Input()].map { StatusDisplay($0).line })
        expectEqual(lines.count, 5, "nor by their words")
    }

    await test("status: a recording shows its time, its microphone and its warning") {
        var input = Input(state: .recording, hasMicrophone: true, micSilent: false, length: "12:34")
        var display = StatusDisplay(input)
        expectEqual(display.kind, .recording, "recording")
        expectEqual(display.title, "12:34", "the elapsed time next to the symbol")
        expectEqual(display.line, "Recording — microphone OK", "status line")
        expect(display.kind.symbol == .recordDot && display.kind.tint == .red, "the red dot")

        input.length = "1:07:05"
        expectEqual(StatusDisplay(input).title, "1:07:05", "hours from the first hour")
        input.micSilent = true
        expectEqual(StatusDisplay(input).line, "Recording — microphone silent", "nothing from the microphone right now")
        input.hasMicrophone = false
        expectEqual(StatusDisplay(input).line, "Recording — no microphone", "a recording without a microphone track says so")

        input.hasMicrophone = true
        input.isMicrophoneMuted = true
        display = StatusDisplay(input)
        expectEqual(display.kind, .muted, "muted")
        expectEqual(display.kind.symbol, .system("mic.slash.fill"), "the muted microphone")
        expectEqual(display.line, "Recording — microphone muted", "status line when muted")
        expectEqual(display.title, "1:07:05", "the time goes on")

        input.warning = "System audio is not being recorded"
        display = StatusDisplay(input)
        expectEqual(display.kind, .warning, "a warning comes before the mute")
        expect(display.kind.tint == .orange, "orange")
        expectEqual(display.line, "System audio is not being recorded — microphone muted", "the warning is the status line, and the mute is not forgotten")
        expectEqual(display.detail, display.line, "and the tooltip")
        expectEqual(display.title, "1:07:05", "with the time")
        expectEqual(display.banner, "System audio is not being recorded.", "and is shown on screen over every app")
        input.isMicrophoneMuted = false
        expectEqual(StatusDisplay(input).line, "System audio is not being recorded", "the warning alone")

        input.isPaused = true
        input.micSilent = false
        display = StatusDisplay(input)
        expectEqual(display.kind, .paused, "paused comes first: nothing is being recorded on purpose")
        expectEqual(display.line, "Paused — microphone OK", "status line when paused")
        expect(display.kind.tint == .standard, "not the colour of a running recording")
        expectEqual(display.banner, nil, "nor is a warning shown on screen while nothing is being recorded on purpose")
        for state in [RecordingState.idle, .starting, .stopping, .finalizing] {
            expectEqual(StatusDisplay(Input(state: state, warning: "Microphone is not being recorded")).banner, nil, "no warning on screen when \(state)")
        }
        expectEqual(StatusDisplay(Input(state: .recording)).banner, nil, "nor without a warning")
    }

    await test("status: a recording without call audio shows it like a warning, under the track warnings") {
        var input = Input(state: .recording, hasMicrophone: true, micSilent: false, notice: "Call audio is not being recorded", length: "0:05")
        var display = StatusDisplay(input)
        expectEqual(display.kind, .warning, "a warning")
        expectEqual(display.line, "Call audio is not being recorded", "in the status line")
        expectEqual(display.banner, "Call audio is not being recorded.", "and on screen over every app")
        input.warning = "Microphone is not being recorded"
        display = StatusDisplay(input)
        expectEqual(display.line, "Microphone is not being recorded", "a track warning comes first")
        expectEqual(display.banner, "Microphone is not being recorded.", "also on screen")
        input.warning = nil
        input.isMicrophoneMuted = true
        expectEqual(StatusDisplay(input).line, "Call audio is not being recorded — microphone muted", "the mute is not forgotten")
        input.isPaused = true
        expectEqual(StatusDisplay(input).banner, nil, "nothing on screen while paused")
        expectEqual(StatusDisplay(Input(state: .starting, notice: "Call audio is not being recorded")).banner, nil, "nor while starting")
    }

    await test("status: saving, finishing and recovering show how far they are") {
        var display = StatusDisplay(Input(state: .stopping))
        expectEqual(display.kind, .saving, "saving from the stop on")
        expectEqual(display.title, "Saving", "one title while saving")
        expectEqual(display.line, "Saving the recording", "no percentage before the mix")
        display = StatusDisplay(Input(state: .finalizing, mixProgress: 0.424))
        expectEqual(display.title, "Saving", "the title does not change its length during the mix")
        expectEqual(display.line, "Mixing the audio tracks of the recording — 42%", "the mix in percent, in the status line")
        expect(display.detail.contains("A new one can be started"), "the tooltip says what to wait for")
        expect(StatusDisplay(Input(state: .finalizing, mixProgress: 1.7)).line.hasSuffix("100%"), "never more than all of it")

        display = StatusDisplay(Input(isRecovering: true))
        expectEqual(display.title, "Recovering", "recovery before its first progress")
        display = StatusDisplay(Input(isRecovering: true, recoveryProgress: 0.5))
        expectEqual(display.title, "Recovering", "the title does not change its length during the recovery")
        expect(display.line.hasSuffix("50%"), "recovery in percent, in the status line")
        expectEqual(StatusDisplay(Input(state: .recording, isRecovering: true, length: "00:03")).kind, .recording, "a recording comes before the recovery")
        display = StatusDisplay(Input(isExporting: true))
        expectEqual(display.title, "Exporting", "an export the user started")
        expect(display.detail.contains("Quitting waits"), "says that quitting waits for it")
        expectEqual(StatusDisplay(Input(isRecovering: true, isExporting: true)).kind, .recovering, "the recovery comes before an export")
        expectEqual(StatusDisplay(Input(state: .recording, isExporting: true, length: "00:03")).kind, .recording, "a recording comes before an export")
        display = StatusDisplay(Input())
        expectEqual(display.kind, .idle, "idle")
        expectEqual(display.title, "", "only the symbol when idle")
    }

    await test("status: the item keeps its width only while a recording runs") {
        for kind in Kind.allCases where kind.isRunningRecording {
            expect(Kind.allCases.filter { $0.isRunningRecording }.allSatisfy { kind.keepsWidth(after: $0) }, "\(kind) after a running recording's state: the time only grows")
            expect(!kind.keepsWidth(after: .starting), "\(kind) after Starting, which is wider than the first minutes")
            expect(!kind.keepsWidth(after: nil), "\(kind) shown first")
            expect(!Kind.saving.keepsWidth(after: kind), "Saving after \(kind): the time of a long recording would leave space after it")
        }
        expect(!Kind.recovering.keepsWidth(after: .saving), "a state with a title of its own has its own width")
        expect(!Kind.starting.keepsWidth(after: .recovering), "a recording starts with its own width")
    }

    await test("status: the recorder's own state is what is shown") {
        let rig = try Rig("status-recorder")
        expectEqual(StatusDisplay(rig.controller.statusInput).kind, .idle, "idle")
        let (session, _, _) = try rig.start(enter: false, microphone: true)
        expectEqual(StatusDisplay(rig.controller.statusInput).kind, .starting, "starting")
        session.enterRecording()
        expectEqual(StatusDisplay(rig.controller.statusInput).line, "Recording — microphone OK", "recording")
        rig.controller.setMicrophoneMuted(true)
        expectEqual(StatusDisplay(rig.controller.statusInput).kind, .muted, "muted")
        rig.controller.togglePause()
        expectEqual(StatusDisplay(rig.controller.statusInput).kind, .paused, "paused")
        rig.holdSave = true
        rig.controller.stop()
        expectEqual(StatusDisplay(rig.controller.statusInput).kind, .saving, "saving")
        expect(await rig.wait { rig.controller.state == .finalizing }, "finalizing")
        session.mixProgressed(0.3)
        expect(StatusDisplay(rig.controller.statusInput).line.hasSuffix("30%"), "finishing")
        rig.releaseSave()
        expect(await rig.idle(), "idle")
        expectEqual(StatusDisplay(rig.controller.statusInput).kind, .idle, "idle again")
    }
}
