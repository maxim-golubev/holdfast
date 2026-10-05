//
//  MixerTests.swift
//  RecordingMixer.mix, verify and inspect on small movies made here
//

import AVFoundation
import Foundation

/// How loud a test tone is at a time, 0 for silence
typealias Loudness = (Double) -> Float

enum TestMovie {
    static let aac: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128000
    ]

    /// Feeds one writer input until `step` returns false
    private static func feed(_ input: AVAssetWriterInput, step: @escaping () -> Bool) async {
        let queue = DispatchQueue(label: "tests.movie")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                while !done && input.isReadyForMoreMediaData {
                    if !step() {
                        done = true
                        input.markAsFinished()
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Writes a movie the way a recording is laid out: H.264 video (10 frames a second, 320 x 240) and one AAC
    /// track per entry of `audio`, in that order, each a 440 Hz tone as loud as its closure says.
    static func write(to url: URL, seconds: Double, audio: [Loudness]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
        ])
        guard writer.canAdd(video) else { throw TestError("the writer does not take the video input") }
        writer.add(video)
        var tracks = [AVAssetWriterInput]()
        for _ in audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw TestError("the writer does not take the audio input") }
            writer.add(input)
            tracks.append(input)
        }
        guard writer.startWriting() else { throw writer.error ?? TestError("the writer does not start") }
        writer.startSession(atSourceTime: .zero)
        let format = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true), "format")
        var problem: String?

        await withTaskGroup(of: Void.self) { group in
            let frames = Int(seconds * 10)
            var frame = 0
            group.addTask {
                await feed(video) {
                    guard frame < frames else { return false }
                    var made: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
                    guard let pixels = made else { problem = "no pixel buffer"; return false }
                    CVPixelBufferLockBaseAddress(pixels, [])
                    if let base = CVPixelBufferGetBaseAddress(pixels) {
                        memset(base, Int32(40 + frame * 5 % 200), CVPixelBufferGetDataSize(pixels))
                    }
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)) else { problem = "a frame was not written"; return false }
                    frame += 1
                    return true
                }
            }
            for (index, loudness) in audio.enumerated() {
                let input = tracks[index]
                let total = Int(seconds * 48000)
                var position = 0
                group.addTask {
                    await feed(input) {
                        let count = min(4800, total - position)
                        guard count > 0 else { return false }
                        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let data = pcm.floatChannelData else { problem = "no audio buffer"; return false }
                        pcm.frameLength = AVAudioFrameCount(count)
                        for offset in 0..<count {
                            let at = Double(position + offset) / 48000
                            let value = loudness(at) * Float(sin(2 * Double.pi * 440 * at))
                            data[0][offset * 2] = value
                            data[0][offset * 2 + 1] = value
                        }
                        guard let buffer = AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: CMTime(value: CMTimeValue(position), timescale: 48000)),
                              input.append(buffer) else { problem = "audio was not written"; return false }
                        position += count
                        return true
                    }
                }
            }
        }
        await writer.finishWriting()
        if let problem = problem { throw TestError(problem) }
        guard writer.status == .completed else { throw writer.error ?? TestError("the movie was not written") }
    }

    /// Writes an audio file (AAC unless `settings` say otherwise), as an audio-only recording is written: `seconds`
    /// of a 440 Hz tone as loud as `loudness` says
    @discardableResult
    static func writeAudio(to url: URL, seconds: Double, settings: [String: Any] = aac, loudness: Loudness) throws -> URL {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let total = Int(seconds * 48000)
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800), "buffer")
        let data = try require(pcm.floatChannelData, "float data")
        var position = 0
        while position < total {
            let count = min(4800, total - position)
            pcm.frameLength = AVAudioFrameCount(count)
            for offset in 0..<count {
                let at = Double(position + offset) / 48000
                let value = loudness(at) * Float(sin(2 * Double.pi * 440 * at))
                for channel in 0..<Int(file.processingFormat.channelCount) { data[channel][offset] = value }
            }
            try file.write(from: pcm)
            position += count
        }
        return url
    }

    /// RMS level of an audio file from `start` to `end` seconds, 1 being full scale
    static func level(of url: URL, from start: Double, to end: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let count = AVAudioFrameCount((end - start) * rate)
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count), "buffer")
        try file.read(into: pcm, frameCount: count)
        let data = try require(pcm.floatChannelData, "float data")
        var sum = 0.0
        for channel in 0..<Int(pcm.format.channelCount) {
            for frame in 0..<Int(pcm.frameLength) { sum += Double(data[channel][frame]) * Double(data[channel][frame]) }
        }
        return pcm.frameLength > 0 ? (sum / Double(Int(pcm.frameLength) * Int(pcm.format.channelCount))).squareRoot() : 0
    }

    static func seconds(of url: URL) async throws -> Double {
        return CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    static func trackCounts(of url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        return [try await asset.loadTracks(withMediaType: .video).count, try await asset.loadTracks(withMediaType: .audio).count]
    }
}

func mixerTests() async {
    let silent: Loudness = { _ in 0 }
    // System audio in the first half, the microphone alone in the second
    let system: Loudness = { $0 < 2 ? 0.2 : 0 }
    let microphone: Loudness = { $0 >= 2 ? 0.3 : 0 }
    var recording: URL?

    /// The recording all of these work on: 4 s of video, system audio and microphone
    func source() async throws -> URL {
        if let url = recording { return url }
        let url = try Suite.folder("mixer").appendingPathComponent("Recording at X.recording.mp4")
        try await TestMovie.write(to: url, seconds: 4, audio: [system, microphone])
        recording = url
        return url
    }

    await test("Mixer: a recording with two audio tracks is mixed to one, and the mix passes the check") {
        let raw = try await source()
        expectEqual(try await TestMovie.trackCounts(of: raw), [1, 2], "tracks of the recording")
        let before = try Data(contentsOf: raw)
        let output = raw.deletingLastPathComponent().appendingPathComponent("Recording at X.mixing.mp4")
        let lock = NSLock()
        var progress = [Double]()
        try await RecordingMixer.mix(source: raw, output: output, fileType: .mp4, audioSettings: TestMovie.aac) { fraction in
            lock.lock(); progress.append(fraction); lock.unlock()
        }
        try await RecordingMixer.verify(source: raw, output: output)
        expectEqual(try await TestMovie.trackCounts(of: output), [1, 1], "tracks of the mix")
        let rawSeconds = try await TestMovie.seconds(of: raw)
        expectClose(rawSeconds, 4, within: 0.1, "length of the recording")
        expectClose(try await TestMovie.seconds(of: output), rawSeconds, within: 0.1, "length of the mix")
        let mixed = AVURLAsset(url: output)
        for type in [AVMediaType.video, .audio] {
            let track = try require(try await mixed.loadTracks(withMediaType: type).first, "\(type.rawValue) track")
            expectClose(CMTimeGetSeconds(try await track.load(.timeRange).duration), 4, within: 0.1, "length of the \(type.rawValue) track")
        }
        let rawVideo = try require(try await AVURLAsset(url: raw).loadTracks(withMediaType: .video).first, "video of the recording")
        let mixedVideo = try require(try await mixed.loadTracks(withMediaType: .video).first, "video of the mix")
        expectEqual(try await mixedVideo.load(.naturalSize), try await rawVideo.load(.naturalSize), "picture size")
        expectEqual(try await mixedVideo.load(.totalSampleDataLength), try await rawVideo.load(.totalSampleDataLength), "the video is copied, not encoded again")
        expectEqual(progress.last, 1, "progress ends at 1")
        expectEqual(progress, progress.sorted(), "progress only goes up")
        expectEqual(try Data(contentsOf: raw), before, "the recording itself is not touched")
        let info = await RecordingMixer.inspect(output)
        expect(!info.mixable, "a mix is not mixed again")
    }

    await test("Mixer: a mix without the microphone is rejected") {
        let raw = try await source()
        let output = raw.deletingLastPathComponent().appendingPathComponent("without microphone.mp4")
        try await TestMovie.write(to: output, seconds: 4, audio: [system])
        let message = await expectThrows("verify") { try await RecordingMixer.verify(source: raw, output: output) }
        expect(message.contains("microphone"), "the reason names the microphone: \(message)")
        let nothing = raw.deletingLastPathComponent().appendingPathComponent("silent.mp4")
        try await TestMovie.write(to: nothing, seconds: 4, audio: [silent])
        await expectThrows("verify of a silent mix") { try await RecordingMixer.verify(source: raw, output: nothing) }
    }

    await test("Mixer: a mix that is shorter, missing or of the wrong shape is rejected") {
        let raw = try await source()
        let folder = raw.deletingLastPathComponent()
        let short = folder.appendingPathComponent("short.mp4")
        try await TestMovie.write(to: short, seconds: 2, audio: [microphone])
        let message = await expectThrows("verify of a short mix") { try await RecordingMixer.verify(source: raw, output: short) }
        expect(message.contains("long"), "the reason gives the lengths: \(message)")
        await expectThrows("verify of a missing mix") { try await RecordingMixer.verify(source: raw, output: folder.appendingPathComponent("missing.mp4")) }
        await expectThrows("verify of a mix with two audio tracks") { try await RecordingMixer.verify(source: raw, output: raw) }
        let garbage = folder.appendingPathComponent("garbage.mp4")
        try Data(repeating: 7, count: 5000).write(to: garbage)
        await expectThrows("verify of a file that is no movie") { try await RecordingMixer.verify(source: raw, output: garbage) }
    }

    await test("Mixer: a recording without two audio tracks is not mixed") {
        let folder = try Suite.folder("mixer")
        let single = folder.appendingPathComponent("one track.mp4")
        try await TestMovie.write(to: single, seconds: 2, audio: [microphone])
        let output = folder.appendingPathComponent("one track.mixing.mp4")
        let message = await expectThrows("mix") {
            try await RecordingMixer.mix(source: single, output: output, fileType: .mp4, audioSettings: TestMovie.aac) { _ in }
        }
        expect(message.contains("two audio tracks"), "the reason: \(message)")
        expect(!FileManager.default.fileExists(atPath: output.path), "nothing is written")
        expect(FileManager.default.fileExists(atPath: single.path), "the recording is still there")
        let garbage = folder.appendingPathComponent("garbage.recording.mp4")
        try Data(repeating: 7, count: 5000).write(to: garbage)
        await expectThrows("mix of a file that is no movie") {
            try await RecordingMixer.mix(source: garbage, output: output, fileType: .mp4, audioSettings: TestMovie.aac) { _ in }
        }
        expect(FileManager.default.fileExists(atPath: garbage.path), "the file is still there")
    }

    await test("Mixer: a microphone that is never alone has nothing to check, and the mix passes") {
        let folder = try Suite.folder("mixer")
        let raw = folder.appendingPathComponent("both.recording.mp4")
        try await TestMovie.write(to: raw, seconds: 3, audio: [{ _ in 0.3 }, { _ in 0.3 }])
        let output = folder.appendingPathComponent("both.mixing.mp4")
        try await RecordingMixer.mix(source: raw, output: output, fileType: .mp4, audioSettings: TestMovie.aac) { _ in }
        try await RecordingMixer.verify(source: raw, output: output)
        expectClose(try await TestMovie.seconds(of: output), try await TestMovie.seconds(of: raw), within: 0.1, "length of the mix")
    }

    await test("Conversion: a converted file is accepted only when it opens and is as long as the recording") {
        let folder = try Suite.folder("conversion")
        func audioFile(_ name: String, seconds: Double) throws -> URL {
            return try TestMovie.writeAudio(to: folder.appendingPathComponent(name), seconds: seconds) { _ in 0.3 }
        }
        let source = try audioFile("recording.m4a", seconds: 5)
        try RecordingMixer.verifyConversion(source: source, output: try audioFile("complete.m4a", seconds: 5))
        let short = await expectThrows("a cut-off file") { try RecordingMixer.verifyConversion(source: source, output: try audioFile("cut.m4a", seconds: 2)) }
        expect(short.contains("long"), "the reason gives both lengths: \(short)")
        let empty = folder.appendingPathComponent("empty.mp3")
        try Data().write(to: empty)
        await expectThrows("an empty file") { try RecordingMixer.verifyConversion(source: source, output: empty) }
        let garbage = folder.appendingPathComponent("garbage.mp3")
        try Data(repeating: 7, count: 4096).write(to: garbage)
        await expectThrows("a file that does not open") { try RecordingMixer.verifyConversion(source: source, output: garbage) }
        await expectThrows("a file that was not written") { try RecordingMixer.verifyConversion(source: source, output: folder.appendingPathComponent("missing.mp3")) }
    }

    // An audio-only recording with a microphone: system audio has a tone from 2 to 4 s of its 6, the microphone from
    // 1 to 1.5 s and from 5.5 to 6.3 s of its 6.5, past the end of the system audio
    let packageSystem: Loudness = { $0 >= 2 && $0 < 4 ? 0.3 : 0 }
    let packageMicrophone: Loudness = { ($0 >= 1 && $0 < 1.5) || ($0 >= 5.5 && $0 < 6.3) ? 0.3 : 0 }

    await test("Package mix: both files are mixed in step, at their volumes, to the end of the longer one") {
        // AAC, and FLAC, whose package files are CAF and whose mix is a FLAC file
        for format in [AudioFormat.aac, .flac] {
            let folder = try Suite.folder("package mix \(format)")
            let settings = MovieWriter.audioSettings(format: format.rawValue, quality: 128, videoFormat: nil)
            let ending = format.packageFileEnding
            let system = try TestMovie.writeAudio(to: folder.appendingPathComponent("sys.\(ending)"), seconds: 6, settings: settings, loudness: packageSystem)
            let microphone = try TestMovie.writeAudio(to: folder.appendingPathComponent("mic.\(ending)"), seconds: 6.5, settings: settings, loudness: packageMicrophone)
            let output = folder.appendingPathComponent("mix.\(format.fileEnding)")
            try RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (1, 0.5), to: output, settings: settings)
            expectEqual(try container(of: output), output.pathExtension, "\(format): the container of the mix")
            let file = try AVAudioFile(forReading: output)
            expectClose(Double(file.length) / file.processingFormat.sampleRate, 6.5, within: 0.05, "as long as the longer file")
            // A tone of amplitude 0.3 has an RMS level of 0.21, at half the volume 0.11
            func level(_ start: Double, _ end: Double) throws -> Double { try TestMovie.level(of: output, from: start, to: end) }
            expectClose(try level(0, 0.95), 0, within: 0.005, "silence before the first tone")
            expectClose(try level(1.05, 1.45), 0.106, within: 0.02, "the microphone's first tone, at its volume, where it is in its file")
            expectClose(try level(1.55, 1.95), 0, within: 0.005, "silence after it")
            expectClose(try level(2.05, 3.95), 0.212, within: 0.02, "system audio's tone, where it is in its file")
            expectClose(try level(4.05, 5.45), 0, within: 0.005, "silence after it")
            expectClose(try level(5.55, 6.25), 0.106, within: 0.02, "the microphone past the end of the system audio")
            expectClose(try level(6.35, 6.5), 0, within: 0.005, "and nothing after the end of the microphone's tone")
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3, "\(format): nothing else is written")
        }
    }

    await test("Package mix: a mix out of step with its files is rejected, one in step is not") {
        let folder = try Suite.folder("package timing")
        let system = try TestMovie.writeAudio(to: folder.appendingPathComponent("sys.m4a"), seconds: 6, loudness: packageSystem)
        let microphone = try TestMovie.writeAudio(to: folder.appendingPathComponent("mic.m4a"), seconds: 6.5, loudness: packageMicrophone)
        let sources = [(url: system, volume: Float(1)), (url: microphone, volume: Float(1))]
        let together: Loudness = { max(packageSystem($0), packageMicrophone($0)) }
        let inStep = try TestMovie.writeAudio(to: folder.appendingPathComponent("in step.m4a"), seconds: 6.5, loudness: together)
        try RecordingMixer.checkTiming(of: inStep, sources: sources)
        // What a mix that began 1.15 s into its files had: their sound earlier by that, and silence at the end
        let late = try TestMovie.writeAudio(to: folder.appendingPathComponent("late.m4a"), seconds: 6.5) { $0 < 5.35 ? together($0 + 1.15) : 0 }
        let message = await expectThrows("a mix that began late into its files") { try RecordingMixer.checkTiming(of: late, sources: sources) }
        expect(message.contains("1.15"), "the reason gives the offset: \(message)")
        let early = try TestMovie.writeAudio(to: folder.appendingPathComponent("early.m4a"), seconds: 6.5) { $0 >= 0.5 ? together($0 - 0.5) : 0 }
        await expectThrows("a mix that began before its files") { try RecordingMixer.checkTiming(of: early, sources: sources) }
        // Nothing but silence, or a sound without changes: nothing to tell from, so no failure
        let quiet = try TestMovie.writeAudio(to: folder.appendingPathComponent("quiet.m4a"), seconds: 6) { _ in 0 }
        try RecordingMixer.checkTiming(of: quiet, sources: [(url: quiet, volume: 1), (url: quiet, volume: 1)])
        let steady = try TestMovie.writeAudio(to: folder.appendingPathComponent("steady.m4a"), seconds: 6) { _ in 0.3 }
        try RecordingMixer.checkTiming(of: steady, sources: [(url: steady, volume: 1), (url: quiet, volume: 1)])
    }

    await test("Leftovers: a recording is inspected by opening it") {
        let raw = try await source()
        let closed = await RecordingMixer.inspect(raw)
        expectClose(closed.seconds ?? 0, 4, within: 0.1, "length of a closed recording")
        expect(!closed.fragmented, "a closed recording is not in fragments, so it is complete")
        expect(closed.mixable, "one video and two audio tracks can be mixed")
        let folder = raw.deletingLastPathComponent()
        let garbage = folder.appendingPathComponent("Recording at Z.recording.mp4")
        try Data(repeating: 7, count: 5000).write(to: garbage)
        let damaged = await RecordingMixer.inspect(garbage)
        expect(damaged.seconds == nil, "a file that does not open has no length: it is damaged")
        expect(!damaged.mixable, "and cannot be mixed")
        let missing = await RecordingMixer.inspect(folder.appendingPathComponent("nothing.mp4"))
        expect(missing.seconds == nil, "nor has a file that is not there")
        let single = folder.appendingPathComponent("single.mp4")
        try await TestMovie.write(to: single, seconds: 1, audio: [microphone])
        let one = await RecordingMixer.inspect(single)
        expect(one.seconds != nil && !one.mixable, "a recording with one audio track opens but is not mixed")
    }
}
