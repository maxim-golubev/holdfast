//
//  MicConverterTests.swift
//

import AVFoundation
import Foundation

/// A microphone, the clock its buffers are stamped with, and the track they end up on
final class Mic {
    let converter: MicConverter
    let track = Track()
    /// When the writer's session started, in nanoseconds on the buffers' clock
    let sessionStart: Int64
    /// The present on that clock
    var now: Int64
    /// What the microphone's timestamps are off by
    var lag: Int64 = 0
    /// Whether the monitor runs: every half second it fills the track up to a second behind the present
    var monitor = false
    /// Whether the converter is told when each buffer arrived, as the app does
    var knowsArrival = true
    private var lastTick: Int64
    var results = [Bool]()

    init(start seconds: Double = 1000) throws {
        converter = try require(MicConverter(), "converter")
        sessionStart = Int64(seconds * 1_000_000_000)
        now = sessionStart
        lastTick = sessionStart
        converter.start(at: stamp(sessionStart))
    }

    func stamp(_ nanoseconds: Int64) -> CMTime { CMTime(value: nanoseconds, timescale: 1_000_000_000) }
    var present: CMTime { stamp(now) }
    /// Seconds from the session start to the end of the track
    var trackSeconds: Double {
        guard let end = track.end else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(end, stamp(sessionStart)))
    }
    var wallSeconds: Double { Double(now - sessionStart) / 1_000_000_000 }

    private func advance(by nanoseconds: Int64) {
        now += nanoseconds
        while monitor && now - lastTick >= 500_000_000 {
            lastTick += 500_000_000
            let target = CMTimeSubtract(stamp(lastTick), CMTime(seconds: 1, preferredTimescale: 600))
            converter.fill(upTo: target, atLeast: 24000) { track.append($0) }
        }
        if !monitor { lastTick = now }
    }

    /// The microphone delivers 20 ms buffers for `seconds`, each arriving 5 ms after the present reaches its end
    func deliver(_ seconds: Double, rate: Double = 24000, channels: UInt32 = 1, amplitude: Float = 0.5) throws {
        let frames = Int(rate / 50)
        for _ in 0..<Int((seconds * 50).rounded()) {
            let buffer = try audioBuffer(rate: rate, channels: channels, frames: frames, at: stamp(now - lag), amplitude: amplitude)
            let arrival = knowsArrival ? stamp(now + 25_000_000) : CMTime.invalid
            results.append(converter.convert(buffer, at: buffer.presentationTimeStamp, arrival: arrival) { track.append($0) })
            advance(by: 20_000_000)
        }
    }

    /// A 20 ms buffer stamped `pts` (nanoseconds on the clock) that arrives at `arrival`: the clock first runs on to
    /// then, with the monitor if it runs. Returns whether it was written.
    @discardableResult
    func receive(stampedAt pts: Int64, arrival: Int64) throws -> Bool {
        if arrival > now { advance(by: arrival - now) }
        let buffer = try audioBuffer(rate: 24000, frames: 480, at: stamp(pts))
        let written = converter.convert(buffer, at: buffer.presentationTimeStamp, arrival: stamp(arrival)) { track.append($0) }
        results.append(written)
        return written
    }

    /// Nothing arrives for `seconds`
    func wait(_ seconds: Double) {
        var left = Int64((seconds * 1_000_000_000).rounded())
        while left > 0 {
            let step = min(left, 20_000_000)
            advance(by: step)
            left -= step
        }
    }

    /// What stopping does: the track is padded to the length of the recording
    func stop() {
        converter.fill(upTo: present) { track.append($0) }
    }
}

func micConverterTests() async {
    await test("MicConverter: a steady 24 kHz mono microphone becomes a continuous 48 kHz track") {
        let mic = try Mic()
        try mic.deliver(3)
        expect(mic.track.contiguous, "every buffer starts where the one before ended")
        expectEqual(mic.track.start, mic.stamp(mic.sessionStart), "the track starts at the session start")
        expectClose(mic.trackSeconds, 3, within: 0.02, "length of the track")
        expectEqual(mic.converter.buffersIn, 150, "buffers in")
        expectEqual(mic.converter.buffersWritten, 150, "buffers written")
        expectEqual(mic.converter.silenceFrames, 0, "silence")
        expectEqual(mic.converter.formatChanges, 0, "format changes")
        expect(mic.results.allSatisfy { $0 }, "convert reports every buffer as written")
        expectEqual(mic.converter.end, mic.track.end, "the converter's end is the end of the track")
        expectEqual(mic.converter.framesWritten, mic.track.frames, "frames counted are frames written")
    }

    await test("MicConverter: the format changes 24 kHz -> 48 kHz -> 24 kHz mid-stream") {
        let mic = try Mic()
        try mic.deliver(2, rate: 24000)
        try mic.deliver(2, rate: 48000)
        try mic.deliver(2, rate: 24000)
        expect(mic.track.contiguous, "the track has no hole or overlap")
        expectEqual(mic.converter.formatChanges, 2, "format changes")
        expectEqual(mic.converter.buffersFailed, 0, "failed buffers")
        expectEqual(mic.converter.buffersDropped, 0, "dropped buffers")
        expectEqual(mic.converter.buffersWritten, 300, "buffers written")
        expectClose(mic.trackSeconds, 6, within: 0.1, "length of the track")
        expect(mic.track.pieces.allSatisfy { $0.peak > 0.3 || $0.frames < 960 }, "every full buffer carries the tone")
        expectEqual(RecLog.lines.filter { $0.contains("Microphone format changed") }.count, 2, "format changes in the log")
        expect(mic.converter.summary.contains("2 format changes"), "summary names the format changes: \(mic.converter.summary)")
        expect(mic.converter.summary.contains("24000 Hz x1"), "summary names the last device format: \(mic.converter.summary)")
        mic.stop()
        expectClose(mic.trackSeconds, 6, within: 0.0001, "length of the track after the stop")
    }

    await test("MicConverter: a stereo 44.1 kHz device is converted as well") {
        let mic = try Mic()
        try mic.deliver(1, rate: 44100, channels: 2)
        expect(mic.track.contiguous, "continuous")
        expectEqual(mic.converter.buffersWritten, 50, "buffers written")
        expectClose(mic.trackSeconds, 1, within: 0.02, "length of the track")
    }

    await test("MicConverter: a gap in the microphone's buffers becomes silence of the same length") {
        let mic = try Mic()
        try mic.deliver(1)
        let before = try require(mic.track.end, "end of the track")
        mic.wait(2)
        let resumed = mic.present
        try mic.deliver(1)
        expect(mic.track.contiguous, "continuous")
        let gap = CMTimeConvertScale(CMTimeSubtract(resumed, before), timescale: 48000, method: .default).value
        expectEqual(mic.converter.silenceFrames, gap, "silence frames")
        expectEqual(mic.track.silentFrames, gap, "frames of digital silence on the track")
        expectClose(Double(gap) / 48000, 2, within: 0.02, "seconds of silence")
        let first = try require(mic.track.pieces.first { $0.peak > 0 && $0.pts >= before }, "first buffer after the gap")
        expectEqual(first.pts, CMTimeConvertScale(resumed, timescale: 48000, method: .default), "the first buffer after the gap sits at its own time")
        expectClose(mic.trackSeconds, 4, within: 0.02, "length of the track")
        expectEqual(mic.converter.buffersDropped, 0, "dropped buffers")
    }

    await test("MicConverter: silence is written in pieces of at most half a second") {
        let mic = try Mic()
        mic.wait(2.3)
        try mic.deliver(0.02)
        let silent = mic.track.pieces.filter { $0.peak == 0 }
        expectEqual(silent.map { $0.frames }, [24000, 24000, 24000, 24000, 14400], "pieces of silence")
    }

    await test("MicConverter: a hole longer than 10 s is filled over several buffers before audio continues") {
        let mic = try Mic()
        try mic.deliver(1)
        mic.wait(25)
        try mic.deliver(1)
        expect(mic.track.contiguous, "continuous")
        let late = Array(mic.results.suffix(50))
        expectEqual(Array(late.prefix(3)), [false, false, true], "the first two buffers after the hole only write silence")
        expectClose(Double(mic.converter.silenceFrames) / 48000, 25.04, within: 0.03, "seconds of silence")
        expectEqual(mic.converter.buffersDropped, 2, "the two buffers are counted as dropped")
        expectEqual(mic.converter.buffersIn, mic.converter.buffersWritten + mic.converter.buffersDropped + mic.converter.buffersFailed, "every buffer is counted once")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.02, "the track is back at the present")
    }

    await test("MicConverter: the first buffer after the session start is placed to the sample") {
        // A late microphone: the track is padded from the session start to the buffer's own time
        let late = try Mic()
        late.wait(0.03)
        try late.deliver(1)
        expectEqual(late.track.start, late.stamp(late.sessionStart), "the track starts at the session start")
        expectEqual(late.track.pieces.first?.frames, 1440, "30 ms of silence in front")
        expectEqual(late.track.pieces.first?.peak, 0, "and it is silence")
        expectEqual(late.track.pieces.dropFirst().first?.pts, CMTimeAdd(samples(1440), CMTimeConvertScale(late.stamp(late.sessionStart), timescale: 48000, method: .default)), "the audio starts at its own time")
        expect(late.track.contiguous, "continuous")

        // A buffer that began before the session start: the part before it is left out
        let early = try Mic()
        early.lag = 5_000_000
        try early.deliver(1)
        expectEqual(early.track.start, early.stamp(early.sessionStart), "the track starts at the session start")
        expectEqual(early.converter.silenceFrames, 0, "no silence")
        let produced = Int64(early.converter.buffersWritten) * 960
        expect(early.track.frames < produced && early.track.frames >= produced - 240 - 64, "5 ms are cut from the first buffer: \(early.track.frames) of \(produced) frames")
        expect(early.track.contiguous, "continuous")

        // A buffer that ended before the session start has nothing to write, and the next one is aligned instead
        let before = try Mic()
        before.lag = 30_000_000
        try before.deliver(1)
        expectEqual(before.results.prefix(3).map { $0 }, [false, true, true], "the first buffer is left out")
        expectEqual(before.converter.buffersDropped, 1, "dropped buffers")
        expectEqual(before.track.start, before.stamp(before.sessionStart), "the track starts at the session start")
        expect(before.track.contiguous, "continuous")
    }

    await test("MicConverter: without a session start the track begins at the first buffer") {
        let converter = try require(MicConverter(), "converter")
        let track = Track()
        expect(!converter.end.isValid, "no end before the first buffer")
        expectEqual(converter.lag(behind: time(5)), 0, "no lag before the timeline has started")
        converter.fill(upTo: time(5)) { track.append($0) }
        expectEqual(track.pieces.count, 0, "nothing is filled before the timeline has started")
        let buffer = try audioBuffer(rate: 24000, frames: 480, at: time(7))
        expect(converter.convert(buffer, at: time(7)) { track.append($0) }, "written")
        expectEqual(track.start, time(7), "the track starts at the buffer")
        expectClose(converter.lag(behind: time(8)), 0.98, within: 0.01, "lag behind a later time")
        converter.start(at: time(3))
        expectEqual(track.start, time(7), "a second start changes nothing")
    }

    await test("MicConverter: jitter within 0.1 s is written back to back, more is corrected") {
        let mic = try Mic()
        try mic.deliver(1)
        mic.wait(0.06)
        try mic.deliver(1)
        expectEqual(mic.converter.silenceFrames, 0, "60 ms of jitter is not filled")
        expect(mic.track.contiguous, "continuous")
        mic.wait(0.06)
        try mic.deliver(1)
        expectClose(Double(mic.converter.silenceFrames) / 48000, 0.12, within: 0.02, "once the offset passes 0.1 s it is filled")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.02, "the track is at the present again")
    }

    await test("MicConverter: without arrival times, buffers behind the track are dropped, then shifted after 1 s") {
        let mic = try Mic()
        mic.knowsArrival = false
        try mic.deliver(1)
        mic.wait(4)
        // The monitor wrote silence up to here while the microphone was away
        mic.converter.fill(upTo: mic.present, atLeast: 24000) { mic.track.append($0) }
        let filledEnd = try require(mic.track.end, "end of the track")
        expectEqual(filledEnd, CMTimeConvertScale(mic.present, timescale: 48000, method: .default), "the fill ends at the time it was given")
        // The microphone comes back with timestamps three seconds in the past
        mic.lag = 3_000_000_000
        try mic.deliver(3)
        let results = Array(mic.results.suffix(150))
        let dropped = results.prefix { !$0 }.count
        expect(dropped == 49 || dropped == 50, "one second's worth of buffers is dropped first: \(dropped)")
        expectEqual(mic.converter.buffersDropped, dropped, "dropped buffers")
        expect(results.dropFirst(dropped).allSatisfy { $0 }, "every buffer after that is written")
        expectEqual(mic.track.pieces.first { $0.pts >= filledEnd }?.pts, filledEnd, "they continue at the end of the track")
        expect(mic.track.contiguous, "continuous")
        expectEqual(RecLog.lines.filter { $0.contains("behind the recording") }.count, 1, "the shift is logged once")
        let shiftedEnd = try require(mic.track.end, "end of the track")
        expectClose(CMTimeGetSeconds(CMTimeSubtract(shiftedEnd, filledEnd)), Double(150 - dropped) * 0.02, within: 0.02, "audio written after the shift")

        // The timestamps catch up with the clock: the shift is given back and the buffer sits at its own time
        mic.lag = 0
        mic.wait(2)
        let caughtUp = mic.present
        try mic.deliver(1)
        expect(mic.track.contiguous, "continuous")
        expectEqual(mic.track.pieces.last { $0.peak == 0 }.map { CMTimeAdd($0.pts, samples($0.frames)) }, CMTimeConvertScale(caughtUp, timescale: 48000, method: .default), "silence runs up to the buffer's own time")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.02, "the track is at the present again")
    }

    await test("MicConverter: late buffers that catch up with a track nothing fills further are dropped, not shifted") {
        let mic = try Mic()
        try mic.deliver(1)
        mic.wait(4)
        // Silence up to here while the microphone was away, and no more after it
        mic.converter.fill(upTo: mic.present, atLeast: 24000) { mic.track.append($0) }
        let filledEnd = try require(mic.track.end, "end of the track")
        // The microphone comes back with timestamps three seconds in the past, at real-time pace
        mic.lag = 3_000_000_000
        try mic.deliver(5)
        let results = Array(mic.results.suffix(250))
        let dropped = results.prefix { !$0 }.count
        // Less late audio arrives than the 3 s it lies behind, so it never shifts: the buffers more than 0.1 s behind
        // are dropped as late, the ones within 0.1 s as ending before the anchor the fill left
        expect(dropped >= 149 && dropped <= 151, "the buffers before the end of the track are dropped: \(dropped)")
        expectEqual(mic.converter.buffersDropped, dropped, "dropped buffers")
        expectClose(mic.converter.lateSecondsDropped, 2.9, within: 0.03, "seconds dropped late")
        expect(results.dropFirst(dropped).allSatisfy { $0 }, "every buffer after that is written")
        expectEqual(mic.track.pieces.first { $0.pts >= filledEnd }?.pts, filledEnd, "they continue at the end of the track")
        expect(mic.track.contiguous, "continuous")
        expectEqual(mic.converter.shifts, 0, "no shift")
        expect(RecLog.lines.allSatisfy { !$0.contains("behind the recording") }, "no shift in the log")
        expectEqual(RecLog.lines.filter { $0.contains("Microphone backlog") }.count, 1, "the drop is logged")
    }

    await test("MicConverter: a microphone clock that lags by a steady 2 s is shifted while the monitor fills") {
        let mic = try Mic()
        mic.monitor = true
        try mic.deliver(3)
        mic.lag = 2_000_000_000
        try mic.deliver(8)
        let results = Array(mic.results.suffix(400))
        let dropped = results.prefix { !$0 }.count
        expect(dropped >= 100 && dropped <= 130, "about two seconds' worth of buffers is dropped first: \(dropped)")
        expect(results.dropFirst(dropped).allSatisfy { $0 }, "every buffer after that is written")
        expectEqual(mic.converter.shifts, 1, "one shift")
        expectEqual(RecLog.lines.filter { $0.contains("behind the recording") && $0.contains("real-time pace") }.count, 1, "the shift is logged once, as a lagging clock")
        expect(RecLog.lines.allSatisfy { !$0.contains("backlog") }, "not taken for a backlog")
        expect(mic.track.contiguous, "continuous")
        expect(mic.trackSeconds <= mic.wallSeconds + 0.02, "the track is not ahead of the clock")
        mic.stop()
        expect(mic.track.contiguous, "continuous after the stop")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.0001, "full length")
    }

    await test("MicConverter: a backlog with its own timestamps is dropped where silence was filled and leaves no offset") {
        // What a call app taking the microphone did: nothing for 13 s while the monitor filled the track with
        // silence, then what piled up (from 2 s into the hold-up on) delivered at three times real time with the
        // times it was captured at, until the queue was empty; real time from there on.
        let mic = try Mic()
        mic.monitor = true
        try mic.deliver(5)
        let held = mic.now
        let step: Int64 = 20_000_000
        let firstQueued = held + 2_000_000_000
        let release = held + 13_000_000_000
        var buffers = [(pts: Int64, arrival: Int64)]()
        var caughtUp: Int?
        for k in 0..<1200 {
            let pts = firstQueued + Int64(k) * step
            let drained = release + Int64(k) * step / 3
            let live = pts + step + 5_000_000
            if caughtUp == nil && live >= drained { caughtUp = k }
            buffers.append((pts, max(drained, live)))
        }
        let drainedAt = try require(caughtUp, "the queue empties")
        expect(drainedAt > 800 && drainedAt < 850, "the backlog is about 16.5 s of audio: \(drainedAt) buffers")
        let dropsBefore = mic.converter.buffersDropped
        var firstWritten: Int64?
        var offsets = [Double]()
        for buffer in buffers {
            let written = try mic.receive(stampedAt: buffer.pts, arrival: buffer.arrival)
            if written {
                if firstWritten == nil { firstWritten = buffer.pts }
                // Every buffer written ends where its own time ends
                let end = try require(mic.track.end, "end of the track")
                offsets.append(CMTimeGetSeconds(CMTimeSubtract(end, mic.stamp(buffer.pts + step))))
            }
        }
        let resumedAt = try require(firstWritten, "the microphone is written again")
        let worst = offsets.map { abs($0) }.max() ?? 0
        expect(worst <= 0.02, "every buffer after the backlog sits at its own time: worst \(worst) s")
        expectEqual(offsets.count, mic.results.suffix(buffers.count).filter { $0 }.count, "counted every written buffer")
        expect(mic.results.suffix(buffers.count).drop { !$0 }.allSatisfy { $0 }, "nothing is dropped once the microphone is written again")
        // What was dropped is the part of the backlog that overlaps the silence the monitor wrote (the last few
        // buffers of it, within 0.1 s of the end of the track, are dropped as buffers that end before an anchor)
        let overlap = Double(resumedAt - firstQueued) / 1_000_000_000
        expectClose(mic.converter.lateSecondsDropped, overlap, within: 0.12, "seconds dropped")
        expectEqual(mic.converter.buffersDropped - dropsBefore, Int((overlap / 0.02).rounded()), "buffers dropped")
        expect(overlap > 11 && overlap < 16.5, "the overlap is most of the backlog: \(overlap) s")
        expectEqual(mic.converter.shifts, 0, "no shift")
        expect(RecLog.lines.allSatisfy { !$0.contains("behind the recording") }, "no shift in the log")
        let backlog = RecLog.lines.filter { $0.contains("Microphone backlog") }
        expectEqual(backlog.count, 1, "the backlog is logged once: \(RecLog.lines)")
        expect(backlog.first?.contains(String(format: "%.2f s of audio", mic.converter.lateSecondsDropped)) ?? false, "with what was dropped: \(backlog)")
        expect(mic.track.contiguous, "continuous")
        mic.stop()
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.0001, "full length, no longer")
    }

    await test("MicConverter: a few late buffers are dropped without shifting the timeline") {
        let mic = try Mic()
        try mic.deliver(1)
        mic.lag = 500_000_000
        try mic.deliver(0.4)
        expectEqual(mic.converter.buffersDropped, 20, "dropped buffers")
        mic.lag = 0
        try mic.deliver(1)
        expectEqual(mic.converter.buffersDropped, 20, "nothing more is dropped")
        expect(mic.track.contiguous, "continuous")
        expect(RecLog.lines.allSatisfy { !$0.contains("behind the recording") }, "no shift")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.02, "the track is at the present")
    }

    await test("MicConverter: fill pads with silence, only from the least amount on, and realigns") {
        let mic = try Mic()
        try mic.deliver(1)
        let end = try require(mic.track.end, "end of the track")
        mic.converter.fill(upTo: CMTimeAdd(end, samples(23999)), atLeast: 24000) { mic.track.append($0) }
        expectEqual(mic.track.end, end, "less than the least amount is not filled")
        mic.converter.fill(upTo: CMTimeSubtract(end, samples(4800))) { mic.track.append($0) }
        expectEqual(mic.track.end, end, "a time before the end is not filled")
        mic.converter.fill(upTo: CMTimeAdd(end, samples(30000)), atLeast: 24000) { mic.track.append($0) }
        expectEqual(mic.track.end, CMTimeAdd(end, samples(30000)), "the fill ends at the time it was given")
        expectEqual(mic.converter.silenceFrames, 30000, "silence frames")
        expectEqual(mic.track.pieces.suffix(2).map { $0.frames }, [24000, 6000], "pieces of silence")
        // The buffer after a fill is placed at its own time, although it is within the jitter tolerance
        let next = CMTimeAdd(end, samples(30000 + 2400))
        let buffer = try audioBuffer(rate: 24000, frames: 480, at: next)
        expect(mic.converter.convert(buffer, at: next) { mic.track.append($0) }, "written")
        expectEqual(mic.track.pieces.last?.pts, next, "the buffer sits at its own time")
        expectEqual(mic.converter.silenceFrames, 32400, "50 ms of silence in front of it")
        expect(mic.track.contiguous, "continuous")
    }

    await test("MicConverter: after a resume the next buffer is placed to the sample") {
        let mic = try Mic()
        try mic.deliver(1)
        mic.converter.realign()
        mic.wait(0.05)
        let resumed = mic.present
        try mic.deliver(1)
        expectEqual(mic.track.pieces.first { $0.peak == 0 }.map { CMTimeAdd($0.pts, samples($0.frames)) }, CMTimeConvertScale(resumed, timescale: 48000, method: .default), "silence up to the buffer's own time")
        expect(mic.track.contiguous, "continuous")
    }

    await test("MicConverter: buffers the writer does not take leave no hole in the track") {
        let mic = try Mic()
        try mic.deliver(1)
        mic.track.accepts = false
        try mic.deliver(0.5)
        expectEqual(mic.converter.buffersFailed, 25, "failed buffers, counted whether it was the audio or the silence in front of it that was refused")
        expect(mic.results.suffix(25).allSatisfy { !$0 }, "convert reports them as not written")
        expectClose(mic.trackSeconds, 1, within: 0.02, "the track did not move")
        mic.track.accepts = true
        try mic.deliver(1)
        expect(mic.track.contiguous, "continuous")
        expectClose(Double(mic.converter.silenceFrames) / 48000, 0.5, within: 0.02, "what was not written is silence")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.02, "the track is at the present")

        // Silence the writer does not take is not counted either
        mic.track.accepts = false
        mic.wait(2)
        try mic.deliver(0.1)
        expectClose(Double(mic.converter.silenceFrames) / 48000, 0.5, within: 0.02, "no silence counted while the writer refuses")
        mic.track.accepts = true
        try mic.deliver(1)
        expect(mic.track.contiguous, "continuous")
        expectClose(mic.trackSeconds, mic.wallSeconds, within: 0.02, "the track is at the present")
    }

    await test("MicConverter: statistics count what happened") {
        let mic = try Mic()
        try mic.deliver(1, amplitude: 0.25)
        try mic.deliver(1, amplitude: 0)
        expectEqual(mic.converter.lastPeak, 0, "peak of a silent buffer")
        expect(mic.converter.buffersAllZero >= 45 && mic.converter.buffersAllZero <= 50, "all-zero buffers: \(mic.converter.buffersAllZero)")
        expectClose(Double(mic.converter.loudestPeak), 0.25, within: 0.03, "loudest peak")
        try mic.deliver(0.1, amplitude: 0.5)
        expectClose(Double(mic.converter.lastPeak), 0.5, within: 0.1, "peak of the last buffer")
        mic.lag = 400_000_000
        try mic.deliver(0.2)
        mic.lag = 0
        mic.wait(1)
        try mic.deliver(0.1)
        // Something that is not audio
        var description: CMFormatDescription?
        CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: 0, extensions: nil, formatDescriptionOut: &description)
        var other: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &other)
        let odd = try require(other, "a buffer without audio")
        expect(!mic.converter.convert(odd, at: mic.present) { mic.track.append($0) }, "a buffer without audio is not written")
        expect(!mic.converter.convert(odd, at: .invalid) { mic.track.append($0) }, "a buffer without a time is not written")
        let converter = mic.converter
        expectEqual(converter.buffersIn, 122, "buffers in")
        expectEqual(converter.buffersDropped, 10, "dropped")
        expectEqual(converter.buffersFailed, 2, "failed")
        expectEqual(converter.buffersWritten, 110, "written")
        expectEqual(converter.buffersIn, converter.buffersWritten + converter.buffersDropped + converter.buffersFailed, "every buffer is counted once")
        expectEqual(converter.framesWritten + converter.silenceFrames, mic.track.frames, "frames written plus silence is the track")
        expect(mic.track.contiguous, "continuous")
        let summary = converter.summary
        for part in ["122 buffers in", "110 written", "10 dropped", "2 failed", "all-zero", "s of silence filled", "0 format changes", "24000 Hz x1"] {
            expect(summary.contains(part), "summary contains \"\(part)\": \(summary)")
        }
    }

    await test("MicConverter: the track is as long as the recording, whatever the microphone did") {
        let mic = try Mic()
        mic.monitor = true
        mic.wait(0.25)                      // the microphone starts late
        try mic.deliver(5)                  // AirPods
        try mic.deliver(5, rate: 48000)     // a call app takes the microphone: the format changes
        try mic.deliver(5)                  // and gives it back
        mic.wait(4)                         // the device is gone, the monitor fills
        try mic.deliver(5)
        mic.lag = 2_500_000_000             // it comes back with timestamps in the past
        try mic.deliver(6)
        mic.lag = 0
        mic.wait(3)
        try mic.deliver(5, rate: 44100, channels: 2)
        mic.track.accepts = false           // the writer is busy for a moment
        try mic.deliver(0.3)
        mic.track.accepts = true
        try mic.deliver(5)
        mic.wait(0.7)                       // nothing arrives before the stop
        expect(mic.track.contiguous, "the track has no hole or overlap")
        expect(mic.trackSeconds <= mic.wallSeconds + 0.02, "the track is not ahead of the clock: \(mic.trackSeconds) of \(mic.wallSeconds) s")
        mic.stop()
        expect(mic.track.contiguous, "the track has no hole or overlap after the stop")
        expectEqual(mic.track.start, mic.stamp(mic.sessionStart), "the track starts at the session start")
        expectEqual(mic.track.end, CMTimeConvertScale(mic.present, timescale: 48000, method: .default), "the track ends at the stop")
        expectEqual(mic.track.frames, Int64((mic.wallSeconds * 48000).rounded()), "frames on the track are the seconds of the recording")
        expectEqual(mic.converter.framesWritten + mic.converter.silenceFrames, mic.track.frames, "counted frames")
        expectEqual(mic.converter.formatChanges, 4, "format changes")
        expectEqual(RecLog.lines.filter { $0.contains("behind the recording") }.count, 1, "the late timestamps shifted the timeline once")
        expect(mic.converter.framesWritten > 30 * 48000, "most of the microphone's audio is on the track: \(Double(mic.converter.framesWritten) / 48000) s of 36.3 s")
    }
}
