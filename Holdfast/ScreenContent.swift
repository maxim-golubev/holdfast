//
//  ScreenContent.swift
//  Holdfast
//
//  Created by apple on 2024/4/16.
//

import AppKit
import Foundation
import ScreenCaptureKit

/// What can be recorded: the list of screens, windows and applications ScreenCaptureKit reports, the screen
/// recording permission that list depends on, and the area the area selector chose.
enum ScreenContent {
    /// The area the area selector chose, which the next area recording captures
    static var screenArea: NSRect?
    /// The screens, windows and applications of the last fetch. Assigned and read on the main thread only.
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]

    private static func fetch(_ completion: @escaping (SCShareableContent?, Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false, completionHandler: completion)
    }

    /// Fetches the list again and calls `completion` on the main thread once `availableContent` holds it. A failed
    /// fetch keeps the old list; a denied permission asks for it and quits instead of calling back.
    static func updateAvailableContent(completion: @escaping @MainActor () -> Void) {
        fetch { content, error in
            DispatchQueue.main.async {
                if let error {
                    if case SCStreamError.userDeclined = error {
                        requestPermissions()
                        return
                    }
                    // The caller goes on with the list it has; a start that needs what is missing says so
                    print("Failed to fetch the screens and windows: \(error.localizedDescription)")
                } else {
                    availableContent = content
                    if content?.displays.isEmpty != false { print("There needs to be at least one display connected!") }
                }
                completion()
            }
        }
    }

    /// The same fetch for the main thread, which it blocks until the list is there: the launch and the click-a-window
    /// picker, which need the list before they go on. A failed fetch keeps the old list and asks for nothing.
    static func updateAvailableContentSync() {
        dispatchPrecondition(condition: .onQueue(.main))
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: SCShareableContent?
        fetch { content, _ in
            fetched = content
            semaphore.signal()
        }
        semaphore.wait()
        if let fetched { availableContent = fetched }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return availableContent?.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return availableContent?.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != WindowTitle.mousePointer
            && title != WindowTitle.screenMagnifier
        })
    }
    
    /// The windows on screen that can be recorded, without the app's own when "hideSelf" is on
    static func getWindows() -> [SCWindow] {
        guard let content = availableContent else { return [] }
        var windows = content.windows.filter {
            guard let app = $0.owningApplication, let title = $0.title else { return false }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
            && $0.isOnScreen
        }
        if AppSettings.hideSelf { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon?.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    /// The area last recorded on the screen with that name, as the area selector stored it
    static func savedArea(forScreen name: String) -> NSRect? {
        guard let area = AppSettings.savedAreas[name] as? [String: Any] else { return nil }
        func value(_ key: String) -> CGFloat? { (area[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = value("x"), let y = value("y"), let width = value("width"), let height = value("height"),
              width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    /// Remembers `area` for the screen with that name. The areas of the other screens stay as they are.
    static func saveArea(_ area: NSRect, forScreen name: String) {
        var saved = AppSettings.savedAreas
        saved[name] = ["x": Double(area.origin.x), "y": Double(area.origin.y), "width": Double(area.width), "height": Double(area.height)]
        AppSettings.savedAreas = saved
    }
    
    private static func requestPermissions() {
        UserNotice.onMainRunLoop {
            // macOS applies the permission when the app is opened again, so Holdfast quits either way
            let alert = createAlert(title: "Permission Required",
                                    message: "Holdfast needs permission to record the screen, even to record audio only. Allow it in System Settings, then open Holdfast again. Holdfast quits now.",
                                    button1: "Open System Settings",
                                    button2: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                UserNotice.openPrivacySettings("Privacy_ScreenCapture")
            }
            NSApp.terminate(nil)
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
}
