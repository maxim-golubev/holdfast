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

    await test("Recovery: the folders recorded to are remembered most recent first, a few at most") {
        var list = [String]()
        for name in ["/Users/me/Desktop", "/Users/me/Movies/", "/Users/me/Desktop", "/Volumes/Disk/Meetings/../Meetings"] {
            list = RecordingFolders.remembering(name, in: list)
        }
        expectEqual(list, ["/Volumes/Disk/Meetings", "/Users/me/Desktop", "/Users/me/Movies"], "each once, the last one written to first")
        expectEqual(RecordingFolders.remembering("", in: list), list, "no folder, nothing remembered")
        var many = list
        for number in 1...20 { many = RecordingFolders.remembering("/Users/me/Folder \(number)", in: many) }
        expectEqual(many.count, RecordingFolders.limit, "never more than the limit")
        expectEqual(many.first, "/Users/me/Folder 20", "the newest first")
        expect(!many.contains("/Users/me/Desktop"), "the ones written to longest ago go")
        expectEqual(RecordingFolders.forgetting(["/Users/me/Desktop/", "/Users/me/Elsewhere"], in: list), ["/Volumes/Disk/Meetings", "/Users/me/Movies"], "forgotten by its path")
        expectEqual(RecordingFolders.forgetting(list, in: list, keeping: ["/Users/me/Movies/"]), ["/Users/me/Movies"], "but not while a recording is being written there")
        expect(RecordingFolders.volumeIsAway("/Volumes/Disk/Meetings") { _ in false }, "a folder on a disk that is not connected")
        expect(!RecordingFolders.volumeIsAway("/Volumes/Disk/Meetings") { $0 == "/Volumes/Disk" }, "a folder that is gone from a disk that is there")
        expect(!RecordingFolders.volumeIsAway("/Users/me/Desktop") { _ in false }, "a folder on the startup disk")
    }

    await test("Recovery: every folder recorded to is searched; one that is gone or clean is forgotten, one that cannot be read is passed over") {
        let root = try Suite.folder("recovery-folders")
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let current = try folder("current"), earlier = try folder("earlier"), clean = try folder("clean"), locked = try folder("locked")
        let gone = root.appendingPathComponent("gone"), file = root.appendingPathComponent("a file")
        try Data("not a folder".utf8).write(to: file)
        let garbage = Data(repeating: 7, count: 5000)
        try await TestMovie.write(to: current.appendingPathComponent("Recording at A.recording.mp4"), seconds: 2, audio: [system, microphone])
        try await TestMovie.write(to: earlier.appendingPathComponent("Recording at B.recording.mp4"), seconds: 2, audio: [system, microphone])
        try garbage.write(to: earlier.appendingPathComponent("Recording at C.mixing.mp4"))
        // Not the app's: another prefix, and a final name
        try garbage.write(to: earlier.appendingPathComponent("Meeting.recording.mp4"))
        try garbage.write(to: clean.appendingPathComponent("Recording at D.mp4"))
        try garbage.write(to: locked.appendingPathComponent("Recording at E.recording.mp4"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        expect(RecordingFileStore(directory: locked.path).leftoversIfReadable() == nil, "a folder that may not be listed says nothing about its files")
        expectEqual(RecordingFileStore(directory: locked.path).leftovers().count, 0, "and has no leftovers to take")

        let away = "/Volumes/Holdfast Test Disk That Is Not Connected/Meetings"
        let remembered = [earlier, clean, locked, gone, file, current].map { RecordingFolders.standard($0.path) } + [away]
        let search = RecordingRecovery.search(current: current.path, remembered: remembered)
        expectEqual(search.found.map(\.path), [current.path, RecordingFolders.standard(earlier.path)], "the folders with leftovers, the save folder first and once")
        expectEqual(search.found.map { $0.leftovers.map { $0.url.lastPathComponent } }, [["Recording at A.recording.mp4"], ["Recording at B.recording.mp4", "Recording at C.mixing.mp4"]], "only the app's own unfinished files")
        expectEqual(Set(search.forget), Set([clean, gone, file].map { RecordingFolders.standard($0.path) }), "forgotten: without leftovers, gone, no folder; kept: unreadable, and on a disk that is away")
        // A save folder that was never recorded to is not in the list, and nothing is to be forgotten of it
        expectEqual(RecordingRecovery.search(current: clean.path, remembered: []).forget, [], "nothing to forget of a folder that is not remembered")
        expect(RecordingRecovery.search(current: gone.path, remembered: []).found.isEmpty, "a save folder that is gone has nothing")

        let recovered = await RecordingRecovery.recover(folders: search.found, audioSettings: settings) { _ in }
        expectEqual(try names(in: current), ["Recording at A.mp4", "Recording at A (unmixed, 2 audio tracks).mp4"], "the save folder afterwards")
        expectEqual(try names(in: earlier), ["Recording at B.mp4", "Recording at B (unmixed, 2 audio tracks).mp4", "Recording at C (incomplete mix).mp4", "Meeting.recording.mp4"],
                    "the earlier folder afterwards: its recording mixed, nothing deleted, the file of another app untouched")
        expectEqual(recovered.cleared, [current, earlier].map { RecordingFolders.standard($0.path) }, "both hold no leftovers any more")
        // One report: each folder named, with a paragraph about each of its files
        let sections = recovered.message.components(separatedBy: "Found in ")
        expectEqual(sections.count, 3, "a part for each folder: \(recovered.message)")
        expect(sections[1].hasPrefix(current.path + " from an earlier run") && sections[1].contains("\"Recording at A.mp4\"") && !sections[1].contains("Recording at B"), "the save folder's: \(sections[1])")
        expect(sections[2].hasPrefix(RecordingFolders.standard(earlier.path) + " from an earlier run") && sections[2].contains("\"Recording at B.mp4\"")
               && sections[2].contains("\"Recording at C (incomplete mix).mp4\""), "the earlier folder's: \(sections[2])")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        expectEqual(try names(in: locked), ["Recording at E.recording.mp4"], "the folder that could not be read is as it was")
        let next = RecordingRecovery.search(current: current.path, remembered: RecordingFolders.forgetting(search.forget + recovered.cleared, in: remembered))
        expectEqual(next.found.map(\.path), [RecordingFolders.standard(locked.path)], "and is searched again at the next launch, now that it can be read")
        expect(next.forget.isEmpty, "the disk that is away stays remembered: \(next.forget)")
    }

    await test("Recovery: a folder whose leftover cannot be renamed stays remembered") {
        let root = try Suite.folder("recovery-stuck")
        let raw = root.appendingPathComponent("Recording at S.recording.m4a")
        try Data(repeating: 7, count: 5000).write(to: raw)
        // Listed, but nothing in it can be renamed
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let search = RecordingRecovery.search(current: root.path, remembered: [RecordingFolders.standard(root.path)])
        expectEqual(search.found.count, 1, "found")
        let recovered = await RecordingRecovery.recover(folders: search.found, audioSettings: settings) { _ in }
        expect(recovered.message.contains("could not be renamed"), "the report says so: \(recovered.message)")
        expect(recovered.cleared.isEmpty && search.forget.isEmpty, "the folder is looked into again at the next launch")
        expect(FileManager.default.fileExists(atPath: raw.path), "and the file is where it was")
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
