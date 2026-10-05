//
//  QuickRecorderApp.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AppKit
import SwiftUI
import AVFAudio
import AVFoundation
import ScreenCaptureKit
import UserNotifications
import KeyboardShortcuts
import ServiceManagement
import VideoToolbox

var scPerm = false
let fd = FileManager.default
var mouseMonitor: Any?
var keyMonitor: Any?
let mousePointer = NSWindow(contentRect: NSRect(x: -70, y: -70, width: 70, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
let screenMagnifier = NSWindow(contentRect: NSRect(x: -402, y: -402, width: 402, height: 348), styleMask: [.borderless], backing: .buffered, defer: false)
let countdownPanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 266, height: 156), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)

@main
struct QuickRecorderApp: App {
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
            SidebarCommands()
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .textEditing) {}
        }
        
        Settings {
            SettingsView()
                .background(
                    WindowAccessor(
                        onWindowOpen: { w in
                            if let w = w {
                                //w.level = .floating
                                w.titlebarSeparatorStyle = .none
                                guard let nsSplitView = findNSSplitVIew(view: w.contentView),
                                      let controller = nsSplitView.delegate as? NSSplitViewController else { return }
                                controller.splitViewItems.first?.canCollapse = false
                                controller.splitViewItems.first?.minimumThickness = 140
                                controller.splitViewItems.first?.maximumThickness = 140
                                w.orderFront(nil)
                            }
                        })
                )
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
    
    var isResizing = false
    private var isMagnifierCapturing = false
    private var pendingMagnifierEvent: NSEvent?
    /// The monitor that drives the mouse highlight and the magnifier of a recording. Not `mouseMonitor`, which
    /// belongs to the selectors.
    private var recordingMouseMonitor: Any?
    private var tracksMouseForRecording = false
    private var mousePointerHost: NSHostingView<MousePointerView>?
    
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
                screenMagnifier.contentView = NSHostingView(rootView: ScreenMagnifier(screenShot: image, event: event))
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
    /// video recording with "Highlight the Mouse Cursor" on or the magnifier switched on. Called when any of the
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
    
    /// Removes the monitor a selector installed (`mouseMonitor`)
    func stopGlobalMouseMonitor() {
        mousePointer.orderOut(nil)
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor); mouseMonitor = nil }
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
            createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, random: true, only: false)
            closeMainWindow()
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        scPerm = ScreenContent.updateAvailableContentSync() != nil
        
        let process = NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        if process.count > 1 {
            DispatchQueue.main.async {
                let button = createAlert(title: "QuickRecorder is Running".local, message: "Please do not run multiple instances!".local, button1: "Quit".local).runModal()
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
        
        KeyboardShortcuts.onKeyDown(for: .showPanel) {
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            if withRecorder({ !$0.hasStream }) { NSApp.activate(ignoringOtherApps: true) }
        }
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
        KeyboardShortcuts.onKeyDown(for: .startWithAudio) {
            withRecorder { recorder in
                guard recorder.canStart() else { return }
                closeAllWindow()
                recorder.start(type: "audio", screens: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .startWithScreen) {
            withRecorder { recorder in
                guard recorder.canStart() else { return }
                closeAllWindow()
                recorder.start(type: "display", screens: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .startWithArea) {[self] in
            guard withRecorder({ $0.canStart() }) else { return }
            closeAllWindow()
            showAreaSelector(size: NSSize(width: 600, height: 450))
        }
        KeyboardShortcuts.onKeyDown(for: .startWithWindow) {
            withRecorder { recorder in
                guard recorder.canStart() else { return }
                closeAllWindow()
                let frontmostApp = NSWorkspace.shared.frontmostApplication
                if let pid = frontmostApp?.processIdentifier {
                    guard let scWindow = ScreenContent.getWindows().first(where: { $0.owningApplication?.processID == pid && $0.title != "" && $0.isOnScreen }) else { return }
                    recorder.start(type: "window", screens: ScreenContent.getSCDisplayWithMouse(), windows: [scWindow], applications: nil, fastStart: true)
                }
            }
        }
        withRecorder { _ in StatusItemController.shared.install() }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        closeAllWindow()
        withRecorder { $0.recovery.start(in: AppSettings.saveDirectory) }
        if AppSettings.showOnDock { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if withRecorder({ !$0.hasStream }) {
            let w1 = NSApp.windows.filter({ !$0.title.contains("Item-0") && !$0.title.isEmpty && $0.isVisible })
            let w2 = w1.filter({ !$0.title.contains(".qma") })
            if (!w1.isEmpty && w2.isEmpty) || w1.isEmpty {
                let offset = (!AppSettings.showOnDock && !AppSettings.showMenubar) ? 127 : 0
                let width = 801
                let mainPanel = EscPanel(contentRect: NSRect(x: 0, y: 0, width: width + offset, height: 100), styleMask: [.fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
                mainPanel.contentView = NSHostingView(rootView: ContentView())
                mainPanel.title = "QuickRecorder".local
                mainPanel.identifier = .mainPanel
                mainPanel.isOpaque = false
                mainPanel.level = .floating
                mainPanel.isRestorable = false
                mainPanel.backgroundColor = .clear
                mainPanel.isReleasedWhenClosed = false
                mainPanel.isMovableByWindowBackground = true
                mainPanel.collectionBehavior = [.canJoinAllSpaces]
                mainPanel.center()
                if let screen = mainPanel.screen {
                    let wX = (screen.frame.width - mainPanel.frame.width) / 2 + screen.frame.minX
                    let wY = (screen.frame.height - mainPanel.frame.height) / 2 + screen.frame.minY
                    mainPanel.setFrameOrigin(NSPoint(x: wX, y: wY))
                }
                mainPanel.makeKeyAndOrderFront(self)
            }
        }
        return false
    }
    
    /// The status item's commands under the Dock icon too, which is there when the status item is out of sight
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return withRecorder { _ in StatusItemController.shared.dockMenu() }
    }

    func openSettingPanel() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI gives the Settings item a private action, so it can only be triggered through the app menu.
        // Look it up by its Cmd+, shortcut instead of a fixed index, which shifts whenever the menu changes.
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let settingsItem = appMenu?.items.first(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        (settingsItem ?? appMenu?.item(at: 2))?.performAction()
    }
    
    class EscPanel: NSPanel {
        override func cancelOperation(_ sender: Any?) {
            self.close()
        }
        override var canBecomeKey: Bool {
            return true
        }
    }
}

func closeMainWindow() {
    for w in NSApp.windows(.mainPanel) { w.close() }
}

/// Main thread. The dashed frame around the recorded area, which a selector puts up before it asks for the start.
func closeAreaOverlay() {
    for w in NSApp.windows(.areaOverlay) { w.close() }
}

/// Closes every window that has a title, except the status item's, the audio documents' and the one with the
/// identifier `except`. Windows that must survive this (the preview, alerts) have no title.
func closeAllWindow(except: NSUserInterfaceItemIdentifier? = nil) {
    for w in NSApp.windows.filter({
        $0.title != "Item-0" && $0.title != ""
        && !$0.title.lowercased().contains(".qma")
        && (except == nil || $0.identifier != except) }) { w.close() }
}

func findNSSplitVIew(view: NSView?) -> NSSplitView? {
    var queue = [NSView]()
    if let root = view { queue.append(root) }
    
    while !queue.isEmpty {
        let current = queue.removeFirst()
        if current is NSSplitView { return current as? NSSplitView }
        for subview in current.subviews { queue.append(subview) }
    }
    return nil
}

func tips(_ message: String, title: String? = nil, id: String, buttonTitle: String = "OK", switchButton: Bool = false, width: Int? = nil, action: (() -> Void)? = nil) {
    let never = AppSettings.dismissedTips
    if !never.contains(id) {
        if switchButton {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: buttonTitle, button2: "Don't remind me again", width: width).runModal()
            if alert == .alertSecondButtonReturn { AppSettings.dismissedTips = never + [id] }
            if alert == .alertFirstButtonReturn { action?() }
        } else {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: "Don't remind me again", button2: buttonTitle, width: width).runModal()
            if alert == .alertFirstButtonReturn { AppSettings.dismissedTips = never + [id] }
            if alert == .alertSecondButtonReturn { action?() }
        }
    }
}

func createAlert(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "", width: Int? = nil) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title.local
    alert.informativeText = message.local
    alert.addButton(withTitle: button1.local)
    if button2 != "" { alert.addButton(withTitle: button2.local) }
    alert.alertStyle = level
    if let width = width {
        alert.accessoryView = NSView(frame: NSMakeRect(0, 0, Double(width), 0))
    }
    return alert
}

func showAlertSyncOnMainThread(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "", width: Int? = nil) -> NSApplication.ModalResponse {
    // Waiting for the main queue on the main thread would never return
    if Thread.isMainThread {
        return createAlert(level: level, title: title, message: message, button1: button1, button2: button2, width: width).runModal()
    }
    var response: NSApplication.ModalResponse = .abort
    let semaphore = DispatchSemaphore(value: 0)
    
    // A run loop block: an alert inside a main queue block would hold up everything queued behind it while it is open
    UserNotice.onMainRunLoop {
        let alert = createAlert(level: level, title: title, message: message, button1: button1, button2: button2, width: width)
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
    var deletingPathExtension: String {
        return (self as NSString).deletingPathExtension
    }
    var pathExtension: String {
        return (self as NSString).pathExtension
    }
    var lastPathComponent: String {
        return (self as NSString).lastPathComponent
    }
    var url: URL { return URL(fileURLWithPath: self) }
}

extension NSMenuItem {
    func performAction() {
        guard let menu else {
            return
        }
        menu.performActionForItem(at: menu.index(of: self))
    }
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
    
    func saveToFile(_ url: URL, type: NSBitmapImageRep.FileType = .png) {
        if let tiffData = self.tiffRepresentation,
           let imageRep = NSBitmapImageRep(data: tiffData) {
            let pngData = imageRep.representation(using: type, properties: [:])
            do {
                try pngData?.write(to: url)
            } catch {
                print("Error saving image: \(error.localizedDescription)")
            }
        }
    }
}

class NNSWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
}

extension utsname {
    static var sMachine: String {
        var utsname = utsname()
        uname(&utsname)
        return withUnsafePointer(to: &utsname.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
    static var isAppleSilicon: Bool {
        sMachine == "arm64"
    }
}
