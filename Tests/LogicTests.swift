//
//  LogicTests.swift
//  AudioSilence, system audio placement, the timeline, the disk guard
//

import AVFoundation
import Foundation

/// Stands in for the system audio track: `MovieWriter.audioEndPTS`, the sample handler that places and writes a
/// buffer, and `MovieWriter.fillSystemAudio`
final class SystemAudio {
    var end: CMTime?
    /// False while the "writer" is not ready
    var accepts = true
    var silenceFrames: Int64 = 0
    var written = [CMTime]()
    var dropped = 0

    func fill(upTo time: CMTime) -> CMTime? {
        guard let from = end else { return nil }
        var (position, left) = SystemAudioPlacement.silence(from: from, upTo: time, scale: 48000)
        while left > 0, accepts {
            let count = min(left, 24000)
            position = CMTimeAdd(position, samples(count))
            left -= count
            silenceFrames += count
            end = position
        }
        return end
    }

    /// A buffer arrives with these times; returns where it was written
    @discardableResult
    func deliver(from pts: CMTime, to endPTS: CMTime) -> CMTime? {
        guard let start = SystemAudioPlacement.place(from: pts, to: endPTS, end: end, tolerance: 0.1, fill: { fill(upTo: $0) }) else {
            dropped += 1
            return nil
        }
        guard accepts else { return nil }
        end = CMTimeAdd(start, CMTimeSubtract(endPTS, pts))
        written.append(start)
        return start
    }
}

func logicTests() async {
    await test("AudioSilence: makes the frames it is asked for, all zero") {
        let stereo = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true), "format")
        let pcm = try require(AudioSilence.pcm(format: stereo, frames: 480), "silence")
        expectEqual(pcm.frameLength, 480, "frames")
        expectEqual(pcm.format, stereo, "format")
        expectEqual(pcm.audioBufferList.pointee.mBuffers.mDataByteSize, 480 * 8, "bytes")
        let split = try require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2), "format")
        let two = try require(AudioSilence.pcm(format: split, frames: 100), "silence")
        let data = try require(two.floatChannelData, "channels")
        // Start from dirt, to see that the buffer is cleared rather than left as allocated
        expect((0..<2).allSatisfy { channel in (0..<100).allSatisfy { data[channel][$0] == 0 } }, "both channels are zero")
        expect(AudioSilence.pcm(format: stereo, frames: 0) == nil, "no buffer for no frames")
        expect(AudioSilence.pcm(format: stereo, frames: -5) == nil, "no buffer for a negative count")
        expect(AudioSilence.pcm(format: stereo, frames: Int64(UInt32.max) + 1) == nil, "no buffer for more frames than a buffer holds")
    }

    await test("AudioSilence: sample buffers carry the time, length and format they are given") {
        let stereo = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true), "format")
        let pcm = try require(AudioSilence.pcm(format: stereo, frames: 24000), "silence")
        let at = CMTime(value: 123456, timescale: 48000)
        let buffer = try require(AudioSilence.sampleBuffer(from: pcm, description: stereo.formatDescription, at: at), "sample buffer")
        expectEqual(buffer.numSamples, 24000, "samples")
        expectEqual(buffer.presentationTimeStamp, at, "time")
        expectEqual(buffer.duration, CMTime(value: 24000, timescale: 48000), "duration")
        expectEqual(buffer.formatDescription?.audioStreamBasicDescription?.mSampleRate, 48000, "sample rate")
        expectEqual(buffer.formatDescription?.audioStreamBasicDescription?.mChannelsPerFrame, 2, "channels")
        expectEqual(peak(of: buffer), 0, "peak")
        expectEqual(buffer.dataBuffer.map { CMBlockBufferGetDataLength($0) }, 24000 * 8, "bytes")
        expect(AudioSilence.sampleBuffer(from: pcm, description: stereo.formatDescription, at: .invalid) == nil, "no buffer without a time")
    }

    await test("System audio: buffers go back to back at the end of what was written") {
        let audio = SystemAudio()
        expectEqual(audio.deliver(from: time(10), to: time(10.02)), time(10), "the first buffer goes at its own time")
        expectEqual(audio.deliver(from: time(10.02), to: time(10.04)), time(10.02), "the next one follows")
        // 50 ms of jitter: written at the end, not at its own time
        expectEqual(audio.deliver(from: time(10.09), to: time(10.11)), time(10.04), "a buffer within the tolerance goes at the end")
        expectEqual(audio.end, time(10.06), "the end is counted from what was written")
        expectEqual(audio.silenceFrames, 0, "no silence")
    }

    await test("System audio: a hole is filled with silence once it exceeds 0.1 s") {
        let audio = SystemAudio()
        audio.deliver(from: time(10), to: time(10.02))
        // Three buffers the writer does not take: the hole adds up, because the end does not move
        audio.accepts = false
        for index in 1...3 { audio.deliver(from: time(10 + 0.02 * Double(index)), to: time(10.02 + 0.02 * Double(index))) }
        audio.accepts = true
        expectEqual(audio.end, time(10.02), "the end did not move")
        expectEqual(audio.deliver(from: time(10.08), to: time(10.10)), time(10.02), "60 ms: still within the tolerance")
        expectEqual(audio.silenceFrames, 0, "no silence yet")
        // A hole of two seconds
        let start = audio.deliver(from: time(12.04), to: time(12.06))
        expectEqual(start, time(12.04), "the buffer after the hole sits at its own time")
        expectEqual(audio.silenceFrames, 96000, "two seconds of silence")
        expectEqual(audio.end, time(12.06), "end")
    }

    await test("System audio: silence starts on a whole sample and never runs past the buffer") {
        let plan = SystemAudioPlacement.silence(from: time(1.00001), upTo: time(2), scale: 48000)
        expectEqual(plan.position, CMTime(value: 48001, timescale: 48000), "starts at the next whole sample")
        expectEqual(plan.frames, 47999, "whole frames that fit")
        expectEqual(SystemAudioPlacement.silence(from: time(2), upTo: time(2), scale: 48000).frames, 0, "nothing to fill")
        expect(SystemAudioPlacement.silence(from: time(3), upTo: time(2), scale: 48000).frames <= 0, "nothing to fill backwards")
        let audio = SystemAudio()
        audio.end = time(1.00001)
        let start = try require(audio.deliver(from: time(5.000004), to: time(5.020004)), "placement")
        expect(start <= time(5.000004), "the buffer is not placed after its own time")
        expectClose(CMTimeGetSeconds(start), 5.000004, within: 1.0 / 48000, "and less than a sample before it")
    }

    await test("System audio: a buffer is not written while the silence in front of it could not be") {
        let audio = SystemAudio()
        audio.deliver(from: time(10), to: time(10.02))
        audio.accepts = false
        expect(SystemAudioPlacement.place(from: time(13), to: time(13.02), end: audio.end, tolerance: 0.1, fill: { audio.fill(upTo: $0) }) == nil, "not placed")
        expectEqual(audio.end, time(10.02), "the end did not move")
        audio.accepts = true
        expectEqual(audio.deliver(from: time(13.02), to: time(13.04)), time(13.02), "the next buffer is placed after the silence")
        expectEqual(audio.silenceFrames, 144000, "three seconds of silence")
    }

    await test("System audio: a late buffer is dropped, one that overlaps the end is written") {
        let audio = SystemAudio()
        audio.deliver(from: time(10), to: time(10.02))
        // The monitor wrote silence in the buffers' place
        _ = audio.fill(upTo: time(12))
        expectEqual(audio.end, time(12), "filled")
        expect(audio.deliver(from: time(10.02), to: time(10.04)) == nil, "a buffer wholly before the end is dropped")
        expect(audio.deliver(from: time(11.98), to: time(12)) == nil, "so is one that ends exactly at the end")
        expectEqual(audio.dropped, 2, "dropped")
        expectEqual(audio.deliver(from: time(11.99), to: time(12.01)), time(12), "a buffer that overlaps the end is written whole, at the end")
        expectEqual(audio.end, time(12.02), "which puts the audio late by less than one buffer")
        expectEqual(audio.deliver(from: time(12.01), to: time(12.03)), time(12.02), "and the next one follows")
    }

    await test("Timeline: a pause is taken out of the timeline, and so is every later one") {
        // What the writer keeps: timeOffset and lastPTS
        var offset = CMTime.zero
        var last: CMTime?
        func arrive(_ raw: Double, resume: Bool = false) -> CMTime {
            if resume, let end = last { offset = Timeline.pauseOffset(resumingAt: time(raw), last: end, current: offset) }
            let pts = CMTimeSubtract(time(raw), offset)
            last = Timeline.latestEnd(CMTimeAdd(pts, time(1)), after: last)
            return pts
        }
        expectEqual(arrive(100), time(100), "before any pause the times are the buffers' own")
        expectEqual(arrive(109), time(109), "")
        // Paused at 110 for 30 s
        expectEqual(arrive(140, resume: true), time(110), "the first buffer after the pause continues where the recording left off")
        expectEqual(offset, time(30), "time taken out")
        expectEqual(arrive(144), time(114), "what follows is moved by the same amount")
        // Paused at 115 on the timeline (145 on the clock) for 55 s
        expectEqual(arrive(200, resume: true), time(115), "a second pause adds to the first")
        expectEqual(offset, time(85), "time taken out")
        expectEqual(last, time(116), "end of the timeline")
    }

    await test("Timeline: the pause offset never gets smaller and the end never moves back") {
        expectEqual(Timeline.pauseOffset(resumingAt: time(140), last: time(110), current: .zero), time(30), "offset")
        expectEqual(Timeline.pauseOffset(resumingAt: time(140), last: time(120), current: time(30)), time(30), "a smaller offset is not taken")
        expectEqual(Timeline.pauseOffset(resumingAt: time(100), last: time(110), current: .zero), .zero, "nor a negative one")
        expectEqual(Timeline.latestEnd(time(5), after: nil), time(5), "the first end")
        expectEqual(Timeline.latestEnd(time(4), after: time(5)), time(5), "an earlier end changes nothing")
        expectEqual(Timeline.latestEnd(time(5), after: time(5)), time(5), "nor the same")
        expectEqual(Timeline.latestEnd(time(6), after: time(5)), time(6), "a later one is taken")
        expectEqual(Timeline.latestEnd(nil, after: time(5)), time(5), "no end changes nothing")
        expectEqual(Timeline.latestEnd(.invalid, after: time(5)), time(5), "nor an invalid one")
        expect(Timeline.latestEnd(.invalid, after: nil) == nil, "an invalid end is never taken")
    }

    await test("Status bar: the timer reads mm:ss, and h:mm:ss from the first hour") {
        let cases: [(TimeInterval, String)] = [
            (0, "00:00"), (0.9, "00:00"), (59.99, "00:59"), (60, "01:00"), (425, "07:05"), (3599, "59:59"),
            (3600, "1:00:00"), (4025, "1:07:05"), (5400, "1:30:00"), (36000 + 62, "10:01:02"),
            (-5, "00:00"), (.nan, "00:00"), (.infinity, "00:00")
        ]
        for (interval, text) in cases {
            expectEqual(Timeline.lengthText(interval), text, "\(interval) s")
        }
    }

    await test("placement: a tap buffer goes back to back within 0.1 s of where it arrived, a hole is filled first, and only a time that is taken leaves it out") {
        let tolerance = 0.1
        func place(_ from: Double, end: Double?, floor: Double = 0, fills: CMTime? = nil, filled: inout [CMTime]) -> CMTime? {
            var asked = [CMTime]()
            let placed = SystemAudioPlacement.placeArrived(from: time(from), to: time(from + 0.02), end: end.map { time($0) }, floor: time(floor), tolerance: tolerance) { upTo in
                asked.append(upTo)
                return fills
            }
            filled = asked
            return placed
        }
        var filled = [CMTime]()
        expectEqual(place(10, end: 10, filled: &filled), time(10), "at the end of the track")
        expectEqual(place(10.1, end: 10, filled: &filled), time(10), "up to 0.1 s after the end: back to back, the hole not worth silence")
        expect(filled.isEmpty, "and nothing filled")
        expectEqual(place(9.9, end: 10, filled: &filled), time(10), "arrived before the end, by up to 0.1 s: still at the end, not left out")
        expectEqual(place(9.88, end: 10, filled: &filled), time(10), "also when it ends 0.1 s before it")
        expect(place(9.87, end: 10, filled: &filled) == nil, "ending more than 0.1 s before the track's end, its time is taken: left out")
        expect(place(-1090, end: 10, filled: &filled) == nil, "however far")
        expect(filled.isEmpty, "without any silence")
        expect(SystemAudioPlacement.isTaken(time(9.89), end: time(10), tolerance: tolerance), "taken: more than the tolerance beyond its end")
        expect(!SystemAudioPlacement.isTaken(time(9.9), end: time(10), tolerance: tolerance), "not at the tolerance")
        expect(!SystemAudioPlacement.isTaken(time(10.5), end: time(10), tolerance: tolerance), "nor after the end")
        // A hole of more than the tolerance: silence up to the buffer first
        expectEqual(place(10.5, end: 10, fills: time(10.5), filled: &filled), time(10.5), "after the silence that fills a real hole")
        expectEqual(filled, [time(10.5)], "silence asked for up to the buffer")
        expectEqual(place(10.5, end: 10, fills: time(10.45), filled: &filled), time(10.45), "silence that ends within the tolerance will do")
        expect(place(10.5, end: 10, fills: time(10.2), filled: &filled) == nil, "not written while the silence could not be: it would be early")
        expect(place(10.5, end: 10, fills: nil, filled: &filled) == nil, "nor when there is none at all")
        // Before anything is in the track: the buffer that reaches into the recording begins it
        expectEqual(place(4.99, end: nil, floor: 5, filled: &filled), time(4.99), "the first buffer that ends after the recording's start is taken, at its own time")
        expect(place(4.98, end: nil, floor: 5, filled: &filled) == nil, "one that ends at the start is not")
        expect(place(3, end: nil, floor: 5, filled: &filled) == nil, "nor one before it")
        // The stream's rule is another: what lies before the end is left out, which for the tap would lose 0.1 s
        // each time its converter's timeline starts anew
        expect(SystemAudioPlacement.place(from: time(9.9), to: time(9.92), end: time(10), tolerance: tolerance) { _ in nil } == nil, "the stream's buffer before the end is left out")
    }

    await test("tap drift: the track is brought back a frame at a time once it is 10 ms from the arrivals, until it is within 2 ms") {
        expectEqual([TapDrift.begins, TapDrift.ends, TapDrift.window, TapDrift.spacing], [0.010, 0.002, 2.0, 0.1], "the thresholds")
        let frame = 1.0 / 48000
        let length = 1024 * frame
        // Arrivals that jitter by milliseconds around the track's end are not drift
        var jitter = TapDrift()
        var asked = 0
        for index in 0..<2000 { asked += abs(jitter.next(offset: index % 2 == 0 ? 0.008 : -0.008, duration: length)) }
        expectEqual(asked, 0, "jitter of 8 ms either way moves nothing")
        var once = TapDrift()
        expectEqual(once.next(offset: 0.09, duration: length), 0, "nor does a single buffer 90 ms late")
        expect(!once.isCorrecting, "which is not a run")
        // A device 50 parts in a million slow or fast, for an hour and a half
        for direction in [1.0, -1.0] {
            var drift = TapDrift()
            var offset = 0.0
            var furthest = 0.0
            var changes = 0
            var sinceChange = 1.0
            var closest = 1.0
            for _ in 0..<Int(5400 / length) {
                offset += direction * length * 50 / 1_000_000
                let frames = drift.next(offset: offset, duration: length)
                sinceChange += length
                if frames != 0 {
                    expectEqual(Double(frames), direction, "a frame added when the track is behind, taken out when it is ahead")
                    drift.applied(frames, frame: frame)
                    offset -= Double(frames) * frame
                    changes += 1
                    closest = min(closest, sinceChange)
                    sinceChange = 0
                }
                furthest = max(furthest, abs(offset))
            }
            expect(furthest < 0.0125, "\(direction): never more than about 12 ms off: \(furthest) s")
            expect(abs(offset) < 0.011, "\(direction): at the end too: \(offset) s")
            expectClose(Double(changes), 5400 * 50 / 1_000_000 * 48000, within: 520, "\(direction): the frames the device's clock was off by, less what is still to do")
            expect(closest >= TapDrift.spacing, "\(direction): no two frames closer than 0.1 s of audio: \(closest) s")
            expect(drift.runs >= 10 && drift.runs <= 40, "\(direction): in runs, with the track left alone in between: \(drift.runs)")
            expectEqual(direction > 0 ? drift.removed : drift.added, 0, "\(direction): never the other way")
            expectClose(try require(drift.partsPerMillion, "its rate"), direction * 50, within: 5, "\(direction): the summary's figure is the device's")
        }
        // Silence written up to the buffer: the track is where the arrivals are again
        var drift = TapDrift()
        for _ in 0..<400 { _ = drift.next(offset: 0.03, duration: length) }
        expect(drift.isCorrecting && drift.behind > 0.02, "30 ms behind is being corrected")
        drift.restart()
        expect(!drift.isCorrecting && drift.behind == 0, "forgotten after silence")
        expectEqual(drift.next(offset: .nan, duration: length), 0, "a time that is none asks for nothing")
        expectEqual(drift.next(offset: 0.05, duration: 0), 0, "nor a buffer without length")
        expect(TapDrift().partsPerMillion == nil, "no rate before any audio")
    }

    await test("DiskSpace: start, stop and mix thresholds") {
        expectEqual(DiskSpace.startMinimum, 2_000_000_000, "start minimum")
        expectEqual(DiskSpace.stopMinimum, 500_000_000, "stop minimum")
        expect(DiskSpace.canStart(free: 2_000_000_000), "2 GB is enough to start")
        expect(!DiskSpace.canStart(free: 1_999_999_999), "less is not")
        expect(!DiskSpace.canStart(free: 0), "a full disk is not")
        expect(DiskSpace.mustStop(free: 499_999_999), "less than 500 MB stops the recording")
        expect(!DiskSpace.mustStop(free: 500_000_000), "500 MB does not")
        expect(!DiskSpace.mustStop(free: DiskSpace.startMinimum), "a recording that may start is not stopped at once")
        expect(DiskSpace.hasRoom(forCopyOf: 1_000_000_000, free: 1_500_000_001), "a copy fits with 500 MB to spare")
        expect(!DiskSpace.hasRoom(forCopyOf: 1_000_000_000, free: 1_500_000_000), "not with exactly that")
        expect(!DiskSpace.hasRoom(forCopyOf: 3_000_000_000, free: 2_900_000_000), "not when the file is larger than the free space")
    }

    await test("DiskSpace: while a recording is starting or running, the mix of an earlier one must leave it the room it started with") {
        expectEqual(DiskSpace.copyReserve(recording: false), DiskSpace.stopMinimum, "nothing running: 500 MB to spare")
        expectEqual(DiskSpace.copyReserve(recording: true), DiskSpace.startMinimum, "a recording running: the 2 GB it was started with")
        // 3 GB free, a 2 GB recording stopped and the next started at once
        let folder = try Suite.folder("disk-beside")
        let file = folder.appendingPathComponent("Recording at X.recording.mp4")
        try Data(count: 2000).write(to: file)
        let scale: Int64 = 1_000_000
        func fits(free: Int64, recording: Bool) -> Bool {
            // The file's 2000 bytes stand for 2 GB: the free space is told less what a real one would add
            DiskSpace.hasRoomForCopy(of: file, recording: recording) { _ in free - 2000 * scale + 2000 }
        }
        expect(fits(free: 3000 * scale, recording: false), "alone, the mix fits: 2 GB beside 3 GB free leaves the 500 MB")
        expect(!fits(free: 3000 * scale, recording: true), "beside a running recording it does not: it would leave it 1 GB, and stop it after 500 MB")
        expect(!fits(free: 4000 * scale, recording: true), "nor with exactly 2 GB left over")
        expect(fits(free: 4000 * scale + 1, recording: true), "with more than 2 GB left over it does")
        expect(DiskSpace.hasRoomForCopy(of: folder.appendingPathComponent("missing.mp4"), recording: true) { _ in 0 }, "a file that cannot be measured does not stop the mix")
        expect(DiskSpace.hasRoomForCopy(of: file, recording: true) { _ in nil }, "nor a volume that does not say")
        // The recorder says when it has a recording
        let first = NSObject(), second = NSObject()
        let was = DiskSpace.isRecording
        DiskSpace.setRecording(true, for: ObjectIdentifier(first))
        DiskSpace.setRecording(true, for: ObjectIdentifier(second))
        expect(DiskSpace.isRecording, "a recording is starting or running")
        DiskSpace.setRecording(false, for: ObjectIdentifier(first))
        expect(DiskSpace.isRecording, "still, while another recorder has one")
        expect(DiskSpace.noRoom(to: "mix the audio tracks").contains("kept for the recording that is running"), "the failure says why the space is not used: \(DiskSpace.noRoom(to: "mix the audio tracks"))")
        DiskSpace.setRecording(false, for: ObjectIdentifier(second))
        expectEqual(DiskSpace.isRecording, was, "and when it is over")
        expectEqual(DiskSpace.noRoom(to: "mix the audio tracks", recording: false), "Not enough free disk space to mix the audio tracks.", "without one, as before")
    }

    await test("DiskSpace: an open recording is followed when its folder moves, and found when it is deleted") {
        let parent = try Suite.folder("open-file")
        let folder = parent.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Recording at X.mp4")
        try Data(count: 100).write(to: file)
        let opened = try require(DiskSpace.OpenFile(file), "the file opens")
        expectEqual(opened.folder, folder.path, "its folder")
        expect(!opened.isDeleted, "not deleted")
        let moved = parent.appendingPathComponent("Meetings renamed")
        try FileManager.default.moveItem(at: folder, to: moved)
        expectEqual(opened.folder, moved.path, "the folder after it was renamed")
        expect(!opened.isDeleted, "a moved file is not deleted")
        try FileManager.default.removeItem(at: moved)
        expect(opened.isDeleted, "deleted with its folder")
        expect(opened.folder == nil, "and has no folder")
        expect(DiskSpace.OpenFile(file) == nil, "a file that is not there does not open")
    }

    await test("DiskSpace: free space counts what the system can free") {
        expectEqual(DiskSpace.usable(important: 10, free: 4), 10, "the larger of the two")
        expectEqual(DiskSpace.usable(important: 0, free: 7), 7, "a volume that reports zero for it")
        expectEqual(DiskSpace.usable(important: nil, free: 7), 7, "a volume that does not report it")
        expectEqual(DiskSpace.usable(important: 10, free: nil), 10, "only the first figure")
        expect(DiskSpace.usable(important: nil, free: nil) == nil, "nothing known")
        let folder = try Suite.folder("disk")
        let free = try require(DiskSpace.available(at: folder.path), "free space of a real folder")
        expect(free > 0, "a real volume has free space: \(free)")
        expect(DiskSpace.available(at: "/nonexistent-\(UUID().uuidString)/x") == nil, "nothing known about a path that does not exist")
        expect(DiskSpace.hasRoomForCopy(of: folder.appendingPathComponent("missing.mp4")), "a file that cannot be measured does not stop the mix")
        let file = folder.appendingPathComponent("small.mp4")
        try Data(count: 1000).write(to: file)
        expectEqual(DiskSpace.hasRoomForCopy(of: file), DiskSpace.hasRoom(forCopyOf: 1000, free: free), "a small file fits when the volume has room")
        let package = folder.appendingPathComponent("Recording at X.qma")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(count: 3000).write(to: package.appendingPathComponent("sys.m4a"))
        try Data(count: 4000).write(to: package.appendingPathComponent("mic.m4a"))
        expectEqual(DiskSpace.size(of: package), 7000, "a package is as large as the files in it")
        expectEqual(DiskSpace.size(of: file), 1000, "a file is as large as itself")
        expect(DiskSpace.size(of: folder.appendingPathComponent("missing.mp4")) == nil, "a file that is not there has no size")
    }

    await test("Stream stamps: audio stamped 1.2 s behind at real-time pace is first written at its own time and within 2 s by its arrival; a backlog's tail never is") {
        // A tenth of a second at a time, each buffer arriving 20 ms after its last frame
        var stamps = StreamStamps()
        var end = time(100)
        var byArrival: Double?
        var leftOut = 0
        var events = [StreamStamps.Event]()
        for index in 0..<60 {
            let t = 100 + Double(index) / 10
            let lag = t >= 102 ? 1.2 : 0
            let arrival = time(t + 0.12)
            let placed = stamps.start(time(t - lag), duration: time(0.1), arrival: arrival, end: end)
            events += placed.events
            guard let start = placed.start else {
                leftOut += 1
                continue
            }
            if lag > 0, byArrival == nil, start == time(t + 0.02) { byArrival = t }
            if byArrival != nil { expectEqual(start, time(t + 0.02), "from then on each ends when it arrived") }
            end = CMTimeAdd(start, time(0.1))
        }
        let since = try require(byArrival, "placed by arrival")
        expect(since - 102 <= 2, "within 2 s: after \(since - 102) s")
        expect(leftOut <= 12, "what lay before the end of the track is left out until the stamps pass it, no more: \(leftOut) buffers")
        expect(events.contains { if case .lagging = $0 { return true } else { return false } }, "said once: \(events)")
        expectEqual(stamps.runs, 1, "one run")

        // Five seconds handed over in half a second, the first 5 s after its time: behind, and not at real-time pace
        var backlog = StreamStamps()
        var kept = 0
        for index in 0..<50 {
            let stamp = 200 + Double(index) / 10
            let arrival = time(205 + Double(index) / 100)
            let placed = backlog.start(time(stamp), duration: time(0.1), arrival: arrival, end: time(200))
            if placed.start == time(stamp) { kept += 1 }
            expect(placed.start == nil || placed.start == time(stamp), "a backlog keeps its own times")
        }
        expectEqual(kept, 50, "and what does not lie before the end of the track is written")
        expectEqual(backlog.total, 0, "none by its arrival")
    }
}
