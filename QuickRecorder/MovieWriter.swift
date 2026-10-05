//
//  MovieWriter.swift
//  QuickRecorder
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
        case audio
        case microphone
    }
    let kind: Kind
    let buffer: CMSampleBuffer
    /// When the buffer starts on the stream's clock
    let pts: CMTime
}

/// Writes one recording: the `AVAssetWriter` with its tracks (or the audio files of an audio-only recording), the
/// writer's session, the timeline with its pauses, and the converter of the microphone track. One is created for
/// every recording and thrown away when it is finished or its start is discarded; nothing here outlives a recording.
///
/// Confined to the sample queue (`SCContext.sampleQueue`) from the moment the capture is started. Before that,
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
    }

    /// What is left for the stop path once the inputs are finished
    struct Finished {
        /// Nil when no file was created, or for an audio-only recording without a microphone
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
    private var videoInput, audioInput, micInput: AVAssetWriterInput?
    /// The system audio file of an audio-only recording
    private var audioFile: AVAudioFile?
    /// True from just before the capture is started until the recording is stopped or has failed
    private(set) var isCapturing = false
    private(set) var isPaused = false
    /// Set when a pause ends, until the first time after it has been put on the timeline
    private(set) var isResume = false
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
    private(set) var audioEndPTS: CMTime?
    /// Format of the system audio delivered last
    private var audioFormatDescription: CMAudioFormatDescription?
    /// Time of the last video frame appended, and that frame, which is written again while no new one arrives
    private(set) var videoPTS: CMTime?
    private var lastVideoFrame: CMSampleBuffer?
    /// Whether `lastVideoFrame` owns its pixels instead of holding a surface of the stream
    private var lastVideoFrameIsCopy = false
    /// Small picture of the recording's first frame for the preview. An image, not the frame: a frame as delivered
    /// holds one of the stream's surfaces, and a full-size copy would sit in memory for the whole recording.
    private var firstFrame: NSImage?
    /// End times of the frames seen last; a frame that ends before one of them is left out
    private var frameEnds = FixedLengthArray<CMTime>(maxLength: 20)

    var hasSystemAudio: Bool { audioInput != nil || audioFile != nil }
    var hasMicrophoneTrack: Bool { micInput != nil }

    init(recording: RecordingContext, micConverter: MicConverter?) {
        self.recording = recording
        self.micConverter = micConverter
    }

    // MARK: - Files and tracks

    /// Creates the video file and its tracks. When it throws, the caller discards what was created (`cancel`).
    func prepareVideo(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: recording.rawURL, fileType: recording.fileType)
        self.writer = writer
        // The file is written in fragments, so a crash, a kill or a power loss costs the last few seconds instead of
        // the recording: without them a .mp4 or .mov cannot be opened at all unless it was closed properly.
        // Closing the file normally turns it into an ordinary movie file.
        writer.movieFragmentInterval = MovieWriter.fragmentInterval
        let encoderIsH265 = (AppSettings.encoder == .h265) || AppSettings.recordHDR
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
        print("framerate set in app: \(fps)")
        print("target bitrate: \(targetBitrate/1000000)")

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: encoderIsH265 ? ((AppSettings.withAlpha && !AppSettings.recordHDR) ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc) : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
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

        let audioSettings = recording.audioSettings
        let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError("The video settings are not supported by this file format.") }
        writer.add(videoInput)

        // Only tracks that are fed: the writer puts a fragment on disk once every track has data for it, so a single
        // track that never gets any would leave the whole file unreadable until it is closed
        var audioInput: AVAssetWriterInput?
        if recording.systemAudio {
            let input = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError("The audio settings are not supported by this file format.") }
            writer.add(input)
            audioInput = input
        }

        var micInput: AVAssetWriterInput?
        if recording.recordMic {
            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            let input = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError("The microphone track cannot be written in this file format.") }
            writer.add(input)
            micInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? RecordingError("The video file could not be created.") }
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.micInput = micInput
    }

    /// Creates the files of an audio-only recording. When it throws, the caller discards what was created (`cancel`).
    func prepareAudio() throws {
        guard let systemAudioURL = recording.systemAudioURL else { throw RecordingError("The audio file has no location.") }
        let settings = recording.audioSettings
        if let micAudioURL = recording.micAudioURL {
            let exportMP3 = recording.audioFormat == .mp3
            let jsonString = "{\"format\": \"\(recording.audioFileEnding)\", \"encoder\": \"\(recording.audioEncoder)\", \"exportMP3\": \(exportMP3), \"sysVol\": 1.0, \"micVol\": 1.0}"
            try FileManager.default.createDirectory(at: recording.rawURL, withIntermediateDirectories: true, attributes: nil)
            try jsonString.write(to: recording.rawURL.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)

            // MicConverter delivers 48 kHz stereo whatever the device's own format is
            let writer = try AVAssetWriter(outputURL: micAudioURL, fileType: recording.audioFileType)
            self.writer = writer
            // .caf, used for FLAC and Opus, has no movie fragments
            if recording.audioFileType == .m4a { writer.movieFragmentInterval = MovieWriter.fragmentInterval }
            let micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: settings)
            micInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(micInput) else { throw RecordingError("The microphone track cannot be written in this audio format.") }
            writer.add(micInput)
            guard writer.startWriting() else { throw writer.error ?? RecordingError("The microphone file could not be created.") }
            self.micInput = micInput
        }
        audioFile = try AVAudioFile(forWriting: systemAudioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// The encoder settings of an audio track. The defaults are the current settings; code that works on a
    /// recording passes that recording's values instead (`RecordingContext.audioSettings`).
    static func audioSettings(format: String = AppSettings.audioFormat.rawValue,
                              quality: Int = AppSettings.audioQuality.rawValue,
                              videoFormat: String = AppSettings.videoFormat.rawValue) -> [String : Any] {
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

    /// For a start that failed before anything was recorded. Also deletes the file the writer created.
    func cancel() {
        isCapturing = false
        audioFile = nil
        writer?.cancelWriting()
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

    /// Keeps `lastPTS` at the latest end time of anything on the timeline
    private func noteEnd(_ end: CMTime?) {
        lastPTS = Timeline.latestEnd(end, after: lastPTS)
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
        let rawPTS = sample.pts
        let duration = sampleBuffer.duration
        guard rawPTS.isValid else { return }
        guard checkWriter() else { return }
        let rawEnd = duration.isValid && duration.value > 0 ? CMTimeAdd(rawPTS, duration) : rawPTS
        var isMicrophone = false
        if case .microphone = sample.kind { isMicrophone = true }
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
        case .audio:
            if recording.audioOnly {
                writeAudioToFile(sampleBuffer, from: pts, to: endPTS)
            } else {
                writeAudioToTrack(sampleBuffer, rawPTS: rawPTS, from: pts, to: endPTS)
            }
        case .microphone:
            guard sessionStart != nil, let micInput = micInput, let converter = micConverter else { return }
            let written = converter.convert(sampleBuffer, at: pts) { buffer in
                append(buffer, to: micInput)
            }
            if written { events.microphoneWritten(converter.end, converter.lastPeak) }
        }
    }

    private func writeFrame(_ sampleBuffer: CMSampleBuffer, from pts: CMTime, to endPTS: CMTime) {
        // The first complete frame starts the session; until then nothing is appended to any track
        if sessionStart == nil { guard beginSession(at: pts) else { return } }
        guard var frame = MovieWriter.retime(sampleBuffer, by: timeOffset) else { return }
        if frameEnds.getArray().contains(where: { $0 >= endPTS }) { print("Skip this frame"); return } else { frameEnds.append(endPTS) }
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
                noteEnd(framePTS)
                lastVideoFrame = frame
                lastVideoFrameIsCopy = false
            }
        }
    }

    /// System audio of an audio-only recording, which goes straight into its file
    private func writeAudioToFile(_ sampleBuffer: CMSampleBuffer, from pts: CMTime, to endPTS: CMTime) {
        // The first system audio starts the session of the microphone file, if there is one
        if sessionStart == nil { guard beginSession(at: pts) else { return } }
        guard let samples = sampleBuffer.asPCMBuffer else { return }
        // The file has no timestamps: audio that did not arrive is written as silence, or everything after it
        // would be early, and audio that arrives after silence was written in its place is left out, or
        // everything after it would be late
        guard let start = placeSystemAudio(from: pts, to: endPTS) else { return }
        do {
            try audioFile?.write(from: samples)
            let end = CMTimeAdd(start, CMTimeSubtract(endPTS, pts))
            audioEndPTS = end
            events.systemAudioWritten(end)
        } catch {
            fail(MovieWriter.writeFailure(error))
        }
    }

    private func writeAudioToTrack(_ sampleBuffer: CMSampleBuffer, rawPTS: CMTime, from pts: CMTime, to endPTS: CMTime) {
        guard sessionStart != nil, let audioInput = audioInput else { return }
        audioFormatDescription = sampleBuffer.formatDescription
        // The writer plays audio buffers back to back whatever their timestamps say. The buffer goes at the end
        // of what was written, and only once that end is where the buffer belongs.
        guard let start = placeSystemAudio(from: pts, to: endPTS) else { return }
        guard let buffer = MovieWriter.retime(sampleBuffer, by: CMTimeSubtract(rawPTS, start)) else { return }
        if append(buffer, to: audioInput) {
            let end = CMTimeAdd(start, CMTimeSubtract(endPTS, pts))
            audioEndPTS = end
            events.systemAudioWritten(end)
        }
    }

    /// Where a system audio buffer that covers `pts` to `endPTS` goes: at the end of the system audio written so far.
    /// Nil when it must not be written: it lies before that end (silence was already written in its place), or the
    /// silence for a hole in front of it could not be written yet. That end is counted from what was written, not
    /// read from the timestamps, so a buffer the writer did not take leaves a hole that is still there for the next
    /// buffer to see. Holes add up and are filled with silence once they exceed `gapTolerance`; a buffer that
    /// overlaps the end is written whole, which puts the audio late by less than one buffer and no more.
    private func placeSystemAudio(from pts: CMTime, to endPTS: CMTime) -> CMTime? {
        return SystemAudioPlacement.place(from: pts, to: endPTS, end: audioEndPTS, tolerance: MovieWriter.gapTolerance) { time in
            fillSystemAudio(upTo: time)
            return audioEndPTS
        }
    }

    // MARK: - Tracks whose source delivers nothing

    /// Appends silence to the microphone track up to `time`, once at least half a second is missing
    func fillMicrophone(upTo time: CMTime) {
        guard let converter = micConverter, let micInput = micInput else { return }
        converter.fill(upTo: time, atLeast: Int64(MicConverter.sampleRate / 2)) { append($0, to: micInput) }
        noteEnd(converter.end)
    }

    /// Appends silence to the system audio from where it ends up to `time`: to the audio track of a video recording,
    /// or to the system audio file of an audio-only recording, which has no timestamps and would otherwise come out
    /// shorter than the microphone file next to it.
    func fillSystemAudio(upTo time: CMTime) {
        guard let from = audioEndPTS ?? sessionStart else { return }
        let file = audioFile
        let input = audioInput
        var description = audioFormatDescription
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
            audioEndPTS = position
            noteEnd(position)
        }
    }

    /// ScreenCaptureKit delivers no frames while the picture does not change (a static slide, a locked or sleeping
    /// display). The last frame is then written again once a second, so the video track keeps up with the audio.
    func repeatVideoFrame(at now: CMTime) {
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
            noteEnd(time)
        }
    }

    // MARK: - Finish

    /// After the capture has stopped. Ends the recording on the queue the buffers are appended on: the microphone
    /// track is brought to the length of the recording and the inputs are marked as finished here, so no append can
    /// run alongside or after that. What it returns is what is left to do off the queue: closing the file.
    func finish() -> Finished {
        isCapturing = false
        let sessionStarted = sessionStart != nil
        let writer = self.writer
        if recording.recordMic, let input = micInput {
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
        self.writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        firstFrame = nil
        lastVideoFrame = nil
        return Finished(writer: writer, frame: frame, sessionStarted: sessionStarted)
    }

    // MARK: - Frames

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

struct FixedLengthArray<T> {
    private var array: [T] = []
    private let maxLength: Int

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    mutating func append(_ element: T) {
        if array.count >= maxLength {
            array.removeFirst()
        }
        array.append(element)
    }

    func getArray() -> [T] {
        return array
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
