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
    }
}
