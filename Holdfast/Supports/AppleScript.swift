//
//  AppleScript.swift
//  Holdfast
//
//  Created by apple on 2024/9/23.
//

import Foundation
import AppKit
import ScreenCaptureKit

/// Whether a recording can be started now (`RecorderController.canStart`, as the hotkeys ask). When not, the script gets an
/// error instead of a start that is refused later without a word. Script commands run on the main thread.
private func scriptCanStart(_ command: NSScriptCommand) -> Bool {
    if withRecorder({ $0.canStart() }) { return true }
    command.scriptErrorNumber = errOSAGeneralError
    command.scriptErrorString = withRecorder({ $0.isSaving }) ? "The previous recording is still being saved." : "Already recording!"
    return false
}

class selectScreen: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        ScreenContent.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                if var index = self.evaluatedArguments?["index"] as? Int {
                    guard let screens = ScreenContent.availableContent?.displays else { return }
                    index -= 1
                    if index >= screens.count || index < 0 {
                        createAlert(title: "Error".local, message: "Invalid screen number!".local, button1: "OK".local).runModal()
                        return
                    } else {
                        let screen = screens[index]
                        AppDelegate.shared.createCountdownPanel(screen: screen) {
                            RecorderController.shared.start(type: .screen, screens: screen, windows: nil, applications: nil)
                        }
                    }
                } else {
                    AppDelegate.shared.createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
                }
            }
        }
        return nil
    }
}

class selectArea: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        closeAllWindow()
        AppDelegate.shared.chooseArea()
        return nil
    }
}

class selectApps: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        ScreenContent.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                if let name = self.evaluatedArguments?["name"] as? String {
                    guard let app = ScreenContent.availableContent?.applications.first(where: { $0.applicationName == name }) else {
                        createAlert(title: "Error".local, message: "No such application!".local, button1: "OK".local).runModal()
                        return
                    }
                    guard let screens = ScreenContent.availableContent?.displays else { return }
                    guard let windows = ScreenContent.availableContent?.windows.filter({
                        guard let title = $0.title else { return false }
                        return !title.contains("Item-0")
                        && title != "Window"
                        && $0.frame.width > 40
                        && $0.frame.height > 40
                    }) else { return }
                    var s = [SCDisplay]()
                    for screen in screens {
                        for w in windows {
                            if NSIntersectsRect(screen.frame, w.frame) { if !s.contains(screen) { s.append(screen) }}
                        }
                    }
                    guard let screen = s.first else {
                        createAlert(title: "Error".local, message: "This application has no windows!".local, button1: "OK".local).runModal()
                        return
                    }
                    if s.count != 1 {
                        AppDelegate.shared.createNewWindow(view: AppSelector(), title: "App Selector".local, identifier: .appSelector)
                        createAlert(title: "Error".local, message: "This app exists in multiple screens, please select it manually!".local, button1: "OK".local).runModal()
                    } else {
                        AppDelegate.shared.createCountdownPanel(screen: screen) {
                            RecorderController.shared.start(type: .application, screens: screen, windows: nil, applications: [app])
                        }
                    }
                } else {
                    AppDelegate.shared.createNewWindow(view: AppSelector(), title: "App Selector".local, identifier: .appSelector)
                }
            }
        }
        return nil
    }
}

class selectWindows: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        ScreenContent.updateAvailableContent {
            DispatchQueue.main.async {
                closeAllWindow()
                if let title = self.evaluatedArguments?["title"] as? String {
                    guard var windows = ScreenContent.availableContent?.windows.filter({ $0.title == title }) else { return }
                    if let app = self.evaluatedArguments?["app"] as? String {
                        windows = windows.filter({ $0.owningApplication?.applicationName == app })
                    }
                    guard let window = windows.first else {
                        createAlert(title: "Error".local, message: "No such window!".local, button1: "OK".local).runModal()
                        return
                    }
                    if windows.count > 1 {
                        AppDelegate.shared.createNewWindow(view: WinSelector(), title: "Window Selector".local, identifier: .windowSelector)
                        createAlert(title: "Error".local, message: "Duplicate window exists, please select it manually!".local, button1: "OK".local).runModal()
                        return
                    }
                    guard let screens = ScreenContent.availableContent?.displays else { return }
                    var s = [SCDisplay]()
                    for screen in screens {
                        if NSIntersectsRect(screen.frame, window.frame) { if !s.contains(screen) { s.append(screen) }}
                    }
                    guard let screen = s.first else {
                        createAlert(title: "Error".local, message: "Unable to find the screen this window belongs to!".local, button1: "OK".local).runModal()
                        return
                    }
                    if let display = ScreenContent.getSCDisplayWithMouse() {
                        // The countdown is shown where the pointer is when the window is there too
                        AppDelegate.shared.createCountdownPanel(screen: s.contains(display) ? display : screen) {
                            RecorderController.shared.start(type: .window, screens: screen, windows: [window], applications: nil)
                        }
                    }
                } else {
                    AppDelegate.shared.createNewWindow(view: WinSelector(), title: "Window Selector".local, identifier: .windowSelector)
                }
            }
        }
        return nil
    }
}

class recordAudio: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard scriptCanStart(self) else { return nil }
        ScreenContent.updateAvailableContent {
            DispatchQueue.main.async {
                // The "mic" argument applies to this recording only; the "recordMic" setting is left alone
                let mic = self.evaluatedArguments?["mic"] as? Bool
                closeAllWindow()
                RecorderController.shared.start(type: .systemaudio, screens: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil, recordMic: mic)
            }
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
