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

class SCContext {
    static var trimingList = [URL]()
    static var autoStop = 0
    static var isMagnifierEnabled = false
    static var saveFrame = false
    /// The one queue all stream outputs are delivered on. The recording's `MovieWriter` and `RecordingMonitor` are
    /// only used on it while capturing.
    static let sampleQueue = DispatchQueue(label: "QuickRecorder.samples")
    /// The area the area selector chose, which the next area recording captures
    static var screenArea: NSRect?
    /// The writer of the recording in progress, from the start until `stopRecording()` takes it. Only assigned and
    /// used inside `sampleQueue`; nil between recordings.
    static var writer: MovieWriter?
    /// The recording in progress. On `sampleQueue`.
    static var recording: RecordingContext? { writer?.recording }
    /// The capture of the recording in progress, from the moment its stream exists until it is stopped. Assigned once
    /// by the task of `record()` (not on the main thread) while the state is `.starting`; read and cleared on the main thread.
    static var capture: CaptureSource?
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
    static var startTime: Date?
    static var timePassed: TimeInterval = 0
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
            && title != WindowTitle.mousePointer
            && title != WindowTitle.screenMagnifier
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).compactMap({ $0.owningApplication }) {
            if !apps.contains(app) { apps.append(app) }
        }
        if hideSelf && AppSettings.hideSelf { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
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
        if hideSelf && AppSettings.hideSelf { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
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
    
    static func performMicCheck() async {
        guard AppSettings.recordMic else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        AppSettings.recordMic = false
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
    
    /// The area last recorded on the screen with that name, as the area selector stored it
    static func savedArea(forScreen name: String) -> NSRect? {
        guard let area = AppSettings.savedAreas[name] as? [String: Any] else { return nil }
        func value(_ key: String) -> CGFloat? { (area[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = value("x"), let y = value("y"), let width = value("width"), let height = value("height"),
              width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    /// Remembers `area` for the screen with that name. The areas of the other screens stay as they are.
    static func saveArea(_ area: NSRect, forScreen name: String) {
        var saved = AppSettings.savedAreas
        saved[name] = ["x": Double(area.origin.x), "y": Double(area.origin.y), "width": Double(area.width), "height": Double(area.height)]
        AppSettings.savedAreas = saved
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
        if !PopoverState.shared.isPaused { timePassed = Date.now.timeIntervalSince(startTime ?? Date.now) }
        return lengthText(timePassed)
    }
    
    /// "07:05" up to an hour, "1:07:05" from then on. The status bar makes room for the longer form (`getStatusBarWidth`).
    static func lengthText(_ interval: TimeInterval) -> String {
        return Timeline.lengthText(interval)
    }
    
    /// Main thread. Pauses the recording in progress, or resumes it.
    static func pauseRecording() {
        let paused: Bool? = sampleQueue.sync {
            guard let writer = writer else { return nil }
            RecordingMonitor.resumeWaited = false
            return writer.togglePause()
        }
        guard let paused = paused else { return }
        PopoverState.shared.isPaused = paused
        if !paused {
            startTime = Date.now.addingTimeInterval(-1) - SCContext.timePassed
        }
    }
    
    /// Undoes a start that failed before anything was recorded: the writer, the files it created, the stream and
    /// the recording state, which goes back to idle. Any thread. A recording that is starting cannot be stopped
    /// (a stop is put off until the capture runs), so `recording` is the current one.
    static func discardStart(_ recording: RecordingContext) {
        var discarded: MovieWriter?
        sampleQueue.sync {
            guard writer?.recording.id == recording.id else { return }
            discarded = writer
            writer = nil
            RecordingMonitor.stop()
        }
        // Also deletes the file the writer created
        discarded?.cancel()
        // Nothing was recorded, so what is left is an empty file or a package without audio
        try? fd.removeItem(at: recording.rawURL)
        let reset = {
            capture?.releaseStream()
            capture = nil
            startTime = nil
            closeAreaOverlay()
            controlPanel.close()
            endFailedStart()
        }
        if Thread.isMainThread { reset() } else { DispatchQueue.main.async(execute: reset) }
    }
    
    /// Main thread. The dashed frame around the recorded area, which a selector puts up before it asks for the start.
    static func closeAreaOverlay() {
        for w in NSApp.windows(.areaOverlay) { w.close() }
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
        // The pause flag of the UI starts every recording in step with its new `MovieWriter`, also after a
        // start that was paused and then discarded.
        PopoverState.shared.isPaused = false
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
    /// error (`MovieWriter.fail`, the disk guard, a stream that stopped) and quitting all come here. Main thread.
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
        RecordingFileStore.stopWatchingFreeSpace()
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
        startTime = nil
        // Nil when the stream stopped by itself
        let capture = SCContext.capture
        SCContext.capture = nil
        // The status bar shows "Saving…" from here until the state is idle again
        streamType = nil
        
        Task { @MainActor in
            // Buffers that arrive while the capture is being stopped are still recorded
            if let capture = capture { await stopCapture(capture) }
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
    private static func stopCapture(_ capture: CaptureSource) async {
        await completion { done in
            capture.stop { error in
                if let error = error { print("Stopping the capture: \(error.localizedDescription)") }
                done()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { done() }
        }
    }
    
    /// On `sampleQueue`, after the capture has stopped. The recording leaves `writer` here, and its inputs are
    /// marked as finished on the queue the buffers are appended on, so no append can run alongside or after that.
    private static func takeWriter() -> MovieWriter.Finished {
        RecordingMonitor.stop()
        let taken = writer
        writer = nil
        // Cannot be missing: a recording that is being stopped has its writer, which may have no file
        return taken?.finish() ?? MovieWriter.Finished(writer: nil, frame: nil, sessionStarted: false)
    }
    
    /// What follows the end of the capture: the inputs are finished on the sample queue, then the file is closed,
    /// then it is post-processed (audio mix, MP3 conversion), and only then is the state idle again. Nothing here
    /// blocks the main thread. It works from `recording` and what `takeWriter` handed over, not from statics or settings.
    @MainActor
    private static func finish(_ recording: RecordingContext, earlyReason: String?, cancelled: Bool) async {
        let taken = await withCheckedContinuation { (continuation: CheckedContinuation<MovieWriter.Finished, Never>) in
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
                    let kept = recording.unmixedURL.map { RecordingFileStore.keep(written: recording.rawURL, as: $0) } ?? recording.rawURL
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
        if !RecordingFileStore.hasRoomForCopy(of: raw) {
            failure = "Not enough free disk space to mix the audio tracks.".local
        } else {
            RecordingHealth.shared.mixProgress = 0
            let settings = recording.audioSettings
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
            let kept = RecordingFileStore.keep(written: raw, as: unmixedURL)
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
            let kept = RecordingFileStore.keep(written: raw, as: unmixedURL)
            if kept != unmixedURL { leftover = kept }
        } else {
            do {
                try fd.removeItem(at: raw)
            } catch {
                print("Failed to remove the unmixed recording: \(error.localizedDescription)")
                leftover = RecordingFileStore.keep(written: raw, as: unmixedURL)
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
    
    /// Shows the floating preview for a finished recording. `image` is that recording's first frame or an icon.
    static func showPreview(path: String, image: NSImage?) {
        if let previewImage = image, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(self)
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL, bitrate: Int = AppSettings.audioQuality.rawValue) async throws {
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
        if let id = AppSettings.storedMicDeviceID {
            if id != "default", !mics.contains(where: { $0.uniqueID == id }), let device = mics.first(where: { $0.localizedName == id }) {
                AppSettings.micDeviceID = device.uniqueID
                return device.uniqueID
            }
            return id
        }
        let name = AppSettings.micName
        let id = name == "default" ? name : (mics.first(where: { $0.localizedName == name })?.uniqueID ?? name)
        AppSettings.micDeviceID = id
        return id
    }
    
    /// Name of the chosen microphone for display, kept under "micDevice" so that it is known while the device is absent
    static func selectedMicName() -> String {
        let id = selectedMicID()
        if let device = getMicrophone().first(where: { $0.uniqueID == id }) { return device.localizedName }
        let name = AppSettings.micName
        return name == "default" ? id : name
    }
    
    /// Selects a microphone by name, or the system default for "default". Returns false when there is no such device.
    static func selectMic(named name: String) -> Bool {
        if name == "default" {
            AppSettings.micDeviceID = "default"
        } else if let device = getMicrophone().first(where: { $0.localizedName == name }) {
            AppSettings.micDeviceID = device.uniqueID
        } else {
            return false
        }
        AppSettings.micName = name
        return true
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
