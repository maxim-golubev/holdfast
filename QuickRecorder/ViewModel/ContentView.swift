//
//  ContentView.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// The main panel: what to record, the microphone, Settings. Shown as a floating panel that is as large as
/// this view asks for (`AppDelegate.showMainPanel`).
struct ContentView: View {
    @AppStorage(AppSettings.$recordMic) private var recordMic: Bool
    @AppStorage(AppSettings.$showOnDock) private var showOnDock: Bool
    @AppStorage(AppSettings.$showMenubar) private var showMenubar: Bool

    var appDelegate = AppDelegate.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                tile("System Audio", "waveform", help: "Record what the Mac plays, without video") { appDelegate.recordSystemAudio() }
                tile("Screen", "tv.inset.filled", help: "Choose a screen to record") { appDelegate.chooseScreen() }
                tile("Screen Area", "viewfinder", help: "Choose a part of the screen to record") { appDelegate.chooseArea() }
                tile("Application", "app", help: "Choose one or more applications to record") { appDelegate.chooseApplication() }
                tile("Window", "macwindow", help: "Choose one or more windows to record") { appDelegate.chooseWindow() }
            }
            Divider()
            HStack(spacing: 8) {
                MicToggle().toggleStyle(.checkbox)
                MicPicker()
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .disabled(!recordMic)
                Spacer(minLength: 16)
                Button {
                    closeMainWindow()
                    appDelegate.openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .help("Open the settings window")
                // Without a Dock icon and a menu bar item there is no other way to quit
                if !showOnDock && !showMenubar {
                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit", systemImage: "xmark.circle")
                    }
                    .help("Quit QuickRecorder")
                }
                Button("Close") { closeMainWindow() }
                    .help("Close this panel (Esc)")
            }
        }
        .padding(16)
        .fixedSize()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.controlActiveState, .active)
    }

    private func tile(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .frame(height: 38)
                Text(title)
            }
        }
        .buttonStyle(TileButtonStyle())
        .help(help)
        .accessibilityLabel("Record \(title)")
    }
}

/// A large square button of the main panel, tinted under the pointer
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.vertical, 10)
                .frame(minWidth: 104)
                .background(Color.primary.opacity(configuration.isPressed ? 0.25 : (isHovered ? 0.12 : 0)), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { isHovered = $0 }
        }
    }
}

// The running countdown, kept outside the view so a pending start can be cancelled from anywhere
private var countdownTimer: Timer?

struct CountdownView: View {
    @State var countdownValue: Int = 00
    var atEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("\(countdownValue)")
                .font(.system(size: 72))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Recording starts in \(countdownValue) seconds")
            Button {
                AppDelegate.shared.cancelCountdown()
            } label: {
                Text("Cancel")
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel the recording that is about to start")
        }
        .foregroundStyle(.white)
        .frame(width: 120, height: 120)
        .background(Color.mypurple.environment(\.colorScheme, .dark))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear{
            countdownTimer?.invalidate()
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                // The panel is the countdown: once it is closed, by whatever closed it, nothing is started
                guard countdownPanel.isVisible else {
                    timer.invalidate()
                    if countdownTimer === timer { countdownTimer = nil }
                    return
                }
                if countdownValue > 1 {
                    countdownValue -= 1
                } else {
                    timer.invalidate()
                    countdownTimer = nil
                    countdownPanel.close()
                    atEnd()
                }
            }
        }
    }
}


extension AppDelegate {
    // What the tiles of the main panel and the items of the status item's menu do

    func recordSystemAudio() {
        guard let display = ScreenContent.getSCDisplayWithMouse() else { return }
        closeMainWindow()
        createCountdownPanel(screen: display) {
            withRecorder { $0.start(type: "audio", screens: ScreenContent.getSCDisplayWithMouse(), windows: nil, applications: nil) }
        }
    }

    func chooseScreen() {
        closeMainWindow()
        createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
    }

    func chooseArea() {
        closeMainWindow()
        ScreenContent.updateAvailableContent {
            DispatchQueue.main.async { [self] in
                showAreaSelector(size: NSSize(width: 600, height: 450))
                var currentDisplay = ScreenContent.getSCDisplayWithMouse()
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { [self] event in
                    let display = ScreenContent.getSCDisplayWithMouse()
                    if display != currentDisplay {
                        currentDisplay = display
                        closeAllWindow()
                        showAreaSelector(size: NSSize(width: 600, height: 450))
                    }
                }
            }
        }
    }

    func chooseApplication() {
        closeMainWindow()
        createNewWindow(view: AppSelector(), title: "App Selector".local, identifier: .appSelector)
    }

    func chooseWindow() {
        closeMainWindow()
        createNewWindow(view: WinSelector(), title: "Window Selector".local, identifier: .windowSelector)
    }

    /// The main panel, centred on its screen and as large as its content
    func showMainPanel() {
        let content = NSHostingView(rootView: ContentView())
        let mainPanel = MainPanel(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        mainPanel.contentView = content
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
            mainPanel.setFrameOrigin(NSPoint(x: screen.frame.midX - mainPanel.frame.width / 2, y: screen.frame.midY - mainPanel.frame.height / 2))
        }
        mainPanel.makeKeyAndOrderFront(self)
    }

    /// Opens the window of the Settings scene with SwiftUI's own action. The action has no state, so the one of
    /// an empty environment is the one a view would get, and AppKit code (the status item's menu) can call it too.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        EnvironmentValues().openSettings()
    }

    func showAreaSelector(size: NSSize, noPanel: Bool = false) {
        guard let scDisplay = ScreenContent.getSCDisplayWithMouse() else { return }
        guard let screen = scDisplay.nsScreen else { return }
        let screenshotWindow = ScreenshotWindow(contentRect: screen.frame, backing: .buffered, defer: false, size: size, force: noPanel)
        screenshotWindow.title = "Area Selector".local
        screenshotWindow.identifier = .areaSelector
        screenshotWindow.orderFrontRegardless()
        if !noPanel {
            // Centred, a little above the Dock, and as large as its content
            let contentView = NSHostingView(rootView: AreaSelector(screen: scDisplay))
            let size = contentView.fittingSize
            let gapAboveDock: CGFloat = 80
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + gapAboveDock, width: size.width, height: size.height)
            contentView.focusRingType = .none
            let areaPanel = NSPanel(contentRect: frame, styleMask: [.fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            areaPanel.collectionBehavior = [.canJoinAllSpaces]
            areaPanel.level = .screenSaver
            areaPanel.title = "Start Recording".local
            areaPanel.identifier = .areaPanel
            areaPanel.contentView = contentView
            areaPanel.setFrame(frame, display: true)
            areaPanel.backgroundColor = .clear
            areaPanel.titleVisibility = .hidden
            areaPanel.isReleasedWhenClosed = false
            areaPanel.titlebarAppearsTransparent = true
            areaPanel.isMovableByWindowBackground = true
            areaPanel.orderFront(self)
        }
    }
    
    /// Cancels a countdown that has not started its recording yet. Returns false if no countdown was running.
    @discardableResult
    func cancelCountdown() -> Bool {
        guard let timer = countdownTimer else { return false }
        timer.invalidate()
        countdownTimer = nil
        for w in NSApp.windows(.countdownPanel, .areaOverlay) { w.close() }
        return true
    }
    
    func createCountdownPanel(screen: SCDisplay, action: @escaping () -> Void) {
        guard let screen = screen.nsScreen else { return }
        let countdown = AppSettings.countdown
        if countdown == 0 {
            action()
        } else {
            let contentView = NSHostingView(rootView: CountdownView(countdownValue: countdown, atEnd: action))
            let size = contentView.fittingSize
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
            countdownPanel.contentView = contentView
            countdownPanel.setFrame(frame, display: true)
            countdownPanel.makeKeyAndOrderFront(self)
        }
    }
    
    /// A titled window around `view`, centred on the screen with the mouse. It is as large as the view asks for,
    /// or `size` for a view that takes what it is given. `random` moves it a little, so that several do not
    /// cover each other exactly.
    func createNewWindow(view: some View, title: String, identifier: NSUserInterfaceItemIdentifier? = nil, size: NSSize? = nil, random: Bool = false, only: Bool = true) {
        guard let screen = ScreenContent.getScreenWithMouse() else { return }
        if only { closeAllWindow() }
        let contentView = NSHostingView(rootView: view)
        let size = size ?? contentView.fittingSize
        let shift = random ? CGFloat(Int.random(in: -200...200)) : 0
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2 + shift, y: screen.visibleFrame.midY - size.height / 2 + shift)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.identifier = identifier
        window.contentView = contentView
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(self)
        window.orderFrontRegardless()
    }
}

/// The main panel closes with Esc and takes the keyboard although it does not activate the app
final class MainPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
    override var canBecomeKey: Bool {
        return true
    }
}
