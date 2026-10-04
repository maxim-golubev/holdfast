//
//  SCContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AVFAudio
import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications
import SwiftLAME
import SwiftUI

/// Everything about one recording that must not change while it runs or while it is being finished: where it is
/// written and the settings it was started with. Built once in `prepRecord`. `stopRecording()` and what follows it
/// (audio mix, preview, notifications) work from their own copy, so changing a setting or starting the next
/// recording in the meantime cannot redirect them to another file.
struct RecordingContext {
    /// Tells this recording from the next one where a stop is requested asynchronously
    let id = UUID()
    let audioOnly: Bool
    /// Whether this recording has a microphone track, which the "recordMic" setting alone does not decide
    let recordMic: Bool
    let recordWinSound: Bool
    let remuxAudio: Bool
    let preventSleep: Bool
    let showPreview: Bool
    let trimAfterRecord: Bool
    let videoFormat: VideoFormat
    let audioFormat: AudioFormat
    let saveDirectory: String
    /// MP3 bitrate in kbit/s
    let audioQuality: Int
    /// What is written while recording: the video file, the audio file, or the .qma package for audio with a microphone
    let rawURL: URL
    /// Intermediate file of the audio mix after a video recording, nil when the audio tracks are not mixed
    let mixURL: URL?
    /// What the user ends up with
    let finalURL: URL
    /// Audio-only recordings: the system audio file, and the microphone file when there is one
    let systemAudioURL: URL?
    let micAudioURL: URL?
    
    var mixesAudio: Bool { mixURL != nil }
    var fileType: AVFileType { videoFormat == .mov ? .mov : .mp4 }
    var audioFileType: AVFileType { audioFormat == .flac || audioFormat == .opus ? .caf : .m4a }
    var audioFileEnding: String { RecordingContext.fileEnding(for: audioFormat) }
    /// MP3 is recorded as AAC and converted afterwards
    var audioEncoder: String { audioFormat == .mp3 ? AudioFormat.aac.rawValue : audioFormat.rawValue }
    
    private static func fileEnding(for format: AudioFormat) -> String {
        switch format {
        case .mp3, .aac, .alac: return "m4a"
        case .flac: return "flac"
        case .opus: return "ogg"
        }
    }
    
    init(audioOnly: Bool, recordMic: Bool, saveDirectory: String) {
        let recordWinSound = ud.bool(forKey: "recordWinSound")
        let remuxAudio = ud.bool(forKey: "remuxAudio")
        let videoFormat = VideoFormat(rawValue: ud.string(forKey: "videoFormat") ?? "") ?? .mp4
        let audioFormat = AudioFormat(rawValue: ud.string(forKey: "audioFormat") ?? "") ?? .aac
        self.audioOnly = audioOnly
        self.recordMic = recordMic
        self.recordWinSound = recordWinSound
        self.remuxAudio = remuxAudio
        self.preventSleep = ud.bool(forKey: "preventSleep")
        self.showPreview = ud.bool(forKey: "showPreview")
        self.trimAfterRecord = ud.bool(forKey: "trimAfterRecord")
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.saveDirectory = saveDirectory
        self.audioQuality = ud.integer(forKey: "audioQuality")
        
        let base = SCContext.getFilePath(directory: saveDirectory)
        if audioOnly {
            let ending = RecordingContext.fileEnding(for: audioFormat)
            let exported = audioFormat == .mp3 ? "mp3" : ending
            mixURL = nil
            if recordMic {
                let package = "\(base).qma".url
                rawURL = package
                systemAudioURL = package.appendingPathComponent("sys.\(ending)")
                micAudioURL = package.appendingPathComponent("mic.\(ending)")
                finalURL = remuxAudio ? "\(base).\(exported)".url : package
            } else {
                let file = "\(base).\(ending)".url
                rawURL = file
                systemAudioURL = file
                micAudioURL = nil
                finalURL = audioFormat == .mp3 ? "\(base).mp3".url : file
            }
        } else {
            let ending = videoFormat.rawValue
            finalURL = "\(base).\(ending)".url
            systemAudioURL = nil
            micAudioURL = nil
            if remuxAudio && recordMic && recordWinSound {
                // Written under a temporary name; the mix produces the final file
                mixURL = "\(base).\(ending).\(ending)".url
                rawURL = "\(base).\(ending).\(ending).\(ending)".url
            } else {
                mixURL = nil
                rawURL = finalURL
            }
        }
    }
}

/// A reason a recording could not be started, shown to the user as it is
struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

class SCContext {
    static var trimingList = [URL]()
    static var firstFrame: CMSampleBuffer?
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession!
    static var previewSession: AVCaptureSession!
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    /// The one queue all stream outputs are delivered on. The writer inputs and the timing state below are only used on it while capturing.
    static let sampleQueue = DispatchQueue(label: "QuickRecorder.samples")
    static var isCapturing = false
    /// Latest end time seen on any output, on the writer's timeline
    static var lastPTS: CMTime?
    /// Total paused time, subtracted from every buffer's timestamps
    static var timeOffset = CMTime.zero
    /// End of the system audio appended so far
    static var audioEndPTS: CMTime?
    /// Time of the last video frame appended, and that frame, which is written again while no new one arrives
    static var videoPTS: CMTime?
    static var lastVideoFrame: CMSampleBuffer?
    /// Whether `lastVideoFrame` owns its pixels instead of holding a surface of the stream
    static var lastVideoFrameIsCopy = false
    /// How far the video track may fall behind before the last frame is written again
    static let videoStallSeconds: Double = 3
    /// Whether the current recording has a microphone track. Decided when the recording starts, unlike the "recordMic" setting.
    static var recordsMic = false
    /// The device ScreenCaptureKit captures, nil for the system default input
    static var micCaptureDeviceID: String?
    static var micConverter: MicConverter?
    /// Set while the microphone track is behind the recording by more than `micStallSeconds` and is being filled with silence
    static var micStalled = false
    static let micStallSeconds: Double = 5
    /// How much of a recording an unclosed .mp4, .mov or .m4a file can be missing at its end
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    static var screenArea: NSRect?
    static var backgroundColor: CGColor = CGColor.black
    /// The recording in progress, set when it starts and taken by `stopRecording()`. Only assigned inside `sampleQueue.sync`.
    static var recording: RecordingContext?
    /// Entered for every stopped recording whose files are still being finished (audio mix, MP3 conversion, closing the
    /// microphone file) and left when that is done. The app waits for it before it quits.
    static let finishing = DispatchGroup()
    static var audioFile: AVAudioFile?
    static var vW: AVAssetWriter?
    static var vwInput, awInput, micInput: AVAssetWriterInput?
    static var startTime: Date?
    static var timePassed: TimeInterval = 0
    static var stream: SCStream?
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static var availableContent: SCShareableContent?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    static func updateAvailableContentSync() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent? = nil

        updateAvailableContent { content in
            result = content
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
    
    private static func updateAvailableContent(completion: @escaping (SCShareableContent?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [self] content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.updateAvailableContent() {_ in}
                    }
                default:
                    print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                completion(nil) // 在错误情况下返回 nil
                return
            }

            availableContent = content
            if let displays = content?.displays, !displays.isEmpty {
                completion(content) // 返回成功获取的 content
            } else {
                print("There needs to be at least one display connected!".local)
                completion(nil) // 如果没有显示器连接，则返回 nil
            }
        }
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined: requestPermissions()
                default: print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                return
            }
            availableContent = content
            assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
            completion()
        }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return SCContext.availableContent?.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return SCContext.availableContent?.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).map({ $0.owningApplication }) {
            if !apps.contains(app!) { apps.append(app!) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        var windows = [SCWindow]()
        windows = availableContent!.windows.filter {
            guard let app =  $0.owningApplication,
                  let title = $0.title else {//, !title.isEmpty else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter({$0.isOnScreen == true}) }
        if hideSelf && ud.bool(forKey: "hideSelf") { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon!.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    /// Path without extension for a new file. `directory` is the save directory a running recording was started with;
    /// without it the current setting is used.
    static func getFilePath(capture: Bool = false, directory: String? = nil) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        let directory = directory ?? ud.string(forKey: "saveDirectory") ?? (NSHomeDirectory() + "/Desktop")
        return directory + (capture ? "/Capturing at ".local : "/Recording at ".local) + dateFormatter.string(from: Date())
    }
    
    /// The defaults are the current settings. Code that works on a recording passes that recording's values instead.
    static func updateAudioSettings(format: String = ud.string(forKey: "audioFormat") ?? "",
                                    quality: Int = ud.integer(forKey: "audioQuality"),
                                    videoFormat: String = ud.string(forKey: "videoFormat") ?? "") -> [String : Any] {
        var audioSettings: [String : Any] = [AVSampleRateKey : 48000, AVNumberOfChannelsKey : 2] // reset audioSettings
        let bitRate = quality * 1000
        switch format {
        case AudioFormat.mp3.rawValue: fallthrough
        case AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            audioSettings[AVFormatIDKey] = videoFormat != VideoFormat.mp4.rawValue ? kAudioFormatOpus : kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] =  bitRate
        default:
            assertionFailure("unknown audio format while setting audio settings: ".local + format)
        }
        return audioSettings
    }
    
    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black  }
        if color == BackgroundType.wallpaper.rawValue { return CGColor.black }
        switch color {
            case "clear": backgroundColor = CGColor.clear
            case "black": backgroundColor = CGColor.black
            case "white": backgroundColor = CGColor.white
            case "gray": backgroundColor = NSColor.systemGray.cgColor
            case "yellow": backgroundColor = NSColor.systemYellow.cgColor
            case "orange": backgroundColor = NSColor.systemOrange.cgColor
            case "green": backgroundColor = NSColor.systemGreen.cgColor
            case "blue": backgroundColor = NSColor.systemBlue.cgColor
            case "red": backgroundColor = NSColor.systemRed.cgColor
            default: backgroundColor = ud.cgColor(forKey: "userColor") ?? CGColor.black
        }
        return backgroundColor
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    
    private static func requestPermissions() {
        DispatchQueue.main.async {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs screen recording permissions, even if you only intend on recording audio.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            NSApp.terminate(self)
        }
    }
    
    static func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized, .restricted, .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                let alert = createAlert(title: "Permission Required",
                                                           message: "QuickRecorder needs this permission to record your camera or mobile device.",
                                                           button1: "Open Settings",
                                                           button2: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        @unknown default:
            break
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        do {
            var wallpaper: NSImage?
            try wallpaper = NSImage(data: Data(contentsOf: url))
            if let w = wallpaper { return w }
        } catch {
            print("load wallpaper error: \(error)")
        }
        return nil
    }
    
    static func getRecordingLength() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        if isPaused { return formatter.string(from: timePassed) ?? "Unknown".local }
        timePassed = Date.now.timeIntervalSince(startTime ?? Date.now)
        return formatter.string(from: timePassed) ?? "Unknown".local
    }
    
    static func isCameraRunning() -> Bool {
        var preview = false
        var capture = false
        if let session = previewSession { preview = session.isRunning }
        if let session = captureSession { capture = session.isRunning }
        return (preview || capture)
    }
    
    static func pauseRecording() {
        sampleQueue.sync {
            isPaused.toggle()
            if !isPaused { isResume = true }
        }
        PopoverState.shared.isPaused = isPaused
        if !isPaused {
            startTime = Date.now.addingTimeInterval(-1) - SCContext.timePassed
        }
    }
    
    /// On `sampleQueue`. Returns whether the buffer was written. An input that is not ready drops the buffer;
    /// an append that fails means the file can no longer be written, which ends the recording.
    static func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        guard input.isReadyForMoreMediaData else { return false }
        if input.append(buffer) { return true }
        abortRecording(reason: writeFailure(vW?.error))
        return false
    }
    
    static func writeFailure(_ error: Error?) -> String {
        return String(format: "The recording could not be written: %@".local, error?.localizedDescription ?? "Unknown error".local)
    }
    
    /// On `sampleQueue`. The one way a recording ends when it cannot go on: nothing more is appended, and the
    /// recording is stopped on the main thread, which closes the file as far as possible and tells the user why.
    static func abortRecording(reason: String) {
        guard isCapturing, let id = recording?.id else { return }
        isCapturing = false
        DispatchQueue.main.async { stopRecording(only: id, earlyReason: reason) }
    }
    
    /// Undoes a start that failed before anything was recorded: the writer, the files it created, the stream and
    /// the recording state. Returns false, having done nothing, when `recording` is not the current recording any more.
    static func discardStart(_ recording: RecordingContext) -> Bool {
        var writer: AVAssetWriter?
        let current = sampleQueue.sync { () -> Bool in
            guard SCContext.recording?.id == recording.id else { return false }
            SCContext.recording = nil
            isCapturing = false
            writer = vW
            vW = nil
            vwInput = nil
            awInput = nil
            micInput = nil
            audioFile = nil
            firstFrame = nil
            lastVideoFrame = nil
            videoPTS = nil
            lastPTS = nil
            micConverter = nil
            micStalled = false
            recordsMic = false
            return true
        }
        guard current else { return false }
        // Also deletes the file the writer created
        writer?.cancelWriting()
        // Nothing was recorded, so what is left is an empty file or a package without audio
        try? fd.removeItem(at: recording.rawURL)
        stream = nil
        streamType = nil
        startTime = nil
        window = nil
        screen = nil
        DispatchQueue.main.async {
            if let w = NSApp.windows.first(where:  { $0.title == "Area Overlayer".local }) { w.close() }
            closeRecordingWindows()
            updateStatusBar()
        }
        return true
    }
    
    /// Main thread. The control panel and the camera overlays that accompany a recording.
    private static func closeRecordingWindows() {
        controlPanel.close()
        if isCameraRunning() {
            if camWindow.isVisible { camWindow.close() }
            if deviceWindow.isVisible { deviceWindow.close() }
            if let preview = previewSession { preview.stopRunning() }
            if let capture = captureSession { capture.stopRunning() }
        }
    }
    
    /// A modal alert on the main thread that does not hold up the caller
    static func showAlertLater(title: String, message: String) {
        // Not DispatchQueue.main.async: a modal alert inside a main queue block holds up every block queued behind it,
        // which includes the work that finishes a recording
        RunLoop.main.perform(inModes: [.common]) {
            NSApp.activate(ignoringOtherApps: true)
            _ = createAlert(level: .critical, title: title, message: message, button1: "OK").runModal()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    
    /// For a failure that must not be missed: a notification, and an alert because notifications may be off or silenced
    static func reportFailure(title: String, message: String) {
        showNotification(title: title, body: message, id: "quickrecorder.error.\(UUID().uuidString)")
        showAlertLater(title: title, message: message)
    }
    
    /// Stops the current recording. Main thread. With `id`, only when that recording is still the current one.
    /// `earlyReason` says why the recording ends without the user having stopped it; the user is told so.
    static func stopRecording(only id: UUID? = nil, earlyReason: String? = nil) {
        // The recording being stopped. Everything below, the completion handlers included, works from this copy and
        // the locals captured here: by the time they run, the statics and the settings may belong to the next recording.
        let stopped = sampleQueue.sync { () -> RecordingContext? in
            guard let current = SCContext.recording, id == nil || current.id == id else { return nil }
            SCContext.recording = nil
            return current
        }
        guard let recording = stopped else {
            // Nothing is being recorded, or this recording is already being stopped
            if id == nil { SleepPreventer.shared.allowSleep() }
            return
        }
        DiskSpace.stopMonitoring()
        if recording.preventSleep { SleepPreventer.shared.allowSleep() }
        autoStop = 0
        recordCam = ""
        recordDevice = ""
        isMagnifierEnabled = false
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        AppDelegate.shared.stopGlobalMouseMonitor()

        if let w = NSApp.windows.first(where:  { $0.title == "Area Overlayer".local }) { w.close() }
        
        stream?.stopCapture()
        stream = nil
        let hadMic = recording.recordMic
        let audioOnly = recording.audioOnly
        var writer: AVAssetWriter?
        var frame: CMSampleBuffer?
        var sessionStarted = false
        // Buffers are appended on sampleQueue. Finishing the inputs there means no append runs alongside or after it.
        sampleQueue.sync {
            isCapturing = false
            sessionStarted = startTime != nil
            // The writer and its inputs leave the statics with the recording. `prepRecord` clears them as well, so a
            // recording that never got as far as creating a writer has none here, not the one of an earlier recording.
            writer = vW
            let videoInput = vwInput
            let audioInput = awInput
            let microphoneInput = micInput
            vW = nil
            vwInput = nil
            awInput = nil
            micInput = nil
            if hadMic, let input = microphoneInput {
                // Bring the microphone track to the length of the recording, whatever the microphone delivered
                if let end = lastPTS, writer?.status == .writing {
                    micConverter?.fill(upTo: end) { buffer in
                        var waited = 0
                        while !input.isReadyForMoreMediaData && waited < 200 {
                            usleep(5000)
                            waited += 1
                        }
                        return input.isReadyForMoreMediaData && input.append(buffer)
                    }
                }
                input.markAsFinished()
            }
            if !audioOnly {
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
            }
            audioFile = nil // close audio file
            frame = firstFrame
            firstFrame = nil
            lastVideoFrame = nil
            videoPTS = nil
            lastPTS = nil
            micConverter = nil
            micStalled = false
            recordsMic = false
        }
        let savedSoFar = String(format: "The recording up to that point is saved as: %@".local, recording.finalURL.path)
        var videoSaved = false
        if !audioOnly {
            if !sessionStarted, let unused = writer {
                // No frame arrived, so there is nothing to close: the empty file is removed and the report below says so
                unused.cancelWriting()
                writer = nil
            }
            // A writer that already failed has nothing to finish
            if let writer = writer, writer.status == .writing {
                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()
                writer.finishWriting { dispatchGroup.leave() }
                dispatchGroup.wait()
                videoSaved = writer.status == .completed
            }
            if !videoSaved {
                print("Video writing failed with status: \(String(describing: writer?.status)), error: \(String(describing: writer?.error))")
                var body = earlyReason ?? ""
                if let error = writer?.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                if body.isEmpty { body = writer == nil ? "The recording did not start, nothing was written.".local : "Unknown error".local }
                if fd.fileExists(atPath: recording.rawURL.path) {
                    // The file is written in fragments, so it plays up to the last few seconds without having been closed.
                    // It gets its final name; no mix is attempted on it.
                    let kept = recording.mixURL.map { keepUnmixedRecording(written: recording.rawURL, partialMix: $0, final: recording.finalURL) } ?? recording.rawURL
                    body += " " + String(format: "The file could not be closed. What was written before that was kept as: %@".local, kept.path)
                }
                reportFailure(title: earlyReason == nil ? "Failed to save file".local : "Recording Stopped Early".local, message: body)
            } else {
                if let reason = earlyReason { reportFailure(title: "Recording Stopped Early".local, message: reason + " " + savedSoFar) }
                if recording.mixesAudio {
                    finishing.enter()
                    DispatchQueue.global(qos: .userInitiated).async { mixRecording(recording, frame: frame) { finishing.leave() } }
                }
            }
        } else if !sessionStarted {
            // No audio arrived, so the files are empty. The microphone writer never got a session and cannot be closed.
            writer?.cancelWriting()
            try? fd.removeItem(at: recording.rawURL)
            let body = (earlyReason.map { $0 + " " } ?? "") + "No audio arrived, nothing was recorded.".local
            reportFailure(title: earlyReason == nil ? "Failed to save file".local : "Recording Stopped Early".local, message: body)
        } else if hadMic, let writer = writer {
            let title = earlyReason == nil ? "Failed to save file".local : "Recording Stopped Early".local
            // The microphone file did not close: the package is kept as it is and is not mixed
            let reportUnclosed = {
                var body = earlyReason ?? ""
                if let error = writer.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                body += (body.isEmpty ? "" : " ") + String(format: "The microphone file could not be closed. The recording was kept with separate audio files: %@".local, recording.rawURL.path)
                reportFailure(title: title, message: body)
            }
            if writer.status == .writing {
                // The package is only read once the microphone file is complete
                finishing.enter()
                writer.finishWriting {
                    DispatchQueue.main.async {
                        guard writer.status == .completed else {
                            reportUnclosed()
                            finishing.leave()
                            return
                        }
                        if let reason = earlyReason { reportFailure(title: title, message: reason + " " + savedSoFar) }
                        finishAudioRecording(recording) { finishing.leave() }
                    }
                }
            } else {
                reportUnclosed()
            }
        } else {
            if let reason = earlyReason { reportFailure(title: "Recording Stopped Early".local, message: reason + " " + savedSoFar) }
            finishing.enter()
            finishAudioRecording(recording) { finishing.leave() }
        }
        
        DispatchQueue.main.async { closeRecordingWindows() }
        
        isPaused = false
        hideMousePointer = false
        window = nil
        screen = nil
        startTime = nil
        AppDelegate.shared.presenterType = "OFF"
        updateStatusBar()
        
        if videoSaved && !recording.mixesAudio {
            let url = recording.finalURL
            if !recording.showPreview {
                let title = "Recording Completed".local
                let body = String(format: "File saved to: %@".local, url.path)
                let id = "quickrecorder.completed.\(UUID().uuidString)"
                showNotification(title: title, body: body, id: id)
            } else {
                showPreview(path: url.path, frame: frame)
            }
            if recording.trimAfterRecord {
                AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
            }
        }
        
        streamType = nil
    }
    
    /// Mixes the audio tracks of a finished video recording and presents the result. `completion` is called once,
    /// when the recording has its final name.
    private static func mixRecording(_ recording: RecordingContext, frame: CMSampleBuffer?, completion: @escaping () -> Void) {
        guard let mixURL = recording.mixURL else { completion(); return }
        let finished: (Result<URL, Error>) -> Void = { result in
            switch result {
            case .success(let url):
                print("Exported video to \(String(describing: url.path))")
                if !recording.showPreview {
                    showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "quickrecorder.completed.\(UUID().uuidString)")
                }
                DispatchQueue.main.async {
                    if recording.trimAfterRecord {
                        AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
                    } else if recording.showPreview {
                        showPreview(path: url.path, frame: frame)
                    }
                }
            case .failure(let error):
                print("Failed to export video: \(error.localizedDescription)")
                let kept = keepUnmixedRecording(written: recording.rawURL, partialMix: mixURL, final: recording.finalURL)
                let body = String(format: "%@ The recording was kept with separate audio tracks: %@".local, error.localizedDescription, kept.path)
                showNotification(title: "Audio Mix Failed".local, body: body, id: "quickrecorder.error.\(UUID().uuidString)")
                if recording.showPreview {
                    DispatchQueue.main.async { showPreview(path: kept.path, frame: frame) }
                }
            }
            completion()
        }
        // The mix writes a second file of about the same size next to the recording. On a nearly full disk the
        // recording is kept as it is rather than put at risk.
        guard DiskSpace.hasRoomForCopy(of: recording.rawURL) else {
            finished(.failure(RecordingError("Not enough free disk space to mix the audio tracks.".local)))
            return
        }
        mixAudioTracks(videoURL: recording.rawURL, audioURL: mixURL, outputURL: recording.finalURL, fileType: recording.fileType, completion: finished)
    }
    
    /// What follows an audio-only recording once its files are closed: MP3 conversion, the mix of a .qma package, or just the report.
    /// `completion` is called once, when the files are in their final state.
    private static func finishAudioRecording(_ recording: RecordingContext, completion: @escaping () -> Void) {
        if recording.audioFormat == .mp3 && !recording.recordMic {
            guard let source = recording.systemAudioURL else { completion(); return }
            let output = recording.finalURL
            Task {
                defer { completion() }
                do {
                    try await m4a2mp3(inputUrl: source, outputUrl: output, bitrate: recording.audioQuality)
                    try? fd.removeItem(at: source)
                    if !recording.showPreview {
                        let title = "Recording Completed".local
                        let body = String(format: "File saved to: %@".local, output.path)
                        let id = "quickrecorder.completed.\(UUID().uuidString)"
                        showNotification(title: title, body: body, id: id)
                    } else {
                        DispatchQueue.main.async { showPreview(path: output.path, image: NSImage(named: "audioIcon")) }
                    }
                } catch {
                    let body = String(format: "%@ The recording was kept as: %@".local, error.localizedDescription, source.path)
                    showNotification(title: "Failed to save file".local, body: body, id: "quickrecorder.error.\(UUID().uuidString)")
                }
            }
        } else if recording.remuxAudio && recording.recordMic {
            let package = recording.rawURL
            if let document = try? qmaPackageHandle.load(from: package) {
                let audioPlayerManager = AudioPlayerManager()
                audioPlayerManager.loadAudioFiles(format: document.info.format, package: package, encoder: document.info.encoder, saveMP3: document.info.exportMP3)
                audioPlayerManager.sysVol = document.info.sysVol
                audioPlayerManager.micVol = document.info.micVol
                // With the settings the recording was started with, not the current ones
                audioPlayerManager.saveFile(recording.finalURL, saveAsMP3: document.info.exportMP3, audioQuality: recording.audioQuality, videoFormat: recording.videoFormat.rawValue, completion: completion)
            } else {
                let body = String(format: "The recording was kept with separate audio files: %@".local, package.path)
                showNotification(title: "Audio Mix Failed".local, body: body, id: "quickrecorder.error.\(UUID().uuidString)")
                completion()
            }
        } else {
            if !recording.showPreview {
                let title = "Recording Completed".local
                let body = String(format: "File saved to: %@".local, recording.rawURL.path)
                let id = "quickrecorder.completed.\(UUID().uuidString)"
                showNotification(title: title, body: body, id: id)
            } else {
                showPreview(path: recording.rawURL.path, image: NSImage(named: "qmaIcon"))
            }
            completion()
        }
    }
    
    /// After a failed audio mix: removes what the mix left behind and gives the recording, which was written under a
    /// temporary name for the mix, its final name. Only the three given files are touched. Returns where the recording is afterwards.
    static func keepUnmixedRecording(written: URL, partialMix: URL, final: URL) -> URL {
        try? fd.removeItem(at: partialMix)
        try? fd.removeItem(at: final)
        do {
            try fd.moveItem(at: written, to: final)
            return final
        } catch {
            print("Failed to rename the unmixed recording: \(error.localizedDescription)")
            return written
        }
    }
    
    /// A copy of a video frame with pixels of its own. A frame as ScreenCaptureKit delivers it holds one of the
    /// stream's few surfaces for as long as it is kept. Nil when the pixels cannot be copied.
    static func detachedCopy(of frame: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = frame.imageBuffer else { return nil }
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                                  CVPixelBufferGetPixelFormatType(source), attributes, &created) == kCVReturnSuccess,
              let copy = created else { return nil }
        CVBufferPropagateAttachments(source, copy)
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }
        func copyRows(from: UnsafeMutableRawPointer?, _ fromRow: Int, to: UnsafeMutableRawPointer?, _ toRow: Int, rows: Int) -> Bool {
            guard let from = from, let to = to else { return false }
            for row in 0..<rows { memcpy(to + row * toRow, from + row * fromRow, min(fromRow, toRow)) }
            return true
        }
        if CVPixelBufferIsPlanar(source) {
            guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(copy) else { return nil }
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard copyRows(from: CVPixelBufferGetBaseAddressOfPlane(source, plane), CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                               to: CVPixelBufferGetBaseAddressOfPlane(copy, plane), CVPixelBufferGetBytesPerRowOfPlane(copy, plane),
                               rows: min(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(copy, plane))) else { return nil }
            }
        } else {
            guard copyRows(from: CVPixelBufferGetBaseAddress(source), CVPixelBufferGetBytesPerRow(source),
                           to: CVPixelBufferGetBaseAddress(copy), CVPixelBufferGetBytesPerRow(copy),
                           rows: min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(copy))) else { return nil }
        }
        guard let description = try? CMVideoFormatDescription(imageBuffer: copy) else { return nil }
        let timing = CMSampleTimingInfo(duration: frame.duration, presentationTimeStamp: frame.presentationTimeStamp, decodeTimeStamp: .invalid)
        return try? CMSampleBuffer(imageBuffer: copy, formatDescription: description, sampleTiming: timing)
    }
    
    /// Shows the floating preview for a finished recording. `frame` is that recording's first video frame, `image` an icon to show instead.
    static func showPreview(path: String, frame: CMSampleBuffer? = nil, image: NSImage? = nil) {
        var previewImage: NSImage?
        let previewURL = fd.temporaryDirectory.appendingPathComponent("qr-preview.jpg")
        if image == nil { frame?.nsImage?.saveToFile(previewURL, type: .jpeg) }
        
        if let i = image { previewImage = i } else { previewImage = NSImage(contentsOf: previewURL) }
        if let previewImage = previewImage, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(self)
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL, bitrate: Int = ud.integer(forKey: "audioQuality")) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(bitrate)),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
    
    static func getCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    /// The chosen microphone: an AVCaptureDevice uniqueID, or "default" to follow the system default input.
    /// A selection is kept while its device is not connected.
    ///
    /// Earlier versions stored the device's name under "micDevice". That is converted the first time this is read;
    /// if the device is absent then, its name stands in for the ID until the device is seen again.
    static func selectedMicID() -> String {
        let mics = getMicrophone()
        if let id = ud.string(forKey: "micDeviceID") {
            if id != "default", !mics.contains(where: { $0.uniqueID == id }), let device = mics.first(where: { $0.localizedName == id }) {
                ud.set(device.uniqueID, forKey: "micDeviceID")
                return device.uniqueID
            }
            return id
        }
        let name = ud.string(forKey: "micDevice") ?? "default"
        let id = name == "default" ? name : (mics.first(where: { $0.localizedName == name })?.uniqueID ?? name)
        ud.set(id, forKey: "micDeviceID")
        return id
    }
    
    /// Name of the chosen microphone for display, kept under "micDevice" so that it is known while the device is absent
    static func selectedMicName() -> String {
        let id = selectedMicID()
        if let device = getMicrophone().first(where: { $0.uniqueID == id }) { return device.localizedName }
        let name = ud.string(forKey: "micDevice") ?? "default"
        return name == "default" ? id : name
    }
    
    /// Selects a microphone by name, or the system default for "default". Returns false when there is no such device.
    static func selectMic(named name: String) -> Bool {
        if name == "default" {
            ud.set("default", forKey: "micDeviceID")
        } else if let device = getMicrophone().first(where: { $0.localizedName == name }) {
            ud.set(device.uniqueID, forKey: "micDeviceID")
        } else {
            return false
        }
        ud.set(name, forKey: "micDevice")
        return true
    }
    
    static func getiDevice() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }
    
    /// Returns the buffer with `offset` subtracted from its timestamps, or the buffer itself when there is nothing to shift
    static func retime(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid else { return nil }
        if offset.value == 0 { return sample }
        guard var timing = try? sample.sampleTimingInfos(), !timing.isEmpty else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timing)
    }
    
    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send：\(error.localizedDescription)") }
        }
    }
    
    /// Mixes the audio tracks of `videoURL` into one and writes the result to `outputURL`, using `audioURL` for the
    /// intermediate audio file. On success `videoURL` and `audioURL` are removed. It touches no other files and reads
    /// no settings, so a recording started while this runs is not affected.
    static func mixAudioTracks(videoURL: URL, audioURL audioOutputURL: URL, outputURL: URL, fileType: AVFileType, completion: @escaping (Result<URL, Error>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")
        
        let asset = AVAsset(url: videoURL)
        let audioOnlyComposition = AVMutableComposition()
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
            return
        }
        
        for audioTrack in audioTracks {
            if let compositionAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                    return
                }
            }
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.trackID = $0.trackID
            return parameters
        }
        
        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(NSError(domain: "AudioExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session."])))
            return
        }
        audioExportSession.outputURL = audioOutputURL
        audioExportSession.outputFileType = fileType
        audioExportSession.audioMix = audioMix
        
        audioExportSession.exportAsynchronously {
            /*var exportStatus: AVAssetExportSession.Status = .unknown
            
            // Loop until export session is completed, failed, or cancelled
            while exportStatus != .completed && exportStatus != .failed && exportStatus != .cancelled {
                exportStatus = audioExportSession.status
                Thread.sleep(forTimeInterval: 0.1)
            }*/
            
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: audioOutputURL)
                let composition = AVMutableComposition()
                
                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    completion(.failure(NSError(domain: "VideoTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get video track."])))
                    return
                }
                
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
                } catch {
                    completion(.failure(NSError(domain: "VideoTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert video track: \(error.localizedDescription)"])))
                    return
                }
                
                let audioTracks = audioAsset.tracks(withMediaType: .audio)
                guard audioTracks.count >= 1 else {
                    completion(.failure(NSError(domain: "AudioTrackError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not enough audio tracks found."])))
                    return
                }
                
                for audioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                        } catch {
                            completion(.failure(NSError(domain: "AudioTrackInsertionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert audio track: \(error.localizedDescription)"])))
                            return
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    completion(.failure(NSError(domain: "ExportSessionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session."])))
                    return
                }
                
                exportSession.outputURL = outputURL
                exportSession.outputFileType = fileType
                exportSession.audioMix = audioMix
                
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        // Only the files this call was given are removed
                        try? fd.removeItem(at: videoURL)
                        try? fd.removeItem(at: audioOutputURL)
                        completion(.success(outputURL))
                    case .failed:
                        completion(.failure(exportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
                    case .cancelled:
                        completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
                    default:
                        completion(.failure(NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export ended in an unexpected state."])))
                    }
                }
            case .failed:
                completion(.failure(audioExportSession.error ?? NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed for an unknown reason."])))
            case .cancelled:
                completion(.failure(NSError(domain: "ExportCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled."])))
            default:
                completion(.failure(NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export ended in an unexpected state."])))
            }
        }
    }
}
