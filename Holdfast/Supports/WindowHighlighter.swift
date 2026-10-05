//
//  WindowHighlighter.swift
//  Holdfast
//
//  Created by apple on 2024/11/26.
//

import SwiftUI
import ScreenCaptureKit

struct CoverView: View {
    var body: some View {
        Color.clear.overlay { Rectangle().stroke(.blue, lineWidth: 5) }
    }
}

struct HighlightMask: View {
    let app: String
    let title: String
    let windowID: Int
    var appDelegate = AppDelegate.shared
    @State var window: SCWindow?
    @State var display: SCDisplay?
    @State var color: Color = .blue
    @State var showSheet: Bool = false
    @State private var autoStop = 0
    
    var body: some View {
        color
            .opacity(0.2)
            .cornerRadius(10)
            .help("\(app) - \(title)")
            .sheet(isPresented: $showSheet) {
                SelectorBar(autoStop: $autoStop, start: startRecording) {
                    SymbolButton("Cancel", symbol: "xmark.circle.fill", color: .gray, help: "Do not record this window") {
                        showSheet = false
                    }
                }
                .focusable(false)
                .padding(20)
                .fixedSize()
                .onDisappear {
                    if let mask = WindowHighlighter.shared.mask {
                        mask.close()
                    }
                }
            }
            .onClick {
                if let w = WindowHighlighter.shared.getSCWindowWithID(UInt32(windowID)),
                   let d = ScreenContent.getSCDisplayWithMouse() {
                    display = d
                    window = w
                    WindowHighlighter.shared.stopMouseMonitor()
                    showSheet = true
                    return
                }
                color = .red
                withAnimation(.easeInOut(duration: 0.6)) { color = .blue }
            }
    }
    
    func startRecording() {
        closeAllWindow()
        switch WindowHighlighter.shared.mode {
        case .area:
            guard let screen = display, let nsScreen = display?.nsScreen, let frame = window?.frame else { return }
            let onDesktop = CGRectTransform(cgRect: frame)
            // Relative to its screen, as the area selector gives it
            let area = onDesktop.offsetBy(dx: -nsScreen.frame.minX, dy: -nsScreen.frame.minY)
            appDelegate.showAreaOverlay(around: onDesktop, border: 3)
            appDelegate.createCountdownPanel(screen: screen) {
                RecorderController.shared.start(type: .screenarea, display: screen, windows: nil, applications: nil, autoStop: autoStop, area: area)
            }
        case .window:
            if let d = display, let w = window {
                appDelegate.createCountdownPanel(screen: d) {
                    RecorderController.shared.start(type: .window, display: d, windows: [w], applications: nil, autoStop: autoStop)
                }
            }
        }
    }
}

class WindowHighlighter {
    static let shared = WindowHighlighter()
    var mouseMonitor: Any?
    var mouseMonitorL: Any?
    private var keyMonitor: Any?
    var targetWindowID: Int?
    var mask: EscPanel?

    /// What a click on a window picks: the window, recorded as a window, or its frame, recorded as an area
    enum PickMode { case window, area }
    private(set) var mode = PickMode.window

    func registerMouseMonitor(mode: PickMode = .window) {
        closeAllWindow()
        self.mode = mode
        // A run loop block: the tip is modal, and must not hold up the main queue
        UserNotice.onMainRunLoop {
            // The ids are those dismissed tips were stored under
            switch mode {
            case .area: tips("Click on a window to select its area\nor press Esc to cancel.".local, id: "qr.how-to-select.note2")
            case .window: tips("Click the window you want to record\nor press Esc to cancel.".local, id: "qr.how-to-select.note")
            }
            // The tip's alert had the keyboard
            self.makeCoverKey()
        }
        
        for screen in NSScreen.screens {
            let cover = EscPanel(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            cover.contentView = NSHostingView(rootView: CoverView())
            cover.level = .statusBar
            cover.sharingType = .none
            cover.backgroundColor = .clear
            cover.ignoresMouseEvents = true
            cover.isReleasedWhenClosed = false
            cover.collectionBehavior = [.canJoinAllSpaces, .stationary]
            cover.title = "Screen Cover"
            cover.identifier = .screenCover
            cover.orderFront(self)
        }
        makeCoverKey()
        // Esc while one of the app's windows has the keyboard, the picker's own included
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.cancel()
                return nil
            }
        }
        
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in self.updateMask() }
        }
        if mouseMonitorL == nil {
            mouseMonitorL = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
                self.updateMask()
                return event
            }
        }
    }
        
    /// Esc: the picker ends and nothing is chosen
    func cancel() {
        mask?.close()
        stopMouseMonitor()
    }
    
    /// The covers ignore the mouse and are over other applications' windows, so Esc only reaches the picker
    /// while one of its panels has the keyboard: the mask when there is one, a cover otherwise.
    private func makeCoverKey() {
        let covers = NSApp.windows(.screenCover).filter({ $0.isVisible })
        let mouse = NSEvent.mouseLocation
        (covers.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? covers.first)?.makeKey()
    }
    
    /// Main thread. Ends the picker: its covers and its monitors go. The mask stays, a click on it shows its sheet.
    func stopMouseMonitor() {
        for w in NSApp.windows(.screenCover) { w.close() }
        targetWindowID = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = mouseMonitorL {
            NSEvent.removeMonitor(monitor)
            mouseMonitorL = nil
        }
    }
    
    func updateMask() {
        guard let targetWindow = getWindowUnderMouse() else {
            if targetWindowID != nil {
                mask?.close()
                targetWindowID = nil
                makeCoverKey()
            }
            return
        }
        
        if let app = targetWindow["kCGWindowOwnerName"] as? String, app != Bundle.main.appName,
           let windowID = targetWindow["kCGWindowNumber"] as? Int, targetWindowID != windowID {
            mask?.close()
            targetWindowID = windowID
            createMaskWindow(window: targetWindow)
        }
    }
    
    func createMaskWindow(window: [String: Any]) {
        guard let windowID = targetWindowID, let frame = getCGWindowFrame(window: window) else { return }
        let app = window["kCGWindowOwnerName"] as? String ?? ""
        let title = window["kCGWindowName"] as? String ?? ""
        
        mask = EscPanel(contentRect: CGRectTransform(cgRect: frame),
                        styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        let contentView = NSHostingView(rootView: HighlightMask(app: app, title: title, windowID: windowID))
        mask?.contentView = contentView
        mask?.title = "Mask Window"
        mask?.hasShadow = false
        mask?.sharingType = .none
        mask?.backgroundColor = .clear
        mask?.titleVisibility = .hidden
        mask?.isMovableByWindowBackground = false
        mask?.isReleasedWhenClosed = false
        mask?.collectionBehavior = [.canJoinAllSpaces, .transient]
        mask?.setFrame(CGRectTransform(cgRect: frame), display: true)
        mask?.order(.above, relativeTo: windowID)
        mask?.makeKey()
    }
    
    func getWindowUnderMouse() -> [String: Any]? {
        let mousePosition = NSEvent.mouseLocation
        guard let windowList = getAllCGWindows() else { return nil }

        for window in windowList {
            guard let bounds = getCGWindowFrame(window: window) else { continue }
            if CGRectTransform(cgRect: bounds).contains(mousePosition) {
                return window
            }
        }
        return nil
    }
    
    func getAllCGWindows() -> [[String: Any]]? {
        guard var windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements,.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        windowList = windowList.filter({
            !["SystemUIServer", "Window Server"].contains($0["kCGWindowOwnerName"] as? String)
            && $0["kCGWindowAlpha"] as? NSNumber != 0
            && $0["kCGWindowLayer"] as? NSNumber == 0
        })
        
        return windowList
    }
    
    func getSCWindowWithID(_ windowID: UInt32?) -> SCWindow? {
        guard let windowID else { return nil }
        ScreenContent.updateAvailableContentSync()
        let windows = ScreenContent.getWindows()
        return windows.first(where: { $0.windowID == windowID })
    }
    
    func getCGWindowFrame(window: [String: Any]) -> CGRect? {
        guard let boundsDict = window["kCGWindowBounds"] as? [String: CGFloat] else { return nil }
        let bounds = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
        return bounds
    }
    
}

class EscPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        self.close()
        WindowHighlighter.shared.cancel()
    }
    override var canBecomeKey: Bool {
        return true
    }
}

func CGRectTransform(cgRect: CGRect) -> NSRect {
    let x = cgRect.origin.x
    let y = cgRect.origin.y
    let w = cgRect.width
    let h = cgRect.height
    if let main = NSScreen.screens.first(where: { $0.isMainScreen }) {
        return NSRect(x: x, y: main.frame.height - y - h, width: w, height: h)
    }
    return cgRect
}

extension View {
    /// Once per click, when the button is released: `perform` looks the window up, which blocks the main thread
    func onClick(perform: @escaping () -> Void) -> some View {
        gesture(DragGesture(minimumDistance: 0).onEnded { _ in perform() })
    }
}
