//
//  PackageTests.swift
//  The mix of a .qma package's two files (RecordingMixer.mixPackage): the plain sum it was before, and "Level Voices"
//

import AVFoundation
import Foundation

enum TestPackage {
    /// 32 bit float, so that what is read back is what was written
    static let float: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]

    /// Writes `mono` (one value a frame, in both channels) as an audio file, as a sound-only recording's files are
    /// written
    @discardableResult
    static func write(_ mono: [Float], to url: URL, settings: [String: Any] = float) throws -> URL {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096), "buffer")
        let data = try require(pcm.floatChannelData, "float data")
        var position = 0
        while position < mono.count {
            let count = min(4096, mono.count - position)
            pcm.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for frame in 0..<count { data[channel][frame] = mono[position + frame] }
            }
            try file.write(from: pcm)
            position += count
        }
        file.close()
        return url
    }

    /// Every sample of an audio file, interleaved stereo
    static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096), "buffer")
        let channels = Int(file.processingFormat.channelCount)
        var samples = [Float]()
        samples.reserveCapacity(Int(file.length) * 2)
        while file.framePosition < file.length {
            try file.read(into: pcm, frameCount: 4096)
            guard pcm.frameLength > 0, let data = pcm.floatChannelData else { break }
            for frame in 0..<Int(pcm.frameLength) {
                samples.append(data[0][frame])
                samples.append(data[channels > 1 ? 1 : 0][frame])
            }
        }
        return samples
    }

    /// The package mix as it was made before the mixer's own sum: an audio engine rendering offline, a player for
    /// each file at its volume. What `RecordingMixer.mixPackage` without "Level Voices" must still give.
    static func engineMix(system: URL, microphone: URL, volumes: (system: Float, microphone: Float), to output: URL, settings: [String: Any]) throws {
        let sources = [(url: system, volume: volumes.system), (url: microphone, volume: volumes.microphone)]
        let files = try sources.map { try AVAudioFile(forReading: $0.url) }
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), "format")
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        var players = [AVAudioPlayerNode]()
        for (file, source) in zip(files, sources) {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = source.volume
            player.scheduleFile(file, at: nil)
            players.append(player)
        }
        try engine.start()
        defer { engine.stop() }
        players.forEach { $0.play() }
        func seconds(_ file: AVAudioFile) -> Double { Double(file.length) / file.processingFormat.sampleRate }
        let longest = files.map(seconds).max() ?? 0
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount), "buffer")
        let outputFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let duration = AVAudioFramePosition((longest * engine.manualRenderingFormat.sampleRate).rounded())
        while engine.manualRenderingSampleTime < duration {
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(duration - engine.manualRenderingSampleTime))
            guard try engine.renderOffline(frames, to: buffer) == .success else { throw TestError("the engine did not render") }
            try outputFile.write(from: buffer)
        }
        outputFile.close()
    }

    /// How two sets of samples differ: how many have another value, and by how much at most
    static func difference(_ one: [Float], _ other: [Float]) -> (count: Int, largest: Float) {
        var count = abs(one.count - other.count)
        var largest: Float = 0
        for index in 0..<min(one.count, other.count) where one[index] != other[index] {
            count += 1
            largest = max(largest, abs(one[index] - other[index]))
        }
        return (count, largest)
    }
}

func packageTests() async {
    // A call recorded as sound only: the other side speaks in the first half, quietly, the owner in the second,
    // loudly, and goes on half a second past the end of the system audio
    let far = TestLoudness.speech(seconds: 12, from: 0.5, to: 6, loudness: -26, seed: 11)
    let near = TestLoudness.speech(seconds: 12.5, from: 6.5, to: 12.3, loudness: -14, seed: 12)
    // Both speaking at once for most of it, so that the mix has sums to make
    let together = TestLoudness.speech(seconds: 12.5, from: 0.2, to: 12.3, loudness: -20, seed: 13)
    func levelLines() -> [String] { RecLog.lines.filter { $0.hasPrefix("Level Voices:") } }
    /// The largest sample of interleaved stereo, and the largest value a player makes of the half second around it
    func peaks(_ samples: [Float]) -> (sample: Float, between: Float) {
        let loudest = (0..<samples.count).max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
        let frame = loudest / 2, frames = samples.count / 2
        return (abs(samples[loudest]), TestLoudness.truePeak(samples, frames: max(0, frame - 12000)..<min(frames, frame + 12000)))
    }
    /// What the mixer's sum makes of the two files at these levels: the system audio first, then the microphone
    func sum(_ system: [Float], _ systemLevel: Float, _ microphone: [Float], _ microphoneLevel: Float) -> [Float] {
        var mix = [Float](repeating: 0, count: max(system.count, microphone.count))
        for index in 0..<system.count { mix[index] += system[index] * systemLevel }
        for index in 0..<microphone.count { mix[index] += microphone[index] * microphoneLevel }
        return mix
    }

    await test("Package mix: without Level Voices it is, sample for sample, the mix the audio engine made") {
        let folder = try Suite.folder("package plain")
        let system = try TestPackage.write(far, to: folder.appendingPathComponent("sys.caf"))
        let microphone = try TestPackage.write(together, to: folder.appendingPathComponent("mic.caf"))
        // At the volumes a recording is saved with, and at volumes set in the player, also above 1
        for (index, volumes) in [(Float(1), Float(1)), (1, 0.5), (2, 1), (4, 0.25), (0, 1)].enumerated() {
            let before = folder.appendingPathComponent("engine \(index).caf"), now = folder.appendingPathComponent("mix \(index).caf")
            try TestPackage.engineMix(system: system, microphone: microphone, volumes: volumes, to: before, settings: TestPackage.float)
            let applied = try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: volumes, to: now, settings: TestPackage.float)
            expect(applied == nil, "nothing leveled")
            let engine = try TestPackage.samples(of: before), mixed = try TestPackage.samples(of: now)
            expectEqual(mixed.count, 600_000 * 2, "as long as the microphone's file, the longer one")
            let difference = TestPackage.difference(engine, mixed)
            expectEqual(difference.count, 0, "samples that differ at volumes \(volumes) (by \(difference.largest) at most)")
            print("measured: volumes \(volumes): \(mixed.count) samples, \(difference.count) different from the engine's mix")
        }
        // Volumes that are no power of two: the engine rounds the products another way, by one unit in the last
        // place of a sample at most
        let before = folder.appendingPathComponent("engine odd.caf"), now = folder.appendingPathComponent("mix odd.caf")
        try TestPackage.engineMix(system: system, microphone: microphone, volumes: (0.3, 0.7), to: before, settings: TestPackage.float)
        try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (0.3, 0.7), to: now, settings: TestPackage.float)
        let difference = TestPackage.difference(try TestPackage.samples(of: before), try TestPackage.samples(of: now))
        expect(difference.largest <= 6e-8, "at volumes 0.3 and 0.7 the two differ by rounding only: \(difference)")
        print("measured: volumes 0.3 and 0.7: \(difference.count) samples different, by \(difference.largest) at most")
        expect(levelLines().isEmpty, "nothing logged without the setting")
        expectEqual(try TestPackage.samples(of: system).count, far.count * 2, "the package's files are only read")
    }

    await test("Package mix: the files of every format are read where the audio engine read them") {
        // A package of each format the app writes: lossless ones must give the engine's mix bit for bit, and the
        // others the same sound at the same place (their decoders do not promise the last bit from one reader to the next)
        for format in [AudioFormat.aac, .alac, .flac, .opus] {
            let folder = try Suite.folder("package format \(format)")
            let settings = MovieWriter.audioSettings(format: format.rawValue, quality: 128, videoFormat: nil)
            let ending = format.packageFileEnding
            let system = try TestPackage.write(far, to: folder.appendingPathComponent("sys.\(ending)"), settings: settings)
            let microphone = try TestPackage.write(together, to: folder.appendingPathComponent("mic.\(ending)"), settings: settings)
            let before = folder.appendingPathComponent("engine.caf"), now = folder.appendingPathComponent("mix.caf")
            try TestPackage.engineMix(system: system, microphone: microphone, volumes: (1, 1), to: before, settings: TestPackage.float)
            try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (1, 1), to: now, settings: TestPackage.float)
            let engine = try TestPackage.samples(of: before), mixed = try TestPackage.samples(of: now)
            expectEqual(mixed.count, engine.count, "\(format): as long as the engine's mix")
            let difference = TestPackage.difference(engine, mixed)
            if format == .alac || format == .flac {
                expectEqual(difference.count, 0, "\(format): samples that differ (by \(difference.largest) at most)")
            } else {
                // A mix one frame out of step would differ by the sound's own size, about 0.1
                expect(difference.largest < 1e-4, "\(format): the same sound at the same place: \(difference)")
            }
            print("measured: \(format): \(mixed.count) samples, \(difference.count) different from the engine's mix, by \(difference.largest) at most")
        }
    }

    await test("Package mix: a package as the writer makes it is mixed where the audio engine mixed it") {
        let run = try TestRecording(folder: "package writer", audioOnly: true, settings: ["remuxAudio": true])
        try run.writer.prepareAudio()
        run.writer.startCapturing()
        try run.feed(from: 0, to: 3, video: false)
        _ = try await run.close()
        let package = run.recording.rawURL
        let info = try QmaInfo.read(package: package)
        let folder = try Suite.folder("package writer mixes")
        let before = folder.appendingPathComponent("engine.caf"), now = folder.appendingPathComponent("mix.caf")
        try TestPackage.engineMix(system: info.systemAudio(in: package), microphone: info.microphone(in: package), volumes: (1, 1), to: before, settings: TestPackage.float)
        try await RecordingMixer.mixPackage(system: info.systemAudio(in: package), microphone: info.microphone(in: package), volumes: (1, 1), to: now,
                                            settings: TestPackage.float)
        let engine = try TestPackage.samples(of: before), mixed = try TestPackage.samples(of: now)
        expectEqual(mixed.count, engine.count, "as long as the engine's mix")
        expect(mixed.count >= 2 * 48000 * 2, "and as the recording: \(mixed.count / 2) frames")
        let difference = TestPackage.difference(engine, mixed)
        expect(difference.largest < 1e-4, "the same sound at the same place: \(difference)")
        print("measured: the writer's package (AAC): \(mixed.count) samples, \(difference.count) different from the engine's mix, by \(difference.largest) at most")
    }

    await test("Package mix: Level Voices brings each file to -16 LUFS by one gain, and the volumes come on top") {
        let folder = try Suite.folder("package leveled")
        let system = try TestPackage.write(far, to: folder.appendingPathComponent("sys.caf"))
        let microphone = try TestPackage.write(near, to: folder.appendingPathComponent("mic.caf"))
        let recorded = (try TestPackage.samples(of: system), try TestPackage.samples(of: microphone))
        let measured = try await RecordingMixer.packageLeveling(system: system, microphone: microphone)
        expectClose(measured.system.reading.loudness ?? 0, -26, within: 0.3, "the system audio as recorded")
        expectClose(measured.microphone?.reading.loudness ?? 0, -14, within: 0.3, "the microphone as recorded")
        expectClose(measured.system.gain, 10, within: 0.3, "the system audio's gain")
        expectClose(measured.microphone?.gain ?? 0, -2, within: 0.3, "the microphone's gain")

        let leveled = folder.appendingPathComponent("leveled.caf")
        let applied = try require(try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (1, 1), levelVoices: true, to: leveled,
                                                                      settings: TestPackage.float), "what the mix did")
        expectEqual(applied.system, measured.system, "the mix measures what the player is told")
        expectEqual(applied.microphone, measured.microphone, "for the microphone too")
        expectEqual(applied.limiterReduction, 0, "nothing for the limiter to do: the two do not speak at once")
        expect(levelLines().count == 1 && levelLines()[0].contains("system audio -26.") && levelLines()[0].contains("microphone -14.")
               && levelLines()[0].contains("the limiter had nothing to do"), "the log: \(levelLines())")
        let mixed = try TestPackage.samples(of: leveled)
        expectEqual(mixed.count, recorded.1.count, "as long as the microphone's file")
        expectClose(TestLoudness.loudness(mixed, from: 0, to: 6), -16, within: 0.3, "the other side in the mix")
        expectClose(TestLoudness.loudness(mixed, from: 6.5, to: 12.5), -16, within: 0.3, "the microphone in the mix")
        // One gain for the whole of each file, and nothing else done to it
        let expected = sum(recorded.0, applied.system.factor, recorded.1, applied.microphone?.factor ?? 1)
        expectEqual(TestPackage.difference(mixed, expected).count, 0, "samples that are not the two files at their gains")

        // The volumes set in the player, on top of the gains
        let balanced = folder.appendingPathComponent("balanced.caf")
        RecLog.lines = []
        let again = try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (0.5, 4), levelVoices: true, to: balanced,
                                                        settings: TestPackage.float)
        expectEqual(again?.system, measured.system, "a volume does not change what is measured")
        let other = try TestPackage.samples(of: balanced)
        expectClose(TestLoudness.loudness(other, from: 0, to: 6), -22, within: 0.3, "the other side at half its volume")
        expect((again?.limiterReduction ?? 0) > 3, "the microphone at four times its volume is held by the limiter: \(String(describing: again))")
        let held = peaks(other)
        // Every sample at the ceiling or under it. Between the samples of sound like this, noise up to half the
        // sample rate, the limiter's estimate from 12 samples is up to half a decibel under what 64 samples give
        expect(held.sample <= Float(PeakLimiter.ceiling) * 1.000001 && held.between <= Float(PeakLimiter.ceiling) * 1.06, "at -1 dBFS: \(held)")
        print("measured: the microphone at four times its volume: the limiter took off \(again?.limiterReduction ?? 0) dB, peak \(held)")
        expectEqual(other.count, mixed.count, "and as long")
        // The limiter leaves the mix where it was: the other side's part, where it has nothing to do, sample for sample
        let quiet = sum(recorded.0, 0.5 * applied.system.factor, [], 1)
        expect((0..<(6 * 48000 * 2)).allSatisfy { other[$0].bitPattern == quiet[$0].bitPattern }, "the first half is the system audio at its level, in place")
    }

    await test("Package mix: Level Voices in the formats of a recording, with the limiter holding two voices at once") {
        // Both speak at the same time and loudly: the sum would clip
        let loud = TestLoudness.speech(seconds: 8, from: 0.5, to: 7.5, loudness: -9, seed: 21)
        for format in [AudioFormat.aac, .flac] {
            let folder = try Suite.folder("package leveled \(format)")
            let settings = MovieWriter.audioSettings(format: format.rawValue, quality: 256, videoFormat: nil)
            let ending = format.packageFileEnding
            let system = try TestPackage.write(loud, to: folder.appendingPathComponent("sys.\(ending)"), settings: settings)
            let microphone = try TestPackage.write(loud, to: folder.appendingPathComponent("mic.\(ending)"), settings: settings)
            let output = folder.appendingPathComponent("mix.\(format.fileEnding)")
            let applied = try require(try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (1, 1), levelVoices: true, to: output,
                                                                          settings: settings), "what the mix did")
            expectClose(applied.system.gain, -6, within: 0.01, "\(format): a side this loud gets the most that is taken off")
            expect(applied.limiterReduction > 0, "\(format): the limiter acted: \(applied)")
            let mixed = try TestPackage.samples(of: output)
            expectClose(Double(mixed.count / 2) / 48000, 8, within: 0.05, "\(format): as long as the files")
            // A lossy encoder may overshoot a little
            let held = peaks(mixed)
            expect(held.between <= Float(PeakLimiter.ceiling) * (format == .flac ? 1.06 : 1.12), "\(format): the peak is held: \(held)")
            print("measured: \(format): gains \(applied.system.gain) and \(applied.microphone?.gain ?? 0) dB, the limiter took off \(applied.limiterReduction) dB, peak \(held)")
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3, "\(format): nothing else is written")
        }
    }

    await test("Package mix: a silent side is left as it is, and a file that does not open fails the mix") {
        let folder = try Suite.folder("package silent")
        let system = try TestPackage.write([Float](repeating: 0, count: 6 * 48000), to: folder.appendingPathComponent("sys.caf"))
        let microphone = try TestPackage.write(TestLoudness.speech(seconds: 6, from: 0.5, to: 5.5, loudness: -30, seed: 31), to: folder.appendingPathComponent("mic.caf"))
        let output = folder.appendingPathComponent("mix.caf")
        let applied = try require(try await RecordingMixer.mixPackage(system: system, microphone: microphone, volumes: (1, 1), levelVoices: true, to: output,
                                                                      settings: TestPackage.float), "what the mix did")
        expectEqual(applied.system.gain, 0, "nothing for a silent side")
        expectClose(applied.microphone?.gain ?? 0, 12, within: 0.01, "and no more than 12 dB for a quiet one")
        expect(levelLines().first?.contains("system audio silent, not changed") == true, "the log: \(levelLines())")
        let garbage = folder.appendingPathComponent("garbage.caf")
        try Data(repeating: 7, count: 4096).write(to: garbage)
        let failed = folder.appendingPathComponent("failed.caf")
        await expectThrows("a system audio file that does not open") {
            try await RecordingMixer.mixPackage(system: garbage, microphone: microphone, volumes: (1, 1), levelVoices: true, to: failed, settings: TestPackage.float)
        }
        await expectThrows("measuring it") { _ = try await RecordingMixer.packageLeveling(system: garbage, microphone: microphone) }
    }
}
