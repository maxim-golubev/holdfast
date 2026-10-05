//
//  QmaPlayer.swift
//  Holdfast
//
//  Created by apple on 2024/6/28.
//

import Foundation
import AVFoundation
import SwiftUI

struct qmaPlayerView: View {
    @Binding var document: qmaPackageHandle
    @State var fileURL: URL
    @State private var overPlay: Bool = false
    @State private var overStop: Bool = false
    @State private var overSave: Bool = false
    @State private var overExport: Bool = false
    @StateObject private var audioPlayerManager = AudioPlayerManager()
    
    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectView().ignoresSafeArea()
            VStack(spacing: 3) {
                Button {} label: {
                    PlayerSlider(percentage: $audioPlayerManager.progress, audioLength: $audioPlayerManager.audioLength){ editing in
                        if !editing {
                            let newTime = audioPlayerManager.progress * audioPlayerManager.audioLength
                            audioPlayerManager.seek(to: newTime)
                            audioPlayerManager.shouldPlay = false
                        } else {
                            if audioPlayerManager.isPlaying {
                                audioPlayerManager.pause()
                                audioPlayerManager.shouldPlay = true
                            }
                        }
                    }.frame(height: 30)
                }
                .buttonStyle(.plain)
                .disabled(audioPlayerManager.exporting)
                
                HStack(spacing: 4) {
                    Rectangle().opacity(0.00001).frame(width: 30)
                    Spacer()
                    Button {
                        audioPlayerManager.stop()
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overStop ? 0.1 : 0.00001))
                            Image(systemName: "stop.fill")
                                .font(.system(size: 20))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop Play")
                    .accessibilityLabel("Stop")
                    .frame(width: 30, height: 30)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overStop = hovering }
                    
                    Button {
                        if audioPlayerManager.isPlaying {
                            audioPlayerManager.pause()
                        } else {
                            audioPlayerManager.play()
                        }
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overPlay ? 0.1 : 0.00001))
                            Image(systemName: audioPlayerManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Play / Pause")
                    .accessibilityLabel(audioPlayerManager.isPlaying ? "Pause" : "Play")
                    .frame(width: 35, height: 35)
                    .padding(.leading, 2)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overPlay = hovering }
                    
                    Button {
                        saveQMA()
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overSave ? 0.1 : 0.00001))
                            Image("save")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16.5)
                                .foregroundColor(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Save Changes")
                    .accessibilityLabel("Save Changes")
                    .frame(width: 30, height: 30)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overSave = hovering }
                    
                    Spacer()
                    
                    Button {
                        saveQMA()
                        audioPlayerManager.export()
                    } label: {
                        ZStack {
                            Rectangle()
                                .cornerRadius(6)
                                .foregroundColor(.secondary.opacity(overExport ? 0.1 : 0.00001))
                            if audioPlayerManager.exporting {
                                ActivityIndicator()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18))
                                    .foregroundColor(.secondary)
                                    .offset(y: -2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Export")
                    .accessibilityLabel("Export")
                    .frame(width: 30, height: 30)
                    .disabled(audioPlayerManager.exporting)
                    .onHover { hovering in overExport = hovering }
                }
                
                Button {} label: {
                    HStack(spacing: 14) {
                        HStack(spacing: 2) {
                            Image(systemName: "speaker.wave.2.fill")
                            Text("\(Int(audioPlayerManager.sysVol * 100))%").foregroundColor(.secondary).frame(width: 40)
                            VolumeSlider(percentage: $audioPlayerManager.sysVol, maxValue: 4)
                                .frame(height: 16)
                                .disabled(audioPlayerManager.exporting)
                        }
                        HStack(spacing: 2) {
                            Image(systemName: "mic.fill")
                            Text("\(Int(audioPlayerManager.micVol * 100))%").foregroundColor(.secondary).frame(width: 40)
                            VolumeSlider(percentage: $audioPlayerManager.micVol, maxValue: 4)
                                .frame(height: 16)
                                .disabled(audioPlayerManager.exporting)
                        }
                    }
                }.buttonStyle(.plain)
            }.padding().padding(.top, -14)
        }
        .onAppear {
            do {
                try audioPlayerManager.loadAudioFiles(format: document.info.format, package: fileURL, encoder: document.info.encoder, saveMP3: document.info.exportMP3)
            } catch {
                UserNotice.showAlertLater(title: "Recording Not Opened", message: String(format: "The audio files of %@ could not be opened: %@", fileURL.lastPathComponent, error.localizedDescription))
            }
            audioPlayerManager.sysVol = document.info.sysVol
            audioPlayerManager.micVol = document.info.micVol
        }
        .background(WindowAccessor(onWindowOpen: { w in
            guard let w = w else { return }
            w.setContentSize(CGSize(width: 400, height: 100))
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
        }, onWindowActive: { w in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w?.titlebarAppearsTransparent = true }
        }, onWindowDeactivate: { w in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w?.titlebarAppearsTransparent = true }
        }, onWindowClose: { audioPlayerManager.reset() }))
    }
    
    func saveQMA() {
        var save = 0
        if document.info.sysVol != audioPlayerManager.sysVol {
            document.info.sysVol = audioPlayerManager.sysVol
            save += 1
        }
        if document.info.micVol != audioPlayerManager.micVol {
            document.info.micVol = audioPlayerManager.micVol
            save += 1
        }
        if save != 0 {
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.state = .active
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    }
}

struct VolumeSlider: View {
    @Binding var percentage: Float
    @State var maxValue: Float = 1.0
    @State private var isDragging = false
    @State private var isHover = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Group {
                    Rectangle()
                        .foregroundColor(.secondary.opacity(0.2))
                    Rectangle()
                        .foregroundColor(.accentColor)
                        .frame(width: geometry.size.width * CGFloat(min(1.0, self.percentage / maxValue)))
                }.frame(height: 5).cornerRadius(12)
                Circle()
                    .shadow(radius: 1)
                    .foregroundColor(.white)
                    .opacity(isHover || isDragging ? 1.0 : 0.00001)
                    .frame(width: 16, height: 16)
                    .offset(x: geometry.size.width * CGFloat(min(1.0, self.percentage / maxValue)) - 8)
            }.onHover { hovering in isHover = hovering }
                .compositingGroup()
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.percentage = min(max(0, Float(value.location.x / geometry.size.width) * maxValue), maxValue)
                        self.isDragging = true
                    }
                    .onEnded { value in
                        self.percentage = min(max(0, Float(value.location.x / geometry.size.width) * maxValue), maxValue)
                        self.isDragging = false
                    }
                )
        }
    }
}

struct PlayerSlider: View {
    @Binding var percentage: Double
    @Binding var audioLength: TimeInterval
    @State private var isDragging = false
    @State private var isHover = false
    @State private var temporaryPercentage: Double = 0.0 // Temporary value during dragging

    var onEditingChanged: (Bool) -> Void // Callback for editing changes

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 2) {
                // As the menu bar shows a recording's length
                HStack {
                    Text(Timeline.lengthText((isDragging ? temporaryPercentage : percentage) * audioLength))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(Timeline.lengthText(audioLength))
                        .foregroundColor(.secondary)
                }
                ZStack(alignment: .leading) {
                    Group {
                        Rectangle()
                            .foregroundColor(.secondary.opacity(0.5))
                        Rectangle()
                            .foregroundColor(.secondary)
                            .frame(width: geometry.size.width * CGFloat(min(1.0, self.isDragging ? self.temporaryPercentage : self.percentage)))
                    }.frame(height: 4).cornerRadius(12)
                    if isHover || isDragging {
                        Rectangle()
                            .foregroundColor(.black)
                            .blendMode(.destinationOut)
                            .frame(width: 6, height: 10)
                            .offset(x: geometry.size.width * CGFloat(min(1.0, self.isDragging ? self.temporaryPercentage : self.percentage)) - 3)
                    }
                    Rectangle()
                        .cornerRadius(12)
                        .foregroundColor(.primary)
                        .opacity(isHover || isDragging ? 1.0 : 0.00001)
                        .frame(width: 4, height: 12)
                        .offset(x: geometry.size.width * CGFloat(min(1.0, self.isDragging ? self.temporaryPercentage : self.percentage)) - 2)
                }.onHover { hovering in isHover = hovering }
                    .compositingGroup()
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Update temporary percentage during dragging
                            self.temporaryPercentage = min(max(0, Double(value.location.x / geometry.size.width)), 1)
                            self.isDragging = true // Indicate dragging
                            self.onEditingChanged(true) // Notify that editing started
                        }
                        .onEnded { value in
                            // Update the bound percentage value when dragging ends
                            self.percentage = self.temporaryPercentage
                            self.isDragging = false // Indicate dragging ended
                            self.onEditingChanged(false) // Notify that editing ended
                        }
                    )
            }
        }
    }
}

struct qmaPackageHandle: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.qma] }
    
    var info: Info
    var sysAudio: Data
    var micAudio: Data
    
    struct Info: Codable {
        var format: String
        var encoder: String
        var exportMP3: Bool
        var sysVol: Float
        var micVol: Float
    }
    
    init(info: Info = Info(format: "m4a", encoder: "aac", exportMP3: false, sysVol: 1.0, micVol: 1.0), sysAudio: Data = Data(), micAudio: Data = Data()) {
        self.info = info
        self.sysAudio = sysAudio
        self.micAudio = micAudio
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(wrappers: configuration.file.fileWrappers)
    }

    /// The package at `url`, for code that has no document
    static func load(from url: URL) throws -> qmaPackageHandle {
        return try qmaPackageHandle(wrappers: FileWrapper(url: url, options: .immediate).fileWrappers)
    }

    private init(wrappers: [String: FileWrapper]?) throws {
        guard let wrappers = wrappers,
              let infoData = wrappers["info.json"]?.regularFileContents,
              let info = try? JSONDecoder().decode(Info.self, from: infoData),
              let sysAudio = wrappers["sys.\(info.format)"]?.regularFileContents,
              let micAudio = wrappers["mic.\(info.format)"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.info = info
        self.sysAudio = sysAudio
        self.micAudio = micAudio
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let infoData = try JSONEncoder().encode(info)
        let infoFileWrapper = FileWrapper(regularFileWithContents: infoData)
        infoFileWrapper.preferredFilename = "info.json"
        
        let sysAudioFileWrapper = FileWrapper(regularFileWithContents: sysAudio)
        sysAudioFileWrapper.preferredFilename = "sys.\(info.format)"
        
        let micAudioFileWrapper = FileWrapper(regularFileWithContents: micAudio)
        micAudioFileWrapper.preferredFilename = "mic.\(info.format)"
        
        let fileWrapper = FileWrapper(directoryWithFileWrappers: [
            "info.json": infoFileWrapper,
            "sys.\(info.format)": sysAudioFileWrapper,
            "mic.\(info.format)": micAudioFileWrapper
        ])
        
        return fileWrapper
    }
}

class AudioPlayerManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var isPlaying: Bool = false
    @Published var shouldPlay: Bool = false
    @Published var exporting: Bool = false
    @Published var audioLength: TimeInterval = 0
    @Published var sysVol: Float = 1.0 {
        didSet {
            updateSysVol()
        }
    }
    @Published var micVol: Float = 1.0 {
        didSet {
            updateMicVol()
        }
    }
    
    private var engine = AVAudioEngine()
    private var playerNode1 = AVAudioPlayerNode()
    private var playerNode2 = AVAudioPlayerNode()
    private var mixerNode = AVAudioMixerNode()
    private var timer: Timer?
    private var lastStartFramePosition = AVAudioFramePosition(0.0)
    private var audioFile1: AVAudioFile?
    private var audioFile2: AVAudioFile?
    private var exportMP3 = false
    private var fileFormat = "m4a"
    private var fileEncoder = "aac"
    private var packageURL: URL?
    private var panel = NSSavePanel()
    
    init() {
        setupAudioEngine()
    }
    
    /// Also after an export, when the nodes are attached already
    private func setupAudioEngine() {
        for node in [playerNode1, playerNode2, mixerNode] where node.engine == nil { engine.attach(node) }
        
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false) else {
            print("Audio engine: no output format")
            return
        }
        engine.connect(playerNode1, to: mixerNode, format: outputFormat)
        engine.connect(playerNode2, to: mixerNode, format: outputFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)
        
        do {
            try engine.start()
        } catch {
            print("Audio engine start error: \(error)")
        }
    }
    
    /// Opens the system audio and microphone files of the package
    func loadAudioFiles(format: String, package: URL, encoder: String, saveMP3: Bool) throws {
        fileFormat = format
        fileEncoder = encoder
        exportMP3 = saveMP3
        packageURL = package
        let system = try AVAudioFile(forReading: package.appendingPathComponent("sys.\(format)"))
        let microphone = try AVAudioFile(forReading: package.appendingPathComponent("mic.\(format)"))
        audioFile1 = system
        audioFile2 = microphone
        audioLength = Double(system.length) / system.processingFormat.sampleRate
        updateSysVol()
        updateMicVol()
    }
    
    func play() {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else { return }
        playerNode1.scheduleFile(audioFile1, at: nil, completionHandler: nil)
        playerNode2.scheduleFile(audioFile2, at: nil, completionHandler: nil)
        playerNode1.play()
        playerNode2.play()
        stopProgressTimer()
        startProgressTimer()
        isPlaying = true
    }
    
    func pause() {
        playerNode1.pause()
        playerNode2.pause()
        stopProgressTimer()
        isPlaying = false
    }
    
    func stop() {
        playerNode1.stop()
        playerNode2.stop()
        stopProgressTimer()
        lastStartFramePosition = AVAudioFramePosition(0.0)
        progress = 0.0
        isPlaying = false
    }
    
    func seek(to time: Double) {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else { return }
        playerNode1.stop()
        playerNode2.stop()
        stopProgressTimer()
        
        let startFrame = AVAudioFramePosition(time * audioFile1.processingFormat.sampleRate)
        let frameCount = AVAudioFrameCount(audioFile1.length - startFrame)
        
        if frameCount > 0 {
            lastStartFramePosition = startFrame
            playerNode1.scheduleSegment(audioFile1, startingFrame: startFrame, frameCount: frameCount, at: nil, completionHandler: nil)
            playerNode2.scheduleSegment(audioFile2, startingFrame: startFrame, frameCount: frameCount, at: nil, completionHandler: nil)
            progress = time / audioLength
            if isPlaying || shouldPlay {
                playerNode1.play()
                playerNode2.play()
                startProgressTimer()
                isPlaying = true
            }
        } else {
            stop()
        }
        
        
    }
    
    private func startProgressTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let lastRenderTime = self.playerNode1.lastRenderTime, let playerTime = self.playerNode1.playerTime(forNodeTime: lastRenderTime) {
                let currentTime = Double(self.lastStartFramePosition + playerTime.sampleTime) / playerTime.sampleRate
                self.progress = currentTime / self.audioLength
                if currentTime > self.audioLength {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.stop()
                    }
                }
            }
        }
    }
    
    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    func reset() {
        stop()
        playerNode1.reset()
        playerNode2.reset()
        audioFile1 = nil
        audioFile2 = nil
    }
    
    func export() {
        guard let packageURL = packageURL else { return }
        stop()
        let format = exportMP3 ? "mp3" : self.fileFormat
        showSavePanel(defaultFileName: "\(packageURL.deletingPathExtension().appendingPathExtension(format).lastPathComponent)", exportMP3: exportMP3) { url, saveAsMP3 in
            guard let url = url else { return }
            self.saveFile(url, saveAsMP3: saveAsMP3) { result in
                switch result {
                case .success(let file):
                    UserNotice.showNotification(title: "Recording Exported", body: String(format: "File saved to: %@".local, file.path), id: "holdfast.completed.\(UUID().uuidString)")
                case .failure(let error):
                    UserNotice.reportFailure(title: "Export Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    /// Mixes the two files at their volumes into `url`, whose extension becomes the package's format, and converts
    /// that to MP3 when `saveAsMP3`. `completion` gets the file that was written, or why there is none, once, on the
    /// main thread; a failure leaves no partial file behind. `audioQuality` defaults to the current setting;
    /// finishing a recording passes the one it was started with. Main thread.
    func saveFile(_ url: URL, saveAsMP3: Bool = false,
                  audioQuality: Int = AppSettings.audioQuality.rawValue,
                  completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        var named = url
        if named.pathExtension == "mp3" { named = named.deletingPathExtension() }
        if named.pathExtension != fileFormat { named = named.appendingPathExtension(fileFormat) }
        let mp3 = named.deletingPathExtension().appendingPathExtension("mp3")
        // What is converted to MP3 is mixed into a hidden file first
        let mixed = saveAsMP3 ? named.deletingLastPathComponent().appendingPathComponent("." + named.lastPathComponent) : named
        exporting = true
        let finish: (Result<URL, Error>) -> Void = { result in
            DispatchQueue.main.async {
                self.exporting = false
                completion(result)
            }
        }
        Thread.detachNewThread {
            do {
                try self.render(to: mixed, audioQuality: audioQuality)
            } catch {
                try? fd.removeItem(at: mixed)
                finish(.failure(error))
                return
            }
            guard saveAsMP3 else { finish(.success(mixed)); return }
            Task {
                do {
                    try await RecordingSaver.m4a2mp3(inputUrl: mixed, outputUrl: mp3, bitrate: audioQuality)
                    try? fd.removeItem(at: mixed)
                    finish(.success(mp3))
                } catch {
                    try? fd.removeItem(at: mp3)
                    try? fd.removeItem(at: mixed)
                    finish(.failure(error))
                }
            }
        }
    }

    /// Plays both files through the engine offline into `url`. The file is complete and closed when it returns.
    private func render(to url: URL, audioQuality: Int) throws {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else {
            throw RecordingError("The audio files of the recording could not be opened.")
        }
        playerNode1.scheduleFile(audioFile1, at: nil, completionHandler: nil)
        playerNode2.scheduleFile(audioFile2, at: nil, completionHandler: nil)
        let audioSettings = MovieWriter.audioSettings(format: fileEncoder, quality: audioQuality, videoFormat: nil)
        let outputFormat = playerNode1.outputFormat(forBus: 0)
        let outputFile = try AVAudioFile(forWriting: url, settings: audioSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        engine.stop()
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        defer {
            engine.disableManualRenderingMode()
            engine.stop()
            setupAudioEngine()
        }
        try engine.start()
        playerNode1.play()
        playerNode2.play()
        let duration = audioFile1.length
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw RecordingError("No buffer to mix the audio into.")
        }
        while engine.manualRenderingSampleTime < duration {
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(duration - engine.manualRenderingSampleTime))
            // Players render silence once their file has ended, so anything but success would never move on
            guard try engine.renderOffline(frames, to: buffer) == .success else {
                throw RecordingError("The audio could not be mixed.")
            }
            try outputFile.write(from: buffer)
        }
    }
    
    private func updateSysVol() {
        playerNode1.volume = sysVol
    }
    
    private func updateMicVol() {
        playerNode2.volume = micVol
    }
    
    private func showSavePanel(defaultFileName: String, exportMP3: Bool, completion: @escaping (URL?, Bool) -> Void) {
        panel.isReleasedWhenClosed = true
        panel.nameFieldStringValue = defaultFileName
        panel.canCreateDirectories = true
        panel.title = "Export Recording".local
        
        let checkBox = NSButton(checkboxWithTitle: "Export as MP3".local, target: self, action: #selector(checkBoxToggled(_:)))
        checkBox.state = exportMP3 ? .on : .off
        
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: checkBox.frame.width, height: checkBox.frame.height))
        accessoryView.addSubview(checkBox)
        
        panel.accessoryView = accessoryView
        
        panel.begin { response in
            if response == .OK {
                let exportAsMP3 = (checkBox.state == .on)
                completion(self.panel.url, exportAsMP3)
            } else {
                completion(nil, false)
            }
        }
    }
    
    @objc private func checkBoxToggled(_ sender: NSButton) {
        panel.close()
        panel = NSSavePanel()
        exportMP3.toggle()
        export()
    }
}

extension UTType {
    static let qma = UTType(exportedAs: (Bundle.main.bundleIdentifier ?? "Holdfast") + ".qma")
}

struct ActivityIndicator: View {
    
    @State var currentDegrees = 0.0
    @State private var timer: Timer?
    
    let colorGradient = LinearGradient(gradient: Gradient(colors: [
        .secondary, .secondary.opacity(0.75), .secondary.opacity(0.5), .secondary.opacity(0.2), .clear
    ]), startPoint: .leading, endPoint: .trailing)
    
    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.85)
            .stroke(colorGradient, style: StrokeStyle(lineWidth: 3))
            .frame(width: 18, height: 18)
            .rotationEffect(Angle(degrees: currentDegrees))
            .onAppear {
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    withAnimation {
                        self.currentDegrees += 10
                    }
                }
            }
            .onDisappear {
                // The timer would go on firing for the rest of the app's life otherwise
                timer?.invalidate()
                timer = nil
            }
    }
}
