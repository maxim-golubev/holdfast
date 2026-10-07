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

func sawBuffer(first: Int, frames: Int = 480, at pts: CMTime) throws -> CMSampleBuffer {
    let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), "format")
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), "pcm buffer")
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = try require(pcm.floatChannelData, "float data")
    for frame in 0..<frames {
        let value = Float((first + frame) % sawPeriod + 1) / 32768
        data[0][frame] = value
        data[1][frame] = value
    }
    return try require(AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: pts), "sample buffer")
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
    func io(first: Int, stamped stamp: Double, at time: Double) throws {
        ioTime = time
        try require(fakes.taps.last, "a tap").deliver(try sawBuffer(first: first, at: run.at(stamp)))
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
