//
//  AlignmentTests.swift
//  The process tap's audio against its backup's: how far apart the two tracks hold the same sound is measured from
//  the sound, the mix puts the tap's audio on the backup's timeline, and the tap is the source wherever it was alive.
//  The system audio here is a noise with clicks in it, the same in both tracks, the tap's 2515 samples (52.4 ms)
//  later, as measured on the real machine.
//

import AVFoundation
import Foundation

/// What the tests' system audio sounds like: a quiet low noise, the same at every run, with a click of 3 ms centred
/// on each of `clicks` (in samples). Sample `n` of the sound is `samples[n + lead]`.
struct TestSound {
    static let lead = 48000
    let samples: [Float]

    /// Another `seed` gives another noise
    init(seconds: Double, clicks: [Int], seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        let count = Int(seconds * 48000) + 2 * TestSound.lead
        var state = seed
        var white = [Float](repeating: 0, count: count + 8)
        for index in white.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            white[index] = Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
        var made = [Float](repeating: 0, count: count)
        var sum: Float = 0
        for index in 0..<count {
            // A moving mean of eight: most of it below 3 kHz, which the codec keeps
            sum += white[index + 8] - white[index]
            made[index] = 0.15 * sum / 8
        }
        for click in clicks {
            for k in -72..<72 {
                let window = 0.5 + 0.5 * cos(Double.pi * Double(k) / 72)
                made[click + TestSound.lead + k] += Float(0.6 * window * sin(2 * Double.pi * 2000 * Double(k) / 48000))
            }
        }
        samples = made
    }

    /// A tenth of a second of it from sample `first` on, in ScreenCaptureKit's format; silence with `silent`
    func buffer(from first: Int, pts: CMTime, silent: Bool = false) throws -> CMSampleBuffer {
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), "format")
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800), "pcm")
        pcm.frameLength = 4800
        let data = try require(pcm.floatChannelData, "data")
        for frame in 0..<4800 {
            let value = silent ? 0 : samples[first + frame + TestSound.lead]
            data[0][frame] = value
            data[1][frame] = value
        }
        return try require(AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: pts), "sample buffer")
    }
}

/// How many samples later the tap's track has the sound than the backup's: 52.4 ms
let tapDelay = 2515

/// A recording made with the process tap through the real writer, without a microphone: `sound` in the backup's
/// track and, `tapDelay` samples later, in the tap's. The tap delivers nothing where `tapDead` says, zeros where
/// `tapZeros` says; the backup is silent throughout with `backupSilent`. With `starts` the two tracks begin that many
/// samples after the picture, as they do in a real recording (each with the first buffer of its source), the sound
/// in each that much later still.
func recordApart(_ folder: String, seconds: Double, sound: TestSound, tapDead: (Double) -> Bool = { _ in false }, tapZeros: (Double) -> Bool = { _ in false },
                 backupSilent: Bool = false, tapDelay: Int = tapDelay, starts: (tap: Int, backup: Int) = (0, 0)) async throws -> TestRecording {
    let run = try TestRecording(folder: folder, microphone: false, settings: ["remuxAudio": true, "recordWinSound": true], tap: true)
    let writer = run.writer
    try writer.prepareVideo(width: 320, height: 240)
    writer.startCapturing()
    var step = 0
    while Double(step) / 10 < seconds - 0.001 {
        let t = Double(step) / 10
        try run.frame(t)
        if !tapDead(t) {
            let pts = run.at(t + Double(starts.tap) / 48000)
            writer.write(CaptureSample(kind: .audio, buffer: try sound.buffer(from: step * 4800 - tapDelay, pts: pts, silent: tapZeros(t)), pts: pts))
        }
        let pts = run.at(t + Double(starts.backup) / 48000)
        writer.write(CaptureSample(kind: .backupAudio, buffer: try sound.buffer(from: step * 4800, pts: pts, silent: backupSilent), pts: pts))
        let target = run.at(t + 0.1 - 1)
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.audioEndPTS ?? run.at(0))) >= 0.5 { writer.fillSystemAudio(upTo: target) }
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.backupEndPTS ?? run.at(0))) >= 0.5 { writer.fillBackupAudio(upTo: target) }
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.callEndPTS ?? run.at(0))) >= 0.5 { writer.fillCallAudio(upTo: target) }
        usleep(15_000)
        step += 1
    }
    _ = try await run.close()
    expect(run.failures.isEmpty, "no failure: \(run.failures)")
    return run
}

/// An audio track of a movie as one channel (the mean of its two), each buffer at its own time
func monoTrack(_ url: URL, track index: Int) throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = asset.tracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
    guard index < tracks.count else { throw TestError("no audio track \(index)") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? TestError("cannot read") }
    var mono = [Float]()
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = buffer.dataBuffer else { continue }
        let count = CMBlockBufferGetDataLength(block) / 4
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { bytes in bytes.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0) } }
        let first = Int((CMTimeGetSeconds(buffer.presentationTimeStamp) * 48000).rounded())
        if mono.count < first { mono.append(contentsOf: repeatElement(0, count: first - mono.count)) }
        mono.append(contentsOf: values)
    }
    return mono
}

/// The clicks in `audio` between `start` and `end` seconds: where each is (the middle of its energy, in seconds) and
/// its energy. A click is what rises above 0.25; two rises less than 10 ms apart are one click.
func clicks(in audio: [Float], from start: Double, to end: Double) -> [(time: Double, energy: Double)] {
    var found = [(first: Int, last: Int)]()
    let range = max(0, Int(start * 48000))..<min(audio.count, Int(end * 48000))
    for index in range where abs(audio[index]) > 0.25 {
        if let last = found.last, index - last.last < 480 {
            found[found.count - 1].last = index
        } else {
            found.append((index, index))
        }
    }
    return found.map { click in
        var energy = 0.0, moment = 0.0
        for index in max(0, click.first - 96)...min(audio.count - 1, click.last + 96) {
            let power = Double(audio[index]) * Double(audio[index])
            energy += power
            moment += power * Double(index)
        }
        return (moment / energy / 48000, energy)
    }
}

/// How alike two pieces of audio are sample for sample between `start` and `end` seconds: 1 the same, 0 unrelated
func likeness(_ a: [Float], _ b: [Float], from start: Double, to end: Double) -> Double {
    var products = 0.0, first = 0.0, second = 0.0
    for index in Int(start * 48000)..<min(a.count, b.count, Int(end * 48000)) {
        products += Double(a[index]) * Double(b[index])
        first += Double(a[index]) * Double(a[index])
        second += Double(b[index]) * Double(b[index])
    }
    return first > 0 && second > 0 ? products / (first * second).squareRoot() : 0
}

func alignmentTests() async {
    /// The mix of a recording as the app makes it, checked as the app checks it
    func mixed(_ run: TestRecording) async throws -> (url: URL, plan: RecordingMixer.MixPlan, spans: TapSpans) {
        let mixURL = try require(run.recording.mixURL, "mix name")
        let spans = try require(TapSpans.read(try require(run.recording.tapSpansURL, "spans file")), "spans")
        let plan = try await RecordingMixer.mix(source: run.recording.rawURL, output: mixURL, fileType: .mp4, audioSettings: run.recording.audioSettings, tapSpans: spans) { _ in }
        try await RecordingMixer.verify(source: run.recording.rawURL, output: mixURL, plan: plan)
        return (mixURL, plan, spans)
    }
    let delay = Double(tapDelay) / 48000

    await test("alignment: the place of one piece of sound in another, to the sample; a steady tone and a place past the limit give none") {
        let sound = TestSound(seconds: 6, clicks: [])
        func piece(_ first: Int, _ count: Int) -> [Float] {
            let from = first + TestSound.lead
            return Array(sound.samples[from..<(from + count)])
        }
        let margin = 14400, most = 12000
        let length = 48000 + 2 * margin
        let reference = piece(48000, 48000)
        /// Where the reference is found in what is searched, which starts at sample `first` of the sound
        func found(_ reference: [Float], in searched: [Float]) -> Int? {
            return SystemAudioAlignment.lag(of: reference, in: searched, margin: margin, most: most, width: 24)
        }
        expectEqual(found(reference, in: piece(48000 - margin - 2515, length)), 2515, "52.4 ms later")
        expectEqual(found(reference, in: piece(48000 - margin + 700, length)), -700, "earlier")
        expectEqual(found(reference, in: piece(48000 - margin, length)), 0, "in step")
        expect(found(reference, in: piece(48000 - margin - 13000, length)) == nil, "270 ms is past the limit")
        expect(found(reference, in: piece(120_000, length)) == nil, "another sound matches nowhere")
        var tone = [Float](repeating: 0, count: length)
        for index in 0..<length { tone[index] = Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / 48000)) }
        let toneReference = Array(tone[margin..<(margin + 48000)])
        expect(found(toneReference, in: tone) == nil, "a steady tone matches every period: no answer")
        expect(found(reference, in: [Float](repeating: 0, count: length)) == nil, "silence matches nothing")
        // What the windows say together
        expectEqual(SystemAudioAlignment.agree([2515, 2515, 2514, 2516, 2515], windows: 6, rate: 48000), .init(offset: 2515.0 / 48000, agreeing: 5, windows: 6), "all agree")
        expectEqual(SystemAudioAlignment.agree([2515, 2515, 2515, 9000], windows: 4, rate: 48000).offset, 2515.0 / 48000, "one window astray")
        expectEqual(SystemAudioAlignment.agree([2515, 2515], windows: 2, rate: 48000).offset, nil, "two windows are too few")
        expectEqual(SystemAudioAlignment.agree([100, 2515, 2515, 2515, 7000, -3000], windows: 6, rate: 48000).offset, nil, "half of them elsewhere: not known")
        expectEqual(SystemAudioAlignment.agree([], windows: 0, rate: 48000), .none, "nothing to compare")
        // The whole measurement, from levels and samples
        let levels = [Float](repeating: 0.05, count: 600)
        func measured(_ late: Int) -> SystemAudioAlignment.Measurement {
            SystemAudioAlignment.measure(tap: levels, backup: levels, duration: 6, rate: 48000) { source, first, count in
                piece(Int(first) - (source == .tap ? late : 0), count)
            }
        }
        expectEqual(measured(2515).offset, 2515.0 / 48000, "measured over the windows")
        expect(measured(2515).windows >= 3, "at least three windows in six seconds")
        expectEqual(measured(13000).offset, nil, "270 ms apart: not known")
        let silentBackup = SystemAudioAlignment.measure(tap: levels, backup: [Float](repeating: 0, count: 600), duration: 6, rate: 48000) { _, _, count in piece(0, count) }
        expectEqual(silentBackup, SystemAudioAlignment.Measurement.none, "a silent backup: nothing to compare")
        let text = measured(2515).text
        expect(text.contains("52.4 ms later"), "for the log: \(text)")
        expect(SystemAudioAlignment.Measurement.none.text.contains("not measured"), "and when it is not known")
    }

    await test("system audio choice: a tap that is alive is the source whatever it holds, but for two seconds of nothing against the backup's sound") {
        let blocks = 3000
        let sound = [Float](repeating: 0.1, count: blocks)
        let alive = TapSpans([.init(start: 0, end: 30)])
        func tapLevels(_ silent: (Double) -> Bool) -> [Float] { (0..<blocks).map { silent(Double($0) / 100) ? 0 : 0.1 } }
        // The old rule gave every silent half second of the tap to the backup
        let pauses = tapLevels { $0.truncatingRemainder(dividingBy: 3) >= 1.5 }
        expectEqual(SystemAudioChoice.plan(tap: pauses, backup: sound, spans: alive, duration: 30), [.init(start: 0, end: 30, source: .tap)], "pauses of 1.5 s: the tap throughout")
        expect(SystemAudioChoice.summary(SystemAudioChoice.plan(tap: pauses, backup: sound, spans: alive, duration: 30)).contains("0.0 s from the backup in 0 stretches"), "for the log")
        let quiet = tapLevels { _ in false }.map { $0 * 0.000_1 }
        expectEqual(SystemAudioChoice.plan(tap: quiet, backup: sound, spans: alive, duration: 30), [.init(start: 0, end: 30, source: .tap)], "a very quiet tap is not a silent one")
        expectEqual(SystemAudioChoice.plan(tap: tapLevels { $0 >= 10 && $0 < 15 }, backup: sound, spans: alive, duration: 30),
                    [.init(start: 0, end: 10, source: .tap), .init(start: 10, end: 15, source: .backup), .init(start: 15, end: 30, source: .tap)], "five seconds of zeros: the backup's")
        // The end of a sound the backup holds a little later than the tap is not the backup's signal
        var tail = [Float](repeating: 0, count: blocks)
        for index in 0..<1025 { tail[index] = 0.1 }
        expectEqual(SystemAudioChoice.plan(tap: tapLevels { $0 >= 10 }, backup: tail, spans: alive, duration: 30), [.init(start: 0, end: 30, source: .tap)], "250 ms of the same sound's end")
        // The tap's audio 52.4 ms late: every edge that much earlier in the mix, and no stretch of the backup at the end
        let dead = TapSpans([.init(start: 0, end: 10), .init(start: 13, end: 30)])
        let moved = SystemAudioChoice.plan(tap: tapLevels { $0 >= 10 && $0 < 13 }, backup: sound, spans: dead, duration: 30, offset: 0.0524)
        expectEqual(moved.map(\.source), [.tap, .backup, .tap], "the tap, the backup, the tap")
        if moved.count == 3 {
            expectClose(moved[1].start, 10 - 0.0524, within: 1e-9, "the outage begins where the tap's audio ends in the mix")
            expectClose(moved[1].end, 13 - 0.0524, within: 1e-9, "and ends where it begins again")
            expectEqual(moved[2].end, 30, "the tap to the end")
        }
        expectEqual(SystemAudioChoice.plan(tap: sound, backup: sound, spans: alive, duration: 30, offset: 0.0524), [.init(start: 0, end: 30, source: .tap)], "alive throughout: nothing from the backup")
        expectEqual(SystemAudioChoice.plan(tap: sound, backup: sound, spans: alive, duration: 30, offset: -0.03), [.init(start: 0, end: 30, source: .tap)], "nor with the tap early")
        // A tap dead at the start or the end stays so in the mix
        let late = SystemAudioChoice.plan(tap: tapLevels { $0 < 1 }, backup: sound, spans: TapSpans([.init(start: 1, end: 30)]), duration: 30, offset: 0.0524)
        expectEqual(late.first, .init(start: 0, end: 1 - 0.0524, source: .backup), "from the start of the recording")
        // A recording that was killed: the tap's track ends before the backup's
        let short = [Float](repeating: 0.1, count: 2500)
        expectEqual(SystemAudioChoice.plan(tap: short, backup: sound, spans: TapSpans([.init(start: 0, end: .infinity)]), duration: 30).last, .init(start: 25, end: 30, source: .backup), "past its end the backup")
        // The fade lies in the tap's stretch on both sides
        let gain = SystemAudioChoice.tapGain(for: moved)
        expectEqual(gain.value(at: moved.count == 3 ? moved[1].start : 0), 0, "the backup alone from the edge")
        expectEqual(gain.value(at: moved.count == 3 ? moved[1].end : 0), 0, "and up to the other")
    }

    await test("alignment: two tracks with the same sound 52.4 ms apart: measured within 0.5 ms, the mix on the backup's timeline within 1 ms, 0.0 s from the backup") {
        let click = 5 * 48000
        let sound = TestSound(seconds: 12, clicks: [click])
        let run = try await recordApart("apart", seconds: 12, sound: sound)
        let (mixURL, plan, spans) = try await mixed(run)
        expectEqual(spans.spans.count, 1, "the tap alive throughout: \(spans.spans)")
        let offset = try require(plan.alignment?.offset, "a measured offset: \(RecLog.lines)")
        expectClose(offset, 0.0524, within: 0.000_5, "the tap's audio 52.4 ms later than the backup's")
        expect((plan.alignment?.agreeing ?? 0) >= 3, "by at least three windows: \(String(describing: plan.alignment))")
        expectEqual(plan.segments.map(\.source), [.tap], "the tap throughout")
        expect(RecLog.lines.contains { $0.contains("System audio in the mix:") && $0.contains("0.0 s from the backup in 0 stretches") }, "0.0 s from the backup: \(RecLog.lines)")
        expect(RecLog.lines.contains { $0.hasPrefix("System audio alignment: the tap's audio is 52.4 ms later than the backup's") && $0.contains("windows agree") }, "one line with the offset and the windows: \(RecLog.lines)")
        let tap = try monoTrack(run.recording.rawURL, track: 0), backup = try monoTrack(run.recording.rawURL, track: 1), mix = try monoTrack(mixURL, track: 0)
        // The tracks as recorded, and the mix
        let inTap = clicks(in: tap, from: 4.5, to: 5.5), inBackup = clicks(in: backup, from: 4.5, to: 5.5), inMix = clicks(in: mix, from: 4.5, to: 5.5)
        expectEqual([inTap.count, inBackup.count, inMix.count], [1, 1, 1], "the click once in each")
        if let tapClick = inTap.first, let backupClick = inBackup.first, let mixClick = inMix.first {
            expectClose(backupClick.time, 5, within: 0.000_5, "the backup's track has it at its time")
            expectClose(tapClick.time, 5 + delay, within: 0.000_5, "the tap's track 52.4 ms later, as recorded")
            expectClose(mixClick.time, backupClick.time, within: 0.001, "the mix where the backup has it, within 1 ms")
            expectClose(mixClick.energy / backupClick.energy, 1, within: 0.25, "once, not twice")
        }
        // Sample for sample the mix is the backup's sound: the tap's, moved onto its timeline
        expect(likeness(mix, backup, from: 1, to: 11) > 0.8, "the mix against the backup's track: \(likeness(mix, backup, from: 1, to: 11))")
        expect(likeness(mix, tap, from: 1, to: 11) < 0.3, "and not where the tap's track has it: \(likeness(mix, tap, from: 1, to: 11))")
        let searched = Array(mix[(96000 - 14400)..<(144000 + 14400)])
        let lag = SystemAudioAlignment.lag(of: Array(backup[96000..<144000]), in: searched, margin: 14400, most: 12000, width: 24)
        expect(abs(lag ?? 1000) <= 48, "measured the same way, the mix is within 1 ms of the backup: \(String(describing: lag))")
    }

    await test("alignment: tracks that begin 18.0 and 12.1 ms after the picture, as in a real recording: the mix as a player plays it is within 1 ms of the backup") {
        // The recording of 2026-10-07 18:26: the tap's track begins 864 samples after the picture and the backup's 583,
        // and on the file's timeline the tap's sound is 1075 samples (22.4 ms) later than the backup's. A tool that
        // decodes each track from its first sample, leaving those beginnings out, sees 16.5 ms.
        let starts = (tap: 864, backup: 583)
        let apart = 1075
        let click = 6 * 48000
        let sound = TestSound(seconds: 12, clicks: [click])
        let run = try await recordApart("apart-starts", seconds: 12, sound: sound, tapDelay: apart - (starts.tap - starts.backup), starts: starts)
        // The file is laid out like the real one: each track begins with nothing, for as long as its source began late
        let asset = AVURLAsset(url: run.recording.rawURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var began = [Double]()
        for track in tracks.prefix(2) {
            let first = try await track.load(.segments).first
            began.append(first.map { $0.isEmpty ? CMTimeGetSeconds($0.timeMapping.target.duration) : 0 } ?? -1)
        }
        expectClose(began.first ?? -1, 864.0 / 48000, within: 0.000_1, "the tap's track begins 18.0 ms after the picture: \(began)")
        expectClose(began.last ?? -1, 583.0 / 48000, within: 0.000_1, "the backup's 12.1 ms after it: \(began)")
        let (mixURL, plan, _) = try await mixed(run)
        expectClose(plan.alignment?.offset ?? 0, Double(apart) / 48000, within: 0.000_5, "22.4 ms on the file's timeline, the beginnings counted")
        expectEqual(plan.segments.map(\.source), [.tap], "the tap throughout")
        let mixTrack = try await AVURLAsset(url: mixURL).loadTracks(withMediaType: .audio)
        let mixFirst = try await mixTrack.first?.load(.segments).first
        expect(mixFirst?.isEmpty == false, "the mix's audio begins with the picture")
        // Read as a player plays them: every track on the file's timeline
        let tap = try monoTrack(run.recording.rawURL, track: 0), backup = try monoTrack(run.recording.rawURL, track: 1), mix = try monoTrack(mixURL, track: 0)
        func found(_ reference: [Float], in other: [Float]) -> Int? {
            let searched = Array(other[(192_000 - 14400)..<(240_000 + 14400)])
            return SystemAudioAlignment.lag(of: Array(reference[192_000..<240_000]), in: searched, margin: 14400, most: 12000, width: 24)
        }
        expect(abs((found(backup, in: tap) ?? 0) - apart) <= 2, "the tracks as recorded are 22.4 ms apart: \(String(describing: found(backup, in: tap)))")
        expect(abs(found(backup, in: mix) ?? 1000) <= 48, "the mix within 1 ms of the backup, by correlation: \(String(describing: found(backup, in: mix)))")
        expect(abs((found(tap, in: mix) ?? 0) + apart) <= 48, "which is 22.4 ms before the tap's track: \(String(describing: found(tap, in: mix)))")
        let inBackup = clicks(in: backup, from: 5.5, to: 6.5), inMix = clicks(in: mix, from: 5.5, to: 6.5)
        expectEqual([inBackup.count, inMix.count], [1, 1], "the click once in each")
        if let backupClick = inBackup.first, let mixClick = inMix.first {
            expectClose(backupClick.time, 6 + 583.0 / 48000, within: 0.000_5, "the backup's track has the click 12.1 ms after its place in the sound")
            expectClose(mixClick.time, backupClick.time, within: 0.001, "and the mix has it there, within 1 ms")
        }
        expect(likeness(mix, backup, from: 1, to: 11) > 0.8, "the mix against the backup's track: \(likeness(mix, backup, from: 1, to: 11))")
    }

    await test("alignment: a tap dead for a stretch: the backup fills exactly that stretch, and a click at each switch is in the mix once") {
        // The tap's track has nothing from 8 s to 11 s: the sound it is missing is the backup's from 8 s - 52.4 ms on.
        // A click right on each edge (half of it in the tap's track), one inside the outage and one far from it.
        let edges = [8 * 48000 - tapDelay, 11 * 48000 - tapDelay]
        let sound = TestSound(seconds: 16, clicks: edges + [Int(9.5 * 48000), 4 * 48000])
        let run = try await recordApart("apart-dead", seconds: 16, sound: sound, tapDead: { $0 >= 8 && $0 < 11 })
        let (mixURL, plan, spans) = try await mixed(run)
        expectEqual(spans.spans.count, 2, "the tap's two stretches: \(spans.spans)")
        expectClose(plan.alignment?.offset ?? 0, 0.0524, within: 0.000_5, "measured around the outage")
        expectEqual(plan.segments.map(\.source), [.tap, .backup, .tap], "the tap, the backup, the tap: \(plan.segments)")
        if plan.segments.count == 3 {
            expectClose(plan.segments[1].start, 8 - delay, within: 0.001, "the backup from where the tap's sound ends")
            expectClose(plan.segments[1].end, 11 - delay, within: 0.001, "to where it begins again")
        }
        expect(RecLog.lines.contains { $0.contains("System audio in the mix:") && $0.contains("3.0 s from the backup in 1 stretch") }, "the log: \(RecLog.lines)")
        let backup = try monoTrack(run.recording.rawURL, track: 1), mix = try monoTrack(mixURL, track: 0)
        for (name, time) in [("where the tap died", 8 - delay), ("where it came back", 11 - delay), ("inside the outage", 9.5), ("far from it", 4.0)] {
            let inMix = clicks(in: mix, from: time - 0.3, to: time + 0.3), inBackup = clicks(in: backup, from: time - 0.3, to: time + 0.3)
            expectEqual(inMix.count, 1, "the click \(name) is in the mix once: \(inMix)")
            guard let mixClick = inMix.first, let backupClick = inBackup.first else { continue }
            expectClose(mixClick.time, time, within: 0.001, "the click \(name), at its time")
            expectClose(mixClick.energy / backupClick.energy, 1, within: 0.25, "the click \(name), whole and not doubled")
            expect(likeness(mix, backup, from: time - 0.25, to: time + 0.25) > 0.8, "the sound goes on unbroken \(name): \(likeness(mix, backup, from: time - 0.25, to: time + 0.25))")
        }
        expect(likeness(mix, backup, from: 1, to: 15) > 0.8, "one sound from start to end: \(likeness(mix, backup, from: 1, to: 15))")
    }

    await test("alignment: a tap that delivers zeros for 5 s while the backup has sound: the backup is used there") {
        let sound = TestSound(seconds: 16, clicks: [Int(8.5 * 48000)])
        let run = try await recordApart("apart-zeros", seconds: 16, sound: sound, tapZeros: { $0 >= 6 && $0 < 11 })
        let (mixURL, plan, spans) = try await mixed(run)
        expectEqual(spans.spans.count, 1, "the tap counts as alive throughout: \(spans.spans)")
        expectClose(plan.alignment?.offset ?? 0, 0.0524, within: 0.000_5, "measured where both have the sound")
        expectEqual(plan.segments.map(\.source), [.tap, .backup, .tap], "the tap, the backup, the tap: \(plan.segments)")
        if plan.segments.count == 3 {
            // Told from the sound in 10 ms steps, and the codec spreads sound a little into silence
            expectClose(plan.segments[1].start, 6 - delay, within: 0.06, "the backup from where the zeros begin")
            expectClose(plan.segments[1].end, 11 - delay, within: 0.06, "to where they end")
        }
        let backup = try monoTrack(run.recording.rawURL, track: 1), mix = try monoTrack(mixURL, track: 0)
        expect(likeness(mix, backup, from: 6.2, to: 10.8) > 0.8, "the backup's sound where the tap had none: \(likeness(mix, backup, from: 6.2, to: 10.8))")
        expectEqual(clicks(in: mix, from: 8, to: 9).count, 1, "with its click")
        expect(likeness(mix, backup, from: 1, to: 15) > 0.8, "and one sound from start to end: \(likeness(mix, backup, from: 1, to: 15))")
    }

    await test("alignment: the backup silent throughout (FaceTime): the tap is used as it was stamped") {
        let sound = TestSound(seconds: 8, clicks: [4 * 48000 - tapDelay])
        let run = try await recordApart("apart-facetime", seconds: 8, sound: sound, backupSilent: true)
        let (mixURL, plan, _) = try await mixed(run)
        expectEqual(plan.alignment, SystemAudioAlignment.Measurement.none, "nothing to measure by")
        expectEqual(plan.segments.map(\.source), [.tap], "the tap throughout")
        expect(RecLog.lines.contains { $0.hasPrefix("System audio alignment: not measured") && $0.contains("used as it was stamped") }, "the log says so: \(RecLog.lines)")
        let tap = try monoTrack(run.recording.rawURL, track: 0), mix = try monoTrack(mixURL, track: 0)
        let inTap = clicks(in: tap, from: 3.5, to: 4.5), inMix = clicks(in: mix, from: 3.5, to: 4.5)
        expectEqual([inTap.count, inMix.count], [1, 1], "the click once in each")
        if let tapClick = inTap.first, let mixClick = inMix.first {
            expectClose(tapClick.time, 4, within: 0.000_5, "in the tap's track at 4 s")
            expectClose(mixClick.time, tapClick.time, within: 0.000_5, "and in the mix where the tap's track has it")
        }
        expect(likeness(mix, tap, from: 1, to: 7) > 0.8, "the mix is the tap's track: \(likeness(mix, tap, from: 1, to: 7))")
    }
}
