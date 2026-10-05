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
        SelectorWindow(prompt: "Please select the window(s) to record") {
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
        viewModel.setupStreams(filter: !disableFilter, capture: !donotCapture)
        selected.removeAll()
    }
    
    func startRecording() {
        guard let display = display else { return }
        closeAllWindow()
        appDelegate.createCountdownPanel(screen: display) {
            RecorderController.shared.start(type: selected.count < 2 ? .window : .windows, screens: display, windows: selected, applications: nil, autoStop: autoStop)
        }
    }
}

class WindowSelectorViewModel: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    @Published var windowThumbnails = [SCDisplay:[WindowThumbnail]]()
    @Published var isReady = false
    private var allWindows = [SCWindow]()
    private var streams = [SCStream]()
    
    override init() {
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupStreams()
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if CMSampleBufferGetImageBuffer(sampleBuffer) == nil { return }
        let nsImage = sampleBuffer.nsImage ?? NSImage.unknowScreen
        if let index = self.streams.firstIndex(of: stream), index + 1 <= self.allWindows.count {
            let currentWindow = self.allWindows[index]
            let thumbnail = WindowThumbnail(image: nsImage, window: currentWindow)
            guard let displays = ScreenContent.availableContent?.displays.filter({ NSIntersectsRect(currentWindow.frame, $0.frame) }) else {
                self.streams[index].stopCapture()
                return
            }
            for d in displays {
                DispatchQueue.main.async {
                    if !self.windowThumbnails[d, default: []].contains(where: { $0.window == currentWindow }) {
                        self.windowThumbnails[d, default: []].append(thumbnail)
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { self.streams[index].stopCapture() }
            if index + 1 == self.streams.count { DispatchQueue.main.async { self.isReady = true }}
        }
    }

    func setupStreams(filter: Bool = true, capture: Bool = true) {
        ScreenContent.updateAvailableContent {
            Task {
                do {
                    self.streams.removeAll()
                    DispatchQueue.main.async { self.windowThumbnails.removeAll() }
                    self.allWindows = ScreenContent.getWindows().filter({
                        !($0.title == "" && $0.owningApplication?.bundleIdentifier == "com.apple.finder")
                        && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                        && $0.owningApplication?.applicationName != ""
                    })
                    if filter { self.allWindows = self.allWindows.filter({ $0.title != "" }) }
                    if capture {
                        let contentFilters = self.allWindows.map { SCContentFilter(desktopIndependentWindow: $0) }
                        for (index, contentFilter) in contentFilters.enumerated() {
                            let streamConfiguration = SCStreamConfiguration()
                            let width = self.allWindows[index].frame.width
                            let height = self.allWindows[index].frame.height
                            var factor = 0.5
                            if width < 200 && height < 200 { factor = 1.0 }
                            streamConfiguration.width = Int(width * factor)
                            streamConfiguration.height = Int(height * factor)
                            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(1))
                            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
                            streamConfiguration.capturesAudio = false
                            streamConfiguration.showsCursor = false
                            streamConfiguration.scalesToFit = true
                            streamConfiguration.queueDepth = 3
                            let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
                            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                            try await stream.startCapture()
                            self.streams.append(stream)
                        }
                    } else {
                        for w in self.allWindows {
                            let thumbnail = WindowThumbnail(image: NSImage.unknowScreen, window: w)
                            guard let displays = ScreenContent.availableContent?.displays.filter({ NSIntersectsRect(w.frame, $0.frame) }) else { break }
                            for d in displays {
                                DispatchQueue.main.async {
                                    if !self.windowThumbnails[d, default: []].contains(where: { $0.window == w }) {
                                        self.windowThumbnails[d, default: []].append(thumbnail)
                                    }
                                }
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.isReady = true }
                    }
                } catch {
                    print("Get windowshot error：\(error)")
                }
            }
        }
    }
}

class WindowThumbnail {
    let image: NSImage
    let window: SCWindow

    init(image: NSImage, window: SCWindow) {
        self.image = image
        self.window = window
    }
}
