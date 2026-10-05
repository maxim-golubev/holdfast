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
    /// Whether this recording captures system audio. The "recordWinSound" setting alone does not decide that
    /// either: a hotkey start and an audio-only recording always do.
    let systemAudio: Bool
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
    /// What the audio mix after a video recording writes before it is checked and gets the final name, nil when
    /// the audio tracks are not mixed
    let mixURL: URL?
    /// The name the recording as it was written (two audio tracks) gets when it is kept, nil when the audio tracks are not mixed
    let unmixedURL: URL?
    /// Whether the recording as it was written stays next to the mixed one
    let keepUnmixed: Bool
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
    
    init(audioOnly: Bool, recordMic: Bool, fastStart: Bool, saveDirectory: String) {
        let systemAudio = ud.bool(forKey: "recordWinSound") || fastStart || audioOnly
        let remuxAudio = ud.bool(forKey: "remuxAudio")
        let videoFormat = VideoFormat(rawValue: ud.string(forKey: "videoFormat") ?? "") ?? .mp4
        let audioFormat = AudioFormat(rawValue: ud.string(forKey: "audioFormat") ?? "") ?? .aac
        self.audioOnly = audioOnly
        self.recordMic = recordMic
        self.systemAudio = systemAudio
        self.remuxAudio = remuxAudio
        self.preventSleep = ud.bool(forKey: "preventSleep")
        self.showPreview = ud.bool(forKey: "showPreview")
        self.trimAfterRecord = ud.bool(forKey: "trimAfterRecord")
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.saveDirectory = saveDirectory
        self.audioQuality = ud.integer(forKey: "audioQuality")
        self.keepUnmixed = ud.bool(forKey: "keepUnmixed")
        
        let files = RecordingFiles(base: SCContext.getFilePath(directory: saveDirectory), audioOnly: audioOnly,
                                   recordMic: recordMic, systemAudio: systemAudio, remuxAudio: remuxAudio,
                                   videoEnding: videoFormat.rawValue, audioEnding: RecordingContext.fileEnding(for: audioFormat),
                                   exportsMP3: audioFormat == .mp3)
        rawURL = files.rawURL
        mixURL = files.mixURL
        unmixedURL = files.unmixedURL
        finalURL = files.finalURL
        systemAudioURL = files.systemAudioURL
        micAudioURL = files.micAudioURL
    }
}

/// The recording side is in exactly one of these. A recording is started from `idle` only and stopped from
/// `recording` only; `SCContext.state` describes who moves it on.
enum RecordingState {
    case idle
    /// From the request to start until the capture runs
    case starting
    case recording
    /// The capture is being stopped and the writer's inputs are being finished
    case stopping
    /// The file is being closed and post-processed (audio mix, MP3 conversion)
    case finalizing
}

/// A reason a recording could not be started, shown to the user as it is
struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

class SCContext {
    static var trimingList = [URL]()
    /// Small picture of the recording's first frame for the preview. An image, not the frame: a frame as delivered
    /// holds one of the stream's surfaces, and a full-size copy would sit in memory for the whole recording.
    static var firstFrame: NSImage?
    static var autoStop = 0
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    /// The one queue all stream outputs are delivered on. The writer inputs and the timing state below are only used on it while capturing.
    static let sampleQueue = DispatchQueue(label: "QuickRecorder.samples")
    static var isCapturing = false
    /// Latest end time seen on any output, on the writer's timeline
    static var lastPTS: CMTime?
    /// Total paused time, subtracted from every buffer's timestamps
    static var timeOffset = CMTime.zero
    /// Where the writer's session starts on the timeline, nil until the first frame (or audio buffer, when only audio is recorded)
    static var sessionStart: CMTime?
    /// The end time of the buffer that arrived last and the uptime at which it arrived. `RecordingMonitor` tells the
    /// present time on the buffers' clock from it while nothing arrives.
    static var clockAnchor: (raw: CMTime, uptime: UInt64)?
    /// End of the system audio appended so far, silence included
    static var audioEndPTS: CMTime?
    /// Format of the system audio ScreenCaptureKit delivered last
    static var audioFormatDescription: CMAudioFormatDescription?
    /// Time of the last video frame appended, and that frame, which is written again while no new one arrives
    static var videoPTS: CMTime?
    static var lastVideoFrame: CMSampleBuffer?
    /// Whether `lastVideoFrame` owns its pixels instead of holding a surface of the stream
    static var lastVideoFrameIsCopy = false
    /// How long no frame may arrive before the last one is written again
    static let videoStallSeconds: Double = 1
    /// Whether the current recording has a microphone track. Decided when the recording starts, unlike the "recordMic" setting.
    static var recordsMic = false
    /// The device ScreenCaptureKit is asked to capture when the recording starts, nil for the system default input
    static var micCaptureDeviceID: String?
    /// The microphone setting this recording was started with: a device's uniqueID, or "default"
    static var micSelection = "default"
    /// The device the microphone is being captured from. `MicDevices` changes it when the devices change.
    static var micActiveDeviceID: String?
    /// The configuration the stream was started with, kept to update it when the microphone changes
    static var streamConfiguration: SCStreamConfiguration?
    static var micConverter: MicConverter?
    /// How much of a recording an unclosed .mp4, .mov or .m4a file can be missing at its end
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    static var screenArea: NSRect?
    /// The recording in progress, set when it starts and taken by `stopRecording()`. Only assigned inside `sampleQueue.sync`.
    static var recording: RecordingContext?
    /// Where the recording side is. Main thread only, and only changed by `beginStart`, `endFailedStart`,
    /// `enterRecording`, `stopRecording` and `finish`.
    private(set) static var state = RecordingState.idle {
        didSet {
            guard state != oldValue else { return }
            print("Recording state: \(oldValue) -> \(state)")
            RecordingHealth.shared.saving = isSaving
            if state != .finalizing { RecordingHealth.shared.mixProgress = nil }
            updateStatusBar()
            guard state == .idle else { return }
            // The floating controller stayed open to show "Saving…" where the menu bar is not visible
            controlPanel.close()
            let handlers = idleHandlers
            idleHandlers = []
            handlers.forEach { $0() }
        }
    }
    /// Whether a stopped recording is still being closed or post-processed
    static var isSaving: Bool { state == .stopping || state == .finalizing }
    /// A stop that was asked for while the capture was still starting
    private static var pendingStop: (id: UUID?, reason: String?)?
    /// When the capture began to run (`enterRecording`). A stop right after it that recorded nothing is a cancelled start, not a failure.
    private static var enteredRecording: Date?
    private static var idleHandlers = [() -> Void]()
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
                completion(nil)
                return
            }

            availableContent = content
            if let displays = content?.displays, !displays.isEmpty {
                completion(content)
            } else {
                print("There needs to be at least one display connected!".local)
                completion(nil)
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
            if content?.displays.isEmpty != false { print("There needs to be at least one display connected!".local) }
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
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).compactMap({ $0.owningApplication }) {
            if !apps.contains(app) { apps.append(app) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        guard let content = availableContent else { return [] }
        var windows = content.windows.filter {
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
        icon?.size = NSSize(width: 69, height: 69)
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
        let directory = directory ?? ud.string(forKey: "saveDirectory") ?? (NSHomeDirectory() + "/Desktop")
        return RecordingFiles.basePath(directory: directory, prefix: capture ? "Capturing at ".local : recordingNamePrefix.local, date: Date())
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
            // An unknown format must not cost the recording: AAC goes into every container used here
            print("Unknown audio format \"\(format)\", using AAC")
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        }
        return audioSettings
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        onMainRunLoop {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openPrivacySettings("Privacy_Microphone")
            }
        }
    }
    
    private static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
    
    /// The frame rate a recording is captured and encoded at, whatever the "frameRate" setting holds (a script can
    /// set any number): never 0 or negative, which would make an invalid frame interval
    static func captureFrameRate(_ setting: Int) -> Int {
        return min(240, max(1, setting))
    }
    
    /// The area last recorded on the screen with that name, as the area selector stored it
    static func savedArea(forScreen name: String) -> NSRect? {
        guard let area = ud.dictionary(forKey: "savedArea")?[name] as? [String: Any] else { return nil }
        func value(_ key: String) -> CGFloat? { (area[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = value("x"), let y = value("y"), let width = value("width"), let height = value("height"),
              width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    /// Remembers `area` for the screen with that name. The areas of the other screens stay as they are.
    static func saveArea(_ area: NSRect, forScreen name: String) {
        var saved = ud.dictionary(forKey: "savedArea") ?? [:]
        saved[name] = ["x": Double(area.origin.x), "y": Double(area.origin.y), "width": Double(area.width), "height": Double(area.height)]
        ud.set(saved, forKey: "savedArea")
    }
    
    private static func requestPermissions() {
        onMainRunLoop {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs screen recording permissions, even if you only intend on recording audio.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openPrivacySettings("Privacy_ScreenCapture")
            }
            NSApp.terminate(self)
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
        if !isPaused { timePassed = Date.now.timeIntervalSince(startTime ?? Date.now) }
        return lengthText(timePassed)
    }
    
    /// "07:05" up to an hour, "1:07:05" from then on. The status bar makes room for the longer form (`getStatusBarWidth`).
    static func lengthText(_ interval: TimeInterval) -> String {
        return Timeline.lengthText(interval)
    }
    
    static func pauseRecording() {
        sampleQueue.sync {
            isPaused.toggle()
            if !isPaused { isResume = true }
            // Nothing arrives to replace the last frame while paused, however long that is
            if isPaused { detachLastVideoFrame() }
            // The timeline is put together anew at the first buffer after the pause
            micConverter?.realign()
            RecordingMonitor.resumeWaited = false
        }
        PopoverState.shared.isPaused = isPaused
        if !isPaused {
            startTime = Date.now.addingTimeInterval(-1) - SCContext.timePassed
        }
    }
    
    /// On `sampleQueue`. Turns a time on the buffers' clock into a time on the writer's timeline, which leaves out the
    /// pauses. The first time after a pause continues where the recording left off: the paused time is taken out of
    /// every track alike, which keeps video, system audio and microphone in sync.
    static func timelineTime(_ raw: CMTime) -> CMTime {
        if isResume {
            isResume = false
            if let last = lastPTS {
                timeOffset = Timeline.pauseOffset(resumingAt: raw, last: last, current: timeOffset)
                print("time removed for pauses: \(CMTimeGetSeconds(timeOffset))")
            }
        }
        return CMTimeSubtract(raw, timeOffset)
    }
    
    /// On `sampleQueue`. Keeps `lastPTS` at the latest end time of anything on the timeline.
    static func noteEnd(_ end: CMTime?) {
        lastPTS = Timeline.latestEnd(end, after: lastPTS)
    }
    
    /// On `sampleQueue`. Starts the writer's session at `pts`: at the first complete video frame, or at the first
    /// system audio buffer of an audio-only recording. `sessionStart` is only set here, together with the session,
    /// and every path that appends to a track checks it first, so nothing reaches the writer before its session
    /// has started. `startTime` is the wall clock for the status bar and decides nothing. False when the writer
    /// cannot take a session.
    static func beginSession(at pts: CMTime) -> Bool {
        if let writer = vW {
            guard writer.status == .writing else { return false }
            writer.startSession(atSourceTime: pts)
        }
        sessionStart = pts
        micConverter?.start(at: pts)
        startTime = Date.now
        return true
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
    /// the recording state, which goes back to idle. Any thread. A recording that is starting cannot be stopped
    /// (a stop is put off until the capture runs), so `recording` is the current one.
    static func discardStart(_ recording: RecordingContext) {
        var writer: AVAssetWriter?
        sampleQueue.sync {
            guard SCContext.recording?.id == recording.id else { return }
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
            sessionStart = nil
            clockAnchor = nil
            micConverter = nil
            recordsMic = false
            RecordingMonitor.stop()
        }
        // Also deletes the file the writer created
        writer?.cancelWriting()
        // Nothing was recorded, so what is left is an empty file or a package without audio
        try? fd.removeItem(at: recording.rawURL)
        let reset = {
            stream = nil
            streamConfiguration = nil
            startTime = nil
            window = nil
            screen = nil
            closeAreaOverlay()
            controlPanel.close()
            endFailedStart()
        }
        if Thread.isMainThread { reset() } else { DispatchQueue.main.async(execute: reset) }
    }
    
    /// Main thread. The dashed frame around the recorded area, which a selector puts up before it asks for the start.
    static func closeAreaOverlay() {
        for w in NSApp.windows where w.title == "Area Overlayer".local { w.close() }
    }
    
    /// Runs `block` on the main thread as a run loop block. For everything that shows a modal alert: a modal alert
    /// inside a `DispatchQueue.main.async` block holds up every block queued behind it for as long as it is open,
    /// which includes the work that stops and finishes a recording. Any thread.
    static func onMainRunLoop(_ block: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    
    private static let alertLock = NSLock()
    private static var alertsWaiting = 0
    private static var alertHandlers = [() -> Void]()
    
    /// A modal alert on the main thread that does not hold up the caller. Any thread.
    static func showAlertLater(title: String, message: String) {
        alertLock.lock()
        alertsWaiting += 1
        alertLock.unlock()
        onMainRunLoop {
            NSApp.activate(ignoringOtherApps: true)
            _ = createAlert(level: .critical, title: title, message: message, button1: "OK").runModal()
            alertLock.lock()
            alertsWaiting -= 1
            let handlers = alertsWaiting == 0 ? alertHandlers : []
            if alertsWaiting == 0 { alertHandlers = [] }
            alertLock.unlock()
            handlers.forEach { $0() }
        }
    }
    
    /// Main thread. Runs `handler` once every alert asked for with `showAlertLater` has been shown and dismissed;
    /// at once when none is waiting. Quitting waits for it, so that the report of a failure is seen.
    static func whenAlertsDismissed(_ handler: @escaping () -> Void) {
        alertLock.lock()
        let waiting = alertsWaiting > 0
        if waiting { alertHandlers.append(handler) }
        alertLock.unlock()
        if !waiting { handler() }
    }
    
    /// For a failure that must not be missed: a notification, and an alert because notifications may be off or silenced
    static func reportFailure(title: String, message: String) {
        showNotification(title: title, body: message, id: "quickrecorder.error.\(UUID().uuidString)")
        showAlertLater(title: title, message: message)
    }
    
    /// Main thread. Whether a recording can be started now. While the previous one is still being saved the user is told so.
    static func canStart() -> Bool {
        switch state {
        case .idle:
            return true
        case .starting, .recording:
            return false
        case .stopping, .finalizing:
            showAlertLater(title: "Failed to Record".local, message: "The previous recording is still being saved. Start the new one when \"Saving…\" has gone from the menu bar.".local)
            return false
        }
    }
    
    /// Main thread. idle → starting: the only way into a recording, called by `prepRecord` before anything else.
    /// `autoStop` (minutes, 0 for none) belongs to the recording being started, so it is only taken when the start is accepted.
    static func beginStart(autoStop: Int = 0) -> Bool {
        guard canStart() else {
            // A selector's dashed frame must not stay behind. While a recording is starting or running the frame
            // on screen may be that recording's, so it is left alone.
            if state != .starting && state != .recording { closeAreaOverlay() }
            return false
        }
        pendingStop = nil
        SCContext.autoStop = max(0, autoStop)
        state = .starting
        return true
    }
    
    /// Main thread. starting → idle, for a start that did not lead to a recording.
    static func endFailedStart() {
        guard state == .starting else { return }
        pendingStop = nil
        streamType = nil
        autoStop = 0
        state = .idle
    }
    
    /// Main thread. starting → recording, once the capture runs. A stop that was asked for in the meantime is carried out now.
    static func enterRecording() {
        guard state == .starting else { return }
        enteredRecording = Date.now
        state = .recording
        if let stop = pendingStop {
            pendingStop = nil
            stopRecording(only: stop.id, earlyReason: stop.reason)
        }
    }
    
    /// Main thread. Runs `handler` once nothing is being recorded or saved any more; at once when that is so now.
    static func whenIdle(_ handler: @escaping () -> Void) {
        if state == .idle { handler() } else { idleHandlers.append(handler) }
    }
    
    /// The one way a recording ends: the Stop buttons, the hotkey, the script command, the auto-stop timer, an
    /// error (`abortRecording`, the disk guard, a stream that stopped) and quitting all come here. Main thread.
    /// Returns at once; the recording is closed and post-processed in the background while the status bar says so,
    /// and the state is back at idle when its files are final. Only a recording in the `recording` state is stopped:
    /// a stop while the capture is still starting is carried out as soon as it runs, and any other call is ignored,
    /// so repeated stops are harmless. With `id`, only when that recording is still the current one.
    /// `earlyReason` says why the recording ends without the user having stopped it; the user is told so.
    static func stopRecording(only id: UUID? = nil, earlyReason: String? = nil) {
        switch state {
        case .idle:
            return
        case .starting:
            if pendingStop == nil { pendingStop = (id, earlyReason) }
            return
        case .stopping, .finalizing:
            return
        case .recording:
            break
        }
        let current = sampleQueue.sync { SCContext.recording }
        if let id = id, current?.id != id { return }
        guard let recording = current else {
            // Cannot happen: a recording in this state has its context. Without one there is nothing to close.
            streamType = nil
            state = .idle
            return
        }
        // Stopped by the user within moments of the start: when nothing was recorded by then, that is a cancelled start
        let cancelled = earlyReason == nil && Date.now.timeIntervalSince(enteredRecording ?? .distantPast) < 3
        state = .stopping
        DiskSpace.stopMonitoring()
        autoStop = 0
        isMagnifierEnabled = false
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        AppDelegate.shared.stopGlobalMouseMonitor()
        AppDelegate.shared.stopRecordingMouseMonitor()
        closeAreaOverlay()
        // The floating controller stays for the "Saving…" pill; it is closed when the state is idle again
        hideMousePointer = false
        PopoverState.shared.isPaused = false
        window = nil
        screen = nil
        startTime = nil
        // Nil when the stream stopped by itself
        let stream = SCContext.stream
        SCContext.stream = nil
        streamConfiguration = nil
        // The status bar shows "Saving…" from here until the state is idle again
        streamType = nil
        
        Task { @MainActor in
            // Buffers that arrive while the capture is being stopped are still recorded
            if let stream = stream { await stopCapture(stream) }
            await finish(recording, earlyReason: earlyReason, cancelled: cancelled)
        }
    }
    
    /// Suspends until `body` calls the closure it is given, on any thread. Calls after the first do nothing.
    /// `body` itself runs on the main thread, like the caller: what it starts may build windows (the preview, the
    /// audio player of the mix). Work that takes time has to leave the main thread inside `body`.
    @MainActor
    private static func completion(of body: @escaping (@escaping () -> Void) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var done = false
            body {
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                if first { continuation.resume() }
            }
        }
    }
    
    /// Returns when the stream has stopped delivering buffers. A stream that does not answer is given 5 seconds;
    /// what it delivers after that is ignored, because the recording is no longer capturing by then.
    @MainActor
    private static func stopCapture(_ stream: SCStream) async {
        await completion { done in
            stream.stopCapture { error in
                if let error = error { print("Stopping the capture: \(error.localizedDescription)") }
                done()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { done() }
        }
    }
    
    private struct TakenWriter {
        let writer: AVAssetWriter?
        let frame: NSImage?
        let sessionStarted: Bool
    }
    
    /// On `sampleQueue`, after the capture has stopped. Ends the recording on the queue the buffers are appended on:
    /// the inputs are marked as finished here, so no append can run alongside or after that, and the writer and
    /// the timing state leave the statics with the recording.
    private static func takeWriter() -> TakenWriter {
        isCapturing = false
        RecordingMonitor.stop()
        let hadMic = recordsMic
        let sessionStarted = sessionStart != nil
        // `prepRecord` clears the writer and its inputs as well, so a recording that never got as far as creating
        // a writer has none here, not the one of an earlier recording
        let writer = vW
        let videoInput = vwInput
        let audioInput = awInput
        let microphoneInput = micInput
        SCContext.recording = nil
        vW = nil
        vwInput = nil
        awInput = nil
        micInput = nil
        if hadMic, let input = microphoneInput {
            // Bring the microphone track to the length of the recording, whatever the microphone delivered
            if sessionStarted, let end = lastPTS, writer?.status == .writing {
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
        if let converter = micConverter { RecLog.write(converter.summary) }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        audioFile = nil // close audio file
        let frame = firstFrame
        firstFrame = nil
        lastVideoFrame = nil
        videoPTS = nil
        lastPTS = nil
        sessionStart = nil
        clockAnchor = nil
        micConverter = nil
        recordsMic = false
        isPaused = false
        isResume = false
        return TakenWriter(writer: writer, frame: frame, sessionStarted: sessionStarted)
    }
    
    /// What follows the end of the capture: the inputs are finished on the sample queue, then the file is closed,
    /// then it is post-processed (audio mix, MP3 conversion), and only then is the state idle again. Nothing here
    /// blocks the main thread. It works from `recording` and what `takeWriter` handed over, not from statics or settings.
    @MainActor
    private static func finish(_ recording: RecordingContext, earlyReason: String?, cancelled: Bool) async {
        let taken = await withCheckedContinuation { (continuation: CheckedContinuation<TakenWriter, Never>) in
            sampleQueue.async { continuation.resume(returning: takeWriter()) }
        }
        state = .finalizing
        // Held until the files are final, whether or not the recording itself kept the display awake
        SleepPreventer.shared.preventSleep(reason: "Finishing a recording", display: false)
        let frame = taken.frame
        var writer = taken.writer
        if !taken.sessionStarted {
            // Nothing arrived, so there is nothing to close: the empty file is removed and the report below says so
            writer?.cancelWriting()
            writer = nil
        }
        // A writer that already failed has nothing to finish
        var closed = false
        if let writer = writer, writer.status == .writing {
            await writer.finishWriting()
            closed = writer.status == .completed
        }
        let failureTitle = earlyReason == nil ? "Failed to save file".local : "Recording Stopped Early".local
        let savedSoFar = String(format: "The recording up to that point is saved as: %@".local, recording.finalURL.path)
        if !taken.sessionStarted && cancelled {
            // Stopped before the first frame or the first audio arrived. Nothing was lost, so nothing is reported as failed.
            try? fd.removeItem(at: recording.rawURL)
            showNotification(title: "Recording Cancelled".local, body: "The recording was stopped before anything was recorded.".local, id: "quickrecorder.cancelled.\(UUID().uuidString)")
        } else if !recording.audioOnly {
            if !closed {
                print("Video writing failed with status: \(String(describing: writer?.status)), error: \(String(describing: writer?.error))")
                var body = earlyReason ?? ""
                if let error = writer?.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
                if body.isEmpty { body = writer == nil ? "The recording did not start, nothing was written.".local : "Unknown error".local }
                if fd.fileExists(atPath: recording.rawURL.path) {
                    // The file is written in fragments, so it plays up to the last few seconds without having been closed.
                    // It leaves its temporary name; no mix is attempted on it.
                    let kept = recording.unmixedURL.map { keepUnmixedRecording(written: recording.rawURL, as: $0) } ?? recording.rawURL
                    body += " " + String(format: "The file could not be closed. What was written before that was kept as: %@".local, kept.path)
                } else if writer != nil {
                    body += " " + movedNote(for: recording.rawURL)
                }
                reportFailure(title: failureTitle, message: body)
            } else {
                if recording.mixesAudio {
                    // Where the recording ends up is only known after the mix
                    await mixRecording(recording, frame: frame, earlyReason: earlyReason)
                } else {
                    if let reason = earlyReason { reportFailure(title: failureTitle, message: reason + " " + savedSoFar) }
                    let url = recording.finalURL
                    if !recording.showPreview {
                        showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "quickrecorder.completed.\(UUID().uuidString)")
                    } else {
                        showPreview(path: url.path, image: frame)
                    }
                    if recording.trimAfterRecord {
                        AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
                    }
                }
            }
        } else if !taken.sessionStarted {
            // No audio arrived, so the files are empty
            try? fd.removeItem(at: recording.rawURL)
            let body = (earlyReason.map { $0 + " " } ?? "") + "No audio arrived, nothing was recorded.".local
            reportFailure(title: failureTitle, message: body)
        } else if recording.recordMic, let writer = writer, !closed {
            // The microphone file did not close: the package is kept as it is and is not mixed
            var body = earlyReason ?? ""
            if let error = writer.error?.localizedDescription, !body.contains(error) { body += (body.isEmpty ? "" : " ") + error }
            body += (body.isEmpty ? "" : " ") + String(format: "The microphone file could not be closed. The recording was kept with separate audio files: %@".local, recording.rawURL.path)
            reportFailure(title: failureTitle, message: body)
        } else {
            // The package is only read now that the microphone file is complete
            if let reason = earlyReason { reportFailure(title: failureTitle, message: reason + " " + savedSoFar) }
            await completion { done in finishAudioRecording(recording, completion: done) }
        }
        SleepPreventer.shared.allowSleep()
        // A frame that arrived while the capture was being stopped may have set it again
        startTime = nil
        state = .idle
    }
    
    /// Mixes the audio tracks of a finished video recording and presents the result. Returns when the recording has
    /// its final name. The recording as it was written is only removed or renamed after the mix has been written
    /// completely, checked against it and moved to the final name; whatever goes wrong before that, it is kept
    /// under its "(unmixed, 2 audio tracks)" name and the user is told. The work itself runs off the main thread.
    @MainActor
    private static func mixRecording(_ recording: RecordingContext, frame: NSImage?, earlyReason: String?) async {
        guard let mixURL = recording.mixURL, let unmixedURL = recording.unmixedURL else { return }
        let raw = recording.rawURL
        let final = recording.finalURL
        let early = earlyReason.map { $0 + " " } ?? ""
        var failure: String?
        // The mix writes a second file of about the same size next to the recording. On a nearly full disk the
        // recording is kept as it is rather than put at risk.
        if !DiskSpace.hasRoomForCopy(of: raw) {
            failure = "Not enough free disk space to mix the audio tracks.".local
        } else {
            RecordingHealth.shared.mixProgress = 0
            let settings = updateAudioSettings(format: recording.audioFormat.rawValue, quality: recording.audioQuality, videoFormat: recording.videoFormat.rawValue)
            do {
                try await RecordingMixer.mix(source: raw, output: mixURL, fileType: recording.fileType, audioSettings: settings) { fraction in
                    DispatchQueue.main.async {
                        if state == .finalizing { RecordingHealth.shared.mixProgress = fraction }
                    }
                }
                try await RecordingMixer.verify(source: raw, output: mixURL)
                // A rename within the folder: the final name appears with the complete file or not at all
                try fd.moveItem(at: mixURL, to: final)
            } catch {
                print("Failed to mix the audio tracks: \(error)")
                failure = error.localizedDescription
            }
        }
        if let failure = failure {
            // What the mix wrote is incomplete or not to be trusted, and the recording has everything
            try? fd.removeItem(at: mixURL)
            let kept = keepUnmixedRecording(written: raw, as: unmixedURL)
            guard fd.fileExists(atPath: kept.path) else {
                // Not a place to claim the recording is: the writer kept writing through its open file, wherever that went
                reportFailure(title: "Audio Mix Failed".local, message: early + String(format: "Mixing the audio failed: %@".local, failure) + " " + movedNote(for: raw))
                return
            }
            let body = early + String(format: "Mixing the audio failed: %@ Nothing is lost: the recording is kept with system audio and microphone as two separate audio tracks in: %@".local, failure, kept.path)
            reportFailure(title: "Audio Mix Failed".local, message: body)
            if recording.showPreview { showPreview(path: kept.path, image: frame) }
            return
        }
        print("Mixed recording saved to \(final.path)")
        var leftover: URL?
        if recording.keepUnmixed {
            let kept = keepUnmixedRecording(written: raw, as: unmixedURL)
            if kept != unmixedURL { leftover = kept }
        } else {
            do {
                try fd.removeItem(at: raw)
            } catch {
                print("Failed to remove the unmixed recording: \(error.localizedDescription)")
                leftover = keepUnmixedRecording(written: raw, as: unmixedURL)
            }
        }
        if let leftover = leftover {
            let body = String(format: "The recording was mixed and saved, but its unmixed copy is still at: %@".local, leftover.path)
            showNotification(title: "Recording Completed".local, body: body, id: "quickrecorder.completed.\(UUID().uuidString)")
        }
        if let reason = earlyReason {
            reportFailure(title: "Recording Stopped Early".local, message: reason + " " + String(format: "The recording up to that point is saved as: %@".local, final.path))
        }
        if !recording.showPreview {
            showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, final.path), id: "quickrecorder.completed.\(UUID().uuidString)")
        }
        if recording.trimAfterRecord {
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: final), title: final.lastPathComponent, only: false)
        } else if recording.showPreview {
            showPreview(path: final.path, image: frame)
        }
    }
    
    /// What follows an audio-only recording once its files are closed: MP3 conversion, the mix of a .qma package, or just the report.
    /// `completion` is called once, when the files are in their final state. Main thread: it shows the preview
    /// and creates the audio player that does the mix.
    @MainActor
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
    
    /// What to tell the user when a recording is not where it was written to: the save folder was renamed or moved
    /// (or its volume went away) while recording. The file still has the name it was written under.
    private static func movedNote(for written: URL) -> String {
        return String(format: "The recording is no longer at %@: the folder was moved or renamed, or its disk was removed, while recording. Look for the file \"%@\" where the folder is now; it holds everything that was recorded.".local, written.deletingLastPathComponent().path, written.lastPathComponent)
    }
    
    /// Gives a recording that was written under its temporary name the name it is kept under. Nothing is deleted
    /// or replaced: when the name is taken or the rename fails, the recording stays where it is. Returns where it is afterwards.
    static func keepUnmixedRecording(written: URL, as kept: URL) -> URL {
        return RecordingFiles.keep(written: written, as: kept)
    }
    
    /// What the app's recordings are named with, in front of the date. Launch recovery only takes files with it for its own.
    static let recordingNamePrefix = "Recording at "
    /// Whether leftovers of an earlier run are still being dealt with. Main thread only.
    private(set) static var isRecovering = false
    /// Main thread. Set when the app was asked to quit and is waiting for its files to be final.
    static var quitRequested = false
    /// Whether the status item shows the "Recovering…" pill: always while quitting waits for the recovery, so the
    /// app does not look hung, and otherwise only where it does not take the place of the menu bar icon, from which
    /// a recording can be started meanwhile.
    static var showsRecovery: Bool { isRecovering && (quitRequested || !ud.bool(forKey: "showMenubar")) }
    private static var recoveredHandlers = [() -> Void]()
    
    /// Main thread. Runs `handler` once launch recovery is over; at once when it is not running.
    static func whenRecovered(_ handler: @escaping () -> Void) {
        if isRecovering { recoveredHandlers.append(handler) } else { handler() }
    }
    
    /// Main thread, once at launch. A recording that was being written or mixed when the app crashed or was killed
    /// is still in the save folder under its temporary name. Each such file gets a name that says what it is, and a
    /// recording that opens gets the audio mix it did not get (`recoverRecording`). The user is told in one report.
    /// Nothing is deleted. With another instance of the app running, the files may be its recording, so nothing is touched.
    /// This is not part of the recording state: a recording can be started while it runs, since it only works on
    /// files of an earlier run. Quitting waits for it.
    static func recoverLeftovers() {
        let instances = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        guard !isRecovering, instances.count <= 1, let directory = ud.string(forKey: "saveDirectory") else { return }
        let found = RecordingMixer.leftovers(in: directory, prefix: recordingNamePrefix.local)
        guard !found.isEmpty else { return }
        // The settings such a recording was started with are not known any more, so the mix uses the current ones
        let settings = Dictionary(found.map { ($0.ending, updateAudioSettings(videoFormat: $0.ending.lowercased())) }, uniquingKeysWith: { first, _ in first })
        isRecovering = true
        updateStatusBar()
        // A token of its own: the sleep assertion of SleepPreventer belongs to the recording that may run meanwhile
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Finishing a recording from an earlier run")
        Task.detached {
            var lines = [String]()
            // What an interrupted mix wrote goes out of the way first. It says nothing about the recording it was
            // made from: the mix of a recording that was never closed is written under the same marker.
            for leftover in found where leftover.isMix {
                let target = RecordingMixer.freeURL(base: leftover.base, label: RecoveryNames.incompleteMix, ending: leftover.ending)
                let now = keepUnmixedRecording(written: leftover.url, as: target)
                print("Leftover \(leftover.url.lastPathComponent) -> \(now.lastPathComponent)")
                var line = String(format: "\"%@\" is what an interrupted audio mix had written. The recording it was made from is kept separately; this file can be deleted.".local, now.lastPathComponent)
                if now != target { line += " " + "It could not be renamed.".local }
                lines.append(line)
            }
            for leftover in found where !leftover.isMix {
                lines.append(await recoverRecording(leftover, audioSettings: settings[leftover.ending] ?? [:]))
            }
            let message = String(format: "Found in %@ from an earlier run of QuickRecorder that did not end normally:".local, directory) + "\n\n" + lines.joined(separator: "\n\n")
            await MainActor.run {
                ProcessInfo.processInfo.endActivity(activity)
                isRecovering = false
                RecordingHealth.shared.recoveryProgress = nil
                updateStatusBar()
                let handlers = recoveredHandlers
                recoveredHandlers = []
                reportFailure(title: "Recording Recovered".local, message: message)
                handlers.forEach { $0() }
            }
        }
    }
    
    /// Deals with one recording left under its temporary name and returns what to tell the user about it.
    /// A file that does not open becomes `X (damaged)`. One that opens is mixed under the rules of `mixRecording`:
    /// the mix is written to `X.mixing`, checked, and only then renamed, and the recording itself is only ever renamed.
    /// - Closed before the app went away (it is not in fragments any more): it is complete. Mix `X`, recording
    ///   `X (unmixed, 2 audio tracks)`. Only the file itself says so; a `.mixing` file next to it does not, because
    ///   the recovery mix of an unclosed recording leaves one too when it is interrupted.
    /// - Never closed: it plays up to its last seconds. Mix `X (recovered)`, recording `X (recovered, unmixed, 2 audio tracks)`.
    /// - The mix fails: recording `X (unmixed, 2 audio tracks)` when complete, `X (recovered)` when not.
    private static func recoverRecording(_ leftover: RecordingMixer.Leftover, audioSettings: [String: Any]) async -> String {
        let raw = leftover.url
        let base = leftover.base
        let ending = leftover.ending
        let info = await RecordingMixer.inspect(raw)
        /// Renames the recording and says so when that fails
        func rename(_ label: String, _ line: String) -> String {
            let target = RecordingMixer.freeURL(base: base, label: label, ending: ending)
            let now = keepUnmixedRecording(written: raw, as: target)
            print("Leftover \(raw.lastPathComponent) -> \(now.lastPathComponent)")
            let text = String(format: line, now.lastPathComponent)
            return now == target ? text : text + " " + "It could not be renamed.".local
        }
        guard let seconds = info.seconds else {
            return rename(RecoveryNames.damaged, "\"%@\" is a recording that was not finished and cannot be opened.".local)
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        let length = formatter.string(from: seconds) ?? ""
        let complete = !info.fragmented
        let what = complete
            ? String(format: "is a complete recording (%@) whose audio had not been mixed yet when the app went away.".local, length)
            : String(format: "is a recording that was not finished (%@); its last seconds may be missing.".local, length)
        let separate = "It plays, with system audio and microphone as two separate audio tracks (many players only play the first, which is system audio).".local
        let mixURL = RecordingMixer.temporaryURL(base: base, marker: RecordingMixer.mixMarker, ending: ending)
        let final = RecordingMixer.freeURL(base: base, label: RecoveryNames.mix(complete: complete), ending: ending)
        var failure: String?
        if !info.mixable {
            failure = "It does not have one video and two audio tracks.".local
        } else if fd.fileExists(atPath: mixURL.path) {
            // What the interrupted mix wrote could not be moved away; it is not overwritten
            failure = "The file of the interrupted mix is in the way.".local
        } else if !DiskSpace.hasRoomForCopy(of: raw) {
            failure = "Not enough free disk space to mix the audio tracks.".local
        } else {
            do {
                try await RecordingMixer.mix(source: raw, output: mixURL, fileType: ending.lowercased() == "mov" ? .mov : .mp4, audioSettings: audioSettings) { fraction in
                    DispatchQueue.main.async {
                        if isRecovering { RecordingHealth.shared.recoveryProgress = fraction }
                    }
                }
                try await RecordingMixer.verify(source: raw, output: mixURL)
                try fd.moveItem(at: mixURL, to: final)
            } catch {
                print("Failed to mix the leftover \(raw.lastPathComponent): \(error)")
                failure = error.localizedDescription
                // Only what this mix wrote: there was no such file before it
                try? fd.removeItem(at: mixURL)
            }
        }
        if let failure = failure {
            let line = "\"%@\" " + what + " " + String(format: "Mixing its audio now failed: %@".local, failure).replacingOccurrences(of: "%", with: "%%") + " " + separate
            return rename(RecoveryNames.recording(complete: complete, mixed: false), line)
        }
        let mixed = String(format: "\"%@\" ".local, final.lastPathComponent) + what + " " + "Its audio was mixed now.".local
        let kept = "The recording as it was written, with system audio and microphone as separate audio tracks, is kept as \"%@\".".local
        return rename(RecoveryNames.recording(complete: complete, mixed: true), mixed.replacingOccurrences(of: "%", with: "%%") + " " + kept)
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
    
    /// On `sampleQueue`. Replaces `lastVideoFrame` by a copy with pixels of its own, so it no longer holds a surface of
    /// the stream. When the copy cannot be made the frame stays as it is and the next call tries again.
    static func detachLastVideoFrame() {
        guard !lastVideoFrameIsCopy, let frame = lastVideoFrame else { return }
        guard let copy = detachedCopy(of: frame) else {
            print("The last video frame could not be copied")
            return
        }
        lastVideoFrame = copy
        lastVideoFrameIsCopy = true
    }
    
    /// A picture of a video frame, at most `side` pixels wide and high, that does not depend on the frame's pixels afterwards
    static func thumbnail(of frame: CMSampleBuffer, side: CGFloat = 1280) -> NSImage? {
        guard let pixels = frame.imageBuffer else { return nil }
        var image = CIImage(cvPixelBuffer: pixels)
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return nil }
        if longest > side { image = image.transformed(by: CGAffineTransform(scaleX: side / longest, y: side / longest)) }
        let bounds = image.extent.integral.intersection(image.extent)
        guard !bounds.isEmpty, let rendered = CIContext().createCGImage(image, from: bounds) else { return nil }
        return NSImage(cgImage: rendered, size: .zero)
    }
    
    /// Shows the floating preview for a finished recording. `image` is that recording's first frame or an icon.
    static func showPreview(path: String, image: NSImage?) {
        if let previewImage = image, let screen = getScreenWithMouse() {
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
}
