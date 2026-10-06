//
//  ScreenSharingPrivacy.swift
//  Holdfast
//

import AppKit

/// Keeps Holdfast's own windows (the menu bar item, the panel, the preview, Settings) out of other apps' screen
/// sharing and recordings while "Show During Screen Sharing" is off, by marking them `sharingType = .none`, as Paste
/// does. Holdfast's own recordings leave its windows out either way ("hideSelf").
///
/// Every window the app has is checked whenever one appears or changes, so a window made anywhere in the app is
/// covered without knowing about this. Windows that are always left out of captures (the warning panel, the
/// picker's covers) set `.none` themselves; only the windows hidden here are shown again when the setting goes on.
@MainActor
enum ScreenSharingPrivacy {
    private static var observers: [NSObjectProtocol] = []
    /// The windows this hid, and only those
    private static let hidden = NSHashTable<NSWindow>.weakObjects()

    /// Starts watching the app's windows. Once, at launch.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // A window that comes on screen changes its occlusion state before it can be seen for long; the app's
        // update after each event catches the rest
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSApplication.didUpdateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { apply() }
            })
        }
        apply()
    }

    /// Brings every window in line with the setting. Cheap: a few windows, a property compared.
    static func apply() {
        let hide = !AppSettings.showDuringScreenSharing
        for window in NSApp.windows {
            if hide {
                guard window.sharingType != .none else { continue }
                window.sharingType = .none
                hidden.add(window)
            } else if hidden.contains(window) {
                window.sharingType = .readOnly
                hidden.remove(window)
            }
        }
    }
}
