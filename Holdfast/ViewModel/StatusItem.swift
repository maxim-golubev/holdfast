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
    /// The widest the item has been since it last was idle
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
            if display.kind != shown?.kind { button.image = StatusItemController.image(for: display) }
            // A symbol this system does not have must not leave an empty, unclickable item
            let title = button.image == nil && display.title.isEmpty ? "Holdfast" : display.title
            let text = StatusItemController.attributed(title)
            // The width is set before the text, and never made smaller while there is something to show: an item
            // that is resized for every new text shows the text cut off for a moment and pushes its neighbours about
            if display.kind == .idle {
                heldLength = 0
                item.length = NSStatusItem.variableLength
            } else {
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

    /// Puts the middle of the digits on the menu bar's centre line, a whole pixel step from where AppKit sets them
    private static let titleBaselineOffset: CGFloat = -0.5

    private static func image(for display: StatusDisplay) -> NSImage? {
        if display.kind == .recording { return recordGlyph }
        guard let plain = NSImage(systemSymbolName: display.symbol, accessibilityDescription: nil) else { return nil }
        // Drawn at the size and weight of the text next to it
        let sized = NSImage.SymbolConfiguration(pointSize: titleFont.pointSize, weight: .medium, scale: .medium)
        let symbol = plain.withSymbolConfiguration(sized) ?? plain
        let colour: NSColor
        switch display.tint {
        case .standard:
            symbol.isTemplate = true
            return symbol
        case .red: colour = .systemRed
        case .orange: colour = .systemOrange
        }
        // One colour for every layer of the symbol: a hierarchy of it turns parts of the symbol pale
        return symbol.withSymbolConfiguration(sized.applying(NSImage.SymbolConfiguration(paletteColors: [colour]))) ?? symbol
    }

    /// The recording symbol, drawn to the pixel on a 2x display: a red ring 12.5 pt across with a dot, centred on
    /// the line through the middle of the timer's digits. The SF Symbol of that size is an even number of pixels
    /// tall and so sits half a pixel below the digits; every edge here falls on a pixel boundary instead.
    private static let recordGlyph: NSImage = {
        // The box has the height of the SF Symbols beside it, so the menu bar places it the same way
        let image = NSImage(size: NSSize(width: 13, height: 16), flipped: false) { _ in
            let centre = NSPoint(x: 6.25, y: 7.75)
            NSColor.systemRed.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 5.5, y: centre.y - 5.5, width: 11, height: 11))
            ring.lineWidth = 1.5
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: centre.x - 3.25, y: centre.y - 3.25, width: 6.5, height: 6.5)).fill()
            return true
        }
        image.accessibilityDescription = "Recording".local
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
            let stop = add("Stop Recording".local, symbol: "stop.circle.fill", #selector(stopRecording))
            stop.attributedTitle = NSAttributedString(string: stop.title, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
            stop.image = stop.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            add("", symbol: nil, #selector(togglePause), tag: .pause)
            add("", symbol: nil, #selector(toggleMicrophoneMute), tag: .mute)
            menu.addItem(.separator())
            addStatusLine()
        case .saving:
            addStatusLine()
        case .idle:
            // Shown while a recovery runs
            addStatusLine()
            let separator = NSMenuItem.separator()
            separator.tag = Tag.lineSeparator.rawValue
            menu.addItem(separator)
            add("Open Main Panel".local, symbol: "rectangle.on.rectangle", #selector(openMainPanel))
            menu.addItem(.separator())
            add("Record System Audio".local, symbol: "waveform", #selector(recordSystemAudio))
            add("Record Screen…".local, symbol: "tv.inset.filled", #selector(chooseScreen))
            add("Record Screen Area…".local, symbol: "viewfinder", #selector(chooseArea))
            add("Record Application…".local, symbol: "app", #selector(chooseApplication))
            add("Record Window…".local, symbol: "macwindow", #selector(chooseWindow))
            menu.addItem(.separator())
            add("Settings…".local, symbol: "gearshape", #selector(openSettings))
        }
        // Not next to Stop, where it could be hit by accident; the Dock has its own
        if !forDock, layout != .recording {
            menu.addItem(.separator())
            add("Quit Holdfast".local, symbol: "xmark.circle", #selector(quit))
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
            set(.pause, title: "Resume Recording".local, symbol: "play.circle", enabled: state == .recording)
        } else {
            set(.pause, title: "Pause Recording".local, symbol: "pause.circle", enabled: state == .recording)
        }
        if recorder.isMicrophoneMuted {
            set(.mute, title: "Unmute Microphone".local, symbol: "mic", enabled: recorder.canMuteMicrophone)
        } else {
            set(.mute, title: "Mute Microphone".local, symbol: "mic.slash", enabled: recorder.canMuteMicrophone)
        }
        if let line = menu.item(withTag: Tag.line.rawValue), line.title != display.line { line.title = display.line }
        let lineShown = state != .idle || display.kind == .recovering
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
