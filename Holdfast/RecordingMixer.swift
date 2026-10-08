//
//  RecordingMixer.swift
//  Holdfast
//

import AVFoundation
import Foundation

/// The audio mix that follows a video recording with system audio and a microphone, or with the process tap and its
/// backup, and what can be told about a recording an earlier run left behind by opening it. The names of the files
/// are `RecordingFileStore`'s.
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
    /// What the tracks are read as: 48 kHz stereo float, interleaved
    private static var trackSettings: [String: Any] {
        var settings = pcmSettings
        settings[AVSampleRateKey] = 48000
        settings[AVNumberOfChannelsKey] = 2
        return settings
    }
    static let sampleRate = 48000.0

    /// The audio tracks of a recording: the system audio (the tap's, when there is a backup), the backup of the
    /// system audio, the microphone. Told by their titles (`MovieWriter.TrackTitle`); in a file without titles, one
    /// written before there were any, by their order: system audio, then microphone.
    struct Layout {
        var system: AVAssetTrack?
        var backup: AVAssetTrack?
        var microphone: AVAssetTrack?

        static func read(_ tracks: [AVAssetTrack]) async throws -> Layout {
            let ordered = tracks.sorted { $0.trackID < $1.trackID }
            var layout = Layout()
            var titled = false
            for track in ordered {
                guard let title = try await RecordingMixer.title(of: track) else { continue }
                titled = true
                switch title {
                case MovieWriter.TrackTitle.system, MovieWriter.TrackTitle.tap: layout.system = track
                case MovieWriter.TrackTitle.backup: layout.backup = track
                case MovieWriter.TrackTitle.microphone: layout.microphone = track
                default: break
                }
            }
            guard !titled else { return layout }
            switch ordered.count {
            case 1: return Layout(system: ordered[0])
            case 2: return Layout(system: ordered[0], microphone: ordered[1])
            case 3: return Layout(system: ordered[0], backup: ordered[1], microphone: ordered[2])
            default: return layout
            }
        }

        /// The tracks there are, in the order the writer adds them
        var all: [AVAssetTrack] { [system, backup, microphone].compactMap { $0 } }
    }

    /// The title a track was written with, nil when it has none
    static func title(of track: AVAssetTrack) async throws -> String? {
        for item in try await track.load(.commonMetadata) where item.commonKey == .commonKeyTitle {
            if let title = try await item.load(.stringValue) { return title }
        }
        return nil
    }

    /// What a mix did with the system audio: which source each stretch came from (`SystemAudioChoice`; empty when
    /// the recording has no backup and its system audio track is taken throughout), and whether the microphone was
    /// kept as a track of its own
    struct MixPlan {
        var segments: [SystemAudioChoice.Segment]
        var separateMicrophone: Bool
        /// How far the tap's audio was from the backup's, and so how far the mix moved it; nil without a backup
        var alignment: SystemAudioAlignment.Measurement?
        /// What "Level Voices" did: each side's loudness and gain and the limiter's work; nil when the mix is the
        /// plain sum of the tracks
        var leveling: VoiceLeveling.Applied?

        /// The sources of the system audio from `start` to `end` seconds
        func sources(from start: Double, to end: Double) -> Set<SystemAudioChoice.Source> {
            guard !segments.isEmpty else { return [.tap] }
            return Set(segments.filter { $0.end > start && $0.start < end }.map(\.source))
        }
    }

    /// Writes `source` to `output` in one pass: the video samples are copied as they are, and the audio tracks are
    /// mixed into one track encoded with `audioSettings`. With the process tap's backup on a track of its own, the
    /// system audio is the tap's or the backup's stretch by stretch, never both (`SystemAudioChoice`, from the tap's
    /// recorded `tapSpans`, nil when they are not known), with the tap's audio moved onto the backup's timeline by
    /// what the two tracks' sound says they are apart (`SystemAudioAlignment`; not moved when that cannot be
    /// measured); with `separateMicrophone` the microphone is not mixed in but copied as a second audio track.
    /// With `levelVoices` each side (the system audio as the mix takes it, the microphone) is first measured over the
    /// whole recording and gets one gain towards `VoiceLeveling.target`, and their sum goes through `PeakLimiter`;
    /// not with the microphone kept apart, whose track is copied as it was recorded. Without it the mix is the plain
    /// sum of the tracks. `progress` gets a value from 0 to 1, on a background queue. `source` is
    /// only read. Returns what was done with the system audio; when this throws, `output` is missing or incomplete.
    @discardableResult
    static func mix(source: URL, output: URL, fileType: AVFileType, audioSettings: [String: Any], tapSpans: TapSpans? = nil,
                    separateMicrophone: Bool = false, levelVoices: Bool = false, progress: @escaping (Double) -> Void) async throws -> MixPlan {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, videoTracks.count == 1 else { throw RecordingError("The recording has no video track.") }
        let layout = try await Layout.read(audioTracks)
        guard audioTracks.count > 1, let system = layout.system, layout.backup != nil || layout.microphone != nil else {
            throw RecordingError("The recording does not have two audio tracks to mix.")
        }
        let separate = separateMicrophone && layout.backup != nil && layout.microphone != nil
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw RecordingError("The recording is empty.") }
        let transform = try await videoTrack.load(.preferredTransform)
        guard let videoFormat = try await videoTrack.load(.formatDescriptions).first else { throw RecordingError("The video track has no format.") }

        // Which source of the system audio each stretch takes
        var plan = MixPlan(segments: [], separateMicrophone: separate)
        var tapGain: GainCurve?
        // How many frames earlier the tap's audio goes into the mix than it is in its track
        var tapShift: Int64 = 0
        if let backup = layout.backup {
            let chosen = try await choose(tap: system, backup: backup, in: asset, spans: tapSpans)
            plan.segments = chosen.segments
            plan.alignment = chosen.alignment
            tapShift = Int64(((chosen.alignment.offset ?? 0) * sampleRate).rounded())
            tapGain = SystemAudioChoice.tapGain(for: plan.segments)
            RecLog.write("System audio alignment: " + chosen.alignment.text)
            RecLog.write("System audio in the mix: " + SystemAudioChoice.summary(plan.segments) + (tapSpans == nil ? " (the tap's spans were not known: it counts as alive throughout)" : ""))
        }

        // Up to the end of the longest track that goes into the mix
        var end = 0.0
        for track in [system, layout.backup, separate ? nil : layout.microphone].compactMap({ $0 }) {
            // The tap's track where the mix has it
            let moved = track === system ? Double(tapShift) / sampleRate : 0
            end = max(end, CMTimeGetSeconds(try await track.load(.timeRange).end) - moved)
        }
        let frames = Int64((end * sampleRate).rounded())

        // How loud each side is, and with that its gain; the microphone kept apart is copied, not mixed
        var leveling: VoiceLeveling.Applied?
        if levelVoices && !separate {
            let measured = try loudness(of: asset, system: system, backup: layout.backup, microphone: layout.microphone, tapShift: tapShift, tapGain: tapGain, frames: frames)
            leveling = VoiceLeveling.Applied(system: VoiceLeveling.Side(measured.system), microphone: measured.microphone.map { VoiceLeveling.Side($0) })
        }
        let systemScale = leveling?.system.factor ?? 1
        let microphoneScale = leveling?.microphone?.factor ?? 1

        let reader = try AVAssetReader(asset: asset)
        // No output settings: the compressed frames are handed over as they are in the file
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw RecordingError("The recording cannot be read for mixing.") }
        reader.add(videoOutput)
        var parts = [MixedAudio.Part]()
        func pcm(_ track: AVAssetTrack, earlier: Int64 = 0) throws -> TrackPCM {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: trackSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw RecordingError("The recording cannot be read for mixing.") }
            reader.add(output)
            return TrackPCM(output, earlier: earlier)
        }
        parts.append(MixedAudio.Part(track: try pcm(system, earlier: tapShift), gain: tapGain, complement: false, scale: systemScale))
        if let backup = layout.backup { parts.append(MixedAudio.Part(track: try pcm(backup), gain: tapGain, complement: true, scale: systemScale)) }
        var microphoneOutput: AVAssetReaderTrackOutput?
        var microphoneFormat: CMFormatDescription?
        if let microphone = layout.microphone {
            if separate {
                let output = AVAssetReaderTrackOutput(track: microphone, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw RecordingError("The recording cannot be read for mixing.") }
                reader.add(output)
                microphoneOutput = output
                microphoneFormat = try await microphone.load(.formatDescriptions).first
            } else {
                parts.append(MixedAudio.Part(track: try pcm(microphone), gain: nil, complement: false, scale: microphoneScale))
            }
        }
        guard let mixed = MixedAudio(parts: parts, frames: frames, limiter: leveling == nil ? nil : PeakLimiter(rate: sampleRate)) else {
            throw RecordingError("The audio could not be mixed.")
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw RecordingError("The mixed recording cannot be written in this format.") }
        writer.add(videoInput)
        writer.add(audioInput)
        var pairs: [(next: () -> CMSampleBuffer?, input: AVAssetWriterInput)] = [
            ({ videoOutput.copyNextSampleBuffer() }, videoInput),
            ({ mixed.next() }, audioInput),
        ]
        if let microphoneOutput {
            audioInput.metadata = [MovieWriter.titleItem(MovieWriter.TrackTitle.system)]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: microphoneFormat)
            input.expectsMediaDataInRealTime = false
            input.metadata = [MovieWriter.titleItem(MovieWriter.TrackTitle.microphone)]
            guard writer.canAdd(input) else { throw RecordingError("The mixed recording cannot be written in this format.") }
            writer.add(input)
            pairs.append(({ microphoneOutput.copyNextSampleBuffer() }, input))
        }

        guard reader.startReading() else { throw reader.error ?? RecordingError("The recording could not be read.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? RecordingError("The mixed recording could not be created.")
        }
        writer.startSession(atSourceTime: .zero)

        var lastPercent = -1
        let copied = await copy(pairs, reader: reader, writer: writer) { buffer, index in
            guard index == 0 else { return }
            let percent = Int(max(0, min(1, CMTimeGetSeconds(buffer.presentationTimeStamp) / seconds)) * 100)
            // Video samples come in decoding order, so their times do not only go up
            if percent > lastPercent {
                lastPercent = percent
                progress(Double(percent) / 100)
            }
        }
        // Every state but "completed" is a failure: failed, cancelled, and anything unexpected
        guard copied == nil, reader.status == .completed, !mixed.failed else {
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
        if var applied = leveling {
            applied.limiterReduction = mixed.limiterReduction
            plan.leveling = applied
            RecLog.write("Level Voices: " + applied.text)
        }
        progress(1)
        return plan
    }

    /// The loudness of each side of a recording over its whole length, as the mix takes them: the system audio from
    /// the tap (moved by `tapShift`) and its backup by `tapGain`, and the microphone. One pass over the tracks, a
    /// piece at a time.
    private static func loudness(of asset: AVAsset, system: AVAssetTrack, backup: AVAssetTrack?, microphone: AVAssetTrack?, tapShift: Int64,
                                 tapGain: GainCurve?, frames: Int64) throws -> (system: LoudnessMeter.Reading, microphone: LoudnessMeter.Reading?) {
        let reader = try AVAssetReader(asset: asset)
        func pcm(_ track: AVAssetTrack, earlier: Int64 = 0) throws -> TrackPCM {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: trackSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw RecordingError("The audio cannot be read to measure its loudness.") }
            reader.add(output)
            return TrackPCM(output, earlier: earlier)
        }
        var systemParts = [MixedAudio.Part(track: try pcm(system, earlier: tapShift), gain: tapGain, complement: false)]
        if let backup { systemParts.append(MixedAudio.Part(track: try pcm(backup), gain: tapGain, complement: true)) }
        let microphoneParts = try microphone.map { [MixedAudio.Part(track: try pcm($0), gain: nil, complement: false)] }
        guard let systemSum = MixedAudio(parts: systemParts, frames: frames) else { throw RecordingError("The audio cannot be read to measure its loudness.") }
        var microphoneSum: MixedAudio?
        if let microphoneParts {
            guard let sum = MixedAudio(parts: microphoneParts, frames: frames) else { throw RecordingError("The audio cannot be read to measure its loudness.") }
            microphoneSum = sum
        }
        guard reader.startReading() else { throw reader.error ?? RecordingError("The audio cannot be read to measure its loudness.") }
        var systemMeter = LoudnessMeter(rate: sampleRate, channels: 2)
        var microphoneMeter = LoudnessMeter(rate: sampleRate, channels: 2)
        // Piece by piece from both, so that neither track is read far ahead of the other
        var more = true
        while more {
            more = systemSum.sum { systemMeter.add($0, frames: $1) }
            if let microphoneSum, microphoneSum.sum({ microphoneMeter.add($0, frames: $1) }) { more = true }
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError("The audio cannot be read to measure its loudness.") }
        return (systemMeter.reading, microphoneSum == nil ? nil : microphoneMeter.reading)
    }

    /// Which source each stretch of the system audio takes, from the tap's spans and the levels of the tap's and the
    /// backup's tracks, and how far apart the two tracks hold the same sound (not measured without `align`: then the
    /// stretches are on the timeline of the tracks as they are)
    private static func choose(tap: AVAssetTrack, backup: AVAssetTrack, in asset: AVAsset, spans: TapSpans?,
                               align: Bool = true) async throws -> (segments: [SystemAudioChoice.Segment], alignment: SystemAudioAlignment.Measurement) {
        let tapLevels = try blockLevels(of: tap, in: asset)
        let backupLevels = try blockLevels(of: backup, in: asset)
        let end = max(CMTimeGetSeconds(try await tap.load(.timeRange).end), CMTimeGetSeconds(try await backup.load(.timeRange).end))
        var alignment = SystemAudioAlignment.Measurement.none
        if align {
            alignment = try SystemAudioAlignment.measure(tap: tapLevels, backup: backupLevels, duration: end, rate: sampleRate) { source, first, count in
                try samples(of: source == .tap ? tap : backup, in: asset, from: first, count: count)
            }
        }
        let segments = SystemAudioChoice.plan(tap: tapLevels, backup: backupLevels, spans: spans, duration: end, offset: alignment.offset ?? 0)
        return (segments, alignment)
    }

    /// `count` frames of a track from frame `first` on (which may be before its start), the two channels added up
    /// to one, each buffer at its own time; silence where the track has nothing
    private static func samples(of track: AVAssetTrack, in asset: AVAsset, from first: Int64, count: Int) throws -> [Float] {
        var mono = [Float](repeating: 0, count: max(0, count))
        let start = max(0, first), end = first + Int64(count)
        guard end > start else { return mono }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: trackSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingError("The audio cannot be read to compare its sources.") }
        reader.add(output)
        let scale = CMTimeScale(sampleRate)
        reader.timeRange = CMTimeRange(start: CMTime(value: start, timescale: scale), duration: CMTime(value: end - start, timescale: scale))
        guard reader.startReading() else { throw reader.error ?? RecordingError("The audio cannot be read to compare its sources.") }
        var incoming = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let frames = TrackPCM.copy(buffer, into: &incoming) else { continue }
            let at = Int64((CMTimeGetSeconds(buffer.presentationTimeStamp) * sampleRate).rounded()) - first
            for frame in 0..<frames {
                let index = at + Int64(frame)
                if index >= 0 && index < Int64(count) { mono[Int(index)] = incoming[frame * 2] + incoming[frame * 2 + 1] }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError("The audio cannot be read to compare its sources.") }
        return mono
    }

    /// The RMS level of a track, all channels, every `SystemAudioChoice.block` seconds from the start of the file
    static func blockLevels(of track: AVAssetTrack, in asset: AVAsset) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: trackSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingError("The audio cannot be read to choose its sources.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecordingError("The audio cannot be read to choose its sources.") }
        var levels = BlockLevels(rate: sampleRate)
        var samples = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let count = TrackPCM.copy(buffer, into: &samples) else { continue }
            let first = Int64((CMTimeGetSeconds(buffer.presentationTimeStamp) * sampleRate).rounded())
            samples.withUnsafeBufferPointer { levels.add($0, frames: count, channels: 2, at: first) }
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError("The audio cannot be read to choose its sources.") }
        return levels.finish()
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

    /// Moves every sample of each source (a reader output, the mixed audio) to its writer input. Returns nil when all of them have reached
    /// their end, and what went wrong otherwise: at once when an append fails, and from a watchdog when the writer
    /// or the reader has failed or no sample has moved for `stallLimit` seconds. The copy runs on one serial queue,
    /// which owns its bookkeeping. The watchdog runs on another, because a read that hangs would hold up the first;
    /// without it a writer that stops asking for data would leave the caller waiting for ever.
    private static func copy(_ pairs: [(next: () -> CMSampleBuffer?, input: AVAssetWriterInput)], reader: AVAssetReader, writer: AVAssetWriter, each: @escaping (CMSampleBuffer, Int) -> Void) async -> String? {
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
                    pairs[index].input.markAsFinished()
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
                let (next, input) = pair
                input.requestMediaDataWhenReady(on: queue) {
                    while !ended[index] && !state.isOver && input.isReadyForMoreMediaData {
                        guard let buffer = next() else {
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

    /// The system audio of a sound-only recording made with the process tap, from its two files: the tap's (`tap`)
    /// and the backup's (`backup`), each stretch from the source `SystemAudioChoice` takes (`spans` where the tap
    /// delivered, nil when not known), the tap's moved onto the backup's timeline by what `SystemAudioAlignment`
    /// measures between them, written to `output` with `settings`, as long as the longer file. Returns
    /// the stretches; throws, leaving `output` incomplete, when it cannot be written or is not as long as the tap's
    /// file. Blocks while it renders, so not on the main thread.
    @discardableResult
    static func mergeSystemAudio(tap: URL, backup: URL, spans: TapSpans?, to output: URL, settings: [String: Any]) throws -> [SystemAudioChoice.Segment] {
        let files = try [tap, backup].map { try AVAudioFile(forReading: $0) }
        let format = files[0].processingFormat
        guard files[1].processingFormat == format, format.channelCount > 0, !format.isInterleaved else {
            throw RecordingError("The two system audio files are not in the same format.")
        }
        let readBuffers = try files.map { _ in try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)) }
        // The levels, then the plan
        var levels = [[Float]]()
        for (file, buffer) in zip(files, readBuffers) {
            var blocks = BlockLevels(rate: format.sampleRate)
            var interleaved = [Float]()
            while file.framePosition < file.length {
                let first = file.framePosition
                try file.read(into: buffer, frameCount: 4096)
                guard buffer.frameLength > 0 else { break }
                interleave(buffer, into: &interleaved)
                interleaved.withUnsafeBufferPointer { blocks.add($0, frames: Int(buffer.frameLength), channels: Int(format.channelCount), at: first) }
            }
            levels.append(blocks.finish())
        }
        // How far apart the two files hold the same sound; the tap's goes into the merged file that much earlier
        let alignment = try SystemAudioAlignment.measure(tap: levels[0], backup: levels[1], duration: Double(max(files[0].length, files[1].length)) / format.sampleRate,
                                                         rate: format.sampleRate) { source, first, count in
            try samples(of: files[source == .tap ? 0 : 1], into: readBuffers[source == .tap ? 0 : 1], from: first, count: count)
        }
        let shift = AVAudioFramePosition(((alignment.offset ?? 0) * format.sampleRate).rounded())
        let frames = max(files[0].length - shift, files[1].length)
        let segments = SystemAudioChoice.plan(tap: levels[0], backup: levels[1], spans: spans, duration: Double(frames) / format.sampleRate, offset: Double(shift) / format.sampleRate)
        let curve = SystemAudioChoice.tapGain(for: segments)
        RecLog.write("System audio alignment: " + alignment.text)
        RecLog.write("System audio of the sound-only recording: " + SystemAudioChoice.summary(segments) + (spans == nil ? " (the tap's spans were not known: it counts as alive throughout)" : ""))
        // The merge
        let outputFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let mixed = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var gains = [Float]()
        var cursor = 0
        var position: AVAudioFramePosition = 0
        while position < frames {
            let count = AVAudioFrameCount(min(4096, frames - position))
            // Where each file's frames begin in this piece, and how many it has for it
            var leads = [Int](), counts = [Int]()
            for (index, (file, buffer)) in zip(files, readBuffers).enumerated() {
                let from = position + (index == 0 ? shift : 0)
                let first = max(0, from), end = min(file.length, from + AVAudioFramePosition(count))
                buffer.frameLength = 0
                if end > first {
                    // Read on from where the last piece ended: a seek only when the file is not there
                    if file.framePosition != first { file.framePosition = first }
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(end - first))
                }
                leads.append(Int(first - from))
                counts.append(Int(buffer.frameLength))
            }
            curve.values(from: position, count: Int(count), rate: format.sampleRate, cursor: &cursor, into: &gains)
            mixed.frameLength = count
            guard let out = mixed.floatChannelData, let tapData = readBuffers[0].floatChannelData, let backupData = readBuffers[1].floatChannelData else {
                throw RecordingError("The system audio could not be merged.")
            }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(count) {
                    let tapFrame = frame - leads[0], backupFrame = frame - leads[1]
                    let fromTap = tapFrame >= 0 && tapFrame < counts[0] ? tapData[channel][tapFrame] : 0
                    let fromBackup = backupFrame >= 0 && backupFrame < counts[1] ? backupData[channel][backupFrame] : 0
                    out[channel][frame] = gains[frame] * fromTap + (1 - gains[frame]) * fromBackup
                }
            }
            try outputFile.write(from: mixed)
            position += AVAudioFramePosition(count)
        }
        outputFile.close()
        try verifyConversion(source: files[0].length >= files[1].length ? tap : backup, output: output)
        return segments
    }

    /// `count` frames of an audio file from frame `first` on (which may be before its start), its channels added up to
    /// one; silence where the file has nothing. `buffer` is what it reads through.
    private static func samples(of file: AVAudioFile, into buffer: AVAudioPCMBuffer, from first: Int64, count: Int) throws -> [Float] {
        var mono = [Float](repeating: 0, count: max(0, count))
        var position = max(0, first)
        let end = min(file.length, first + Int64(count))
        while position < end {
            if file.framePosition != position { file.framePosition = position }
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), end - position)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames { mono[Int(position - first) + frame] += data[channel][frame] }
            }
            position += Int64(frames)
        }
        return mono
    }

    /// The frames of a non-interleaved buffer, one after the other with their channels side by side
    private static func interleave(_ buffer: AVAudioPCMBuffer, into samples: inout [Float]) {
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        if samples.count < channels * frames { samples = [Float](repeating: 0, count: channels * frames) }
        guard let data = buffer.floatChannelData else { return }
        for frame in 0..<frames {
            for channel in 0..<channels { samples[frame * channels + channel] = data[channel][frame] }
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw RecordingError("The audio could not be mixed.") }
        return value
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

    /// Throws unless `output` is a complete mix of `source`: one video and one audio track (two with the
    /// microphone kept separate, `plan`), whose lengths differ by `maxAudioVideoDifference` at most (the audio of an
    /// `unfinished` recording, one never closed, may be up to `unfinishedAudioShortfall` shorter), as long as the
    /// source to within a second, with the microphone audible where only the microphone had sound, and the system
    /// audio at the level of the source the plan took for it where only it had sound: neither missing nor doubled.
    /// With "Level Voices" (`plan.leveling`) those levels are the tracks' times the gains the mix gave them.
    /// `plan` is what the mix returned; without it the system audio's sources are chosen again.
    static func verify(source: URL, output: URL, unfinished: Bool = false, plan: MixPlan? = nil) async throws {
        guard FileManager.default.fileExists(atPath: output.path) else { throw RecordingError("The mixed recording was not written.") }
        let raw = AVURLAsset(url: source)
        let mixed = AVURLAsset(url: output)
        let video = try await mixed.loadTracks(withMediaType: .video)
        let audio = try await mixed.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        let separate = plan?.separateMicrophone ?? false
        guard video.count == 1, let mixedAudio = audio.first, audio.count == (separate ? 2 : 1) else {
            throw RecordingError(separate ? "The mixed recording does not have one video and two audio tracks." : "The mixed recording does not have one video and one audio track.")
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
        let layout = try await Layout.read(try await raw.loadTracks(withMediaType: .audio))
        var rawAudioSeconds = 0.0
        for track in layout.all { rawAudioSeconds = max(rawAudioSeconds, CMTimeGetSeconds(try await track.load(.timeRange).duration)) }
        guard audioSeconds.isFinite, audioSeconds >= rawAudioSeconds - 1 else {
            throw RecordingError("The audio of the mixed recording is shorter than the recording.")
        }
        guard let system = layout.system else { return }
        var used = plan ?? MixPlan(segments: [], separateMicrophone: false)
        if plan == nil, let backup = layout.backup {
            used.segments = try await choose(tap: system, backup: backup, in: raw, spans: nil, align: false).segments
        }
        try checkLevels(layout, in: raw, mixed: mixedAudio, in: mixed, plan: used, seconds: rawSeconds)
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
    /// How far the system audio in the mix may be from the level of its source where only it has sound: half of it
    /// is missing it, one and a half times it is the same sound twice (two sources of one sound add up to twice the
    /// level)
    private static let systemLevelRange = 0.5...1.5

    /// Looks at up to 30 one-second windows spread over the recording. Where the microphone has sound and system
    /// audio has next to none, the mix must have sound of about the microphone's level. Where the system audio has
    /// sound from one source (the tap's or the backup's, as the plan took it) and the microphone next to none, the
    /// mix must have it at its level: not missing, as a dead tap would leave it, and not twice. Throws when either
    /// fails in half of its windows or more. A recording without such windows passes: there is nothing to tell from.
    /// A mix made with "Level Voices" is held to the same, with each side at the level its gain gives it; where
    /// the peaks of a window, at those gains, are over the limiter's ceiling, the mix may be lower by as much as
    /// the limiter can have taken off there and no more.
    private static func checkLevels(_ layout: Layout, in raw: AVAsset, mixed: AVAssetTrack, in mixedAsset: AVAsset, plan: MixPlan, seconds: Double) throws {
        guard let system = layout.system else { return }
        let count = min(30, Int(seconds))
        guard count > 0 else { return }
        // The microphone counts against the mix's track only when it is mixed into it
        let microphone = plan.separateMicrophone ? nil : layout.microphone
        var microphoneOnly = 0, microphoneMissing = 0
        var systemOnly = 0, systemWrong = 0
        // The gains "Level Voices" gave the two sides, 1 without it
        let systemFactor = Double(plan.leveling?.system.factor ?? 1), microphoneFactor = Double(plan.leveling?.microphone?.factor ?? 1)
        for index in 0..<count {
            let middle = (Double(index) + 0.5) * seconds / Double(count)
            let start = max(0, middle - 0.5)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000), duration: CMTime(seconds: 1, preferredTimescale: 48000))
            let sources = plan.sources(from: start, to: start + 1)
            var systemLevel = Level()
            if sources.contains(.tap) { systemLevel = try level(of: system, in: raw, range: range) }
            if sources.contains(.backup), let backup = layout.backup {
                let level = try level(of: backup, in: raw, range: range)
                systemLevel = Level(rms: max(systemLevel.rms, level.rms), peak: max(systemLevel.peak, level.peak))
            }
            let microphoneLevel = try microphone.map { try level(of: $0, in: raw, range: range) } ?? Level()
            let mixedLevel = try level(of: mixed, in: mixedAsset, range: range).rms
            // What each side is in the mix
            let systemInMix = systemLevel.rms * systemFactor, microphoneInMix = microphoneLevel.rms * microphoneFactor
            // The least of it the limiter can have left
            var kept = 1.0
            if plan.leveling != nil {
                let peak = systemLevel.peak * systemFactor + microphoneLevel.peak * microphoneFactor
                if peak > PeakLimiter.ceiling { kept = PeakLimiter.ceiling / peak }
            }
            if microphoneLevel.rms > silence && systemInMix < microphoneInMix / 4 {
                microphoneOnly += 1
                if mixedLevel < microphoneInMix / 4 * kept { microphoneMissing += 1 }
            }
            if sources.count == 1 && systemLevel.rms > silence && microphoneInMix < systemInMix / 4 {
                systemOnly += 1
                if !((systemLevelRange.lowerBound * kept)...systemLevelRange.upperBound).contains(mixedLevel / systemInMix) { systemWrong += 1 }
            }
        }
        print("Mix check: \(count) windows, \(microphoneOnly) with the microphone alone, \(microphoneMissing) of them without it in the mix; \(systemOnly) with system audio alone, \(systemWrong) of them not at its level in the mix")
        if microphoneOnly > 0 && microphoneMissing * 2 >= microphoneOnly {
            throw RecordingError("The microphone is in the recording but cannot be heard in the mixed audio.")
        }
        if systemOnly > 0 && systemWrong * 2 >= systemOnly {
            throw RecordingError("The system audio is in the recording but the mixed audio does not have it at its level.")
        }
    }

    /// How loud a stretch of a track is, 1 being full scale: the RMS of all its channels, and its largest sample
    private struct Level {
        var rms = 0.0
        var peak = 0.0
    }

    /// The level of all channels of `track` within `range`
    private static func level(of track: AVAssetTrack, in asset: AVAsset, range: CMTimeRange) throws -> Level {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingError("The audio cannot be read to check the mix.") }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { throw reader.error ?? RecordingError("The audio cannot be read to check the mix.") }
        var sum = 0.0
        var count = 0
        var peak: Float = 0
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
            for i in 0..<length {
                sum += Double(samples[i]) * Double(samples[i])
                peak = max(peak, abs(samples[i]))
            }
            count += length
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingError("The audio cannot be read to check the mix.") }
        return Level(rms: count > 0 ? (sum / Double(count)).squareRoot() : 0, peak: Double(peak))
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
        /// One video track and two or three audio tracks
        let mixable: Bool
        /// How many audio tracks it has
        var audioTracks = 0
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
        return Inspection(seconds: length, fragmented: fragmented, mixable: video == 1 && (2...3).contains(audio), audioTracks: audio)
    }
}

/// One audio track read as 48 kHz stereo float, interleaved, by the frame: `add` puts the frames of a range into a
/// mix, each by its gain, placing every buffer the reader hands over at its own time (the tap's track `earlier`
/// frames before it, where the backup has the same sound). Frames the track does not have
/// (before its first buffer, after its end) count as silence. Used on one queue at a time.
final class TrackPCM {
    private let output: AVAssetReaderTrackOutput
    /// Frames from `start` on, from index `head`, two values a frame
    private var samples = [Float]()
    private var head = 0
    private var start: Int64 = 0
    private var started = false
    private var ended = false
    private var incoming = [Float]()
    /// How many frames earlier than its buffers say the track goes into the mix
    private let earlier: Int64

    init(_ output: AVAssetReaderTrackOutput, earlier: Int64 = 0) {
        self.output = output
        self.earlier = earlier
    }

    /// Copies the samples of an interleaved stereo float buffer into `samples` (made large enough); returns how many
    /// frames it has, nil when it has none
    static func copy(_ buffer: CMSampleBuffer, into samples: inout [Float]) -> Int? {
        guard let block = buffer.dataBuffer else { return nil }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count >= 2 else { return nil }
        if samples.count < count { samples = [Float](repeating: 0, count: count) }
        let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
        }
        return status == kCMBlockBufferNoErr ? count / 2 : nil
    }

    private var available: Int { (samples.count - head) / 2 }

    /// Reads what is left of the track, which the mix does not need
    func drain() {
        while !ended {
            if output.copyNextSampleBuffer() == nil { ended = true }
        }
        samples = []
        head = 0
    }

    /// Adds the frames `from` to `from + count` of the track, each times `gains[i]` (1 without gains), into `mix`
    /// (interleaved stereo, `count` frames). Frames before `from` are let go: the mix only goes forward.
    func add(into mix: inout [Float], from: Int64, count: Int, gains: [Float]?) {
        let needed = from + Int64(count)
        while !ended && (!started || start + Int64(available) < needed) {
            guard let buffer = output.copyNextSampleBuffer() else {
                ended = true
                break
            }
            guard let frames = TrackPCM.copy(buffer, into: &incoming) else { continue }
            let first = Int64((CMTimeGetSeconds(buffer.presentationTimeStamp) * RecordingMixer.sampleRate).rounded()) - earlier
            if !started {
                started = true
                start = first
            }
            let expected = start + Int64(available)
            var skip = 0
            if first > expected {
                samples.append(contentsOf: repeatElement(0, count: Int(first - expected) * 2))
            } else if first < expected {
                skip = Int(min(Int64(frames), expected - first))
            }
            if skip < frames { samples.append(contentsOf: incoming[(skip * 2)..<(frames * 2)]) }
        }
        guard started else { return }
        if from > start {
            let drop = Int(min(from - start, Int64(available)))
            head += drop * 2
            start += Int64(drop)
            if head > 65536 {
                samples.removeFirst(head)
                head = 0
            }
        }
        let offset = Int(min(Int64(count), max(0, start - from)))
        let frames = min(count - offset, available)
        guard frames > 0 else { return }
        samples.withUnsafeBufferPointer { source in
            for index in 0..<frames {
                let gain = gains?[offset + index] ?? 1
                let at = (offset + index) * 2, from = head + index * 2
                mix[at] += source[from] * gain
                mix[at + 1] += source[from + 1] * gain
            }
        }
    }
}

/// The mixed audio track, made `chunk` frames at a time from the parts: each track at its gain over time (the
/// backup at one minus the tap's) and its `scale`, added up, as sample buffers of 48 kHz stereo float. With a
/// limiter the sum goes through it, and comes out where it went in: the limiter's delay is left out at the start
/// and made up at the end.
final class MixedAudio {
    struct Part {
        let track: TrackPCM
        /// Nil: the whole track
        let gain: GainCurve?
        /// Whether the part takes one minus `gain`
        let complement: Bool
        /// The part's level for the whole recording ("Level Voices"), 1 as recorded
        var scale: Float = 1
    }

    static let chunk = 4096
    private let parts: [Part]
    private let frames: Int64
    private let format: AVAudioFormat
    private var position: Int64 = 0
    private var cursors: [Int]
    private var gains = [Float]()
    private var mix = [Float]()
    private var limiter: PeakLimiter?
    /// Frames the limiter has returned that are still to be left out (its delay) and whether its last ones were asked for
    private var leftOut = 0
    private var flushed = false
    /// Limited frames not handed on yet, interleaved, and how many frames were
    private var limited = [Float]()
    private var handedOn: Int64 = 0
    /// Set when a buffer could not be made: the mix is then incomplete
    private(set) var failed = false

    /// The most the limiter took off, in dB; 0 without one
    var limiterReduction: Double { limiter?.reduction ?? 0 }

    init?(parts: [Part], frames: Int64, limiter: PeakLimiter? = nil) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RecordingMixer.sampleRate, channels: 2, interleaved: true) else { return nil }
        self.parts = parts
        self.frames = frames
        self.format = format
        self.limiter = limiter
        leftOut = limiter?.delay ?? 0
        cursors = parts.map { _ in 0 }
    }

    /// Adds up the next piece of the parts into `mix`; returns how many frames it has, 0 at the end
    private func add() -> Int {
        guard position < frames else { return 0 }
        let count = Int(min(Int64(MixedAudio.chunk), frames - position))
        if mix.count < count * 2 { mix = [Float](repeating: 0, count: count * 2) }
        for index in 0..<(count * 2) { mix[index] = 0 }
        for (index, part) in parts.enumerated() {
            if let curve = part.gain {
                curve.values(from: position, count: count, rate: RecordingMixer.sampleRate, cursor: &cursors[index], into: &gains)
                if part.complement { for frame in 0..<count { gains[frame] = 1 - gains[frame] } }
                if part.scale != 1 { for frame in 0..<count { gains[frame] *= part.scale } }
                part.track.add(into: &mix, from: position, count: count, gains: gains)
            } else if part.scale != 1 {
                if gains.count < count { gains = [Float](repeating: 0, count: count) }
                for frame in 0..<count { gains[frame] = part.scale }
                part.track.add(into: &mix, from: position, count: count, gains: gains)
            } else {
                part.track.add(into: &mix, from: position, count: count, gains: nil)
            }
        }
        position += Int64(count)
        return count
    }

    /// Reads what is left of the tracks: the reader completes only once every output has been read to its end
    private func drain() { parts.forEach { $0.track.drain() } }

    /// Hands the next piece of the plain sum (interleaved stereo, and its frames) to `body`; false at the end, when
    /// there was none. For measuring: no limiter, no buffers.
    func sum(_ body: (UnsafeBufferPointer<Float>, Int) -> Void) -> Bool {
        let count = add()
        guard count > 0 else {
            drain()
            return false
        }
        mix.withUnsafeBufferPointer { body($0, count) }
        return true
    }

    /// The next piece of the mix, nil at its end
    func next() -> CMSampleBuffer? {
        guard !failed else {
            drain()
            return nil
        }
        guard limiter != nil else {
            let at = position
            let count = add()
            guard count > 0 else {
                drain()
                return nil
            }
            return buffer(of: mix, frames: count, at: at)
        }
        // Through the limiter until it has returned something past its delay, or everything
        while limited.isEmpty {
            var count = add()
            if count == 0 {
                guard !flushed else {
                    drain()
                    return nil
                }
                // The frames still inside the limiter
                flushed = true
                count = limiter?.delay ?? 0
                guard count > 0 else { continue }
                if mix.count < count * 2 { mix = [Float](repeating: 0, count: count * 2) }
                for index in 0..<(count * 2) { mix[index] = 0 }
            }
            mix.withUnsafeMutableBufferPointer { limiter?.process($0, frames: count) }
            let skipped = min(leftOut, count)
            leftOut -= skipped
            if skipped < count { limited.append(contentsOf: mix[(skipped * 2)..<(count * 2)]) }
        }
        let count = limited.count / 2
        let made = buffer(of: limited, frames: count, at: handedOn)
        handedOn += Int64(count)
        limited.removeAll(keepingCapacity: true)
        return made
    }

    /// `frames` frames of interleaved stereo as a sample buffer at frame `at`; nil, and `failed`, when it cannot be made
    private func buffer(of samples: [Float], frames count: Int, at: Int64) -> CMSampleBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let data = pcm.floatChannelData else {
            failed = true
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            data[0].update(from: base, count: count * 2)
        }
        guard let buffer = AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: CMTime(value: at, timescale: CMTimeScale(RecordingMixer.sampleRate))) else {
            failed = true
            return nil
        }
        return buffer
    }
}

/// The RMS level of audio every `SystemAudioChoice.block` seconds, all channels together
struct BlockLevels {
    private let size: Int64
    private var sums = [Double]()
    private var counts = [Int]()

    init(rate: Double) {
        size = max(1, Int64((rate * SystemAudioChoice.block).rounded()))
    }

    /// `frames` frames of `channels` interleaved samples, the first at frame `first`
    mutating func add(_ samples: UnsafeBufferPointer<Float>, frames: Int, channels: Int, at first: Int64) {
        guard frames > 0, channels > 0, first >= 0 else { return }
        let last = Int((first + Int64(frames) - 1) / size)
        if sums.count <= last {
            sums.append(contentsOf: repeatElement(0, count: last + 1 - sums.count))
            counts.append(contentsOf: repeatElement(0, count: last + 1 - counts.count))
        }
        for frame in 0..<frames {
            let block = Int((first + Int64(frame)) / size)
            var sum = 0.0
            for channel in 0..<channels {
                let value = Double(samples[frame * channels + channel])
                sum += value * value
            }
            sums[block] += sum
            counts[block] += channels
        }
    }

    func finish() -> [Float] {
        return zip(sums, counts).map { $1 > 0 ? Float(($0 / Double($1)).squareRoot()) : 0 }
    }
}
