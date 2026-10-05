//
//  RecordingFileStore.swift
//  Holdfast
//

import Foundation

/// The folder recordings are saved to: what their files are called, what an earlier run left there, and whether
/// the folder has room.
///
/// File names. A recording whose audio tracks are mixed afterwards, and every audio-only recording, is written as
/// `<name>.recording.<ext>`; a mix or an MP3 made from it as `<name>.mixing.<ext>`. Neither name is ever a final
/// one: a file under one of them is a recording that is still running or being finished, or one that was left
/// behind by a crash or a kill. The final names are `<name>.<ext>` for the mixed recording (or the audio file, the
/// package, the MP3) and `<name> (unmixed, 2 audio tracks).<ext>` for a video recording as it was written. `<name>`
/// is the prefix and the date of the start.
struct RecordingFileStore {
    /// What the app's recordings are named with, in front of the date. Launch recovery only takes files with it for its own.
    static let namePrefix = "Recording at "
    /// The same for a single frame saved as a picture
    static let framePrefix = "Capturing at "
    static let rawMarker = "recording"
    static let mixMarker = "mixing"
    static let unmixedSuffix = " (unmixed, 2 audio tracks)"

    let directory: String
    let prefix: String

    init(directory: String, prefix: String = RecordingFileStore.namePrefix) {
        self.directory = directory
        self.prefix = prefix
    }

    // MARK: - Names

    /// Path without extension for a recording started at `date`: `<directory>/<prefix><date>`, or `… (2)` and so
    /// on when a file in the folder already has that name, with any extension or label: the date repeats when the
    /// clock goes back (the hour repeated when daylight saving time ends, a time zone change).
    func newBase(date: Date = Date()) -> String {
        let base = RecordingFileStore.basePath(directory: directory, prefix: prefix, date: date)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        func taken(_ candidate: String) -> Bool {
            let name = (candidate as NSString).lastPathComponent
            return names.contains { $0.hasPrefix(name + ".") || $0.hasPrefix(name + " (") }
        }
        var candidate = base
        var number = 2
        while taken(candidate) && number < 1000 {
            candidate = "\(base) (\(number))"
            number += 1
        }
        return candidate
    }

    /// Path without extension for a single frame saved at `date`
    func newFrameBase(date: Date = Date()) -> String {
        return RecordingFileStore.basePath(directory: directory, prefix: RecordingFileStore.framePrefix, date: date)
    }

    static func basePath(directory: String, prefix: String, date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return directory + "/" + prefix + dateFormatter.string(from: date)
    }

    /// `base` is the path of the final file without its extension
    static func temporaryURL(base: String, marker: String, ending: String) -> URL {
        return URL(fileURLWithPath: "\(base).\(marker).\(ending)")
    }

    static func unmixedURL(base: String, ending: String) -> URL {
        return URL(fileURLWithPath: "\(base)\(unmixedSuffix).\(ending)")
    }

    /// `<base>.<ending>`, or `<base> (<label>).<ending>` with a label, numbered when that name is taken
    static func freeURL(base: String, label: String?, ending: String) -> URL {
        let manager = FileManager.default
        var target = URL(fileURLWithPath: label.map { "\(base) (\($0)).\(ending)" } ?? "\(base).\(ending)")
        var number = 2
        while manager.fileExists(atPath: target.path) && number < 100 {
            target = URL(fileURLWithPath: "\(base) (\(label.map { $0 + " " } ?? "")\(number)).\(ending)")
            number += 1
        }
        return target
    }

    /// Where a file made from a recording (a mix, an MP3) is written before it is complete and checked:
    /// `<output without extension>.mixing.<ending>`, next to `output`. `ending` defaults to that of `output`.
    static func stagingURL(for output: URL, ending: String? = nil) -> URL {
        return temporaryURL(base: output.deletingPathExtension().path, marker: mixMarker, ending: ending ?? output.pathExtension)
    }

    /// Throws unless `staging` is free: what is there is not this run's, and writing would truncate or extend it.
    static func checkFree(staging: URL) throws {
        guard !FileManager.default.fileExists(atPath: staging.path) else {
            throw RecordingError(String(format: "A file named \"%@\" is in the way. Move or delete it and try again.", staging.lastPathComponent))
        }
    }

    /// Gives a complete, checked file its name: `output` appears with all of it or not at all. A file at `output` is
    /// replaced only when `replacing` (the user chose to in a save panel); otherwise it is left as it is and this throws.
    static func publish(_ staged: URL, as output: URL, replacing: Bool) throws {
        let manager = FileManager.default
        if replacing && manager.fileExists(atPath: output.path) {
            _ = try manager.replaceItemAt(output, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: output)
        }
    }

    /// Gives a recording that was written under its temporary name the name it is kept under. Nothing is deleted
    /// or replaced: when the name is taken or the rename fails, the recording stays where it is. Returns where it is afterwards.
    static func keep(written: URL, as kept: URL) -> URL {
        do {
            try FileManager.default.moveItem(at: written, to: kept)
            return kept
        } catch {
            print("Failed to rename the unmixed recording: \(error.localizedDescription)")
            return written
        }
    }

    // MARK: - Leftovers of an earlier run

    /// The extensions of the files the app writes under a temporary name: video, audio files, the audio package
    static let videoEndings: Set<String> = ["mp4", "mov"]
    static let audioEndings: Set<String> = ["m4a", "caf", "flac", "mp3"]
    static let packageEnding = "qma"

    /// What a temporary name is made of: `<base>.<marker>.<ending>`
    struct Leftover {
        let url: URL
        /// Path of the final file without its extension
        let base: String
        /// What an interrupted mix or conversion had written, as opposed to a recording
        let isMix: Bool
        let ending: String
        /// An audio-only recording (an audio file or a .qma package), which has no tracks to mix
        var isAudio: Bool { !RecordingFileStore.videoEndings.contains(ending.lowercased()) }
    }

    /// The files in the folder that this app left under a temporary name: `<prefix>….recording.<ext>` and
    /// `<prefix>….mixing.<ext>`, `<ext>` a video or audio file's or the package's. A file that merely has such an
    /// ending is someone else's and is left alone. Only call this when no recording is running or being finished, in
    /// this or in another instance of the app: until then such a file is not a leftover.
    func leftovers() -> [Leftover] {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        return files.sorted { $0.path < $1.path }.compactMap { url in
            let ending = url.pathExtension
            let isPackage = ending.lowercased() == RecordingFileStore.packageEnding
            guard isPackage || RecordingFileStore.videoEndings.union(RecordingFileStore.audioEndings).contains(ending.lowercased()) else { return nil }
            let stem = url.deletingPathExtension()
            let marker = stem.pathExtension
            guard marker == RecordingFileStore.rawMarker || marker == RecordingFileStore.mixMarker else { return nil }
            let name = stem.deletingPathExtension().lastPathComponent
            guard !prefix.isEmpty, name.hasPrefix(prefix), name.count > prefix.count else { return nil }
            // A package is a folder, everything else a file
            let values = try? url.resourceValues(forKeys: keys)
            guard (isPackage ? values?.isDirectory : values?.isRegularFile) == true else { return nil }
            return Leftover(url: url, base: stem.deletingPathExtension().path, isMix: marker == RecordingFileStore.mixMarker, ending: ending)
        }
    }

    // MARK: - Disk guard

    /// Before a recording starts: the folder is there (it is created when it is not) and its volume has room
    /// (`DiskSpace.startMinimum`). Throws what to tell the user. `free` is how the free space is found out.
    func prepareForRecording(free: (String) -> Int64? = DiskSpace.available) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { throw RecordingError("The save folder is a file instead of a folder.") }
        } else {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw RecordingError("Unable to create the save folder.")
            }
        }
        if let free = free(directory), !DiskSpace.canStart(free: free) {
            throw RecordingError(String(format: "Not enough free disk space: only %@ is left on the output volume, and at least %@ is needed to start a recording.", DiskSpace.formatted(free), DiskSpace.formatted(DiskSpace.startMinimum)))
        }
    }

    /// While a recording runs, until the watch that is returned is cancelled: `onLow` is called once, on the main
    /// thread, with the free space when the volume is nearly full (`DiskSpace.stopMinimum`), `onDeleted` when the
    /// recording's `file` was deleted. Main thread.
    func watch(file: URL, onLow: @escaping (Int64) -> Void, onDeleted: @escaping () -> Void) -> DiskSpace.Watch {
        return DiskSpace.Watch(file: file, folder: directory, onLow: onLow, onDeleted: onDeleted)
    }

    /// Before the audio mix: whether a second file as large as `url` fits next to it, or in `folder`. True when that
    /// cannot be determined.
    static func hasRoomForCopy(of url: URL, in folder: URL? = nil) -> Bool {
        return DiskSpace.hasRoomForCopy(of: url, in: folder)
    }
}

/// The files of one recording, from the path of its final file without the extension
struct RecordingFiles {
    /// What is written while recording: the video file, the audio file, or the .qma package for audio with a microphone
    let rawURL: URL
    /// What the audio mix after a video recording writes before it is checked and gets the final name, nil when
    /// the audio tracks are not mixed
    let mixURL: URL?
    /// The name the recording as it was written (two audio tracks) gets when it is kept, nil when the audio tracks are not mixed
    let unmixedURL: URL?
    /// What the user ends up with
    let finalURL: URL
    /// Audio-only recordings: the name the file or package written under `rawURL` gets once it is closed, before
    /// any mix or MP3 conversion. Nil for video recordings.
    let closedURL: URL?
    /// Audio-only recordings: the system audio file, and the microphone file when there is one, as they are written
    let systemAudioURL: URL?
    let micAudioURL: URL?

    /// `videoEnding` is the file extension of the chosen video format, `audioFormat` the chosen audio format (MP3 is
    /// recorded as AAC and converted afterwards).
    init(base: String, audioOnly: Bool, recordMic: Bool, systemAudio: Bool, remuxAudio: Bool, videoEnding: String, audioFormat: AudioFormat) {
        if audioOnly {
            // Written under a temporary name and renamed once closed: an audio file that was not closed does not
            // open, so a crash must leave a name launch recovery finds
            let exported = audioFormat == .mp3 ? "mp3" : audioFormat.fileEnding
            mixURL = nil
            unmixedURL = nil
            if recordMic {
                let package = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.rawMarker, ending: RecordingFileStore.packageEnding)
                let closed = URL(fileURLWithPath: "\(base).\(RecordingFileStore.packageEnding)")
                rawURL = package
                closedURL = closed
                systemAudioURL = package.appendingPathComponent("sys.\(audioFormat.packageFileEnding)")
                micAudioURL = package.appendingPathComponent("mic.\(audioFormat.packageFileEnding)")
                finalURL = remuxAudio ? URL(fileURLWithPath: "\(base).\(exported)") : closed
            } else {
                let file = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.rawMarker, ending: audioFormat.fileEnding)
                let closed = URL(fileURLWithPath: "\(base).\(audioFormat.fileEnding)")
                rawURL = file
                closedURL = closed
                systemAudioURL = file
                micAudioURL = nil
                finalURL = URL(fileURLWithPath: "\(base).\(exported)")
            }
        } else {
            finalURL = URL(fileURLWithPath: "\(base).\(videoEnding)")
            closedURL = nil
            systemAudioURL = nil
            micAudioURL = nil
            if remuxAudio && recordMic && systemAudio {
                // Written under a temporary name, and so is the mix, which becomes the final file once it is
                // complete and checked
                rawURL = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.rawMarker, ending: videoEnding)
                mixURL = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.mixMarker, ending: videoEnding)
                unmixedURL = RecordingFileStore.unmixedURL(base: base, ending: videoEnding)
            } else {
                mixURL = nil
                unmixedURL = nil
                rawURL = finalURL
            }
        }
    }
}

/// What a .qma package (an audio-only recording with a microphone) says about itself in its `info.json`: the
/// extension and encoder of its two files `sys.<format>` and `mic.<format>`, whether its mix is converted to MP3, and
/// the volumes of the two in the mix. Read and written by itself, without the audio files. The extension is the
/// container's: FLAC in a package is in .caf files (`AudioFormat.packageFileEnding`).
struct QmaInfo: Codable, Equatable {
    var format: String
    var encoder: String
    var exportMP3: Bool
    var sysVol: Float = 1
    var micVol: Float = 1

    static let fileName = "info.json"

    static func read(package: URL) throws -> QmaInfo {
        return try decode(Data(contentsOf: package.appendingPathComponent(fileName)))
    }

    static func decode(_ data: Data) throws -> QmaInfo {
        return try JSONDecoder().decode(QmaInfo.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func write(package: URL) throws {
        try encoded().write(to: package.appendingPathComponent(QmaInfo.fileName), options: .atomic)
    }

    /// The extension of the mix of the two files, a single file of the package's encoder: a FLAC package's mix is a
    /// .flac file. Packages of other apps' encoders keep their extension.
    var mixEnding: String { AudioFormat(rawValue: encoder)?.fileEnding ?? format }

    func systemAudio(in package: URL) -> URL { package.appendingPathComponent("sys.\(format)") }
    func microphone(in package: URL) -> URL { package.appendingPathComponent("mic.\(format)") }
}

/// The labels launch recovery puts in the names of the files an earlier run left behind: `<name> (<label>).<ext>`
enum RecoveryNames {
    /// What an interrupted mix had written
    static let incompleteMix = "incomplete mix"
    /// A recording that does not open
    static let damaged = "damaged"
    static let recovered = "recovered"
    /// "unmixed, 2 audio tracks": the label of the recording as it was written, as after an ordinary mix
    static let unmixed = String(RecordingFileStore.unmixedSuffix.dropFirst(2).dropLast())

    /// The mix of a recording that had been closed is complete and gets the final name, without a label
    static func mix(complete: Bool) -> String? {
        return complete ? nil : recovered
    }

    /// The recording itself, which is only ever renamed. `mixed` says whether its mix was written and checked.
    static func recording(complete: Bool, mixed: Bool) -> String {
        if mixed { return complete ? unmixed : recovered + ", " + unmixed }
        return complete ? unmixed : recovered
    }
}
