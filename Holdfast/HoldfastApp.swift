//
//  HoldfastApp.swift
//  Holdfast
//
//  Created by apple on 2024/4/16.
//

import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import UserNotifications
import KeyboardShortcuts

let fd = FileManager.default
let mousePointer = NSWindow(contentRect: NSRect(x: -70, y: -70, width: 70, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
let screenMagnifier = NSWindow(contentRect: NSRect(x: -402, y: -402, width: 402, height: 348), styleMask: [.borderless], backing: .buffered, defer: false)
let countdownPanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 266, height: 156), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)

@main
struct HoldfastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        DocumentGroup(newDocument: qmaPackageHandle()) { file in
            if let fileURL = file.fileURL {
                qmaPlayerView(document: file.$document, fileURL: fileURL)
                    .frame(minWidth: 400, minHeight: 100, maxHeight: 100)
                    .focusable(false)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .textEditing) {}
        }
        
        Settings {
            SettingsView()
        }
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The delegate SwiftUI created for `@NSApplicationDelegateAdaptor`, which is the one the app's events go to. `NSApp.delegate` is a SwiftUI object that forwards to it, so it is noted when it is created.
    private static var created: AppDelegate?
    static var shared: AppDelegate { created ?? AppDelegate() }
    
    override init() {
        super.init()
        // SwiftUI creates its delegate before any view or script command asks for `shared`; nothing else creates one
        AppDelegate.created = self
    }
    
    private var isMagnifierCapturing = false
    private var pendingMagnifierEvent: NSEvent?
    /// The monitor that drives the mouse highlight and the magnifier of a recording
    private var recordingMouseMonitor: Any?
    /// The area selector's, which shows it again on the display the pointer moves to. One at most.
    private var areaSelectorMonitor: Any?
    private var tracksMouseForRecording = false
    private var mousePointerHost: NSHostingView<MousePointerView>?
    /// SIGTERM (`kill`, `killall`, a forced shutdown) quits like Quit does, which closes a running recording first
    private var terminateSignal: DispatchSourceSignal?
    
    func mousePointerReLocation(event: NSEvent) {
        if event.type == .scrollWheel { return }
        if !AppSettings.highlightMouse || withRecorder({ !$0.hasStream || $0.streamType == .window }) {
            mousePointer.orderOut(nil)
            return
        }
        let mouseLocation = event.locationInWindow
        var windowFrame = mousePointer.frame
        windowFrame.origin = NSPoint(x: mouseLocation.x - windowFrame.width / 2, y: mouseLocation.y - windowFrame.height / 2)
        // One hosting view for the whole run, not a new one for every mouse event
        if let host = mousePointerHost {
            host.rootView = MousePointerView(event: event)
            if mousePointer.contentView !== host { mousePointer.contentView = host }
        } else {
            let host = NSHostingView(rootView: MousePointerView(event: event))
            mousePointerHost = host
            mousePointer.contentView = host
        }
        mousePointer.setFrameOrigin(windowFrame.origin)
        mousePointer.orderFront(nil)
    }
    
    func screenMagnifierReLocation(event: NSEvent) {
        if !withRecorder({ $0.isMagnifierEnabled }) { screenMagnifier.orderOut(nil); return }
        // Captures are asynchronous: run one at a time and keep only the latest event that arrived meanwhile
        if isMagnifierCapturing { pendingMagnifierEvent = event; return }
        isMagnifierCapturing = true
        let mouseLocation = event.locationInWindow
        let origin = NSPoint(x: mouseLocation.x - screenMagnifier.frame.width / 2, y: mouseLocation.y - screenMagnifier.frame.height / 2)
        let rect = NSRect(x: mouseLocation.x - 67, y: mouseLocation.y - 58, width: 134, height: 116)
        NSImage.createScreenShot(of: rect) { [self] image in
            isMagnifierCapturing = false
            if let image, withRecorder({ $0.isMagnifierEnabled }) {
                screenMagnifier.contentView = NSHostingView(rootView: ScreenMagnifier(screenShot: image))
                screenMagnifier.setFrameOrigin(origin)
                screenMagnifier.orderFront(nil)
            }
            if let next = pendingMagnifierEvent {
                pendingMagnifierEvent = nil
                screenMagnifierReLocation(event: next)
            }
        }
    }
    
    /// Main thread. From here on a video recording runs, which may show the mouse highlight and the magnifier.
    func startRecordingMouseMonitor() {
        tracksMouseForRecording = true
        updateRecordingMouseMonitor()
    }
    
    /// Main thread. The recording is over.
    func stopRecordingMouseMonitor() {
        tracksMouseForRecording = false
        updateRecordingMouseMonitor()
    }
    
    /// Main thread. Every mouse event of the system is only listened to while something is drawn from it: during a
    /// video recording with "Highlight the Cursor" on or the magnifier switched on. Called when any of the
    /// three changes.
    func updateRecordingMouseMonitor() {
        let highlight = tracksMouseForRecording && AppSettings.highlightMouse
        let magnifier = tracksMouseForRecording && withRecorder({ $0.isMagnifierEnabled })
        if highlight || magnifier {
            if recordingMouseMonitor == nil {
                recordingMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .rightMouseUp, .rightMouseDown, .rightMouseDragged, .leftMouseUp,  .leftMouseDown, .leftMouseDragged, .otherMouseUp, .otherMouseDown, .otherMouseDragged]) { [weak self] event in
                    self?.mousePointerReLocation(event: event)
                    self?.screenMagnifierReLocation(event: event)
                }
            }
        } else if let monitor = recordingMouseMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMouseMonitor = nil
        }
        // No event may come any more to take them off the screen
        if !highlight { mousePointer.orderOut(nil) }
        if !magnifier { screenMagnifier.orderOut(nil) }
    }
    
    /// Removes the area selector's monitor, and the mouse highlight
    func stopAreaSelectorMonitor() {
        mousePointer.orderOut(nil)
        if let monitor = areaSelectorMonitor { NSEvent.removeMonitor(monitor); areaSelectorMonitor = nil }
    }

    /// Shows the area selector on the display with the pointer, and again on each display the pointer moves to,
    /// until it is closed. One that is open already, from another menu or display, goes first with its monitor.
    func showAreaSelectorFollowingPointer() {
        stopAreaSelectorMonitor()
        for w in NSApp.windows(.areaSelector, .areaPanel) { w.close() }
        showAreaSelector(size: NSSize(width: 600, height: 450))
        var currentDisplay = ScreenContent.getSCDisplayWithMouse()
        areaSelectorMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { [self] _ in
            let display = ScreenContent.getSCDisplayWithMouse()
            guard display != currentDisplay else { return }
            currentDisplay = display
            // Only the selector's own windows: a recording's frame, Settings or a trimmer stay
            for w in NSApp.windows(.areaSelector, .areaPanel) { w.close() }
            showAreaSelector(size: NSSize(width: 600, height: 450))
        }
    }
    
    /// Without this the system shows no banner while the app is active, which it is right after Start was clicked
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // While a recording is starting, running or still being saved, quitting would leave a file that was not
        // closed, or one under its temporary name with unmixed audio. The recorder stops it (a no-op when it already
        // is) and replies when its files are final. The same goes for a recording of an earlier run that is being
        // mixed, and the report of a failure is seen first: the notification alone may be off or silenced.
        // Meanwhile the main run loop keeps running.
        let now = withRecorder { $0.canQuit(orReply: { NSApp.reply(toApplicationShouldTerminate: true) }) }
        return now ? .terminateNow : .terminateLater
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // applicationShouldTerminate has waited for the recording, so there is nothing left to do here. Should the
        // app ever be terminated past it, the recording is stopped the same way and given a moment to be saved:
        // the run loop is run, not blocked, because saving continues on the main thread.
        guard withRecorder({ $0.state != .idle }) else { return }
        withRecorder { $0.stop() }
        let deadline = Date.now.addingTimeInterval(30)
        while withRecorder({ $0.state != .idle }) && Date.now < deadline {
            RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.1))
        }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if trimingList.contains(url) { continue }
            openTrimmer(url, random: true)
            closeMainWindow()
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The default action would end the process at once, leaving a recording unclosed and unmixed
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { NSApp.terminate(nil) }
        terminate.resume()
        terminateSignal = terminate
        ScreenContent.updateAvailableContentSync()
        
        let process = NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        if process.count > 1 {
            DispatchQueue.main.async {
                let button = createAlert(title: "Holdfast Is Already Running".local, message: "Another copy of Holdfast is already open. This copy quits.".local, button1: "Quit".local).runModal()
                if button == .alertFirstButtonReturn { NSApp.terminate(self) }
            }
        }
        
        // Whether the Mac encodes HEVC in hardware is asked once, here, not when the first recording starts
        _ = Encoder.preferred
        if AppSettings.showOnDock { NSApp.setActivationPolicy(.regular) }
        
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error { print("Notification authorization denied: \(error.localizedDescription)") }
        }
        
        mousePointer.title = WindowTitle.mousePointer
        mousePointer.level = .screenSaver
        mousePointer.ignoresMouseEvents = true
        mousePointer.isReleasedWhenClosed = false
        mousePointer.backgroundColor = NSColor.clear
        
        screenMagnifier.title = WindowTitle.screenMagnifier
        screenMagnifier.level = .floating
        screenMagnifier.ignoresMouseEvents = true
        screenMagnifier.isReleasedWhenClosed = false
        screenMagnifier.backgroundColor = NSColor.clear
        
        countdownPanel.title = "Countdown Panel".local
        countdownPanel.identifier = .countdownPanel
        countdownPanel.level = .floating
        countdownPanel.isReleasedWhenClosed = false
        countdownPanel.isMovableByWindowBackground = false
        countdownPanel.backgroundColor = NSColor.clear
        
        previewWindow.level = .statusBar
        previewWindow.titlebarAppearsTransparent = true
        previewWindow.titleVisibility = .hidden
        previewWindow.isReleasedWhenClosed = false
        previewWindow.backgroundColor = .clear
        
        KeyboardShortcuts.onKeyDown(for: .showPanel) { [self] in openMainPanel() }
        KeyboardShortcuts.onKeyDown(for: .saveFrame) { withRecorder { if $0.hasStream { $0.session?.savePicture() } } }
        KeyboardShortcuts.onKeyDown(for: .screenMagnifier) { [self] in
            guard withRecorder({ $0.hasStream }) else { return }
            withRecorder { $0.session?.isMagnifierEnabled.toggle() }
            updateRecordingMouseMonitor()
        }
        // During a countdown there is no recording yet: the pending start is cancelled, as its Cancel button does
        KeyboardShortcuts.onKeyDown(for: .stop) { [self] in if !cancelCountdown() { withRecorder { $0.stop() } } }
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { withRecorder { if $0.hasStream { $0.togglePause() } } }
        KeyboardShortcuts.onKeyDown(for: .muteMicrophone) { withRecorder { $0.toggleMicrophoneMute() } }
        KeyboardShortcuts.onKeyDown(for: .startWithAudio) { [self] in
            startWithFreshContent { recorder in
                closeAllWindow()
                recorder.start(type: .systemaudio, display: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .startWithScreen) { [self] in
            startWithFreshContent { recorder in
                closeAllWindow()
                recorder.start(type: .screen, display: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .startWithArea) { [self] in
            guard withRecorder({ $0.canStart() }) else { return }
            closeAllWindow()
            chooseArea()
        }
        KeyboardShortcuts.onKeyDown(for: .startWithWindow) { [self] in
            // Asked now: by the time the list is there, another application may be in front
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            startWithFreshContent { recorder in
                closeAllWindow()
                guard let pid = pid, let scWindow = ScreenContent.getWindows().first(where: { $0.owningApplication?.processID == pid && $0.title != "" && $0.isOnScreen }) else {
                    UserNotice.showAlertLater(title: "Failed to Record".local, message: "No window of the frontmost application was found.".local)
                    return
                }
                recorder.start(type: .window, display: ScreenContent.getSCDisplayWithMouse(), windows: [scWindow], applications: nil, fastStart: true)
            }
        }
        withRecorder { _ in StatusItemController.shared.install() }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        closeAllWindow()
        withRecorder { $0.recovery.start(in: AppSettings.saveDirectory) }
        // Opened by the user, the app shows its panel; started at login, it waits in the menu bar until it is wanted
        let launch = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = launch?.eventID == kAEOpenApplication
            && launch?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if AppSettings.showOnDock && !atLogin { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }
    }
    
    /// A start that works from the list of screens and windows without a selector having fetched it: the list is
    /// fetched first, because the one from the launch does not know a display connected or a window opened since.
    /// `start` runs on the main thread, if a recording can still be started by then.
    func startWithFreshContent(_ start: @escaping @MainActor (RecorderController) -> Void) {
        guard withRecorder({ $0.canStart() }) else { return }
        ScreenContent.updateAvailableContent {
            DispatchQueue.main.async {
                withRecorder { recorder in
                    guard recorder.canStart() else { return }
                    start(recorder)
                }
            }
        }
    }

    /// "Open Main Panel" in the menus and its hotkey: shows the panel unless it is there or a recording has its
    /// stream, whatever other windows are open.
    func openMainPanel() {
        guard withRecorder({ !$0.hasStream }) else { return }
        if !NSApp.windows(.mainPanel).contains(where: { $0.isVisible }) { showMainPanel() }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A click on the Dock icon: the main panel, unless another window of the app is open (audio players aside)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard withRecorder({ !$0.hasStream }) else { return false }
        let open = NSApp.windows.filter { $0.isVisible && $0.title != "Item-0" && !$0.title.isEmpty && !$0.title.lowercased().contains(".qma") }
        if open.isEmpty { showMainPanel() }
        return false
    }
    
    /// The status item's commands under the Dock icon too, which is there when the status item is out of sight
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return withRecorder { _ in StatusItemController.shared.dockMenu() }
    }
}

func closeMainWindow() {
    for w in NSApp.windows(.mainPanel) { w.close() }
}

/// Main thread. The dashed frame around the recorded area, which a selector puts up before it asks for the start.
func closeAreaOverlay() {
    for w in NSApp.windows(.areaOverlay) { w.close() }
}

/// Closes every window that has a title, except the status item's and the audio documents'. Windows that must
/// survive this (the preview, alerts) have no title. The click-a-window picker ends with its windows.
func closeAllWindow() {
    WindowHighlighter.shared.stopMouseMonitor()
    for w in NSApp.windows.filter({ $0.title != "Item-0" && $0.title != "" && !$0.title.lowercased().contains(".qma") }) { w.close() }
}

/// A tip that is shown until "Don't Remind Me Again" is chosen. Return is OK: it shows the tip again next time.
func tips(_ message: String, id: String) {
    let never = AppSettings.dismissedTips
    if never.contains(id) { return }
    let alert = createAlert(title: Bundle.main.appName + " Tips".local, message: message, button1: "OK", button2: "Don't Remind Me Again").runModal()
    if alert == .alertSecondButtonReturn { AppSettings.dismissedTips = never + [id] }
}

func createAlert(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "") -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title.local
    alert.informativeText = message.local
    alert.addButton(withTitle: button1.local)
    if button2 != "" { alert.addButton(withTitle: button2.local) }
    alert.alertStyle = level
    return alert
}

func showAlertSyncOnMainThread(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "") -> NSApplication.ModalResponse {
    // Waiting for the main queue on the main thread would never return
    if Thread.isMainThread {
        return createAlert(level: level, title: title, message: message, button1: button1, button2: button2).runModal()
    }
    var response: NSApplication.ModalResponse = .abort
    let semaphore = DispatchSemaphore(value: 0)
    
    // A run loop block: an alert inside a main queue block would hold up everything queued behind it while it is open
    UserNotice.onMainRunLoop {
        let alert = createAlert(level: level, title: title, message: message, button1: button1, button2: button2)
        response = alert.runModal()
        semaphore.signal()
    }
    
    semaphore.wait()
    return response
}

extension Bundle {
    var appName: String {
        let appName = self.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                     ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                     ?? "Unknown App Name"
        return appName
    }
}

extension String {
    var local: String { return NSLocalizedString(self, comment: "") }
    var url: URL { return URL(fileURLWithPath: self) }
}

extension NSImage {
    /// Captures `rect` (global AppKit screen coordinates) without this app's own windows.
    /// Only the display containing the centre of `rect` is captured; parts of `rect` outside it are left transparent.
    /// The completion handler runs on the main queue.
    static func createScreenShot(of rect: NSRect, completion: @escaping (NSImage?) -> Void) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let content = ScreenContent.availableContent,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            completion(nil)
            return
        }
        // sourceRect must stay inside the display, so capture only the visible part and pad the rest
        let visible = rect.intersection(screen.frame)
        if visible.isEmpty { completion(nil); return }
        let ownApps = content.applications.filter({ $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let factor = screen.backingScaleFactor
        let conf = SCStreamConfiguration()
        // sourceRect is relative to the display, in points, with a top-left origin
        conf.sourceRect = CGRect(x: visible.minX - screen.frame.minX, y: screen.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        conf.width = max(1, Int(visible.width * factor))
        conf.height = max(1, Int(visible.height * factor))
        conf.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: conf) { cgImage, error in
            if let error = error { print("Screenshot failed: \(error.localizedDescription)") }
            var image: NSImage?
            if let cgImage {
                let part = NSImage(cgImage: cgImage, size: visible.size)
                if visible == rect {
                    image = part
                } else {
                    let offset = NSPoint(x: visible.minX - rect.minX, y: visible.minY - rect.minY)
                    image = NSImage(size: rect.size, flipped: false) { _ in
                        part.draw(in: NSRect(origin: offset, size: visible.size))
                        return true
                    }
                }
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
    
    /// Writes the image to `url`, which must not exist yet, as a PNG. Throws when it cannot be encoded or written.
    func saveToFile(_ url: URL) throws {
        guard let tiffData = tiffRepresentation, let imageRep = NSBitmapImageRep(data: tiffData),
              let pngData = imageRep.representation(using: .png, properties: [:]) else {
            throw RecordingError("The picture could not be encoded.")
        }
        try pngData.write(to: url, options: .withoutOverwriting)
    }
}
