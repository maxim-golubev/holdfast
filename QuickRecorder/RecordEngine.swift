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
    @objc func prepRecord(type: String, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false) {
        switch type {
        case "window":  SCContext.streamType = .window
        case "windows":  SCContext.streamType = .windows
        case "display": SCContext.streamType = .screen
        case "application": SCContext.streamType = .application
        case "area": SCContext.streamType = .screenarea
        case "audio":   SCContext.streamType = .systemaudio
            default: return // if we don't even know what to record I don't think we should even try
        }
        var isDirectory: ObjCBool = false
        let outputPath = saveDirectory!
        if fd.fileExists(atPath: outputPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                SCContext.streamType = nil
                _ = createAlert(title: "Failed to Record".local, message: "The output path is a file instead of a folder!".local, button1: "OK").runModal()
                return
            }
        } else {
            do {
                try fd.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                SCContext.streamType = nil
                _ = createAlert(title: "Failed to Record".local, message: "Unable to create output folder!".local, button1: "OK").runModal()
                return
            }
        }
        
        // file preparation
        if let screens = screens {
            SCContext.screen = SCContext.availableContent!.displays.first(where: { $0 == screens })
        } else { SCContext.streamType = nil; return }
        
        if let windows = windows {
            SCContext.window = SCContext.availableContent!.windows.filter({ windows.contains($0) })
        } else { if SCContext.streamType == .window { SCContext.streamType = nil; return } }
        
        if let applications = applications {
            SCContext.application = SCContext.availableContent!.applications.filter({ applications.contains($0) })
        } else { if SCContext.streamType == .application { SCContext.streamType = nil; return } }
        
        let screen = SCContext.screen ?? SCContext.getSCDisplayWithMouse()!
        let qrSelf = SCContext.getSelf()
        let qrWindows = SCContext.getSelfWindows()
        let dockApp = SCContext.availableContent!.applications.first(where: { $0.bundleIdentifier.description == "com.apple.dock" })
        let wallpaper = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title != "LPSpringboard" && title != "Dock"
        })
        let desktop = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "" && title == "Desktop"
        })
        let dockWindow = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return true }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title == "Dock"
        })
        let desktopFiles = SCContext.availableContent!.windows.filter({
            $0.owningApplication?.bundleIdentifier == "com.apple.finder"
            && $0.title == "" && $0.frame == screen.frame })
        let controlCenterWindow = SCContext.availableContent!.applications.filter({ $0.bundleIdentifier == "com.apple.controlcenter" })
        let mouseWindow = SCContext.availableContent!.windows.filter({ $0.title == "Mouse Pointer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        let camLayer = SCContext.availableContent!.windows.filter({ $0.title == "Camera Overlayer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        var appBlackList = [String]()
        if let savedData = ud.data(forKey: "hiddenApps"),
           let decodedApps = try? JSONDecoder().decode([AppInfo].self, from: savedData) {
            appBlackList = (decodedApps as [AppInfo]).map({ $0.bundleID })
        }
        let excliudedApps = SCContext.availableContent!.applications.filter({ appBlackList.contains($0.bundleIdentifier) })
        
        if SCContext.streamType == .window || SCContext.streamType == .windows {
            if var includ = SCContext.window {
                if includ.count > 1 {
                    if highlightMouse { includ += mouseWindow }
                    if background.rawValue == BackgroundType.wallpaper.rawValue { if dockApp != nil { includ += wallpaper }}
                    SCContext.filter = SCContentFilter(display: screen, including: includ + camLayer)
                    if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = includeMenuBar }
                } else {
                    SCContext.streamType = .window
                    SCContext.filter = SCContentFilter(desktopIndependentWindow: includ[0])
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
                if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = ((SCContext.streamType == .screen || SCContext.streamType == .screenarea) && includeMenuBar) }
            }
            if SCContext.streamType == .application {
                var includ = SCContext.application!
                var except = [SCWindow]()
                if let qrSelf = qrSelf { includ.append(qrSelf) }
                let withFinder = includ.map{ $0.bundleIdentifier }.contains("com.apple.finder")
                if withFinder && hideDesktopFiles { except += desktopFiles }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                //if ud.bool(forKey: "highlightMouse") { if let qrSelf = qrSelf { includ.append(qrSelf) }}
                if background.rawValue == BackgroundType.wallpaper.rawValue { if let dock = dockApp { includ.append(dock); except += dockWindow}}
                SCContext.filter = SCContentFilter(display: screen, including: includ, exceptingWindows: except)
                if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = includeMenuBar }
            }
        }
        prepareMicCapture()
        if SCContext.streamType == .systemaudio {
            SCContext.filter = SCContentFilter(display: screen, excludingApplications: [], exceptingWindows: [])
            prepareAudioRecording()
        }
        Task { await record(filter: SCContext.filter!, fastStart: fastStart) }
    }

    /// Decides whether this recording gets a microphone track and which device ScreenCaptureKit captures it from
    func prepareMicCapture() {
        SCContext.recordsMic = false
        SCContext.micCaptureDeviceID = nil
        SCContext.micConverter = nil
        guard recordMic else { return }
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
        if selected == "default" { return }
        if SCContext.getMicrophone().contains(where: { $0.uniqueID == selected }) {
            SCContext.micCaptureDeviceID = selected
        } else {
            let body = String(format: "\"%@\" is not connected. Recording with the default microphone \"%@\" instead.".local, SCContext.selectedMicName(), defaultMic.localizedName)
            SCContext.showNotification(title: "Microphone Unavailable".local, body: body, id: id)
        }
    }

    func record(filter: SCContentFilter, fastStart: Bool = true) async {
        SCContext.timeOffset = .zero
        SCContext.lastPTS = nil
        SCContext.audioEndPTS = nil
        SCContext.isPaused = false
        SCContext.isResume = false
        
        let audioOnly = SCContext.streamType == .systemaudio
        
        let conf: SCStreamConfiguration
#if compiler(>=6.0)
        if recordHDR {
            if #available(macOS 15, *) {
                // TODO change here. https://developer.apple.com/videos/play/wwdc2024/10088/?time=191
                // For canonical display, it means you are capturing HDR content that is optimized for sharing with other HDR devices.
                // hdrLocalDisplay or hdrCanonicalDisplay


                conf = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            } else { conf = SCStreamConfiguration() }
        } else { conf = SCStreamConfiguration() }
#else
        conf = SCStreamConfiguration()
#endif
        conf.width = 2
        conf.height = 2
        
        if !audioOnly {
            if #available(macOS 14.0, *) {
                conf.width = Int(filter.contentRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                conf.height = Int(filter.contentRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
            } else {
                guard let pointPixelScaleOld = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).nsScreen?.backingScaleFactor else { return }
                if SCContext.streamType == .application || SCContext.streamType == .windows || SCContext.streamType == .screen {
                    let frame = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).frame
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                if SCContext.streamType == .window {
                    let frame = SCContext.window![0].frame
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                if SCContext.streamType == .screenarea {
                    let frame = SCContext.screenArea!
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                conf.width = conf.width * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                conf.height = conf.height * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
            }
            
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
        
        conf.capturesAudio = recordWinSound || fastStart || audioOnly
        conf.sampleRate = 48000
        conf.channelCount = 2
        // The microphone is captured by ScreenCaptureKit as well. A nil device ID means the system default input.
        conf.captureMicrophone = SCContext.recordsMic
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
            if let nsRect = SCContext.screenArea {
                let newY = SCContext.screen!.frame.height - nsRect.size.height - nsRect.origin.y
                conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
                if #available(macOS 14.0, *) {
                    conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                    conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                } else {
                    guard let pointPixelScaleOld = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).nsScreen?.backingScaleFactor else { return }
                    conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                    conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                }
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
        
        SCContext.stream = SCStream(filter: filter, configuration: conf, delegate: self)
        do {
            // Every output is handled on the same serial queue, so the writer inputs and the timing state are never used concurrently
            try SCContext.stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: SCContext.sampleQueue)
            try SCContext.stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: SCContext.sampleQueue)
            if SCContext.recordsMic { try SCContext.stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: SCContext.sampleQueue) }
            if !audioOnly { initVideo(conf: conf) }
            SCContext.isCapturing = true
            try await SCContext.stream.startCapture()
        } catch {
            SCContext.showNotification(title: "Failed to Record".local, body: error.localizedDescription, id: "quickrecorder.error.\(UUID().uuidString)")
            assertionFailure("capture failed".local)
            return
        }
        if !audioOnly { registerGlobalMouseMonitor() }
        DispatchQueue.main.async { updateStatusBar() }
        if preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
    }

    func prepareAudioRecording() {
        var fileEnding = audioFormat.rawValue
        var fileType = AVFileType.m4a
        let encorder = fileEnding == AudioFormat.mp3.rawValue ? "aac" : fileEnding
        switch fileEnding { // todo: I'd like to store format info differently
            case AudioFormat.mp3.rawValue: fallthrough
            case AudioFormat.aac.rawValue: fallthrough
            case AudioFormat.alac.rawValue: fileEnding = "m4a"
            case AudioFormat.flac.rawValue: fileEnding = "flac"; fileType = .caf
            case AudioFormat.opus.rawValue: fileEnding = "ogg"; fileType = .caf
            default: assertionFailure("loaded unknown audio format: ".local + fileEnding)
        }
        let path = SCContext.getFilePath()
        if SCContext.recordsMic {
            SCContext.filePath = "\(path).qma"
            SCContext.filePath1 = "\(path).qma/sys.\(fileEnding)"
            SCContext.filePath2 = "\(path).qma/mic.\(fileEnding)"
            let infoJsonURL = "\(path).qma/info.json".url
            let jsonString = "{\"format\": \"\(fileEnding)\", \"encoder\": \"\(encorder)\", \"exportMP3\": \(audioFormat.rawValue == AudioFormat.mp3.rawValue), \"sysVol\": 1.0, \"micVol\": 1.0}"
            try? fd.createDirectory(at: SCContext.filePath.url, withIntermediateDirectories: true, attributes: nil)
            try? jsonString.write(to: infoJsonURL, atomically: true, encoding: .utf8)
            
            SCContext.audioFile = try! AVAudioFile(forWriting: SCContext.filePath1.url, settings: SCContext.updateAudioSettings(), commonFormat: .pcmFormatFloat32, interleaved: false)

            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            SCContext.vW = try? AVAssetWriter.init(outputURL: SCContext.filePath2.url, fileType: fileType)
            SCContext.micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: SCContext.updateAudioSettings())
            SCContext.micInput.expectsMediaDataInRealTime = true
            if SCContext.vW.canAdd(SCContext.micInput) { SCContext.vW.add(SCContext.micInput) }
            SCContext.vW.startWriting()
            //SCContext.audioFile2 = try! AVAudioFile(forWriting: SCContext.filePath2.url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } else {
            SCContext.filePath = "\(path).\(fileEnding)"
            SCContext.filePath1 = SCContext.filePath
            SCContext.audioFile = try! AVAudioFile(forWriting: SCContext.filePath.url, settings: SCContext.updateAudioSettings(), commonFormat: .pcmFormatFloat32, interleaved: false)
        }
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
    func initVideo(conf: SCStreamConfiguration) {
        SCContext.startTime = nil

        let fileEnding = videoFormat.rawValue
        var fileType: AVFileType?
        switch fileEnding {
            case VideoFormat.mov.rawValue: fileType = AVFileType.mov
            case VideoFormat.mp4.rawValue: fileType = AVFileType.mp4
            default: assertionFailure("loaded unknown video format".local)
        }

        if remuxAudio && SCContext.recordsMic && recordWinSound {
            SCContext.filePath = "\(SCContext.getFilePath()).\(fileEnding).\(fileEnding).\(fileEnding)"
        } else {
            SCContext.filePath = "\(SCContext.getFilePath()).\(fileEnding)"
        }
        SCContext.vW = try? AVAssetWriter.init(outputURL: SCContext.filePath.url, fileType: fileType!)
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
        
        SCContext.vwInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        SCContext.vwInput.expectsMediaDataInRealTime = true
        
        if SCContext.vW.canAdd(SCContext.vwInput) { SCContext.vW.add(SCContext.vwInput) }

        SCContext.awInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: SCContext.updateAudioSettings())
        SCContext.awInput.expectsMediaDataInRealTime = true
        if SCContext.vW.canAdd(SCContext.awInput) { SCContext.vW.add(SCContext.awInput) }

        if SCContext.recordsMic {
            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            SCContext.micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: SCContext.updateAudioSettings())
            SCContext.micInput.expectsMediaDataInRealTime = true
            if SCContext.vW.canAdd(SCContext.micInput) { SCContext.vW.add(SCContext.micInput) }
        }
        SCContext.vW.startWriting()
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
            let url = "\(SCContext.getFilePath(capture: true)).png".url
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
                    if #available(macOS 14.0, *) {
                        try context.writePNGRepresentation(of:ciImage,
                                                           to:url,
                                                           format: .RGB10,
                                                           colorSpace:colorSpace
                        )
                    } else {
                        // Fallback on earlier versions
                        print("RGB10 PNG not supported on this macOS version")
                        try context.writePNGRepresentation(of:ciImage,
                                                           to:url,
                                                           format: .RGBA8,
                                                           colorSpace:colorSpace)
                    }
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
        if SCContext.isResume {
            SCContext.isResume = false
            // The first buffer after a pause continues where the recording left off. The paused time is taken out of
            // every track alike, which keeps video, system audio and microphone in sync.
            if let last = SCContext.lastPTS {
                let offset = CMTimeSubtract(rawPTS, last)
                if offset > SCContext.timeOffset { SCContext.timeOffset = offset }
                print("time removed for pauses: \(CMTimeGetSeconds(SCContext.timeOffset))")
            }
        }
        // Times on the writer's timeline
        let pts = CMTimeSubtract(rawPTS, SCContext.timeOffset)
        let endPTS = duration.isValid && duration.value > 0 ? CMTimeAdd(pts, duration) : pts
        if let last = SCContext.lastPTS {
            if endPTS > last { SCContext.lastPTS = endPTS }
        } else {
            SCContext.lastPTS = endPTS
        }
        switch outputType {
        case .screen:
            if (SCContext.screen == nil && SCContext.window == nil && SCContext.application == nil) || SCContext.streamType == .systemaudio { break }
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first else { return }
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }
            
            if SCContext.vW != nil && SCContext.vW?.status == .writing, SCContext.startTime == nil {
                SCContext.startTime = Date.now
                SCContext.vW.startSession(atSourceTime: pts)
                SCContext.micConverter?.start(at: pts)
            }
            guard let frame = SCContext.retime(sampleBuffer, by: SCContext.timeOffset) else { return }
            if frameQueue.getArray().contains(where: { $0 >= endPTS }) { print("Skip this frame"); return } else { frameQueue.append(endPTS) }
            if SCContext.vwInput.isReadyForMoreMediaData {
                if #available(macOS 14.2, *) {
                    if let rect = attachments[.presenterOverlayContentRect] as? [String: Any]{
                        var type = "np"
                        let off = (rect["X"] as! CGFloat == .infinity)
                        let small = (rect["X"] as! CGFloat == 0.0)
                        let big = (!off && !small)
                        if off { type = "OFF" } else if small { type = "Small" } else if big { type = "Big" }
                        if type != presenterType {
                            print("Presenter Overlay set to \"\(type)\"!")
                            isCameraReady = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
                                self.isCameraReady = true
                            }
                            presenterType = type
                        }
                    }
                }
                if isPresenterON && !isCameraReady { break }
                if SCContext.firstFrame == nil { SCContext.firstFrame = frame }
                SCContext.vwInput.append(frame)
            }
            break
        case .audio:
            if SCContext.streamType == .systemaudio { // write directly to file if not video recording
                hideMousePointer = true
                if SCContext.startTime == nil {
                    if SCContext.recordsMic, SCContext.vW?.status == .writing {
                        SCContext.vW.startSession(atSourceTime: pts)
                        SCContext.micConverter?.start(at: pts)
                    }
                    SCContext.startTime = Date.now
                }
                guard let samples = sampleBuffer.asPCMBuffer else { return }
                do { try SCContext.audioFile?.write(from: samples) }
                catch { assertionFailure("audio file writing issue".local) }
            } else {
                guard SCContext.startTime != nil, let awInput = SCContext.awInput else { return }
                var start = pts
                if let end = SCContext.audioEndPTS, start < end {
                    // The writer is never handed audio that starts before what it already has
                    if endPTS <= end { return }
                    start = end
                }
                guard let buffer = SCContext.retime(sampleBuffer, by: CMTimeSubtract(rawPTS, start)) else { return }
                if awInput.isReadyForMoreMediaData, awInput.append(buffer) {
                    SCContext.audioEndPTS = duration.isValid ? CMTimeAdd(start, duration) : start
                }
            }
        case .microphone:
            guard SCContext.recordsMic, SCContext.startTime != nil, let micInput = SCContext.micInput else { return }
            SCContext.micConverter?.convert(sampleBuffer, at: pts) { buffer in
                micInput.isReadyForMoreMediaData && micInput.append(buffer)
            }
        @unknown default:
            assertionFailure("unknown stream type".local)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        DispatchQueue.main.async {
            SCContext.stream = nil
            SCContext.stopRecording()
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
