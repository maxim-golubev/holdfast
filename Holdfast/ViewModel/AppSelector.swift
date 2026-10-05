//
//  AppSelector.swift
//  Holdfast
//
//  Created by apple on 2024/4/16.
//

import SwiftUI
import ScreenCaptureKit

struct AppSelector: View {
    @StateObject var viewModel = AppSelectorViewModel()
    @State private var selected = [SCRunningApplication]()
    @State private var display: SCDisplay?
    @State private var selectedTab = 0
    @State private var autoStop = 0
    var appDelegate = AppDelegate.shared
    
    var body: some View {
        SelectorWindow(prompt: "Select one or more applications to record") {
            TabView(selection: $selectedTab) {
                let allApps = viewModel.allApps.sorted(by: { $0.key.displayID < $1.key.displayID })
                ForEach(Array(allApps.enumerated()), id: \.element.key) { index, element in
                    let (screen, apps) = element
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 8) {
                            ForEach(apps, id: \.self) { item in
                                let name = item.applicationName != "" ? item.applicationName : item.bundleIdentifier
                                Button {
                                    if !selected.contains(item) {
                                        selected.append(item)
                                    } else {
                                        selected.removeAll{ $0 == item }
                                    }
                                } label: {
                                    VStack {
                                        if let icon = ScreenContent.getAppIcon(item) {
                                            Image(nsImage: icon)
                                        } else {
                                            Image(systemName: "app.dashed").font(.system(size: 56))
                                        }
                                        Text(name)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .modifier(SelectableItem(isSelected: selected.contains(item)))
                                }
                                .buttonStyle(.plain)
                                .help("Record \(name)")
                                .accessibilityLabel(name)
                            }
                        }
                        .padding(12)
                    }
                    .tag(index)
                    .tabItem { Text(screen.nsScreen?.localizedName ?? "Display \(index)") }
                    .onAppear{ display = screen }
                }
            }
            .onChange(of: selectedTab) { selected.removeAll() }
            .onReceive(viewModel.$isReady) { isReady in
                if isReady {
                    let allApps = viewModel.allApps.sorted(by: { $0.key.displayID < $1.key.displayID })
                    if let s = NSApp.windows(.appSelector).first?.screen,
                       let index = allApps.firstIndex(where: { $0.key.displayID == s.displayID }) {
                        selectedTab = index
                    }
                }
            }
        } bar: {
            SelectorBar(autoStop: $autoStop, canStart: !selected.isEmpty && display != nil, start: startRecording) {
                SymbolButton("Refresh", symbol: "arrow.clockwise.circle.fill", color: .blue, help: "Look for the running applications again") {
                    viewModel.updateAppList()
                }
            }
        }
    }
    
    func startRecording() {
        guard let display = display else { return }
        closeAllWindow()
        appDelegate.createCountdownPanel(screen: display) {
            RecorderController.shared.start(type: .application, display: display, windows: nil, applications: selected, autoStop: autoStop)
        }
    }
}

/// The applications with a window on each display
@MainActor
final class AppSelectorViewModel: ObservableObject {
    @Published private(set) var allApps = [SCDisplay: [SCRunningApplication]]()
    @Published private(set) var isReady = false
    
    init() {
        updateAppList()
    }
    
    func updateAppList() {
        ScreenContent.updateAvailableContent { [weak self] in
            guard let self, let screens = ScreenContent.availableContent?.displays else { return }
            var list = [SCDisplay: [SCRunningApplication]]()
            for screen in screens {
                var apps = [SCRunningApplication]()
                let windows = ScreenContent.getWindows().filter({ NSIntersectsRect(screen.frame, $0.frame) })
                for app in windows.compactMap({ $0.owningApplication }) where !apps.contains(app) { apps.append(app) }
                if AppSettings.hideSelf { apps = apps.filter({ $0.bundleIdentifier != Bundle.main.bundleIdentifier }) }
                list[screen] = apps
            }
            self.allApps = list
            self.isReady = true
        }
    }
}
