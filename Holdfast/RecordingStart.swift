//
//  RecordingStart.swift
//  Holdfast
//
//  Created by apple on 2024/4/17.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import VideoToolbox

// Starting a recording in the app: what is checked and decided on the main thread (`start`), then the capture
// source and the writer are created and started (`record`), and what the recorder needs from the app around it
// (`RecorderEnvironment.app`).

/// The recorder, for code that AppKit runs on the main thread without saying so in its types: delegate methods,
/// event monitors, hotkey handlers, script commands. Traps on any other thread.
func withRecorder<T>(_ body: @MainActor (RecorderController) -> T) -> T {
    return MainActor.assumeIsolated { body(RecorderController.shared) }
}

extension RecorderController {
    static let shared = RecorderController(queue: DispatchQueue(label: "Holdfast.samples"), environment: .app)

    /// The one way a recording starts: the selectors, the hotkeys, the script commands and the countdown all end
    /// here. It does nothing unless the recorder is idle (`begin`), so a second start while one is starting,
    /// recording or still being saved cannot get in.
    /// `recordMic` overrides the "recordMic" setting for this recording only. `autoStop` is the number of minutes
    /// after which this recording stops by itself (0: never); it is not set anywhere else.
    func start(type streamType: StreamType, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false, recordMic micOverride: Bool? = nil, autoStop: Int = 0) {
        guard let session = begin(streamType, autoStop: autoStop) else { return }
        // Every reason not to start ends here, with one alert
        func failToRecord(_ message: String) {
            session.abandonStart()
            UserNotice.showAlertLater(title: "Failed to Record".local, message: message)
        }

        let store = RecordingFileStore(directory: AppSettings.saveDirectory)
        do {
            try store.prepareForRecording()
        } catch {
            return failToRecord(error.localizedDescription)
        }

        guard let content = ScreenContent.availableContent else {
            return failToRecord("The list of screens and windows is not available. Check the screen recording permission.".local)
        }
        guard let screens = screens else { return failToRecord("No display to record was found.".local) }
        let listedDisplay = content.displays.first(where: { $0 == screens })

        var listedWindows: [SCWindow]?
        if let windows = windows {
            listedWindows = content.windows.filter({ windows.contains($0) })
        } else if streamType == .window {
            return failToRecord("No window to record was given.".local)
        }

        var listedApplications: [SCRunningApplication]?
        if let applications = applications {
            listedApplications = content.applications.filter({ applications.contains($0) })
        } else if streamType == .application {
            return failToRecord("No application to record was given.".local)
        }

        guard let screen = listedDisplay ?? ScreenContent.getSCDisplayWithMouse() else {
            return failToRecord("No display to record was found.".local)
        }
        var target = CaptureTarget(type: streamType, display: screen, areaDisplay: listedDisplay, windows: listedWindows,
                                   applications: listedApplications, area: ScreenContent.screenArea)
        if target.type == .screenarea, let area = target.area, let name = screen.nsScreen?.localizedName {
            ScreenContent.saveArea(area, forScreen: name)
        }
        let filter: SCContentFilter
        do {
            filter = try CaptureSource.filter(for: &target, content: content)
        } catch {
            return failToRecord(error.localizedDescription)
        }
        // Several windows of which one is left are recorded as a window
        session.streamType = target.type

        let (microphone, problem) = RecorderController.prepareMicCapture(wanted: micOverride ?? AppSettings.recordMic)
        if let problem = problem {
            // A recording that was asked to have the microphone never starts without it unnoticed: a microphone
            // that turns up later cannot be added to it. Cancel is the default button.
            NSApp.activate(ignoringOtherApps: true)
            let message = problem + " " + "A recording started now has no microphone track, and one cannot be added while it runs. Cancel, connect the microphone and start again, or record without it.".local
            let answer = createAlert(level: .critical, title: "Microphone Not Available".local, message: message, button1: "Cancel", button2: "Record Without Microphone").runModal()
            if answer != .alertSecondButtonReturn {
                session.abandonStart()
                return
            }
        }
        // The output files and the settings this recording keeps until it is finished, whatever changes meanwhile
        let recording = RecordingContext(audioOnly: target.type == .systemaudio, recordMic: microphone != nil, fastStart: fastStart, saveDirectory: store.directory)
        let writer = MovieWriter(recording: recording, micConverter: microphone?.converter)
        session.install(writer)
        if recording.audioOnly {
            do {
                try writer.prepareAudio()
            } catch {
                RecorderController.failStart(session, error: error)
                return
            }
        }
        Task { await RecorderController.record(session, filter: filter, target: target, writer: writer, microphone: microphone) }
    }

    /// A recording that was set up but could not be started: everything created for it is removed, the state goes
    /// back to idle and the user gets one alert.
    private static func failStart(_ session: RecordingSession, error: Error) {
        print("Failed to start the recording: \(error)")
        session.abandonStart()
        UserNotice.showAlertLater(title: "Failed to Record".local, message: error.localizedDescription)
    }

    /// Decides whether this recording gets a microphone track and which device ScreenCaptureKit captures it from.
    /// Without a microphone, `problem` says why not when one is wanted and cannot be recorded.
    static func prepareMicCapture(wanted: Bool) -> (microphone: MicrophoneChoice?, problem: String?) {
        guard wanted else { return (nil, nil) }
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .denied || access == .restricted {
            return (nil, "Holdfast has no permission to use the microphone (System Settings, Privacy & Security, Microphone).".local)
        }
        guard let defaultMic = AVCaptureDevice.default(for: .audio), let converter = MicConverter() else {
            return (nil, "No microphone was found.".local)
        }
        // The selection is kept for the recording: MicDevices follows the default input, or goes back to the chosen
        // device when it returns
        let selected = MicSelection.selectedMicID()
        let defaultID = MicDevices.defaultInputUID() ?? defaultMic.uniqueID
        if selected == "default" {
            return (MicrophoneChoice(converter: converter, selection: selected, captureDeviceID: nil, activeDeviceID: defaultID), nil)
        }
        if MicSelection.getMicrophone().contains(where: { $0.uniqueID == selected }) {
            return (MicrophoneChoice(converter: converter, selection: selected, captureDeviceID: selected, activeDeviceID: selected), nil)
        }
        let body = String(format: "\"%@\" is not connected. Recording with the default microphone \"%@\" instead.".local, MicSelection.selectedMicName(), defaultMic.localizedName)
        UserNotice.showNotification(title: "Microphone Unavailable".local, body: body, id: "holdfast.microphone.\(UUID().uuidString)")
        return (MicrophoneChoice(converter: converter, selection: selected, captureDeviceID: nil, activeDeviceID: defaultID), nil)
    }

    /// Not on the main thread: creating the stream and starting the capture take their time.
    private nonisolated static func record(_ session: RecordingSession, filter: SCContentFilter, target: CaptureTarget, writer: MovieWriter, microphone: MicrophoneChoice?) async {
        let recording = writer.recording
        let audioOnly = recording.audioOnly
        let conf = CaptureSource.configuration(for: recording, target: target, filter: filter, microphoneDeviceID: microphone?.captureDeviceID)

        let encoderIsH265 = (AppSettings.encoder == .h265) || AppSettings.recordHDR
        if !audioOnly && !encoderIsH265 {
            var probe: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(conf.width),
                height: Int32(conf.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &probe
            )

            if status != noErr {
                let button = showAlertSyncOnMainThread(
                    level: .critical,
                    title: "Encoder Warning",
                    message: "VideoToolbox H.264 hardware encoder doesn't support the current resolution.\nContinue with a software encoder will significantly increase the CPU usage.\n\nWould you like to use H.265 instead?".local,
                    button1: "Use H.265",
                    button2: "Continue with H.264"
                )
                if button == .alertFirstButtonReturn { AppSettings.encoder = .h265 }
            }
        }

        // The stream hands its buffers to this session and reports its end to it, so neither can reach another recording
        let capture = CaptureSource(filter: filter, configuration: conf, recording: recording, microphone: microphone, queue: session.queue,
                                    onSample: { session.received($0) },
                                    onStop: { [weak session] capture, error in
            let nsError = error as NSError
            let userStopped = nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userStopped.rawValue
            session?.captureEnded(capture, reason: userStopped ? nil : String(format: "The screen capture stopped: %@".local, error.localizedDescription))
        })
        await session.attach(capture)
        do {
            try capture.addOutputs()
            if !audioOnly { try writer.prepareVideo(width: conf.width, height: conf.height) }
            session.startCapturing()
            try await capture.start()
        } catch {
            await failStart(session, error: error)
            return
        }
        session.startMonitor()
        DispatchQueue.main.async {
            // Nothing can have stopped this recording yet: a stop that was asked for while the capture was starting
            // is carried out by enterRecording, after everything it undoes has been set up
            session.enterRecording {
                if !audioOnly { AppDelegate.shared.startRecordingMouseMonitor() }
                if recording.preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
                if recording.recordMic { MicDevices.watch() }
                let watch = RecordingFileStore(directory: recording.saveDirectory).watchFreeSpace { [weak session] free in
                    let reason = String(format: "The disk is almost full, only %@ is left.".local, DiskSpace.formatted(free))
                    MainActor.assumeIsolated { session?.stop(earlyReason: reason) }
                }
                session.whenStopped { watch.cancel() }
            }
        }
    }
}

extension RecorderEnvironment {
    /// The app around the recorder: the status item, the windows of a recording, alerts and notifications
    static var app: RecorderEnvironment {
        var app = RecorderEnvironment()
        // The status item reads the recorder itself, whatever it was that changed
        app.statusChanged = { _ in StatusItemController.shared.refresh() }
        app.startRefused = { reason in
            switch reason {
            case .saving:
                UserNotice.showAlertLater(title: "Failed to Record", message: "The previous recording is still being saved. Start the new one when \"Saving\" has gone from the menu bar.")
            case .quitting:
                UserNotice.showAlertLater(title: "Failed to Record", message: "Holdfast is quitting: it quits as soon as what it is saving or recovering is done, and a new recording would end with it. Open Holdfast again to record.")
            }
        }
        app.startAbandoned = { closeAreaOverlay() }
        app.tearDown = {
            // Both also take the mouse highlight and the magnifier off the screen
            AppDelegate.shared.stopGlobalMouseMonitor()
            AppDelegate.shared.stopRecordingMouseMonitor()
            closeAreaOverlay()
        }
        app.save = { session, recording, taken, earlyReason, cancelled in
            await RecordingSaver.save(session, recording: recording, taken: taken, earlyReason: earlyReason, cancelled: cancelled)
        }
        app.notify = { title, body in
            UserNotice.showNotification(title: title, body: body, id: "holdfast.watchdog.\(UUID().uuidString)")
        }
        app.savePicture = { frame, directory in savePicture(of: frame, in: directory ?? AppSettings.saveDirectory) }
        app.report = { title, message in UserNotice.reportFailure(title: title, message: message) }
        app.whenAlertsDismissed = { handler in UserNotice.whenAlertsDismissed(handler) }
        return app
    }

    /// Saves one frame as a picture in the folder of the recording (the "saveFrame" hotkey). On the sample queue.
    private static func savePicture(of sampleBuffer: CMSampleBuffer, in directory: String) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let url = "\(RecordingFileStore(directory: directory).newFrameBase()).png".url
        if !AppSettings.recordHDR {
            sampleBuffer.nsImage?.saveToFile(url)
        } else {
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
            // Image exposure needs to be increased by one stop to match the original
            let ciImage = CIImage(cvPixelBuffer: imageBuffer).applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
            do {
                try CIContext().writePNGRepresentation(of: ciImage, to: url, format: .RGB10, colorSpace: colorSpace)
            } catch {
                print("Error: \(error)")
            }
        }
    }
}
