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
        
        var isDirectory: ObjCBool = false
        let outputPath = AppSettings.saveDirectory
        if fd.fileExists(atPath: outputPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { return failToRecord("The output path is a file instead of a folder!".local) }
        } else {
            do {
                try fd.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return failToRecord("Unable to create output folder!".local)
            }
        }
        if let free = DiskSpace.available(at: outputPath), !DiskSpace.canStart(free: free) {
            return failToRecord(String(format: "Not enough free disk space: only %@ is left on the output volume, and at least %@ is needed to start a recording.".local, DiskSpace.formatted(free), DiskSpace.formatted(DiskSpace.startMinimum)))
        }
        
        // file preparation
        guard let content = SCContext.availableContent else {
            return failToRecord("The list of screens and windows is not available. Check the screen recording permission.".local)
        }
        guard let screens = screens else { return failToRecord("No display to record was found.".local) }
        SCContext.screen = content.displays.first(where: { $0 == screens })
        
        if let windows = windows {
            SCContext.window = content.windows.filter({ windows.contains($0) })
        } else if SCContext.streamType == .window {
            return failToRecord("No window to record was given.".local)
        }
        
        if let applications = applications {
            SCContext.application = content.applications.filter({ applications.contains($0) })
        } else if SCContext.streamType == .application {
            return failToRecord("No application to record was given.".local)
        }
        
        guard let screen = SCContext.screen ?? SCContext.getSCDisplayWithMouse() else {
            return failToRecord("No display to record was found.".local)
        }
        let qrSelf = SCContext.getSelf()
        let qrWindows = SCContext.getSelfWindows()
        let dockApp = content.applications.first(where: { $0.bundleIdentifier.description == "com.apple.dock" })
        let wallpaper = content.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title != "LPSpringboard" && title != "Dock"
        })
        let dockWindow = content.windows.filter({
            guard let title = $0.title else { return true }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title == "Dock"
        })
        let desktopFiles = content.windows.filter({
            $0.owningApplication?.bundleIdentifier == "com.apple.finder"
            && $0.title == "" && $0.frame == screen.frame })
        let controlCenterWindow = content.applications.filter({ $0.bundleIdentifier == "com.apple.controlcenter" })
        let mouseWindow = content.windows.filter({ $0.title == WindowTitle.mousePointer && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        let appBlackList = AppSettings.hiddenApps.map({ $0.bundleID })
        let excliudedApps = content.applications.filter({ appBlackList.contains($0.bundleIdentifier) })
        
        if SCContext.streamType == .window || SCContext.streamType == .windows {
            if var includ = SCContext.window {
                if includ.count > 1 {
                    if AppSettings.highlightMouse { includ += mouseWindow }
                    if dockApp != nil { includ += wallpaper }
                    SCContext.filter = SCContentFilter(display: screen, including: includ)
                    SCContext.filter?.includeMenuBar = AppSettings.includeMenuBar
                } else if let only = includ.first {
                    SCContext.streamType = .window
                    SCContext.filter = SCContentFilter(desktopIndependentWindow: only)
                } else {
                    return failToRecord("The window to record is not there any more.".local)
                }
            }
        } else {
            if SCContext.streamType == .screen || SCContext.streamType == .screenarea {
                if SCContext.streamType == .screenarea {
                    if let area = SCContext.screenArea, let name = screen.nsScreen?.localizedName {
                        SCContext.saveArea(area, forScreen: name)
                    }
                }
                var excluded = [SCRunningApplication]()
                var except = [SCWindow]()
                excluded += excliudedApps
                if AppSettings.hideCCenter { excluded += controlCenterWindow }
                if AppSettings.hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                if AppSettings.hideDesktopFiles { except += desktopFiles }
                SCContext.filter = SCContentFilter(display: screen, excludingApplications: excluded, exceptingWindows: except)
                SCContext.filter?.includeMenuBar = AppSettings.includeMenuBar
            }
            if SCContext.streamType == .application {
                var includ = SCContext.application ?? []
                var except = [SCWindow]()
                if let qrSelf = qrSelf { includ.append(qrSelf) }
                let withFinder = includ.map{ $0.bundleIdentifier }.contains("com.apple.finder")
                if withFinder && AppSettings.hideDesktopFiles { except += desktopFiles }
                if AppSettings.hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                if let dock = dockApp { includ.append(dock); except += dockWindow }
                SCContext.filter = SCContentFilter(display: screen, including: includ, exceptingWindows: except)
                SCContext.filter?.includeMenuBar = AppSettings.includeMenuBar
            }
        }
        if let problem = prepareMicCapture(wanted: micOverride ?? AppSettings.recordMic) {
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
        let recording = RecordingContext(audioOnly: SCContext.streamType == .systemaudio, recordMic: SCContext.recordsMic, fastStart: fastStart, saveDirectory: outputPath)
        SCContext.sampleQueue.sync {
            SCContext.recording = recording
            // A writer still here belongs to an earlier recording and must not be taken for this one's
            SCContext.vW = nil
            SCContext.vwInput = nil
            SCContext.awInput = nil
            SCContext.micInput = nil
            SCContext.audioFile = nil
            SCContext.sessionStart = nil
        }
        SCContext.startTime = nil
        if recording.audioOnly {
            SCContext.filter = SCContentFilter(display: screen, excludingApplications: [], exceptingWindows: [])
            do {
                try prepareAudioRecording(recording)
            } catch {
                failStart(recording, error: error)
                return
            }
        }
        guard let filter = SCContext.filter else {
            failStart(recording, error: RecordingError("There is nothing to record.".local))
            return
        }
        Task { await record(filter: filter, recording: recording) }
    }
    
    /// A recording that was set up but could not be started: everything created for it is removed, the state goes
    /// back to idle and the user gets one alert.
    func failStart(_ recording: RecordingContext, error: Error) {
        print("Failed to start the recording: \(error)")
        SCContext.discardStart(recording)
        SCContext.showAlertLater(title: "Failed to Record".local, message: error.localizedDescription)
    }

    /// Decides whether this recording gets a microphone track and which device ScreenCaptureKit captures it from.
    /// Returns why not when the microphone is wanted and cannot be recorded, nil otherwise.
    func prepareMicCapture(wanted: Bool) -> String? {
        SCContext.recordsMic = false
        SCContext.micCaptureDeviceID = nil
        SCContext.micConverter = nil
        SCContext.micSelection = "default"
        SCContext.micActiveDeviceID = nil
        guard wanted else { return nil }
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .denied || access == .restricted {
            return "QuickRecorder has no permission to use the microphone (System Settings, Privacy & Security, Microphone).".local
        }
        guard let defaultMic = AVCaptureDevice.default(for: .audio), let converter = MicConverter() else {
            return "No microphone was found.".local
        }
        SCContext.recordsMic = true
        SCContext.micConverter = converter
        let selected = SCContext.selectedMicID()
        // The selection is kept for the recording: MicDevices follows the default input, or goes back to the chosen
        // device when it returns
        SCContext.micSelection = selected
        SCContext.micActiveDeviceID = MicDevices.defaultInputUID() ?? defaultMic.uniqueID
        if selected == "default" { return nil }
        if SCContext.getMicrophone().contains(where: { $0.uniqueID == selected }) {
            SCContext.micCaptureDeviceID = selected
            SCContext.micActiveDeviceID = selected
        } else {
            let body = String(format: "\"%@\" is not connected. Recording with the default microphone \"%@\" instead.".local, SCContext.selectedMicName(), defaultMic.localizedName)
            SCContext.showNotification(title: "Microphone Unavailable".local, body: body, id: "quickrecorder.microphone.\(UUID().uuidString)")
        }
        return nil
    }

    func record(filter: SCContentFilter, recording: RecordingContext) async {
        SCContext.sampleQueue.sync {
            SCContext.timeOffset = .zero
            SCContext.lastPTS = nil
            SCContext.sessionStart = nil
            SCContext.clockAnchor = nil
            SCContext.audioEndPTS = nil
            SCContext.audioFormatDescription = nil
            SCContext.videoPTS = nil
            SCContext.lastVideoFrame = nil
            SCContext.lastVideoFrameIsCopy = false
            SCContext.firstFrame = nil
            SCContext.isPaused = false
            SCContext.isResume = false
        }
        
        let audioOnly = recording.audioOnly
        
        // HDR uses the local display preset; see https://developer.apple.com/videos/play/wwdc2024/10088/?time=191 for the canonical display alternative
        let conf = AppSettings.recordHDR ? SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay) : SCStreamConfiguration()
        conf.width = 2
        conf.height = 2
        
        if !audioOnly {
            conf.width = Int(filter.contentRect.width) * (AppSettings.recordsPixels ? Int(filter.pointPixelScale) : 1)
            conf.height = Int(filter.contentRect.height) * (AppSettings.recordsPixels ? Int(filter.pointPixelScale) : 1)
            
            conf.showsCursor = AppSettings.showMouse
            if !AppSettings.recordHDR {
                conf.pixelFormat = kCVPixelFormatType_32BGRA
                conf.colorSpaceName = CGColorSpace.sRGB
            } else {
                // For recording HDR in a BT2020 PQ container
                conf.colorSpaceName = CGColorSpace.itur_2100_PQ
//                https://developer.apple.com/videos/play/wwdc2022/10155/ guide on how to record 4k60
//                streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    
// Note: 420 encoding causes color bleed at edges, e.g. youtube settings icon with red logo
                // conf.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
//              dont exceed 8 frames  https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
//                lower queuedepth has more stutter, dont go below 4 https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example/blob/main/Sources/sckrecording/main.swift
                conf.queueDepth = 8
            }
        }
        
        conf.capturesAudio = recording.systemAudio
        conf.sampleRate = 48000
        conf.channelCount = 2
        // The microphone is captured by ScreenCaptureKit as well. A nil device ID means the system default input.
        conf.captureMicrophone = recording.recordMic
        conf.microphoneCaptureDeviceID = SCContext.micCaptureDeviceID
        

        // Always an explicit interval: a timescale of 0 is not a valid time, and leaving the stream unthrottled
        // delivers frames at the display's rate whatever the setting says. An audio-only stream gets next to no frames.
        let fps = SCContext.captureFrameRate(AppSettings.frameRate)
        conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : CMTimeScale(fps))
        print("Frame interval passed to ScreenCaptureKit: \(conf.minimumFrameInterval)")

        if SCContext.streamType == .screenarea {
            if let nsRect = SCContext.screenArea, let display = SCContext.screen {
                let newY = display.frame.height - nsRect.size.height - nsRect.origin.y
                conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
                conf.width = Int(conf.sourceRect.width) * (AppSettings.recordsPixels ? Int(filter.pointPixelScale) : 1)
                conf.height = Int(conf.sourceRect.height) * (AppSettings.recordsPixels ? Int(filter.pointPixelScale) : 1)
            }
        }
        
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
        
        let stream = SCStream(filter: filter, configuration: conf, delegate: self)
        SCContext.stream = stream
        SCContext.streamConfiguration = conf
        do {
            // Every output is handled on the same serial queue, so the writer inputs and the timing state are never used concurrently
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: SCContext.sampleQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: SCContext.sampleQueue)
            if recording.recordMic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: SCContext.sampleQueue) }
            if !audioOnly { try initVideo(conf: conf, recording: recording) }
            SCContext.sampleQueue.sync { SCContext.isCapturing = true }
            try await stream.startCapture()
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
            DiskSpace.startMonitoring(recording.saveDirectory) { free in
                let reason = String(format: "The disk is almost full, only %@ is left.".local, DiskSpace.formatted(free))
                SCContext.stopRecording(only: recording.id, earlyReason: reason)
            }
            SCContext.enterRecording()
        }
    }

    /// Creates the files of an audio-only recording. When it throws, the caller discards what was created.
    func prepareAudioRecording(_ recording: RecordingContext) throws {
        guard let systemAudioURL = recording.systemAudioURL else { throw RecordingError("The audio file has no location.".local) }
        let settings = SCContext.updateAudioSettings(format: recording.audioFormat.rawValue, quality: recording.audioQuality, videoFormat: recording.videoFormat.rawValue)
        if let micAudioURL = recording.micAudioURL {
            let exportMP3 = recording.audioFormat == .mp3
            let jsonString = "{\"format\": \"\(recording.audioFileEnding)\", \"encoder\": \"\(recording.audioEncoder)\", \"exportMP3\": \(exportMP3), \"sysVol\": 1.0, \"micVol\": 1.0}"
            try fd.createDirectory(at: recording.rawURL, withIntermediateDirectories: true, attributes: nil)
            try jsonString.write(to: recording.rawURL.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)

            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            let writer = try AVAssetWriter(outputURL: micAudioURL, fileType: recording.audioFileType)
            SCContext.vW = writer
            // .caf, used for FLAC and Opus, has no movie fragments
            if recording.audioFileType == .m4a { writer.movieFragmentInterval = SCContext.fragmentInterval }
            let micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: settings)
            micInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(micInput) else { throw RecordingError("The microphone track cannot be written in this audio format.".local) }
            writer.add(micInput)
            guard writer.startWriting() else { throw writer.error ?? RecordingError("The microphone file could not be created.".local) }
            SCContext.micInput = micInput
        }
        SCContext.audioFile = try AVAudioFile(forWriting: systemAudioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
    var isMainScreen: Bool {
        guard let id = self.displayID else { return false }
        return (CGDisplayIsMain(id) == 1)
    }
}

extension SCDisplay {
    var nsScreen: NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == self.displayID })
    }
}

extension AppDelegate {
    /// Creates the video file and its tracks. When it throws, the caller discards what was created.
    func initVideo(conf: SCStreamConfiguration, recording: RecordingContext) throws {
        let writer = try AVAssetWriter(outputURL: recording.rawURL, fileType: recording.fileType)
        SCContext.vW = writer
        // The file is written in fragments, so a crash, a kill or a power loss costs the last few seconds instead of
        // the recording: without them a .mp4 or .mov cannot be opened at all unless it was closed properly.
        // Closing the file normally turns it into an ordinary movie file.
        writer.movieFragmentInterval = SCContext.fragmentInterval
        let encoderIsH265 = (AppSettings.encoder == .h265) || AppSettings.recordHDR
        let fps = SCContext.captureFrameRate(AppSettings.frameRate)
        let fpsMultiplier: Double = Double(fps)/8
        let encoderMultiplier: Double = encoderIsH265 ? 0.5 : 0.9
        let resolution = Double(max(600, conf.width)) * Double(max(600, conf.height))
        var qualityMultiplier = 1 - (log10(sqrt(resolution) * fpsMultiplier) / 5)
        switch AppSettings.videoQuality {
            case 0.3: qualityMultiplier = max(0.1, qualityMultiplier)
            case 0.7: qualityMultiplier = max(0.4, min(0.6, qualityMultiplier * 3))
            default: qualityMultiplier = 1.0
        }
        let h264Level = AVVideoProfileLevelH264HighAutoLevel
        let h265Level = AppSettings.recordHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel

        let targetBitrate = resolution * fpsMultiplier * encoderMultiplier * qualityMultiplier * (AppSettings.recordHDR ? 2 : 1)
        print("framerate set in app: \(fps)")
        print("target bitrate: \(targetBitrate/1000000)")

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: encoderIsH265 ? ((AppSettings.withAlpha && !AppSettings.recordHDR) ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc) : AVVideoCodecType.h264,
            // yes, not ideal if we want more than these encoders in the future, but it's ok for now
            AVVideoWidthKey: conf.width,
            AVVideoHeightKey: conf.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: encoderIsH265 ? h265Level : h264Level,
                AVVideoAverageBitRateKey: max(200000, Int(targetBitrate)),
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String : Any]
        ]
        
        if !AppSettings.recordHDR {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] as [String : Any]
        }
        
        let audioSettings = SCContext.updateAudioSettings(format: recording.audioFormat.rawValue, quality: recording.audioQuality, videoFormat: recording.videoFormat.rawValue)
        let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError("The video settings are not supported by this file format.".local) }
        writer.add(videoInput)

        // Only tracks that are fed: the writer puts a fragment on disk once every track has data for it, so a single
        // track that never gets any would leave the whole file unreadable until it is closed
        var audioInput: AVAssetWriterInput?
        if recording.systemAudio {
            let input = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError("The audio settings are not supported by this file format.".local) }
            writer.add(input)
            audioInput = input
        }

        var micInput: AVAssetWriterInput?
        if recording.recordMic {
            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            let input = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError("The microphone track cannot be written in this file format.".local) }
            writer.add(input)
            micInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? RecordingError("The video file could not be created.".local) }
        SCContext.vwInput = videoInput
        SCContext.awInput = audioInput
        SCContext.micInput = micInput
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if SCContext.saveFrame, let imageBuffer = sampleBuffer.imageBuffer {
            SCContext.saveFrame = false
            
            var ciImage = CIImage(cvPixelBuffer: imageBuffer)
            // On the sample queue, where SCContext.recording is assigned
            let url = "\(SCContext.getFilePath(capture: true, directory: SCContext.recording?.saveDirectory)).png".url
            if !AppSettings.recordHDR {
                sampleBuffer.nsImage?.saveToFile(url)
            } else {
                let context = CIContext()
                
                // Create the HEIF destination with the correct UTI
                //            if let destination = url? {
                // Specify format and color space (assuming default settings here)
                //                let format = CIFormat.rgb10
                let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
                
                // let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                
                // Image exposure needs to be increased by one stop to match the original
                ciImage = ciImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
                
                
                
                
                
                //                context.writeHEIF10Representation(of: ciImage, to: destination as! URL, colorSpace: colorSpace)
                do{
                    // try context.writeHEIF10Representation(of:ciImage,
                    //                                       to:url,
                    //                                       colorSpace:colorSpace,
                    //                                       options: [
                    //     kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0
                    try context.writePNGRepresentation(of:ciImage,
                                                       to:url,
                                                       format: .RGB10,
                                                       colorSpace:colorSpace
                    )
                    //        try context.writePNGRepresentation(of:outImage, to:outURL, format: .RGBA16,colorSpace:colorSpace,options:[:])
                } catch let error {
                    // Handle the error case
                    print("Error: \(error)")
                }
                //                CGImageDestinationFinalize(destination)
            }
        }
        // `recording` and `sessionStart` belong to this queue. The statics the main thread owns (`streamType`,
        // `startTime`, `screen`) decide nothing here: stopping clears them while the last buffers still arrive.
        guard SCContext.isCapturing, !SCContext.isPaused, sampleBuffer.isValid, let recording = SCContext.recording else { return }
        var rawPTS = sampleBuffer.presentationTimeStamp
        let duration = sampleBuffer.duration
        if outputType == .microphone {
            // Microphone timestamps are expected on the stream's clock like the other outputs. Should they ever not be,
            // the arrival time is used, so the microphone still lands on the recording's timeline instead of being dropped.
            let now = (stream.synchronizationClock ?? CMClockGetHostTimeClock()).time
            if !rawPTS.isValid || abs(CMTimeGetSeconds(CMTimeSubtract(now, rawPTS))) > 5 {
                rawPTS = duration.isValid ? CMTimeSubtract(now, duration) : now
            }
        }
        guard rawPTS.isValid else { return }
        if let writer = SCContext.vW, writer.status == .failed {
            // The writer gave up between two appends, for example because the disk is full or gone
            SCContext.abortRecording(reason: SCContext.writeFailure(writer.error))
            return
        }
        let rawEnd = duration.isValid && duration.value > 0 ? CMTimeAdd(rawPTS, duration) : rawPTS
        if outputType != .microphone || SCContext.clockAnchor == nil {
            SCContext.clockAnchor = (rawEnd, DispatchTime.now().uptimeNanoseconds)
        }
        // Times on the writer's timeline
        let pts = SCContext.timelineTime(rawPTS)
        let endPTS = CMTimeSubtract(rawEnd, SCContext.timeOffset)
        SCContext.noteEnd(endPTS)
        switch outputType {
        case .screen:
            if recording.audioOnly { break }
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first else { return }
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }
            
            // The first complete frame starts the session; until then nothing is appended to any track
            if SCContext.sessionStart == nil { guard SCContext.beginSession(at: pts) else { return } }
            guard var frame = SCContext.retime(sampleBuffer, by: SCContext.timeOffset) else { return }
            if frameQueue.getArray().contains(where: { $0 >= endPTS }) { print("Skip this frame"); return } else { frameQueue.append(endPTS) }
            guard let vwInput = SCContext.vwInput else { return }
            var framePTS = pts
            if let last = SCContext.videoPTS, pts <= last {
                // The writer fails on a frame that is not later than the one before it. A frame that is only just behind
                // (the last frame was written again a moment ago) goes right after it instead of being lost: it may be
                // the only frame of a new picture, a slide change for example.
                guard CMTimeGetSeconds(CMTimeSubtract(last, pts)) < SCContext.videoStallSeconds else { return }
                framePTS = CMTimeAdd(last, CMTime(value: 1, timescale: 100))
                let timing = CMSampleTimingInfo(duration: frame.duration, presentationTimeStamp: framePTS, decodeTimeStamp: .invalid)
                guard let moved = try? CMSampleBuffer(copying: frame, withNewTiming: [timing]) else { return }
                frame = moved
            }
            if vwInput.isReadyForMoreMediaData {
                // The preview picture is made from the first frame right away, so the frame itself is not kept
                if SCContext.videoPTS == nil { SCContext.firstFrame = SCContext.thumbnail(of: frame) }
                if SCContext.append(frame, to: vwInput) {
                    SCContext.videoPTS = framePTS
                    SCContext.noteEnd(framePTS)
                    SCContext.lastVideoFrame = frame
                    SCContext.lastVideoFrameIsCopy = false
                }
            }
            break
        case .audio:
            if recording.audioOnly { // write directly to file if not video recording
                hideMousePointer = true
                // The first system audio starts the session of the microphone file, if there is one
                if SCContext.sessionStart == nil { guard SCContext.beginSession(at: pts) else { return } }
                guard let samples = sampleBuffer.asPCMBuffer else { return }
                // The file has no timestamps: audio that did not arrive is written as silence, or everything after it
                // would be early, and audio that arrives after silence was written in its place is left out, or
                // everything after it would be late
                guard let start = RecordingMonitor.placeSystemAudio(from: pts, to: endPTS) else { return }
                do {
                    try SCContext.audioFile?.write(from: samples)
                    let end = CMTimeAdd(start, CMTimeSubtract(endPTS, pts))
                    SCContext.audioEndPTS = end
                    RecordingMonitor.systemAudioWritten(upTo: end)
                } catch {
                    SCContext.abortRecording(reason: SCContext.writeFailure(error))
                }
            } else {
                guard SCContext.sessionStart != nil, let awInput = SCContext.awInput else { return }
                SCContext.audioFormatDescription = sampleBuffer.formatDescription
                // The writer plays audio buffers back to back whatever their timestamps say. The buffer goes at the end
                // of what was written, and only once that end is where the buffer belongs.
                guard let start = RecordingMonitor.placeSystemAudio(from: pts, to: endPTS) else { return }
                guard let buffer = SCContext.retime(sampleBuffer, by: CMTimeSubtract(rawPTS, start)) else { return }
                if SCContext.append(buffer, to: awInput) {
                    let end = CMTimeAdd(start, CMTimeSubtract(endPTS, pts))
                    SCContext.audioEndPTS = end
                    RecordingMonitor.systemAudioWritten(upTo: end)
                }
            }
        case .microphone:
            guard SCContext.recordsMic, SCContext.sessionStart != nil, let micInput = SCContext.micInput, let converter = SCContext.micConverter else { return }
            let written = converter.convert(sampleBuffer, at: pts) { buffer in
                SCContext.append(buffer, to: micInput)
            }
            if written { RecordingMonitor.microphoneWritten(upTo: converter.end, peak: converter.lastPeak) }
        @unknown default:
            // An output type this version does not know is not recorded
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        DispatchQueue.main.async {
            // A stream that was already stopped must not stop the recording that was started after it
            guard SCContext.stream === stream else { return }
            // While the capture is still starting the stream stays where it is: either startCapture fails and the
            // start is discarded, or the stop below is carried out once it runs
            if SCContext.state != .starting { SCContext.stream = nil }
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userStopped.rawValue {
                // Stopped by the user from the system's screen sharing menu, which is a stop like any other
                SCContext.stopRecording()
            } else {
                // The capture ended on its own: the file is closed and the user is told that the recording is shorter than expected
                SCContext.stopRecording(earlyReason: String(format: "The screen capture stopped: %@".local, error.localizedDescription))
            }
        }
    }
}

// https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos
// For Sonoma updated to https://developer.apple.com/forums/thread/727709
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
    
    var nsImage: NSImage? {
        return autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ciContext = CIContext()
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
            return nil
        }
    }
}
