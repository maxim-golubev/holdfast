//
//  ArrivalTests.swift
//  Nothing is placed, or left out, by a device's timestamp that disagrees with when the buffer arrived. On
//  2026-10-06 the other side of a 47-minute meeting was lost: the process tap's device stamped its buffers some
//  seconds in the past, every one of them then lay "before the end of the track" and was left out, while the IOProc
//  kept running and nothing was rebuilt.
//

import AVFoundation
import Foundation

/// 48 kHz stereo as the tap and ScreenCaptureKit deliver it, each sample telling which one it is: sample `i` of the
/// source is `(i % sawPeriod + 1) / 32768`, never zero, and exact in a lossless 16-bit file
let sawPeriod = 20000

func sawPCM(first: Int, frames: Int = 480) throws -> AVAudioPCMBuffer {
    let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), "format")
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), "pcm buffer")
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = try require(pcm.floatChannelData, "float data")
    for frame in 0..<frames {
        let value = Float((first + frame) % sawPeriod + 1) / 32768
        data[0][frame] = value
        data[1][frame] = value
    }
    return pcm
}

func sawBuffer(first: Int, frames: Int = 480, at pts: CMTime) throws -> CMSampleBuffer {
    let pcm = try sawPCM(first: first, frames: frames)
    return try require(AudioSilence.sampleBuffer(from: pcm, description: pcm.format.formatDescription, at: pts), "sample buffer")
}

/// What a file of `sawBuffer`s holds, counted: the samples that are sound, how many of them do not follow the sound
/// before them (a piece missing, or a sample added or taken out), and the samples of silence between the first
/// sound and the last
func sawCount(in url: URL) throws -> (found: Int, breaks: Int, silent: Int) {
    var found = 0, breaks = 0, zeros = 0, silent = 0
    var last = 0
    for value in try sawValues(in: url) {
        if value == 0 {
            if found > 0 { zeros += 1 }
            continue
        }
        if found > 0, value != last % sawPeriod + 1 { breaks += 1 }
        last = value
        found += 1
        silent = zeros
    }
    return (found, breaks, silent)
}

/// What a lossless audio file holds, as the numbers `sawBuffer` wrote (0 is silence), left channel
func sawValues(in url: URL) throws -> [Int] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), "read buffer")
    try file.read(into: buffer)
    let data = try require(buffer.floatChannelData, "float data")
    return (0..<Int(buffer.frameLength)).map { Int((data[0][$0] * 32768).rounded()) }
}

/// Checks a file of the tap's audio against the `total` samples its IOProc delivered back to back from the start:
/// every one there, once, in order, none more than `buffer` samples after its place, and no more than `silence`
/// samples of silence in between
func expectEverySample(in url: URL, total: Int, buffer: Int = 480, silence: Int = 0) throws {
    let values = try sawValues(in: url)
    var found = 0
    var latest = 0
    var wrong = 0
    var lastSound = -1
    for (position, value) in values.enumerated() where value != 0 {
        if value != found % sawPeriod + 1 { wrong += 1 }
        latest = max(latest, abs(position - found))
        found += 1
        lastSound = position
    }
    expectEqual(found, total, "every sample the tap delivered is in the file, none twice")
    expectEqual(wrong, 0, "in the order they were delivered")
    expect(latest <= buffer, "each within one buffer of when it arrived: the furthest is \(latest) samples off")
    expect(lastSound + 1 - found <= silence, "no silence put between them: \(lastSound + 1 - found) samples")
}

/// A recording of sound only with the tap and its backup, lossless, with the tap's source and a monitor: fed by a
/// fake tap whose IOProc's host time is `ioTime`, in seconds of the test's clock
final class TapRig {
    let run: TestRecording
    let queue = DispatchQueue(label: "HoldfastTests.arrival")
    let fakes = FakeTapFactory()
    let monitor: RecordingMonitor
    var source: SystemAudioSource?
    var ioTime = 0.0
    var notified = [String]()
    /// What the source handed on, kept back when `holds` until the test writes it
    var holds = false
    var held = [CaptureSample]()

    init(folder: String) throws {
        run = try TestRecording(folder: folder, audioOnly: true, microphone: false, settings: ["recordWinSound": true, "audioFormat": "alac"], tap: true)
        monitor = RecordingMonitor(queue: queue)
        try run.writer.prepareAudio()
        monitor.notify = { [unowned self] title, _ in notified.append(title) }
        let writer = run.writer
        writer.events.systemAudioWritten = { [unowned self] end in
            run.systemAudioEnd = end
            monitor.systemAudioWritten(upTo: end)
        }
        writer.events.backupAudioWritten = { [unowned self] end in monitor.backupAudioWritten(upTo: end) }
        writer.startCapturing()
        queue.sync { monitor.watch(writer, from: DispatchTime.now().uptimeNanoseconds) }
        source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue, stallSeconds: 600, clock: { [unowned self] in run.at(ioTime) }) { [unowned self] sample in
            if holds { held.append(sample) } else { run.writer.write(sample) }
        }
        try source?.start()
    }

    /// The tap's IOProc is called at `time` with a buffer its device stamped `stamp`
    func io(first: Int, frames: Int = 480, stamped stamp: Double, at time: Double) throws {
        ioTime = time
        try require(fakes.taps.last, "a tap").deliver(try sawBuffer(first: first, frames: frames, at: run.at(stamp)))
        queue.sync {}
    }

    /// A tenth of a second of the backup, as ScreenCaptureKit hands it over a little after its end
    func backup(_ t: Double) throws {
        let buffer = try audioBuffer(rate: 48000, channels: 2, frames: 4800, at: run.at(t), amplitude: 0.2)
        queue.sync { run.writer.write(CaptureSample(kind: .backupAudio, buffer: buffer, pts: run.at(t), arrival: run.at(t + 0.11))) }
    }

    func tick() {
        queue.sync { monitor.tick(at: DispatchTime.now().uptimeNanoseconds) }
    }

    /// The present as the monitor would tell it now, in seconds of the test's clock
    func monitorPresent() throws -> Double {
        let anchor = try require(run.writer.clockAnchor, "clock anchor")
        let now = DispatchTime.now().uptimeNanoseconds
        return CMTimeGetSeconds(anchor.raw) - TestRecording.base + Double(now &- anchor.uptime) / 1_000_000_000
    }

    func finish() -> MovieWriter.Finished {
        source?.stopNow()
        queue.sync {}
        return queue.sync {
            monitor.stop()
            return run.writer.finish()
        }
    }
}

/// A video recording whose system audio is ScreenCaptureKit's, with a monitor, fed a tenth of a second at a time
final class StreamRig {
    let run: TestRecording
    let queue = DispatchQueue(label: "HoldfastTests.arrival")
    let monitor: RecordingMonitor
    var notified = [String]()

    init(folder: String) throws {
        run = try TestRecording(folder: folder, microphone: false, settings: ["recordWinSound": true])
        monitor = RecordingMonitor(queue: queue)
        try run.writer.prepareVideo(width: 320, height: 240)
        monitor.notify = { [unowned self] title, _ in notified.append(title) }
        let writer = run.writer
        writer.events.systemAudioWritten = { [unowned self] end in
            run.systemAudioEnd = end
            monitor.systemAudioWritten(upTo: end)
        }
        writer.startCapturing()
        queue.sync { monitor.watch(writer, from: DispatchTime.now().uptimeNanoseconds) }
    }

    /// A frame stamped `stamp` that arrives at `arrival`, which is the present then
    func frame(stamped stamp: Double, arrival: Double) throws {
        run.present = arrival
        let buffer = try videoFrame(at: run.at(stamp), shade: Int(arrival * 50))
        queue.sync { run.writer.write(CaptureSample(kind: .screen(complete: true), buffer: buffer, pts: run.at(stamp), arrival: run.at(arrival))) }
    }

    /// A tenth of a second of system audio stamped `stamp` that arrives at `arrival`; true when it was written
    func audio(stamped stamp: Double, arrival: Double) throws -> Bool {
        run.present = arrival
        let before = run.systemAudioEnd
        let buffer = try audioBuffer(rate: 48000, channels: 2, frames: 4800, at: run.at(stamp), amplitude: 0.2)
        queue.sync { run.writer.write(CaptureSample(kind: .audio, buffer: buffer, pts: run.at(stamp), arrival: run.at(arrival))) }
        return run.systemAudioEnd != before
    }

    func tick() {
        queue.sync { monitor.tick(at: DispatchTime.now().uptimeNanoseconds) }
        usleep(15_000)
    }

    /// Where the system audio written last ends, in seconds of the test's clock
    var audioEnd: Double { run.systemAudioEnd.map { CMTimeGetSeconds($0) - TestRecording.base } ?? -1 }

    func monitorPresent() throws -> Double {
        let anchor = try require(run.writer.clockAnchor, "clock anchor")
        let now = DispatchTime.now().uptimeNanoseconds
        return CMTimeGetSeconds(anchor.raw) - TestRecording.base + Double(now &- anchor.uptime) / 1_000_000_000
    }

    func close() async throws {
        queue.sync { monitor.stop() }
        _ = try await run.close()
    }
}

func arrivalTests() async {
    await test("arrival: the tap's device timestamps jump -10 s, +5 s and -1100 s mid-recording and come back, and every sample is recorded where it arrived") {
        let rig = try TapRig(folder: "arrival-jumps")
        // What the tap's device stamps its buffers with against the time they arrive: right, 10 s in the past (what
        // lost the meeting), right again, 5 s ahead (voice processing switched on), 1100 s in the past
        func jump(_ t: Double) -> Double {
            if t >= 2 && t < 4 { return -10 }
            if t >= 5 && t < 7 { return 5 }
            if t >= 8 && t < 10 { return -1100 }
            return 0
        }
        let buffers = 1200
        for index in 0..<buffers {
            let t = Double(index) / 100
            rig.run.present = t + 0.012
            try rig.io(first: index * 480, stamped: t + jump(t), at: t + 0.01)
            if index % 10 == 9 { try rig.backup(t - 0.09) }
            if index % 50 == 49 { rig.tick() }
        }
        let finished = rig.finish()
        expect(finished.sessionStarted, "recorded")
        expect(rig.run.failures.isEmpty, "no failure: \(rig.run.failures)")
        try expectEverySample(in: try require(rig.run.recording.systemAudioURL, "tap file"), total: buffers * 480)
        let spans = try require(TapSpans.read(try require(rig.run.recording.tapSpansURL, "spans file")), "spans")
        expectEqual(spans.spans.count, 1, "the tap was alive from the first buffer written to the last, without a break: \(spans.spans)")
        expect(spans.covers(0.001, Double(buffers) / 100 - 0.001), "all twelve seconds: \(spans.spans)")
        expectEqual(rig.notified, [], "nothing to tell the user")
        expect(RecLog.lines.allSatisfy { !$0.contains("delivered nothing") && !$0.contains("left out") }, "and nothing left out: \(RecLog.lines)")
        let backup = try await TestMovie.seconds(of: try require(rig.run.recording.backupAudioURL, "backup file"))
        expectClose(backup, 12, within: 0.15, "the backup beside it is whole too")
    }

    await test("arrival: put together as in the app (the real tap's IOProc, its source without a clock, the writer), device time stamps 10 s behind and 5 s ahead lose nothing") {
        let run = try TestRecording(folder: "arrival-ioproc", audioOnly: true, microphone: false, settings: ["recordWinSound": true, "audioFormat": "alac"], tap: true)
        let queue = DispatchQueue(label: "HoldfastTests.arrival-ioproc")
        try run.writer.prepareAudio()
        // The host clock itself, as in the app: the buffers carry the time the IOProc read from it
        run.writer.presentClock = { CMClockGetHostTimeClock().time }
        run.writer.startCapturing()
        let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: false))
        let factory = SystemAudioSource.Factory(constructions: { [.builtInOutput] }, makeTap: { clock, control, deliver, changed in
            try SystemAudioTap(hardware: hardware, clock: clock, queue: control, deliver: deliver, outputChanged: changed)
        })
        let source = SystemAudioSource(factory: factory, sampleQueue: queue, stallSeconds: 60) { run.writer.write($0) }
        try source.start()
        // What the device stamps its buffers with against the time of the call: 10 s behind from the second second
        // on (the direction that lost the meeting), right again, 5 s ahead, right again
        func jump(_ t: Double) -> Double {
            if t >= 1 && t < 2.5 { return -10 }
            if t >= 3 && t < 3.5 { return 5 }
            return 0
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let step = UInt64(10_000_000) * UInt64(timebase.denom) / UInt64(timebase.numer)
        let buffers = 400
        // The IOProc is called at the pace of real time, as Core Audio calls it: every 10 ms with 10 ms of audio
        let began = mach_absolute_time()
        for index in 0..<buffers {
            mach_wait_until(began + UInt64(index) * step)
            let pcm = try sawPCM(first: index * 480)
            let stamp = jump(Double(index) / 100)
            hardware.runIO(pcm.audioBufferList, host: hostTicks(stamp))
        }
        source.stopNow()
        queue.sync {}
        let finished = queue.sync { run.writer.finish() }
        expect(finished.sessionStarted, "recorded")
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let counted = try sawCount(in: try require(run.recording.systemAudioURL, "tap file"))
        // A sample or two may be added or taken out where the test's own pace was off (`TapDrift`); a buffer left
        // out is 480 at once, and the stamps trusted would leave out every one after the first second
        expect(abs(counted.found - buffers * 480) <= 48, "every sample the IOProc was given is in the file: \(counted.found) of \(buffers * 480)")
        expect(counted.breaks <= 48, "in order, nothing missing in between: \(counted.breaks) breaks")
        expect(RecLog.lines.allSatisfy { !$0.contains("left out") && !$0.contains("is stamped") }, "nothing left out, and no stamp even looked at: \(RecLog.lines)")
    }

    await test("arrival: a tap buffer that reaches the writer after silence was written over its time is left out, once and counted, and the ones after it are recorded") {
        let rig = try TapRig(folder: "arrival-taken")
        rig.holds = true
        rig.run.present = 10
        // The IOProc hands on buffer `index` at `arrival`; what the source made of it
        func handedOn(_ index: Int, at arrival: Double) throws -> CaptureSample {
            try rig.io(first: index * 480, stamped: 0, at: arrival)
            return try require(rig.held.popLast(), "the buffer handed on")
        }
        func write(_ sample: CaptureSample) { rig.queue.sync { rig.run.writer.write(sample) } }
        for index in 0..<100 { write(try handedOn(index, at: Double(index + 1) / 100)) }
        // The next one waits for the sample queue, and the monitor meanwhile continues the track with silence
        let late = try handedOn(100, at: 1.01)
        rig.queue.sync { rig.run.writer.fillSystemAudio(upTo: rig.run.at(1.6)) }
        let before = rig.run.systemAudioEnd
        write(late)
        expectEqual(rig.run.systemAudioEnd, before, "its time is taken: not written a second time")
        expect(RecLog.lines.contains { $0.contains("System audio: a buffer of the tap reached the recording when its track already held 0.59 s beyond it") && $0.contains("left out") },
               "the log says so: \(RecLog.lines)")
        // The tap's audio after the silence, each buffer as it arrives
        for index in 101..<201 { write(try handedOn(index, at: 1.6 + Double(index - 100) / 100)) }
        // One whose IOProc ran 30 ms early by the clock, so that it lies before the end of the track: within the
        // tolerance a buffer of the tap goes back to back, whatever its arrival says
        write(try handedOn(201, at: 2.6 - 0.02))
        expectEqual(rig.run.systemAudioEnd, rig.run.at(2.61), "a buffer that arrived a little early is written at the end of the track all the same")
        for index in 202..<250 { write(try handedOn(index, at: 1.6 + Double(index - 100) / 100)) }
        let finished = rig.finish()
        expect(finished.sessionStarted, "recorded")
        expectEqual(RecLog.lines.filter { $0.contains("reached the recording when") }.count, 1, "logged once")
        expect(RecLog.lines.contains("System audio: 1 buffer of the tap reached the recording after silence had been written over its time and was left out"),
               "and counted in the summary: \(RecLog.lines)")
        let counted = try sawCount(in: try require(rig.run.recording.systemAudioURL, "tap file"))
        expectEqual(counted.found, 249 * 480, "every other buffer is in the file")
        expectEqual(counted.breaks, 1, "in order, with the one piece missing")
        expectEqual(counted.silent, 28800, "and the silence that stands in its place, 0.6 s")
        let spans = try require(TapSpans.read(try require(rig.run.recording.tapSpansURL, "spans file")), "spans")
        expectEqual(spans.spans.count, 2, "the tap's audio before the silence and after it: \(spans.spans)")
    }

    await test("arrival: a tap whose device runs 100 parts in a million slow or fast stays within 13 ms of where it arrives, a sample at a time, with no silence and nothing left out") {
        for (name, ppm) in [("slow", 100.0), ("fast", -100.0)] {
            let rig = try TapRig(folder: "arrival-drift-\(name)")
            // A tenth of a second of audio at a time, which the device takes a little more or less than that to deliver
            let buffers = 2000
            let pace = 0.1 * (1 + ppm / 1_000_000)
            var furthest = 0.0
            var last = 0.0
            for index in 0..<buffers {
                let arrival = Double(index + 1) * pace
                rig.run.present = arrival + 0.002
                try rig.io(first: index * 4800, frames: 4800, stamped: 0, at: arrival)
                let end = CMTimeGetSeconds(try require(rig.run.systemAudioEnd, "the track's end")) - TestRecording.base
                last = arrival - end
                furthest = max(furthest, abs(last))
            }
            let finished = rig.finish()
            expect(finished.sessionStarted, "\(name): recorded")
            // Left alone the track would be 20 ms from the arrivals by now, and at 0.1 s get a hole or lose a buffer
            expect(furthest < 0.013, "\(name): never further than 13 ms from where the audio arrived: \(furthest) s")
            expect(abs(last) < 0.008, "\(name): and brought back: \(last) s at the end")
            let counted = try sawCount(in: try require(rig.run.recording.systemAudioURL, "tap file"))
            let changed = counted.found - buffers * 4800
            expect(ppm > 0 ? changed > 300 && changed < 1000 : changed < -300 && changed > -1000, "\(name): by samples \(ppm > 0 ? "added" : "taken out"), one at a time: \(changed)")
            expectEqual(counted.silent, 0, "\(name): no silence in the tap's audio")
            let spans = try require(TapSpans.read(try require(rig.run.recording.tapSpansURL, "spans file")), "spans")
            expectEqual(spans.spans.count, 1, "\(name): one span, so the mix stays on the tap: \(spans.spans)")
            expect(RecLog.lines.contains { $0.contains("System audio: the tap's audio is in its track 10 ms \(ppm > 0 ? "earlier" : "later") than it arrives") && $0.contains(ppm > 0 ? "a sample is added" : "a sample is taken out") }, "\(name): the log says what is done: \(RecLog.lines)")
            expect(RecLog.lines.contains { line in line.contains("to keep the tap's audio where it arrived") && (98...102).contains { line.contains("about \($0) parts in a million \(ppm > 0 ? "less" : "more") audio than time passed") } }, "\(name): and the summary how much: \(RecLog.lines)")
            expect(RecLog.lines.allSatisfy { !$0.contains("left out") }, "\(name): nothing left out: \(RecLog.lines)")
            expectEqual(rig.notified, [], "\(name): nothing to tell the user")
        }
    }

    await test("arrival: a buffer is made a frame longer or shorter where it is heard least") {
        // A ramp with a flat piece: the frame is added, or taken out, in the flat piece
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), "format")
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480), "pcm")
        pcm.frameLength = 480
        let data = try require(pcm.floatChannelData, "float data")
        for frame in 0..<480 {
            let value: Float = frame < 200 ? Float(frame) * 0.001 : (frame < 210 ? 0.2 : Float(frame - 10) * 0.001)
            data[0][frame] = value
            data[1][frame] = -value
        }
        let buffer = try require(AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: time(7)), "buffer")
        let original = samplesByChannel(of: buffer)
        for frames in [1, -1] {
            let made = try require(MovieWriter.stretched(buffer, by: frames), "a buffer \(frames) frame")
            expectEqual(made.numSamples, 480 + frames, "\(frames): one frame more or less")
            expectEqual(made.presentationTimeStamp, time(7), "\(frames): at the same time")
            let samples = samplesByChannel(of: made)
            expectEqual(samples.count, 2, "\(frames): both channels")
            expectEqual(Array(samples[0].prefix(200)), Array(original[0].prefix(200)), "\(frames): what comes before is untouched")
            expectEqual(Array(samples[0].suffix(260)), Array(original[0].suffix(260)), "\(frames): and what comes after")
            expectEqual(samples[1], samples[0].map { -$0 }, "\(frames): the same frame in both channels")
            let steps = zip(samples[0], samples[0].dropFirst()).map { abs($1 - $0) }
            expect((steps.max() ?? 1) < 0.0011, "\(frames): no step larger than the signal's own: \(steps.max() ?? 1)")
        }
        expect(MovieWriter.stretched(buffer, by: 0) == nil && MovieWriter.stretched(buffer, by: 2) == nil, "only one frame at a time")
        let interleaved = try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(7))
        expect(MovieWriter.stretched(interleaved, by: 1) == nil, "another format is left as it is")
        let short = try sawBuffer(first: 0, frames: 3, at: time(7))
        expect(MovieWriter.stretched(short, by: -1) == nil, "and so is a buffer too short for it")
    }

    await test("arrival: tap buffers that wait 300 ms between the IOProc and the sample queue are neither dropped nor shifted, and do not set the monitor's clock back") {
        let rig = try TapRig(folder: "arrival-hand-off")
        rig.holds = true
        let buffers = 600
        var processed = 0.0
        var worst = 0.0
        var nextTick = 0.5
        for index in 0..<buffers {
            let t = Double(index) / 100
            let arrived = t + 0.01
            // The sample queue is held up for the buffers of the third and fourth second: each reaches the writer
            // 300 ms after its IOProc, and the ones behind them once the queue has caught up
            let waits = t >= 2 && t < 4 ? 0.3 : 0.002
            processed = max(processed, arrived + waits)
            try rig.io(first: index * 480, stamped: t, at: arrived)
            while nextTick <= processed {
                rig.run.present = nextTick
                rig.tick()
                nextTick += 0.5
            }
            rig.run.present = processed
            let sample = try require(rig.held.popLast(), "the buffer handed on")
            rig.queue.sync { rig.run.writer.write(sample) }
            worst = max(worst, abs(try rig.monitorPresent() - processed))
        }
        let finished = rig.finish()
        expect(finished.sessionStarted, "recorded")
        try expectEverySample(in: try require(rig.run.recording.systemAudioURL, "tap file"), total: buffers * 480)
        let spans = try require(TapSpans.read(try require(rig.run.recording.tapSpansURL, "spans file")), "spans")
        expectEqual(spans.spans.count, 1, "one span, unbroken: \(spans.spans)")
        expect(worst < 0.1, "the monitor's present stays the present while buffers wait: \(worst) s off at worst")
        expectEqual(rig.notified, [], "nothing to tell the user")
    }

    await test("arrival: ScreenCaptureKit audio stamped a steady 10 s behind at real-time pace is recorded by its arrival within 2 s") {
        let rig = try StreamRig(folder: "arrival-lagging-stream")
        var left = [Double]()
        var firstBack: Double?
        var furthest = 0.0
        for index in 0..<120 {
            let t = Double(index) / 10
            let lags = t >= 3 && t < 8
            try rig.frame(stamped: t, arrival: t + 0.02)
            let written = try rig.audio(stamped: lags ? t - 10 : t, arrival: t + 0.12)
            if !written { left.append(t) }
            if lags && written {
                if firstBack == nil { firstBack = t }
                furthest = max(furthest, abs(rig.audioEnd - (t + 0.12)))
            }
            rig.tick()
        }
        let back = try require(firstBack, "the lagging stream is recorded again")
        expect(back - 3 <= 2.0001, "within 2 s of its clock falling behind: after \(back - 3) s")
        expect(left.allSatisfy { $0 >= 3 && $0 < back }, "and from then on every buffer is, also when its clock is right again: left out at \(left)")
        expect(furthest <= 0.11, "each where it arrived: \(furthest) s off at worst")
        expectClose(rig.audioEnd, 12, within: 0.15, "the audio ends with the recording")
        expect(RecLog.lines.contains { $0.contains("System audio: buffers stamped") && $0.contains("the stream's clock lags") }, "the log says why: \(RecLog.lines)")
        expectEqual(rig.notified, [], "no warning")
        try await rig.close()
        expect(rig.run.failures.isEmpty, "no failure: \(rig.run.failures)")
        let tracks = try await TestRecording.tracks(of: rig.run.recording.rawURL)
        expectClose(try require(tracks.audio.first, "system audio").end, 12, within: 0.25, "the track is as long as the recording")
    }

    await test("arrival: a ScreenCaptureKit backlog, 5 s of audio in half a second after a 5 s stall, is dropped where silence was written, and what follows is in place") {
        let rig = try StreamRig(folder: "arrival-backlog")
        var kept = 0, dropped = 0
        var shifted = 0.0
        var clockBack = 0.0
        var silenceEnd = 0.0
        // What is handed over late keeps the time it was captured at
        func hear(_ stamp: Double, arrival: Double, backlog: Bool) throws {
            // Where the track ends before the buffer: silence, as far as the monitor has written it by now
            let trackEnd = rig.run.writer.audioEndPTS.map { CMTimeGetSeconds($0) - TestRecording.base } ?? 0
            if try rig.audio(stamped: stamp, arrival: arrival) {
                if backlog { kept += 1 }
                shifted = max(shifted, abs(rig.audioEnd - (stamp + 0.1)))
            } else {
                if backlog { dropped += 1 } else { expect(false, "a buffer on time is left out at \(stamp) s") }
                expect(stamp + 0.1 <= trackEnd + 0.0001, "only what silence stands for is left out: \(stamp) s against \(trackEnd) s")
            }
            clockBack = max(clockBack, arrival - (try rig.monitorPresent()))
        }
        var pending = [Double]()
        for index in 0..<120 {
            let t = Double(index) / 10
            try rig.frame(stamped: t, arrival: t + 0.02)
            if t >= 3 && t < 8.5 {
                // Nothing arrives for five seconds, and what is captured while the backlog drains waits behind it
                pending.append(t)
            } else {
                try hear(t, arrival: t + 0.12, backlog: false)
            }
            if t >= 8 && t < 8.5 {
                if silenceEnd == 0 { silenceEnd = CMTimeGetSeconds(try require(rig.run.writer.audioEndPTS, "audio end")) - TestRecording.base }
                // Ten buffers every tenth of a second: 5 s of audio in half a second
                for step in 0..<11 where !pending.isEmpty {
                    try hear(pending.removeFirst(), arrival: t + 0.03 + Double(step) * 0.008, backlog: true)
                    usleep(3_000)
                }
            }
            rig.tick()
        }
        expect(pending.isEmpty, "the backlog has drained")
        expect(silenceEnd > 6 && silenceEnd <= 7.2, "silence had been written up to a second before the present: \(silenceEnd) s")
        expect(dropped >= 30 && kept >= 10, "the part of the backlog that silence stands for is dropped (\(dropped) buffers), the rest recorded (\(kept))")
        expect(shifted <= 0.1001, "every buffer written is at its own time, a buffer late at most: \(shifted) s")
        expectClose(rig.audioEnd, 12, within: 0.1001, "and the audio after it is where it belongs")
        expect(clockBack < 0.5, "the monitor's clock is not set back by the old buffers: \(clockBack) s")
        expect(RecLog.lines.contains { $0.contains("System audio backlog:") && $0.contains("left out") }, "the log has the backlog: \(RecLog.lines)")
        expect(RecLog.lines.allSatisfy { !$0.contains("arrival time") }, "its timestamps are kept: \(RecLog.lines)")
        try await rig.close()
        expect(rig.run.failures.isEmpty, "no failure: \(rig.run.failures)")
        let tracks = try await TestRecording.tracks(of: rig.run.recording.rawURL)
        expectClose(try require(tracks.audio.first, "system audio").end, 12, within: 0.25, "the track is as long as the recording")
    }

    await test("arrival: a video frame stamped 12 s ahead, and one 12 s behind, is written at its arrival, and every frame after it in order") {
        let rig = try StreamRig(folder: "arrival-frames")
        let writer = rig.run.writer
        var fed = 0, written = 0
        var ordered = true
        func show(stamped stamp: Double, arrival: Double) throws {
            let before = writer.videoPTS
            try rig.frame(stamped: stamp, arrival: arrival)
            fed += 1
            guard let now = writer.videoPTS, now != before else { return }
            written += 1
            if let before, now <= before { ordered = false }
        }
        for index in 0..<70 {
            let t = Double(index) / 10
            try show(stamped: t, arrival: t + 0.02)
            if index == 30 {
                // As a call connects
                try show(stamped: t + 12, arrival: t + 0.05)
                expectEqual(writer.videoPTS, rig.run.at(t + 0.05), "the frame stamped 12 s ahead is written when it arrived")
            }
            if index == 50 {
                try show(stamped: t - 12, arrival: t + 0.05)
                expectEqual(writer.videoPTS, rig.run.at(t + 0.05), "and so is the one stamped 12 s behind")
            }
            _ = try rig.audio(stamped: t, arrival: t + 0.12)
            rig.tick()
        }
        expectEqual(written, fed, "no frame is left out")
        expect(ordered, "each later than the one before it")
        expectEqual(writer.videoPTS, rig.run.at(6.9), "the frames after them are at their own times")
        expect(try require(writer.lastPTS, "end") <= rig.run.at(7.2), "and the recording is not 12 s longer")
        expectEqual(RecLog.lines.filter { $0.contains("Video: a frame is stamped") }.count, 2, "one line for each: \(RecLog.lines)")
        try await rig.close()
        expect(rig.run.failures.isEmpty, "no failure: \(rig.run.failures)")
        let tracks = try await TestRecording.tracks(of: rig.run.recording.rawURL)
        expectClose(try require(tracks.video.first, "video").end, 7, within: 0.25, "the video is as long as the recording")
    }
}
