//
//  FilesTests.swift
//  File names of a recording, and what an earlier run left behind
//

import Foundation

func filesTests() async {
    let prefix = "Recording at "

    await test("Names: a new recording is named with the prefix and the date") {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 3, 4, 5, 6, 7)
        let date = try require(Calendar.current.date(from: parts), "date")
        expectEqual(RecordingFiles.basePath(directory: "/Users/me/Movies", prefix: prefix, date: date), "/Users/me/Movies/Recording at 2026-03-04 05.06.07", "base path")
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
        let found = RecordingMixer.leftovers(in: folder.path, prefix: prefix)
        expectEqual(found.map { $0.url.lastPathComponent }, mine.sorted { folder.appendingPathComponent($0).path < folder.appendingPathComponent($1).path }, "leftovers, in the order of their paths")
        let first = try require(found.first { $0.url.lastPathComponent == mine[0] }, "the recording")
        expect(!first.isMix, "a .recording file is a recording")
        expectEqual(first.ending, "mp4", "ending")
        expectEqual(first.base, folder.appendingPathComponent("Recording at 2026-01-02 10.00.00").path, "path of the final file without its extension")
        expectEqual(found.first { $0.url.lastPathComponent == mine[1] }?.isMix, true, "a .mixing file is a mix")
        expectEqual(found.first { $0.url.lastPathComponent == mine[2] }?.ending, "MOV", "the ending is kept as it is")
        expectEqual(RecordingMixer.leftovers(in: folder.path, prefix: "").count, 0, "without a prefix nothing is taken")
        expectEqual(RecordingMixer.leftovers(in: folder.path, prefix: "Lecture").count, 0, "a name that is only the prefix is not taken")
        expectEqual(RecordingMixer.leftovers(in: folder.appendingPathComponent("missing").path, prefix: prefix).count, 0, "a folder that does not exist has none")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, mine.count + others.count + 1, "looking deletes nothing")
    }

    await test("Leftovers: the names a recording is written under are found again, its final names are not") {
        let folder = try Suite.folder("roundtrip")
        let base = RecordingFiles.basePath(directory: folder.path, prefix: prefix, date: Date())
        let files = RecordingFiles(base: base, audioOnly: false, recordMic: true, systemAudio: true, remuxAudio: true, videoEnding: "mp4", audioEnding: "m4a", exportsMP3: false)
        let mixURL = try require(files.mixURL, "mix name")
        let unmixedURL = try require(files.unmixedURL, "unmixed name")
        for url in [files.rawURL, mixURL, files.finalURL, unmixedURL] { try Data("x".utf8).write(to: url) }
        let found = RecordingMixer.leftovers(in: folder.path, prefix: prefix)
        expectEqual(Set(found.map { $0.url.lastPathComponent }), [files.rawURL.lastPathComponent, mixURL.lastPathComponent], "leftovers")
        expect(found.allSatisfy { $0.base == URL(fileURLWithPath: base).path }, "they lead back to the final name")
        let recording = try require(found.first { !$0.isMix }, "the recording")
        expectEqual(RecordingMixer.temporaryURL(base: recording.base, marker: RecordingMixer.mixMarker, ending: recording.ending), mixURL, "the mix of a leftover is written where the mix of the recording was")
        expectEqual(RecordingMixer.unmixedURL(base: recording.base, ending: recording.ending), unmixedURL, "and the recording gets the same name")
    }

    await test("Leftovers: what each file is renamed to") {
        expectEqual(RecoveryNames.unmixed, "unmixed, 2 audio tracks", "label of the recording as written")
        expectEqual(" (\(RecoveryNames.unmixed))", RecordingMixer.unmixedSuffix, "the same name an ordinary mix leaves")
        expect(RecoveryNames.mix(complete: true) == nil, "the mix of a closed recording gets the final name")
        expectEqual(RecoveryNames.mix(complete: false), "recovered", "the mix of an unclosed one says so")
        expectEqual(RecoveryNames.recording(complete: true, mixed: true), "unmixed, 2 audio tracks", "closed and mixed")
        expectEqual(RecoveryNames.recording(complete: false, mixed: true), "recovered, unmixed, 2 audio tracks", "not closed, mixed")
        expectEqual(RecoveryNames.recording(complete: true, mixed: false), "unmixed, 2 audio tracks", "closed, mix failed")
        expectEqual(RecoveryNames.recording(complete: false, mixed: false), "recovered", "not closed, mix failed")
        let base = "/save/Recording at X"
        expectEqual(RecordingMixer.freeURL(base: base, label: RecoveryNames.mix(complete: true), ending: "mp4").path, base + ".mp4", "complete mix")
        expectEqual(RecordingMixer.freeURL(base: base, label: RecoveryNames.mix(complete: false), ending: "mp4").path, base + " (recovered).mp4", "recovered mix")
        expectEqual(RecordingMixer.freeURL(base: base, label: RecoveryNames.recording(complete: false, mixed: true), ending: "mov").path, base + " (recovered, unmixed, 2 audio tracks).mov", "recovered recording")
        expectEqual(RecordingMixer.freeURL(base: base, label: RecoveryNames.damaged, ending: "mp4").path, base + " (damaged).mp4", "damaged recording")
        expectEqual(RecordingMixer.freeURL(base: base, label: RecoveryNames.incompleteMix, ending: "mp4").path, base + " (incomplete mix).mp4", "interrupted mix")
        expectEqual(RecordingMixer.freeURL(base: base, label: RecoveryNames.recording(complete: true, mixed: true), ending: "mp4"), RecordingMixer.unmixedURL(base: base, ending: "mp4"), "a complete recording gets the name an ordinary mix gives it")
        for label in [RecoveryNames.damaged, RecoveryNames.incompleteMix, RecoveryNames.recovered, RecoveryNames.unmixed] {
            let name = RecordingMixer.freeURL(base: base, label: label, ending: "mp4").deletingPathExtension().pathExtension
            expect(name != RecordingMixer.rawMarker && name != RecordingMixer.mixMarker, "\"\(label)\" is not a temporary name")
        }
    }

    await test("Leftovers: a name that is taken is never reused") {
        let folder = try Suite.folder("free")
        let base = folder.appendingPathComponent("Recording at X").path
        expectEqual(RecordingMixer.freeURL(base: base, label: nil, ending: "mp4").path, base + ".mp4", "free")
        try Data("first".utf8).write(to: URL(fileURLWithPath: base + ".mp4"))
        expectEqual(RecordingMixer.freeURL(base: base, label: nil, ending: "mp4").path, base + " (2).mp4", "taken once")
        try Data("second".utf8).write(to: URL(fileURLWithPath: base + " (2).mp4"))
        expectEqual(RecordingMixer.freeURL(base: base, label: nil, ending: "mp4").path, base + " (3).mp4", "taken twice")
        try Data("damaged".utf8).write(to: URL(fileURLWithPath: base + " (damaged).mp4"))
        expectEqual(RecordingMixer.freeURL(base: base, label: "damaged", ending: "mp4").path, base + " (damaged 2).mp4", "with a label")
    }

    await test("Leftovers: keeping a recording renames it and never deletes or replaces anything") {
        let folder = try Suite.folder("keep")
        let written = folder.appendingPathComponent("Recording at X.recording.mp4")
        let kept = folder.appendingPathComponent("Recording at X (unmixed, 2 audio tracks).mp4")
        try Data("the recording".utf8).write(to: written)
        expectEqual(RecordingFiles.keep(written: written, as: kept), kept, "renamed")
        expectEqual(try Data(contentsOf: kept), Data("the recording".utf8), "the recording is under its new name")
        expect(!FileManager.default.fileExists(atPath: written.path), "and no longer under the temporary one")

        // The name is taken: both files stay as they are
        try Data("a newer recording".utf8).write(to: written)
        expectEqual(RecordingFiles.keep(written: written, as: kept), written, "not renamed")
        expectEqual(try Data(contentsOf: kept), Data("the recording".utf8), "the file under that name is not replaced")
        expectEqual(try Data(contentsOf: written), Data("a newer recording".utf8), "the recording stays where it is")

        // The recording is not there (the folder was moved): nothing is created or removed
        let gone = folder.appendingPathComponent("Recording at Y.recording.mp4")
        let target = folder.appendingPathComponent("Recording at Y (unmixed, 2 audio tracks).mp4")
        expectEqual(RecordingFiles.keep(written: gone, as: target), gone, "a missing file stays reported where it was written")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "files in the folder")
    }
}
