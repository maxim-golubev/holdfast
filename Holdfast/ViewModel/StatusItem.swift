//
//  StatusItem.swift
//  Holdfast
//

import AppKit

/// The app's item in the menu bar: a plain `NSStatusItem` whose button shows a symbol and a title
/// (`StatusDisplay`), and whose click opens a menu. The system lays the button out and opens the menu; nothing
/// here measures a width or looks at where a click landed.
///
/// It shows what `RecorderController` is doing and is told of every change through `RecorderEnvironment.app`
/// (`statusChanged` calls `refresh`). While a recording starts or runs a timer refreshes the elapsed time twice a second, and carries
/// out the recording's automatic stop.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    /// Which set of items the menu has. Within one set the items are changed in place; the sets differ in
    /// what is under the pointer, so an open menu is never turned from one into another.
    private enum Layout {
        case recording, saving, idle

        init(_ state: RecordingState) {
            switch state {
            case .starting, .recording: self = .recording
            case .stopping, .finalizing: self = .saving
            case .idle: self = .idle
            }
        }
    }

    /// The items whose text changes while the menu is open
    private enum Tag: Int {
        case pause = 1, mute, line, lineSeparator
    }

    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var timer: Timer?
    private var shown: StatusDisplay?
    private var menuIsOpen = false
    private var menuLayout: Layout?
    /// The widest the item has been since it last was idle or starting. During a recording only the time makes it
    /// wider (the first hour adds digits): its symbols have one width.
    private var heldLength: CGFloat = 0

    private var recorder: RecorderController { RecorderController.shared }

    /// Puts the item into the menu bar. Once, when the app launches.
    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // The symbol stays where it is when the text next to it changes
        item.button?.alignment = .left
        self.item = item
        refresh()
    }

    /// Shows the recorder as it is now. Called for every change of it and of the "showMenubar" setting.
    func refresh() {
        guard let item = item else { return }
        let display = StatusDisplay(recorder.statusInput)
        // Without the menu bar setting the item is only there while there is something to show or to stop
        let visible = AppSettings.showMenubar || display.kind != .idle
        if item.isVisible != visible { item.isVisible = visible }
        runTimer(recorder.streamType != nil)
        if display != shown, let button = item.button {
            if display.kind != shown?.kind { button.image = StatusItemController.image(for: display.kind) }
            // A symbol this system does not have must not leave an empty, unclickable item
            let title = button.image == nil && display.title.isEmpty ? "Holdfast" : display.title
            let text = StatusItemController.attributed(title)
            // The width is set before the text, and never made smaller while there is something to show: an item
            // that is resized for every new text shows the text cut off for a moment and pushes its neighbours about
            if display.kind == .idle {
                heldLength = 0
                item.length = NSStatusItem.variableLength
            } else {
                // "Starting" is there for a moment and is wider than the time: the recording is not held to it
                if shown?.kind == .starting { heldLength = 0 }
                let symbolWidth = button.image?.size.width ?? 0
                let needed = (symbolWidth + (title.isEmpty ? 0 : 5 + text.size().width) + 14).rounded(.up)
                heldLength = max(heldLength, needed)
                if item.length != heldLength { item.length = heldLength }
            }
            button.attributedTitle = text
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.toolTip = display.detail
            button.setAccessibilityLabel(display.accessibilityLabel)
            shown = display
        }
        guard menuIsOpen else { return }
        if Layout(recorder.state) == menuLayout {
            update(menu, display)
        } else {
            // Its commands are no longer the right ones. Closed, not refilled: a click that is on its way must
            // not land on an item that has just taken the place of another
            menu.cancelTracking()
        }
    }

    /// The same commands as the status item's menu, for the Dock icon: there when the status item is out of
    /// sight (a full-screen app, a menu bar with no room left for it).
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        fill(menu, forDock: true)
        return menu
    }

    /// The menu bar's own text style: digits of one width, so the item does not change its size with every
    /// second, colons centred on the digits as in the system clock, and the weight the clock uses.
    private static let titleFont: NSFont = {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kCaseSensitiveLayoutType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kCaseSensitiveLayoutOnSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }()

    private static func attributed(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: titleFont, .baselineOffset: titleBaselineOffset])
    }

    /// Lowers the digits by a whole pixel step on a 2x display from where AppKit sets them. Measured in a 22 pt
    /// menu bar at 2x: the digits of "10:23" cover rows 12–30 of the 44, so their middle is 0.25 pt above the bar's
    /// centre line (`digitsAboveCentre`), which is where the symbol beside them is put.
    private static let titleBaselineOffset: CGFloat = -0.5
    private static let digitsAboveCentre: CGFloat = 0.25

    /// The symbol of a state. Those of a running recording share one width (the widest of them) with the symbol in
    /// the middle, so pausing, muting or a warning neither changes the item's width nor moves the time, and no space
    /// is left after the time when a wider symbol has been shown.
    private static func image(for kind: StatusDisplay.Kind) -> NSImage? {
        guard let image = symbolImage(for: kind) else { return nil }
        return kind.isRunningRecording ? centred(image, width: runningRecordingSymbolWidth) : image
    }

    private static let runningRecordingSymbolWidth: CGFloat = StatusDisplay.Kind.allCases
        .filter { $0.isRunningRecording }
        .compactMap { symbolImage(for: $0)?.size.width }
        .max() ?? 0

    private static func symbolImage(for kind: StatusDisplay.Kind) -> NSImage? {
        if kind == .recording { return recordGlyph }
        guard let plain = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) else { return nil }
        // Drawn at the size and weight of the text next to it
        let sized = NSImage.SymbolConfiguration(pointSize: titleFont.pointSize, weight: .medium, scale: .medium)
        var symbol = plain.withSymbolConfiguration(sized) ?? plain
        switch kind.tint {
        case .standard:
            symbol.isTemplate = true
        case .red, .orange:
            // One colour for every layer of the symbol: a hierarchy of it turns parts of the symbol pale
            let colour: NSColor = kind.tint == .red ? .systemRed : .systemOrange
            symbol = symbol.withSymbolConfiguration(sized.applying(NSImage.SymbolConfiguration(paletteColors: [colour]))) ?? symbol
        }
        return onDigitsLine(symbol)
    }

    /// `image` in the middle of a box `width` wide, moved by whole points: what is drawn on the pixel grid (the record
    /// symbol) stays on it
    private static func centred(_ image: NSImage, width: CGFloat) -> NSImage {
        guard width > image.size.width else { return image }
        let x = ((width - image.size.width) / 2).rounded(.down)
        let boxed = NSImage(size: NSSize(width: width, height: image.size.height), flipped: false) { _ in
            image.draw(in: NSRect(origin: NSPoint(x: x, y: 0), size: image.size))
            return true
        }
        boxed.isTemplate = image.isTemplate
        boxed.accessibilityDescription = image.accessibilityDescription
        return boxed
    }

    /// The symbol in a box of its own size, moved up or down so that the middle of what it draws is on the middle of
    /// the digits. AppKit centres the box, and the ink of SF Symbols at this size sits 0.75 to 1 pt below the box's
    /// centre (measured at 2x: rows 10–35 of the bar for 12–30 of the digits), so a paused, muted or warning
    /// symbol would otherwise sit low next to the time. Measured the same way after the move: within 0.2 px.
    private static func onDigitsLine(_ symbol: NSImage) -> NSImage {
        guard let ink = inkRows(of: symbol) else { return symbol }
        // In points, upwards. The symbol's edges are smooth curves, so it may move by a fraction of a pixel.
        let inkMiddle = symbol.size.height - (ink.top + ink.bottom) / 2
        let raise = symbol.size.height / 2 + digitsAboveCentre - inkMiddle
        let moved = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect.offsetBy(dx: 0, dy: raise))
            return true
        }
        moved.isTemplate = symbol.isTemplate
        return moved
    }

    /// Where what `image` draws begins and ends, in points from the top of its box. Drawn at the screen's scale,
    /// since symbols are fitted to its pixels: each edge is the first or last row with ink, less the part of that row
    /// its coverage leaves empty.
    private static func inkRows(of image: NSImage) -> (top: CGFloat, bottom: CGFloat)? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
        // Before the context is made from it: the context draws at this size in points
        bitmap.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = bitmap.bitmapData else { return nil }
        // Rows of the bitmap go from the top; the coverage of a row is its most opaque pixel
        var coverage = [CGFloat]()
        for row in 0..<height {
            var most: UInt8 = 0
            for column in 0..<width { most = max(most, pixels[row * bitmap.bytesPerRow + column * 4 + 3]) }
            coverage.append(CGFloat(most) / 255)
        }
        guard let top = coverage.firstIndex(where: { $0 > 0.02 }), let bottom = coverage.lastIndex(where: { $0 > 0.02 }) else { return nil }
        return ((CGFloat(top) + 1 - coverage[top]) / scale, (CGFloat(bottom) + coverage[bottom]) / scale)
    }

    /// The recording symbol, drawn to the pixel on a 2x display: a red ring 12.5 pt across with a dot. Its centre is
    /// `digitsAboveCentre` above the centre of its box, so it covers rows 9–33 of the bar, middle 21.5, the middle of
    /// the digits; every edge falls on a pixel boundary.
    private static let recordGlyph: NSImage = {
        // The box has the height of the SF Symbols beside it, so the menu bar places it the same way
        let image = NSImage(size: NSSize(width: 13, height: 16), flipped: false) { _ in
            let centre = NSPoint(x: 6.25, y: 8 + digitsAboveCentre)
            NSColor.systemRed.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 5.5, y: centre.y - 5.5, width: 11, height: 11))
            ring.lineWidth = 1.5
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: centre.x - 3.25, y: centre.y - 3.25, width: 6.5, height: 6.5)).fill()
            return true
        }
        image.accessibilityDescription = "Recording"
        return image
    }()

    private func runTimer(_ wanted: Bool) {
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { StatusItemController.shared.tick() }
            }
            // Also while a menu is open
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let running = timer {
            running.invalidate()
            timer = nil
        }
    }

    private func tick() {
        recorder.stopIfDue()
        refresh()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    /// While a recording starts or runs: Stop first and largest, Pause, Mute, then the status line. While it is
    /// being saved: the status line. Otherwise what starts a recording, the settings and Quit.
    private func fill(_ menu: NSMenu, forDock: Bool = false) {
        let display = StatusDisplay(recorder.statusInput)
        let layout = Layout(recorder.state)
        if !forDock { menuLayout = layout }
        menu.removeAllItems()

        @discardableResult
        func add(_ title: String, symbol: String?, _ action: Selector, tag: Tag? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol = symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if let tag = tag { item.tag = tag.rawValue }
            menu.addItem(item)
            return item
        }
        func addStatusLine() {
            let line = NSMenuItem(title: display.line, action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.tag = Tag.line.rawValue
            menu.addItem(line)
        }

        switch layout {
        case .recording:
            let stop = add("Stop Recording", symbol: "stop.circle.fill", #selector(stopRecording))
            stop.attributedTitle = NSAttributedString(string: stop.title, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
            stop.image = stop.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            add("", symbol: nil, #selector(togglePause), tag: .pause)
            add("", symbol: nil, #selector(toggleMicrophoneMute), tag: .mute)
            menu.addItem(.separator())
            addStatusLine()
        case .saving:
            addStatusLine()
        case .idle:
            // Shown while a recovery or an export runs
            addStatusLine()
            let separator = NSMenuItem.separator()
            separator.tag = Tag.lineSeparator.rawValue
            menu.addItem(separator)
            add("Open Main Panel", symbol: "rectangle.on.rectangle", #selector(openMainPanel))
            menu.addItem(.separator())
            // Nothing can be started while the app waits to quit (`canStart`)
            let starts = [
                add("Record System Audio", symbol: "waveform", #selector(recordSystemAudio)),
                add("Record Screen…", symbol: "tv.inset.filled", #selector(chooseScreen)),
                add("Record Screen Area…", symbol: "viewfinder", #selector(chooseArea)),
                add("Record Application…", symbol: "app", #selector(chooseApplication)),
                add("Record Window…", symbol: "macwindow", #selector(chooseWindow)),
            ]
            starts.forEach { $0.isEnabled = !recorder.quitRequested }
            menu.addItem(.separator())
            add("Settings…", symbol: "gearshape", #selector(openSettings))
        }
        // Not next to Stop, where it could be hit by accident; the Dock has its own
        if !forDock, layout != .recording {
            menu.addItem(.separator())
            add("Quit Holdfast", symbol: "xmark.circle", #selector(quit))
        }
        update(menu, display)
    }

    /// Sets what changes within a layout, on the items that are there: no item is removed or added, so the one
    /// under the pointer stays where it is while the menu is open.
    private func update(_ menu: NSMenu, _ display: StatusDisplay) {
        func set(_ tag: Tag, title: String, symbol: String, enabled: Bool) {
            guard let item = menu.item(withTag: tag.rawValue) else { return }
            if item.title != title {
                item.title = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            if item.isEnabled != enabled { item.isEnabled = enabled }
        }
        func show(_ tag: Tag, _ visible: Bool) {
            guard let item = menu.item(withTag: tag.rawValue), item.isHidden == visible else { return }
            item.isHidden = !visible
        }

        let state = recorder.state
        if recorder.isPaused {
            set(.pause, title: "Resume Recording", symbol: "play.circle", enabled: state == .recording)
        } else {
            set(.pause, title: "Pause Recording", symbol: "pause.circle", enabled: state == .recording)
        }
        if recorder.isMicrophoneMuted {
            set(.mute, title: "Unmute Microphone", symbol: "mic", enabled: recorder.canMuteMicrophone)
        } else {
            set(.mute, title: "Mute Microphone", symbol: "mic.slash", enabled: recorder.canMuteMicrophone)
        }
        if let line = menu.item(withTag: Tag.line.rawValue), line.title != display.line { line.title = display.line }
        let lineShown = display.kind != .idle
        show(.line, lineShown)
        show(.lineSeparator, lineShown)
    }

    // MARK: - Commands

    @objc private func stopRecording() {
        recorder.stop()
    }

    @objc private func togglePause() {
        recorder.togglePause()
    }

    @objc private func toggleMicrophoneMute() {
        recorder.toggleMicrophoneMute()
    }

    @objc private func openMainPanel() {
        AppDelegate.shared.openMainPanel()
    }

    /// The menu may have been open while the recorder left the idle state
    private func start(_ action: (AppDelegate) -> Void) {
        guard recorder.canStart() else { return }
        NSApp.activate(ignoringOtherApps: true)
        action(AppDelegate.shared)
    }

    @objc private func recordSystemAudio() { start { $0.recordSystemAudio() } }
    @objc private func chooseScreen() { start { $0.chooseScreen() } }
    @objc private func chooseArea() { start { $0.chooseArea() } }
    @objc private func chooseApplication() { start { $0.chooseApplication() } }
    @objc private func chooseWindow() { start { $0.chooseWindow() } }

    @objc private func openSettings() {
        closeMainWindow()
        AppDelegate.shared.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
