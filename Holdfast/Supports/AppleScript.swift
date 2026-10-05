//
//  AppleScript.swift
//  Holdfast
//
//  Created by apple on 2024/9/23.
//

import Foundation
import AppKit
import ScreenCaptureKit

/// Whether a recording can be started now (`RecorderController.startRefusal`). When not, the script gets an error,
/// and no alert: the script reports it, and an alert would come up over the app in front. Script commands run on
/// the main thread.
private func scriptCanStart(_ command: NSScriptCommand) -> Bool {
    guard let refusal = withRecorder({ $0.startRefusal }) else { return true }
    command.scriptErrorNumber = errOSAGeneralError
    switch refusal {
    case .recording: command.scriptErrorString = "A recording is already running."
    case .saving: command.scriptErrorString = "The previous recording is still being saved."
    case .quitting: command.scriptErrorString = "Holdfast is quitting."
    }
    return false
}

/// What a record command that has looked at the screens and windows cannot do. The command has returned by then,
/// so the user is told with an alert that does not hold up a recording.
private func scriptFailed(_ message: String) {
    UserNotice.showAlertLater(title: "Failed to Record", message: message)
}

/// `record screen [number]`: that screen, or the screen selector without a number
class selectScreen: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        let number = evaluatedArguments?["index"] as? Int
        ScreenContent.updateAvailableContent {
            closeAllWindow()
            guard let number = number else { return AppDelegate.shared.chooseScreen() }
            let screens = ScreenContent.availableContent?.displays ?? []
            guard screens.indices.contains(number - 1) else {
                return scriptFailed(String(format: "There is no screen number %d. Screens are numbered from 1 to %d.", number, screens.count))
            }
            let screen = screens[number - 1]
            AppDelegate.shared.createCountdownPanel(screen: screen) {
                RecorderController.shared.start(type: .screen, display: screen, windows: nil, applications: nil)
            }
        }
        return nil
    }
}

/// `record area`: the area selector
class selectArea: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        closeAllWindow()
        AppDelegate.shared.chooseArea()
        return nil
    }
}

/// `record application [named X]`: that application on the one screen it has windows on, or the selector
class selectApps: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        let name = evaluatedArguments?["name"] as? String
        ScreenContent.updateAvailableContent {
            closeAllWindow()
            guard let name = name else { return AppDelegate.shared.chooseApplication() }
            guard let app = ScreenContent.availableContent?.applications.first(where: { $0.applicationName == name }) else {
                return scriptFailed(String(format: "No running application is named \"%@\".", name))
            }
            // The screens are those the named application has windows on
            let windows = ScreenContent.getWindows().filter { $0.owningApplication?.processID == app.processID }
            let screens = (ScreenContent.availableContent?.displays ?? []).filter { screen in windows.contains { NSIntersectsRect(screen.frame, $0.frame) } }
            guard let screen = screens.first else {
                return scriptFailed(String(format: "\"%@\" has no window on screen to record.", name))
            }
            guard screens.count == 1 else {
                AppDelegate.shared.chooseApplication()
                return scriptFailed(String(format: "\"%@\" has windows on more than one screen. Choose it in the selector.", name))
            }
            AppDelegate.shared.createCountdownPanel(screen: screen) {
                RecorderController.shared.start(type: .application, display: screen, windows: nil, applications: [app])
            }
        }
        return nil
    }
}

/// `record window [titled X] [in application Y]`: that window, or the selector. Only windows on screen are
/// looked at, as in the selector: a minimized window or one on another Space delivers no picture.
class selectWindows: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        let title = evaluatedArguments?["title"] as? String
        let appName = evaluatedArguments?["app"] as? String
        ScreenContent.updateAvailableContent {
            closeAllWindow()
            guard let title = title else { return AppDelegate.shared.chooseWindow() }
            var windows = ScreenContent.getWindows().filter { $0.title == title }
            if let appName = appName { windows = windows.filter { $0.owningApplication?.applicationName == appName } }
            guard let window = windows.first else {
                return scriptFailed(String(format: "No window on screen is titled \"%@\".", title))
            }
            guard windows.count == 1 else {
                AppDelegate.shared.chooseWindow()
                return scriptFailed(String(format: "More than one window is titled \"%@\". Choose it in the selector.", title))
            }
            let screens = (ScreenContent.availableContent?.displays ?? []).filter { NSIntersectsRect($0.frame, window.frame) }
            guard let screen = screens.first else {
                return scriptFailed(String(format: "The window \"%@\" is on no connected screen.", title))
            }
            // The countdown is shown where the pointer is when the window is there too
            let countdownScreen = ScreenContent.getSCDisplayWithMouse().flatMap { screens.contains($0) ? $0 : nil } ?? screen
            AppDelegate.shared.createCountdownPanel(screen: countdownScreen) {
                RecorderController.shared.start(type: .window, display: screen, windows: [window], applications: nil)
            }
        }
        return nil
    }
}

/// `record system audio [with microphone]`: starts at once, without a selector
class recordAudio: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        // The "mic" argument applies to this recording only; the "recordMic" setting is left alone
        let mic = evaluatedArguments?["mic"] as? Bool
        ScreenContent.updateAvailableContent {
            closeAllWindow()
            RecorderController.shared.start(type: .systemaudio, display: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil, recordMic: mic)
        }
        return nil
    }
}

class stopRecording: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Script commands are dispatched on the main thread. A countdown runs before a recording is started, so
        // there is either one to cancel, like its Cancel button does, or a recording to stop.
        if !AppDelegate.shared.cancelCountdown() {
            // Same action as Stop Recording in the status item's menu. It returns at once; a recording that is still starting is
            // stopped as soon as its capture runs.
            withRecorder { $0.stop() }
        }
        return nil
    }
}

/// `mute microphone` and `unmute microphone`: each says what the track is to be, so a script that runs twice does
/// not undo itself. An error when no recording with a microphone track is running.
private func scriptSetMicrophoneMuted(_ muted: Bool, _ command: NSScriptCommand) {
    if withRecorder({ $0.setMicrophoneMuted(muted) }) { return }
    command.scriptErrorNumber = errOSAGeneralError
    command.scriptErrorString = "No recording with a microphone track is running."
}

class muteMicrophone: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptSetMicrophoneMuted(true, self)
        return nil
    }
}

class unmuteMicrophone: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptSetMicrophoneMuted(false, self)
        return nil
    }
}

class setPreferences: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Settings are read while a recording starts and runs. One that is only being saved has its own copy.
        if withRecorder({ $0.state == .starting || $0.state == .recording }) {
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = "Settings cannot be changed while recording."
            return nil
        }
        // highRes is an Int setting: 2 = Retina resolution, 1 = normal
        if let hires = self.evaluatedArguments?["hires"] as? Bool { AppSettings.highRes = hires ? 2 : 1 }
        if let fps = self.evaluatedArguments?["fps"] as? Int { AppSettings.frameRate = fps }
        if let cursor = self.evaluatedArguments?["cursor"] as? Bool { AppSettings.showMouse = cursor }
        if let sound = self.evaluatedArguments?["sound"] as? Bool { AppSettings.recordWinSound = sound }
        if let microphone = self.evaluatedArguments?["microphone"] as? Bool { AppSettings.recordMic = microphone }
        if let quality = self.evaluatedArguments?["quality"] as? Int {
            if [1,2,3].contains(quality) {
                switch quality {
                    case 1: AppSettings.videoQuality = 0.3
                    case 2: AppSettings.videoQuality = 0.7
                    default: AppSettings.videoQuality = 1.0
                }
            }
        }
        if let micname = self.evaluatedArguments?["micname"] as? String, !MicSelection.selectMic(named: micname) {
            // The other settings above were applied; the microphone selection stays as it was
            scriptErrorNumber = errOSAGeneralError
            scriptErrorString = "No connected audio input device is named \"\(micname)\". The microphone selection was not changed."
        }
        if let hdr = self.evaluatedArguments?["hdr"] as? Bool { AppSettings.recordHDR = hdr }
        return nil
    }
}
