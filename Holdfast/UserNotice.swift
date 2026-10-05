//
//  UserNotice.swift
//  Holdfast
//

import AppKit
import Foundation
import UserNotifications

/// How the app tells the user something: notifications, and modal alerts that do not hold up a recording
enum UserNotice {
    /// Runs `block` on the main thread as a run loop block. For everything that shows a modal alert: a modal alert
    /// inside a `DispatchQueue.main.async` block holds up every block queued behind it for as long as it is open,
    /// which includes the work that stops and finishes a recording. Any thread.
    static func onMainRunLoop(_ block: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    
    private static let alertLock = NSLock()
    private static var alertsWaiting = 0
    private static var alertHandlers = [() -> Void]()
    
    /// A modal alert on the main thread that does not hold up the caller. Any thread.
    static func showAlertLater(title: String, message: String) {
        alertLock.lock()
        alertsWaiting += 1
        alertLock.unlock()
        onMainRunLoop {
            NSApp.activate(ignoringOtherApps: true)
            _ = createAlert(level: .critical, title: title, message: message, button1: "OK").runModal()
            alertLock.lock()
            alertsWaiting -= 1
            let handlers = alertsWaiting == 0 ? alertHandlers : []
            if alertsWaiting == 0 { alertHandlers = [] }
            alertLock.unlock()
            handlers.forEach { $0() }
        }
    }
    
    /// Main thread. Runs `handler` once every alert asked for with `showAlertLater` has been shown and dismissed;
    /// at once when none is waiting. Quitting waits for it, so that the report of a failure is seen.
    static func whenAlertsDismissed(_ handler: @escaping () -> Void) {
        alertLock.lock()
        let waiting = alertsWaiting > 0
        if waiting { alertHandlers.append(handler) }
        alertLock.unlock()
        if !waiting { handler() }
    }
    
    /// For a failure that must not be missed: a notification, and an alert because notifications may be off or
    /// silenced. It also goes into the recordings log.
    static func reportFailure(title: String, message: String) {
        RecLog.write("\(title): \(message)")
        showNotification(title: title, body: message, id: "holdfast.error.\(UUID().uuidString)")
        showAlertLater(title: title, message: message)
    }

    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send：\(error.localizedDescription)") }
        }
    }
    
    static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
