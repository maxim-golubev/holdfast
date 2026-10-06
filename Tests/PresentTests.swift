//
//  PresentTests.swift
//  The timeline never runs past the present: buffers stamped far from the time they arrived, ends in the future,
//  the stop's padding and the mix check of the lengths. A FaceTime call once came out with 38 minutes of audio
//  for 20 minutes of picture.
//

import AVFoundation
import Foundation

func presentTests() async {
    await test("Arrival check: audio stamped more than 1 s after it arrived, or more than 30 s before, is given its arrival time") {
        let arrival = time(5000)
        expectEqual(ArrivalCheck.verdict(pts: time(4999.98), arrival: arrival), .trusted, "a buffer stamped just before it arrived")
        expectEqual(ArrivalCheck.verdict(pts: time(5000.9), arrival: arrival), .trusted, "up to a second after it")
        expectEqual(ArrivalCheck.verdict(pts: time(4989), arrival: arrival), .trusted, "a backlog 11 s old is left to the microphone's converter")
        expectEqual(ArrivalCheck.verdict(pts: time(4971), arrival: arrival), .trusted, "29 s old")
        expectEqual(ArrivalCheck.verdict(pts: time(6100), arrival: arrival), .ahead(1100), "1100 s in the future")
        expectEqual(ArrivalCheck.verdict(pts: time(5001.5), arrival: arrival), .ahead(1.5), "1.5 s in the future")
        expectEqual(ArrivalCheck.verdict(pts: time(4960), arrival: arrival), .behind(40), "40 s old")
        expectEqual(ArrivalCheck.verdict(pts: time(6100), arrival: .invalid), .trusted, "an arrival that is not known judges nothing")
        expectEqual(ArrivalCheck.restamped(arrival: arrival, duration: time(0.01)), time(4999.99), "given its arrival time, it ends when it arrived")
        expectEqual(ArrivalCheck.restamped(arrival: arrival, duration: .invalid), arrival, "without a length, it starts then")
    }

    await test("Timeline: an end after the limit is left out of the recording's length") {
        expectEqual(Timeline.latestEnd(time(10), after: time(5), limit: time(11)), time(10), "an end before the limit is taken")
        expectEqual(Timeline.latestEnd(time(1110), after: time(5), limit: time(11)), time(5), "one after it is not")
        expectEqual(Timeline.latestEnd(time(1110), after: nil, limit: time(11)), nil, "not even as the first")
        expectEqual(Timeline.latestEnd(time(1110), after: time(5)), time(1110), "without a limit any later end is taken")
    }

    await test("Writer: a tap buffer stamped 1100 s in the future near the end of a call is recorded at its arrival time") {
        let run = try TestRecording(folder: "present-future-tap")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        // Every buffer arrives 0.1 s after it is stamped, which is the present when it is written
        func step(_ t: Double, systemStamp: Double? = nil) throws {
            run.present = t + 0.1
            try run.frame(t)
            try run.systemAudio(systemStamp ?? t, arrival: t + 0.1)
            try run.microphone(t, arrival: t + 0.1)
            usleep(15_000)
        }
        for index in 0..<30 { try step(Double(index) / 10) }
        // As the call ends: the tap hands on one buffer with a time 1100 s ahead
        try step(3.0, systemStamp: 3.0 + 1100)
        let afterIt = try require(writer.lastPTS, "end of the timeline")
        expect(afterIt <= run.at(3.1), "the end of the timeline stays at the present: \(CMTimeGetSeconds(afterIt) - TestRecording.base)")
        expectClose(CMTimeGetSeconds(try require(writer.audioEndPTS, "system audio end")) - TestRecording.base, 3.1, within: 0.01, "the buffer goes where its arrival puts it")
        for index in 31..<40 { try step(Double(index) / 10) }
        expectClose(CMTimeGetSeconds(try require(run.systemAudioEnd, "system audio reported")) - TestRecording.base, 4, within: 0.01, "the system audio after it is recorded, not dropped")
        expect(RecLog.lines.contains { $0.contains("System audio: a buffer is stamped 1099.90 s after it arrived") }, "the log says so: \(RecLog.lines)")
        expect(RecLog.lines.contains { $0.contains("System audio: timestamps can be believed again, after 1 buffer recorded at its arrival time") }, "and when the next buffer is right")
        expectEqual(writer.stopEnd(), run.at(4), "the stop brings the tracks to the end of the video")

        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        expect(RecLog.lines.contains { $0.contains("System audio: 1 buffer recorded at its arrival time in 1 run") }, "the stop gives the total")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        expectEqual(tracks.audio.count, 2, "audio tracks")
        for (name, track) in [("video", tracks.video.first), ("system audio", tracks.audio.first), ("microphone", tracks.audio.last)] {
            expectClose(try require(track, name).end, 4, within: 0.25, "\(name) is as long as the call")
        }
    }

    await test("Writer: a buffer stamped in the future whose arrival is not known, and such a frame, are left out") {
        let run = try TestRecording(folder: "present-future-unknown")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        run.present = 2.1
        try run.feed(from: 0, to: 1)
        let end = writer.lastPTS
        let audioEnd = writer.audioEndPTS
        let video = writer.videoPTS
        try run.systemAudio(1.0 + 1100)
        try run.frame(1.0 + 1100)
        try run.frame(1.0 + 1100, complete: false)
        expectEqual(writer.lastPTS, end, "the end of the timeline does not move")
        expectEqual(writer.audioEndPTS, audioEnd, "no silence is written towards it")
        expectEqual(writer.videoPTS, video, "the frame is not written")
        expect(writer.clockAnchor.map { $0.raw <= run.at(1) } ?? false, "and the monitor's clock does not take its time")
        expect(RecLog.lines.contains { $0.contains("A system audio buffer ending 1099.") && $0.contains("after the present was left out") }, "logged once: \(RecLog.lines)")
        try run.feed(from: 1, to: 2)
        expectEqual(writer.lastPTS, run.at(2), "the recording goes on")
        _ = try await run.close()
        expect(RecLog.lines.contains { $0.contains("Left out for lying beyond the present: 3 buffers") }, "the stop gives the count")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        for track in tracks.video + tracks.audio { expectClose(track.end, 2, within: 0.25, "every track is two seconds long") }
    }

    await test("Writer: a microphone buffer stamped 40 s before it arrived is recorded at its arrival time") {
        let run = try TestRecording(folder: "present-old-microphone")
        let writer = run.writer
        let converter = try require(writer.micConverter, "converter")
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        for index in 0..<20 {
            let t = Double(index) / 10
            run.present = t + 0.1
            try run.frame(t)
            try run.systemAudio(t, arrival: t + 0.1)
            try run.microphone(t - 40, arrival: t + 0.1)
            usleep(15_000)
        }
        expectEqual(converter.buffersDropped, 0, "nothing dropped")
        expectEqual(converter.shifts, 0, "nothing shifted")
        expectClose(CMTimeGetSeconds(try require(run.microphoneEnd, "microphone written")) - TestRecording.base, 2, within: 0.01, "the microphone is at its arrival time")
        expect(RecLog.lines.contains { $0.contains("Microphone: a buffer is stamped 40.10 s before it arrived") }, "logged: \(RecLog.lines)")
        expectEqual(RecLog.lines.filter { $0.contains("a buffer is stamped") }.count, 1, "once for the run")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
    }

    await test("Writer: what the monitor fills or repeats never reaches past a second after the present") {
        let run = try TestRecording(folder: "present-fills")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        run.present = 1.1
        try run.feed(from: 0, to: 1)
        // What the monitor would ask for with a clock anchored 1100 s in the future
        let far = run.at(1100)
        let limit = run.at(2.1)
        let converter = try require(writer.micConverter, "converter")
        run.until({ (writer.audioEndPTS ?? .zero) >= limit }) { writer.fillSystemAudio(upTo: far) }
        run.until({ converter.end >= CMTimeSubtract(limit, CMTime(value: 1, timescale: 48000)) }) { writer.fillMicrophone(upTo: far) }
        writer.repeatVideoFrame(at: far)
        expectEqual(writer.audioEndPTS, limit, "system audio silence up to the present plus a second")
        expectClose(CMTimeGetSeconds(converter.end) - TestRecording.base, 2.1, within: 0.001, "microphone silence as far")
        expectEqual(writer.videoPTS, run.at(1.6), "the last frame is repeated half a second before that")
        expect(try require(writer.lastPTS, "end") <= limit, "the end of the timeline is no later")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
    }

    await test("Writer: the stop pads the microphone up to the end of the video, never beyond") {
        let run = try TestRecording(folder: "present-stop-video")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        // The microphone stops after a second and the picture after three; system audio goes on to four
        for index in 0..<40 {
            let t = Double(index) / 10
            if t < 3 { try run.frame(t) }
            try run.systemAudio(t)
            if t < 1 { try run.microphone(t) }
            usleep(15_000)
        }
        expectEqual(writer.lastPTS, run.at(4), "the timeline ends with the system audio")
        expectEqual(writer.stopEnd(), run.at(3), "the tracks end with the video's last frame")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        expectClose(try require(tracks.audio.last, "microphone").end, 3, within: 0.05, "the microphone is padded to the video's end")
        expectClose(try require(tracks.audio.first, "system audio").end, 4, within: 0.15, "system audio is as it was written")
    }

    await test("Writer: the stop pads an audio-only recording's microphone no further than the present") {
        let run = try TestRecording(folder: "present-stop-audio", audioOnly: true)
        let writer = run.writer
        try writer.prepareAudio()
        writer.startCapturing()
        run.present = 3.1
        for index in 0..<30 {
            let t = Double(index) / 10
            try run.systemAudio(t)
            if t < 1 { try run.microphone(t) }
        }
        writer.fillSystemAudio(upTo: run.at(4))
        expectEqual(writer.lastPTS, run.at(4), "an end within a second of the present is taken")
        expectEqual(writer.stopEnd(), run.at(3.1), "the stop pads only to the present")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let microphone = try require(run.recording.micAudioURL, "microphone file")
        expectClose(try await TestMovie.seconds(of: microphone), 3.1, within: 0.05, "the microphone file")
    }

    await test("Mixer: a mix whose audio is more than 2 s longer or shorter than its video is rejected") {
        let folder = try Suite.folder("present-mixer")
        let system: Loudness = { $0 < 2 ? 0.2 : 0 }
        let microphone: Loudness = { $0 >= 2 ? 0.3 : 0 }
        for (name, video, audio, passes) in [("longer", 4.0, 7.0, false), ("shorter", 6.0, 3.0, false), ("close", 4.0, 5.5, true), ("short", 4.0, 2.5, true)] {
            let raw = folder.appendingPathComponent("\(name).recording.mp4")
            try await TestMovie.write(to: raw, seconds: video, audioSeconds: audio, audio: [system, microphone])
            let output = folder.appendingPathComponent("\(name).mixing.mp4")
            try await RecordingMixer.mix(source: raw, output: output, fileType: .mp4, audioSettings: TestMovie.aac) { _ in }
            if passes {
                try await RecordingMixer.verify(source: raw, output: output)
            } else {
                let message = await expectThrows("verify of the \(name) audio") { try await RecordingMixer.verify(source: raw, output: output) }
                expect(message.contains(String(format: "audio of the mixed recording is %.1f s long and its video %.1f s", audio, video)), "the reason gives both lengths: \(message)")
            }
            // A recording that was never closed: its audio may end up to a fragment earlier than its picture
            if name == "shorter" { try await RecordingMixer.verify(source: raw, output: output, unfinished: true) }
            if name == "longer" {
                await expectThrows("verify of an unfinished recording's longer audio") { try await RecordingMixer.verify(source: raw, output: output, unfinished: true) }
            }
        }
    }

    await test("Recovery: a recording whose audio runs far past its video is kept unmixed") {
        let folder = try Suite.folder("present-recovery")
        let raw = folder.appendingPathComponent("Recording at L.recording.mp4")
        try await TestMovie.write(to: raw, seconds: 4, audioSeconds: 7, audio: [{ $0 < 2 ? 0.2 : 0 }, { $0 >= 2 ? 0.3 : 0 }])
        let found = RecordingFileStore(directory: folder.path).leftovers()
        expectEqual(found.count, 1, "the leftover is found")
        let lines = await RecordingRecovery.recover(found, audioSettings: ["mp4": TestMovie.aac]) { _ in }
        expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["Recording at L (unmixed, 2 audio tracks).mp4"], "kept as written, nothing else")
        expect(lines.first?.contains("7.0 s long and its video 4.0 s") == true, "the reason: \(lines)")
    }

    await test("System audio source: a tap buffer carries when it arrived, and one stamped 1100 s ahead is recorded then") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tapFuture")
        let run = try TestRecording(folder: "present-tap-source", audioOnly: true, microphone: false)
        try run.writer.prepareAudio()
        run.writer.startCapturing()
        run.present = 3.1
        var arrival = 0.0
        var arrivals = [CMTime]()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue, clock: { run.at(arrival) }) { sample in
            arrivals.append(sample.arrival)
            run.writer.write(sample)
        }
        try source.start()
        let tap = try require(fakes.taps.first, "a tap")
        let format = tapFormat(rate: 48000, interleaved: false)
        for index in 0..<300 {
            let t = Double(index) / 100
            arrival = t + 0.01
            tap.deliver(try tapBuffer(format, frames: 480, at: run.at(index == 250 ? t + 1100 : t), amplitude: 0.3))
        }
        source.stopNow()
        queue.sync {}
        let finished = queue.sync { run.writer.finish() }
        expect(finished.sessionStarted, "recorded")
        expectEqual(arrivals.count, 300, "every buffer handed on")
        expectEqual(arrivals.first, run.at(0.01), "with the time the IOProc handed it on")
        expect(RecLog.lines.contains { $0.contains("System audio: a buffer is stamped 1099.99 s after it arrived") }, "the one in the future is recorded at that time: \(RecLog.lines)")
        let seconds = try await TestMovie.seconds(of: try require(run.recording.systemAudioURL, "system audio file"))
        expectClose(seconds, 3, within: 0.05, "three seconds in the file, nothing towards the future")
    }
}
