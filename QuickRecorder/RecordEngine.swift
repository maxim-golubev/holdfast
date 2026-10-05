//
//  RecordEngine.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/17.
//

import Foundation
import UserNotifications
import ScreenCaptureKit
import AVFoundation
import AVFAudio
import VideoToolbox

// Starting a recording: what is checked and decided on the main thread (`prepRecord`), then the capture source
// and the writer are created and started (`record`). While it runs, `SCContext.received` hands the buffers of the
// capture to the writer.

extension AppDelegate {
    /// The one way a recording starts: the selectors, the hotkeys, the script commands and the countdown all end
    /// here. Main thread. It does nothing unless the recording side is idle (`SCContext.beginStart`), so a second
    /// start while one is starting, recording or still being saved cannot get in.
    /// `recordMic` overrides the "recordMic" setting for this recording only. `autoStop` is the number of minutes
    /// after which this recording stops by itself (0: never); it is not set anywhere else.
    func prepRecord(type: String, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false, recordMic micOverride: Bool? = nil, autoStop: Int = 0) {
        let streamType: StreamType
        switch type {
        case "window":  streamType = .window
        case "windows":  streamType = .windows
        case "display": streamType = .screen
        case "application": streamType = .application
        case "area": streamType = .screenarea
        case "audio":   streamType = .systemaudio
            default: return // if we don't even know what to record I don't think we should even try
        }
        guard SCContext.beginStart(autoStop: autoStop) else { return }
        SCContext.streamType = streamType
        // Every reason not to start ends here, with one alert
        func failToRecord(_ message: String) {
            SCContext.closeAreaOverlay()
            SCContext.endFailedStart()
            SCContext.showAlertLater(title: "Failed to Record".local, message: message)
        }

        let store = RecordingFileStore(directory: AppSettings.saveDirectory)
        do {
            try store.prepareForRecording()
        } catch {
            return failToRecord(error.localizedDescription)
        }

        guard let content = SCContext.availableContent else {
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

        guard let screen = listedDisplay ?? SCContext.getSCDisplayWithMouse() else {
            return failToRecord("No display to record was found.".local)
        }
        var target = CaptureTarget(type: streamType, display: screen, areaDisplay: listedDisplay, windows: listedWindows,
                                   applications: listedApplications, area: SCContext.screenArea)
        if target.type == .screenarea, let area = target.area, let name = screen.nsScreen?.localizedName {
            SCContext.saveArea(area, forScreen: name)
        }
        let filter: SCContentFilter
        do {
            filter = try CaptureSource.filter(for: &target, content: content)
        } catch {
            return failToRecord(error.localizedDescription)
        }
        // Several windows of which one is left are recorded as a window
        SCContext.streamType = target.type

        let (microphone, problem) = prepareMicCapture(wanted: micOverride ?? AppSettings.recordMic)
        if let problem = problem {
            // A recording that was asked to have the microphone never starts without it unnoticed: a microphone
            // that turns up later cannot be added to it. Cancel is the default button.
            NSApp.activate(ignoringOtherApps: true)
            let message = problem + " " + "A recording started now has no microphone track, and one cannot be added while it runs. Cancel, connect the microphone and start again, or record without it.".local
            let answer = createAlert(level: .critical, title: "Microphone Not Available".local, message: message, button1: "Cancel", button2: "Record Without Microphone").runModal()
            if answer != .alertSecondButtonReturn {
                SCContext.closeAreaOverlay()
                SCContext.endFailedStart()
                return
            }
        }
        // The output files and the settings this recording keeps until it is finished, whatever changes meanwhile
        let recording = RecordingContext(audioOnly: target.type == .systemaudio, recordMic: microphone != nil, fastStart: fastStart, saveDirectory: store.directory)
        let writer = MovieWriter(recording: recording, micConverter: microphone?.converter)
        writer.events.failed = { reason in
            // On the sample queue. The id keeps a late failure from stopping the next recording.
            DispatchQueue.main.async { SCContext.stopRecording(only: recording.id, earlyReason: reason) }
        }
        writer.events.sessionStarted = { SCContext.startTime = Date.now }
        writer.events.microphoneWritten = { end, peak in RecordingMonitor.microphoneWritten(upTo: end, peak: peak) }
        writer.events.systemAudioWritten = { end in RecordingMonitor.systemAudioWritten(upTo: end) }
        // A recording that never gets as far as creating its file still has its writer, an empty one, so its stop
        // reports that nothing was saved
        SCContext.sampleQueue.sync { SCContext.writer = writer }
        SCContext.startTime = nil
        if recording.audioOnly {
            do {
                try writer.prepareAudio()
            } catch {
                failStart(recording, error: error)
                return
            }
        }
        Task { await record(filter: filter, target: target, writer: writer, microphone: microphone) }
    }

    /// A recording that was set up but could not be started: everything created for it is removed, the state goes
    /// back to idle and the user gets one alert.
    func failStart(_ recording: RecordingContext, error: Error) {
        print("Failed to start the recording: \(error)")
        SCContext.discardStart(recording)
        SCContext.showAlertLater(title: "Failed to Record".local, message: error.localizedDescription)
    }

    /// Decides whether this recording gets a microphone track and which device ScreenCaptureKit captures it from.
    /// Without a microphone, `problem` says why not when one is wanted and cannot be recorded.
    func prepareMicCapture(wanted: Bool) -> (microphone: MicrophoneChoice?, problem: String?) {
        guard wanted else { return (nil, nil) }
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .denied || access == .restricted {
            return (nil, "QuickRecorder has no permission to use the microphone (System Settings, Privacy & Security, Microphone).".local)
        }
        guard let defaultMic = AVCaptureDevice.default(for: .audio), let converter = MicConverter() else {
            return (nil, "No microphone was found.".local)
        }
        // The selection is kept for the recording: MicDevices follows the default input, or goes back to the chosen
        // device when it returns
        let selected = SCContext.selectedMicID()
        let defaultID = MicDevices.defaultInputUID() ?? defaultMic.uniqueID
        if selected == "default" {
            return (MicrophoneChoice(converter: converter, selection: selected, captureDeviceID: nil, activeDeviceID: defaultID), nil)
        }
        if SCContext.getMicrophone().contains(where: { $0.uniqueID == selected }) {
            return (MicrophoneChoice(converter: converter, selection: selected, captureDeviceID: selected, activeDeviceID: selected), nil)
        }
        let body = String(format: "\"%@\" is not connected. Recording with the default microphone \"%@\" instead.".local, SCContext.selectedMicName(), defaultMic.localizedName)
        SCContext.showNotification(title: "Microphone Unavailable".local, body: body, id: "quickrecorder.microphone.\(UUID().uuidString)")
        return (MicrophoneChoice(converter: converter, selection: selected, captureDeviceID: nil, activeDeviceID: defaultID), nil)
    }

    func record(filter: SCContentFilter, target: CaptureTarget, writer: MovieWriter, microphone: MicrophoneChoice?) async {
        let recording = writer.recording
        let audioOnly = recording.audioOnly
        let conf = CaptureSource.configuration(for: recording, target: target, filter: filter, microphoneDeviceID: microphone?.captureDeviceID)

        let encoderIsH265 = (AppSettings.encoder == .h265) || AppSettings.recordHDR
        if !audioOnly && !encoderIsH265 {
            var session: VTCompressionSession?
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
                compressionSessionOut: &session
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

        let capture = CaptureSource(filter: filter, configuration: conf, recording: recording, microphone: microphone, queue: SCContext.sampleQueue,
                                    onSample: { SCContext.received($0) },
                                    onStop: { capture, error in SCContext.captureStopped(capture, error: error) })
        SCContext.capture = capture
        do {
            try capture.addOutputs()
            if !audioOnly { try writer.prepareVideo(width: conf.width, height: conf.height) }
            SCContext.sampleQueue.sync { writer.startCapturing() }
            try await capture.start()
        } catch {
            failStart(recording, error: error)
            return
        }
        // From here on the tracks are kept going and watched whether or not their sources deliver anything
        SCContext.sampleQueue.sync { RecordingMonitor.start(for: recording.id) }
        DispatchQueue.main.async {
            // Nothing can have stopped this recording yet: a stop that was asked for while the capture was starting
            // is carried out by enterRecording below, after everything it undoes has been set up
            guard SCContext.state == .starting else { return }
            if !audioOnly { self.startRecordingMouseMonitor() }
            if recording.preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
            if recording.recordMic { MicDevices.watch() }
            RecordingFileStore(directory: recording.saveDirectory).watchFreeSpace { free in
                let reason = String(format: "The disk is almost full, only %@ is left.".local, DiskSpace.formatted(free))
                SCContext.stopRecording(only: recording.id, earlyReason: reason)
            }
            SCContext.enterRecording()
        }
    }
}

extension SCContext {
    /// On `sampleQueue`: a buffer of the capture. The recording's writer puts it on the timeline and into its track.
    static func received(_ sample: CaptureSample) {
        if saveFrame, sample.buffer.imageBuffer != nil {
            saveFrame = false
            savePicture(of: sample.buffer)
        }
        guard let writer = writer else { return }
        if case .audio = sample.kind, writer.recording.audioOnly, writer.isCapturing, !writer.isPaused {
            hideMousePointer = true
        }
        writer.write(sample)
    }

    /// The stream ended without having been asked to. Any thread.
    static func captureStopped(_ stopped: CaptureSource, error: Error) {
        DispatchQueue.main.async {
            // A stream that was already stopped must not stop the recording that was started after it
            guard capture === stopped else { return }
            // While the capture is still starting the stream stays where it is: either startCapture fails and the
            // start is discarded, or the stop below is carried out once it runs
            if state != .starting {
                capture = nil
                stopped.releaseStream()
            }
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userStopped.rawValue {
                // Stopped by the user from the system's screen sharing menu, which is a stop like any other
                stopRecording()
            } else {
                // The capture ended on its own: the file is closed and the user is told that the recording is shorter than expected
                stopRecording(earlyReason: String(format: "The screen capture stopped: %@".local, error.localizedDescription))
            }
        }
    }

    /// Saves one frame as a picture in the folder of the recording (the "saveFrame" hotkey). On `sampleQueue`.
    private static func savePicture(of sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let directory = recording?.saveDirectory ?? AppSettings.saveDirectory
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
