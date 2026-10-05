//
//  ScreenSelector.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/18.
//

import SwiftUI
import ScreenCaptureKit

struct ScreenSelector: View {
    @StateObject var viewModel = ScreenSelectorViewModel()
    
    @State private var selected: SCDisplay?
    @State private var autoStop = 0
    var appDelegate = AppDelegate.shared
    
    var body: some View {
        // One screen gets the whole width, several are shown two in a row
        let single = viewModel.screenThumbnails.count == 1
        SelectorWindow(prompt: "Please select the screen to record") {
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: single ? 1 : 2), spacing: 14) {
                    ForEach(viewModel.screenThumbnails, id: \.screen.displayID) { item in
                        let name = screenName(item.screen)
                        Button {
                            selected = item.screen
                        } label: {
                            VStack(spacing: 6) {
                                Thumbnail(image: item.image)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: single ? 360 : 180)
                                Text(name)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .modifier(SelectableItem(isSelected: selected == item.screen, badgeSize: single ? 54 : 27))
                        }
                        .buttonStyle(.plain)
                        .help("Record \(name)")
                        .accessibilityLabel(name)
                    }
                }
            }
        } bar: {
            SelectorBar(autoStop: $autoStop, canStart: selected != nil, start: startRecording) {
                SymbolButton("Refresh", symbol: "arrow.clockwise.circle.fill", color: .blue, help: "Look for the screens again") {
                    viewModel.setupStreams()
                }
            }
        }
    }
    
    private func screenName(_ screen: SCDisplay) -> String {
        return NSScreen.screens.first(where: { $0.displayID == screen.displayID })?.localizedName ?? "Display \(screen.displayID)"
    }
    
    func startRecording() {
        closeAllWindow()
        if let screen = selected {
            appDelegate.createCountdownPanel(screen: screen) {
                RecorderController.shared.start(type: "display", screens: screen, windows: nil, applications: nil, autoStop: autoStop)
            }
        }
    }
}

class ScreenSelectorViewModel: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    @Published var screenThumbnails = [ScreenThumbnail]()
    private var allScreens = [SCDisplay]()
    private var streams = [SCStream]()
    
    override init() {
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupStreams()
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if CMSampleBufferGetImageBuffer(sampleBuffer) == nil { return }
        if let index = self.streams.firstIndex(of: stream), index + 1 <= self.allScreens.count {
            let currentScreen = self.allScreens[index]
            let nsImage = sampleBuffer.nsImage ?? ScreenContent.getWallpaper(currentScreen) ?? NSImage.unknowScreen
            let thumbnail = ScreenThumbnail(image: nsImage, screen: currentScreen)
            DispatchQueue.main.async {
                if !self.screenThumbnails.contains(where: { $0.screen == currentScreen }) { self.screenThumbnails.append(thumbnail) }
            }
            self.streams[index].stopCapture()
        }
    }

    func setupStreams() {
        ScreenContent.updateAvailableContent {
            Task {
                do {
                    self.streams.removeAll()
                    DispatchQueue.main.async { self.screenThumbnails.removeAll() }
                    guard let screens = ScreenContent.availableContent?.displays else { return }
                    self.allScreens = screens
                    let qrSelf = ScreenContent.getSelf().map { [$0] } ?? []
                    let contentFilters = self.allScreens.map { SCContentFilter(display: $0, excludingApplications: qrSelf, exceptingWindows: []) }
                    for (index, contentFilter) in contentFilters.enumerated() {
                        let streamConfiguration = SCStreamConfiguration()
                        streamConfiguration.width = Int(self.allScreens[index].frame.width)
                        streamConfiguration.height = Int(self.allScreens[index].frame.height)
                        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(1))
                        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
                        streamConfiguration.capturesAudio = false
                        streamConfiguration.showsCursor = false
                        streamConfiguration.queueDepth = 3
                        let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                        try await stream.startCapture()
                        self.streams.append(stream)
                    }
                } catch {
                    print("Get screenshot error：\(error)")
                }
            }
        }
    }
}

class ScreenThumbnail {
    let image: NSImage
    let screen: SCDisplay

    init(image: NSImage, screen: SCDisplay) {
        self.image = image
        self.screen = screen
    }
}
