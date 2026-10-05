//
//  PreviewView.swift
//  QuickRecorder
//
//  Created by apple on 2024/12/10.
//

import SwiftUI
import Combine

struct PreviewView: View {
    let frame: NSImage
    let filePath: String
    private let sharingDelegate = SharingServicePickerDelegate()
    @State private var isHovered: Bool = false
    @State private var isHovered2: Bool = false
    @State private var isSharing: Bool = false
    @State private var nsWindow: NSWindow?
    @State private var opacity: Double = 0.0
    @AppStorage(AppSettings.$trimAfterRecord)  private var trimAfterRecord: Bool
    
    var body: some View {
        ZStack(alignment: Alignment(horizontal: .leading, vertical: .top)) {
            ZStack {
                Color.clear
                    .background(.ultraThickMaterial)
                    .environment(\.controlActiveState, .active)
                    .cornerRadius(6)
                ZStack {
                    Image(nsImage: frame)
                        .resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
                    if isHovered2 {
                        Button(action: {
                            if fd.fileExists(atPath: filePath) {
                                NSWorkspace.shared.open(filePath.url)
                                closeWindow()
                            }
                        }, label: {
                            ZStack {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 49))
                                    .foregroundStyle(.black)
                                    .opacity(0.5)
                                Image(systemName: "play.circle")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                        }).buttonStyle(.plain)
                    }
                }
                .onHover(perform: { isHovered2 = $0 })
                .padding(8)
            }
            if isHovered {
                HoverButton(color: .buttonRed, secondaryColor: .buttonRedDark,
                            action: { closeWindow() }, label: {
                    ZStack {
                        Image(systemName: "circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                        Image(systemName: "circle.fill")
                            .font(.title2)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                    }
                }).padding(4)
            }
        }
        .opacity(opacity)
        .onHover(perform: { isHovered = $0 })
        .background(WindowAccessor(onWindowOpen: { w in nsWindow = w }))
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { opacity = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if !isHovered && !isSharing { closeWindow() }
            }
        }
        .onChange(of: isHovered) { newValue in
            if !newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if !isHovered && !isSharing { closeWindow() }
                }
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                if fd.fileExists(atPath: filePath) {
                    NSWorkspace.shared.activateFileViewerSelecting([filePath.url])
                }
                closeWindow()
            }
            Button("Delete") {
                do {
                    try fd.removeItem(atPath: filePath)
                } catch {
                    print("Failed to delete file: \(error.localizedDescription)")
                }
                closeWindow()
            }
            Divider()
            Button("Copy") {
                if fd.fileExists(atPath: filePath) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([filePath.url as NSURL])
                }
                closeWindow()
            }
            Button("Share...") { showSharingServicePicker(for: filePath.url) }
            Divider()
            if !trimAfterRecord {
                Button("Trim") {
                    if fd.fileExists(atPath: filePath) {
                        AppDelegate.shared.openTrimmer(filePath.url)
                    }
                    closeWindow()
                }
            }
            Button("Close") { closeWindow() }
        }
    }
    
    private func closeWindow() {
        withAnimation(.easeIn(duration: 0.2)) { opacity = 0.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            nsWindow?.close()
        }
    }
    
    private func showSharingServicePicker(for url: URL) {
        if let window = nsWindow {
            isSharing = true
            sharingDelegate.onDidChooseService = { service in
                isSharing = false
                if service != nil {
                    DispatchQueue.main.async { closeWindow() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        if !isHovered && !isSharing { closeWindow() }
                    }
                }
            }
            let sharingPicker = NSSharingServicePicker(items: [url])
            sharingPicker.delegate = sharingDelegate
            sharingPicker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .minY)
        }
    }
}

/// A borderless button whose label changes colour under the pointer
struct HoverButton<Content: View>: View {
    var color: Color = .primary
    var secondaryColor: Color = .blue
    var action: () -> Void
    @ViewBuilder let label: () -> Content
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            label().foregroundStyle(isHovered ? secondaryColor : color)
        }
        .buttonStyle(.plain)
        .onHover(perform: { isHovered = $0 })
    }
}

// Custom NSSharingServicePickerDelegate
class SharingServicePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    var onDidChooseService: ((NSSharingService?) -> Void)?
    
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        onDidChooseService?(service)
    }
}
