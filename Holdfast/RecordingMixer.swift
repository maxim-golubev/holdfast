//
//  RecordingMixer.swift
//  Holdfast
//

import AVFoundation
import Foundation

/// The audio mix that follows a video recording with system audio and a microphone, and what can be told about a
/// recording an earlier run left behind by opening it. The names of the files are `RecordingFileStore`'s.
///
/// Nothing here deletes or renames a file. It writes the mix to the URL it is given and says whether that file can
/// be trusted; the caller decides what happens to the files.
enum RecordingMixer {
    // MARK: - Mix

    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    /// Writes `source` to `output` in one pass: the video samples are copied as they are, and all audio tracks are
    /// mixed into one track encoded with `audioSettings`. `progress` gets a value from 0 to 1, on a background queue.
    /// `source` is only read. When this throws, `output` is missing or incomplete.
    static func mix(source: URL, output: URL, fileType: AVFileType, audioSettings: [String: Any], progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, videoTracks.count == 1 else { throw RecordingError("The recording has no video track.") }
        guard audioTracks.count > 1 else { throw RecordingError("The recording does not have two audio tracks to mix.") }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw RecordingError("The recording is empty.") }
        let transform = try await videoTrack.load(.preferredTransform)
        guard let videoFormat = try await videoTrack.load(.formatDescriptions).first else { throw RecordingError("The video track has no format.") }

        let reader = try AVAssetReader(asset: asset)
        // No output settings: the compressed frames are handed over as they are in the file
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        var mixSettings = pcmSettings
        mixSettings[AVSampleRateKey] = 48000
        mixSettings[AVNumberOfChannelsKey] = 2
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: mixSettings)
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else { throw RecordingError("The recording cannot be read for mixing.") }
        reader.add(videoOutput)
        reader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw RecordingError("The mixed recording cannot be written in this format.") }
        writer.add(videoInput)
        writer.add(audioInput)

        guard reader.startReading() else { throw reader.error ?? RecordingError("The recording could not be read.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? RecordingError("The mixed recording could not be created.")
        }
        writer.startSession(atSourceTime: .zero)

        var lastPercent = -1
        let copied = await copy([(videoOutput, videoInput), (audioOutput, audioInput)], reader: reader, writer: writer) { buffer, index in
            guard index == 0 else { return }
            let percent = Int(max(0, min(1, CMTimeGetSeconds(buffer.presentationTimeStamp) / seconds)) * 100)
            // Video samples come in decoding order, so their times do not only go up
            if percent > lastPercent {
                lastPercent = percent
                progress(Double(percent) / 100)
            }
        }
        // Every state but "completed" is a failure: failed, cancelled, and anything unexpected
        guard copied == nil, reader.status == .completed else {
            let error = writer.error ?? reader.error
            reader.cancelReading()
            writer.cancelWriting()
            throw error ?? RecordingError(copied ?? "Mixing the audio tracks was interrupted.")
        }
        guard writer.status == .writing else {
            throw writer.error ?? RecordingError("The mixed recording could not be written.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecordingError("The mixed recording could not be closed.")
        }
        progress(1)
    }

    /// How long the copy may go without moving a single sample before it is given up
    static let stallLimit: TimeInterval = 60

    /// What the copy and its watchdog share: they run on different queues
    private final class CopyState {
        private let lock = NSLock()
        private var result: String??
        private var activity = DispatchTime.now().uptimeNanoseconds
        private let continuation: CheckedContinuation<String?, Never>

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

        /// Whether the copy has ended, one way or the other
        var isOver: Bool {
            lock.lock(); defer { lock.unlock() }
            return result != nil
        }

        func noteActivity() {
            lock.lock(); defer { lock.unlock() }
            activity = DispatchTime.now().uptimeNanoseconds
        }

        var idleSeconds: Double {
            lock.lock(); defer { lock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            return now > activity ? Double(now - activity) / 1_000_000_000 : 0
        }

        /// Ends the wait with `failure` (nil for success). Only the first call counts; returns whether this was it.
        @discardableResult
        func end(_ failure: String?) -> Bool {
            lock.lock()
            let first = result == nil
            if first { result = .some(failure) }
            lock.unlock()
            if first { continuation.resume(returning: failure) }
            return first
        }
    }

    /// Moves every sample of each reader output to its writer input. Returns nil when all of them have reached
    /// their end, and what went wrong otherwise: at once when an append fails, and from a watchdog when the writer
    /// or the reader has failed or no sample has moved for `stallLimit` seconds. The copy runs on one serial queue,
    /// which owns its bookkeeping. The watchdog runs on another, because a read that hangs would hold up the first;
    /// without it a writer that stops asking for data would leave the caller waiting for ever.
    private static func copy(_ pairs: [(AVAssetReaderOutput, AVAssetWriterInput)], reader: AVAssetReader, writer: AVAssetWriter, each: @escaping (CMSampleBuffer, Int) -> Void) async -> String? {
        let queue = DispatchQueue(label: "Holdfast.mix")
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Holdfast.mix.watchdog"))
        let failure = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let state = CopyState(continuation)
            var remaining = pairs.count
            var ended = [Bool](repeating: false, count: pairs.count)
            // On the copy queue
            func end(_ index: Int, failure: String?) {
                // Once the wait is over the caller owns the writer (and may be cancelling it): hands off
                guard !state.isOver else { return }
                if !ended[index] {
                    ended[index] = true
                    pairs[index].1.markAsFinished()
                    remaining -= 1
                }
                if let failure = failure {
                    reader.cancelReading()
                    state.end(failure)
                } else if remaining == 0 {
                    state.end(nil)
                }
            }
            for (index, pair) in pairs.enumerated() {
                let (output, input) = pair
                input.requestMediaDataWhenReady(on: queue) {
                    while !ended[index] && !state.isOver && input.isReadyForMoreMediaData {
                        guard let buffer = output.copyNextSampleBuffer() else {
                            end(index, failure: nil)
                            return
                        }
                        guard !state.isOver else { return }
                        guard input.append(buffer) else {
                            end(index, failure: "The mixed recording could not be written.")
                            return
                        }
                        state.noteActivity()
                        each(buffer, index)
                    }
                }
            }
            watchdog.schedule(deadline: .now() + 2, repeating: 2)
            watchdog.setEventHandler {
                guard !state.isOver else { return }
                var problem: String?
                if writer.status == .failed {
                    problem = "The mixed recording could not be written."
                } else if reader.status == .failed {
                    problem = "The recording could not be read."
                } else if state.idleSeconds > stallLimit {
                    problem = String(format: "Mixing made no progress for %d seconds and was given up.", Int(stallLimit))
                }
                guard let problem = problem, state.end(problem) else { return }
                print("Mix watchdog: \(problem) writer: \(String(describing: writer.error)), reader: \(String(describing: reader.error))")
                // Lets a read that is still waiting return
                reader.cancelReading()
            }
            watchdog.resume()
        }
        watchdog.cancel()
        return failure
    }

    // MARK: - The two files of a .qma package

    /// Mixes the system audio and microphone files of a .qma package, each at its volume, into the audio file
    /// `output` (written with `settings`), up to the end of the longer file: the microphone file runs on past the
    /// system audio by what the stop padded it with. Returns once `output` is closed, as long as that file and in
    /// step with both (`checkTiming`); throws otherwise, and `output` is then incomplete or wrong. Blocks while it
    /// renders, so not on the main thread.
    static func mixPackage(system: URL, microphone: URL, volumes: (system: Float, microphone: Float), to output: URL, settings: [String: Any]) throws {
        let sources = [(url: system, volume: volumes.system), (url: microphone, volume: volumes.microphone)]
        let files = try sources.map { try AVAudioFile(forReading: $0.url) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw RecordingError("The audio could not be mixed.")
        }
        // An engine of its own, offline from the start. One that has run in real time has read ahead into the files
        // scheduled on it and drops that read-ahead when it is switched to offline rendering: the mix then began
        // about 1.15 s into both files and ended in as much silence, at the right length.
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        var players = [AVAudioPlayerNode]()
        for (file, source) in zip(files, sources) {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            // The mixer converts each file's own rate and channels
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = source.volume
            player.scheduleFile(file, at: nil)
            players.append(player)
        }
        try engine.start()
        defer { engine.stop() }
        players.forEach { $0.play() }

        func seconds(_ file: AVAudioFile) -> Double { Double(file.length) / file.processingFormat.sampleRate }
        guard let longer = files.max(by: { seconds($0) < seconds($1) }),
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw RecordingError("The audio could not be mixed.")
        }
        let outputFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let duration = AVAudioFramePosition((seconds(longer) * engine.manualRenderingFormat.sampleRate).rounded())
        while engine.manualRenderingSampleTime < duration {
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(duration - engine.manualRenderingSampleTime))
            // Players render silence once their file has ended, so anything but success would never move on
            guard try engine.renderOffline(frames, to: buffer) == .success else {
                throw RecordingError("The audio could not be mixed.")
            }
            try outputFile.write(from: buffer)
        }
        // Closed here, not when it is released, so that a file that could not be finished fails the checks below
        outputFile.close()
        try verifyConversion(source: longer.url, output: output)
        try checkTiming(of: output, sources: sources)
    }

    /// How far into the files `checkTiming` looks, and in what steps
    private static let timingSeconds = 30.0
    private static let timingStep = 0.01

    /// Throws when the mix `output` is out of step with the files it was mixed from (`sources`, each with the volume
    /// it was mixed at). A mix that starts late or early into its files still has their length, so only its sound
    /// tells: the loudness of its first 30 s, in 10 ms steps, must match what the sources add up to without an
    /// offset better than none. Sources without changes in loudness there pass, as there is nothing to tell from.
    static func checkTiming(of output: URL, sources: [(url: URL, volume: Float)]) throws {
        let mixed = try envelope(of: output)
        let parts = try sources.map { source in try envelope(of: source.url).map { $0 * Double(source.volume) } }
        let count = max(mixed.count, parts.map(\.count).max() ?? 0)
        // Loudness adds up as power: the sources are not expected to cancel each other out
        let expected = (0..<count).map { step in parts.reduce(0) { sum, part in step < part.count ? sum + part[step] * part[step] : sum }.squareRoot() }
        /// Mean difference between the mix, moved by `offset` steps, and what is expected
        func difference(at offset: Int) -> Double {
            let first = max(0, -offset)
            let end = min(expected.count, mixed.count - offset)
            guard first < end else { return .infinity }
            return (first..<end).reduce(0) { $0 + abs(mixed[$1 + offset] - expected[$1]) } / Double(end - first)
        }
        let maximumOffset = Int(2 / timingStep)
        let differences = (-maximumOffset...maximumOffset).map { (offset: $0, difference: difference(at: $0)) }
        guard let best = differences.min(by: { $0.difference < $1.difference }) else { return }
        // Up to 20 ms is the encoder's doing; a match elsewhere that is better by half is no chance
        if abs(best.offset) > 2 && best.difference < difference(at: 0) / 2 {
            throw RecordingError(String(format: "The mixed audio is out of step with the recording by %.2f s.", Double(abs(best.offset)) * timingStep))
        }
    }

    /// The loudness (RMS of all channels) of the first `timingSeconds` of an audio file, one value per `timingStep`
    private static func envelope(of url: URL) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let step = AVAudioFrameCount(max(1, (rate * timingStep).rounded()))
        let frames = min(file.length, AVAudioFramePosition(rate * timingSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step) else {
            throw RecordingError("The audio cannot be read to check the mix.")
        }
        var levels = [Double]()
        while file.framePosition < frames {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: min(step, AVAudioFrameCount(frames - file.framePosition)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(buffer.format.channelCount)
            let length = Int(buffer.frameLength)
            var sum = 0.0
            for channel in 0..<channels {
                for frame in 0..<length { sum += Double(data[channel][frame]) * Double(data[channel][frame]) }
            }
            levels.append((sum / Double(channels * length)).squareRoot())
        }
        return levels
    }

    // MARK: - Verification

    /// How much longer or shorter than its video the audio of a mixed recording may be
    static let maxAudioVideoDifference: Double = 2
    /// How much shorter than its video the audio of a recording that was never closed may be: its tracks end
    /// where the last fragment of each reached the disk, and audio lags the picture by up to a fragment
    static var unfinishedAudioShortfall: Double { CMTimeGetSeconds(MovieWriter.fragmentInterval) + maxAudioVideoDifference }

    /// Throws unless `output` is a complete mix of `source`: one video and one audio track, whose lengths differ
    /// by `maxAudioVideoDifference` at most (the audio of an `unfinished` recording, one never closed, may be up
    /// to `unfinishedAudioShortfall` shorter), as long as the source to within a second, and with the microphone
    /// audible where only the microphone had sound.
    static func verify(source: URL, output: URL, unfinished: Bool = false) async throws {
        guard FileManager.default.fileExists(atPath: output.path) else { throw RecordingError("The mixed recording was not written.") }
        let raw = AVURLAsset(url: source)
        let mixed = AVURLAsset(url: output)
        let video = try await mixed.loadTracks(withMediaType: .video)
        let audio = try await mixed.loadTracks(withMediaType: .audio)
        guard video.count == 1, let mixedAudio = audio.first, audio.count == 1 else {
            throw RecordingError("The mixed recording does not have one video and one audio track.")
        }
        let rawSeconds = CMTimeGetSeconds(try await raw.load(.duration))
        let mixedSeconds = CMTimeGetSeconds(try await mixed.load(.duration))
        let videoSeconds = CMTimeGetSeconds(try await video[0].load(.timeRange).duration)
        let audioSeconds = CMTimeGetSeconds(try await mixedAudio.load(.timeRange).duration)
        // A microphone padded with silence far beyond the picture once passed every check below: a 20-minute call
        // came out with 38 minutes of audio
        let shortfall = unfinished ? unfinishedAudioShortfall : maxAudioVideoDifference
        guard videoSeconds.isFinite, audioSeconds.isFinite, audioSeconds - videoSeconds <= maxAudioVideoDifference,
              videoSeconds - audioSeconds <= shortfall else {
            throw RecordingError(String(format: "The audio of the mixed recording is %.1f s long and its video %.1f s.", audioSeconds, videoSeconds))
        }
        guard rawSeconds.isFinite, mixedSeconds.isFinite, abs(rawSeconds - mixedSeconds) <= 1 else {
            throw RecordingError(String(format: "The mixed recording is %.1f s long, the recording %.1f s.", mixedSeconds, rawSeconds))
        }
        let rawVideoSeconds = CMTimeGetSeconds(try await raw.loadTracks(withMediaType: .video).first?.load(.timeRange).duration ?? .zero)
        guard videoSeconds.isFinite, videoSeconds >= rawVideoSeconds - 1 else {
            throw RecordingError("The video of the mixed recording is shorter than the recording.")
        }
        // Tracks in the order they were added to the file: system audio, then microphone
        let rawAudio = try await raw.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var rawAudioSeconds = 0.0
        for track in rawAudio { rawAudioSeconds = max(rawAudioSeconds, CMTimeGetSeconds(try await track.load(.timeRange).duration)) }
        guard audioSeconds.isFinite, audioSeconds >= rawAudioSeconds - 1 else {
            throw RecordingError("The audio of the mixed recording is shorter than the recording.")
        }
        guard rawAudio.count == 2 else { return }
        try checkMicrophone(system: rawAudio[0], microphone: rawAudio[1], in: raw, mixed: mixedAudio, in: mixed, seconds: rawSeconds)
    }

    /// Throws unless `output`, an audio file converted from the audio file `source`, opens and is as long as
    /// `source` to within a second. The MP3 encoder does not report a failed write, so an empty or cut-off file
    /// is only found here.
    static func verifyConversion(source: URL, output: URL) throws {
        func seconds(_ url: URL) -> Double? {
            guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
            return Double(file.length) / file.fileFormat.sampleRate
        }
        guard let outputSeconds = seconds(output), outputSeconds > 0 else { throw RecordingError("The converted file was not written completely.") }
        guard let sourceSeconds = seconds(source) else { throw RecordingError("The recording cannot be read to check the converted file.") }
        guard abs(outputSeconds - sourceSeconds) <= 1 else {
            throw RecordingError(String(format: "The converted file is %.1f s long, the recording %.1f s.", outputSeconds, sourceSeconds))
        }
    }

    /// A sound below this (-60 dBFS) counts as silence
    private static let silence = 0.001

    /// Looks at up to 30 one-second windows spread over the recording. Where the microphone has sound and system
    /// audio has next to none, the mix must have sound of about the microphone's level. Throws when it does not in
    /// half of those windows or more. A recording without such a window passes: there is nothing to tell from.
    private static func checkMicrophone(system: AVAssetTrack, microphone: AVAssetTrack, in raw: AVAsset, mixed: AVAssetTrack, in mixedAsset: AVAsset, seconds: Double) throws {
        let count = min(30, Int(seconds))
        guard count > 0 else { return }
        var microphoneOnly = 0
        var missing = 0
        for index in 0..<count {
            let middle = (Double(index) + 0.5) * seconds / Double(count)
            let range = CMTimeRange(start: CMTime(seconds: max(0, middle - 0.5), preferredTimescale: 48000), duration: CMTime(seconds: 1, preferredTimescale: 48000))
            let microphoneLevel = try level(of: microphone, in: raw, range: range)
            guard microphoneLevel > silence else { continue }
            guard try level(of: system, in: raw, range: range) < microphoneLevel / 4 else { continue }
            microphoneOnly += 1
            if try level(of: mixed, in: mixedAsset, range: range) < microphoneLevel / 4 { missing += 1 }
        }
        print("Mix check: \(count) windows, \(microphoneOnly) with the microphone alone, \(missing) of them without it in the mix")
        if microphoneOnly > 0 && missing * 2 >= microphoneOnly {
            throw RecordingError("The microphone is in the recording but cannot be heard in the mixed audio.")
        }
    }

    /// RMS level of all channels of `track` within `range`, 1 being full scale
    private static func level(of track: AVAssetTrack, in asset: AVAsset, range: CMTimeRange) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingError("The audio cannot be read to check the mix.") }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { throw reader.error ?? RecordingError("The audio cannot be read to check the mix.") }
        var sum = 0.0
        var count = 0
        var samples = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = buffer.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard length > 0 else { continue }
            if samples.count < length { samples = [Float](repeating: 0, count: length) }
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length * MemoryLayout<Float>.size, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for i in 0..<length { sum += Double(samples[i]) * Double(samples[i]) }
            count += length
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError("The audio cannot be read to check the mix.") }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    // MARK: - Leftovers of an earlier run

    /// What can be told about a leftover recording by opening it
    struct Inspection {
        /// Nil when the file does not open
        let seconds: Double?
        /// Whether the file is still laid out for fragments, as it is recorded: its header announces them
        /// (`canContainFragments`), also before the first fragment after the header was written. Closing it rewrites
        /// it as an ordinary movie. (`containsFragments` is false for a file cut off within its first fragment.)
        let fragmented: Bool
        /// One video track and two audio tracks
        let mixable: Bool
    }

    static func inspect(_ url: URL) async -> Inspection {
        let asset = AVURLAsset(url: url)
        guard let (playable, duration) = try? await asset.load(.isPlayable, .duration), playable else {
            return Inspection(seconds: nil, fragmented: true, mixable: false)
        }
        let length = CMTimeGetSeconds(duration)
        guard length.isFinite, length > 0 else { return Inspection(seconds: nil, fragmented: true, mixable: false) }
        // When in doubt the file counts as not closed
        let fragmented = (try? await asset.load(.canContainFragments)) ?? true
        let video = (try? await asset.loadTracks(withMediaType: .video).count) ?? 0
        let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        return Inspection(seconds: length, fragmented: fragmented, mixable: video == 1 && audio == 2)
    }
}
