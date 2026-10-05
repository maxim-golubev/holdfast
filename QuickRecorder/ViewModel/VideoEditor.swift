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
        asset = AVAsset(url: fromUrl)
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
        
        if playerItem.status == .readyToPlay {
            let checkCanBeginTrimming: () -> Void = {
                if self.playerView.canBeginTrimming {
                    self.playerView.beginTrimming { result in
                        if result == .okButton {
                            guard let fileUrl = self.fileUrl else { return }
                            let startTime = playerItem.reversePlaybackEndTime
                            let endTime = playerItem.forwardPlaybackEndTime
                            let timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)
                            guard let asset = self.asset else { return }
                            let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
                            let dateFormatter = DateFormatter()
                            let fileEnding = fileUrl.pathExtension.lowercased()
                            let fileType: AVFileType
                            switch fileEnding {
                            case VideoFormat.mov.rawValue: fileType = .mov
                            case VideoFormat.mp4.rawValue: fileType = .mp4
                            default:
                                // An export needs a file type, and only these two are written
                                UserNotice.showNotification(title: "Clip Not Saved".local, body: String(format: "Only MOV and MP4 files can be trimmed: %@".local, fileUrl.lastPathComponent), id: "quickrecorder.error.\(UUID().uuidString)")
                                self.nsWindow?.close()
                                return
                            }
                            dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
                            let filePath = fileUrl.deletingPathExtension().path + " (Cropped in ".local + "\(dateFormatter.string(from: Date())))." + fileEnding
                            exportSession?.outputURL = filePath.url
                            exportSession?.outputFileType = fileType
                            exportSession?.timeRange = timeRange
                            exportSession?.exportAsynchronously {
                                if let error = exportSession?.error {
                                    print("Error: \(error.localizedDescription)")
                                } else {
                                    print("Trimmed video exported successfully.")
                                    UserNotice.showNotification(title: "Clip Saved".local, body: String(format: "File saved to: %@".local, filePath), id: "quickrecorder.completed.\(UUID().uuidString)")
                                }
                            }
                            self.nsWindow?.close()
                        } else {
                            self.nsWindow?.close()
                        }
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
