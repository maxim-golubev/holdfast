//
//  FilesTests.swift
//  File names of a recording, and what an earlier run left behind
//

import AVFoundation
import Foundation

func filesTests() async {
    let prefix = "Recording at "

    await test("Names: a new recording is named with the prefix and the date") {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 3, 4, 5, 6, 7)
        let date = try require(Calendar.current.date(from: parts), "date")
        expectEqual(RecordingFileStore.basePath(directory: "/Users/me/Movies", prefix: prefix, date: date), "/Users/me/Movies/Recording at 2026-03-04 05.06.07", "base path")
    }

    await test("Names: a video recording that is mixed is written under temporary names") {
        let base = "/save/Recording at 2026-03-04 05.06.07"
        let files = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: false)
        expectEqual(files.rawURL.path, base + ".recording.mp4", "written as")
        expectEqual(files.mixURL?.path, base + ".mixing.mp4", "mixed as")
        expectEqual(files.finalURL.path, base + ".mp4", "final name")
        expectEqual(files.unmixedURL?.path, base + " (unmixed, 2 audio tracks).mp4", "name of the recording as written")
        expect(files.systemAudioURL == nil && files.micAudioURL == nil, "no audio files")
        for url in [files.rawURL, files.mixURL, files.finalURL, files.unmixedURL].compactMap({ $0 }) {
            expectEqual(url.pathExtension, "mp4", "the real extension comes last, so the file opens: \(url.lastPathComponent)")
        }
        let mov = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mov", audioEnding: "m4a", exportsMP3: false)
        expectEqual(mov.rawURL.lastPathComponent, "Recording at 2026-03-04 05.06.07.recording.mov", "mov")
    }

    await test("Names: a video recording that is not mixed is written under its final name") {
        let base = "/save/Recording at X"
        for (mic, system, remux) in [(false, true, true), (true, false, true), (true, true, false), (false, false, false)] {
            let files = RecordingFiles(base: base, audioOnly: false, recordMic: mic, systemAudio: system, remuxAudio: remux, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: false)
            expectEqual(files.rawURL.path, base + ".mp4", "written as (mic \(mic), system audio \(system), mix \(remux))")
            expectEqual(files.finalURL, files.rawURL, "final name")
            expect(files.mixURL == nil && files.unmixedURL == nil, "no temporary names")
        }
    }

    await test("Names: audio-only recordings") {
        let base = "/save/Recording at X"
        let plain = RecordingFiles(base: base, audioOnly: true, recordMic: false, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: false)
        expectEqual(plain.rawURL.path, base + ".m4a", "system audio alone: one file")
        expectEqual(plain.systemAudioURL, plain.rawURL, "which is the system audio file")
        expectEqual(plain.finalURL, plain.rawURL, "and the final one")
        expect(plain.micAudioURL == nil && plain.mixURL == nil && plain.unmixedURL == nil, "nothing else")
        let mp3 = RecordingFiles(base: base, audioOnly: true, recordMic: false, systemAudio: true, remuxAudio: false, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: true)
        expectEqual(mp3.rawURL.path, base + ".m4a", "MP3 is recorded as AAC")
        expectEqual(mp3.finalURL.path, base + ".mp3", "and converted")
        let package = RecordingFiles(base: base, audioOnly: true, recordMic: true, systemAudio: true, remuxAudio: false, videoEnding: "mp4", audioEnding: "flac", exportsMP3: false)
        expectEqual(package.rawURL.path, base + ".qma", "with a microphone: a package")
        expectEqual(package.systemAudioURL?.path, base + ".qma/sys.flac", "system audio in the package")
        expectEqual(package.micAudioURL?.path, base + ".qma/mic.flac", "microphone in the package")
        expectEqual(package.finalURL, package.rawURL, "the package is what is kept")
        let mixed = RecordingFiles(base: base, audioOnly: true, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: true)
        expectEqual(mixed.finalURL.path, base + ".mp3", "mixed down to one file")
        expectEqual(mixed.rawURL.path, base + ".qma", "from the package")
    }

    await test("Leftovers: only the app's own files under a temporary name are taken") {
        let folder = try Suite.folder("leftovers")
        func make(_ name: String) throws { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        let mine = ["Recording at 2026-01-02 10.00.00.recording.mp4", "Recording at 2026-01-02 10.00.00.mixing.mp4", "Recording at 2026-01-03 09.00.00.recording.MOV", "Recording at b.mixing.mov"]
        let others = [
            "Lecture.recording.mp4",                                          // someone else's file
            "My Recording at 2026.recording.mp4",                             // the prefix is not at the start
            "Recording at .recording.mp4",                                    // nothing after the prefix
            "Recording at 2026-01-02 10.00.00.mp4",                           // a final name
            "Recording at 2026-01-02 10.00.00 (unmixed, 2 audio tracks).mp4", // a final name
            "Recording at 2026-01-02 10.00.00 (recovered).mp4",
            "Recording at 2026-01-02 10.00.00 (incomplete mix).mp4",
            "Recording at 2026-01-02 10.00.00 (damaged).mp4",
            "Recording at 2026-01-02 10.00.00.recording.m4a",                 // not a video
            "Recording at 2026-01-02 10.00.00.recording",
            "Recording at 2026-01-02 10.00.00.recording.mp4.part",
            "Recording at c.Recording.mp4",                                   // not the marker
            "Recording at 2026-01-02 10.00.00.recording.mixing.txt"
        ]
        for name in mine + others { try make(name) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Recording at folder.recording.mp4"), withIntermediateDirectories: false)
        let found = RecordingFileStore(directory: folder.path, prefix: prefix).leftovers()
        expectEqual(found.map { $0.url.lastPathComponent }, mine.sorted { folder.appendingPathComponent($0).path < folder.appendingPathComponent($1).path }, "leftovers, in the order of their paths")
        let first = try require(found.first { $0.url.lastPathComponent == mine[0] }, "the recording")
        expect(!first.isMix, "a .recording file is a recording")
        expectEqual(first.ending, "mp4", "ending")
        expectEqual(first.base, folder.appendingPathComponent("Recording at 2026-01-02 10.00.00").path, "path of the final file without its extension")
        expectEqual(found.first { $0.url.lastPathComponent == mine[1] }?.isMix, true, "a .mixing file is a mix")
        expectEqual(found.first { $0.url.lastPathComponent == mine[2] }?.ending, "MOV", "the ending is kept as it is")
        expectEqual(RecordingFileStore(directory: folder.path, prefix: "").leftovers().count, 0, "without a prefix nothing is taken")
        expectEqual(RecordingFileStore(directory: folder.path, prefix: "Lecture").leftovers().count, 0, "a name that is only the prefix is not taken")
        expectEqual(RecordingFileStore(directory: folder.appendingPathComponent("missing").path, prefix: prefix).leftovers().count, 0, "a folder that does not exist has none")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, mine.count + others.count + 1, "looking deletes nothing")
    }

    await test("Leftovers: the names a recording is written under are found again, its final names are not") {
        let folder = try Suite.folder("roundtrip")
        let base = RecordingFileStore.basePath(directory: folder.path, prefix: prefix, date: Date())
        let files = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: false)
        let mixURL = try require(files.mixURL, "mix name")
        let unmixedURL = try require(files.unmixedURL, "unmixed name")
        for url in [files.rawURL, mixURL, files.finalURL, unmixedURL] { try Data("x".utf8).write(to: url) }
        let found = RecordingFileStore(directory: folder.path, prefix: prefix).leftovers()
        expectEqual(Set(found.map { $0.url.lastPathComponent }), [files.rawURL.lastPathComponent, mixURL.lastPathComponent], "leftovers")
        expect(found.allSatisfy { $0.base == URL(fileURLWithPath: base).path }, "they lead back to the final name")
        let recording = try require(found.first { !$0.isMix }, "the recording")
        expectEqual(RecordingFileStore.temporaryURL(base: recording.base, marker: RecordingFileStore.mixMarker, ending: recording.ending), mixURL, "the mix of a leftover is written where the mix of the recording was")
        expectEqual(RecordingFileStore.unmixedURL(base: recording.base, ending: recording.ending), unmixedURL, "and the recording gets the same name")
    }

    await test("Leftovers: what each file is renamed to") {
        expectEqual(RecoveryNames.unmixed, "unmixed, 2 audio tracks", "label of the recording as written")
        expectEqual(" (\(RecoveryNames.unmixed))", RecordingFileStore.unmixedSuffix, "the same name an ordinary mix leaves")
        expect(RecoveryNames.mix(complete: true) == nil, "the mix of a closed recording gets the final name")
        expectEqual(RecoveryNames.mix(complete: false), "recovered", "the mix of an unclosed one says so")
        expectEqual(RecoveryNames.recording(complete: true, mixed: true), "unmixed, 2 audio tracks", "closed and mixed")
        expectEqual(RecoveryNames.recording(complete: false, mixed: true), "recovered, unmixed, 2 audio tracks", "not closed, mixed")
        expectEqual(RecoveryNames.recording(complete: true, mixed: false), "unmixed, 2 audio tracks", "closed, mix failed")
        expectEqual(RecoveryNames.recording(complete: false, mixed: false), "recovered", "not closed, mix failed")
        let base = "/save/Recording at X"
        expectEqual(RecordingFileStore.freeURL(base: base, label: RecoveryNames.mix(complete: true), ending: "mp4").path, base + ".mp4", "complete mix")
        expectEqual(RecordingFileStore.freeURL(base: base, label: RecoveryNames.mix(complete: false), ending: "mp4").path, base + " (recovered).mp4", "recovered mix")
        expectEqual(RecordingFileStore.freeURL(base: base, label: RecoveryNames.recording(complete: false, mixed: true), ending: "mov").path, base + " (recovered, unmixed, 2 audio tracks).mov", "recovered recording")
        expectEqual(RecordingFileStore.freeURL(base: base, label: RecoveryNames.damaged, ending: "mp4").path, base + " (damaged).mp4", "damaged recording")
        expectEqual(RecordingFileStore.freeURL(base: base, label: RecoveryNames.incompleteMix, ending: "mp4").path, base + " (incomplete mix).mp4", "interrupted mix")
        expectEqual(RecordingFileStore.freeURL(base: base, label: RecoveryNames.recording(complete: true, mixed: true), ending: "mp4"), RecordingFileStore.unmixedURL(base: base, ending: "mp4"), "a complete recording gets the name an ordinary mix gives it")
        for label in [RecoveryNames.damaged, RecoveryNames.incompleteMix, RecoveryNames.recovered, RecoveryNames.unmixed] {
            let name = RecordingFileStore.freeURL(base: base, label: label, ending: "mp4").deletingPathExtension().pathExtension
            expect(name != RecordingFileStore.rawMarker && name != RecordingFileStore.mixMarker, "\"\(label)\" is not a temporary name")
        }
    }

    await test("Leftovers: a name that is taken is never reused") {
        let folder = try Suite.folder("free")
        let base = folder.appendingPathComponent("Recording at X").path
        expectEqual(RecordingFileStore.freeURL(base: base, label: nil, ending: "mp4").path, base + ".mp4", "free")
        try Data("first".utf8).write(to: URL(fileURLWithPath: base + ".mp4"))
        expectEqual(RecordingFileStore.freeURL(base: base, label: nil, ending: "mp4").path, base + " (2).mp4", "taken once")
        try Data("second".utf8).write(to: URL(fileURLWithPath: base + " (2).mp4"))
        expectEqual(RecordingFileStore.freeURL(base: base, label: nil, ending: "mp4").path, base + " (3).mp4", "taken twice")
        try Data("damaged".utf8).write(to: URL(fileURLWithPath: base + " (damaged).mp4"))
        expectEqual(RecordingFileStore.freeURL(base: base, label: "damaged", ending: "mp4").path, base + " (damaged 2).mp4", "with a label")
    }

    await test("Leftovers: keeping a recording renames it and never deletes or replaces anything") {
        let folder = try Suite.folder("keep")
        let written = folder.appendingPathComponent("Recording at X.recording.mp4")
        let kept = folder.appendingPathComponent("Recording at X (unmixed, 2 audio tracks).mp4")
        try Data("the recording".utf8).write(to: written)
        expectEqual(RecordingFileStore.keep(written: written, as: kept), kept, "renamed")
        expectEqual(try Data(contentsOf: kept), Data("the recording".utf8), "the recording is under its new name")
        expect(!FileManager.default.fileExists(atPath: written.path), "and no longer under the temporary one")

        // The name is taken: both files stay as they are
        try Data("a newer recording".utf8).write(to: written)
        expectEqual(RecordingFileStore.keep(written: written, as: kept), written, "not renamed")
        expectEqual(try Data(contentsOf: kept), Data("the recording".utf8), "the file under that name is not replaced")
        expectEqual(try Data(contentsOf: written), Data("a newer recording".utf8), "the recording stays where it is")

        // The recording is not there (the folder was moved): nothing is created or removed
        let gone = folder.appendingPathComponent("Recording at Y.recording.mp4")
        let target = folder.appendingPathComponent("Recording at Y (unmixed, 2 audio tracks).mp4")
        expectEqual(RecordingFileStore.keep(written: gone, as: target), gone, "a missing file stays reported where it was written")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "files in the folder")
    }

    await test("Store: a new recording and a saved frame are named with their prefix in the folder") {
        let store = RecordingFileStore(directory: "/save")
        expectEqual(RecordingFileStore.namePrefix, prefix, "the prefix launch recovery knows the app's files by")
        expectEqual(store.prefix, prefix, "which is what a store names recordings with")
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 3, 4, 5, 6, 7)
        let date = try require(Calendar.current.date(from: parts), "date")
        expectEqual(store.newBase(date: date), "/save/Recording at 2026-03-04 05.06.07", "recording")
        expectEqual(store.newFrameBase(date: date), "/save/Capturing at 2026-03-04 05.06.07", "frame")
        expect(store.newBase().hasPrefix("/save/Recording at "), "now")
        expectEqual(RecordingFileStore.rawMarker, "recording", "marker of a recording being written")
        expectEqual(RecordingFileStore.mixMarker, "mixing", "marker of a mix being written")
    }

    await test("Store: a recording starts only with a folder that is there and has room") {
        let folder = try Suite.folder("store")
        let plenty: (String) -> Int64? = { _ in 50_000_000_000 }
        let missing = folder.appendingPathComponent("new/deeper")
        try RecordingFileStore(directory: missing.path).prepareForRecording(free: plenty)
        var isDirectory: ObjCBool = false
        expect(FileManager.default.fileExists(atPath: missing.path, isDirectory: &isDirectory) && isDirectory.boolValue, "a folder that is not there is created")
        try RecordingFileStore(directory: missing.path).prepareForRecording(free: plenty)
        try RecordingFileStore(directory: missing.path).prepareForRecording(free: { _ in nil })
        try RecordingFileStore(directory: missing.path).prepareForRecording(free: { _ in DiskSpace.startMinimum })
        let file = folder.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let notFolder = await expectThrows("a file in the folder's place") { try RecordingFileStore(directory: file.path).prepareForRecording(free: plenty) }
        expect(notFolder.contains("file instead of a folder"), "says so: \(notFolder)")
        let below = await expectThrows("a folder under a file") { try RecordingFileStore(directory: file.appendingPathComponent("x").path).prepareForRecording(free: plenty) }
        expect(below.contains("Unable to create"), "says so: \(below)")
        var asked: String?
        let full = await expectThrows("a full disk") {
            try RecordingFileStore(directory: missing.path).prepareForRecording(free: { asked = $0; return DiskSpace.startMinimum - 1 })
        }
        expectEqual(asked, missing.path, "the volume of the folder is what is measured")
        expect(full.contains("Not enough free disk space") && full.contains(DiskSpace.formatted(DiskSpace.startMinimum)), "says how much is needed: \(full)")
        expect(try Data(contentsOf: file) == Data("x".utf8), "nothing is touched")
    }

    await test("Store: a recording's files follow from the settings it is started with") {
        let folder = try Suite.folder("context").path
        let mixed = withSettings(["remuxAudio": true, "recordWinSound": true, "videoFormat": "mov", "audioQuality": 192]) {
            RecordingContext(audioOnly: false, recordMic: true, fastStart: false, saveDirectory: folder)
        }
        expect(mixed.rawURL.path.hasPrefix(folder + "/Recording at ") && mixed.rawURL.path.hasSuffix(".recording.mov"), "written as \(mixed.rawURL.lastPathComponent)")
        expect(mixed.mixesAudio && mixed.systemAudio && mixed.recordMic, "mixed afterwards")
        expectEqual(mixed.finalURL.pathExtension, "mov", "final name")
        expectEqual(mixed.fileType, .mov, "file type")
        expectEqual(mixed.audioSettings[AVEncoderBitRateKey] as? Int, 192_000, "audio bit rate of the recording")
        let silent = withSettings(["remuxAudio": true, "recordWinSound": false]) {
            RecordingContext(audioOnly: false, recordMic: true, fastStart: false, saveDirectory: folder)
        }
        expect(!silent.systemAudio && !silent.mixesAudio, "no system audio, nothing to mix")
        expectEqual(silent.rawURL, silent.finalURL, "written under its final name")
        let hotkey = withSettings(["remuxAudio": true, "recordWinSound": false]) {
            RecordingContext(audioOnly: false, recordMic: true, fastStart: true, saveDirectory: folder)
        }
        expect(hotkey.systemAudio && hotkey.mixesAudio, "a hotkey start always has system audio")
        let noMic = withSettings(["remuxAudio": true, "recordMic": true]) {
            RecordingContext(audioOnly: false, recordMic: false, fastStart: false, saveDirectory: folder)
        }
        expect(!noMic.recordMic && !noMic.mixesAudio, "the microphone is what the start decided, not the setting")
        let audio = withSettings(["recordWinSound": false, "audioFormat": "mp3"]) {
            RecordingContext(audioOnly: true, recordMic: false, fastStart: false, saveDirectory: folder)
        }
        expect(audio.systemAudio, "an audio-only recording always has system audio")
        expectEqual(audio.rawURL.pathExtension, "m4a", "MP3 is recorded as AAC")
        expectEqual(audio.finalURL.pathExtension, "mp3", "and converted")
        expectEqual(audio.audioEncoder, "aac", "encoder")
        expect(mixed.id != silent.id, "every recording has its own id")
    }
}
