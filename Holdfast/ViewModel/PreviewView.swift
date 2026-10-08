//
//  PreviewView.swift
//  Holdfast
//
//  Created by apple on 2024/12/10.
//

import SwiftUI

/// The floating preview of a finished recording: its first frame, its file name and where it was saved, and Done,
/// which only closes the preview. Nothing on it removes the recording: Move to Trash is in the context menu alone,
/// and asks first, naming the file.
struct PreviewView: View {
    let frame: NSImage
    /// The recording
    let fileURL: URL
    /// How long the preview stays when the pointer is not on it, in seconds
    private static let staysFor: Double = 8
    private let sharingDelegate = SharingServicePickerDelegate()
    @State private var isHovered: Bool = false
    @State private var isPictureHovered: Bool = false
    @State private var isSharing: Bool = false
    /// The Move to Trash question is open
    @State private var isConfirming: Bool = false
    @State private var closeWaits = 0
    @State private var nsWindow: NSWindow?
    @State private var opacity: Double = 0.0
    @AppStorage(AppSettings.$trimAfterRecord)  private var trimAfterRecord: Bool

    /// "Desktop", or the name Finder shows for the folder the recording is in
    private var folderName: String {
        FileManager.default.displayName(atPath: fileURL.deletingLastPathComponent().path)
    }

    var body: some View {
        VStack(spacing: 0) {
            picture
            infoBar
        }
        .frame(width: 272)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.controlActiveState, .active)
        // The play button is only there under the pointer, so VoiceOver gets what it does as an action
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording Preview")
        .accessibilityAction(named: "Open Recording", openRecording)
        .accessibilityAction(named: "Close Preview, Keeping the Recording") { closeWindow() }
        .opacity(opacity)
        .onHover(perform: { isHovered = $0 })
        .background(WindowAccessor(onWindowOpen: { w in nsWindow = w }))
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { opacity = 1.0 }
            closeLaterUnlessUsed()
        }
        .onChange(of: isHovered) { _, newValue in
            if !newValue { closeLaterUnlessUsed() }
        }
        .contextMenu {
            Button("Show in Finder") { showInFinder() }
            Divider()
            Button("Copy") {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([fileURL as NSURL])
                }
                closeWindow()
            }
            Button("Share…") { showSharingServicePicker(for: fileURL) }
            Divider()
            // Audio-only recordings have nothing the trimmer can export
            if !trimAfterRecord && TrimmerModel.canTrim(fileURL) {
                Button("Trim") {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        AppDelegate.shared.openTrimmer(fileURL)
                    }
                    closeWindow()
                }
            }
            Button("Close Preview") { closeWindow() }
            Divider()
            // Last and apart from the rest, asked first, and to the Trash: this may be the only copy of a meeting
            Button("Move to Trash…", role: .destructive) { confirmMoveToTrash() }
        }
    }

    /// The first frame (or an icon for audio), with a play button under the pointer that opens the recording
    private var picture: some View {
        ZStack {
            Image(nsImage: frame)
                .resizable().scaledToFit()
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
            if isPictureHovered {
                Button(action: openRecording, label: {
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
                })
                .buttonStyle(.plain)
                .help("Open the recording")
                .accessibilityLabel("Open Recording")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .onHover(perform: { isPictureHovered = $0 })
        .padding([.horizontal, .top], 8)
    }

    /// What was saved and where, and the button that closes the preview
    private var infoBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: fileURL.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fileURL.lastPathComponent)
                Text(verbatim: "Saved to " + folderName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fileURL.deletingLastPathComponent().path)
            }
            Spacer(minLength: 4)
            Button(action: showInFinder) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show the recording in Finder")
            .accessibilityLabel("Show in Finder")
            Button("Done") { closeWindow() }
                .controlSize(.small)
                .help("Close the preview. The recording is kept.")
                .accessibilityHint("Closes the preview. The recording is kept.")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Closes the preview after a while, unless the pointer is on it, the share sheet or the Trash question is open
    /// Counted from the last time the pointer left: an earlier wait that ends meanwhile closes nothing
    private func closeLaterUnlessUsed() {
        closeWaits += 1
        let wait = closeWaits
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewView.staysFor) {
            if wait == closeWaits && !isHovered && !isSharing && !isConfirming { closeWindow() }
        }
    }

    /// A .qma package opens in Holdfast's own player: the system's default for it may be another app (QuickRecorder,
    /// whose type for it LaunchServices may prefer). Everything else opens in its default app.
    private func openRecording() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let url = fileURL
        if url.pathExtension.lowercased() == RecordingFileStore.packageEnding {
            // The player's window must come to the front: without a Dock icon Holdfast is usually not active
            NSApp.activate(ignoringOtherApps: true)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error {
                    UserNotice.showAlertLater(title: "Recording Not Opened", message: String(format: "%@ could not be opened: %@", url.lastPathComponent, error.localizedDescription))
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        closeWindow()
    }

    private func showInFinder() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        closeWindow()
    }

    /// Asks before anything is moved, naming the file and its folder; Return does not answer it. A run loop block:
    /// a recording may be running, and a modal alert inside a main-queue block would hold up its stop.
    private func confirmMoveToTrash() {
        isConfirming = true
        let url = fileURL
        let folder = folderName
        UserNotice.onMainRunLoop {
            let alert = createAlert(level: .warning,
                                    title: String(format: "Move \u{201C}%@\u{201D} to the Trash?", url.lastPathComponent),
                                    message: String(format: "The recording in %@ is moved to the Trash. You can put it back from the Trash until it is emptied.", folder),
                                    button1: "Move to Trash", button2: "Cancel")
            if let move = alert.buttons.first {
                move.hasDestructiveAction = true
                move.keyEquivalent = ""
            }
            let answer = alert.runInFront()
            isConfirming = false
            if answer == .alertFirstButtonReturn {
                moveToTrash()
                closeWindow()
            } else {
                closeLaterUnlessUsed()
            }
        }
    }

    private func moveToTrash() {
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            RecLog.write("Recording moved to the Trash from its preview: \(fileURL.path)")
        } catch {
            UserNotice.showAlertLater(title: "Not Moved to Trash", message: "\(fileURL.path) could not be moved to the Trash: \(error.localizedDescription)")
        }
    }

    private func closeWindow() {
        withAnimation(.easeIn(duration: 0.2)) { opacity = 0.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            nsWindow?.close()
        }
    }

    private func showSharingServicePicker(for url: URL) {
        if let window = nsWindow, let view = window.contentView {
            isSharing = true
            sharingDelegate.onDidChooseService = { service in
                isSharing = false
                if service != nil {
                    DispatchQueue.main.async { closeWindow() }
                } else {
                    closeLaterUnlessUsed()
                }
            }
            let sharingPicker = NSSharingServicePicker(items: [url])
            sharingPicker.delegate = sharingDelegate
            sharingPicker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }
}

/// The preview's window. Its view holds on to it, so the view goes when it closes: the window and its picture are
/// freed then.
final class PreviewWindow: NSWindow {
    override func close() {
        super.close()
        contentView = nil
    }
}

// Custom NSSharingServicePickerDelegate
class SharingServicePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    var onDidChooseService: ((NSSharingService?) -> Void)?
    
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        onDidChooseService?(service)
    }
}
