//
//  RecordingMixer.swift
//  QuickRecorder
//

import AVFoundation
import Foundation

/// The audio mix that follows a video recording with system audio and a microphone, and what is done about the
/// files such a recording leaves behind when the app does not get to finish it.
///
/// File names. A recording that is going to be mixed is written as `<name>.recording.<ext>` and the mix as
/// `<name>.mixing.<ext>`, both in the folder the recording is saved to. Neither name is ever a final one: a file
/// under one of them is a recording that is still running or being finished, or one that was left behind by a
/// crash or a kill. The final names are `<name>.<ext>` for the mixed recording and
/// `<name> (unmixed, 2 audio tracks).<ext>` for the recording as it was written.
///
/// Nothing here deletes or renames a file. It writes the mix to the URL it is given and says whether that file can
/// be trusted, and it finds and describes leftovers; the caller decides what happens to the files.
enum RecordingMixer {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let rawMarker = "recording"
    static let mixMarker = "mixing"
    static let unmixedSuffix = " (unmixed, 2 audio tracks)"

    /// `base` is the path of the final file without its extension
    static func temporaryURL(base: String, marker: String, ending: String) -> URL {
        return URL(fileURLWithPath: "\(base).\(marker).\(ending)")
    }

    static func unmixedURL(base: String, ending: String) -> URL {
        return URL(fileURLWithPath: "\(base)\(unmixedSuffix).\(ending)")
    }

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
        guard let videoTrack = videoTracks.first, videoTracks.count == 1 else { throw Failure("The recording has no video track.") }
        guard audioTracks.count > 1 else { throw Failure("The recording does not have two audio tracks to mix.") }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw Failure("The recording is empty.") }
        let transform = try await videoTrack.load(.preferredTransform)
        guard let videoFormat = try await videoTrack.load(.formatDescriptions).first else { throw Failure("The video track has no format.") }

        let reader = try AVAssetReader(asset: asset)
        // No output settings: the compressed frames are handed over as they are in the file
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        var mixSettings = pcmSettings
        mixSettings[AVSampleRateKey] = 48000
        mixSettings[AVNumberOfChannelsKey] = 2
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: mixSettings)
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else { throw Failure("The recording cannot be read for mixing.") }
        reader.add(videoOutput)
        reader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw Failure("The mixed recording cannot be written in this format.") }
        writer.add(videoInput)
        writer.add(audioInput)

        guard reader.startReading() else { throw reader.error ?? Failure("The recording could not be read.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? Failure("The mixed recording could not be created.")
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
            throw error ?? Failure(copied ?? "Mixing the audio tracks was interrupted.")
        }
        guard writer.status == .writing else {
            throw writer.error ?? Failure("The mixed recording could not be written.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? Failure("The mixed recording could not be closed.")
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
        let queue = DispatchQueue(label: "QuickRecorder.mix")
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "QuickRecorder.mix.watchdog"))
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

    // MARK: - Verification

    /// Throws unless `output` is a complete mix of `source`: one video and one audio track, as long as the source
    /// to within a second, and with the microphone audible where only the microphone had sound.
    static func verify(source: URL, output: URL) async throws {
        guard FileManager.default.fileExists(atPath: output.path) else { throw Failure("The mixed recording was not written.") }
        let raw = AVURLAsset(url: source)
        let mixed = AVURLAsset(url: output)
        let video = try await mixed.loadTracks(withMediaType: .video)
        let audio = try await mixed.loadTracks(withMediaType: .audio)
        guard video.count == 1, let mixedAudio = audio.first, audio.count == 1 else {
            throw Failure("The mixed recording does not have one video and one audio track.")
        }
        let rawSeconds = CMTimeGetSeconds(try await raw.load(.duration))
        let mixedSeconds = CMTimeGetSeconds(try await mixed.load(.duration))
        let videoSeconds = CMTimeGetSeconds(try await video[0].load(.timeRange).duration)
        let audioSeconds = CMTimeGetSeconds(try await mixedAudio.load(.timeRange).duration)
        guard rawSeconds.isFinite, mixedSeconds.isFinite, abs(rawSeconds - mixedSeconds) <= 1 else {
            throw Failure(String(format: "The mixed recording is %.1f s long, the recording %.1f s.", mixedSeconds, rawSeconds))
        }
        let rawVideoSeconds = CMTimeGetSeconds(try await raw.loadTracks(withMediaType: .video).first?.load(.timeRange).duration ?? .zero)
        guard videoSeconds.isFinite, videoSeconds >= rawVideoSeconds - 1 else {
            throw Failure("The video of the mixed recording is shorter than the recording.")
        }
        // Tracks in the order they were added to the file: system audio, then microphone
        let rawAudio = try await raw.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var rawAudioSeconds = 0.0
        for track in rawAudio { rawAudioSeconds = max(rawAudioSeconds, CMTimeGetSeconds(try await track.load(.timeRange).duration)) }
        guard audioSeconds.isFinite, audioSeconds >= rawAudioSeconds - 1 else {
            throw Failure("The audio of the mixed recording is shorter than the recording.")
        }
        guard rawAudio.count == 2 else { return }
        try checkMicrophone(system: rawAudio[0], microphone: rawAudio[1], in: raw, mixed: mixedAudio, in: mixed, seconds: rawSeconds)
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
            throw Failure("The microphone is in the recording but cannot be heard in the mixed audio.")
        }
    }

    /// RMS level of all channels of `track` within `range`, 1 being full scale
    private static func level(of track: AVAssetTrack, in asset: AVAsset, range: CMTimeRange) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure("The audio cannot be read to check the mix.") }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { throw reader.error ?? Failure("The audio cannot be read to check the mix.") }
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
        guard reader.status == .completed else { throw reader.error ?? Failure("The audio cannot be read to check the mix.") }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    // MARK: - Leftovers of an earlier run

    /// What a temporary name is made of: `<base>.<marker>.<ending>`
    struct Leftover {
        let url: URL
        /// Path of the final file without its extension
        let base: String
        let isMix: Bool
        let ending: String
    }

    /// What can be told about a leftover recording by opening it
    struct Inspection {
        /// Nil when the file does not open
        let seconds: Double?
        /// Whether the file is still in the fragments it was recorded in. A recording that was closed is not.
        let fragmented: Bool
        /// One video track and two audio tracks
        let mixable: Bool
    }

    /// The files in `directory` that this app left under a temporary name: `<prefix>….recording.<ext>` and
    /// `<prefix>….mixing.<ext>`, `prefix` being what the app's recordings are named with. A file that merely has
    /// such an ending is someone else's and is left alone. Only call this when no recording is running or being
    /// finished, in this or in another instance of the app: until then such a file is not a leftover.
    static func leftovers(in directory: String, prefix: String) -> [Leftover] {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return files.sorted { $0.path < $1.path }.compactMap { url in
            let ending = url.pathExtension
            guard ["mp4", "mov"].contains(ending.lowercased()) else { return nil }
            let stem = url.deletingPathExtension()
            let marker = stem.pathExtension
            guard marker == rawMarker || marker == mixMarker else { return nil }
            let name = stem.deletingPathExtension().lastPathComponent
            guard !prefix.isEmpty, name.hasPrefix(prefix), name.count > prefix.count else { return nil }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return Leftover(url: url, base: stem.deletingPathExtension().path, isMix: marker == mixMarker, ending: ending)
        }
    }

    static func inspect(_ url: URL) async -> Inspection {
        let asset = AVURLAsset(url: url)
        guard let (playable, duration) = try? await asset.load(.isPlayable, .duration), playable else {
            return Inspection(seconds: nil, fragmented: true, mixable: false)
        }
        let length = CMTimeGetSeconds(duration)
        guard length.isFinite, length > 0 else { return Inspection(seconds: nil, fragmented: true, mixable: false) }
        // When in doubt the file counts as not closed
        let fragmented = (try? await asset.load(.containsFragments)) ?? true
        let video = (try? await asset.loadTracks(withMediaType: .video).count) ?? 0
        let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        return Inspection(seconds: length, fragmented: fragmented, mixable: video == 1 && audio == 2)
    }

    /// `<base>.<ending>`, or `<base> (<label>).<ending>` with a label, numbered when that name is taken
    static func freeURL(base: String, label: String?, ending: String) -> URL {
        let manager = FileManager.default
        var target = URL(fileURLWithPath: label.map { "\(base) (\($0)).\(ending)" } ?? "\(base).\(ending)")
        var number = 2
        while manager.fileExists(atPath: target.path) && number < 100 {
            target = URL(fileURLWithPath: "\(base) (\(label.map { $0 + " " } ?? "")\(number)).\(ending)")
            number += 1
        }
        return target
    }
}
