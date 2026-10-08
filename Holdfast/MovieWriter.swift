//
//  MovieWriter.swift
//  Holdfast
//

import Accelerate
import AppKit
import AVFoundation
import CoreImage
import VideoToolbox

/// One buffer of the capture, as `CaptureSource` hands it over on the sample queue
struct CaptureSample {
    enum Kind {
        /// `complete` is false for a frame that carries no new picture (idle, blank, suspended)
        case screen(complete: Bool)
        /// System audio: the process tap's, or ScreenCaptureKit's when the tap is not used
        case audio
        /// ScreenCaptureKit's system audio while the tap is used: the backup, written to a track of its own
        case backupAudio
        /// What the call tap delivers while the process tap is used: `avconferenced`'s audio alone, written to a
        /// track of its own
        case callAudio
        case microphone
    }
    let kind: Kind
    let buffer: CMSampleBuffer
    /// When the buffer starts on the stream's clock
    let pts: CMTime
    /// When the buffer reached the app, on the host clock its timestamps are on; invalid when not known. A frame or
    /// a buffer of the stream stamped far from it goes where it puts them instead (`ArrivalCheck`), and a backlog is
    /// told from a clock that lags by it. A buffer of the process tap ends at it: the host time read in the tap's
    /// IOProc is the only time it has (`SystemAudioTap`).
    let arrival: CMTime

    init(kind: Kind, buffer: CMSampleBuffer, pts: CMTime, arrival: CMTime = .invalid) {
        self.kind = kind
        self.buffer = buffer
        self.pts = pts
        self.arrival = arrival
    }
}

/// Writes one recording: the `AVAssetWriter` with its tracks (or the audio files of an audio-only recording), the
/// writer's session, the timeline with its pauses, and the converter of the microphone track. One is created for
/// every recording and thrown away when it is finished or its start is discarded; nothing here outlives a recording.
///
/// Confined to the sample queue (`RecorderController.queue`) from the moment the capture is started. Before that,
/// `prepareVideo` / `prepareAudio` are called by the one thread that sets the recording up.
final class MovieWriter {
    /// What the writer tells its owner, on the sample queue
    struct Events {
        /// The recording cannot be written any more. Called once, with what to tell the user.
        var failed: (String) -> Void = { _ in }
        var sessionStarted: () -> Void = {}
        /// Microphone audio was written up to that time; the peak is that of the last buffer
        var microphoneWritten: (CMTime, Float) -> Void = { _, _ in }
        /// System audio that was delivered (not silence put in its place) was written up to that time
        var systemAudioWritten: (CMTime) -> Void = { _ in }
        /// The same for the backup of the system audio
        var backupAudioWritten: (CMTime) -> Void = { _ in }
        /// The same for the call tap's audio
        var callAudioWritten: (CMTime) -> Void = { _ in }
        /// The process tap runs and hears nothing while the other sources have sound, or hears again (`SilentTap`):
        /// what is to be done about it. Never `.none`.
        var tapSilent: (SilentTap.Action) -> Void = { _ in }
    }

    /// The titles of the audio tracks of a video recording, which players show and the mix tells the tracks by
    enum TrackTitle {
        static let system = "System audio"
        static let tap = "System audio (tap)"
        static let backup = "System audio (backup)"
        static let call = "Call audio (second tap)"
        static let microphone = "Microphone"
    }

    /// What is left for the stop path once the inputs are finished
    struct Finished {
        /// Nil when the session never started (no file is left), or for an audio-only recording without a microphone
        let writer: AVAssetWriter?
        /// Small picture of the first frame, for the preview
        let frame: NSImage?
        let sessionStarted: Bool
    }

    /// How much of a recording an unclosed .mp4, .mov or .m4a file can be missing at its end
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    /// How long no frame may arrive before the last one is written again
    static let videoStallSeconds: Double = 1
    /// A hole between two system audio buffers shorter than this is not filled
    static let gapTolerance: Double = 0.1
    /// The longest a buffer is believed to have waited between its arrival and the sample queue, in seconds
    static let longestHandOff: Double = 10

    let recording: RecordingContext
    /// Nil when the recording has no microphone track
    let micConverter: MicConverter?
    var events = Events()

    private var writer: AVAssetWriter?
    private var videoInput, micInput: AVAssetWriterInput?
    /// The system audio track (or file, for an audio-only recording), and its backup when the tap is used
    private var system: SystemTrack?
    private var backup: SystemTrack?
    /// The call tap's track (or file), there whenever the tap is used and silent while no call plays
    private var call: SystemTrack?
    /// Where the tap delivered, written next to the recording while it runs; nil without the backup
    private var tapSpans: TapSpanLog?
    /// The same for the call tap
    private var callSpans: TapSpanLog?
    /// Whether the process tap hears what the other sources hear; nil without the backup
    private var silentTap: SilentTap?
    /// What this writer created at `recording.rawURL` (the file or the package), which `cancel` removes; nil until
    /// then. The backup file of an audio-only recording without a package, and the tap's spans, are removed with it.
    private var created: URL?
    private var createdAlongside = [URL]()
    /// True from just before the capture is started until the recording is stopped or has failed
    private(set) var isCapturing = false
    private(set) var isPaused = false
    /// Set when a pause ends, until the first time after it has been put on the timeline
    private(set) var isResume = false
    /// While set, what the microphone delivers is left out of its track, which goes on as silence
    private(set) var isMicrophoneMuted = false
    /// Latest end time of anything on the timeline, including what was written in place of a silent source
    private(set) var lastPTS: CMTime?
    /// Total paused time, subtracted from every buffer's timestamps
    private(set) var timeOffset = CMTime.zero
    /// Where the writer's session starts on the timeline, nil until the first frame (or audio buffer, when only audio is recorded)
    private(set) var sessionStart: CMTime?
    /// When the buffer that was taken last arrived on the buffers' clock (its end time, when its arrival is not
    /// known), and the uptime of that moment (`anchor(for:endingAt:)`). `RecordingMonitor` tells the present on the
    /// buffers' clock from it while nothing arrives.
    private(set) var clockAnchor: (raw: CMTime, uptime: UInt64)?
    /// End of the system audio appended so far, silence included
    var audioEndPTS: CMTime? { system?.end }
    /// End of the backup of the system audio appended so far, silence included
    var backupEndPTS: CMTime? { backup?.end }
    /// End of the call tap's audio appended so far, silence included
    var callEndPTS: CMTime? { call?.end }
    /// Time of the last video frame appended, and that frame, which is written again while no new one arrives
    private(set) var videoPTS: CMTime?
    private var lastVideoFrame: CMSampleBuffer?
    /// Whether `lastVideoFrame` owns its pixels instead of holding a surface of the stream
    private var lastVideoFrameIsCopy = false
    /// End of the last video frame appended, a repeated one included (its time, when it has no duration). The tracks
    /// are brought to it at the stop.
    private(set) var videoEnd: CMTime?
    /// The present on the host clock the buffers' timestamps are on. Nothing on the timeline ends more than
    /// `ArrivalCheck.ahead` after it. The tests and the simulation give a clock of their own; one that returns an
    /// invalid time turns the checks against the present off.
    var presentClock: () -> CMTime = { CMClockGetHostTimeClock().time }
    /// Microphone buffers given their arrival time because their own could not be believed, for the log (system
    /// audio counts its own in its `SystemTrack`), and the frames written at theirs
    private var microphoneRestamps = Restamps(name: "Microphone", behind: ArrivalCheck.microphoneBehind)
    private var frameRestamps = Restamps(name: "Video", behind: ArrivalCheck.behind, unit: "frame", logsEnd: false)
    /// Buffers left out because they end beyond the present, and ends the timeline did not take for that reason
    private var futureBuffers = 0
    private var futureEnds = 0
    /// Small picture of the recording's first frame for the preview. An image, not the frame: a frame as delivered
    /// holds one of the stream's surfaces, and a full-size copy would sit in memory for the whole recording.
    private var firstFrame: NSImage?
    /// How far after the frame before it a frame is written when its own time is not later: half a frame at the
    /// capture's rate, a hundredth of a second at most, so that frames moved one after another never run ahead of
    /// the frames that keep arriving
    private var frameStep = CMTime(value: 1, timescale: 100)

    var hasSystemAudio: Bool { system != nil }
    var hasBackupAudio: Bool { backup != nil }
    var hasCallAudio: Bool { call != nil }
    var hasMicrophoneTrack: Bool { micInput != nil }

    init(recording: RecordingContext, micConverter: MicConverter?) {
        self.recording = recording
        self.micConverter = micConverter
    }

    // MARK: - Files and tracks

    /// Creates the video file and its tracks. When it throws, the caller discards what was created (`cancel`).
    func prepareVideo(width: Int, height: Int) throws {
        // AVAssetWriterInput raises an exception, which ends the app, for a picture without width or height
        guard width >= 1, height >= 1 else {
            throw RecordingError(String(format: "The picture to record is %d x %d pixels: select a larger area.", width, height))
        }
        try checkNameIsFree()
        let writer = try AVAssetWriter(outputURL: recording.rawURL, fileType: recording.fileType)
        self.writer = writer
        // The file is written in fragments, so a crash, a kill or a power loss costs the last few seconds instead of
        // the recording: without them a .mp4 or .mov cannot be opened at all unless it was closed properly.
        // Closing the file normally turns it into an ordinary movie file.
        writer.movieFragmentInterval = MovieWriter.fragmentInterval
        let encoderIsH265 = AppSettings.usesHEVC
        let fps = AppSettings.captureFrameRate
        frameStep = CMTime(value: 1, timescale: CMTimeScale(max(100, 2 * fps)))
        let fpsMultiplier: Double = Double(fps)/8
        let encoderMultiplier: Double = encoderIsH265 ? 0.5 : 0.9
        let resolution = Double(max(600, width)) * Double(max(600, height))
        var qualityMultiplier = 1 - (log10(sqrt(resolution) * fpsMultiplier) / 5)
        switch AppSettings.videoQuality {
            case 0.3: qualityMultiplier = max(0.1, qualityMultiplier)
            case 0.7: qualityMultiplier = max(0.4, min(0.6, qualityMultiplier * 3))
            default: qualityMultiplier = 1.0
        }
        let h264Level = AVVideoProfileLevelH264HighAutoLevel
        let h265Level = AppSettings.recordHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel

        let targetBitrate = resolution * fpsMultiplier * encoderMultiplier * qualityMultiplier * (AppSettings.recordHDR ? 2 : 1)
        let bitrate = max(200000, Int(targetBitrate))
        RecLog.write("Video: \(width) x \(height), \(fps) fps, \(encoderIsH265 ? "H.265" : "H.264"), \(bitrate / 1000) kbit/s")

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: encoderIsH265 ? ((AppSettings.withAlpha && !AppSettings.recordHDR) ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc) : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: encoderIsH265 ? h265Level : h264Level,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String : Any]
        ]

        if !AppSettings.recordHDR {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] as [String : Any]
        }

        let audioSettings = recording.audioSettings
        let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError("The video settings are not supported by this file format.") }
        writer.add(videoInput)

        // Only tracks that are fed: the writer puts a fragment on disk once every track has data for it, so a single
        // track that never gets any would leave the whole file unreadable until it is closed. In this order, which
        // the mix also goes by when a file has no titles: system audio, its backup, the call tap's audio, the
        // microphone. The call tap's track is there from the start, since a track cannot be added when a call
        // begins, and is kept going with silence like the others while no call plays.
        func audioInput(_ title: String, failure: String) throws -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            input.metadata = [MovieWriter.titleItem(title)]
            guard writer.canAdd(input) else { throw RecordingError(failure) }
            writer.add(input)
            return input
        }
        var system: SystemTrack?
        var backup: SystemTrack?
        var call: SystemTrack?
        if recording.systemAudio {
            let title = recording.systemAudioBackup ? TrackTitle.tap : TrackTitle.system
            system = SystemTrack(name: "System audio", fromTap: recording.systemAudioBackup,
                                 input: try audioInput(title, failure: "The audio settings are not supported by this file format."))
            if recording.systemAudioBackup {
                backup = SystemTrack(name: "System audio backup", input: try audioInput(TrackTitle.backup, failure: "The audio settings are not supported by this file format."))
                call = SystemTrack(name: "Call audio", fromTap: true, input: try audioInput(TrackTitle.call, failure: "The audio settings are not supported by this file format."))
            }
        }
        var micInput: AVAssetWriterInput?
        if recording.recordMic {
            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            micInput = try audioInput(TrackTitle.microphone, failure: "The microphone track cannot be written in this file format.")
        }
        guard writer.startWriting() else { throw writer.error ?? RecordingError("The video file could not be created.") }
        created = recording.rawURL
        self.videoInput = videoInput
        self.system = system
        self.backup = backup
        self.call = call
        self.micInput = micInput
        try startTapSpans()
    }

    /// A title for a track, which QuickTime Player and the mix read
    static func titleItem(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// Begins the file of the tap's spans when the recording has the backup: empty until the tap delivers, so an
    /// empty file says that it never did
    private func startTapSpans() throws {
        guard recording.systemAudioBackup else { return }
        silentTap = SilentTap()
        func log(_ url: URL?) throws -> TapSpanLog? {
            guard let url else { return nil }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw RecordingError(String(format: "A file named \"%@\" is already in the save folder.", url.lastPathComponent))
            }
            let made = try TapSpanLog(url: url)
            createdAlongside.append(url)
            return made
        }
        tapSpans = try log(recording.tapSpansURL)
        // The same record for the call tap, when its audio has a track or a file
        if call != nil { callSpans = try log(recording.callSpansURL) }
    }

    /// Creates the files of an audio-only recording. When it throws, the caller discards what was created (`cancel`).
    func prepareAudio() throws {
        guard let systemAudioURL = recording.systemAudioURL else { throw RecordingError("The audio file has no location.") }
        let settings = recording.audioSettings
        try checkNameIsFree()
        // From here on what is at the recording's name is this writer's: the package, or the file AVAudioFile creates
        created = recording.rawURL
        if let micAudioURL = recording.micAudioURL {
            try FileManager.default.createDirectory(at: recording.rawURL, withIntermediateDirectories: true, attributes: nil)
            try QmaInfo(format: recording.audioFormat.packageFileEnding, encoder: recording.audioEncoder, exportMP3: recording.audioFormat == .mp3).write(package: recording.rawURL)

            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            let fileType = recording.audioFormat.packageFileType
            let writer = try AVAssetWriter(outputURL: micAudioURL, fileType: fileType)
            self.writer = writer
            // .caf, used for FLAC and Opus, has no movie fragments
            if fileType == .m4a { writer.movieFragmentInterval = MovieWriter.fragmentInterval }
            let micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: settings)
            micInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(micInput) else { throw RecordingError("The microphone track cannot be written in this audio format.") }
            writer.add(micInput)
            guard writer.startWriting() else { throw writer.error ?? RecordingError("The microphone file could not be created.") }
            self.micInput = micInput
        }
        system = SystemTrack(name: "System audio", fromTap: recording.systemAudioBackup,
                             file: try AVAudioFile(forWriting: systemAudioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false))
        if let backupURL = recording.backupAudioURL {
            // In the package, or next to the file under a name of its own; never over another file
            guard !FileManager.default.fileExists(atPath: backupURL.path) else {
                throw RecordingError(String(format: "A file named \"%@\" is already in the save folder.", backupURL.lastPathComponent))
            }
            if recording.micAudioURL == nil { createdAlongside.append(backupURL) }
            backup = SystemTrack(name: "System audio backup", file: try AVAudioFile(forWriting: backupURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false))
        }
        if let callURL = recording.callAudioURL {
            guard !FileManager.default.fileExists(atPath: callURL.path) else {
                throw RecordingError(String(format: "A file named \"%@\" is already in the save folder.", callURL.lastPathComponent))
            }
            if recording.micAudioURL == nil { createdAlongside.append(callURL) }
            call = SystemTrack(name: "Call audio", fromTap: true, file: try AVAudioFile(forWriting: callURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false))
        }
        try startTapSpans()
    }

    /// The encoder settings of an audio track. `videoFormat` is the container of a video recording, nil for an audio
    /// file. The defaults are the current settings; code that works on a recording passes that recording's values
    /// instead (`RecordingContext.audioSettings`).
    static func audioSettings(format: String = AppSettings.audioFormat.rawValue,
                              quality: Int = AppSettings.audioQuality.rawValue,
                              videoFormat: String?) -> [String : Any] {
        var audioSettings: [String : Any] = [AVSampleRateKey : 48000, AVNumberOfChannelsKey : 2]
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
            // An .mp4 cannot hold Opus, so a video in one gets AAC; a .mov and the .caf of an audio file can
            audioSettings[AVFormatIDKey] = videoFormat == VideoFormat.mp4.rawValue ? kAudioFormatMPEG4AAC : kAudioFormatOpus
            audioSettings[AVEncoderBitRateKey] =  bitRate
        default:
            // An unknown format must not cost the recording: AAC goes into every container used here
            print("Unknown audio format \"\(format)\", using AAC")
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        }
        return audioSettings
    }

    // MARK: - Start, pause, failure

    /// From here on buffers are taken. Called just before the capture is started.
    func startCapturing() {
        isCapturing = true
    }

    /// Pauses or resumes and returns whether the recording is paused now
    func togglePause() -> Bool {
        isPaused.toggle()
        if !isPaused { isResume = true }
        // Nothing arrives to replace the last frame while paused, however long that is
        if isPaused { detachLastVideoFrame() }
        // The timeline is put together anew at the first buffer after the pause
        micConverter?.realign()
        system?.stamps.interrupted()
        backup?.stamps.interrupted()
        silentTap?.tapInterrupted()
        return isPaused
    }

    /// Mutes the microphone track or gives it its audio back. While muted the microphone's buffers are not
    /// written: the track is continued like that of a microphone that delivers nothing, with the silence the
    /// monitor asks for (`fillMicrophone`), and the first buffer after the mute is placed at its own time, behind
    /// silence up to it (`MicConverter.convert`). The timeline never has a hole.
    func setMicrophoneMuted(_ muted: Bool) {
        guard muted != isMicrophoneMuted, micConverter != nil else { return }
        isMicrophoneMuted = muted
        // To the sample, not within the tolerance of a jitter: a short mute must not move what follows it
        micConverter?.realign()
        RecLog.write(muted ? "Microphone muted by the user" : "Microphone unmuted by the user")
    }

    /// The one way a recording ends when it cannot go on: nothing more is appended, and the owner is told why,
    /// once. It stops the recording, which closes the file as far as possible.
    func fail(_ reason: String) {
        guard isCapturing else { return }
        isCapturing = false
        events.failed(reason)
    }

    static func writeFailure(_ error: Error?) -> String {
        return String(format: "The recording could not be written: %@", error?.localizedDescription ?? "Unknown error")
    }

    /// False, after the failure has been reported, when the writer gave up between two appends, for example
    /// because the disk is full or gone
    func checkWriter() -> Bool {
        guard let writer = writer, writer.status == .failed else { return true }
        fail(MovieWriter.writeFailure(writer.error))
        return false
    }

    /// For a start that failed before anything was recorded. Also deletes what the writer created, and nothing else.
    func cancel() {
        isCapturing = false
        system?.file = nil
        backup?.file = nil
        call?.file = nil
        tapSpans?.close()
        tapSpans = nil
        callSpans?.close()
        callSpans = nil
        writer?.cancelWriting()
        if let created = created { try? FileManager.default.removeItem(at: created) }
        for url in createdAlongside { try? FileManager.default.removeItem(at: url) }
        created = nil
        createdAlongside = []
    }

    /// The writer never writes over a file: AVAudioFile would truncate it, and a failed start would remove it.
    /// `RecordingFileStore.newBase` chooses a name no file has, so this only catches one that appeared since.
    private func checkNameIsFree() throws {
        guard !FileManager.default.fileExists(atPath: recording.rawURL.path) else {
            throw RecordingError(String(format: "A file named \"%@\" is already in the save folder.", recording.rawURL.lastPathComponent))
        }
    }

    // MARK: - Timeline

    /// Turns a time on the buffers' clock into a time on the writer's timeline, which leaves out the pauses. The
    /// first time after a pause continues where the recording left off: the paused time is taken out of every
    /// track alike, which keeps video, system audio and microphone in sync.
    func timelineTime(_ raw: CMTime) -> CMTime {
        if isResume {
            isResume = false
            if let last = lastPTS {
                timeOffset = Timeline.pauseOffset(resumingAt: raw, last: last, current: timeOffset)
                print("time removed for pauses: \(CMTimeGetSeconds(timeOffset))")
            }
        }
        return CMTimeSubtract(raw, timeOffset)
    }

    /// Keeps `lastPTS` at the latest end time of anything on the timeline, which is never more than
    /// `ArrivalCheck.ahead` after the present: the stop brought the microphone track to that time once, and an end
    /// in the future made a 20-minute call's microphone 38 minutes long
    private func noteEnd(_ end: CMTime?) {
        let latest = Timeline.latestEnd(end, after: lastPTS, limit: timelineLimit())
        if latest == lastPTS, let end = end, end.isValid, lastPTS.map({ end > $0 }) ?? true {
            futureEnds += 1
            if futureEnds == 1 {
                RecLog.write(String(format: "An end %.2f s after the present was left out of the recording's length", CMTimeGetSeconds(CMTimeSubtract(end, presentOnTimeline() ?? end))))
            }
        }
        lastPTS = latest
    }

    /// The present on the writer's timeline, nil when the clock gives none. While a resume has not been put on the
    /// timeline yet the pause is not taken out, so it is later than the true one, never earlier.
    private func presentOnTimeline() -> CMTime? {
        let present = presentClock()
        guard present.isValid else { return nil }
        return CMTimeSubtract(present, timeOffset)
    }

    /// The latest time anything on the timeline may end: the present plus `ArrivalCheck.ahead`
    private func timelineLimit() -> CMTime? {
        return presentOnTimeline().map { CMTimeAdd($0, CMTime(seconds: ArrivalCheck.ahead, preferredTimescale: 1_000_000_000)) }
    }

    /// `time`, or the latest time anything may end when it is later: what the monitor asks to fill comes from the
    /// buffers' times, and silence or a frame in the future would stay in the file
    private func notAfterLimit(_ time: CMTime) -> CMTime {
        guard let limit = timelineLimit(), time > limit else { return time }
        return limit
    }

    /// Microphone buffers, or frames, given their arrival time instead of their own (`ArrivalCheck`). The first of a
    /// run is logged, and for the microphone the end of the run, for the first runs; the total at the stop.
    private struct Restamps {
        static let loggedRuns = 10
        let name: String
        /// Seconds a buffer may be stamped before its arrival (`ArrivalCheck`)
        let behind: Double
        /// What is counted: "buffer", "frame"
        var unit = "buffer"
        /// Whether the end of a run is logged as well as its beginning
        var logsEnd = true
        var run = 0
        var runs = 0
        var total = 0

        /// The start of a buffer that starts at `pts`, lasts `duration` and arrived at `arrival`
        mutating func start(_ pts: CMTime, duration: CMTime, arrival: CMTime) -> CMTime {
            let how: String
            switch ArrivalCheck.verdict(pts: pts, arrival: arrival, behind: behind) {
            case .trusted:
                if run > 0, runs <= Restamps.loggedRuns, logsEnd {
                    RecLog.write("\(name): timestamps can be believed again, after \(Restamps.recorded(run, unit)) at \(run == 1 ? "its" : "their") arrival time")
                }
                run = 0
                return pts
            case .ahead(let seconds): how = String(format: "%.2f s after", seconds)
            case .behind(let seconds): how = String(format: "%.2f s before", seconds)
            }
            if run == 0 {
                runs += 1
                if runs <= Restamps.loggedRuns {
                    RecLog.write("\(name): a \(unit) is stamped \(how) it arrived, which cannot be its time; it is recorded at its arrival time, as is every \(unit) after it until their timestamps can be believed again")
                }
            }
            run += 1
            total += 1
            return ArrivalCheck.restamped(arrival: arrival, duration: duration)
        }

        var summary: String? { Restamps.summary(name, total: total, runs: runs, unit) }

        static func summary(_ name: String, total: Int, runs: Int, _ unit: String = "buffer") -> String? {
            guard total > 0 else { return nil }
            return "\(name): \(recorded(total, unit)) at \(total == 1 ? "its" : "their") arrival time in \(runs) \(runs == 1 ? "run" : "runs"), \(total == 1 ? "its" : "their") own timestamp being off"
        }

        /// "1 buffer recorded", "3 frames recorded"
        static func recorded(_ count: Int, _ unit: String = "buffer") -> String { "\(count) \(unit)\(count == 1 ? "" : "s") recorded" }
    }

    /// Where a buffer of the stream's system audio starts on the buffers' clock (`StreamStamps`), nil when it is
    /// left out: it lies before the end of what its track holds, where silence was written while it was held up.
    /// Such a buffer does not reach the timeline at all, so its old time does not become the monitor's present.
    private func streamStart(of sample: CaptureSample, duration: CMTime, in track: SystemTrack) -> CMTime? {
        // While a resume has not been put on the timeline yet, the first buffer says where the recording goes on
        var end: CMTime?
        if let sessionStart, !isResume { end = CMTimeAdd(track.end ?? sessionStart, timeOffset) }
        let placed = track.stamps.start(sample.pts, duration: duration, arrival: sample.arrival, end: end)
        for event in placed.events { log(event, of: track) }
        return placed.start
    }

    private func log(_ event: StreamStamps.Event, of track: SystemTrack) {
        guard track.stamps.runs <= Restamps.loggedRuns else { return }
        let name = track.name
        switch event {
        case .ahead(let seconds):
            RecLog.write(String(format: "%@: a buffer is stamped %.2f s after it arrived, which cannot be its time; it is recorded at its arrival time, as is every buffer after it until their timestamps can be believed again", name, seconds))
        case .lagging(let behind, let dropped):
            RecLog.write(String(format: "%@: buffers stamped %.2f s before their place keep arriving at real-time pace: the stream's clock lags. They are recorded at their arrival time from here on (%.2f s of audio left out until that was clear)", name, behind, dropped))
        case .agreesAgain(let buffers):
            RecLog.write("\(name): timestamps can be believed again, after \(Restamps.recorded(buffers)) at \(buffers == 1 ? "its" : "their") arrival time")
        case .backlog(let buffers, let seconds, let firstAge, let lastAge):
            track.backlogs += 1
            guard track.backlogs <= Restamps.loggedRuns else { return }
            var ages = ""
            if let firstAge, let lastAge { ages = String(format: ", arriving %.2f s to %.2f s after their time", firstAge, lastAge) }
            RecLog.write(String(format: "%@ backlog: %d buffers (%.2f s of audio) came in late%@, and were left out, as silence had been written in their place; the stream goes on at its own time", name, buffers, seconds, ages))
        }
    }

    /// Where a buffer of the process tap starts on the buffers' clock: where its IOProc's host time put it. Should
    /// that ever be more than `ArrivalCheck.ahead` after the present it ends at the present instead; it is never
    /// left out for its time.
    private func tapStart(_ pts: CMTime, duration: CMTime) -> CMTime {
        let present = presentClock()
        guard present.isValid, duration.isValid, duration > .zero else { return pts }
        guard CMTimeGetSeconds(CMTimeSubtract(CMTimeAdd(pts, duration), present)) > ArrivalCheck.ahead else { return pts }
        return CMTimeSubtract(present, duration)
    }

    /// What the monitor tells the present from once `sample`, which ends at `rawEnd`, has been taken: a time on the
    /// buffers' clock and the uptime at which it was the present. With a known arrival that is the arrival, at the
    /// uptime the buffer arrived (now, less the time it waited for the sample queue): the host clock itself, which
    /// no timestamp of a device can move, neither ahead nor, with a buffer handed over late with the time its audio
    /// was captured at, back. Without one it is the buffer's end, now.
    private func anchor(for sample: CaptureSample, endingAt rawEnd: CMTime) -> (raw: CMTime, uptime: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let present = presentClock()
        guard sample.arrival.isValid, present.isValid else { return (rawEnd, now) }
        let waited = CMTimeGetSeconds(CMTimeSubtract(present, sample.arrival))
        guard waited.isFinite, waited >= 0, waited <= MovieWriter.longestHandOff else { return (rawEnd, now) }
        let nanoseconds = UInt64(waited * 1_000_000_000)
        return (sample.arrival, now > nanoseconds ? now - nanoseconds : now)
    }

    /// False for a buffer that ends more than `ArrivalCheck.ahead` after the present, which is left out: it would
    /// make the recording that long. Logged the first time; the stop logs how many. Only what has no arrival to go
    /// by and no picture is judged so: a frame without a new picture, or a buffer of the stream or the microphone
    /// whose arrival is not known. A complete frame and a buffer of the tap are placed, never left out.
    private func endsByPresent(_ rawEnd: CMTime, kind: String) -> Bool {
        let present = presentClock()
        guard present.isValid else { return true }
        let beyond = CMTimeGetSeconds(CMTimeSubtract(rawEnd, present))
        guard beyond > ArrivalCheck.ahead else { return true }
        futureBuffers += 1
        if futureBuffers == 1 {
            RecLog.write(String(format: "A %@ buffer ending %.2f s after the present was left out", kind, beyond))
        }
        return false
    }

    /// Starts the writer's session at `pts`: at the first complete video frame, or at the first system audio
    /// buffer of an audio-only recording. `sessionStart` is only set here, together with the session, and every
    /// path that appends to a track checks it first, so nothing reaches the writer before its session has
    /// started. False when the writer cannot take a session.
    private func beginSession(at pts: CMTime) -> Bool {
        if let writer = writer {
            guard writer.status == .writing else { return false }
            writer.startSession(atSourceTime: pts)
        }
        sessionStart = pts
        micConverter?.start(at: pts)
        events.sessionStarted()
        return true
    }

    /// Returns whether the buffer was written. An input that is not ready drops the buffer; an append that fails
    /// means the file can no longer be written, which ends the recording.
    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        guard input.isReadyForMoreMediaData else { return false }
        if input.append(buffer) { return true }
        fail(MovieWriter.writeFailure(writer?.error))
        return false
    }

    // MARK: - Buffers of the capture

    /// Puts one buffer of the capture on the timeline and into its track. Nothing is written before the session
    /// has started, which the first complete frame does (the first system audio of an audio-only recording).
    func write(_ sample: CaptureSample) {
        let sampleBuffer = sample.buffer
        guard isCapturing, !isPaused, sampleBuffer.isValid else { return }
        var rawPTS = sample.pts
        let duration = sampleBuffer.duration
        guard rawPTS.isValid else { return }
        guard checkWriter() else { return }
        var isMicrophone = false
        var audioTrack: SystemTrack?
        // Whether a time beyond the present leaves the buffer out
        var checksPresent = true
        let kind: String
        switch sample.kind {
        case .screen(let complete):
            kind = "video"
            if complete {
                // A complete frame is never left out for its timestamp: stamped more than a second from its
                // arrival, it is written at that time instead. One whose arrival is not known can only be told to
                // be ahead, of the present, and is then written at the present.
                var arrival = sample.arrival
                if !arrival.isValid {
                    let present = presentClock()
                    if present.isValid, rawPTS > present { arrival = present }
                }
                rawPTS = frameRestamps.start(rawPTS, duration: .invalid, arrival: arrival)
                checksPresent = false
            }
        case .audio, .backupAudio, .callAudio:
            let found: SystemTrack?
            switch sample.kind {
            case .backupAudio: (found, kind) = (backup, "system audio backup")
            case .callAudio: (found, kind) = (call, "call audio")
            default: (found, kind) = (system, "system audio")
            }
            guard let track = found else { return }
            audioTrack = track
            if track.fromTap {
                // The buffer ends when it arrived. Its own time is that too, unless it was converted from another
                // format: those buffers are on a timeline counted from their samples (`SystemAudioConverter`), which
                // would hide from `TapDrift` how far the tap's device has drifted until it is a tenth of a second.
                if sample.arrival.isValid, duration.isValid, duration > .zero { rawPTS = CMTimeSubtract(sample.arrival, duration) }
                rawPTS = tapStart(rawPTS, duration: duration)
                checksPresent = false
            } else {
                guard let start = streamStart(of: sample, duration: duration, in: track) else { return }
                rawPTS = start
            }
        case .microphone:
            kind = "microphone"
            isMicrophone = true
            rawPTS = microphoneRestamps.start(rawPTS, duration: duration, arrival: sample.arrival)
        }
        let rawEnd = duration.isValid && duration.value > 0 ? CMTimeAdd(rawPTS, duration) : rawPTS
        if checksPresent { guard endsByPresent(rawEnd, kind: kind) else { return } }
        if !isMicrophone || clockAnchor == nil {
            clockAnchor = anchor(for: sample, endingAt: rawEnd)
        }
        // Times on the writer's timeline
        let pts = timelineTime(rawPTS)
        let endPTS = CMTimeSubtract(rawEnd, timeOffset)
        noteEnd(endPTS)
        switch sample.kind {
        case .screen(let complete):
            if recording.audioOnly || !complete { return }
            writeFrame(sampleBuffer, at: pts)
        case .audio, .backupAudio, .callAudio:
            guard let track = audioTrack else { return }
            if recording.audioOnly {
                writeAudioToFile(sampleBuffer, track: track, from: pts, to: endPTS)
            } else {
                writeAudioToTrack(sampleBuffer, track: track, from: pts, to: endPTS)
            }
        case .microphone:
            guard sessionStart != nil, !isMicrophoneMuted, let micInput = micInput, let converter = micConverter else { return }
            // On the timeline like the buffer's time, so its age is unchanged by pauses
            let arrival = sample.arrival.isValid ? CMTimeSubtract(sample.arrival, timeOffset) : CMTime.invalid
            let written = converter.convert(sampleBuffer, at: pts, arrival: arrival) { buffer in
                append(buffer, to: micInput)
            }
            if written { events.microphoneWritten(converter.end, converter.lastPeak) }
        }
    }

    /// Writes a complete frame at `pts`. The first one starts the session; until then nothing is appended to any
    /// track. No frame is left out for its time: the writer fails on a frame that is not later than the one before
    /// it (and only says so at the end), so such a frame goes right after it, `frameStep` later. It may be the only
    /// frame of a new picture, a slide change for example. Only a writer that is not ready, or a frame that cannot
    /// be copied, loses one.
    private func writeFrame(_ sampleBuffer: CMSampleBuffer, at pts: CMTime) {
        if sessionStart == nil { guard beginSession(at: pts) else { return } }
        guard let videoInput = videoInput else { return }
        var framePTS = pts
        if let last = videoPTS, pts <= last { framePTS = CMTimeAdd(last, frameStep) }
        guard videoInput.isReadyForMoreMediaData, let frame = MovieWriter.retimed(sampleBuffer, to: framePTS) else { return }
        // The preview picture is made from the first frame right away, so the frame itself is not kept
        if videoPTS == nil { firstFrame = MovieWriter.thumbnail(of: frame) }
        if append(frame, to: videoInput) {
            videoPTS = framePTS
            let duration = frame.duration
            noteVideoEnd(duration.isValid && duration > .zero ? CMTimeAdd(framePTS, duration) : framePTS)
            noteEnd(framePTS)
            lastVideoFrame = frame
            lastVideoFrameIsCopy = false
        }
    }

    /// System audio of an audio-only recording, which goes straight into its file. The first buffer of either
    /// system audio file starts the session (and that of the microphone file, if there is one): a tap that delivers
    /// nothing from the start must not keep the backup from being recorded.
    private func writeAudioToFile(_ sampleBuffer: CMSampleBuffer, track: SystemTrack, from pts: CMTime, to endPTS: CMTime) {
        if sessionStart == nil { guard beginSession(at: pts) else { return } }
        guard let samples = sampleBuffer.asPCMBuffer, let sessionStart else { return }
        // The file has no timestamps: audio that did not arrive is written as silence, or everything after it
        // would be early, and audio that arrives after silence was written in its place is left out, or
        // everything after it would be late. Its first sample is the session's start, also for the file whose
        // source began later.
        guard let placed = placeSystemAudio(track, from: pts, to: endPTS, end: track.end ?? sessionStart) else { return }
        var audio = samples
        var length = CMTimeSubtract(endPTS, pts)
        if placed.frames != 0, let stretched = stretch(sampleBuffer, by: placed.frames, in: track), let pcm = stretched.asPCMBuffer {
            audio = pcm
            length = stretched.duration
        }
        do {
            try track.file?.write(from: audio)
            delivered(track, from: placed.start, to: CMTimeAdd(placed.start, length), peak: silentTap == nil ? 0 : MovieWriter.peak(of: sampleBuffer))
        } catch {
            fail(MovieWriter.writeFailure(error))
        }
    }

    private func writeAudioToTrack(_ sampleBuffer: CMSampleBuffer, track: SystemTrack, from pts: CMTime, to endPTS: CMTime) {
        guard sessionStart != nil, let input = track.input else { return }
        track.format = sampleBuffer.formatDescription
        // The writer plays audio buffers back to back whatever their timestamps say. The buffer goes at the end
        // of what was written, and only once that end is where the buffer belongs.
        guard let placed = placeSystemAudio(track, from: pts, to: endPTS, end: track.end) else { return }
        let start = placed.start
        var audio = sampleBuffer
        var length = CMTimeSubtract(endPTS, pts)
        if placed.frames != 0, let stretched = stretch(sampleBuffer, by: placed.frames, in: track) {
            audio = stretched
            length = stretched.duration
        }
        // From the buffer's own timestamp, which is not `pts` when it was given its arrival time
        guard let buffer = MovieWriter.retime(audio, by: CMTimeSubtract(audio.presentationTimeStamp, start)) else { return }
        if append(buffer, to: input) {
            delivered(track, from: start, to: CMTimeAdd(start, length), peak: silentTap == nil ? 0 : MovieWriter.peak(of: sampleBuffer))
        }
    }

    /// A buffer of the tap one frame longer or shorter, as its track's `TapDrift` asked for, and noted there; nil
    /// when that cannot be made of it, and the buffer then goes in as it is
    private func stretch(_ sampleBuffer: CMSampleBuffer, by frames: Int, in track: SystemTrack) -> CMSampleBuffer? {
        guard let stretched = MovieWriter.stretched(sampleBuffer, by: frames) else { return nil }
        let rate = sampleBuffer.formatDescription?.audioStreamBasicDescription?.mSampleRate ?? 48000
        track.drift.applied(frames, frame: 1 / max(1, rate))
        return stretched
    }

    /// Audio of a source went into `track` from `start` to `end`: its end moves on, the monitor hears of it, and
    /// for a tap's track its spans grow. `peak` is the buffer's largest sample, which with the tap in use tells
    /// whether the tap hears what the other sources hear (`SilentTap`).
    private func delivered(_ track: SystemTrack, from start: CMTime, to end: CMTime, peak: Float) {
        track.end = end
        let from = sessionStart.map { CMTimeGetSeconds(CMTimeSubtract(start, $0)) }
        let to = sessionStart.map { CMTimeGetSeconds(CMTimeSubtract(end, $0)) }
        if track === backup {
            events.backupAudioWritten(end)
        } else if track === call {
            events.callAudioWritten(end)
            if let callSpans, let from, let to { callSpans.delivered(from: from, to: to) }
        } else {
            events.systemAudioWritten(end)
            if let tapSpans, let from, let to { tapSpans.delivered(from: from, to: to) }
        }
        guard var watch = silentTap, let from, let to else { return }
        let action = track === system ? watch.tap(from: from, to: to, peak: peak) : watch.other(from: from, to: to, peak: peak)
        silentTap = watch
        guard action != .none else { return }
        switch action {
        case .rebuild(let attempt):
            RecLog.write(String(format: "System audio: the process tap has delivered only zeros for %d s while the backup or the call tap has sound: it does not hear the Mac and is rebuilt (rebuild %d since it last heard anything)", Int(SilentTap.zeroSeconds), attempt))
        case .notice:
            RecLog.write("System audio: the process tap still delivers only zeros after \(SilentTap.quickRebuilds) rebuilds; from here on it is rebuilt once every \(Int(SilentTap.backoff)) s, and the backup and the call tap record meanwhile")
        case .hears:
            RecLog.write("System audio: the process tap hears the Mac again")
        case .none:
            break
        }
        events.tapSilent(action)
    }

    /// The largest sample of a buffer of 32-bit float audio, the format all system audio reaches the writer in; 0
    /// for exact zeros, and 1 for anything that cannot be read, which then never counts as silence
    static func peak(of sample: CMSampleBuffer) -> Float {
        guard let asbd = sample.formatDescription?.audioStreamBasicDescription, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return 1 }
        let found = try? sample.withAudioBufferList { list, _ -> Float in
            var loudest: Float = 0
            for part in list {
                guard let data = part.mData else { continue }
                var value: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &value, vDSP_Length(Int(part.mDataByteSize) / MemoryLayout<Float>.size))
                loudest = max(loudest, value)
            }
            return loudest
        }
        return found ?? 1
    }

    /// Where a system audio buffer that covers `pts` to `endPTS` goes in `track`: at the end of what was written
    /// to it so far (`end`). That end is counted from what was written, not read from the timestamps, so a buffer
    /// the writer did not take leaves a hole that is still there for the next buffer to see. Holes add up and are
    /// filled with silence once they exceed `gapTolerance`. Nil when the buffer must not be written: the silence
    /// for a hole in front of it could not be written yet, or the track already holds its time.
    ///
    /// The tap's buffers go back to back by their sample count, and the time their IOProc gave them only shows a
    /// real hole or a time that is taken (`SystemAudioPlacement.placeArrived`, which says why no device clock can
    /// leave one out). `frames` is then what the buffer is to be made longer or shorter by, a frame at most, to
    /// keep the track on the host clock while the tap's device drifts against it (`TapDrift`). The stream's buffers,
    /// on their own smooth timestamps, are left out when they lie before the end and written whole when they overlap
    /// it, late by less than one buffer (`SystemAudioPlacement.place`); `streamStart` has already kept back the ones
    /// of a backlog. Both tracks share one timeline.
    private func placeSystemAudio(_ track: SystemTrack, from pts: CMTime, to endPTS: CMTime, end: CMTime?) -> (start: CMTime, frames: Int)? {
        var filled = false
        let fill: (CMTime) -> CMTime? = { [self] time in
            filled = true
            self.fill(track, upTo: time)
            return track.end
        }
        guard track.fromTap else {
            return SystemAudioPlacement.place(from: pts, to: endPTS, end: end, tolerance: MovieWriter.gapTolerance, fill: fill).map { ($0, 0) }
        }
        if let end, SystemAudioPlacement.isTaken(endPTS, end: end, tolerance: MovieWriter.gapTolerance) {
            track.taken += 1
            if track.taken == 1 {
                RecLog.write(String(format: "%@: a buffer of the tap reached the recording when its track already held %.2f s beyond it (silence written over its time while it was on its way), and was left out", track.name, CMTimeGetSeconds(CMTimeSubtract(end, endPTS))))
            }
        }
        guard let start = SystemAudioPlacement.placeArrived(from: pts, to: endPTS, end: end, floor: sessionStart ?? pts, tolerance: MovieWriter.gapTolerance, fill: fill) else { return nil }
        // Back to back with what the track holds: how far that is from where the buffer arrived is the drift of
        // the tap's device. After silence up to the buffer, or at the track's beginning, there is none yet.
        guard let end, !filled else {
            track.drift.restart()
            return (start, 0)
        }
        let runs = track.drift.runs
        let frames = track.drift.next(offset: CMTimeGetSeconds(CMTimeSubtract(pts, end)), duration: CMTimeGetSeconds(CMTimeSubtract(endPTS, pts)))
        if track.drift.runs != runs, runs < Restamps.loggedRuns {
            let behind = track.drift.behind
            RecLog.write(String(format: "%@: the tap's audio is in its track %.0f ms %@ than it arrives (its device delivers %@ audio than time passes); a sample is %@ every %.1f s until it is in place again",
                                track.name, abs(behind) * 1000, behind > 0 ? "earlier" : "later", behind > 0 ? "less" : "more", behind > 0 ? "added" : "taken out", TapDrift.spacing))
        }
        return (start, frames)
    }

    // MARK: - Tracks whose source delivers nothing

    /// Keeps `videoEnd` at the latest end of a frame written
    private func noteVideoEnd(_ end: CMTime) {
        if let known = videoEnd, known >= end { return }
        videoEnd = end
    }

    /// Appends silence to the microphone track up to `time`, once at least half a second is missing; never beyond
    /// a second after the present
    func fillMicrophone(upTo time: CMTime) {
        let time = notAfterLimit(time)
        guard let converter = micConverter, let micInput = micInput else { return }
        converter.fill(upTo: time, atLeast: Int64(MicConverter.sampleRate / 2)) { append($0, to: micInput) }
        noteEnd(converter.end)
    }

    /// Appends silence to the system audio from where it ends up to `time`: to the audio track of a video recording,
    /// or to the system audio file of an audio-only recording, which has no timestamps and would otherwise come out
    /// shorter than the microphone file next to it. Never beyond a second after the present.
    func fillSystemAudio(upTo time: CMTime) {
        if let system { fill(system, upTo: time) }
    }

    /// The same for the backup of the system audio
    func fillBackupAudio(upTo time: CMTime) {
        if let backup { fill(backup, upTo: time) }
    }

    /// The same for the call tap's audio, which is silence whenever no call plays
    func fillCallAudio(upTo time: CMTime) {
        if let call { fill(call, upTo: time) }
    }

    private func fill(_ track: SystemTrack, upTo time: CMTime) {
        let time = notAfterLimit(time)
        guard let from = track.end ?? sessionStart else { return }
        let file = track.file
        let input = track.input
        var description = track.format
        var format: AVAudioFormat?
        if let file = file {
            format = file.processingFormat
        } else if let known = description {
            // The format ScreenCaptureKit delivered last, so the track does not change format for the silence
            format = AVAudioFormat(cmAudioFormatDescription: known)
        } else {
            // Nothing was delivered yet: what the stream is configured for
            format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
            description = format?.formatDescription
        }
        guard let format = format, format.sampleRate > 0 else { return }
        let scale = CMTimeScale(format.sampleRate)
        var (position, left) = SystemAudioPlacement.silence(from: from, upTo: time, scale: scale)
        // Silence in a tap's track: whatever the tap delivered before it is one span
        if left > 0, track === system {
            tapSpans?.interrupted()
            silentTap?.tapInterrupted()
        }
        if left > 0, track === call { callSpans?.interrupted() }
        while left > 0 {
            let count = min(left, Int64(scale / 2))
            guard let pcm = AudioSilence.pcm(format: format, frames: count) else { return }
            if let file = file {
                do {
                    try file.write(from: pcm)
                } catch {
                    fail(MovieWriter.writeFailure(error))
                    return
                }
            } else {
                guard let input = input, let description = description,
                      let buffer = AudioSilence.sampleBuffer(from: pcm, description: description, at: position),
                      append(buffer, to: input) else { return }
            }
            position = CMTimeAdd(position, CMTime(value: count, timescale: scale))
            left -= count
            track.end = position
            noteEnd(position)
        }
    }

    /// ScreenCaptureKit delivers no frames while the picture does not change (a static slide, a locked or sleeping
    /// display). The last frame is then written again once a second, so the video track keeps up with the audio.
    func repeatVideoFrame(at now: CMTime) {
        let now = notAfterLimit(now)
        guard let videoInput = videoInput, let last = videoPTS, lastVideoFrame != nil else { return }
        guard CMTimeGetSeconds(CMTimeSubtract(now, last)) > MovieWriter.videoStallSeconds else { return }
        // The frame is going to be used for a while: give its surface back to the stream
        detachLastVideoFrame()
        guard let repeated = lastVideoFrame else { return }
        // A little in the past, so a frame that is on its way with an earlier timestamp than now still comes after it
        let time = CMTimeSubtract(now, CMTime(seconds: MovieWriter.videoStallSeconds / 2, preferredTimescale: 600))
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard let again = try? CMSampleBuffer(copying: repeated, withNewTiming: [timing]) else { return }
        if append(again, to: videoInput) {
            videoPTS = time
            noteVideoEnd(time)
            noteEnd(time)
        }
    }

    // MARK: - Finish

    /// After the capture has stopped. Ends the recording on the queue the buffers are appended on: the microphone
    /// track is brought to the length of the recording and the inputs are marked as finished here, so no append can
    /// run alongside or after that. What it returns is what is left to do off the queue: closing the file. When the
    /// session never started, the empty file or package is removed here and there is nothing to close.
    func finish() -> Finished {
        isCapturing = false
        let sessionStarted = sessionStart != nil
        let writer = self.writer
        if recording.recordMic, let input = micInput {
            // Bring the microphone track to the length of the recording, whatever the microphone delivered
            if sessionStarted, let end = stopEnd(), writer?.status == .writing {
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
        // The call tap's track is silence up to a second behind the present whenever no call plays, which is most of
        // the time: brought to the recording's end, so the file's tracks are of one length
        if sessionStarted, let call, let end = stopEnd(), writer?.status == .writing || call.file != nil {
            for _ in 0..<3 {
                var waited = 0
                while let input = call.input, !input.isReadyForMoreMediaData, waited < 200 {
                    usleep(5000)
                    waited += 1
                }
                fill(call, upTo: end)
                if let reached = call.end, CMTimeGetSeconds(CMTimeSubtract(end, reached)) < 0.001 { break }
            }
        }
        if let converter = micConverter { RecLog.write(converter.summary) }
        for line in (system?.summary ?? []) + (backup?.summary ?? []) + (call?.summary ?? []) + [microphoneRestamps.summary, frameRestamps.summary].compactMap({ $0 }) { RecLog.write(line) }
        if futureBuffers > 0 || futureEnds > 0 {
            RecLog.write("Left out for lying beyond the present: \(futureBuffers) buffers, \(futureEnds) ends")
        }
        videoInput?.markAsFinished()
        system?.input?.markAsFinished()
        backup?.input?.markAsFinished()
        call?.input?.markAsFinished()
        // Closes the audio files
        system?.file = nil
        backup?.file = nil
        call?.file = nil
        tapSpans?.close()
        tapSpans = nil
        callSpans?.close()
        callSpans = nil
        if !sessionStarted {
            // Nothing was appended, so there is nothing to close, and an empty file is not a recording. Once the
            // inputs are finished `cancelWriting` leaves the file behind, so `cancel` removes what was created.
            cancel()
        }
        let frame = firstFrame
        self.writer = nil
        videoInput = nil
        system = nil
        backup = nil
        call = nil
        micInput = nil
        firstFrame = nil
        lastVideoFrame = nil
        return Finished(writer: sessionStarted ? writer : nil, frame: frame, sessionStarted: sessionStarted)
    }

    /// Where the tracks end when the recording stops: at the end of the video's last frame; without video (or
    /// before a frame was written), at the latest end on the timeline, but not after the present. Never later: what
    /// a buffer stamped in the future made the timeline's end must not become silence in the file.
    func stopEnd() -> CMTime? {
        if !recording.audioOnly, let video = videoEnd { return video }
        guard let last = lastPTS else { return nil }
        if let present = presentOnTimeline(), present < last { return present }
        return last
    }

    // MARK: - Frames

    /// The picture the recording shows now, for Save Frame: the last frame written, as a copy with pixels of its own
    /// (the writer keeps that copy too, so the stream gets its surface back). Nil before the session has started,
    /// while paused (what is on screen then is not written), or when the copy cannot be made.
    func currentPicture() -> CMSampleBuffer? {
        guard !isPaused else { return nil }
        detachLastVideoFrame()
        return lastVideoFrameIsCopy ? lastVideoFrame : nil
    }

    /// Replaces `lastVideoFrame` by a copy with pixels of its own, so it no longer holds a surface of the stream.
    /// When the copy cannot be made the frame stays as it is and the next call tries again.
    private func detachLastVideoFrame() {
        guard !lastVideoFrameIsCopy, let frame = lastVideoFrame else { return }
        guard let copy = MovieWriter.detachedCopy(of: frame) else {
            print("The last video frame could not be copied")
            return
        }
        lastVideoFrame = copy
        lastVideoFrameIsCopy = true
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

    /// One track of system audio as it is written: the input of a video's track or the file of an audio-only
    /// recording, where its audio ends (silence included), the format it was last delivered in, and how its
    /// buffers' times were taken. The system audio has one; with the process tap its backup has another.
    private final class SystemTrack {
        let name: String
        /// Whether the process tap feeds it: its buffers are stamped by their arrival in the tap's IOProc and go
        /// back to back. Otherwise ScreenCaptureKit does, with timestamps of its own (`stamps`).
        let fromTap: Bool
        let input: AVAssetWriterInput?
        var file: AVAudioFile?
        var end: CMTime?
        var format: CMAudioFormatDescription?
        var stamps = StreamStamps()
        /// Backlogs of the stream that were left out, and buffers of the tap whose time was taken
        var backlogs = 0
        var taken = 0
        /// What keeps the tap's track on the host clock while its device drifts
        var drift = TapDrift()

        init(name: String, fromTap: Bool = false, input: AVAssetWriterInput? = nil, file: AVAudioFile? = nil) {
            self.name = name
            self.fromTap = fromTap
            self.input = input
            self.file = file
        }

        /// For the log at the stop
        var summary: [String] {
            var lines = [String]()
            if let line = Restamps.summary(name, total: stamps.total, runs: stamps.runs) { lines.append(line) }
            // A buffer or two from before the first frame are behind the start of every recording
            if stamps.lateSeconds >= 0.25 {
                lines.append(String(format: "%@: %d buffers (%.2f s of audio) lay before the end of what was written, where silence stood in their place, and were left out", name, stamps.lateBuffers, stamps.lateSeconds))
            }
            if taken > 0 { lines.append("\(name): \(taken) \(taken == 1 ? "buffer" : "buffers") of the tap reached the recording after silence had been written over \(taken == 1 ? "its" : "their") time and \(taken == 1 ? "was" : "were") left out") }
            // Also when nothing had to be done yet: how far the tap's device is from the host clock is worth knowing
            if let ppm = drift.partsPerMillion, drift.added + drift.removed > 0 || (drift.seconds >= 60 && abs(drift.behind) >= 0.001) {
                lines.append(String(format: "%@: %d samples added and %d taken out in %d %@ to keep the tap's audio where it arrived: its device delivered about %.0f parts in a million %@ audio than time passed",
                                    name, drift.added, drift.removed, drift.runs, drift.runs == 1 ? "run" : "runs", abs(ppm), ppm > 0 ? "less" : "more"))
            }
            return lines
        }
    }

    /// The frame with `pts` as its time, or the frame itself when that is its time already
    static func retimed(_ frame: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        guard pts.isValid else { return nil }
        if frame.presentationTimeStamp == pts { return frame }
        let timing = CMSampleTimingInfo(duration: frame.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        return try? CMSampleBuffer(copying: frame, withNewTiming: [timing])
    }

    /// `sample` with one frame more (`frames` 1) or less (-1), at the same time: 32-bit float audio with a buffer
    /// for each channel, the format all system audio reaches the writer in; nil for anything else. The frame is
    /// added, as the mean of its neighbours, or taken out where the samples around it differ least, in silence if
    /// there is any, so the place is not heard.
    static func stretched(_ sample: CMSampleBuffer, by frames: Int) -> CMSampleBuffer? {
        guard frames == 1 || frames == -1, let description = sample.formatDescription, let asbd = description.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame) else { return nil }
        let count = sample.numSamples
        let channels = Int(asbd.mChannelsPerFrame)
        guard count >= 4, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count + 1)),
              let target = output.floatChannelData else { return nil }
        let made = try? sample.withAudioBufferList { list, _ -> Bool in
            var sources = [UnsafePointer<Float>]()
            for part in list {
                guard let data = part.mData, Int(part.mDataByteSize) >= count * MemoryLayout<Float>.size else { return false }
                sources.append(UnsafePointer(data.assumingMemoryBound(to: Float.self)))
            }
            guard sources.count == channels else { return false }
            // The frame after which one is added, or the frame taken out: where its neighbours are closest
            var place = 1
            var least = Float.infinity
            for index in 1..<(count - 1) {
                var difference: Float = 0
                for source in sources { difference += abs(source[index + 1] - source[frames > 0 ? index : index - 1]) }
                if difference < least {
                    least = difference
                    place = index
                    if difference == 0 { break }
                }
            }
            for (channel, source) in sources.enumerated() {
                let out = target[channel]
                if frames > 0 {
                    out.update(from: source, count: place + 1)
                    out[place + 1] = (source[place] + source[place + 1]) / 2
                    (out + place + 2).update(from: source + place + 1, count: count - place - 1)
                } else {
                    out.update(from: source, count: place)
                    (out + place).update(from: source + place + 1, count: count - place - 1)
                }
            }
            return true
        }
        guard made == true else { return nil }
        output.frameLength = AVAudioFrameCount(count + frames)
        return AudioSilence.sampleBuffer(from: output, description: description, at: sample.presentationTimeStamp)
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
}

/// Writes where the process tap delivered (`TapSpans`) to the file next to the recording while it is recorded, a
/// line each time a stretch begins or ends, so a recording that is never closed has them too. Times are seconds on
/// the file's timeline. Sample queue, like the writer that owns it.
final class TapSpanLog {
    let url: URL
    private var handle: FileHandle?
    /// Where the stretch that is going on began, and where the tap's audio last ended
    private var openSince: Double?
    private var lastEnd: Double?
    private var failed = false

    /// Creates the file, empty
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecordingError(String(format: "The file \"%@\" could not be created.", url.lastPathComponent))
        }
        handle = try FileHandle(forWritingTo: url)
    }

    /// The tap's audio went into its track from `start` to `end`
    func delivered(from start: Double, to end: Double) {
        if openSince == nil {
            openSince = max(0, start)
            write(TapSpans.line(alive: max(0, start)))
        }
        lastEnd = end
    }

    /// Silence went into the tap's track: the stretch that was going on ended where its audio did
    func interrupted() {
        guard openSince != nil else { return }
        openSince = nil
        if let end = lastEnd { write(TapSpans.line(dead: end)) }
    }

    /// At the end of the recording
    func close() {
        interrupted()
        try? handle?.close()
        handle = nil
    }

    private func write(_ line: String) {
        do {
            try handle?.write(contentsOf: Data(line.utf8))
        } catch {
            // The mix then judges the sources by their sound alone where the file is missing lines
            if !failed { RecLog.write("System audio: the tap's spans could not be written to \(url.lastPathComponent): \(error.localizedDescription)") }
            failed = true
        }
    }
}
