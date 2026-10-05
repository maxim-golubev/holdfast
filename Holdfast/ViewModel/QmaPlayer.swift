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
                }
                .frame(height: 30)
                .keepsWindowStill()
                .accessibilityRepresentation {
                    Slider(value: position, in: 0...max(audioPlayerManager.audioLength, 1), step: 10) { Text("Position") }
                        .accessibilityValue(Timeline.lengthText(audioPlayerManager.progress * audioPlayerManager.audioLength))
                }
                .help("Position")
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
                
                HStack(spacing: 14) {
                    volume("System Audio Volume", symbol: "speaker.wave.2.fill", value: $audioPlayerManager.sysVol)
                    volume("Microphone Volume", symbol: "mic.fill", value: $audioPlayerManager.micVol)
                }
            }.padding().padding(.top, -14)
        }
        .onAppear {
            do {
                try audioPlayerManager.loadAudioFiles(package: fileURL, info: document.info)
            } catch {
                UserNotice.showAlertLater(title: "Recording Not Opened", message: String(format: "The audio files of %@ could not be opened: %@", fileURL.lastPathComponent, error.localizedDescription))
            }
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
        }, onWindowClose: { audioPlayerManager.windowClosed() }))
    }
    
    /// The playing position in seconds, for accessibility: setting it seeks
    private var position: Binding<Double> {
        Binding(get: { audioPlayerManager.progress * audioPlayerManager.audioLength },
                set: { audioPlayerManager.seek(to: min(max(0, $0), audioPlayerManager.audioLength)) })
    }

    /// One track's volume, from 0 to 400 %
    private func volume(_ title: String, symbol: String, value: Binding<Float>) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text("\(Int(value.wrappedValue * 100))%").foregroundColor(.secondary).frame(width: 40).accessibilityHidden(true)
            VolumeSlider(percentage: value, maxValue: 4)
                .frame(height: 16)
                .keepsWindowStill()
                .accessibilityRepresentation {
                    Slider(value: value, in: 0...4, step: 0.1) { Text(title) }
                        .accessibilityValue("\(Int(value.wrappedValue * 100)) %")
                }
                .help(title)
                .disabled(audioPlayerManager.exporting)
        }
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

extension View {
    /// The window moves by its background, so a drag on a drawn control would move the window instead: inside a
    /// plain button it reaches the control.
    func keepsWindowStill() -> some View {
        Button {} label: { self }.buttonStyle(.plain)
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

/// A .qma package opened in the player. Only its `info.json` is read and written (`QmaInfo`): the player reads the
/// audio files from disk, and saving a changed volume leaves them as they are.
struct qmaPackageHandle: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.qma] }
    
    var info: QmaInfo
    
    init(info: QmaInfo = QmaInfo(format: "m4a", encoder: "aac", exportMP3: false)) {
        self.info = info
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.fileWrappers?[QmaInfo.fileName]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        info = try QmaInfo.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let package = configuration.existingFile ?? FileWrapper(directoryWithFileWrappers: [:])
        if let old = package.fileWrappers?[QmaInfo.fileName] { package.removeFileWrapper(old) }
        let infoFile = FileWrapper(regularFileWithContents: try info.encoded())
        infoFile.preferredFilename = QmaInfo.fileName
        package.addFileWrapper(infoFile)
        return package
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
    /// Whether the players hold what is left to play: a pause keeps it, so Play only resumes them
    private var scheduled = false
    private var audioFile1: AVAudioFile?
    private var audioFile2: AVAudioFile?
    private var exportMP3 = false
    private var fileFormat = "m4a"
    private var fileEncoder = "aac"
    private var packageURL: URL?
    private var panel = NSSavePanel()
    /// The window closed while an export was rendering through the players: they are reset when it is done
    private var resetAfterExport = false
    
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
    
    /// Opens the system audio and microphone files of the package, at the volumes it was saved with
    func loadAudioFiles(package: URL, info: QmaInfo) throws {
        fileFormat = info.format
        fileEncoder = info.encoder
        exportMP3 = info.exportMP3
        packageURL = package
        let system = try AVAudioFile(forReading: info.systemAudio(in: package))
        let microphone = try AVAudioFile(forReading: info.microphone(in: package))
        audioFile1 = system
        audioFile2 = microphone
        audioLength = Double(system.length) / system.processingFormat.sampleRate
        sysVol = info.sysVol
        micVol = info.micVol
    }
    
    func play() {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else { return }
        if !scheduled {
            playerNode1.scheduleFile(audioFile1, at: nil, completionHandler: nil)
            playerNode2.scheduleFile(audioFile2, at: nil, completionHandler: nil)
            scheduled = true
        }
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
        scheduled = false
        stopProgressTimer()
        lastStartFramePosition = AVAudioFramePosition(0.0)
        progress = 0.0
        isPlaying = false
    }
    
    func seek(to time: Double) {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else { return }
        playerNode1.stop()
        playerNode2.stop()
        scheduled = false
        stopProgressTimer()
        
        let startFrame = AVAudioFramePosition(time * audioFile1.processingFormat.sampleRate)
        let frameCount = AVAudioFrameCount(audioFile1.length - startFrame)
        
        if frameCount > 0 {
            lastStartFramePosition = startFrame
            playerNode1.scheduleSegment(audioFile1, startingFrame: startFrame, frameCount: frameCount, at: nil, completionHandler: nil)
            playerNode2.scheduleSegment(audioFile2, startingFrame: startFrame, frameCount: frameCount, at: nil, completionHandler: nil)
            scheduled = true
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

    /// The player's window closed. An export renders through the same players, which would play silence from
    /// here on if they were stopped now, so they are reset when it ends instead.
    func windowClosed() {
        if exporting { resetAfterExport = true } else { reset() }
    }
    
    func export() {
        guard let packageURL = packageURL else { return }
        stop()
        let format = exportMP3 ? "mp3" : self.fileFormat
        showSavePanel(defaultFileName: "\(packageURL.deletingPathExtension().appendingPathExtension(format).lastPathComponent)", format: format, exportMP3: exportMP3) { url, saveAsMP3 in
            guard let url = url else { return }
            // Quitting waits for it
            withRecorder { $0.exportStarted() }
            // The panel has asked whether to replace a file of that name
            self.saveFile(url, saveAsMP3: saveAsMP3, replacing: true) { result in
                switch result {
                case .success(let file):
                    UserNotice.showNotification(title: "Recording Exported", body: String(format: "File saved to: %@".local, file.path), id: "holdfast.completed.\(UUID().uuidString)")
                case .failure(let error):
                    UserNotice.reportFailure(title: "Export Failed", message: error.localizedDescription)
                }
                RecorderController.shared.exportEnded()
            }
        }
    }
    
    /// Mixes the two files at their volumes into `output`, in the package's format, or into an MP3 when
    /// `saveAsMP3`; `output` has that extension. Everything is written under staging names first
    /// (`RecordingFileStore.stagingURL`), and `output` appears only with the complete, checked file. A file at
    /// `output` is replaced only when `replacing` (a name the user confirmed in the save panel). `completion` gets
    /// `output`, or why there is none, once, on the main thread; a failure leaves no file behind. `audioQuality`
    /// defaults to the current setting; finishing a recording passes the one it was started with. Main thread.
    func saveFile(_ output: URL, saveAsMP3: Bool = false, replacing: Bool = false,
                  audioQuality: Int = AppSettings.audioQuality.rawValue,
                  completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let mixed = RecordingFileStore.stagingURL(for: output, ending: fileFormat)
        exporting = true
        let finish: (Result<URL, Error>) -> Void = { result in
            DispatchQueue.main.async {
                self.exporting = false
                if self.resetAfterExport {
                    self.resetAfterExport = false
                    self.reset()
                }
                completion(result)
            }
        }
        let ending = saveAsMP3 ? "mp3" : fileFormat
        guard let package = packageURL else {
            return finish(.failure(RecordingError("The audio files of the recording could not be opened.")))
        }
        guard output.pathExtension.lowercased() == ending else {
            return finish(.failure(RecordingError(String(format: "The name of the exported file must end in .%@.", ending))))
        }
        // The mix is about as large as one of the two files, and an MP3 is made from it next to it
        guard RecordingFileStore.hasRoomForCopy(of: package, in: output.deletingLastPathComponent()) else {
            return finish(.failure(RecordingError("Not enough free disk space to mix the audio tracks.")))
        }
        do {
            try RecordingFileStore.checkFree(staging: mixed)
        } catch {
            return finish(.failure(error))
        }
        Thread.detachNewThread {
            do {
                try self.render(to: mixed, audioQuality: audioQuality)
            } catch {
                try? fd.removeItem(at: mixed)
                finish(.failure(error))
                return
            }
            Task {
                do {
                    if saveAsMP3 {
                        try await RecordingSaver.convertToMP3(mixed, to: output, bitrate: audioQuality, replacing: replacing)
                        try? fd.removeItem(at: mixed)
                    } else {
                        try RecordingFileStore.publish(mixed, as: output, replacing: replacing)
                    }
                    finish(.success(output))
                } catch {
                    try? fd.removeItem(at: mixed)
                    finish(.failure(error))
                }
            }
        }
    }

    /// Plays both files through the engine offline into `url`, up to the end of the longer one: the microphone
    /// file runs on past the system audio by what the stop padded it with. Returns when the file is closed and
    /// opens with that length (`RecordingMixer.verifyConversion`).
    private func render(to url: URL, audioQuality: Int) throws {
        guard let audioFile1 = audioFile1, let audioFile2 = audioFile2 else {
            throw RecordingError("The audio files of the recording could not be opened.")
        }
        func seconds(_ file: AVAudioFile) -> Double { Double(file.length) / file.processingFormat.sampleRate }
        let longer = seconds(audioFile2) > seconds(audioFile1) ? audioFile2 : audioFile1
        playerNode1.scheduleFile(audioFile1, at: nil, completionHandler: nil)
        playerNode2.scheduleFile(audioFile2, at: nil, completionHandler: nil)
        let audioSettings = MovieWriter.audioSettings(format: fileEncoder, quality: audioQuality, videoFormat: nil)
        let outputFormat = playerNode1.outputFormat(forBus: 0)
        let outputFile = try AVAudioFile(forWriting: url, settings: audioSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        engine.stop()
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        defer {
            // Played to the end; stopped, they start from the beginning again
            playerNode1.stop()
            playerNode2.stop()
            engine.disableManualRenderingMode()
            engine.stop()
            setupAudioEngine()
        }
        try engine.start()
        playerNode1.play()
        playerNode2.play()
        let duration = AVAudioFramePosition((seconds(longer) * engine.manualRenderingFormat.sampleRate).rounded())
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
        // Closed here, not when it is released, so that a file that could not be finished fails the check below
        outputFile.close()
        try RecordingMixer.verifyConversion(source: longer.url, output: url)
    }
    
    private func updateSysVol() {
        playerNode1.volume = sysVol
    }
    
    private func updateMicVol() {
        playerNode2.volume = micVol
    }
    
    /// `format` is the extension of what is exported. The panel puts it on the name and asks before replacing a file
    /// of that name, which is then the file that is written.
    private func showSavePanel(defaultFileName: String, format: String, exportMP3: Bool, completion: @escaping (URL?, Bool) -> Void) {
        panel.isReleasedWhenClosed = true
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = UTType(filenameExtension: format).map { [$0] } ?? []
        panel.allowsOtherFileTypes = false
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
