//
//  MovieWriter.swift
//  Holdfast
//

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
        case microphone
    }
    let kind: Kind
    let buffer: CMSampleBuffer
    /// When the buffer starts on the stream's clock
    let pts: CMTime
    /// When the buffer reached the app, on the host clock its timestamps are on; invalid when not known. An audio
    /// buffer stamped far from it is given this time instead (`ArrivalCheck`), and the microphone's converter tells
    /// a backlog from a clock that lags by it.
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
    }

    /// The titles of the audio tracks of a video recording, which players show and the mix tells the tracks by
    enum TrackTitle {
        static let system = "System audio"
        static let tap = "System audio (tap)"
        static let backup = "System audio (backup)"
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

    let recording: RecordingContext
    /// Nil when the recording has no microphone track
    let micConverter: MicConverter?
    var events = Events()

    private var writer: AVAssetWriter?
    private var videoInput, micInput: AVAssetWriterInput?
    /// The system audio track (or file, for an audio-only recording), and its backup when the tap is used
    private var system: SystemTrack?
    private var backup: SystemTrack?
    /// Where the tap delivered, written next to the recording while it runs; nil without the backup
    private var tapSpans: TapSpanLog?
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
    /// The end time of the buffer that arrived last and the uptime at which it arrived. `RecordingMonitor` tells the
    /// present time on the buffers' clock from it while nothing arrives.
    private(set) var clockAnchor: (raw: CMTime, uptime: UInt64)?
    /// End of the system audio appended so far, silence included
    var audioEndPTS: CMTime? { system?.end }
    /// End of the backup of the system audio appended so far, silence included
    var backupEndPTS: CMTime? { backup?.end }
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
    /// audio counts its own in its `SystemTrack`)
    private var microphoneRestamps = Restamps(name: "Microphone", behind: ArrivalCheck.microphoneBehind)
    /// Buffers left out because they end beyond the present, and ends the timeline did not take for that reason
    private var futureBuffers = 0
    private var futureEnds = 0
    /// Small picture of the recording's first frame for the preview. An image, not the frame: a frame as delivered
    /// holds one of the stream's surfaces, and a full-size copy would sit in memory for the whole recording.
    private var firstFrame: NSImage?
    /// End time of the last frame taken; a frame that does not end after it is left out
    private var lastFrameEnd: CMTime?

    var hasSystemAudio: Bool { system != nil }
    var hasBackupAudio: Bool { backup != nil }
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
        // the mix also goes by when a file has no titles: system audio, its backup, the microphone.
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
        if recording.systemAudio {
            let title = recording.systemAudioBackup ? TrackTitle.tap : TrackTitle.system
            system = SystemTrack(name: "System audio", input: try audioInput(title, failure: "The audio settings are not supported by this file format."))
            if recording.systemAudioBackup {
                backup = SystemTrack(name: "System audio backup", input: try audioInput(TrackTitle.backup, failure: "The audio settings are not supported by this file format."))
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
        guard recording.systemAudioBackup, let url = recording.tapSpansURL else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingError(String(format: "A file named \"%@\" is already in the save folder.", url.lastPathComponent))
        }
        tapSpans = try TapSpanLog(url: url)
        createdAlongside.append(url)
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
        system = SystemTrack(name: "System audio", file: try AVAudioFile(forWriting: systemAudioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false))
        if let backupURL = recording.backupAudioURL {
            // In the package, or next to the file under a name of its own; never over another file
            guard !FileManager.default.fileExists(atPath: backupURL.path) else {
                throw RecordingError(String(format: "A file named \"%@\" is already in the save folder.", backupURL.lastPathComponent))
            }
            if recording.micAudioURL == nil { createdAlongside.append(backupURL) }
            backup = SystemTrack(name: "System audio backup", file: try AVAudioFile(forWriting: backupURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false))
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
        tapSpans?.close()
        tapSpans = nil
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

    /// Buffers of one audio source given their arrival time instead of their own (`ArrivalCheck`). The first of a
    /// run is logged, and the end of the run, for the first runs; the total at the stop.
    private struct Restamps {
        static let loggedRuns = 10
        let name: String
        /// Seconds a buffer may be stamped before its arrival (`ArrivalCheck`)
        let behind: Double
        var run = 0
        var runs = 0
        var total = 0

        /// The start of a buffer that starts at `pts`, lasts `duration` and arrived at `arrival`
        mutating func start(_ pts: CMTime, duration: CMTime, arrival: CMTime) -> CMTime {
            let how: String
            switch ArrivalCheck.verdict(pts: pts, arrival: arrival, behind: behind) {
            case .trusted:
                if run > 0, runs <= Restamps.loggedRuns {
                    RecLog.write("\(name): timestamps can be believed again, after \(Restamps.buffers(run)) at \(run == 1 ? "its" : "their") arrival time")
                }
                run = 0
                return pts
            case .ahead(let seconds): how = String(format: "%.2f s after", seconds)
            case .behind(let seconds): how = String(format: "%.2f s before", seconds)
            }
            if run == 0 {
                runs += 1
                if runs <= Restamps.loggedRuns {
                    RecLog.write("\(name): a buffer is stamped \(how) it arrived, which cannot be its time; it is recorded at its arrival time, as is every buffer after it until their timestamps can be believed again")
                }
            }
            run += 1
            total += 1
            return ArrivalCheck.restamped(arrival: arrival, duration: duration)
        }

        var summary: String? {
            guard total > 0 else { return nil }
            return "\(name): \(Restamps.buffers(total)) at \(total == 1 ? "its" : "their") arrival time in \(runs) \(runs == 1 ? "run" : "runs"), \(total == 1 ? "its" : "their") own timestamp being off"
        }

        /// "1 buffer recorded", "3 buffers recorded"
        static func buffers(_ count: Int) -> String { "\(count) \(count == 1 ? "buffer" : "buffers") recorded" }
    }

    /// False for a buffer that ends more than `ArrivalCheck.ahead` after the present, which is left out: it would
    /// make the recording that long. Logged the first time; the stop logs how many.
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
        let kind: String
        switch sample.kind {
        case .screen:
            kind = "video"
        case .audio:
            kind = "system audio"
            guard let system else { return }
            rawPTS = system.restamps.start(rawPTS, duration: duration, arrival: sample.arrival)
        case .backupAudio:
            kind = "system audio backup"
            guard let backup else { return }
            rawPTS = backup.restamps.start(rawPTS, duration: duration, arrival: sample.arrival)
        case .microphone:
            kind = "microphone"
            isMicrophone = true
            rawPTS = microphoneRestamps.start(rawPTS, duration: duration, arrival: sample.arrival)
        }
        let rawEnd = duration.isValid && duration.value > 0 ? CMTimeAdd(rawPTS, duration) : rawPTS
        // A frame, or audio whose arrival is not known, stamped in the future
        guard endsByPresent(rawEnd, kind: kind) else { return }
        if !isMicrophone || clockAnchor == nil {
            clockAnchor = (rawEnd, DispatchTime.now().uptimeNanoseconds)
        }
        // Times on the writer's timeline
        let pts = timelineTime(rawPTS)
        let endPTS = CMTimeSubtract(rawEnd, timeOffset)
        noteEnd(endPTS)
        switch sample.kind {
        case .screen(let complete):
            if recording.audioOnly || !complete { return }
            writeFrame(sampleBuffer, from: pts, to: endPTS)
        case .audio, .backupAudio:
            let isBackup: Bool
            if case .backupAudio = sample.kind { isBackup = true } else { isBackup = false }
            guard let track = isBackup ? backup : system else { return }
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

    private func writeFrame(_ sampleBuffer: CMSampleBuffer, from pts: CMTime, to endPTS: CMTime) {
        // The first complete frame starts the session; until then nothing is appended to any track
        if sessionStart == nil { guard beginSession(at: pts) else { return } }
        if let last = lastFrameEnd, endPTS <= last { return }
        guard var frame = MovieWriter.retime(sampleBuffer, by: timeOffset) else { return }
        lastFrameEnd = endPTS
        guard let videoInput = videoInput else { return }
        var framePTS = pts
        if let last = videoPTS, pts <= last {
            // The writer fails on a frame that is not later than the one before it. A frame that is only just behind
            // (the last frame was written again a moment ago) goes right after it instead of being lost: it may be
            // the only frame of a new picture, a slide change for example.
            guard CMTimeGetSeconds(CMTimeSubtract(last, pts)) < MovieWriter.videoStallSeconds else { return }
            framePTS = CMTimeAdd(last, CMTime(value: 1, timescale: 100))
            let timing = CMSampleTimingInfo(duration: frame.duration, presentationTimeStamp: framePTS, decodeTimeStamp: .invalid)
            guard let moved = try? CMSampleBuffer(copying: frame, withNewTiming: [timing]) else { return }
            frame = moved
        }
        if videoInput.isReadyForMoreMediaData {
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
        guard let start = placeSystemAudio(track, from: pts, to: endPTS, end: track.end ?? sessionStart) else { return }
        do {
            try track.file?.write(from: samples)
            delivered(track, from: start, to: CMTimeAdd(start, CMTimeSubtract(endPTS, pts)))
        } catch {
            fail(MovieWriter.writeFailure(error))
        }
    }

    private func writeAudioToTrack(_ sampleBuffer: CMSampleBuffer, track: SystemTrack, from pts: CMTime, to endPTS: CMTime) {
        guard sessionStart != nil, let input = track.input else { return }
        track.format = sampleBuffer.formatDescription
        // The writer plays audio buffers back to back whatever their timestamps say. The buffer goes at the end
        // of what was written, and only once that end is where the buffer belongs.
        guard let start = placeSystemAudio(track, from: pts, to: endPTS, end: track.end) else { return }
        // From the buffer's own timestamp, which is not `pts` when it was given its arrival time
        guard let buffer = MovieWriter.retime(sampleBuffer, by: CMTimeSubtract(sampleBuffer.presentationTimeStamp, start)) else { return }
        if append(buffer, to: input) {
            delivered(track, from: start, to: CMTimeAdd(start, CMTimeSubtract(endPTS, pts)))
        }
    }

    /// Audio of a source went into `track` from `start` to `end`: its end moves on, the monitor hears of it, and
    /// for the tap's track its spans grow
    private func delivered(_ track: SystemTrack, from start: CMTime, to end: CMTime) {
        track.end = end
        if track === backup {
            events.backupAudioWritten(end)
        } else {
            events.systemAudioWritten(end)
            if let tapSpans, let sessionStart {
                tapSpans.delivered(from: CMTimeGetSeconds(CMTimeSubtract(start, sessionStart)), to: CMTimeGetSeconds(CMTimeSubtract(end, sessionStart)))
            }
        }
    }

    /// Where a system audio buffer that covers `pts` to `endPTS` goes in `track`: at the end of what was written
    /// to it so far (`end`). Nil when it must not be written: it lies before that end (silence was already written
    /// in its place), or the silence for a hole in front of it could not be written yet. That end is counted from
    /// what was written, not read from the timestamps, so a buffer the writer did not take leaves a hole that is
    /// still there for the next buffer to see. Holes add up and are filled with silence once they exceed
    /// `gapTolerance`; a buffer that overlaps the end is written whole, which puts the audio late by less than one
    /// buffer and no more. The backup is placed exactly like the system audio, so the two share one timeline.
    private func placeSystemAudio(_ track: SystemTrack, from pts: CMTime, to endPTS: CMTime, end: CMTime?) -> CMTime? {
        return SystemAudioPlacement.place(from: pts, to: endPTS, end: end, tolerance: MovieWriter.gapTolerance) { time in
            fill(track, upTo: time)
            return track.end
        }
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
        // Silence in the tap's track: whatever the tap delivered before it is one span
        if left > 0, track === system { tapSpans?.interrupted() }
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
        if let converter = micConverter { RecLog.write(converter.summary) }
        for line in [system?.restamps.summary, backup?.restamps.summary, microphoneRestamps.summary] { if let line = line { RecLog.write(line) } }
        if futureBuffers > 0 || futureEnds > 0 {
            RecLog.write("Left out for lying beyond the present: \(futureBuffers) buffers, \(futureEnds) ends")
        }
        videoInput?.markAsFinished()
        system?.input?.markAsFinished()
        backup?.input?.markAsFinished()
        // Closes the audio files
        system?.file = nil
        backup?.file = nil
        tapSpans?.close()
        tapSpans = nil
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
    /// recording, where its audio ends (silence included), the format it was last delivered in, and the buffers it
    /// gave their arrival time. The system audio has one; with the process tap its backup has another, written the
    /// same way.
    private final class SystemTrack {
        let input: AVAssetWriterInput?
        var file: AVAudioFile?
        var end: CMTime?
        var format: CMAudioFormatDescription?
        var restamps: Restamps

        init(name: String, input: AVAssetWriterInput? = nil, file: AVAudioFile? = nil) {
            self.input = input
            self.file = file
            restamps = Restamps(name: name, behind: ArrivalCheck.behind)
        }
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
