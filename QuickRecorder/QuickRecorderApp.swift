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
import CoreMediaIO

let isMacOS12 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 12
let isMacOS14 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14
let isMacOS15 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15
var scPerm = false
let fd = FileManager.default
let ud = UserDefaults.standard
var statusBarItem: NSStatusItem!
var mouseMonitor: Any?
var keyMonitor: Any?
var hideMousePointer = false
var hideScreenMagnifier = false
let updateTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
let mousePointer = NSWindow(contentRect: NSRect(x: -70, y: -70, width: 70, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
let screenMagnifier = NSWindow(contentRect: NSRect(x: -402, y: -402, width: 402, height: 348), styleMask: [.borderless], backing: .buffered, defer: false)
let camWindow = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 200), styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
let deviceWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 200), styleMask: [.fullSizeContentView, .resizable], backing: .buffered, defer: false)
let controlPanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
let countdownPanel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 266, height: 156), styleMask: [.fullSizeContentView], backing: .buffered, defer: false)

@main
struct QuickRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        DocumentGroup(newDocument: qmaPackageHandle()) { file in
            //if SCContext.stream == nil {
                if let fileURL = file.fileURL {
                    qmaPlayerView(document: file.$document, fileURL: fileURL)
                        .frame(minWidth: 400, minHeight: 100, maxHeight: 100)
                        .focusable(false)
                }
            //}
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

class AppDelegate: NSObject, NSApplicationDelegate, SCStreamDelegate, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate  {
    static let shared = AppDelegate()
    var filter: SCContentFilter?
    var isCameraReady = false
    var isPresenterON = false
    var isResizing = false
    var presenterType = "OFF"
    var frameQueue = FixedLengthArray<CMTime>(maxLength: 20)
    private var isMagnifierCapturing = false
    private var pendingMagnifierEvent: NSEvent?
    
    @AppStorage("showOnDock")       var showOnDock: Bool = true
    @AppStorage("showMenubar")      var showMenubar: Bool = false
    @AppStorage("recordMic")        var recordMic: Bool = false
    @AppStorage("remuxAudio")       var remuxAudio: Bool = true
    @AppStorage("recordWinSound")   var recordWinSound: Bool = true
    @AppStorage("recordHDR")        var recordHDR: Bool = false
    @AppStorage("encoder")          var encoder: Encoder = .h265
    @AppStorage("highRes")          var highRes: Int = 2
    @AppStorage("withAlpha")        var withAlpha: Bool = false
    @AppStorage("saveDirectory")    var saveDirectory: String?
    @AppStorage("countdown")        var countdown: Int = 0
    @AppStorage("poSafeDelay")      var poSafeDelay: Int = 1
    @AppStorage("highlightMouse")   var highlightMouse: Bool = false
    @AppStorage("includeMenuBar")   var includeMenuBar: Bool = true
    @AppStorage("hideDesktopFiles") var hideDesktopFiles: Bool = false
    @AppStorage("trimAfterRecord")  var trimAfterRecord: Bool = false
    @AppStorage("miniStatusBar")    var miniStatusBar: Bool = false
    @AppStorage("hideSelf")         var hideSelf: Bool = true
    @AppStorage("preventSleep")     var preventSleep: Bool = true
    @AppStorage("showPreview")      var showPreview: Bool = true
    @AppStorage("background")       var background: BackgroundType = .wallpaper
    @AppStorage("showMouse")        var showMouse: Bool = true
    @AppStorage("frameRate")        var frameRate: Int = 60
    @AppStorage("videoQuality")     var videoQuality: Double = 1.0
    @AppStorage("videoFormat")      var videoFormat: VideoFormat = .mp4
    @AppStorage("audioFormat")      var audioFormat: AudioFormat = .aac
    @AppStorage("audioQuality")     var audioQuality: AudioQuality = .high
    @AppStorage("pixelFormat")      var pixelFormat: PixFormat = .delault
    @AppStorage("hideCCenter")      var hideCCenter: Bool = false
    
    func mousePointerReLocation(event: NSEvent) {
        if event.type == .scrollWheel { return }
        if !highlightMouse || hideMousePointer || SCContext.stream == nil || SCContext.streamType == .window {
            mousePointer.orderOut(nil)
            return
        }
        let mouseLocation = event.locationInWindow
        var windowFrame = mousePointer.frame
        windowFrame.origin = NSPoint(x: mouseLocation.x - windowFrame.width / 2, y: mouseLocation.y - windowFrame.height / 2)
        mousePointer.contentView = NSHostingView(rootView: MousePointerView(event: event))
        mousePointer.setFrameOrigin(windowFrame.origin)
        mousePointer.orderFront(nil)
    }
    
    func screenMagnifierReLocation(event: NSEvent) {
        if !SCContext.isMagnifierEnabled || hideScreenMagnifier { screenMagnifier.orderOut(nil); return }
        // Captures are asynchronous: run one at a time and keep only the latest event that arrived meanwhile
        if isMagnifierCapturing { pendingMagnifierEvent = event; return }
        isMagnifierCapturing = true
        let mouseLocation = event.locationInWindow
        let origin = NSPoint(x: mouseLocation.x - screenMagnifier.frame.width / 2, y: mouseLocation.y - screenMagnifier.frame.height / 2)
        let rect = NSRect(x: mouseLocation.x - 67, y: mouseLocation.y - 58, width: 134, height: 116)
        NSImage.createScreenShot(of: rect) { [self] image in
            isMagnifierCapturing = false
            if let image, SCContext.isMagnifierEnabled, !hideScreenMagnifier {
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
    
    func registerGlobalMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .rightMouseUp, .rightMouseDown, .rightMouseDragged, .leftMouseUp,  .leftMouseDown, .leftMouseDragged, .otherMouseUp, .otherMouseDown, .otherMouseDragged]) { event in
            self.mousePointerReLocation(event: event)
            self.screenMagnifierReLocation(event: event)
        }
    }
        
    func stopGlobalMouseMonitor() {
        mousePointer.orderOut(nil)
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor); mouseMonitor = nil }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stops a running recording and waits for its video file to be closed; a no-op when nothing is recorded
        SCContext.stopRecording()
        if SCContext.finishing.wait(timeout: .now()) == .success { return .terminateNow }
        // An audio mix or a conversion is still running, for this recording or an earlier one. Quitting now would leave
        // the recording under its temporary name with unmixed audio, so the app quits when that work is done.
        SCContext.finishing.notify(queue: .main) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if SCContext.stream != nil { SCContext.stopRecording() }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if SCContext.trimingList.contains(url) { continue }
            createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, random: true, only: false)
            closeMainWindow()
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        scPerm = SCContext.updateAvailableContentSync() != nil
        
        let process = NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        if process.count > 1 {
            DispatchQueue.main.async {
                let button = createAlert(title: "QuickRecorder is Running".local, message: "Please do not run multiple instances!".local, button1: "Quit".local).runModal()
                if button == .alertFirstButtonReturn { NSApp.terminate(self) }
            }
        }
        
        lazy var userDesktop = (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true) as [String]).first!
        
        ud.register( // default defaults (used if not set)
            defaults: [
                "audioFormat": AudioFormat.aac.rawValue,
                "audioQuality": AudioQuality.high.rawValue,
                "background": BackgroundType.wallpaper.rawValue,
                "frameRate": 60,
                "highRes": 2,
                "hideSelf": true,
                "highlightMouse" : false,
                "hideDesktopFiles": false,
                "includeMenuBar": true,
                "videoQuality": 1.0,
                "countdown": 0,
                "videoFormat": VideoFormat.mp4.rawValue,
                "pixelFormat": PixFormat.delault.rawValue,
                "encoder": Encoder.h264.rawValue,
                "poSafeDelay": 1,
                "saveDirectory": userDesktop as NSString,
                "showMouse": true,
                "recordMic": false,
                "remuxAudio": true,
                "recordWinSound": true,
                "trimAfterRecord": false,
                "showOnDock": true,
                "showMenubar": false,
                "recordHDR": false,
                "preventSleep": true,
                "showPreview": true,
                "savedArea": [String: [String: CGFloat]]()
            ]
        )
        
        if highRes == 0 { highRes = 2 }
        if showOnDock { NSApp.setActivationPolicy(.regular) }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error { print("Notification authorization denied: \(error.localizedDescription)") }
        }
        
        var allow : UInt32 = 1
        let dataSize : UInt32 = 4
        let zero : UInt32 = 0
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, zero, nil, dataSize, &allow)

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarItem.button?.image = NSImage()

        mousePointer.title = "Mouse Pointer".local
        mousePointer.level = .screenSaver
        mousePointer.ignoresMouseEvents = true
        mousePointer.isReleasedWhenClosed = false
        mousePointer.backgroundColor = NSColor.clear
        
        screenMagnifier.title = "Screen Magnifier".local
        screenMagnifier.level = .floating
        screenMagnifier.ignoresMouseEvents = true
        screenMagnifier.isReleasedWhenClosed = false
        screenMagnifier.backgroundColor = NSColor.clear
        
        camWindow.title = "Camera Overlayer".local
        camWindow.level = .floating
        camWindow.isReleasedWhenClosed = false
        camWindow.isMovableByWindowBackground = true
        camWindow.backgroundColor = NSColor.clear
        camWindow.collectionBehavior = [.canJoinAllSpaces]
        
        countdownPanel.title = "Countdown Panel".local
        countdownPanel.level = .floating
        countdownPanel.isReleasedWhenClosed = false
        countdownPanel.isMovableByWindowBackground = false
        countdownPanel.backgroundColor = NSColor.clear
        
        deviceWindow.title = "iDevice Overlayer".local
        deviceWindow.level = .floating
        deviceWindow.isReleasedWhenClosed = false
        deviceWindow.isMovableByWindowBackground = true
        deviceWindow.backgroundColor = NSColor.clear
        
        controlPanel.title = "Recording Controller".local
        controlPanel.level = .floating
        controlPanel.titleVisibility = .hidden
        controlPanel.backgroundColor = NSColor.clear
        controlPanel.isReleasedWhenClosed = false
        controlPanel.titlebarAppearsTransparent = true
        controlPanel.isMovableByWindowBackground = true
        
        previewWindow.level = .statusBar
        previewWindow.titlebarAppearsTransparent = true
        previewWindow.titleVisibility = .hidden
        previewWindow.isReleasedWhenClosed = false
        previewWindow.backgroundColor = .clear
        
        KeyboardShortcuts.onKeyDown(for: .showPanel) {
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            if SCContext.stream == nil { NSApp.activate(ignoringOtherApps: true) }
        }
        KeyboardShortcuts.onKeyDown(for: .saveFrame) { if SCContext.stream != nil { SCContext.saveFrame = true }}
        KeyboardShortcuts.onKeyDown(for: .screenMagnifier) { if SCContext.stream != nil { SCContext.isMagnifierEnabled.toggle() }}
        KeyboardShortcuts.onKeyDown(for: .stop) { if SCContext.stream != nil { SCContext.stopRecording() }}
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { if SCContext.stream != nil { SCContext.pauseRecording() }}
        KeyboardShortcuts.onKeyDown(for: .startWithAudio) {[self] in
            if SCContext.streamType != nil { return }
            closeAllWindow()
            prepRecord(type: "audio", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
        }
        KeyboardShortcuts.onKeyDown(for: .startWithScreen) {[self] in
            if SCContext.stream != nil { return }
            closeAllWindow()
            prepRecord(type: "display", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)
        }
        KeyboardShortcuts.onKeyDown(for: .startWithArea) {[self] in
            if SCContext.stream != nil { return }
            closeAllWindow()
            showAreaSelector(size: NSSize(width: 600, height: 450))
        }
        KeyboardShortcuts.onKeyDown(for: .startWithWindow) { [self] in
            if SCContext.stream != nil { return }
            closeAllWindow()
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            if let pid = frontmostApp?.processIdentifier {
                guard let scWindow = SCContext.getWindows().first(where: { $0.owningApplication?.processID == pid && $0.title != "" && $0.isOnScreen }) else { return }
                prepRecord(type: "window", screens: SCContext.getSCDisplayWithMouse(), windows: [scWindow], applications: nil, fastStart: true)
                return
            }
        }
        updateStatusBar()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        closeAllWindow()
        if showOnDock { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SCContext.stream == nil {
            let w1 = NSApp.windows.filter({ !$0.title.contains("Item-0") && !$0.title.isEmpty && $0.isVisible })
            let w2 = w1.filter({ !$0.title.contains(".qma") })
            if (!w1.isEmpty && w2.isEmpty) || w1.isEmpty {
                let offset = (!showOnDock && !showMenubar) ? 127 : 0
                let width = 928
                let mainPanel = EscPanel(contentRect: NSRect(x: 0, y: 0, width: width + offset, height: 100), styleMask: [.fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
                mainPanel.contentView = NSHostingView(rootView: ContentView())
                mainPanel.title = "QuickRecorder".local
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
                PopoverState.shared.isShowing = false
            }
        }
        return false
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
    for w in NSApp.windows.filter({ $0.title == "QuickRecorder".local }) {
        w.close()
    }
}

func closeAllWindow(except: String = "") {
    for w in NSApp.windows.filter({
        $0.title != "Item-0" && $0.title != ""
        && !$0.title.lowercased().contains(".qma")
        && !$0.title.contains(except) }) { w.close() }
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

func getStatusBarWidth() -> CGFloat {
    @AppStorage("miniStatusBar") var miniStatusBar: Bool = false
    var width = 158.0
    switch SCContext.streamType {
    case nil: width = miniStatusBar ? 36.0 : 36.0
    case .idevice: width = miniStatusBar ? 68.0 : 138.0
    case .systemaudio: width = miniStatusBar ? 68.0 : 114.0
    default: width = miniStatusBar ? 78.0 : 158.0
    }
    return width
}

func process(path: String, arguments: [String]) -> String? {
    let task = Process()
    task.launchPath = path
    task.arguments = arguments
    task.standardError = Pipe()
    
    let outputPipe = Pipe()
    defer {
        outputPipe.fileHandleForReading.closeFile()
    }
    task.standardOutput = outputPipe
    
    do {
        try task.run()
    } catch let error {
        print("\(error.localizedDescription)")
        return nil
    }
    
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: outputData, as: UTF8.self)
    
    if output.isEmpty {
        return nil
    }
    
    return output.trimmingCharacters(in: .newlines)
}

func tips(_ message: String, title: String? = nil, id: String, buttonTitle: String = "OK", switchButton: Bool = false, width: Int? = nil, action: (() -> Void)? = nil) {
    let never = (ud.object(forKey: "neverRemindMe") as? [String]) ?? []
    if !never.contains(id) {
        if switchButton {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: buttonTitle, button2: "Don't remind me again", width: width).runModal()
            if alert == .alertSecondButtonReturn { ud.setValue(never + [id], forKey: "neverRemindMe") }
            if alert == .alertFirstButtonReturn { action?() }
        } else {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: "Don't remind me again", button2: buttonTitle, width: width).runModal()
            if alert == .alertFirstButtonReturn { ud.setValue(never + [id], forKey: "neverRemindMe") }
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
    var response: NSApplication.ModalResponse = .abort
    let semaphore = DispatchSemaphore(value: 0)
    
    DispatchQueue.main.async {
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
        guard let content = SCContext.availableContent,
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

struct FixedLengthArray<T> {
    private var array: [T] = []
    private let maxLength: Int

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    mutating func append(_ element: T) {
        if array.count >= maxLength {
            array.removeFirst()
        }
        array.append(element)
    }

    func getArray() -> [T] {
        return array
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

enum AudioQuality: Int { case normal = 128, good = 192, high = 256, extreme = 320 }

enum AudioFormat: String { case aac, alac, flac, opus, mp3 }

enum VideoFormat: String { case mov, mp4 }

enum PixFormat: String { case delault, yuv420p8v, yuv420p8f, yuv420p10v, yuv420p10f, bgra32 }

enum ColSpace: String { case delault, srgb, p3, bt709, bt2020 }

enum Encoder: String { case h264, h265 }

enum StreamType: Int { case screen, window, windows, application, screenarea, systemaudio, idevice, camera }

enum BackgroundType: String { case wallpaper, clear, black, white, red, green, yellow, orange, gray, blue, custom }
