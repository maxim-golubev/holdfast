//
//  BackupTests.swift
//  The backup of the system audio while the process tap records it: the tap's spans, the choice of source stretch
//  by stretch, the writer's three audio tracks, the mix and its check, the merge of a sound-only recording, and
//  recovery. The tap's audio is a 440 Hz tone and the backup's a 1000 Hz one, so the mix tells which it holds.
//

import AVFoundation
import Foundation

/// 48 kHz stereo float, one buffer per channel (ScreenCaptureKit's system audio format), of a tone at `frequency`
/// whose phase follows the time `seconds`, so buffers one after the other make one continuous tone
func toneBuffer(frequency: Double, at seconds: Double, pts: CMTime, frames: Int = 4800, amplitude: Float = 0.2, channels: UInt32 = 2) throws -> CMSampleBuffer {
    let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels), "format")
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), "pcm")
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = try require(pcm.floatChannelData, "data")
    for frame in 0..<frames {
        let value = amplitude * Float(sin(2 * Double.pi * frequency * (seconds + Double(frame) / 48000)))
        for channel in 0..<Int(channels) { data[channel][frame] = value }
    }
    return try require(AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: pts), "sample buffer")
}

/// How strong each of `frequencies` is in every 10 ms of an audio track (or of an audio file when `track` is nil)
func toneStrengths(_ url: URL, track index: Int? = 0, frequencies: [Double]) throws -> [[Float]] {
    var mono = [Float]()
    if let index {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TestError("cannot read") }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = buffer.dataBuffer else { continue }
            let count = CMBlockBufferGetDataLength(block) / 4
            var values = [Float](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { bytes in bytes.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0) } }
            // Placed at the buffer's own time
            let first = Int((CMTimeGetSeconds(buffer.presentationTimeStamp) * 48000).rounded())
            if mono.count < first { mono.append(contentsOf: repeatElement(0, count: first - mono.count)) }
            mono.append(contentsOf: values)
        }
    } else {
        let file = try AVAudioFile(forReading: url)
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), "buffer")
        try file.read(into: pcm)
        let data = try require(pcm.floatChannelData, "data")
        mono = (0..<Int(pcm.frameLength)).map { data[0][$0] }
    }
    let size = 480
    return frequencies.map { frequency in
        let omega = 2 * Double.pi * frequency / 48000
        let cosines = (0..<size).map { Float(cos(omega * Double($0))) }
        let sines = (0..<size).map { Float(sin(omega * Double($0))) }
        return stride(from: 0, to: mono.count - size, by: size).map { start in
            var re: Float = 0, im: Float = 0
            mono.withUnsafeBufferPointer { samples in
                for k in 0..<size {
                    re += samples[start + k] * cosines[k]
                    im += samples[start + k] * sines[k]
                }
            }
            return (re * re + im * im).squareRoot() / Float(size)
        }
    }
}

/// Which tone each 10 ms holds: "t" the tap's (440 Hz), "b" the backup's (1000 Hz), "-" neither, "?" both
func sources(_ strengths: [[Float]]) -> [Character] {
    return zip(strengths[0], strengths[1]).map { tap, backup in
        if tap < 0.005 && backup < 0.005 { return "-" }
        if tap > 4 * backup { return "t" }
        if backup > 4 * tap { return "b" }
        return "?"
    }
}

/// Where each run of the same source begins, in seconds, and which source it is
func runs(_ marks: [Character]) -> [(start: Double, source: Character)] {
    var found = [(start: Double, source: Character)]()
    for (index, mark) in marks.enumerated() where mark != "?" && found.last?.source != mark {
        found.append((Double(index) * 0.01, mark))
    }
    return found
}

/// A recording made with the process tap through the real writer: video, the tap (440 Hz), its backup (1000 Hz),
/// a quiet microphone (3000 Hz), a tenth of a second at a time, with the monitor's fills. The tap delivers nothing
/// where `tapDead` says.
func recordWithBackup(_ folder: String, seconds: Double, microphone: Bool = true, remux: Bool = true, tapDead: (Double) -> Bool,
                      backupSilent: (Double) -> Bool = { _ in false }) throws -> TestRecording {
    let run = try TestRecording(folder: folder, microphone: microphone, settings: ["remuxAudio": remux, "recordWinSound": true], tap: true)
    let writer = run.writer
    try writer.prepareVideo(width: 320, height: 240)
    writer.startCapturing()
    var step = 0
    while Double(step) / 10 < seconds - 0.001 {
        let t = Double(step) / 10
        try run.frame(t)
        if !tapDead(t) {
            writer.write(CaptureSample(kind: .audio, buffer: try toneBuffer(frequency: 440, at: t, pts: run.at(t)), pts: run.at(t)))
        }
        writer.write(CaptureSample(kind: .backupAudio, buffer: try toneBuffer(frequency: 1000, at: t, pts: run.at(t), amplitude: backupSilent(t) ? 0 : 0.2), pts: run.at(t)))
        if microphone {
            writer.write(CaptureSample(kind: .microphone, buffer: try toneBuffer(frequency: 3000, at: t, pts: run.at(t), amplitude: 0.01, channels: 1), pts: run.at(t)))
        }
        // What the monitor does: tracks more than half a second behind a second ago are continued with silence
        let target = run.at(t + 0.1 - 1)
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.audioEndPTS ?? run.at(0))) >= 0.5 { writer.fillSystemAudio(upTo: target) }
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.backupEndPTS ?? run.at(0))) >= 0.5 { writer.fillBackupAudio(upTo: target) }
        usleep(15_000)
        step += 1
    }
    return run
}

func backupTests() async {
    await test("tap spans: read back as written, an open one lasting to the end") {
        let spans = TapSpans.parse(TapSpans.line(alive: 0) + TapSpans.line(dead: 27) + TapSpans.line(alive: 28.25) + "noise\n" + TapSpans.line(dead: 29) + TapSpans.line(alive: 40))
        expectEqual(spans.spans, [.init(start: 0, end: 27), .init(start: 28.25, end: 29), .init(start: 40, end: .infinity)], "three stretches")
        expect(spans.covers(1, 26.9) && !spans.covers(26.9, 27.1) && spans.covers(28.25, 28.5) && spans.covers(100, 200), "what they cover")
        expect(spans.isAlive(at: 27, after: false) && !spans.isAlive(at: 27, after: true), "alive up to an edge, dead after it")
        expectEqual(spans.edges(in: 0...30), [0, 27, 28.25, 29], "the edges")
        expectClose(spans.aliveSeconds(upTo: 50), 27 + 0.75 + 10, within: 1e-9, "seconds alive")
        expectEqual(TapSpans.parse("").spans, [], "an empty file: never alive")
        expect(TapSpans.read(URL(fileURLWithPath: "/nonexistent/spans")) == nil, "no file: not known")
    }

    await test("system audio choice: the tap where it delivered with signal, the backup where it was dead, never both") {
        let blocks = 3000 // 30 s
        let sound = [Float](repeating: 0.1, count: blocks)
        let quiet = [Float](repeating: 0, count: blocks)
        func tapLevels(_ dead: (Double) -> Bool) -> [Float] { (0..<blocks).map { dead(Double($0) / 100) ? 0 : 0.1 } }
        // Today's case: the tap dies at 27 s and is repaired at 28 s
        let spans = TapSpans([.init(start: 0, end: 27), .init(start: 28, end: 30)])
        let plan = SystemAudioChoice.plan(tap: tapLevels { $0 >= 27 && $0 < 28 }, backup: sound, spans: spans, duration: 30)
        expectEqual(plan, [.init(start: 0, end: 27, source: .tap), .init(start: 27, end: 28, source: .backup), .init(start: 28, end: 30, source: .tap)], "switched where the spans say, to the sample")
        let gain = SystemAudioChoice.tapGain(for: plan, spans: spans)
        expectEqual(gain.value(at: 26.99), 1, "the tap up to just before it died")
        expectEqual(gain.value(at: 27), 0, "the backup from the moment it died: the fade lies before")
        expectClose(Double(gain.value(at: 26.9975)), 0.5, within: 0.001, "a 5 ms fade")
        expectEqual(gain.value(at: 28), 0, "the backup until the tap is back: the fade lies after")
        expectEqual(gain.value(at: 28.005), 1, "the tap 5 ms later")
        // A switch off a span's edge: cut there, not at the next window
        let odd = TapSpans([.init(start: 0, end: 12.34), .init(start: 13.71, end: 30)])
        expectEqual(SystemAudioChoice.plan(tap: tapLevels { $0 >= 12.34 && $0 < 13.71 }, backup: sound, spans: odd, duration: 30).map(\.start), [0, 12.34, 13.71], "at the edges")
        // Dead from the start
        expectEqual(SystemAudioChoice.plan(tap: quiet, backup: sound, spans: TapSpans([]), duration: 30), [.init(start: 0, end: 30, source: .backup)], "the backup throughout")
        // FaceTime: only the tap hears the call
        expectEqual(SystemAudioChoice.plan(tap: sound, backup: quiet, spans: TapSpans([.init(start: 0, end: 30)]), duration: 30), [.init(start: 0, end: 30, source: .tap)], "the tap")
        // Both alive and hearing the same: the tap alone
        expectEqual(SystemAudioChoice.plan(tap: sound, backup: sound, spans: TapSpans([.init(start: 0, end: 30)]), duration: 30), [.init(start: 0, end: 30, source: .tap)], "no doubling")
        // A tap that delivers only zeros (no permission) while the backup hears
        expectEqual(SystemAudioChoice.plan(tap: quiet, backup: sound, spans: TapSpans([.init(start: 0, end: 30)]), duration: 30), [.init(start: 0, end: 30, source: .backup)], "content decides between two that are alive")
        // Silence does not switch: a pause in a call keeps the tap
        var pauses = sound
        for index in 1000..<1500 { pauses[index] = 0 }
        let both = SystemAudioChoice.plan(tap: pauses, backup: pauses, spans: TapSpans([.init(start: 0, end: 30)]), duration: 30)
        expectEqual(both, [.init(start: 0, end: 30, source: .tap)], "silence in both keeps the source")
        // Not known where the tap delivered: its sound alone
        expectEqual(SystemAudioChoice.plan(tap: tapLevels { $0 >= 10 && $0 < 12 }, backup: sound, spans: nil, duration: 30).map(\.source), [.tap, .backup, .tap], "judged by the sound")
        expect(SystemAudioChoice.summary(plan).contains("1.0 s from the backup in 1 stretch"), "for the log: \(SystemAudioChoice.summary(plan))")
        // The curve read sample by sample
        var cursor = 0
        var gains = [Float]()
        gain.values(from: Int64(26.99 * 48000), count: 960, rate: 48000, cursor: &cursor, into: &gains)
        expectEqual(gains[0], 1, "before the fade")
        expectEqual(gains[959], 0, "after it")
        expect(zip(gains, gains.dropFirst()).allSatisfy { $0 >= $1 }, "going down smoothly")
    }

    await test("backup: the writer records the tap, its backup and the microphone as three titled tracks, and the tap's spans") {
        let run = try recordWithBackup("backup-writer", seconds: 4, tapDead: { $0 >= 1.5 && $0 < 2.5 })
        let spansURL = try require(run.recording.tapSpansURL, "spans file")
        expect(FileManager.default.fileExists(atPath: spansURL.path), "written next to the recording while it runs")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let asset = AVURLAsset(url: run.recording.rawURL)
        let audio = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var titles = [String?]()
        for track in audio { titles.append(try await RecordingMixer.title(of: track)) }
        expectEqual(titles, ["System audio (tap)", "System audio (backup)", "Microphone"], "titled")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        for (name, track) in zip(["tap", "backup", "microphone"], tracks.audio) {
            expectClose(track.end, 4, within: 0.25, "the \(name) track is as long as the recording")
        }
        let spans = try require(TapSpans.read(spansURL), "spans")
        expectEqual(spans.spans.count, 2, "two stretches: \(spans.spans)")
        expectClose(spans.spans.first?.end ?? 0, 1.5, within: 0.001, "the tap stopped at 1.5 s")
        expectClose(spans.spans.last?.start ?? 0, 2.5, within: 0.001, "and was back at 2.5 s")
        expectClose(spans.spans.last?.end ?? 0, 4, within: 0.001, "until the end")
        expectEqual(run.recording.unmixedURL?.lastPathComponent.hasSuffix(" (unmixed, 3 audio tracks).mp4"), true, "named for its three tracks")
        // A start that fails leaves no spans behind
        let failed = try TestRecording(folder: "backup-cancel", settings: ["remuxAudio": true, "recordWinSound": true], tap: true)
        try failed.writer.prepareVideo(width: 320, height: 240)
        failed.writer.cancel()
        expect(!FileManager.default.fileExists(atPath: failed.recording.tapSpansURL?.path ?? ""), "removed with the empty file")
    }

    await test("backup: today's meeting, the tap dying at 27 s and repaired at 28 s: the mix is the backup there and the tap elsewhere, to 0.02 s") {
        let run = try recordWithBackup("backup-27", seconds: 30, tapDead: { $0 >= 27 && $0 < 28 })
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let raw = run.recording.rawURL
        let mixURL = try require(run.recording.mixURL, "mix name")
        let spans = TapSpans.read(try require(run.recording.tapSpansURL, "spans file"))
        let plan = try await RecordingMixer.mix(source: raw, output: mixURL, fileType: .mp4, audioSettings: run.recording.audioSettings, tapSpans: spans) { _ in }
        try await RecordingMixer.verify(source: raw, output: mixURL, plan: plan)
        expectEqual(plan.segments.map(\.source), [.tap, .backup, .tap], "the tap, the backup, the tap")
        let found = runs(sources(try toneStrengths(mixURL, frequencies: [440, 1000])))
        expectEqual(found.map(\.source), ["t", "b", "t"], "the mix holds the tap, then the backup, then the tap again: \(found)")
        if found.count == 3 {
            expectClose(found[1].start, 27, within: 0.02, "the backup from where the tap died")
            expectClose(found[2].start, 28, within: 0.02, "the tap from where it was repaired")
        }
        expect(RecLog.lines.contains { $0.contains("System audio in the mix:") && $0.contains("from the backup in 1 stretch") }, "the log says what the mix took: \(RecLog.lines)")
    }

    await test("backup: a tap dead from the start is replaced by the backup throughout") {
        let run = try recordWithBackup("backup-dead", seconds: 4, tapDead: { _ in true })
        _ = try await run.close()
        let mixURL = try require(run.recording.mixURL, "mix name")
        let spans = TapSpans.read(try require(run.recording.tapSpansURL, "spans file"))
        expectEqual(spans?.spans, [], "the tap never delivered")
        let plan = try await RecordingMixer.mix(source: run.recording.rawURL, output: mixURL, fileType: .mp4, audioSettings: run.recording.audioSettings, tapSpans: spans) { _ in }
        try await RecordingMixer.verify(source: run.recording.rawURL, output: mixURL, plan: plan)
        let marks = sources(try toneStrengths(mixURL, frequencies: [440, 1000]))
        // A buffer the writer's input was not ready for is a splice in the tone: a block or two of either
        let inner = marks.dropFirst(5).dropLast(5)
        expect(inner.filter { $0 == "b" }.count >= inner.count - 2 && !inner.contains("-"), "the backup's sound all along: \(runs(marks))")
    }

    /// A recording laid out as the writer does with the tap, from tones: 4 s of video, the tap, the backup, the microphone
    func movie(_ name: String, tap: @escaping Loudness, backup: @escaping Loudness, microphone: @escaping Loudness = { _ in 0 }) async throws -> URL {
        let url = try Suite.folder("backup-mixer").appendingPathComponent("\(name).recording.mp4")
        try await TestMovie.write(to: url, seconds: 4, audio: [tap, backup, microphone])
        return url
    }

    await test("backup: FaceTime (the backup silent) is the tap's; both alive is the tap's alone; both dead is silence") {
        let folder = try Suite.folder("backup-mixer")
        let alive = TapSpans([.init(start: 0, end: 4)])
        func mixed(_ source: URL, spans: TapSpans?) async throws -> (URL, RecordingMixer.MixPlan) {
            let output = folder.appendingPathComponent(source.lastPathComponent.replacingOccurrences(of: ".recording.", with: ".mixing."))
            let plan = try await RecordingMixer.mix(source: source, output: output, fileType: .mp4, audioSettings: TestMovie.aac, tapSpans: spans) { _ in }
            try await RecordingMixer.verify(source: source, output: output, plan: plan)
            return (output, plan)
        }
        let faceTime = try await movie("facetime", tap: { _ in 0.2 }, backup: { _ in 0 })
        let (faceTimeMix, faceTimePlan) = try await mixed(faceTime, spans: alive)
        expectEqual(faceTimePlan.segments.map(\.source), [.tap], "the tap, which hears the call")
        expectClose(try TestMovie.level(of: faceTimeMix, from: 0.5, to: 3.5), 0.141, within: 0.015, "at the tap's level")
        let both = try await movie("both", tap: { _ in 0.2 }, backup: { _ in 0.2 })
        let (bothMix, bothPlan) = try await mixed(both, spans: alive)
        expectEqual(bothPlan.segments.map(\.source), [.tap], "the tap")
        expectClose(try TestMovie.level(of: bothMix, from: 0.5, to: 3.5), 0.141, within: 0.015, "at its level, not twice it")
        let dead = try await movie("dead", tap: { _ in 0 }, backup: { _ in 0 })
        let (deadMix, _) = try await mixed(dead, spans: TapSpans([]))
        expectClose(try TestMovie.level(of: deadMix, from: 0.1, to: 3.9), 0, within: 0.000_1, "silence")
        // The microphone is mixed in as before
        let call = try await movie("call", tap: { $0 < 2 ? 0.2 : 0 }, backup: { $0 < 2 ? 0.2 : 0 }, microphone: { $0 >= 2 ? 0.3 : 0 })
        let (callMix, _) = try await mixed(call, spans: alive)
        expectClose(try TestMovie.level(of: callMix, from: 2.5, to: 3.5), 0.212, within: 0.02, "the microphone where it is alone")
        expectClose(try TestMovie.level(of: callMix, from: 0.5, to: 1.5), 0.141, within: 0.015, "the system audio once where it is alone")
    }

    await test("backup: the check rejects a mix without the system audio and one that has it twice") {
        let source = try await movie("check", tap: { _ in 0.2 }, backup: { _ in 0.2 })
        let folder = source.deletingLastPathComponent()
        let plan = RecordingMixer.MixPlan(segments: [.init(start: 0, end: 4, source: .tap)], separateMicrophone: false)
        let doubled = folder.appendingPathComponent("doubled.mp4")
        try await TestMovie.write(to: doubled, seconds: 4, audio: [{ _ in 0.4 }])
        let twice = await expectThrows("a mix with both sources at once") { try await RecordingMixer.verify(source: source, output: doubled, plan: plan) }
        expect(twice.contains("system audio"), "the reason names the system audio: \(twice)")
        let missing = folder.appendingPathComponent("missing.mp4")
        try await TestMovie.write(to: missing, seconds: 4, audio: [{ _ in 0 }])
        await expectThrows("a mix without the system audio") { try await RecordingMixer.verify(source: source, output: missing, plan: plan) }
        let right = folder.appendingPathComponent("right.mp4")
        try await TestMovie.write(to: right, seconds: 4, audio: [{ _ in 0.2 }])
        try await RecordingMixer.verify(source: source, output: right, plan: plan)
    }

    await test("backup: with the microphone kept apart, the system audio is still one track, the microphone a second") {
        let run = try recordWithBackup("backup-separate", seconds: 3, remux: false, tapDead: { $0 >= 1 && $0 < 2 })
        expect(run.recording.separatesMicrophone, "the microphone is kept apart")
        expectEqual(run.recording.rawURL.lastPathComponent.contains(".recording."), true, "written under the temporary name all the same")
        _ = try await run.close()
        let mixURL = try require(run.recording.mixURL, "mix name")
        let spans = TapSpans.read(try require(run.recording.tapSpansURL, "spans file"))
        let plan = try await RecordingMixer.mix(source: run.recording.rawURL, output: mixURL, fileType: .mp4, audioSettings: run.recording.audioSettings,
                                                tapSpans: spans, separateMicrophone: true) { _ in }
        try await RecordingMixer.verify(source: run.recording.rawURL, output: mixURL, plan: plan)
        let asset = AVURLAsset(url: mixURL)
        let audio = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var titles = [String?]()
        for track in audio { titles.append(try await RecordingMixer.title(of: track)) }
        expectEqual(titles, ["System audio", "Microphone"], "two titled tracks")
        let found = runs(sources(try toneStrengths(mixURL, frequencies: [440, 1000])))
        expectEqual(found.map(\.source), ["t", "b", "t"], "the system audio track switches like the mix: \(found)")
        let microphone = try toneStrengths(mixURL, track: 1, frequencies: [3000])[0]
        expect(microphone.dropFirst(10).dropLast(10).allSatisfy { $0 > 0.002 }, "the microphone is there, on its own")
    }

    await test("backup: a sound-only recording starts with the backup when the tap is dead, and its system audio is merged afterwards") {
        let run = try TestRecording(folder: "backup-sound", audioOnly: true, microphone: false, settings: ["recordWinSound": true, "audioFormat": "aac"], tap: true)
        let writer = run.writer
        try writer.prepareAudio()
        let backupURL = try require(run.recording.backupAudioURL, "backup file")
        expect(backupURL.lastPathComponent.hasSuffix(" (system audio backup).recording.m4a"), "written next to the recording: \(backupURL.lastPathComponent)")
        writer.startCapturing()
        for step in 0..<40 {
            let t = Double(step) / 10
            if t >= 1 && !(t >= 2 && t < 3) {
                writer.write(CaptureSample(kind: .audio, buffer: try toneBuffer(frequency: 440, at: t, pts: run.at(t)), pts: run.at(t)))
            }
            writer.write(CaptureSample(kind: .backupAudio, buffer: try toneBuffer(frequency: 1000, at: t, pts: run.at(t)), pts: run.at(t)))
            if step == 0 { expectEqual(writer.sessionStart, run.at(0), "the backup's first buffer starts the recording") }
            let target = run.at(t + 0.1 - 1)
            if CMTimeGetSeconds(CMTimeSubtract(target, writer.audioEndPTS ?? run.at(0))) >= 0.5 { writer.fillSystemAudio(upTo: target) }
        }
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tapURL = try require(run.recording.systemAudioURL, "tap file")
        let spans = try require(TapSpans.read(try require(run.recording.tapSpansURL, "spans file")), "spans")
        expectEqual(spans.spans.count, 2, "the tap's two stretches: \(spans.spans)")
        expectClose(spans.spans.first?.start ?? 0, 1, within: 0.001, "the first from 1 s, where the file has it")
        let merged = tapURL.deletingLastPathComponent().appendingPathComponent("merged.m4a")
        try RecordingMixer.mergeSystemAudio(tap: tapURL, backup: backupURL, spans: spans, to: merged, settings: run.recording.audioSettings)
        let found = runs(sources(try toneStrengths(merged, track: nil, frequencies: [440, 1000])))
        expectEqual(found.map(\.source), ["b", "t", "b", "t"], "the backup until the tap began, then where it was dead: \(found)")
        if found.count == 4 {
            expectClose(found[1].start, 1, within: 0.03, "the tap from 1 s")
            expectClose(found[2].start, 2, within: 0.03, "the backup from 2 s")
            expectClose(found[3].start, 3, within: 0.03, "the tap again from 3 s")
        }
        // The merged file takes the tap's name; the two sources are kept beside it or deleted
        let keptTap = try require(run.recording.tapKeptURL, "name of the kept tap file")
        try RecordingFileStore.adoptMergedSystemAudio(merged: merged, tap: tapURL, keptTap: keptTap, backup: backupURL, keepSources: false)
        expect(FileManager.default.fileExists(atPath: tapURL.path) && !FileManager.default.fileExists(atPath: merged.path), "the merged file under the tap's name")
        expect(!FileManager.default.fileExists(atPath: keptTap.path) && !FileManager.default.fileExists(atPath: backupURL.path), "the sources deleted")
    }

    await test("backup: a recording killed after a tap outage is recovered with its spans, which then go") {
        let run = try recordWithBackup("backup-kill", seconds: 12, tapDead: { $0 >= 5 && $0 < 6 })
        let folder = try Suite.folder("backup-recovery")
        let snapshot = folder.appendingPathComponent("Recording at K.recording.mp4")
        var copied = false
        for _ in 0..<50 where !copied {
            try? FileManager.default.removeItem(at: snapshot)
            try FileManager.default.copyItem(at: run.recording.rawURL, to: snapshot)
            if let seconds = await RecordingMixer.inspect(snapshot).seconds, seconds >= 9 { copied = true } else { usleep(100_000) }
        }
        let spansCopy = RecordingFileStore.tapSpansURL(base: folder.appendingPathComponent("Recording at K").path)
        try FileManager.default.copyItem(at: try require(run.recording.tapSpansURL, "spans"), to: spansCopy)
        _ = try await run.close()
        expect(copied, "a fragment reached the disk")
        let inspection = await RecordingMixer.inspect(snapshot)
        expect(inspection.mixable && inspection.audioTracks == 3, "three audio tracks, mixable")
        let lines = await RecordingRecovery.recover(RecordingFileStore(directory: folder.path).leftovers(), audioSettings: ["mp4": TestMovie.aac]) { _ in }
        expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                    ["Recording at K (recovered).mp4", "Recording at K (recovered, unmixed, 3 audio tracks).mp4"], "the folder afterwards, without the spans")
        expect(lines.count == 1 && lines[0].contains("mixed now"), "the report: \(lines)")
        let found = runs(sources(try toneStrengths(folder.appendingPathComponent("Recording at K (recovered).mp4"), frequencies: [440, 1000])))
        // A file cut off by the kill ends each track where its last fragment did: past the tap's end the backup has it
        expectEqual(found.prefix(3).map(\.source), ["t", "b", "t"], "the outage taken from the backup: \(found)")
        if found.count >= 3 {
            expectClose(found[1].start, 5, within: 0.02, "from where the tap died")
            expectClose(found[2].start, 6, within: 0.02, "to where it was back")
        }
    }

    await test("backup: file names of a recording made with the tap") {
        let base = "/save/Recording at X"
        let video = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioFormat: .aac, systemAudioBackup: true)
        expectEqual(video.rawURL.lastPathComponent, "Recording at X.recording.mp4", "written under the temporary name")
        expectEqual(video.unmixedURL?.lastPathComponent, "Recording at X (unmixed, 3 audio tracks).mp4", "three tracks as written")
        expectEqual(video.tapSpansURL?.lastPathComponent, "Recording at X.tap-alive.txt", "the tap's spans next to it")
        expectEqual(video.audioTracks, 3, "tap, backup, microphone")
        expect(!video.separatesMicrophone, "the microphone mixed in")
        let noMic = RecordingFiles(base: base, audioOnly: false, recordMic: false, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioFormat: .aac, systemAudioBackup: true)
        expect(noMic.mixURL != nil, "without a microphone the system audio is still brought to one track")
        expectEqual(noMic.unmixedURL?.lastPathComponent, "Recording at X (unmixed, 2 audio tracks).mp4", "two tracks: the tap and its backup")
        let apart = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: false, videoEnding: "mov", audioFormat: .aac, systemAudioBackup: true)
        expect(apart.mixURL != nil && apart.separatesMicrophone, "with the microphone apart too")
        let plain = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioFormat: .aac)
        expect(plain.tapSpansURL == nil && plain.audioTracks == 2, "without the tap: no spans, two tracks")
        let package = RecordingFiles(base: base, audioOnly: true, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioFormat: .flac, systemAudioBackup: true)
        expectEqual(package.backupAudioURL?.path, base + ".recording.qma/sys-backup.caf", "the backup in the package")
        expectEqual(package.backupClosedURL?.path, base + ".qma/sys-backup.caf", "where it is once closed")
        expectEqual(package.tapKeptURL?.path, base + ".qma/sys-tap.caf", "and the tap's own file when it is kept")
        let single = RecordingFiles(base: base, audioOnly: true, recordMic: false, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioFormat: .aac, systemAudioBackup: true)
        expectEqual(single.backupAudioURL?.lastPathComponent, "Recording at X (system audio backup).recording.m4a", "a file of its own, under a temporary name")
        expectEqual(single.backupClosedURL?.lastPathComponent, "Recording at X (system audio backup).m4a", "renamed once closed")
        expectEqual(single.tapKeptURL?.lastPathComponent, "Recording at X (system audio tap).m4a", "the tap's own file when kept")
        expectEqual(RecoveryNames.recording(complete: false, mixed: true, tracks: 3), "recovered, unmixed, 3 audio tracks", "recovery counts the tracks")
        expectEqual(RecoveryNames.unmixed, "unmixed, 2 audio tracks", "as before for two")
    }
}
