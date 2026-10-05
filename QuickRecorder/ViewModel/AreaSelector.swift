//
//  AreaSelector.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/20.
//

import SwiftUI
import ScreenCaptureKit
import Quartz

struct DashWindow: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                        .padding(2)
                        .foregroundColor(.blue.opacity(0.5))
                )
        }
    }
}

struct resizeView: View {
    private enum Field: Int, Hashable { case width, height }
    @FocusState private var focusedField: Field?
    
    @AppStorage(AppSettings.$areaWidth)  private var areaWidth: Int
    @AppStorage(AppSettings.$areaHeight) private var areaHeight: Int
    @AppStorage(AppSettings.$highRes)    private var highRes: Int
    
    var appDelegate = AppDelegate.shared
    let screen: SCDisplay
    
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 10) {
            GridRow {
                Text("Area Size:")
                HStack(spacing: 4) {
                    TextField("Width", value: $areaWidth, format: .number.grouping(.never))
                        .frame(width: 60)
                        .focused($focusedField, equals: .width)
                        .onChange(of: areaWidth) { _, newValue in
                            if !appDelegate.isResizing {
                                areaWidth = min(max(newValue, 1), screen.width)
                                resize()
                            }
                        }
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
                    TextField("Height", value: $areaHeight, format: .number.grouping(.never))
                        .frame(width: 60)
                        .focused($focusedField, equals: .height)
                        .onChange(of: areaHeight) { _, newValue in
                            if !appDelegate.isResizing {
                                areaHeight = min(max(newValue, 1), screen.height)
                                resize()
                            }
                        }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            GridRow {
                Text("Output Size:")
                let scale = AppSettings.recordsPixels(highRes) ? Int(screen.nsScreen?.backingScaleFactor ?? 1) : 1
                Text("\(areaWidth * scale) x \(areaHeight * scale)")
            }
        }.onAppear{ focusedField = .width }
    }
    
    func resize() {
        closeAllWindow(except: .areaPanel)
        AppDelegate.shared.showAreaSelector(size: NSSize(width: areaWidth, height: areaHeight), noPanel: true)
    }
}

struct AreaSelector: View {
    @State private var resizePopoverShowing = false
    @State private var autoStop = 0
    @State private var nsWindow: NSWindow?
    
    let screen: SCDisplay
    var appDelegate = AppDelegate.shared
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                nsWindow?.close()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close the area selector")
            .accessibilityLabel("Close")
            SelectorBar(autoStop: $autoStop, start: startRecording) {
                SymbolButton(title: "Window Area", help: "Take the area from a window by clicking it") {
                    nsWindow?.close()
                    for w in NSApp.windows(.areaSelector) { w.close() }
                    appDelegate.stopGlobalMouseMonitor()
                    WindowHighlighter.shared.registerMouseMonitor(mode: 2)
                } icon: {
                    ZStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Image("window.select")
                            .resizable().scaledToFit()
                            .frame(width: 27)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                SymbolButton("Resize", symbol: "viewfinder.circle.fill", color: .blue, help: "Type the size of the area") {
                    resizePopoverShowing = true
                }
                .sheet(isPresented: $resizePopoverShowing) {
                    HStack(spacing: 10) {
                        SymbolButton("Back", symbol: "arrow.uturn.backward.circle.fill", color: .secondary, help: "Back to the area selector") {
                            resizePopoverShowing = false
                        }
                        resizeView(screen: screen)
                    }.padding()
                }
            }
        }
        .padding(12)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .focusable(false)
        .background(WindowAccessor(onWindowOpen: { w in nsWindow = w }, onWindowClose: {
            DispatchQueue.main.async {
                for w in NSApp.windows(.areaSelector) { w.close() }
                if let monitor = keyMonitor {
                    NSEvent.removeMonitor(monitor)
                    keyMonitor = nil
                }
                appDelegate.stopGlobalMouseMonitor()
            }
        }))
    }
    
    func startRecording() {
        guard let area = ScreenContent.screenArea, let nsScreen = screen.nsScreen else { return }
        closeAllWindow()
        appDelegate.stopGlobalMouseMonitor()
        // The dashed frame lies just outside the recorded area
        let border: CGFloat = 4
        let frame = NSRect(x: Int(area.origin.x + nsScreen.frame.minX - border),
                           y: Int(area.origin.y + nsScreen.frame.minY - border),
                           width: Int(area.width + 2 * border), height: Int(area.height + 2 * border))
        let window = NSWindow(contentRect: frame, styleMask: [.fullSizeContentView], backing: .buffered, defer: false)
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.title = "Area Overlayer".local
        window.identifier = .areaOverlay
        window.backgroundColor = NSColor.clear
        window.contentView = NSHostingView(rootView: DashWindow())
        window.orderFront(self)
        appDelegate.createCountdownPanel(screen: screen) {
            RecorderController.shared.start(type: "area", screens: screen, windows: nil, applications: nil, autoStop: autoStop)
        }
    }
}

class ScreenshotOverlayView: NSView {
    var selectionRect: NSRect? {
        didSet {
            updateMaskLayer()
            updateSelectionLayer()
        }
    }
    var initialLocation: NSPoint?
    var dragIng: Bool = false
    var activeHandle: ResizeHandle = .none
    var lastMouseLocation: NSPoint?
    var maxFrame: NSRect?
    var size: NSSize
    var force: Bool

    let controlPointSize: CGFloat = 10.0
    let controlPointColor: NSColor = NSColor.systemYellow

    private var maskLayer: CAShapeLayer?
    private var selectionLayer: CAShapeLayer?
    private var controlPointLayers: [CAShapeLayer] = []

    init(frame: CGRect, size: NSSize, force: Bool) {
        self.size = size
        self.force = force
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        var selection = NSRect(x: (self.frame.width - size.width) / 2, y: (self.frame.height - size.height) / 2, width: size.width, height: size.height)
        if !force, let name = self.window?.screen?.localizedName, let saved = ScreenContent.savedArea(forScreen: name) {
            selection = saved
        }
        selectionRect = selection
        if self.window != nil {
            AppSettings.areaWidth = Int(selection.width)
            AppSettings.areaHeight = Int(selection.height)
            ScreenContent.screenArea = selection
        }
        updateMaskLayer()
        updateSelectionLayer()
        setupControlPoints()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        maxFrame = dirtyRect
    }

     private func updateMaskLayer() {
        maskLayer?.removeFromSuperlayer()

        guard let rect = selectionRect else { return }
         
         let path = CGMutablePath()
         path.addRect(bounds)
         path.addRect(rect)

         let mask = CAShapeLayer()
         mask.path = path
         mask.fillRule = .evenOdd
         mask.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
         self.layer?.addSublayer(mask)
         maskLayer = mask
     }


    private func updateSelectionLayer() {
        selectionLayer?.removeFromSuperlayer()
        controlPointLayers.forEach{
           $0.removeFromSuperlayer()
        }
        controlPointLayers.removeAll()
        
        guard let rect = selectionRect else { return }
    
        let path = CGPath(rect: rect, transform: nil)
    
        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path
        shapeLayer.fillColor = NSColor.init(white: 1, alpha: 0.01).cgColor
        shapeLayer.strokeColor = NSColor.white.cgColor
        shapeLayer.lineWidth = 4.0
        shapeLayer.lineDashPattern = [4,4]
    
        self.layer?.addSublayer(shapeLayer)
        self.selectionLayer = shapeLayer
    
        setupControlPoints()
    }
    
    private func setupControlPoints() {
      guard let rect = selectionRect else { return }
        
      for handle in ResizeHandle.allCases {
        if let point = controlPointForHandle(handle, inRect: rect) {
             let controlPointRect = NSRect(origin: point, size: CGSize(width: controlPointSize, height: controlPointSize))
              let controlPointPath = CGPath(ellipseIn: controlPointRect, transform: nil)
              
              let controlLayer = CAShapeLayer()
              controlLayer.path = controlPointPath
              controlLayer.fillColor = controlPointColor.cgColor
            
             layer?.addSublayer(controlLayer)
             controlPointLayers.append(controlLayer)
        }
      }
    }

    func handleForPoint(_ point: NSPoint) -> ResizeHandle {
        guard let rect = selectionRect else { return .none }

        for handle in ResizeHandle.allCases {
            if let controlPoint = controlPointForHandle(handle, inRect: rect), NSRect(origin: controlPoint, size: CGSize(width: controlPointSize, height: controlPointSize)).contains(point) {
                return handle
            }
        }
        return .none
    }

    func controlPointForHandle(_ handle: ResizeHandle, inRect rect: NSRect) -> NSPoint? {
        switch handle {
        case .topLeft:
            return NSPoint(x: rect.minX - controlPointSize / 2 - 1, y: rect.maxY - controlPointSize / 2 + 1)
        case .top:
            return NSPoint(x: rect.midX - controlPointSize / 2, y: rect.maxY - controlPointSize / 2 + 1)
        case .topRight:
            return NSPoint(x: rect.maxX - controlPointSize / 2 + 1, y: rect.maxY - controlPointSize / 2 + 1)
        case .right:
            return NSPoint(x: rect.maxX - controlPointSize / 2 + 1, y: rect.midY - controlPointSize / 2)
        case .bottomRight:
            return NSPoint(x: rect.maxX - controlPointSize / 2 + 1, y: rect.minY - controlPointSize / 2 - 1)
        case .bottom:
            return NSPoint(x: rect.midX - controlPointSize / 2, y: rect.minY - controlPointSize / 2 - 1)
        case .bottomLeft:
            return NSPoint(x: rect.minX - controlPointSize / 2 - 1, y: rect.minY - controlPointSize / 2 - 1)
        case .left:
            return NSPoint(x: rect.minX - controlPointSize / 2 - 1, y: rect.midY - controlPointSize / 2)
        case .none:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        initialLocation = location
        lastMouseLocation = location
        activeHandle = handleForPoint(location)
        if let rect = selectionRect, NSPointInRect(location, rect) { dragIng = true }
        AppDelegate.shared.isResizing = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var initialLocation = initialLocation else { return }
        let currentLocation = convert(event.locationInWindow, from: nil)
        if activeHandle != .none {

            // Calculate new rectangle size and position
            var newRect = selectionRect ?? CGRect.zero

            // Get last mouse location
            let lastLocation = lastMouseLocation ?? currentLocation

            let deltaX = currentLocation.x - lastLocation.x
            let deltaY = currentLocation.y - lastLocation.y

            switch activeHandle {
            case .topLeft:
                newRect.origin.x = min(newRect.origin.x + newRect.size.width - 20, newRect.origin.x + deltaX)
                newRect.size.width = max(20, newRect.size.width - deltaX)
                newRect.size.height = max(20, newRect.size.height + deltaY)
            case .top:
                newRect.size.height = max(20, newRect.size.height + deltaY)
            case .topRight:
                newRect.size.width = max(20, newRect.size.width + deltaX)
                newRect.size.height = max(20, newRect.size.height + deltaY)
            case .right:
                newRect.size.width = max(20, newRect.size.width + deltaX)
            case .bottomRight:
                newRect.origin.y = min(newRect.origin.y + newRect.size.height - 20, newRect.origin.y + deltaY)
                newRect.size.width = max(20, newRect.size.width + deltaX)
                newRect.size.height = max(20, newRect.size.height - deltaY)
            case .bottom:
                newRect.origin.y = min(newRect.origin.y + newRect.size.height - 20, newRect.origin.y + deltaY)
                newRect.size.height = max(20, newRect.size.height - deltaY)
            case .bottomLeft:
                newRect.origin.y = min(newRect.origin.y + newRect.size.height - 20, newRect.origin.y + deltaY)
                newRect.origin.x = min(newRect.origin.x + newRect.size.width - 20, newRect.origin.x + deltaX)
                newRect.size.width = max(20, newRect.size.width - deltaX)
                newRect.size.height = max(20, newRect.size.height - deltaY)
            case .left:
                newRect.origin.x = min(newRect.origin.x + newRect.size.width - 20, newRect.origin.x + deltaX)
                newRect.size.width = max(20, newRect.size.width - deltaX)
            default:
                break
            }
            self.selectionRect = newRect
            initialLocation = currentLocation // Update initial location for continuous dragging
            lastMouseLocation = currentLocation // Update last mouse location
            if let selection = selectionRect {
                AppSettings.areaWidth = Int(selection.width)
                AppSettings.areaHeight = Int(selection.height)
            }
        } else {
            if dragIng {
                dragIng = true
                // How far the pointer moved
                let deltaX = currentLocation.x - initialLocation.x
                let deltaY = currentLocation.y - initialLocation.y

                // Move the rectangle, keeping it inside the view
                if var moved = self.selectionRect {
                    moved.origin.x = min(max(0.0, moved.origin.x + deltaX), self.frame.width - moved.width)
                    moved.origin.y = min(max(0.0, moved.origin.y + deltaY), self.frame.height - moved.height)
                    self.selectionRect = moved
                }
                initialLocation = currentLocation
            } else {
                //dragIng = false
                // Draw a new rectangle
                guard let maxFrame = maxFrame else { return }
                let origin = NSPoint(x: max(maxFrame.origin.x, min(initialLocation.x, currentLocation.x)), y: max(maxFrame.origin.y, min(initialLocation.y, currentLocation.y)))
                var maxH = abs(currentLocation.y - initialLocation.y)
                var maxW = abs(currentLocation.x - initialLocation.x)
                if currentLocation.y < maxFrame.origin.y { maxH = initialLocation.y }
                if currentLocation.x < maxFrame.origin.x { maxW = initialLocation.x }
                let size = NSSize(width: maxW, height: maxH)
                self.selectionRect = NSIntersectionRect(maxFrame, NSRect(origin: origin, size: size))
                if let selection = selectionRect {
                    AppSettings.areaWidth = Int(selection.width)
                    AppSettings.areaHeight = Int(selection.height)
                }
                //initialLocation = currentLocation
            }
            self.initialLocation = initialLocation
        }
        lastMouseLocation = currentLocation
    }

    override func mouseUp(with event: NSEvent) {
        initialLocation = nil
        activeHandle = .none
        dragIng = false
        AppDelegate.shared.isResizing = false
        if let rect = selectionRect {
            ScreenContent.screenArea = rect
        }
    }
}

class ScreenshotWindow: NSPanel {
    
    init(contentRect: NSRect, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool, size: NSSize, force: Bool = false) {
        let overlayView = ScreenshotOverlayView(frame: contentRect, size:size, force: force)
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: bufferingType, defer: flag)
        self.isOpaque = false
        self.hasShadow = false
        self.level = .statusBar
        self.backgroundColor = NSColor.clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.contentView = overlayView
        
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.keyDown, handler: myKeyDownEvent)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func myKeyDownEvent(event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 && !event.isARepeat {
            self.close()
            for w in NSApp.windows(.areaPanel) { w.close() }
            AppDelegate.shared.stopGlobalMouseMonitor()
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            return nil
        }
        return event
    }
}

enum ResizeHandle: CaseIterable {
    case none
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    
    static var allCases: [ResizeHandle] {
        return [.none, .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
    }
}
