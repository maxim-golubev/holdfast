import SwiftUI
import AVKit

/// The videos open in a trimmer window, which opening such a file again does not open a second time. Main thread.
var trimingList = [URL]()

class RecorderPlayerModel: NSObject, ObservableObject {
    @Published var playerView: AVPlayerView
    var asset: AVAsset?
    var fileUrl: URL?
    var playerItem: AVPlayerItem?
    var nsWindow: NSWindow?
    private var observesStatus = false
    
    override init() {
        self.playerView = AVPlayerView()
        super.init()
        self.playerView.player = AVPlayer()
    }
    
    func loadVideo(fromUrl: URL) {
        fileUrl = fromUrl
        asset = AVURLAsset(url: fromUrl)
        guard let asset = asset else { return }
        // Loading again must not leave the observers of the item before
        removeObservers()
        let playerItem = AVPlayerItem(asset: asset)
        self.playerItem = playerItem
        playerView.player?.replaceCurrentItem(with: playerItem)
        playerView.controlsStyle = .inline
        
        playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.new], context: nil)
        observesStatus = true
    }
    
    /// Takes the status observer off the current item. Safe to call more than once.
    private func removeObservers() {
        if observesStatus, let playerItem = playerItem {
            playerItem.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        }
        observesStatus = false
    }
    
    deinit { removeObservers() }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let playerItem = object as? AVPlayerItem, keyPath == #keyPath(AVPlayerItem.status) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        if playerItem.status == .failed {
            // Nothing to trim: the window would stay black without a word
            removeObservers()
            let name = fileUrl?.lastPathComponent ?? "The file"
            UserNotice.showAlertLater(title: "Recording Not Opened", message: String(format: "%@ cannot be opened in the trimmer: %@", name, playerItem.error?.localizedDescription ?? "Unknown error"))
            nsWindow?.close()
            return
        }
        if playerItem.status == .readyToPlay {
            let checkCanBeginTrimming: () -> Void = {
                if self.playerView.canBeginTrimming {
                    self.playerView.beginTrimming { result in
                        // Read before the window goes, which takes the player down; the clip is exported after it
                        // and reported either way
                        let timeRange = CMTimeRangeFromTimeToTime(start: playerItem.reversePlaybackEndTime, end: playerItem.forwardPlaybackEndTime)
                        let fileUrl = self.fileUrl, asset = self.asset
                        self.nsWindow?.close()
                        guard result == .okButton, let fileUrl, let asset else { return }
                        RecorderPlayerModel.exportClip(of: asset, from: fileUrl, timeRange: timeRange)
                    }
                }
            }
            
            checkCanBeginTrimming()

            if observesStatus, playerItem === self.playerItem {
                playerItem.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
                observesStatus = false
            }
        }
    }
    
    /// Whether a clip of `url` can be exported: the trimmer writes MOV and MP4 only
    static func canTrim(_ url: URL) -> Bool {
        return [VideoFormat.mov.rawValue, VideoFormat.mp4.rawValue].contains(url.pathExtension.lowercased())
    }

    /// Writes the trimmed part next to the recording as "<name> (trimmed <date>).<ext>", untouched (passthrough),
    /// and says whether it worked. The recording itself is never changed.
    private static func exportClip(of asset: AVAsset, from fileUrl: URL, timeRange: CMTimeRange) {
        let fileEnding = fileUrl.pathExtension.lowercased()
        guard canTrim(fileUrl) else {
            // An export needs a file type, and only these two are written
            UserNotice.showAlertLater(title: "Clip Not Saved", message: String(format: "Only MOV and MP4 files can be trimmed: %@", fileUrl.lastPathComponent))
            return
        }
        let fileType: AVFileType = fileEnding == VideoFormat.mov.rawValue ? .mov : .mp4
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            UserNotice.showAlertLater(title: "Clip Not Saved", message: String(format: "%@ cannot be trimmed without re-encoding it.", fileUrl.lastPathComponent))
            return
        }
        exportSession.timeRange = timeRange
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let output = URL(fileURLWithPath: fileUrl.deletingPathExtension().path + " (trimmed \(dateFormatter.string(from: Date.now))).\(fileEnding)")
        Task {
            do {
                try await exportSession.export(to: output, as: fileType)
                UserNotice.showNotification(title: "Clip Saved", body: String(format: "File saved to: %@", output.path), id: "holdfast.completed.\(UUID().uuidString)")
            } catch {
                try? fd.removeItem(at: output)
                UserNotice.showAlertLater(title: "Clip Not Saved", message: String(format: "The trimmed clip of %@ could not be written: %@ The recording itself is unchanged.", fileUrl.lastPathComponent, error.localizedDescription))
            }
        }
    }
    
    func cleanup() {
        removeObservers()
        playerView.player?.pause()
        playerView.player = nil
    }
}

struct RecorderPlayerView: NSViewRepresentable {
    typealias NSViewType = AVPlayerView

    var playerView: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView {
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

}

struct VideoTrimmerView: View {
    /// The size its window opens with; the player takes whatever it is given. Open it with `AppDelegate.openTrimmer`.
    static let windowSize = NSSize(width: 780, height: 555)
    let videoURL: URL
    @StateObject var playerViewModel: RecorderPlayerModel = .init()

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 13, weight: .bold))
                    .offset(y: 0.5)
                Text(videoURL.lastPathComponent)
                    .font(.system(size: 13, weight: .bold))
            }
            ZStack {
                RecorderPlayerView(playerView: playerViewModel.playerView)
                    .onAppear { playerViewModel.loadVideo(fromUrl: videoURL) }
                    .padding(4)
                    .background(
                        Rectangle()
                            .foregroundStyle(.black)
                            .cornerRadius(5)
                    )
            }.padding([.bottom, .leading, .trailing])
        }
        .padding(.top, -22)
        .background(WindowAccessor(onWindowOpen: { window in
            window?.styleMask.insert(.resizable)
            playerViewModel.nsWindow = window
            trimingList.append(videoURL)
        }, onWindowClose: {
            playerViewModel.playerView.player?.replaceCurrentItem(with: nil)
            playerViewModel.cleanup()
            trimingList.removeAll(where: { $0 == videoURL })
        }))
    }
}
