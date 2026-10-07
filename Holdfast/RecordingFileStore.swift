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
/// package, the MP3) and `<name> (unmixed, N audio tracks).<ext>` for a video recording as it was written. `<name>`
/// is the prefix and the date of the start. A recording made with the process tap has `<name>.tap-alive.txt` next to
/// it while it is recorded and finished (`TapSpans`), and a sound-only one without a package its backup file
/// `<name> (system audio backup).recording.<ext>`.
struct RecordingFileStore {
    /// What the app's recordings are named with, in front of the date. Launch recovery only takes files with it for its own.
    static let namePrefix = "Recording at "
    /// The same for a single frame saved as a picture
    static let framePrefix = "Capturing at "
    static let rawMarker = "recording"
    static let mixMarker = "mixing"
    static let unmixedSuffix = unmixedSuffix(tracks: 2)
    /// The tap's spans next to a recording made with the process tap: `<base>.tap-alive.txt`
    static let tapSpansEnding = "tap-alive.txt"
    /// A sound-only recording's backup of the system audio, and the tap's own file when it is kept: in a package
    /// `sys-backup.<ext>` and `sys-tap.<ext>`, else `<base> (system audio backup).<ext>` and `<base> (system audio tap).<ext>`
    static let backupFileName = "sys-backup"
    static let tapFileName = "sys-tap"
    static let backupSuffix = " (system audio backup)"
    static let tapSuffix = " (system audio tap)"

    /// " (unmixed, 3 audio tracks)"
    static func unmixedSuffix(tracks: Int) -> String { " (unmixed, \(tracks) audio tracks)" }

    let directory: String
    let prefix: String

    init(directory: String, prefix: String = RecordingFileStore.namePrefix) {
        self.directory = directory
        self.prefix = prefix
    }

    // MARK: - Names

    /// Path without extension for a recording started at `date`: `<directory>/<prefix><date>`, or `… (2)` and so
    /// on when a file in the folder already has that name, with any extension or label: the date repeats when the
    /// clock goes back (the hour repeated when daylight saving time ends, a time zone change) and when a recording
    /// is started in the second another one was. `reserved` are the paths, without extension, that recordings which
    /// are not final yet have taken (`RecorderController.basesInUse`): such a recording may have no file under its
    /// name at this moment, and the new one must still get another name.
    func newBase(date: Date = Date(), reserved: Set<String> = []) -> String {
        let base = RecordingFileStore.basePath(directory: directory, prefix: prefix, date: date)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        func taken(_ candidate: String) -> Bool {
            if reserved.contains(candidate) { return true }
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

    static func unmixedURL(base: String, ending: String, tracks: Int = 2) -> URL {
        return URL(fileURLWithPath: "\(base)\(unmixedSuffix(tracks: tracks)).\(ending)")
    }

    /// Where the tap's spans of the recording whose final file is `base` plus an extension are kept
    static func tapSpansURL(base: String) -> URL {
        return URL(fileURLWithPath: "\(base).\(tapSpansEnding)")
    }

    /// Removes the tap's spans of a recording once its final files are written; nothing when there are none
    static func removeTapSpans(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// After the system audio of a sound-only recording made with the tap was merged from its two sources into
    /// `merged`: the merged file takes the name of the tap's file (`tap`). With `keepSources` the tap's file is kept
    /// as `keptTap` and the backup's (`backup`) where it is; without, both are deleted once the merged file has its
    /// name. Throws, leaving the tap's file where it was, when the merged file cannot take its name.
    static func adoptMergedSystemAudio(merged: URL, tap: URL, keptTap: URL, backup: URL, keepSources: Bool) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: keptTap.path) else {
            throw RecordingError(String(format: "A file named \"%@\" is in the way.", keptTap.lastPathComponent))
        }
        try manager.moveItem(at: tap, to: keptTap)
        do {
            try manager.moveItem(at: merged, to: tap)
        } catch {
            try? manager.moveItem(at: keptTap, to: tap)
            throw error
        }
        guard !keepSources else { return }
        for url in [keptTap, backup] {
            do {
                try manager.removeItem(at: url)
            } catch {
                print("Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
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
    /// The path of the final file without its extension, which every file of the recording is named from
    let base: String
    /// What is written while recording: the video file, the audio file, or the .qma package for audio with a microphone
    let rawURL: URL
    /// What the audio mix after a video recording writes before it is checked and gets the final name, nil when
    /// the audio tracks are not mixed
    let mixURL: URL?
    /// The name the recording as it was written gets when it is kept, nil when the audio tracks are not mixed:
    /// "(unmixed, N audio tracks)", N being `audioTracks`
    let unmixedURL: URL?
    /// What the user ends up with
    let finalURL: URL
    /// Audio-only recordings: the name the file or package written under `rawURL` gets once it is closed, before
    /// any mix or MP3 conversion. Nil for video recordings.
    let closedURL: URL?
    /// Audio-only recordings: the system audio file, and the microphone file when there is one, as they are written
    let systemAudioURL: URL?
    let micAudioURL: URL?
    /// Recordings whose system audio comes from the process tap (`systemAudioBackup`): where the stretches in which
    /// the tap delivered are written while recording (`TapSpans`), next to the recording; deleted once the final
    /// files are written. Nil otherwise.
    let tapSpansURL: URL?
    /// Audio-only recordings with the process tap: the file ScreenCaptureKit's system audio, the backup, is written
    /// to, and the name it has once the recording is closed (in the package, the same file in the closed package).
    /// Nil otherwise.
    let backupAudioURL: URL?
    let backupClosedURL: URL?
    /// Audio-only recordings with the process tap: what the tap's own file is called when it is kept next to the
    /// system audio merged from both sources ("Keep the Unmixed Recording")
    let tapKeptURL: URL?
    /// Video recordings: how many audio tracks the file is written with (system audio, its backup, microphone)
    let audioTracks: Int
    /// Video recordings whose mix keeps the microphone as a track of its own: the system audio of a recording with
    /// the tap is always brought to one track, also when the microphone is not mixed into it
    let separatesMicrophone: Bool

    /// `videoEnding` is the file extension of the chosen video format, `audioFormat` the chosen audio format (MP3 is
    /// recorded as AAC and converted afterwards). `systemAudioBackup`: the system audio comes from the process tap,
    /// with ScreenCaptureKit's system audio recorded as a backup next to it.
    init(base: String, audioOnly: Bool, recordMic: Bool, systemAudio: Bool, remuxAudio: Bool, videoEnding: String, audioFormat: AudioFormat,
         systemAudioBackup: Bool = false) {
        let backup = systemAudio && systemAudioBackup
        self.base = base
        tapSpansURL = backup ? URL(fileURLWithPath: "\(base).\(RecordingFileStore.tapSpansEnding)") : nil
        if audioOnly {
            // Written under a temporary name and renamed once closed: an audio file that was not closed does not
            // open, so a crash must leave a name launch recovery finds
            let exported = audioFormat == .mp3 ? "mp3" : audioFormat.fileEnding
            mixURL = nil
            unmixedURL = nil
            audioTracks = 0
            separatesMicrophone = false
            if recordMic {
                let package = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.rawMarker, ending: RecordingFileStore.packageEnding)
                let closed = URL(fileURLWithPath: "\(base).\(RecordingFileStore.packageEnding)")
                let ending = audioFormat.packageFileEnding
                rawURL = package
                closedURL = closed
                systemAudioURL = package.appendingPathComponent("sys.\(ending)")
                micAudioURL = package.appendingPathComponent("mic.\(ending)")
                backupAudioURL = backup ? package.appendingPathComponent("\(RecordingFileStore.backupFileName).\(ending)") : nil
                backupClosedURL = backup ? closed.appendingPathComponent("\(RecordingFileStore.backupFileName).\(ending)") : nil
                tapKeptURL = backup ? closed.appendingPathComponent("\(RecordingFileStore.tapFileName).\(ending)") : nil
                finalURL = remuxAudio ? URL(fileURLWithPath: "\(base).\(exported)") : closed
            } else {
                let ending = audioFormat.fileEnding
                let file = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.rawMarker, ending: ending)
                let closed = URL(fileURLWithPath: "\(base).\(ending)")
                rawURL = file
                closedURL = closed
                systemAudioURL = file
                micAudioURL = nil
                let backupBase = base + RecordingFileStore.backupSuffix
                backupAudioURL = backup ? RecordingFileStore.temporaryURL(base: backupBase, marker: RecordingFileStore.rawMarker, ending: ending) : nil
                backupClosedURL = backup ? URL(fileURLWithPath: "\(backupBase).\(ending)") : nil
                tapKeptURL = backup ? URL(fileURLWithPath: "\(base)\(RecordingFileStore.tapSuffix).\(ending)") : nil
                finalURL = URL(fileURLWithPath: "\(base).\(exported)")
            }
        } else {
            finalURL = URL(fileURLWithPath: "\(base).\(videoEnding)")
            closedURL = nil
            systemAudioURL = nil
            micAudioURL = nil
            backupAudioURL = nil
            backupClosedURL = nil
            tapKeptURL = nil
            let tracks = (systemAudio ? 1 : 0) + (backup ? 1 : 0) + (recordMic ? 1 : 0)
            audioTracks = tracks
            separatesMicrophone = backup && recordMic && !remuxAudio
            // The tap's recording is always brought to one system audio track afterwards, whatever is mixed
            if (remuxAudio && recordMic && systemAudio) || backup {
                // Written under a temporary name, and so is the mix, which becomes the final file once it is
                // complete and checked
                rawURL = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.rawMarker, ending: videoEnding)
                mixURL = RecordingFileStore.temporaryURL(base: base, marker: RecordingFileStore.mixMarker, ending: videoEnding)
                unmixedURL = RecordingFileStore.unmixedURL(base: base, ending: videoEnding, tracks: tracks)
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
    static let unmixed = unmixed(tracks: 2)

    /// "unmixed, 3 audio tracks" for a recording with the tap, its backup and the microphone
    static func unmixed(tracks: Int) -> String {
        return String(RecordingFileStore.unmixedSuffix(tracks: tracks).dropFirst(2).dropLast())
    }

    /// The mix of a recording that had been closed is complete and gets the final name, without a label
    static func mix(complete: Bool) -> String? {
        return complete ? nil : recovered
    }

    /// The recording itself, which is only ever renamed. `mixed` says whether its mix was written and checked;
    /// `tracks` is how many audio tracks it has.
    static func recording(complete: Bool, mixed: Bool, tracks: Int = 2) -> String {
        if mixed { return complete ? unmixed(tracks: tracks) : recovered + ", " + unmixed(tracks: tracks) }
        return complete ? unmixed(tracks: tracks) : recovered
    }
}
