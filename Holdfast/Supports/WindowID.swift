//
//  WindowID.swift
//  Holdfast
//
//  How the app finds its own windows again: by identifier, never by title.
//

import AppKit

extension NSUserInterfaceItemIdentifier {
    /// The floating main panel (`ContentView`)
    static let mainPanel = NSUserInterfaceItemIdentifier("Holdfast.mainPanel")
    static let countdownPanel = NSUserInterfaceItemIdentifier("Holdfast.countdownPanel")
    static let appSelector = NSUserInterfaceItemIdentifier("Holdfast.appSelector")
    static let windowSelector = NSUserInterfaceItemIdentifier("Holdfast.windowSelector")
    /// The full-screen window an area is drawn in
    static let areaSelector = NSUserInterfaceItemIdentifier("Holdfast.areaSelector")
    /// The area selector's panel with the size fields and the Start button
    static let areaPanel = NSUserInterfaceItemIdentifier("Holdfast.areaPanel")
    /// The dashed frame around the area that is being recorded
    static let areaOverlay = NSUserInterfaceItemIdentifier("Holdfast.areaOverlay")
    /// The dimming window over each screen while a window is picked with the mouse
    static let screenCover = NSUserInterfaceItemIdentifier("Holdfast.screenCover")
    /// The floating preview of a finished recording
    static let preview = NSUserInterfaceItemIdentifier("Holdfast.preview")
}

extension NSApplication {
    /// The app's windows that carry one of these identifiers
    func windows(_ identifiers: NSUserInterfaceItemIdentifier...) -> [NSWindow] {
        windows.filter { window in window.identifier.map { identifiers.contains($0) } ?? false }
    }
}
