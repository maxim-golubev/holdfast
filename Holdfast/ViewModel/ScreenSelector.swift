//
//  ScreenSelector.swift
//  Holdfast
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
                    viewModel.reload()
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
                RecorderController.shared.start(type: .screen, display: screen, windows: nil, applications: nil, autoStop: autoStop)
            }
        }
    }
}

/// The screens that can be recorded, each with a picture of what is on it. A new `reload` drops whatever an older
/// one was still doing.
@MainActor
final class ScreenSelectorViewModel: ObservableObject {
    @Published private(set) var screenThumbnails = [ScreenThumbnail]()
    private var generation = 0
    private var pictures: Task<Void, Never>?

    init() {
        reload()
    }

    /// Fetches the screens, takes their pictures (a few, one after the other) and then shows them all at once
    func reload() {
        generation += 1
        let run = generation
        pictures?.cancel()
        ScreenContent.updateAvailableContent { [weak self] in
            guard let self, run == self.generation else { return }
            let displays = ScreenContent.availableContent?.displays ?? []
            let ownApp = ScreenContent.getSelf().map { [$0] } ?? []
            self.pictures = Task { [weak self] in
                var thumbnails = [ScreenThumbnail]()
                for display in displays {
                    let picture = await Self.picture(of: display, excluding: ownApp)
                    thumbnails.append(ScreenThumbnail(image: picture ?? ScreenContent.getWallpaper(display) ?? .unknowScreen, screen: display))
                }
                guard let self, !Task.isCancelled else { return }
                self.screenThumbnails = thumbnails
            }
        }
    }

    private static func picture(of display: SCDisplay, excluding ownApp: [SCRunningApplication]) async -> NSImage? {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(display.frame.width))
        configuration.height = max(1, Int(display.frame.height))
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: .zero)
        } catch {
            print("No picture of display \(display.displayID): \(error.localizedDescription)")
            return nil
        }
    }
}

struct ScreenThumbnail {
    let image: NSImage
    let screen: SCDisplay
}
