//
//  WinSelector.swift
//  Holdfast
//
//  Created by apple on 2024/4/17.
//

import SwiftUI
import Foundation
import AVFoundation
import ScreenCaptureKit

struct WinSelector: View {
    @StateObject var viewModel = WindowSelectorViewModel()
    @State private var selected = [SCWindow]()
    @State private var display: SCDisplay?
    @State private var selectedTab = 0
    @State private var isShowingListOptions = false
    @State private var disableFilter = false
    @State private var donotCapture = false
    @State private var autoStop = 0
    var appDelegate = AppDelegate.shared
    
    var body: some View {
        SelectorWindow(prompt: "Select one or more windows to record") {
            TabView(selection: $selectedTab) {
                let allApps = viewModel.windowThumbnails.sorted(by: { $0.key.displayID < $1.key.displayID })
                ForEach(Array(allApps.enumerated()), id: \.element.key) { index, element in
                    let (screen, thumbnails) = element
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                            ForEach(thumbnails, id: \.window.windowID) { item in
                                let title = item.window.title ?? ""
                                let isSelected = selected.contains(item.window)
                                Button {
                                    if !isSelected {
                                        selected.append(item.window)
                                    } else {
                                        selected.removeAll{ $0 == item.window }
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        Thumbnail(image: item.image)
                                            .frame(width: 160, height: 90)
                                            .overlay(alignment: .bottom) {
                                                if let app = item.window.owningApplication, let icon = ScreenContent.getAppIcon(app) {
                                                    Image(nsImage: icon)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fit)
                                                        .frame(width: 40, height: 40)
                                                }
                                            }
                                        Text(title)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(width: 160)
                                    }
                                    .modifier(SelectableItem(isSelected: isSelected))
                                }
                                .buttonStyle(.plain)
                                .help(title)
                                .accessibilityLabel(title.isEmpty ? "Untitled window of \(item.window.owningApplication?.applicationName ?? "an application")" : title)
                            }
                        }
                        .padding(8)
                    }
                    .tag(index)
                    .tabItem { Text(screen.nsScreen?.localizedName ?? "Display \(index)") }
                    .onAppear{ display = screen }
                }
            }
            .onChange(of: selectedTab) { selected.removeAll() }
            .onReceive(viewModel.$isReady) { isReady in
                if isReady {
                    let allApps = viewModel.windowThumbnails.sorted(by: { $0.key.displayID < $1.key.displayID })
                    if let s = NSApp.windows(.windowSelector).first?.screen,
                       let index = allApps.firstIndex(where: { $0.key.displayID == s.displayID }) {
                        selectedTab = index
                    }
                }
            }
        } bar: {
            SelectorBar(autoStop: $autoStop, canStart: !selected.isEmpty && display != nil, start: startRecording) {
                SymbolButton("Refresh", symbol: "arrow.clockwise.circle.fill", color: .blue, help: "Look for the windows again") { reload() }
                Button {
                    isShowingListOptions = true
                } label: {
                    Label("List Options", systemImage: "chevron.down")
                        .fixedSize()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Choose which windows are listed and whether they get a picture")
                .popover(isPresented: $isShowingListOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading) {
                        Toggle("Show Windows with No Title", isOn: $disableFilter)
                        Toggle("Don't Create Thumbnails", isOn: $donotCapture)
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .padding()
                }
            }
        }
        .onChange(of: disableFilter) { reload() }
        .onChange(of: donotCapture) { reload() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    WindowHighlighter.shared.registerMouseMonitor()
                } label: {
                    Label {
                        Text("Select Window Directly")
                    } icon: {
                        Image("window.select")
                            .resizable().scaledToFit()
                            .frame(width: 20)
                    }
                }
                .help("Select a window by clicking it on the screen")
            }
        }
    }
    
    private func reload() {
        viewModel.reload(untitled: disableFilter, pictures: !donotCapture)
        selected.removeAll()
    }
    
    func startRecording() {
        guard let display = display else { return }
        closeAllWindow()
        appDelegate.createCountdownPanel(screen: display) {
            RecorderController.shared.start(type: selected.count < 2 ? .window : .windows, display: display, windows: selected, applications: nil, autoStop: autoStop)
        }
    }
}

/// The windows that can be recorded, by the displays they are on, each with a picture once it is taken. A new
/// `reload` drops whatever an older one was still doing, so the list never mixes two fetches.
@MainActor
final class WindowSelectorViewModel: ObservableObject {
    @Published private(set) var windowThumbnails = [SCDisplay: [WindowThumbnail]]()
    @Published private(set) var isReady = false
    private var generation = 0
    private var pictures: Task<Void, Never>?

    init() {
        reload()
    }

    /// `untitled`: list windows without a title too. `pictures`: replace each placeholder with a picture of the window.
    func reload(untitled: Bool = false, pictures takesPictures: Bool = true) {
        generation += 1
        let run = generation
        pictures?.cancel()
        isReady = false
        ScreenContent.updateAvailableContent { [weak self] in
            guard let self, run == self.generation else { return }
            let windows = ScreenContent.getWindows().filter {
                !($0.title == "" && $0.owningApplication?.bundleIdentifier == "com.apple.finder")
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.owningApplication?.applicationName != ""
                && (untitled || $0.title != "")
            }
            let displays = ScreenContent.availableContent?.displays ?? []
            var list = [SCDisplay: [WindowThumbnail]]()
            for window in windows {
                for display in displays where NSIntersectsRect(window.frame, display.frame) {
                    list[display, default: []].append(WindowThumbnail(image: .unknowScreen, window: window))
                }
            }
            self.windowThumbnails = list
            self.isReady = true
            guard takesPictures else { return }
            self.pictures = Task { [weak self] in
                for window in windows {
                    let image = await Self.picture(of: window)
                    guard let self, !Task.isCancelled else { return }
                    guard let image else { continue }
                    for display in self.windowThumbnails.keys {
                        if let index = self.windowThumbnails[display]?.firstIndex(where: { $0.window == window }) {
                            self.windowThumbnails[display]?[index].image = image
                        }
                    }
                }
            }
        }
    }

    private static func picture(of window: SCWindow) async -> NSImage? {
        let factor = window.frame.width < 200 && window.frame.height < 200 ? 1.0 : 0.5
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * factor))
        configuration.height = max(1, Int(window.frame.height * factor))
        configuration.showsCursor = false
        configuration.scalesToFit = true
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            return NSImage(cgImage: image, size: .zero)
        } catch {
            print("No picture of window \(window.windowID): \(error.localizedDescription)")
            return nil
        }
    }
}

struct WindowThumbnail {
    var image: NSImage
    let window: SCWindow
}
