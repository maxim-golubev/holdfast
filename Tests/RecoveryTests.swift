//
//  RecoveryTests.swift
//  Launch recovery (RecordingRecovery.recover) on what a crash leaves in the save folder
//

import AVFoundation
import Foundation

/// An AAC file of `seconds` of tone, closed, as an audio-only recording is written
func toneFile(_ url: URL, seconds: Int) throws {
    let file = try AVAudioFile(forWriting: url, settings: TestMovie.aac)
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000), "buffer")
    pcm.frameLength = 48000
    let data = try require(pcm.floatChannelData, "float data")
    for channel in 0..<Int(file.processingFormat.channelCount) {
        for frame in 0..<48000 { data[channel][frame] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(frame) / 48000)) }
    }
    for _ in 0..<seconds { try file.write(from: pcm) }
    file.close()
}

func recoveryTests() async {
    let system: Loudness = { $0 < 1.5 ? 0.2 : 0 }
    let microphone: Loudness = { $0 >= 1.5 ? 0.3 : 0 }
    let settings = ["mp4": TestMovie.aac]
    func names(in folder: URL) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) }

    await test("Recovery: each leftover gets a name that says what it is, a closed recording its mix, and nothing is deleted") {
        let folder = try Suite.folder("recovery")
        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        let garbage = Data(repeating: 7, count: 5000)
        try garbage.write(to: file("Recording at A.recording.mp4"))
        try await TestMovie.write(to: file("Recording at B.recording.mp4"), seconds: 3, audio: [system, microphone])
        try await TestMovie.write(to: file("Recording at C.recording.mp4"), seconds: 2, audio: [microphone])
        try garbage.write(to: file("Recording at D.mixing.mp4"))
        try await TestMovie.write(to: file("Recording at D.recording.mp4"), seconds: 3, audio: [system, microphone])
        try garbage.write(to: file("Recording at E.recording.m4a"))
        try toneFile(file("Recording at F.recording.m4a"), seconds: 2)
        let package = file("Recording at G.recording.qma")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try QmaInfo(format: "m4a", encoder: "aac", exportMP3: false).write(package: package)
        try garbage.write(to: package.appendingPathComponent("sys.m4a"))
        try toneFile(package.appendingPathComponent("mic.m4a"), seconds: 2)
        try garbage.write(to: file("Recording at H.mixing.mp3"))

        let found = RecordingFileStore(directory: folder.path).leftovers()
        expectEqual(found.count, 9, "every leftover is found")
        let lines = await RecordingRecovery.recover(found, audioSettings: settings) { _ in }
        expectEqual(lines.count, found.count, "one paragraph about each")
        expectEqual(try names(in: folder), [
            "Recording at A (damaged).mp4",
            "Recording at B.mp4", "Recording at B (unmixed, 2 audio tracks).mp4",
            "Recording at C (unmixed, 2 audio tracks).mp4",
            "Recording at D (incomplete mix).mp4", "Recording at D.mp4", "Recording at D (unmixed, 2 audio tracks).mp4",
            "Recording at E (damaged).m4a",
            "Recording at F (recovered).m4a",
            "Recording at G (recovered).qma",
            "Recording at H (incomplete mix).mp3",
        ], "the folder afterwards")
        expectEqual(try await TestMovie.trackCounts(of: file("Recording at B.mp4")), [1, 1], "the mix has one audio track")
        expectEqual(try await TestMovie.trackCounts(of: file("Recording at B (unmixed, 2 audio tracks).mp4")), [1, 2], "the recording keeps both")
        expectEqual(try Data(contentsOf: file("Recording at D (incomplete mix).mp4")), garbage, "an interrupted mix is moved out of the way, not overwritten")
        expectEqual(try Data(contentsOf: file("Recording at A (damaged).mp4")), garbage, "a damaged recording is only renamed")
        func line(_ name: String) -> String { lines.first { $0.contains("\"\(name)\"") } ?? "" }
        expect(line("Recording at A (damaged).mp4").contains("cannot be opened"), "damaged: \(lines)")
        expect(line("Recording at B.mp4").contains("complete recording") && line("Recording at B.mp4").contains("mixed now"), "mixed: \(lines)")
        expect(line("Recording at C (unmixed, 2 audio tracks).mp4").contains("failed"), "not mixable: \(lines)")
        expect(line("Recording at E (damaged).m4a").contains("cannot be opened"), "an audio file that does not open: \(lines)")
        expect(line("Recording at F (recovered).m4a").contains("not finished (2s); its last seconds may be missing"), "an audio file that opens, with its length: \(lines)")
        expect(line("Recording at G (recovered).qma").contains("sys.m4a cannot be opened"), "a package says which file does not open: \(lines)")
        expect(line("Recording at H (incomplete mix).mp3").contains("MP3"), "an interrupted conversion: \(lines)")
        expect(line("Recording at D (incomplete mix).mp4").contains("can be deleted"), "an interrupted mix: \(lines)")
        expect(!lines.joined().contains("could not be renamed"), "every leftover was renamed: \(lines)")
        expect(RecordingFileStore(directory: folder.path).leftovers().isEmpty, "nothing is left to recover at the next launch")
    }

    await test("Recovery: a recording that was never closed is mixed under the recovered names") {
        let run = try TestRecording(folder: "recovery-writing", settings: ["remuxAudio": true, "recordWinSound": true])
        try run.writer.prepareVideo(width: 320, height: 240)
        run.writer.startCapturing()
        // Past one fragment interval, so that the file on disk opens without having been closed
        try run.feed(from: 0, to: 12)
        let snapshot = try Suite.folder("recovery-unclosed").appendingPathComponent("Recording at U.recording.mp4")
        var copied = false
        for _ in 0..<50 where !copied {
            try? FileManager.default.removeItem(at: snapshot)
            try FileManager.default.copyItem(at: run.recording.rawURL, to: snapshot)
            if let seconds = await RecordingMixer.inspect(snapshot).seconds, seconds >= 9 { copied = true } else { usleep(100_000) }
        }
        _ = try await run.close()
        expect(copied, "a fragment reached the disk")
        let unclosed = await RecordingMixer.inspect(snapshot)
        expect(unclosed.fragmented && unclosed.mixable, "a recording as a crash leaves it: still in fragments, with its three tracks")
        let folder = snapshot.deletingLastPathComponent()
        let lines = await RecordingRecovery.recover(RecordingFileStore(directory: folder.path).leftovers(), audioSettings: settings) { _ in }
        expectEqual(try names(in: folder), ["Recording at U (recovered).mp4", "Recording at U (recovered, unmixed, 2 audio tracks).mp4"], "the folder afterwards")
        expect(lines.count == 1 && lines[0].contains("not finished") && lines[0].contains("mixed now"), "the report: \(lines)")
    }

    await test("Recovery: a mix that cannot be moved away is not overwritten, and the recording is only renamed") {
        let folder = try Suite.folder("recovery-in-the-way")
        let raw = folder.appendingPathComponent("Recording at W.recording.mp4")
        try await TestMovie.write(to: raw, seconds: 2, audio: [system, microphone])
        let inTheWay = folder.appendingPathComponent("Recording at W.mixing.mp4")
        try Data("earlier mix".utf8).write(to: inTheWay)
        let leftover = try require(RecordingFileStore(directory: folder.path).leftovers().first { !$0.isMix }, "the recording")
        let line = await RecordingRecovery.recover(leftover, audioSettings: TestMovie.aac) { _ in }
        expect(line.contains("in the way"), "says why it was not mixed: \(line)")
        expectEqual(try names(in: folder), ["Recording at W.mixing.mp4", "Recording at W (unmixed, 2 audio tracks).mp4"], "the folder afterwards")
        expectEqual(try Data(contentsOf: inTheWay), Data("earlier mix".utf8), "the file in the way is untouched")
    }
}
