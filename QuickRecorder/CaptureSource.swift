//
//  CaptureSource.swift
//  QuickRecorder
//

import AVFoundation
import ScreenCaptureKit

/// What a recording captures, as `RecorderController.start` resolved it against the list of screens and windows
struct CaptureTarget {
    /// `.windows` turns into `.window` when the filter is built for a single window
    var type: StreamType
    /// The display that is recorded, or that an application or several windows are recorded on
    let display: SCDisplay
    /// The display the area was selected on, nil when it is not connected any more
    let areaDisplay: SCDisplay?
    let windows: [SCWindow]?
    let applications: [SCRunningApplication]?
    /// The selected area of an area recording, in the coordinates of its screen
    let area: NSRect?
}

/// The microphone of a recording, decided when it starts (`prepareMicCapture`)
struct MicrophoneChoice {
    let converter: MicConverter
    /// The setting the recording was started with: a device's uniqueID, or "default"
    let selection: String
    /// The device ScreenCaptureKit is asked to capture, nil for the system default input
    let captureDeviceID: String?
    /// The device the microphone is captured from at the start
    let activeDeviceID: String?
}

/// The ScreenCaptureKit side of one recording: what is captured (`filter(for:content:)`), how
/// (`configuration(for:target:filter:microphoneDeviceID:)`), and the stream with its delegate and outputs. Screen,
/// system audio and microphone all arrive here and are handed on as `CaptureSample`s on the queue it was given.
/// One is created for every recording. Except for the stream's callbacks it is used on the main thread.
final class CaptureSource: NSObject, SCStreamDelegate, SCStreamOutput, RecordingCapture {
    /// The configuration the stream was started with, kept to update it when the microphone changes
    let configuration: SCStreamConfiguration
    let recordsMic: Bool
    /// The microphone setting this recording was started with: a device's uniqueID, or "default"
    let micSelection: String
    /// The device the microphone is being captured from. `MicDevices` changes it when the devices change.
    var micActiveDeviceID: String?

    private var stream: SCStream?
    private let queue: DispatchQueue
    private let onSample: (CaptureSample) -> Void
    private let onStop: (CaptureSource, Error) -> Void

    /// `onSample` gets every buffer of every output, on `queue`. `onStop` is called, on a queue of the stream's,
    /// when the stream ends without having been asked to.
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, recording: RecordingContext, microphone: MicrophoneChoice?,
         queue: DispatchQueue, onSample: @escaping (CaptureSample) -> Void, onStop: @escaping (CaptureSource, Error) -> Void) {
        self.configuration = configuration
        self.recordsMic = recording.recordMic
        self.micSelection = microphone?.selection ?? "default"
        self.micActiveDeviceID = microphone?.activeDeviceID
        self.queue = queue
        self.onSample = onSample
        self.onStop = onStop
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    // MARK: - What is captured

    /// The content filter for `target`. Throws when what was selected is not there.
    static func filter(for target: inout CaptureTarget, content: SCShareableContent) throws -> SCContentFilter {
        let screen = target.display
        let qrSelf = ScreenContent.getSelf()
        let qrWindows = ScreenContent.getSelfWindows()
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
        let excludedApps = content.applications.filter({ appBlackList.contains($0.bundleIdentifier) })

        switch target.type {
        case .window, .windows:
            guard var included = target.windows else { throw RecordingError("There is nothing to record.".local) }
            if included.count > 1 {
                if AppSettings.highlightMouse { included += mouseWindow }
                if dockApp != nil { included += wallpaper }
                let filter = SCContentFilter(display: screen, including: included)
                filter.includeMenuBar = AppSettings.includeMenuBar
                return filter
            } else if let only = included.first {
                target.type = .window
                return SCContentFilter(desktopIndependentWindow: only)
            } else {
                throw RecordingError("The window to record is not there any more.".local)
            }
        case .screen, .screenarea:
            var excluded = [SCRunningApplication]()
            var except = [SCWindow]()
            excluded += excludedApps
            if AppSettings.hideCCenter { excluded += controlCenterWindow }
            if AppSettings.hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
            if AppSettings.hideDesktopFiles { except += desktopFiles }
            let filter = SCContentFilter(display: screen, excludingApplications: excluded, exceptingWindows: except)
            filter.includeMenuBar = AppSettings.includeMenuBar
            return filter
        case .application:
            var included = target.applications ?? []
            var except = [SCWindow]()
            if let qrSelf = qrSelf { included.append(qrSelf) }
            let withFinder = included.map{ $0.bundleIdentifier }.contains("com.apple.finder")
            if withFinder && AppSettings.hideDesktopFiles { except += desktopFiles }
            if AppSettings.hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
            if let dock = dockApp { included.append(dock); except += dockWindow }
            let filter = SCContentFilter(display: screen, including: included, exceptingWindows: except)
            filter.includeMenuBar = AppSettings.includeMenuBar
            return filter
        case .systemaudio:
            // ScreenCaptureKit delivers audio only with a stream of a display
            return SCContentFilter(display: screen, excludingApplications: [], exceptingWindows: [])
        }
    }

    /// The stream configuration of `recording`: picture size and format, system audio, microphone and frame rate.
    /// `microphoneDeviceID` is the device to capture, nil for the system default input.
    static func configuration(for recording: RecordingContext, target: CaptureTarget, filter: SCContentFilter, microphoneDeviceID: String?) -> SCStreamConfiguration {
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
                // For recording HDR in a BT2020 PQ container. 4:2:0 formats bleed colour at edges, so the
                // preset's pixel format is kept.
                conf.colorSpaceName = CGColorSpace.itur_2100_PQ
                // Not more than 8 (https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth);
                // a lower depth stutters more
                conf.queueDepth = 8
            }
        }

        conf.capturesAudio = recording.systemAudio
        conf.sampleRate = 48000
        conf.channelCount = 2
        // The microphone is captured by ScreenCaptureKit as well. A nil device ID means the system default input.
        conf.captureMicrophone = recording.recordMic
        conf.microphoneCaptureDeviceID = microphoneDeviceID

        // Always an explicit interval: a timescale of 0 is not a valid time, and leaving the stream unthrottled
        // delivers frames at the display's rate whatever the setting says. An audio-only stream gets next to no frames.
        let fps = AppSettings.captureFrameRate
        conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : CMTimeScale(fps))
        print("Frame interval passed to ScreenCaptureKit: \(conf.minimumFrameInterval)")

        if target.type == .screenarea {
            if let nsRect = target.area, let display = target.areaDisplay {
                let newY = display.frame.height - nsRect.size.height - nsRect.origin.y
                conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
                conf.width = Int(conf.sourceRect.width) * (AppSettings.recordsPixels ? Int(filter.pointPixelScale) : 1)
                conf.height = Int(conf.sourceRect.height) * (AppSettings.recordsPixels ? Int(filter.pointPixelScale) : 1)
            }
        }
        return conf
    }

    // MARK: - The stream

    /// Every output is delivered on the same serial queue, so the writer is never used concurrently
    func addOutputs() throws {
        guard let stream = stream else { return }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if recordsMic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    func start() async throws {
        guard let stream = stream else { throw RecordingError("The screen capture is not available any more.".local) }
        try await stream.startCapture()
    }

    /// `done` is called, on any thread, when the stream has stopped delivering buffers. The stream is given up here.
    func stop(_ done: @escaping (Error?) -> Void) {
        guard let stream = stream else { return done(nil) }
        self.stream = nil
        stream.stopCapture { error in
            done(error)
            // The stream lives until it has stopped
            withExtendedLifetime(stream) {}
        }
    }

    /// Gives up a stream that was never started or has stopped by itself, so the stream and this object, which is
    /// its delegate and its output, do not keep each other
    func releaseStream() {
        stream = nil
    }

    /// Tells the stream about a change made to `configuration`, which is how the microphone device is switched
    func applyConfiguration(_ done: @escaping (Error?) -> Void) {
        guard let stream = stream else { return done(nil) }
        stream.updateConfiguration(configuration, completionHandler: done)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        var pts = sampleBuffer.presentationTimeStamp
        let kind: CaptureSample.Kind
        switch outputType {
        case .screen:
            var complete = false
            if let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
               let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int {
                complete = SCFrameStatus(rawValue: statusRawValue) == .complete
            }
            kind = .screen(complete: complete)
        case .audio:
            kind = .audio
        case .microphone:
            kind = .microphone
            // Microphone timestamps are expected on the stream's clock like the other outputs. Should they ever not be,
            // the arrival time is used, so the microphone still lands on the recording's timeline instead of being dropped.
            let now = (stream.synchronizationClock ?? CMClockGetHostTimeClock()).time
            if !pts.isValid || abs(CMTimeGetSeconds(CMTimeSubtract(now, pts))) > 5 {
                let duration = sampleBuffer.duration
                pts = duration.isValid ? CMTimeSubtract(now, duration) : now
            }
        @unknown default:
            // An output type this version does not know is not recorded
            return
        }
        onSample(CaptureSample(kind: kind, buffer: sampleBuffer, pts: pts))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        onStop(self, error)
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

extension CMSampleBuffer {
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
