//
//  WindowID.swift
//  QuickRecorder
//
//  How the app finds its own windows again: by identifier, never by title.
//

import AppKit

extension NSUserInterfaceItemIdentifier {
    /// The floating main panel (`ContentView`)
    static let mainPanel = NSUserInterfaceItemIdentifier("QuickRecorder.mainPanel")
    static let countdownPanel = NSUserInterfaceItemIdentifier("QuickRecorder.countdownPanel")
    static let appSelector = NSUserInterfaceItemIdentifier("QuickRecorder.appSelector")
    static let windowSelector = NSUserInterfaceItemIdentifier("QuickRecorder.windowSelector")
    /// The full-screen window an area is drawn in
    static let areaSelector = NSUserInterfaceItemIdentifier("QuickRecorder.areaSelector")
    /// The area selector's panel with the size fields and the Start button
    static let areaPanel = NSUserInterfaceItemIdentifier("QuickRecorder.areaPanel")
    /// The dashed frame around the area that is being recorded
    static let areaOverlay = NSUserInterfaceItemIdentifier("QuickRecorder.areaOverlay")
    /// The dimming window over each screen while a window is picked with the mouse
    static let screenCover = NSUserInterfaceItemIdentifier("QuickRecorder.screenCover")
}

extension NSApplication {
    /// The app's windows that carry one of these identifiers
    func windows(_ identifiers: NSUserInterfaceItemIdentifier...) -> [NSWindow] {
        windows.filter { window in window.identifier.map { identifiers.contains($0) } ?? false }
    }
}

/// ScreenCaptureKit lists the app's own windows as `SCWindow`, which has a title but no identifier. These two
/// are told apart there by their titles, so the titles are constants shared by the window and the comparison.
enum WindowTitle {
    static let mousePointer = "Mouse Pointer"
    static let screenMagnifier = "Screen Magnifier"
}
