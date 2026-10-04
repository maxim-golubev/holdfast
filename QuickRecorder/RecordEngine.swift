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
    /// `recordMic` overrides the "recordMic" setting for this recording only
    func prepRecord(type: String, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false, recordMic micOverride: Bool? = nil) {
        switch type {
        case "window":  SCContext.streamType = .window
        case "windows":  SCContext.streamType = .windows
        case "display": SCContext.streamType = .screen
        case "application": SCContext.streamType = .application
        case "area": SCContext.streamType = .screenarea
        case "audio":   SCContext.streamType = .systemaudio
            default: return // if we don't even know what to record I don't think we should even try
        }
        // Every reason not to start ends here, with one alert
        func failToRecord(_ message: String) {
            SCContext.streamType = nil
            SCContext.showAlertLater(title: "Failed to Record".local, message: message)
        }
        
        var isDirectory: ObjCBool = false
        guard let outputPath = saveDirectory else { return failToRecord("No output folder is set.".local) }
        if fd.fileExists(atPath: outputPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { return failToRecord("The output path is a file instead of a folder!".local) }
        } else {
            do {
                try fd.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return failToRecord("Unable to create output folder!".local)
            }
        }
        if let free = DiskSpace.available(at: outputPath), free < DiskSpace.startMinimum {
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
        let desktop = content.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "" && title == "Desktop"
        })
        let dockWindow = content.windows.filter({
            guard let title = $0.title else { return true }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title == "Dock"
        })
        let desktopFiles = content.windows.filter({
            $0.owningApplication?.bundleIdentifier == "com.apple.finder"
            && $0.title == "" && $0.frame == screen.frame })
        let controlCenterWindow = content.applications.filter({ $0.bundleIdentifier == "com.apple.controlcenter" })
        let mouseWindow = content.windows.filter({ $0.title == "Mouse Pointer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        let camLayer = content.windows.filter({ $0.title == "Camera Overlayer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        var appBlackList = [String]()
        if let savedData = ud.data(forKey: "hiddenApps"),
           let decodedApps = try? JSONDecoder().decode([AppInfo].self, from: savedData) {
            appBlackList = (decodedApps as [AppInfo]).map({ $0.bundleID })
        }
        let excliudedApps = content.applications.filter({ appBlackList.contains($0.bundleIdentifier) })
        
        if SCContext.streamType == .window || SCContext.streamType == .windows {
            if var includ = SCContext.window {
                if includ.count > 1 {
                    if highlightMouse { includ += mouseWindow }
                    if background.rawValue == BackgroundType.wallpaper.rawValue { if dockApp != nil { includ += wallpaper }}
                    SCContext.filter = SCContentFilter(display: screen, including: includ + camLayer)
                    SCContext.filter?.includeMenuBar = includeMenuBar
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
                        let a = ["x": area.origin.x, "y": area.origin.y, "width": area.width, "height": area.height]
                        ud.set([name: a], forKey: "savedArea")
                    }
                }
                var excluded = [SCRunningApplication]()
                var except = [SCWindow]()
                excluded += excliudedApps
                if hideCCenter { excluded += controlCenterWindow }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                if background.rawValue != BackgroundType.wallpaper.rawValue { if dockApp != nil {
                    except += wallpaper
                    except += desktop
                }}
                if hideDesktopFiles { except += desktopFiles }
                SCContext.filter = SCContentFilter(display: screen, excludingApplications: excluded, exceptingWindows: except)
                SCContext.filter?.includeMenuBar = includeMenuBar
            }
            if SCContext.streamType == .application {
                var includ = SCContext.application ?? []
                var except = [SCWindow]()
                if let qrSelf = qrSelf { includ.append(qrSelf) }
                let withFinder = includ.map{ $0.bundleIdentifier }.contains("com.apple.finder")
                if withFinder && hideDesktopFiles { except += desktopFiles }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                //if ud.bool(forKey: "highlightMouse") { if let qrSelf = qrSelf { includ.append(qrSelf) }}
                if background.rawValue == BackgroundType.wallpaper.rawValue { if let dock = dockApp { includ.append(dock); except += dockWindow}}
                SCContext.filter = SCContentFilter(display: screen, including: includ, exceptingWindows: except)
                SCContext.filter?.includeMenuBar = includeMenuBar
            }
        }
        prepareMicCapture(wanted: micOverride ?? recordMic)
        // The output files and the settings this recording keeps until it is finished, whatever changes meanwhile
        let recording = RecordingContext(audioOnly: SCContext.streamType == .systemaudio, recordMic: SCContext.recordsMic, saveDirectory: outputPath)
        SCContext.sampleQueue.sync {
            SCContext.recording = recording
            // A writer still here belongs to an earlier recording and must not be taken for this one's
            SCContext.vW = nil
            SCContext.vwInput = nil
            SCContext.awInput = nil
            SCContext.micInput = nil
            SCContext.audioFile = nil
        }
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
        Task { await record(filter: filter, fastStart: fastStart, recording: recording) }
    }
    
    /// A recording that was set up but could not be started: everything created for it is removed and the user gets one alert.
    /// Nothing happens when the recording was stopped or replaced in the meantime.
    func failStart(_ recording: RecordingContext, error: Error) {
        print("Failed to start the recording: \(error)")
        guard SCContext.discardStart(recording) else { return }
        SCContext.showAlertLater(title: "Failed to Record".local, message: error.localizedDescription)
    }

    /// Decides whether this recording gets a microphone track and which device ScreenCaptureKit captures it from
    func prepareMicCapture(wanted: Bool) {
        SCContext.recordsMic = false
        SCContext.micCaptureDeviceID = nil
        SCContext.micConverter = nil
        SCContext.micSelection = "default"
        SCContext.micActiveDeviceID = nil
        guard wanted else { return }
        let id = "quickrecorder.microphone.\(UUID().uuidString)"
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .denied || access == .restricted {
            SCContext.showNotification(title: "Recording Without Microphone".local, body: "QuickRecorder has no permission to use the microphone.".local, id: id)
            return
        }
        guard let defaultMic = AVCaptureDevice.default(for: .audio), let converter = MicConverter() else {
            SCContext.showNotification(title: "Recording Without Microphone".local, body: "No microphone was found.".local, id: id)
            return
        }
        SCContext.recordsMic = true
        SCContext.micConverter = converter
        let selected = SCContext.selectedMicID()
        // The selection is kept for the recording: MicDevices follows the default input, or goes back to the chosen
        // device when it returns
        SCContext.micSelection = selected
        SCContext.micActiveDeviceID = MicDevices.defaultInputUID() ?? defaultMic.uniqueID
        if selected == "default" { return }
        if SCContext.getMicrophone().contains(where: { $0.uniqueID == selected }) {
            SCContext.micCaptureDeviceID = selected
            SCContext.micActiveDeviceID = selected
        } else {
            let body = String(format: "\"%@\" is not connected. Recording with the default microphone \"%@\" instead.".local, SCContext.selectedMicName(), defaultMic.localizedName)
            SCContext.showNotification(title: "Microphone Unavailable".local, body: body, id: id)
        }
    }

    func record(filter: SCContentFilter, fastStart: Bool = true, recording: RecordingContext) async {
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
        let conf = recordHDR ? SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay) : SCStreamConfiguration()
        conf.width = 2
        conf.height = 2
        
        if !audioOnly {
            conf.width = Int(filter.contentRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
            conf.height = Int(filter.contentRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
            
            if fastStart{
                conf.showsCursor = false
            } else{
                conf.showsCursor = showMouse
            }
                    

            if background.rawValue != BackgroundType.wallpaper.rawValue { conf.backgroundColor = SCContext.getBackgroundColor() }
            if !recordHDR {
                conf.pixelFormat = kCVPixelFormatType_32BGRA
                conf.colorSpaceName = CGColorSpace.sRGB
                //if withAlpha { conf.pixelFormat = kCVPixelFormatType_32BGRA }
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
        
        conf.capturesAudio = recording.recordWinSound || fastStart || audioOnly
        conf.sampleRate = 48000
        conf.channelCount = 2
        // The microphone is captured by ScreenCaptureKit as well. A nil device ID means the system default input.
        conf.captureMicrophone = recording.recordMic
        conf.microphoneCaptureDeviceID = SCContext.micCaptureDeviceID
        

        //  conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : CMTimeScale(frameRate))
         conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : (frameRate >= 60 ? 0 : CMTimeScale(frameRate)))

//        CMTimeScale is the denominator in the fraction
//        conf.minimumFrameInterval = CMTime(seconds: audioOnly ? Double(CMTimeScale.max) : Double(1)/Double(frameRate), preferredTimescale: 10000)

        // note: ScreenCaptureKit only delivers frames when something changes
        // https://www.reddit.com/r/swift/comments/158n4c9/comment/ju847rm/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button

        //blog post from the reddit comment https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/

        //https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example

        // https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval
        //minimumFrameInterval: Use this value to throttle the rate at which you receive updates. The default value is 0, which indicates that the system uses the maximum supported frame rate.

        print("Frame interval passed to ScreenCaptureKit. (timescale is FPS. 0 means no throttling): \(conf.minimumFrameInterval)")
        

        if SCContext.streamType == .screenarea {
            if let nsRect = SCContext.screenArea, let display = SCContext.screen {
                let newY = display.frame.height - nsRect.size.height - nsRect.origin.y
                conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
                conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
            }
        }
        
        let encoderIsH265 = (encoder.rawValue == Encoder.h265.rawValue) || recordHDR
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
                if button == .alertFirstButtonReturn { ud.setValue(Encoder.h265.rawValue, forKey: "encoder") }
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
        if !audioOnly { registerGlobalMouseMonitor() }
        DispatchQueue.main.async {
            updateStatusBar()
            // Recordings are stopped on the main thread. If this one was stopped while the capture was starting,
            // nothing would release the assertion or end the disk check any more, so they are not started.
            guard SCContext.stream === stream else { return }
            if recording.preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
            if recording.recordMic { MicDevices.watch() }
            DiskSpace.startMonitoring(recording.saveDirectory) { free in
                let reason = String(format: "The disk is almost full, only %@ is left.".local, DiskSpace.formatted(free))
                SCContext.stopRecording(only: recording.id, earlyReason: reason)
            }
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
        SCContext.startTime = nil

        let writer = try AVAssetWriter(outputURL: recording.rawURL, fileType: recording.fileType)
        SCContext.vW = writer
        // The file is written in fragments, so a crash, a kill or a power loss costs the last few seconds instead of
        // the recording: without them a .mp4 or .mov cannot be opened at all unless it was closed properly.
        // Closing the file normally turns it into an ordinary movie file.
        writer.movieFragmentInterval = SCContext.fragmentInterval
        let encoderIsH265 = (encoder.rawValue == Encoder.h265.rawValue) || recordHDR
        let fpsMultiplier: Double = Double(frameRate)/8
        let encoderMultiplier: Double = encoderIsH265 ? 0.5 : 0.9
        let resolution = Double(max(600, conf.width)) * Double(max(600, conf.height))
        var qualityMultiplier = 1 - (log10(sqrt(resolution) * fpsMultiplier) / 5)
        switch videoQuality {
            case 0.3: qualityMultiplier = max(0.1, qualityMultiplier)
            case 0.7: qualityMultiplier = max(0.4, min(0.6, qualityMultiplier * 3))
            default: qualityMultiplier = 1.0
        }
        let h264Level = AVVideoProfileLevelH264HighAutoLevel
        let h265Level = recordHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel

        let targetBitrate = resolution * fpsMultiplier * encoderMultiplier * qualityMultiplier * (recordHDR ? 2 : 1)
        print("framerate set in app: \(frameRate)")
        print("target bitrate: \(targetBitrate/1000000)")

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: encoderIsH265 ? ((withAlpha && !recordHDR) ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc) : AVVideoCodecType.h264,
            // yes, not ideal if we want more than these encoders in the future, but it's ok for now
            AVVideoWidthKey: conf.width,
            AVVideoHeightKey: conf.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: encoderIsH265 ? h265Level : h264Level,
                AVVideoAverageBitRateKey: max(200000, Int(targetBitrate)),
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ] as [String : Any]
        ]
        
        if !recordHDR {
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
        if conf.capturesAudio {
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
    
    func outputVideoEffectDidStart(for stream: SCStream) {
        DispatchQueue.main.async { camWindow.close() }
        print("[Presenter Overlay ON]")
        isPresenterON = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
            self.isCameraReady = true
        }
    }
    
    func outputVideoEffectDidStop(for stream: SCStream) {
        print("[Presenter Overlay OFF]")
        presenterType = "OFF"
        isPresenterON = false
        isCameraReady = false
        DispatchQueue.main.async {
            if SCContext.stream != nil { camWindow.orderFront(self) }
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if SCContext.saveFrame, let imageBuffer = sampleBuffer.imageBuffer {
            SCContext.saveFrame = false
            
            var ciImage = CIImage(cvPixelBuffer: imageBuffer)
            // On the sample queue, where SCContext.recording is assigned
            let url = "\(SCContext.getFilePath(capture: true, directory: SCContext.recording?.saveDirectory)).png".url
            if !recordHDR {
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
        guard SCContext.isCapturing, !SCContext.isPaused, sampleBuffer.isValid else { return }
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
            if (SCContext.screen == nil && SCContext.window == nil && SCContext.application == nil) || SCContext.streamType == .systemaudio { break }
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first else { return }
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }
            
            if SCContext.startTime == nil, let writer = SCContext.vW, writer.status == .writing {
                SCContext.startTime = Date.now
                writer.startSession(atSourceTime: pts)
                SCContext.sessionStart = pts
                SCContext.micConverter?.start(at: pts)
            }
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
                if let rect = attachments[.presenterOverlayContentRect] as? [String: Any], let x = rect["X"] as? CGFloat {
                    let type = x == .infinity ? "OFF" : (x == 0.0 ? "Small" : "Big")
                    if type != presenterType {
                        print("Presenter Overlay set to \"\(type)\"!")
                        isCameraReady = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
                            self.isCameraReady = true
                        }
                        presenterType = type
                    }
                }
                if isPresenterON && !isCameraReady { break }
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
            if SCContext.streamType == .systemaudio { // write directly to file if not video recording
                hideMousePointer = true
                if SCContext.startTime == nil {
                    if SCContext.recordsMic, let writer = SCContext.vW, writer.status == .writing {
                        writer.startSession(atSourceTime: pts)
                        SCContext.micConverter?.start(at: pts)
                    }
                    SCContext.sessionStart = pts
                    SCContext.startTime = Date.now
                }
                guard let samples = sampleBuffer.asPCMBuffer else { return }
                // The file has no timestamps: audio that did not arrive is written as silence, or everything after it would be early
                if let end = SCContext.audioEndPTS, CMTimeGetSeconds(CMTimeSubtract(pts, end)) > RecordingMonitor.gapTolerance {
                    RecordingMonitor.fillSystemAudio(upTo: pts)
                }
                do {
                    try SCContext.audioFile?.write(from: samples)
                    SCContext.audioEndPTS = max(SCContext.audioEndPTS ?? endPTS, endPTS)
                    RecordingMonitor.systemAudioWritten(upTo: endPTS)
                } catch {
                    SCContext.abortRecording(reason: SCContext.writeFailure(error))
                }
            } else {
                guard SCContext.startTime != nil, let awInput = SCContext.awInput else { return }
                SCContext.audioFormatDescription = sampleBuffer.formatDescription
                var start = pts
                if let end = SCContext.audioEndPTS {
                    if start < end {
                        // The writer is never handed audio that starts before what it already has
                        if endPTS <= end { return }
                        start = end
                    } else if CMTimeGetSeconds(CMTimeSubtract(start, end)) > RecordingMonitor.gapTolerance {
                        // The writer plays audio buffers back to back whatever their timestamps say, so audio that
                        // did not arrive is written as silence
                        RecordingMonitor.fillSystemAudio(upTo: start)
                    }
                }
                guard let buffer = SCContext.retime(sampleBuffer, by: CMTimeSubtract(rawPTS, start)) else { return }
                if SCContext.append(buffer, to: awInput) {
                    let end = duration.isValid ? CMTimeAdd(start, duration) : start
                    SCContext.audioEndPTS = end
                    RecordingMonitor.systemAudioWritten(upTo: end)
                }
            }
        case .microphone:
            guard SCContext.recordsMic, SCContext.startTime != nil, let micInput = SCContext.micInput, let converter = SCContext.micConverter else { return }
            let written = converter.convert(sampleBuffer, at: pts) { buffer in
                SCContext.append(buffer, to: micInput)
            }
            if written { RecordingMonitor.microphoneWritten(upTo: converter.end, peak: converter.lastPeak) }
        @unknown default:
            assertionFailure("unknown stream type".local)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        DispatchQueue.main.async {
            // A stream that was already stopped must not stop the recording that was started after it
            guard SCContext.stream === stream else { return }
            SCContext.stream = nil
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
