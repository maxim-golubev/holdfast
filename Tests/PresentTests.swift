//
//  PresentTests.swift
//  The timeline never runs past the present: buffers stamped far from the time they arrived, ends in the future,
//  the stop's padding and the mix check of the lengths. A FaceTime call once came out with 38 minutes of audio
//  for 20 minutes of picture.
//

import AVFoundation
import Foundation

func presentTests() async {
    await test("Arrival check: a frame or stream audio stamped more than 1 s from its arrival, a microphone 1 s after or 300 s before, is not at its time") {
        let arrival = time(5000)
        let behind = ArrivalCheck.behind
        expectEqual(ArrivalCheck.verdict(pts: time(4999.98), arrival: arrival, behind: behind), .trusted, "a buffer stamped just before it arrived")
        expectEqual(ArrivalCheck.verdict(pts: time(5000.9), arrival: arrival, behind: behind), .trusted, "up to a second after it")
        expectEqual(ArrivalCheck.verdict(pts: time(4999.1), arrival: arrival, behind: behind), .trusted, "and up to a second before it")
        expectEqual(ArrivalCheck.verdict(pts: time(6100), arrival: arrival, behind: behind), .ahead(1100), "1100 s in the future")
        expectEqual(ArrivalCheck.verdict(pts: time(5001.5), arrival: arrival, behind: behind), .ahead(1.5), "1.5 s in the future")
        expectEqual(ArrivalCheck.verdict(pts: time(4998.5), arrival: arrival, behind: behind), .behind(1.5), "1.5 s old: the same the other way")
        expectEqual(ArrivalCheck.verdict(pts: time(4990), arrival: arrival, behind: behind), .behind(10), "10 s old")
        let microphone = ArrivalCheck.microphoneBehind
        expectEqual(ArrivalCheck.verdict(pts: time(4960), arrival: arrival, behind: microphone), .trusted, "a microphone backlog 40 s old is left to the converter")
        expectEqual(ArrivalCheck.verdict(pts: time(4701), arrival: arrival, behind: microphone), .trusted, "nor one 299 s old")
        expectEqual(ArrivalCheck.verdict(pts: time(4600), arrival: arrival, behind: microphone), .behind(400), "a microphone stamped 400 s before is on another clock")
        expectEqual(ArrivalCheck.verdict(pts: time(5001.5), arrival: arrival, behind: microphone), .ahead(1.5), "and one in the future is not trusted either")
        expectEqual(ArrivalCheck.verdict(pts: time(6100), arrival: .invalid, behind: behind), .trusted, "an arrival that is not known judges nothing")
        expectEqual(ArrivalCheck.restamped(arrival: arrival, duration: time(0.01)), time(4999.99), "given its arrival time, it ends when it arrived")
        expectEqual(ArrivalCheck.restamped(arrival: arrival, duration: .invalid), arrival, "without a length, it starts then")
    }

    await test("Timeline: an end after the limit is left out of the recording's length") {
        expectEqual(Timeline.latestEnd(time(10), after: time(5), limit: time(11)), time(10), "an end before the limit is taken")
        expectEqual(Timeline.latestEnd(time(1110), after: time(5), limit: time(11)), time(5), "one after it is not")
        expectEqual(Timeline.latestEnd(time(1110), after: nil, limit: time(11)), nil, "not even as the first")
        expectEqual(Timeline.latestEnd(time(1110), after: time(5)), time(1110), "without a limit any later end is taken")
    }

    await test("Writer: a buffer of the stream's audio stamped 1100 s in the future near the end of a call is recorded at its arrival time") {
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
        // As the call ends: one buffer with a time 1100 s ahead
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

    await test("Writer: a buffer stamped in the future whose arrival is not known is left out, and such a frame is written at the present") {
        let run = try TestRecording(folder: "present-future-unknown")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        run.present = 1.05
        try run.feed(from: 0, to: 1)
        let end = writer.lastPTS
        let audioEnd = writer.audioEndPTS
        try run.systemAudio(1.0 + 1100)
        try run.frame(1.0 + 1100, complete: false)
        expectEqual(writer.lastPTS, end, "the end of the timeline does not move")
        expectEqual(writer.audioEndPTS, audioEnd, "no silence is written towards it")
        expectEqual(writer.videoPTS, run.at(0.9), "a frame without a picture is not written")
        expect(writer.clockAnchor.map { $0.raw <= run.at(1) } ?? false, "and the monitor's clock does not take its time")
        expect(RecLog.lines.contains { $0.contains("A system audio buffer ending 1100.05 s after the present was left out") }, "logged once: \(RecLog.lines)")
        // A complete frame is a picture: it is never left out for its time
        try run.frame(1.0 + 1100)
        expectEqual(writer.videoPTS, run.at(1.05), "the frame is written at the present")
        expect(try require(writer.lastPTS, "end") <= run.at(1.2), "and the timeline stays there")
        expect(RecLog.lines.contains { $0.contains("Video: a frame is stamped 1099.95 s after it arrived") }, "logged: \(RecLog.lines)")
        run.present = 2.1
        try run.feed(from: 1.1, to: 2)
        expectEqual(writer.lastPTS, run.at(2), "the recording goes on")
        expectEqual(writer.videoPTS, run.at(1.9), "with every frame after it at its own time")
        _ = try await run.close()
        expect(RecLog.lines.contains { $0.contains("Left out for lying beyond the present: 2 buffers") }, "the stop gives the count")
        expect(RecLog.lines.contains { $0.contains("Video: 1 frame recorded at its arrival time in 1 run") }, "and the frame: \(RecLog.lines)")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        for track in tracks.video + tracks.audio { expectClose(track.end, 2, within: 0.25, "every track is two seconds long") }
    }

    await test("Writer: a microphone stamped 400 s before its buffers arrive is recorded at their arrival time") {
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
            try run.microphone(t - 400, arrival: t + 0.1)
            usleep(15_000)
        }
        expectEqual(converter.buffersDropped, 0, "nothing dropped")
        expectEqual(converter.shifts, 0, "nothing shifted")
        expectClose(CMTimeGetSeconds(try require(run.microphoneEnd, "microphone written")) - TestRecording.base, 2, within: 0.01, "the microphone is at its arrival time")
        expect(RecLog.lines.contains { $0.contains("Microphone: a buffer is stamped 400.10 s before it arrived") }, "logged: \(RecLog.lines)")
        expectEqual(RecLog.lines.filter { $0.contains("a buffer is stamped") }.count, 1, "once for the run")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
    }

    await test("Writer: a microphone buffer 40 s old, the end of a backlog, is left to the converter and not written at the present") {
        let run = try TestRecording(folder: "present-backlog-microphone")
        let writer = run.writer
        let converter = try require(writer.micConverter, "converter")
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        for index in 0..<10 {
            let t = Double(index) / 10
            run.present = t + 0.1
            try run.frame(t)
            try run.systemAudio(t, arrival: t + 0.1)
            try run.microphone(t, arrival: t + 0.1)
            usleep(15_000)
        }
        let end = try require(run.microphoneEnd, "microphone written")
        // A buffer captured 40 s before it arrives, as the last of a backlog would be: its time has passed
        try run.microphone(-38.9, arrival: 1.1)
        expectEqual(run.microphoneEnd, end, "it is not written at its arrival time")
        expectEqual(converter.buffersDropped, 1, "the converter drops it as late")
        expect(RecLog.lines.allSatisfy { !$0.contains("a buffer is stamped") }, "it keeps its own time: \(RecLog.lines)")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
    }

    await test("Writer and monitor: a frame and an audio buffer stamped 12 s ahead as a call connects leave no hole and do not shift the microphone") {
        // The owner's FaceTime call: as it connected, a buffer stamped about 12 s in the future reached the writer.
        // Without the checks against the present, the monitor's present ran 12 s ahead: video lost 12 s of picture,
        // system audio was filled 11 s into the future and its real buffers dropped, and the microphone, filled as
        // far, was then recorded 11 s late for the rest of the call.
        let run = try TestRecording(folder: "present-call-connect")
        let writer = run.writer
        let converter = try require(writer.micConverter, "converter")
        try writer.prepareVideo(width: 320, height: 240)
        let queue = DispatchQueue(label: "HoldfastTests.callConnect")
        let monitor = RecordingMonitor(queue: queue)
        var notified = [String]()
        monitor.notify = { title, _ in notified.append(title) }
        writer.events.microphoneWritten = { [unowned run] end, peak in
            run.microphoneEnd = end
            monitor.microphoneWritten(upTo: end, peak: peak)
        }
        writer.events.systemAudioWritten = { [unowned run] end in
            run.systemAudioEnd = end
            monitor.systemAudioWritten(upTo: end)
        }
        writer.startCapturing()
        queue.sync { monitor.watch(writer, from: DispatchTime.now().uptimeNanoseconds) }
        var latestFill = -Double.infinity
        var videoGap = 0.0
        // Every buffer arrives 0.1 s after it is stamped, and the monitor ticks after each tenth of a second
        func step(_ t: Double, tap: Bool = true) throws {
            run.present = t + 0.1
            let videoBefore = writer.videoPTS
            try queue.sync {
                try run.frame(t)
                if tap { try run.systemAudio(t, arrival: t + 0.1) }
                try run.microphone(t, arrival: t + 0.1)
                monitor.tick(at: DispatchTime.now().uptimeNanoseconds)
            }
            if let before = videoBefore, let after = writer.videoPTS { videoGap = max(videoGap, CMTimeGetSeconds(CMTimeSubtract(after, before))) }
            if let audioEnd = writer.audioEndPTS { latestFill = max(latestFill, CMTimeGetSeconds(audioEnd) - TestRecording.base - run.present) }
            usleep(15_000)
        }
        for index in 0..<30 { try step(Double(index) / 10) }
        // The call connects: a frame and a tap buffer stamped 12 s ahead, then nothing from the tap for 2 s
        try queue.sync {
            try run.frame(3.0 + 12)
            try run.systemAudio(3.0 + 12, arrival: 3.1)
        }
        for index in 30..<50 { try step(Double(index) / 10, tap: false) }
        for index in 50..<70 { try step(Double(index) / 10) }
        queue.sync { monitor.stop() }

        expect(try require(writer.clockAnchor, "clock anchor").raw <= run.at(7.1), "the monitor's present stayed with the present")
        expect(videoGap < 0.25, "no hole in the video: the longest step between frames is \(videoGap) s")
        expectEqual(writer.videoPTS, run.at(6.9), "every frame on time is written")
        expect(latestFill <= 1.0001, "system audio never reaches more than a second past the present: \(latestFill) s")
        expectClose(CMTimeGetSeconds(try require(run.systemAudioEnd, "system audio")) - TestRecording.base, 7, within: 0.01, "the tap's buffers after the silence are recorded")
        expectEqual(converter.shifts, 0, "the microphone is not shifted")
        expectEqual(converter.buffersDropped, 0, "nor any of it dropped")
        expectClose(CMTimeGetSeconds(converter.end) - TestRecording.base, 7, within: 0.03, "it ends with its last buffer, less what the resampler holds")
        expectEqual(notified, [], "nothing to notify")
        expect(RecLog.lines.contains { $0.contains("Video: a frame is stamped 12.00 s after it arrived") }, "the frame is written at the present, not 12 s ahead: \(RecLog.lines)")
        expect(RecLog.lines.contains { $0.contains("System audio: a buffer is stamped 11.90 s after it arrived") }, "the tap buffer is given its arrival time")

        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        for (name, track) in [("video", tracks.video.first), ("system audio", tracks.audio.first), ("microphone", tracks.audio.last)] {
            expectClose(try require(track, name).end, 7, within: 0.25, "\(name) is as long as the call")
        }
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

    await test("System audio source: a tap buffer ends when it arrived, and one its device stamped 1100 s ahead is recorded like the others") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tapFuture")
        let run = try TestRecording(folder: "present-tap-source", audioOnly: true, microphone: false, tap: true)
        try run.writer.prepareAudio()
        run.writer.startCapturing()
        run.present = 3.1
        var arrival = 0.0
        var samples = [CaptureSample]()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue, stallSeconds: 60, clock: { run.at(arrival) }) { sample in
            samples.append(sample)
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
        expectEqual(samples.count, 300, "every buffer handed on")
        expectEqual(samples.first?.arrival, run.at(0.01), "with the time the IOProc handed it on")
        expect(samples.allSatisfy { CMTimeAdd($0.pts, $0.buffer.duration) == $0.arrival && $0.buffer.presentationTimeStamp == $0.pts }, "which is where it ends, whatever its device stamped")
        expect(RecLog.lines.allSatisfy { !$0.contains("is stamped") }, "nothing to say about a timestamp that is not used: \(RecLog.lines)")
        let seconds = try await TestMovie.seconds(of: try require(run.recording.systemAudioURL, "system audio file"))
        expectClose(seconds, 3, within: 0.05, "three seconds in the file, nothing towards the future")
    }
}
