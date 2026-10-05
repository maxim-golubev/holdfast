//
//  WriterTests.swift
//  MovieWriter fed with generated frames and audio in place of a capture: what ends up in the file
//

import AVFoundation
import Foundation

/// Runs `body` with `values` as stored settings. They go into the argument domain, which is searched first and
/// lives in this process only, so nothing is written to any preferences file.
func withSettings<T>(_ values: [String: Any], _ body: () throws -> T) rethrows -> T {
    let defaults = UserDefaults.standard
    let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(before, forName: UserDefaults.argumentDomain) }
    return try body()
}

/// A 320 x 240 frame as the capture delivers it, a tenth of a second long
func videoFrame(at pts: CMTime, shade: Int = 80) throws -> CMSampleBuffer {
    var made: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
    let pixels = try require(made, "pixel buffer")
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, Int32(shade % 256), CVPixelBufferGetDataSize(pixels)) }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let description = try CMVideoFormatDescription(imageBuffer: pixels)
    let timing = CMSampleTimingInfo(duration: time(0.1), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    return try CMSampleBuffer(imageBuffer: pixels, formatDescription: description, sampleTiming: timing)
}

/// A writer with what it reported, and the three sources of a capture to feed it from
final class TestRecording {
    /// Times of a capture are those of the host clock, far from zero
    static let base = 5000.0
    let recording: RecordingContext
    let writer: MovieWriter
    var failures = [String]()
    var sessions = 0
    var microphoneEnd: CMTime?
    var systemAudioEnd: CMTime?

    init(folder: String, audioOnly: Bool = false, microphone: Bool = true, settings: [String: Any] = [:]) throws {
        let directory = try Suite.folder(folder).path
        recording = withSettings(settings) { RecordingContext(audioOnly: audioOnly, recordMic: microphone, fastStart: false, saveDirectory: directory) }
        writer = MovieWriter(recording: recording, micConverter: microphone ? try require(MicConverter(), "converter") : nil)
        writer.events.failed = { [unowned self] in self.failures.append($0) }
        writer.events.sessionStarted = { [unowned self] in self.sessions += 1 }
        writer.events.microphoneWritten = { [unowned self] end, _ in self.microphoneEnd = end }
        writer.events.systemAudioWritten = { [unowned self] end in self.systemAudioEnd = end }
    }

    func at(_ seconds: Double) -> CMTime { time(TestRecording.base + seconds) }

    func frame(_ seconds: Double, complete: Bool = true) throws {
        writer.write(CaptureSample(kind: .screen(complete: complete), buffer: try videoFrame(at: at(seconds), shade: Int(seconds * 50)), pts: at(seconds)))
    }

    /// A tenth of a second of system audio as ScreenCaptureKit delivers it
    func systemAudio(_ seconds: Double) throws {
        writer.write(CaptureSample(kind: .audio, buffer: try audioBuffer(rate: 48000, channels: 2, frames: 4800, at: at(seconds), amplitude: 0.2), pts: at(seconds)))
    }

    /// A tenth of a second from a microphone in the format of a headset in a call
    func microphone(_ seconds: Double) throws {
        writer.write(CaptureSample(kind: .microphone, buffer: try audioBuffer(rate: 24000, frames: 2400, at: at(seconds), amplitude: 0.3), pts: at(seconds)))
    }

    /// Everything the capture delivers from `start` up to `end`, a tenth of a second at a time and a little
    /// slower than it can be made, since the writer's inputs are those of a live recording
    func feed(from start: Double, to end: Double, video: Bool = true, system: Bool = true, mic: Bool = true) throws {
        var step = 0
        while start + Double(step) / 10 < end - 0.001 {
            let t = start + Double(step) / 10
            if video { try frame(t) }
            if system { try systemAudio(t) }
            if mic { try microphone(t) }
            usleep(15_000)
            step += 1
        }
    }

    /// Calls `step` until `done` says so, for at most 3 seconds: an input of a live recording may refuse what comes too fast
    func until(_ done: () -> Bool, _ step: () -> Void) {
        var tries = 0
        while !done() && tries < 150 {
            step()
            usleep(20_000)
            tries += 1
        }
    }

    /// Finishes and closes the file like the stop path does; returns what the writer handed over
    func close() async throws -> MovieWriter.Finished {
        let finished = writer.finish()
        if let file = finished.writer {
            expectEqual(file.status, .writing, "state of the file when the inputs are finished")
            await file.finishWriting()
            expect(file.status == .completed, "the file closes: \(String(describing: file.error))")
        }
        return finished
    }

    /// Where each track of the written file starts and ends, in seconds: the video tracks, then the audio tracks
    static func tracks(of url: URL) async throws -> (video: [(start: Double, end: Double)], audio: [(start: Double, end: Double)]) {
        let asset = AVURLAsset(url: url)
        func ranges(_ type: AVMediaType) async throws -> [(start: Double, end: Double)] {
            var found = [(start: Double, end: Double)]()
            for track in try await asset.loadTracks(withMediaType: type) {
                let range = try await track.load(.timeRange)
                found.append((CMTimeGetSeconds(range.start), CMTimeGetSeconds(range.end)))
            }
            return found
        }
        return (try await ranges(.video), try await ranges(.audio))
    }
}

func writerTests() async {
    await test("Writer: video, system audio and microphone go into one file, all of the same length") {
        let run = try TestRecording(folder: "writer-all", settings: ["remuxAudio": true, "recordWinSound": true])
        let writer = run.writer
        expectEqual(run.recording.rawURL.lastPathComponent.hasSuffix(".recording.mp4"), true, "written under the temporary name")
        try writer.prepareVideo(width: 320, height: 240)
        expect(FileManager.default.fileExists(atPath: run.recording.rawURL.path), "the file is created")
        expect(writer.hasSystemAudio && writer.hasMicrophoneTrack, "both audio tracks")

        // Nothing is taken before the capture is started
        try run.frame(-1)
        expect(writer.sessionStart == nil && writer.lastPTS == nil, "a buffer before the start is ignored")
        writer.startCapturing()
        // The session starts with the first complete frame: audio and frames without a picture before it are left out
        try run.systemAudio(-0.3)
        try run.microphone(-0.3)
        try run.frame(-0.2, complete: false)
        expect(writer.sessionStart == nil, "no session before the first complete frame")
        expect(writer.audioEndPTS == nil && run.microphoneEnd == nil, "and no audio written")
        expect(writer.clockAnchor != nil, "but the clock is known")

        try run.feed(from: 0, to: 3)
        expectEqual(writer.sessionStart, run.at(0), "the session starts at the first complete frame")
        expectEqual(run.sessions, 1, "session started once")
        expectEqual(writer.lastPTS, run.at(3), "end of the timeline")
        expectClose(CMTimeGetSeconds(try require(writer.audioEndPTS, "system audio end")), TestRecording.base + 3, within: 0.11, "system audio written up to the end")
        expect(run.systemAudioEnd == writer.audioEndPTS, "system audio reported to the monitor")
        expect(run.microphoneEnd != nil, "microphone reported to the monitor")

        let finished = try await run.close()
        expect(finished.sessionStarted, "the session had started")
        expect(finished.frame != nil, "a picture of the first frame for the preview")
        expect(!writer.isCapturing, "nothing is taken any more")
        try run.frame(3)
        expect(run.failures.isEmpty, "no failure: \(run.failures)")

        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        expectEqual(tracks.video.count, 1, "video tracks")
        expectEqual(tracks.audio.count, 2, "audio tracks: system audio, microphone")
        for (name, track) in [("video", tracks.video.first), ("system audio", tracks.audio.first), ("microphone", tracks.audio.last)] {
            let track = try require(track, name)
            expectClose(track.start, 0, within: 0.1, "\(name) starts with the file")
            expectClose(track.end, 3, within: 0.25, "\(name) is as long as the recording")
        }
        let inspection = await RecordingMixer.inspect(run.recording.rawURL)
        expect(inspection.mixable && !inspection.fragmented, "a closed recording is an ordinary movie the mix can read")
    }

    await test("Writer: a pause is taken out of every track alike") {
        let run = try TestRecording(folder: "writer-pause")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        try run.feed(from: 0, to: 1)
        expect(writer.togglePause(), "paused")
        try run.feed(from: 1, to: 1.5)
        expectEqual(writer.lastPTS, run.at(1), "nothing is taken while paused")
        expect(!writer.togglePause(), "resumed")
        expect(writer.isResume, "the next buffer continues the timeline")
        // Ten seconds later
        try run.feed(from: 11, to: 12)
        expect(!writer.isResume, "continued")
        expectClose(CMTimeGetSeconds(writer.timeOffset), 10, within: 0.001, "the pause is what is taken out")
        expectEqual(writer.lastPTS, run.at(2), "the timeline continues where it left off")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        for track in tracks.video + tracks.audio {
            expectClose(track.end, 2, within: 0.25, "two seconds were recorded")
        }
        expectEqual(tracks.audio.count, 2, "audio tracks")
    }

    await test("Writer: a track whose source stops is continued, and a late frame is kept") {
        let run = try TestRecording(folder: "writer-stall")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        try run.feed(from: 0, to: 1)
        // Three seconds without anything: what the monitor does at a tick then
        let now = run.at(4)
        let target = run.at(3)
        run.until({ CMTimeGetSeconds(writer.audioEndPTS ?? .zero) >= TestRecording.base + 3 - 0.001 }) { writer.fillSystemAudio(upTo: target) }
        expectClose(CMTimeGetSeconds(try require(writer.audioEndPTS, "system audio end")), TestRecording.base + 3, within: 0.001, "system audio continued with silence")
        expect(run.systemAudioEnd != writer.audioEndPTS, "silence does not count as system audio that arrived")
        let converter = try require(writer.micConverter, "converter")
        run.until({ converter.lag(behind: target) < 0.001 }) { writer.fillMicrophone(upTo: target) }
        expectClose(converter.lag(behind: target), 0, within: 0.001, "microphone continued with silence")
        run.until({ writer.videoPTS == run.at(3.5) }) { writer.repeatVideoFrame(at: now) }
        expectEqual(writer.videoPTS, run.at(3.5), "the last frame is written again, half a second in the past")
        writer.repeatVideoFrame(at: now)
        expectEqual(writer.videoPTS, run.at(3.5), "not again within a second")
        // A new picture with a time just before the repeated frame goes right after it
        try run.frame(3.3)
        expectEqual(writer.videoPTS, CMTimeAdd(run.at(3.5), CMTime(value: 1, timescale: 100)), "a frame that is only just behind is moved, not lost")
        try run.frame(2.0)
        expectEqual(writer.videoPTS, CMTimeAdd(run.at(3.5), CMTime(value: 1, timescale: 100)), "one that is more than a second behind is left out")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        let video = try require(tracks.video.first, "video")
        expect(video.end > 3.4, "video reaches the repeated frame: \(video.end)")
        expectClose(try require(tracks.audio.first, "system audio").end, 3, within: 0.25, "system audio track")
        expect(try require(tracks.audio.last, "microphone").end > 3.2, "the microphone track is padded to the end of the recording")
    }

    await test("Writer: a muted microphone is written as silence of the same length, and comes back at its own time") {
        let run = try TestRecording(folder: "writer-mute")
        let writer = run.writer
        let converter = try require(writer.micConverter, "converter")
        let rate = Double(MicConverter.sampleRate)
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        try run.feed(from: 0, to: 1)
        let before = converter.buffersIn
        expectEqual(converter.silenceFrames, 0, "no silence while the microphone delivers")

        // A mute as short as one buffer: what follows it must not move up into its place
        writer.setMicrophoneMuted(true)
        expect(writer.isMicrophoneMuted, "muted")
        try run.feed(from: 1, to: 1.1)
        expectEqual(converter.buffersIn, before, "a muted buffer does not reach the track")
        writer.setMicrophoneMuted(false)
        try run.feed(from: 1.1, to: 2)
        expectClose(Double(converter.silenceFrames) / rate, 0.1, within: 0.02, "the muted tenth of a second is silence")
        // The resampler hands its output on in blocks, so the end of the track is up to a block behind
        expectClose(converter.lag(behind: run.at(2)), 0, within: 0.05, "and the track is where the recording is")

        // A longer one: the microphone goes on delivering, the monitor keeps the track going a second behind
        writer.setMicrophoneMuted(true)
        try run.feed(from: 2, to: 4)
        expectEqual(converter.buffersIn, before + 9, "nothing of the microphone is taken while muted")
        run.until({ converter.lag(behind: run.at(3)) < 0.001 }) { writer.fillMicrophone(upTo: run.at(3)) }
        expectClose(converter.lag(behind: run.at(3)), 0, within: 0.001, "the track is continued with silence")
        expect(run.microphoneEnd.map { CMTimeGetSeconds($0) < TestRecording.base + 2.05 } ?? false, "which is not reported as microphone audio")
        writer.setMicrophoneMuted(false)
        try run.feed(from: 4, to: 5)
        expectClose(Double(converter.silenceFrames) / rate, 2.1, within: 0.05, "silence for as long as it was muted")
        expectClose(Double(converter.framesWritten) / rate, 2.9, within: 0.1, "real audio before, between and after")
        expectClose(converter.lag(behind: run.at(5)), 0, within: 0.05, "the microphone is back at its own time")
        expectEqual(converter.buffersDropped, 0, "nothing was dropped on the way back")

        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tracks = try await TestRecording.tracks(of: run.recording.rawURL)
        let microphone = try require(tracks.audio.last, "microphone")
        expectClose(microphone.start, 0, within: 0.1, "the microphone track starts with the file")
        expectClose(microphone.end, 5, within: 0.25, "and is as long as the recording, the mute included")
        expect(RecLog.lines.contains("Microphone muted by the user") && RecLog.lines.contains("Microphone unmuted by the user"), "the log says that the silence was asked for")

        let plain = try TestRecording(folder: "writer-mute-none", microphone: false)
        plain.writer.setMicrophoneMuted(true)
        expect(!plain.writer.isMicrophoneMuted, "a recording without a microphone has nothing to mute")
    }

    await test("Writer: without a complete frame there is no session, and a failure is reported once") {
        let run = try TestRecording(folder: "writer-empty")
        let writer = run.writer
        try writer.prepareVideo(width: 320, height: 240)
        writer.startCapturing()
        try run.feed(from: 0, to: 0.5, video: false)
        try run.frame(0.5, complete: false)
        writer.fillSystemAudio(upTo: run.at(5))
        writer.fillMicrophone(upTo: run.at(5))
        writer.repeatVideoFrame(at: run.at(5))
        expect(writer.sessionStart == nil && writer.audioEndPTS == nil && writer.videoPTS == nil, "nothing is written without a session")
        expect(writer.checkWriter(), "the file is fine")
        writer.fail("first")
        writer.fail("second")
        expectEqual(run.failures, ["first"], "one report")
        expect(!writer.isCapturing, "and nothing is taken after it")
        try run.frame(1)
        expect(writer.sessionStart == nil, "not even a frame")
        let finished = writer.finish()
        expect(!finished.sessionStarted, "the stop path is told that nothing was recorded")
        expect(finished.frame == nil, "no picture")
        expect(finished.writer != nil, "the file is handed over for the stop path to discard")
        expect(MovieWriter.writeFailure(nil).hasPrefix("The recording could not be written"), "text of a write failure")
    }

    await test("Writer: a start that is discarded leaves no file") {
        let run = try TestRecording(folder: "writer-cancel", microphone: false)
        try run.writer.prepareVideo(width: 320, height: 240)
        expect(!run.writer.hasMicrophoneTrack, "no microphone track without a microphone")
        expectEqual(run.recording.rawURL, run.recording.finalURL, "and no temporary name")
        expect(FileManager.default.fileExists(atPath: run.recording.rawURL.path), "created")
        run.writer.cancel()
        expect(!FileManager.default.fileExists(atPath: run.recording.rawURL.path), "removed")
        let untouched = try TestRecording(folder: "writer-none")
        let finished = untouched.writer.finish()
        expect(finished.writer == nil && !finished.sessionStarted, "a recording that never created its file has none to save")
    }

    await test("Writer: a picture without width or height is refused before any file exists") {
        for (width, height) in [(0, 0), (0, 240), (320, 0)] {
            let run = try TestRecording(folder: "writer-empty-\(width)x\(height)", microphone: false)
            let message = await expectThrows("\(width) x \(height)") { try run.writer.prepareVideo(width: width, height: height) }
            expect(message.contains("larger area"), "the reason says what to do: \(message)")
            expect(!FileManager.default.fileExists(atPath: run.recording.rawURL.path), "no file for \(width) x \(height)")
            expect(run.writer.finish().writer == nil, "nothing to close for \(width) x \(height)")
        }
    }

    await test("Writer: a file already at the recording's name is neither written over nor removed") {
        for (audioOnly, microphone) in [(false, false), (true, false), (true, true)] {
            let run = try TestRecording(folder: "writer-taken-\(audioOnly)-\(microphone)", audioOnly: audioOnly, microphone: microphone)
            let earlier = Data("an earlier recording".utf8)
            try earlier.write(to: run.recording.rawURL)
            await expectThrows("audio-only \(audioOnly), microphone \(microphone)") {
                if audioOnly { try run.writer.prepareAudio() } else { try run.writer.prepareVideo(width: 320, height: 240) }
            }
            run.writer.cancel()
            expectEqual(try Data(contentsOf: run.recording.rawURL), earlier, "the earlier file is untouched (audio-only \(audioOnly), microphone \(microphone))")
        }
        let run = try TestRecording(folder: "writer-own-package", audioOnly: true, microphone: true)
        try run.writer.prepareAudio()
        expect(FileManager.default.fileExists(atPath: run.recording.rawURL.path), "the package is created")
        run.writer.cancel()
        expect(!FileManager.default.fileExists(atPath: run.recording.rawURL.path), "and removed with the start")
    }

    await test("Writer: an audio-only recording with a microphone is a package of two files of the same length") {
        let run = try TestRecording(folder: "writer-audio", audioOnly: true, settings: ["remuxAudio": false])
        let writer = run.writer
        let recording = run.recording
        expectEqual(recording.rawURL.pathExtension, "qma", "a package")
        try writer.prepareAudio()
        let info = try String(contentsOf: recording.rawURL.appendingPathComponent("info.json"), encoding: .utf8)
        expect(info.contains("\"format\": \"m4a\"") && info.contains("\"encoder\": \"aac\""), "what the package says about itself: \(info)")
        writer.startCapturing()
        try run.microphone(-0.1)
        try run.frame(-0.1)
        expect(writer.sessionStart == nil, "the session waits for system audio")
        try run.feed(from: 0, to: 1, video: false)
        expectEqual(writer.sessionStart, run.at(0), "the first system audio starts it")
        // Half a second of system audio is missing: it is written as silence, or the rest would be early
        try run.feed(from: 1, to: 1.5, video: false, system: false)
        try run.feed(from: 1.5, to: 2, video: false)
        expectClose(CMTimeGetSeconds(try require(writer.audioEndPTS, "system audio end")), TestRecording.base + 2, within: 0.001, "system audio is as long as the time that passed")
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let system = try await TestMovie.seconds(of: try require(recording.systemAudioURL, "system audio file"))
        let microphone = try await TestMovie.seconds(of: try require(recording.micAudioURL, "microphone file"))
        expectClose(system, 2, within: 0.15, "system audio file")
        expectClose(microphone, 2, within: 0.15, "microphone file")
    }

    await test("Writer: every audio format records audio-only files that open, with and without a microphone") {
        for audioFormat in ["aac", "alac", "flac", "opus", "mp3"] {
            for videoFormat in ["mp4", "mov"] {
                for microphone in [false, true] {
                    let what = "\(audioFormat), video format \(videoFormat), \(microphone ? "with" : "without") microphone"
                    let run = try TestRecording(folder: "writer-formats-\(audioFormat)-\(videoFormat)-\(microphone)", audioOnly: true, microphone: microphone,
                                                settings: ["audioFormat": audioFormat, "videoFormat": videoFormat, "remuxAudio": false])
                    try run.writer.prepareAudio()
                    run.writer.startCapturing()
                    try run.feed(from: 0, to: 1, video: false, mic: microphone)
                    _ = try await run.close()
                    expect(run.failures.isEmpty, "\(what): no failure: \(run.failures)")
                    var files = [try require(run.recording.systemAudioURL, "system audio file")]
                    if microphone { files.append(try require(run.recording.micAudioURL, "microphone file")) }
                    for file in files {
                        do {
                            let read = try AVAudioFile(forReading: file)
                            expectClose(Double(read.length) / read.fileFormat.sampleRate, 1, within: 0.15, "\(what): length of \(file.lastPathComponent)")
                        } catch {
                            expect(false, "\(what): \(file.lastPathComponent) does not open: \(error)")
                        }
                    }
                }
            }
        }
    }

    await test("Writer: audio settings follow the format, and an unknown one is written as AAC") {
        func format(_ settings: [String: Any]) -> AudioFormatID? { settings[AVFormatIDKey] as? AudioFormatID }
        let aac = MovieWriter.audioSettings(format: "aac", quality: 192, videoFormat: "mp4")
        expectEqual(format(aac), kAudioFormatMPEG4AAC, "aac")
        expectEqual(aac[AVEncoderBitRateKey] as? Int, 192_000, "bit rate")
        expectEqual(aac[AVSampleRateKey] as? Int, 48000, "48 kHz")
        expectEqual(aac[AVNumberOfChannelsKey] as? Int, 2, "stereo")
        expectEqual(format(MovieWriter.audioSettings(format: "mp3", quality: 128, videoFormat: "mp4")), kAudioFormatMPEG4AAC, "MP3 is recorded as AAC")
        expectEqual(format(MovieWriter.audioSettings(format: "alac", quality: 128, videoFormat: "mp4")), kAudioFormatAppleLossless, "alac")
        expectEqual(format(MovieWriter.audioSettings(format: "flac", quality: 128, videoFormat: "mp4")), kAudioFormatFLAC, "flac")
        expectEqual(format(MovieWriter.audioSettings(format: "opus", quality: 128, videoFormat: "mov")), kAudioFormatOpus, "opus in a .mov")
        expectEqual(format(MovieWriter.audioSettings(format: "opus", quality: 128, videoFormat: "mp4")), kAudioFormatMPEG4AAC, "opus does not go into an .mp4")
        expectEqual(format(MovieWriter.audioSettings(format: "opus", quality: 128, videoFormat: nil)), kAudioFormatOpus, "opus in an audio file, whatever the video format")
        expectEqual(format(MovieWriter.audioSettings(format: "wma", quality: 128, videoFormat: "mp4")), kAudioFormatMPEG4AAC, "an unknown format")
    }
}
