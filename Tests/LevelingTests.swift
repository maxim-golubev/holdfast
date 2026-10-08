//
//  LevelingTests.swift
//  "Level Voices": the loudness meter, the rule for the gains, the limiter, and the mix made with them
//

import AVFoundation
import Foundation

enum TestLoudness {
    /// What the mixes of these tests are written as: 32 bit float in a MOV file, so that the samples read back are
    /// the samples the mix made
    static let lossless: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]

    /// The integrated loudness of interleaved audio
    static func reading(_ samples: [Float], rate: Double = 48000, channels: Int = 2, piece: Int? = nil) -> LoudnessMeter.Reading {
        var meter = LoudnessMeter(rate: rate, channels: channels)
        let frames = samples.count / channels
        let step = piece ?? frames
        var at = 0
        samples.withUnsafeBufferPointer { all in
            while at < frames {
                let count = min(step, frames - at)
                meter.add(UnsafeBufferPointer(rebasing: all[(at * channels)..<((at + count) * channels)]), frames: count)
                at += count
            }
        }
        return meter.reading
    }

    static func loudness(_ samples: [Float], from start: Double = 0, to end: Double? = nil) -> Double {
        let first = Int(start * 48000) * 2, last = min(samples.count, Int((end ?? Double(samples.count)) * 48000) * 2)
        return reading(Array(samples[first..<last])).loudness ?? -.infinity
    }

    /// Both channels the same
    static func stereo(_ mono: [Float]) -> [Float] {
        var both = [Float](repeating: 0, count: mono.count * 2)
        for index in 0..<mono.count {
            both[index * 2] = mono[index]
            both[index * 2 + 1] = mono[index]
        }
        return both
    }

    /// A sine in both channels, its peak at `level` dBFS
    static func sine(seconds: Double, frequency: Double = 1000, level: Double, rate: Double = 48000) -> [Float] {
        let amplitude = pow(10, level / 20)
        var mono = [Float](repeating: 0, count: Int(seconds * rate))
        for frame in 0..<mono.count {
            let angle: Double = 2 * Double.pi * frequency * Double(frame) / rate
            mono[frame] = Float(amplitude * sin(angle))
        }
        return stereo(mono)
    }

    /// Something like speech, the same every run: low noise in bursts of a third of a second, each at its own
    /// level, from `start` to `end` of `seconds`, at `loudness` LUFS when both channels play it. One value a frame.
    static func speech(seconds: Double, from start: Double, to end: Double, loudness: Double, seed: UInt64) -> [Float] {
        var state = seed &* 2862933555777941757 &+ 3037000493
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 23) - 1
        }
        var mono = [Float](repeating: 0, count: Int(seconds * 48000))
        var low: Float = 0
        var burstLevel: Float = 1
        for index in Int(start * 48000)..<min(mono.count, Int(end * 48000)) {
            let inBurst = (index - Int(start * 48000)) % 24000
            if inBurst == 0 { burstLevel = 0.6 + 0.2 * (random() + 1) }
            low += 0.3 * (random() - low)
            guard inBurst < 16800 else { continue }
            let edge = Float(min(inBurst, 16800 - inBurst))
            mono[index] = low * burstLevel * min(1, edge / 480)
        }
        let measured = reading(stereo(mono)).loudness ?? 0
        let factor = Float(pow(10, (loudness - measured) / 20))
        return mono.map { $0 * factor }
    }

    /// An audio track of a movie as it is read for the mix: interleaved stereo at 48 kHz, each buffer at its own time
    static func track(_ url: URL, _ index: Int = 0) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        guard index < tracks.count else { throw TestError("no audio track \(index)") }
        let reader = try AVAssetReader(asset: asset)
        var settings = lossless
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TestError("cannot read") }
        var samples = [Float]()
        var incoming = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let frames = TrackPCM.copy(buffer, into: &incoming) else { continue }
            let first = Int((CMTimeGetSeconds(buffer.presentationTimeStamp) * 48000).rounded())
            if samples.count < first * 2 { samples.append(contentsOf: repeatElement(0, count: first * 2 - samples.count)) }
            let skip = max(0, samples.count / 2 - first)
            if skip < frames { samples.append(contentsOf: incoming[(skip * 2)..<(frames * 2)]) }
        }
        guard reader.status == .completed else { throw reader.error ?? TestError("the track was not read to its end") }
        return samples
    }

    /// The largest value a player makes of `samples` (interleaved stereo) between `first` and `last` frames: eight
    /// points a sample, each from 32 samples on either side
    static func truePeak(_ samples: [Float], frames range: Range<Int>) -> Float {
        var kernels = [[Float]]()
        for phase in 0..<8 {
            kernels.append((-31...32).map { tap in
                let distance = Double(tap) - Double(phase) / 8
                let sinc = distance == 0 ? 1 : sin(Double.pi * distance) / (Double.pi * distance)
                return Float(sinc * 0.5 * (1 + cos(Double.pi * distance / 32.5)))
            })
        }
        var peak: Float = 0
        let frames = samples.count / 2
        for frame in max(31, range.lowerBound)..<min(frames - 32, range.upperBound) {
            for channel in 0..<2 {
                for kernel in kernels {
                    var value: Float = 0
                    for tap in 0..<64 { value += kernel[tap] * samples[(frame - 31 + tap) * 2 + channel] }
                    peak = max(peak, abs(value))
                }
            }
        }
        return peak
    }

    static func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

    /// `samples` through a limiter, `piece` frames at a time, its delay taken out: what the mix makes of them
    static func limited(_ samples: [Float], piece: Int = 4096) -> (samples: [Float], limiter: PeakLimiter) {
        var limiter = PeakLimiter(rate: 48000)
        var work = samples + [Float](repeating: 0, count: limiter.delay * 2)
        let frames = work.count / 2
        var at = 0
        work.withUnsafeMutableBufferPointer { all in
            while at < frames {
                let count = min(piece, frames - at)
                limiter.process(UnsafeMutableBufferPointer(rebasing: all[(at * 2)..<((at + count) * 2)]), frames: count)
                at += count
            }
        }
        return (Array(work[(limiter.delay * 2)...]), limiter)
    }
}

func levelingTests() async {
    let ceiling = Float(PeakLimiter.ceiling)

    await test("Loudness: a 1 kHz sine at -23 dBFS in both channels reads -23.0 LUFS") {
        let reading = TestLoudness.reading(TestLoudness.sine(seconds: 10, level: -23))
        expectClose(reading.loudness ?? 0, -23, within: 0.1, "at 48 kHz")
        expectClose(reading.gatedSeconds, 9.7, within: 0.11, "all of it passes the gates")
        let other = TestLoudness.reading(TestLoudness.sine(seconds: 10, level: -23, rate: 44100), rate: 44100)
        expectClose(other.loudness ?? 0, -23, within: 0.1, "at 44.1 kHz, where the filters are worked out anew")
        let pieces = TestLoudness.reading(TestLoudness.sine(seconds: 10, level: -23), piece: 777)
        expectEqual(pieces, reading, "the same fed in pieces of any size")
        // One channel alone is half the power
        var mono = LoudnessMeter(rate: 48000, channels: 1)
        let both = TestLoudness.sine(seconds: 10, level: -23)
        let one: [Float] = stride(from: 0, to: both.count, by: 2).map { both[$0] }
        one.withUnsafeBufferPointer { mono.add($0, frames: one.count) }
        expectClose(mono.reading.loudness ?? 0, -26, within: 0.1, "one channel")
        print(String(format: "        measured: %.2f LUFS at 48 kHz, %.2f LUFS at 44.1 kHz", reading.loudness ?? 0, other.loudness ?? 0))
    }

    await test("Loudness: the gates leave silence and what is far quieter out") {
        let tone = TestLoudness.sine(seconds: 30, level: -23)
        let silence = [Float](repeating: 0, count: 20 * 48000 * 2)
        let withSilence = TestLoudness.reading(silence + tone + silence)
        expectClose(withSilence.loudness ?? 0, -23, within: 0.1, "30 s of tone in 70 s")
        expectClose(withSilence.gatedSeconds, 30, within: 0.4, "only the tone counts")
        // 30 dB under it: over the absolute gate, under the relative one
        let withQuiet = TestLoudness.reading(tone + TestLoudness.sine(seconds: 20, level: -53))
        expectClose(withQuiet.loudness ?? 0, -23, within: 0.1, "a far quieter stretch is left out")
        // Without gates the mean of the first would be 3.7 dB lower
        let nothing = TestLoudness.reading(silence)
        expect(nothing.loudness == nil && nothing.gatedSeconds == 0, "silence has no loudness: \(nothing)")
        let faint = TestLoudness.reading(TestLoudness.sine(seconds: 5, level: -80))
        expect(faint.loudness == nil, "nor has a sound under -70 LUFS: \(faint)")
        print(String(format: "        measured: %.2f LUFS with 40 s of silence around the tone, %.2f LUFS with a stretch 30 dB quieter", withSilence.loudness ?? 0, withQuiet.loudness ?? 0))
    }

    await test("Level Voices: the gain brings a side to -16 LUFS, within -6 and +12 dB, and leaves alone what cannot be measured") {
        func gain(_ loudness: Double?, _ seconds: Double = 60) -> Double {
            VoiceLeveling.gain(for: LoudnessMeter.Reading(loudness: loudness, gatedSeconds: seconds))
        }
        expectEqual(VoiceLeveling.target, -16, "the target")
        expectEqual(gain(-21.9), 5.899999999999999, "the owner's FaceTime recording")
        expectClose(gain(-20), 4, within: 1e-9, "quiet")
        expectClose(gain(-14), -2, within: 1e-9, "loud")
        expectEqual(gain(-30), 12, "no more than +12 dB")
        expectEqual(gain(-28), 12, "at the cap")
        expectEqual(gain(-5), -6, "no less than -6 dB")
        expectEqual(gain(nil, 0), 0, "a silent side")
        expectEqual(gain(-30, 2.9), 0, "under 3 s of sound")
        expectEqual(gain(-30, 3), 12, "3 s are enough")
        expectEqual(gain(-55), 0, "the noise of a room is not raised")
        expectClose(Double(VoiceLeveling.Side(LoudnessMeter.Reading(loudness: -22, gatedSeconds: 60)).factor), 1.9953, within: 0.001, "+6 dB as a factor")
    }

    await test("Limiter: a hot signal is held at -1 dBFS, between the samples too, whatever the pieces it comes in") {
        // 0.5 s that is quiet, then tones far over full scale, then a tone whose samples stay under the ceiling
        // while the wave between them goes to 1.2
        var samples = [Float](repeating: 0, count: 3 * 48000 * 2)
        for frame in 0..<(3 * 48000) {
            let t = Double(frame) / 48000
            if t < 0.5 {
                samples[frame * 2] = Float(0.2 * sin(2 * Double.pi * 440 * t))
                samples[frame * 2 + 1] = samples[frame * 2]
            } else if t < 1.5 {
                samples[frame * 2] = Float(1.5 * sin(2 * Double.pi * 997 * t) + 0.4 * sin(2 * Double.pi * 7919 * t))
                samples[frame * 2 + 1] = Float(1.2 * sin(2 * Double.pi * 1499 * t))
            } else if t >= 2 && t < 2.5 {
                samples[frame * 2] = Float(1.2 * sin(2 * Double.pi * 12000 * t + Double.pi / 4))
                samples[frame * 2 + 1] = samples[frame * 2]
            }
        }
        expect(TestLoudness.peak(Array(samples[(2 * 48000 * 2)..<(Int(2.5 * 48000) * 2)])) < ceiling, "the samples of the last tone are under the ceiling")
        expectClose(Double(TestLoudness.truePeak(samples, frames: 100000..<110000)), 1.2, within: 0.02, "and its wave is not")
        let (out, limiter) = TestLoudness.limited(samples)
        expectEqual(out.count, samples.count, "as long as it was")
        let peak = TestLoudness.peak(out)
        expect(peak <= ceiling * 1.000001, "no sample over the ceiling: \(peak)")
        let between = TestLoudness.truePeak(out, frames: 24000..<72000), last = TestLoudness.truePeak(out, frames: 96000..<120000)
        expect(between <= ceiling * 1.012, "nor the wave between them (0.1 dB): \(between)")
        expect(last <= ceiling * 1.012, "the tone at a quarter of the rate is held by its wave: \(last)")
        expect(TestLoudness.truePeak(out, frames: 100000..<110000) >= ceiling * 0.97, "and not taken down further than that")
        expectClose(limiter.reduction, 20 * log10(1.9 / Double(ceiling)), within: 1.5, "what it took off at most, in dB")
        // The quiet start is untouched up to the look-ahead before the first peak
        expect((0..<(23000 * 2)).allSatisfy { out[$0].bitPattern == samples[$0].bitPattern }, "what is quiet before it passes unchanged")
        // Both channels by the same gain
        let frame = 30000
        expectClose(Double(out[frame * 2] / samples[frame * 2]), Double(out[frame * 2 + 1] / samples[frame * 2 + 1]), within: 1e-4, "one gain for both channels")
        for piece in [240, 777] {
            expect(TestLoudness.limited(samples, piece: piece).samples == out, "the same in pieces of \(piece) frames")
        }
        print(String(format: "        measured: sample peak %.2f dBFS, true peak %.2f dBTP, at most %.1f dB taken off; delay %d frames, compensated",
                         20 * log10(peak), 20 * log10(max(between, last)), limiter.reduction, limiter.delay))
    }

    await test("Limiter: what stays under the ceiling passes bit for bit, and it is so again after a peak") {
        let quiet = TestLoudness.stereo(TestLoudness.speech(seconds: 3, from: 0, to: 3, loudness: -20, seed: 7))
        expect(TestLoudness.peak(quiet) < 0.5, "the test's sound is quiet: \(TestLoudness.peak(quiet))")
        let (same, idle) = TestLoudness.limited(quiet, piece: 777)
        expect(same.count == quiet.count && zip(same, quiet).allSatisfy { $0.bitPattern == $1.bitPattern }, "every sample as it was, where it was")
        expectEqual(idle.reduction, 0, "nothing taken off")
        // A click of three times full scale one second in
        var clicked = quiet
        for offset in -2...2 {
            let value = Float(3 * cos(Double(offset) * Double.pi / 6))
            clicked[(48000 + offset) * 2] = value
            clicked[(48000 + offset) * 2 + 1] = value
        }
        let (out, limiter) = TestLoudness.limited(clicked)
        let loudest = (0..<(out.count / 2)).max { abs(out[$0 * 2]) < abs(out[$1 * 2]) } ?? 0
        expectEqual(loudest, 48000, "the click is at its sample")
        expect(abs(out[48000 * 2]) <= ceiling * 1.000001 && abs(out[48000 * 2]) > ceiling * 0.98, "at the ceiling: \(out[48000 * 2])")
        expectClose(limiter.reduction, 20 * log10(3 / Double(ceiling)), within: 0.3, "taken off for it, in dB")
        let attack = 48000 - Int(0.006 * 48000), release = 48000 + 2 * 48000 - 4800
        expect((0..<(attack * 2)).allSatisfy { out[$0].bitPattern == clicked[$0].bitPattern }, "unchanged up to 6 ms before the click")
        expect(((release * 2)..<out.count).allSatisfy { out[$0].bitPattern == clicked[$0].bitPattern }, "and bit for bit again 1.9 s after it")
        // 0.15 s after the click most of the reduction is gone, and it never grows after the click
        func gain(_ frame: Int) -> Double { clicked[frame * 2] == 0 ? 1 : Double(out[frame * 2] / clicked[frame * 2]) }
        let after = (48000 + 7200..<48000 + 7300).map(gain).filter { $0 > 0 }.reduce(0, +) / 100
        expect(after > 0.6 && after < 0.9, "the gain 0.15 s after the click: \(after)")
    }

    // A call: the other side speaks in the first half, quietly, the owner in the second, loudly
    let folder = (try? Suite.folder("leveling")) ?? Suite.workFolder
    /// A recording with these two tracks, as AAC like the app's, or `lossless`: then the tracks read back are these
    /// very samples, which AAC does not promise to the last bit, not even from one reading to the next
    func recording(_ name: String, seconds: Double, system: [Float], microphone: [Float], lossless: Bool = false) async throws -> URL {
        let url = folder.appendingPathComponent("\(name).recording." + (lossless ? "mov" : "mp4"))
        try await TestMovie.write(to: url, seconds: seconds, samples: [
            { $0 < system.count ? system[$0] : 0 }, { $0 < microphone.count ? microphone[$0] : 0 },
        ], settings: lossless ? TestLoudness.lossless : TestMovie.aac, fileType: lossless ? .mov : .mp4)
        return url
    }
    /// The mix of `raw` as a lossless file, and its samples
    func mix(_ raw: URL, _ name: String, level: Bool) async throws -> (url: URL, plan: RecordingMixer.MixPlan, audio: [Float]) {
        let url = folder.appendingPathComponent("\(name).mov")
        try? FileManager.default.removeItem(at: url)
        let plan = try await RecordingMixer.mix(source: raw, output: url, fileType: .mov, audioSettings: TestLoudness.lossless, levelVoices: level) { _ in }
        return (url, plan, try await TestLoudness.track(url))
    }
    func levelLines() -> [String] { RecLog.lines.filter { $0.hasPrefix("Level Voices:") } }
    let silence = [Float](repeating: 0, count: 12 * 48000)
    let far = TestLoudness.speech(seconds: 12, from: 0.5, to: 6, loudness: -26, seed: 1)
    var near = TestLoudness.speech(seconds: 12, from: 6.5, to: 12, loudness: -14, seed: 2)
    // A click in the microphone at 3 s, while only the other side speaks
    let clickAt = 3 * 48000
    for offset in -24...24 { near[clickAt + offset] = Float(0.6 * 0.5 * (1 + cos(Double(offset) * Double.pi / 24))) }
    var call: URL?
    func callRecording() async throws -> URL {
        if let call { return call }
        let url = try await recording("call", seconds: 12, system: far, microphone: near)
        call = url
        return url
    }
    var losslessCall: URL?
    func losslessCallRecording() async throws -> URL {
        if let losslessCall { return losslessCall }
        let url = try await recording("call lossless", seconds: 12, system: far, microphone: near, lossless: true)
        losslessCall = url
        return url
    }

    await test("Level Voices: a quiet other side and a loud microphone are both at -16 LUFS in the mix, and the check follows the gains") {
        let raw = try await callRecording()
        let before = try Data(contentsOf: raw)
        let tracks = (try await TestLoudness.track(raw, 0), try await TestLoudness.track(raw, 1))
        let recorded = (TestLoudness.loudness(tracks.0), TestLoudness.loudness(tracks.1))
        expectClose(recorded.0, -26, within: 0.5, "the system audio as recorded")
        expectClose(recorded.1, -14, within: 0.5, "the microphone as recorded")
        let plain = try await mix(raw, "call plain", level: false)
        expect(levelLines().isEmpty, "nothing logged without the setting")
        let leveled = try await mix(raw, "call leveled", level: true)
        let applied = try require(leveled.plan.leveling, "what the mix did")
        expectClose(applied.system.gain, -16 - recorded.0, within: 0.2, "the system audio's gain")
        expectClose(applied.microphone?.gain ?? 0, -16 - recorded.1, within: 0.2, "the microphone's gain")
        let sides = (TestLoudness.loudness(leveled.audio, from: 0, to: 6), TestLoudness.loudness(leveled.audio, from: 6, to: 12))
        // The click in the microphone track at 3 s is not speech: measured without the 0.4 s around it
        let system = TestLoudness.reading(Array(leveled.audio[0..<(Int(2.7 * 48000) * 2)]) + Array(leveled.audio[(Int(3.3 * 48000) * 2)..<(6 * 48000 * 2)])).loudness ?? 0
        expectClose(system, -16, within: 1, "the other side in the mix")
        expectClose(sides.1, -16, within: 1, "the microphone in the mix")
        let unleveled = (TestLoudness.loudness(plain.audio, from: 0, to: 2.7), TestLoudness.loudness(plain.audio, from: 6, to: 12))
        expectClose(unleveled.0, recorded.0, within: 1, "without the setting the other side stays where it was")
        expectClose(unleveled.1, recorded.1, within: 1, "and the microphone")
        expectEqual(levelLines().count, 1, "one line in the log")
        let line = levelLines().first ?? ""
        expect(line.contains("system audio -2") && line.contains("microphone -1") && line.contains("limiter") && line.contains("dB"), "it gives both sides and the limiter: \(line)")
        expectEqual(try Data(contentsOf: raw), before, "the recording itself is not touched")
        // The check: right for the mix it was made for, and wrong for any other
        try await RecordingMixer.verify(source: raw, output: leveled.url, plan: leveled.plan)
        try await RecordingMixer.verify(source: raw, output: plain.url, plan: plain.plan)
        let tooQuiet = await expectThrows("a mix without the gains, checked as one with them") { try await RecordingMixer.verify(source: raw, output: plain.url, plan: leveled.plan) }
        expect(tooQuiet.contains("system audio"), "the system audio is not at its level: \(tooQuiet)")
        await expectThrows("a mix with the gains, checked as one without them") { try await RecordingMixer.verify(source: raw, output: leveled.url, plan: plain.plan) }
        let deaf = try await mix(try await recording("call without microphone", seconds: 12, system: far, microphone: silence), "call without microphone", level: true)
        expectClose(deaf.plan.leveling?.system.gain ?? 0, applied.system.gain, within: 0.05, "the same gain for the same system audio")
        let missing = await expectThrows("a leveled mix without the microphone") { try await RecordingMixer.verify(source: raw, output: deaf.url, plan: leveled.plan) }
        expect(missing.contains("microphone"), "the reason names the microphone: \(missing)")
        print(String(format: "        measured: recorded %.1f and %.1f LUFS; gains %+.1f and %+.1f dB; in the mix %.1f and %.1f LUFS (without the setting %.1f and %.1f); limiter %.1f dB",
                         recorded.0, recorded.1, applied.system.gain, applied.microphone?.gain ?? 0, system, sides.1, unleveled.0, unleveled.1, applied.limiterReduction))
        print("        log: " + line)
    }

    await test("Level Voices: off, the mix is the plain sum of the tracks, sample for sample") {
        let raw = try await losslessCallRecording()
        let plain = try await mix(raw, "call off", level: false)
        expect(plain.plan.leveling == nil, "nothing was leveled")
        expect(levelLines().isEmpty, "and nothing logged")
        expectEqual(plain.audio.count, far.count * 2, "as long as the tracks")
        var different = 0
        for frame in 0..<min(far.count, plain.audio.count / 2) {
            let sum = far[frame] + near[frame]
            if plain.audio[frame * 2].bitPattern != sum.bitPattern || plain.audio[frame * 2 + 1].bitPattern != sum.bitPattern { different += 1 }
        }
        expectEqual(different, 0, "frames that are not the sum of the two tracks")
        try await RecordingMixer.verify(source: raw, output: plain.url, plan: plain.plan)
        print("        measured: \(min(far.count, plain.audio.count / 2)) frames compared with the sum of the two tracks, \(different) different")
    }

    await test("Level Voices: the picture and the sound stay together: a click is at its sample, and gains of 0 dB change nothing") {
        let raw = try await losslessCallRecording()
        let plain = try await mix(raw, "call plain", level: false), leveled = try await mix(raw, "call leveled", level: true)
        func loudest(_ audio: [Float]) -> Int { ((clickAt - 240)..<(clickAt + 240)).max { abs(audio[$0 * 2]) < abs(audio[$1 * 2]) } ?? 0 }
        expectEqual(loudest(plain.audio), clickAt, "the click in the plain mix")
        expectEqual(loudest(leveled.audio), clickAt, "the click in the leveled mix, its gains \(leveled.plan.leveling?.text ?? "")")
        expectEqual(leveled.audio.count, plain.audio.count, "the same length")
        // Every sample of the microphone's half is the plain one times the microphone's gain, where it was
        let factor = leveled.plan.leveling?.microphone?.factor ?? 0
        expect(leveled.plan.leveling?.limiterReduction == 0 && factor != 1, "the limiter was idle and the microphone has a gain: \(leveled.plan.leveling?.text ?? "")")
        let moved = ((7 * 48000 * 2)..<(11 * 48000 * 2)).filter { abs(leveled.audio[$0] - plain.audio[$0] * factor) > 1e-6 }.count
        expectEqual(moved, 0, "samples of the leveled mix that are not the plain mix's times the gain")
        // Under 3 s of sound on each side: no gain, and nothing for the limiter to do
        var shortMicrophone = TestLoudness.speech(seconds: 8, from: 4, to: 6, loudness: -20, seed: 4)
        for offset in -24...24 { shortMicrophone[7 * 48000 + offset] = Float(0.6 * 0.5 * (1 + cos(Double(offset) * Double.pi / 24))) }
        let short = try await recording("short", seconds: 8, system: TestLoudness.speech(seconds: 8, from: 1, to: 3, loudness: -26, seed: 3),
                                        microphone: shortMicrophone, lossless: true)
        let shortPlain = try await mix(short, "short plain", level: false), shortLeveled = try await mix(short, "short leveled", level: true)
        let applied = try require(shortLeveled.plan.leveling, "what the mix did")
        expectEqual(applied.system.gain, 0, "the system audio: \(applied.system.text)")
        expectEqual(applied.microphone?.gain, 0, "the microphone: \(applied.microphone?.text ?? "")")
        expectEqual(applied.limiterReduction, 0, "the limiter")
        expect(shortLeveled.audio.count == shortPlain.audio.count && zip(shortLeveled.audio, shortPlain.audio).allSatisfy { $0.bitPattern == $1.bitPattern },
               "through the limiter every sample is where and what it was")
        print("        measured: click at frame \(loudest(leveled.audio)) leveled, \(loudest(plain.audio)) plain, \(clickAt) recorded; \(moved) samples off the plain mix times the gain; \(shortLeveled.audio.count / 2) frames through the idle limiter identical; " + applied.text)
    }

    await test("Level Voices: a very quiet side gets +12 dB and no more, a silent one nothing") {
        let raw = try await recording("faint", seconds: 12, system: TestLoudness.speech(seconds: 12, from: 0.5, to: 11.5, loudness: -30, seed: 5), microphone: silence)
        let recorded = TestLoudness.loudness(try await TestLoudness.track(raw, 0))
        let leveled = try await mix(raw, "faint leveled", level: true)
        let applied = try require(leveled.plan.leveling, "what the mix did")
        expectEqual(applied.system.gain, 12, "the cap")
        expectClose(TestLoudness.loudness(leveled.audio), recorded + 12, within: 0.2, "the mix is 12 dB over the recording")
        expectEqual(applied.microphone?.gain, 0, "the silent microphone")
        expect(applied.microphone?.reading.loudness == nil, "which has no loudness")
        expect(applied.text.contains("microphone silent, not changed"), "the log says so: \(applied.text)")
        try await RecordingMixer.verify(source: raw, output: leveled.url, plan: leveled.plan)
        print(String(format: "        measured: recorded %.1f LUFS, in the mix %.1f LUFS; ", recorded, TestLoudness.loudness(leveled.audio)) + applied.text)
    }

    await test("Level Voices: a sum that would clip is held at -1 dBFS by the limiter") {
        // Both sides the same sound, so their peaks add up, and a click of half scale in both
        var both = TestLoudness.speech(seconds: 9, from: 0.5, to: 8.5, loudness: -26, seed: 6)
        for offset in -24...24 { both[4 * 48000 + offset] = Float(0.5 * 0.5 * (1 + cos(Double(offset) * Double.pi / 24))) }
        let raw = try await recording("hot", seconds: 9, system: both, microphone: both)
        let leveled = try await mix(raw, "hot leveled", level: true)
        let applied = try require(leveled.plan.leveling, "what the mix did")
        let peak = TestLoudness.peak(leveled.audio)
        expect(peak <= ceiling * 1.000001, "no sample over -1 dBFS: \(peak)")
        expect(peak > ceiling * 0.95, "and it goes up to it")
        let between = TestLoudness.truePeak(leveled.audio, frames: (4 * 48000 - 2400)..<(4 * 48000 + 2400))
        expect(between <= ceiling * 1.012, "nor between the samples: \(between)")
        // What the sum would have been without the limiter
        let unlimited = 0.5 * 2 * Double(applied.system.factor)
        expect(unlimited > 2, "the sum was hot: \(unlimited)")
        expectClose(applied.limiterReduction, 20 * log10(unlimited / Double(ceiling)), within: 1.5, "what the limiter took off")
        expect(levelLines().last?.contains("the limiter took off") ?? false, "the log says so: \(levelLines())")
        let loudest = ((4 * 48000 - 240)..<(4 * 48000 + 240)).max { abs(leveled.audio[$0 * 2]) < abs(leveled.audio[$1 * 2]) } ?? 0
        expect(abs(loudest - 4 * 48000) <= 4, "the limited click is at its sample: \(loudest)")
        try await RecordingMixer.verify(source: raw, output: leveled.url, plan: leveled.plan)
        print(String(format: "        measured: peak %.2f dBFS, true peak %.2f dBTP, mix %.1f LUFS; ", 20 * log10(peak), 20 * log10(between), TestLoudness.loudness(leveled.audio)) + applied.text)
    }

    await test("Level Voices: a recording left by an earlier run is mixed with it when the setting says so") {
        for level in [true, false] {
            let folder = try Suite.folder("leveling recovery \(level)")
            let raw = folder.appendingPathComponent("Recording at L.recording.mp4")
            try FileManager.default.copyItem(at: try await callRecording(), to: raw)
            RecLog.lines = []
            let lines = await RecordingRecovery.recover(RecordingFileStore(directory: folder.path).leftovers(), audioSettings: ["mp4": TestMovie.aac], levelVoices: level) { _ in }
            expect(lines.count == 1 && lines[0].contains("Its audio was mixed now"), "mixed: \(lines)")
            expectEqual(levelLines().count, level ? 1 : 0, "the log's line with the setting \(level ? "on" : "off")")
            let mixed = try await TestLoudness.track(folder.appendingPathComponent("Recording at L.mp4"))
            expectClose(TestLoudness.loudness(mixed, from: 6, to: 12), level ? -16 : -14, within: 1, "the microphone in the recovered mix")
        }
    }
}
