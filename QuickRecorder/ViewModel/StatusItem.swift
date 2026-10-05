//
//  StatusItem.swift
//  QuickRecorder
//

import AppKit

/// The app's item in the menu bar: a plain `NSStatusItem` whose button shows a symbol and a title
/// (`StatusDisplay`), and whose click opens a menu. The system lays the button out and opens the menu; nothing
/// here measures a width or looks at where a click landed.
///
/// It shows what `RecorderController` is doing and is told of every change through `RecorderEnvironment.app`
/// (`refresh`). While a recording starts or runs a timer refreshes the elapsed time twice a second, and carries
/// out the recording's automatic stop.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    /// What the open menu was filled from. It is filled again when one of these changes while it is open.
    private struct MenuContents: Equatable {
        let state: RecordingState
        let isPaused: Bool
        let isMicrophoneMuted: Bool
        let canMuteMicrophone: Bool
        let line: String
    }

    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var timer: Timer?
    private var shown: StatusDisplay?
    private var menuIsOpen = false
    private var menuContents: MenuContents?

    private var recorder: RecorderController { RecorderController.shared }

    /// Puts the item into the menu bar. Once, when the app launches.
    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // Digits of one width, so the item does not change its size with every second
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
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
            let title = button.image == nil && display.title.isEmpty ? "QuickRecorder" : display.title
            button.title = title
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.toolTip = display.detail
            button.setAccessibilityLabel(display.accessibilityLabel)
            shown = display
        }
        if menuIsOpen, contents(display) != menuContents { fill(menu) }
    }

    /// The same commands as the status item's menu, for the Dock icon: there when the status item is out of
    /// sight (a full-screen app, a menu bar with no room left for it).
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        fill(menu, forDock: true)
        return menu
    }

    private static func image(for display: StatusDisplay) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: display.symbol, accessibilityDescription: nil) else { return nil }
        let colour: NSColor
        switch display.tint {
        case .standard:
            symbol.isTemplate = true
            return symbol
        case .red: colour = .systemRed
        case .orange: colour = .systemOrange
        }
        // One colour for every layer of the symbol: a hierarchy of it turns parts of the symbol pale
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [colour])) ?? symbol
    }

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
        recorder.stopIfDue(at: Date.now)
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

    private func contents(_ display: StatusDisplay) -> MenuContents {
        return MenuContents(state: recorder.state, isPaused: recorder.isPaused, isMicrophoneMuted: recorder.isMicrophoneMuted,
                            canMuteMicrophone: recorder.canMuteMicrophone, line: display.line)
    }

    /// While a recording starts or runs: Stop first and largest, Pause, Mute, then the status line. While it is
    /// being saved: the status line. Otherwise what starts a recording, the settings and Quit.
    private func fill(_ menu: NSMenu, forDock: Bool = false) {
        let display = StatusDisplay(recorder.statusInput)
        if !forDock { menuContents = contents(display) }
        menu.removeAllItems()

        @discardableResult
        func add(_ title: String, symbol: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
            return item
        }
        func addStatusLine() {
            let line = NSMenuItem(title: display.line, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }

        let state = recorder.state
        switch state {
        case .starting, .recording:
            let stop = add("Stop Recording".local, symbol: "stop.circle.fill", #selector(stopRecording))
            stop.attributedTitle = NSAttributedString(string: stop.title, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
            stop.image = stop.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            if recorder.isPaused {
                add("Resume Recording".local, symbol: "play.circle", #selector(togglePause), enabled: state == .recording)
            } else {
                add("Pause Recording".local, symbol: "pause.circle", #selector(togglePause), enabled: state == .recording)
            }
            if recorder.isMicrophoneMuted {
                add("Unmute Microphone".local, symbol: "mic", #selector(toggleMicrophoneMute), enabled: recorder.canMuteMicrophone)
            } else {
                add("Mute Microphone".local, symbol: "mic.slash", #selector(toggleMicrophoneMute), enabled: recorder.canMuteMicrophone)
            }
            menu.addItem(.separator())
            addStatusLine()
        case .stopping, .finalizing:
            addStatusLine()
        case .idle:
            if display.kind == .recovering {
                addStatusLine()
                menu.addItem(.separator())
            }
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
        if !forDock, state != .starting, state != .recording {
            menu.addItem(.separator())
            add("Quit QuickRecorder".local, symbol: "xmark.circle", #selector(quit))
        }
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
        _ = AppDelegate.shared.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        NSApp.activate(ignoringOtherApps: true)
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
        AppDelegate.shared.openSettingPanel()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
