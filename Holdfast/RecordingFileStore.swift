//
//  RecordingFileStore.swift
//  Holdfast
//

import Foundation

/// The folder recordings are saved to: what their files are called, what an earlier run left there, and whether
/// the folder has room.
///
/// File names. A recording whose audio tracks are mixed afterwards is written as `<name>.recording.<ext>` and the
/// mix as `<name>.mixing.<ext>`. Neither name is ever a final one: a file under one of them is a recording that is
/// still running or being finished, or one that was left behind by a crash or a kill. The final names are
/// `<name>.<ext>` for the mixed recording and `<name> (unmixed, 2 audio tracks).<ext>` for the recording as it
/// was written. `<name>` is the prefix and the date of the start.
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

    /// Path without extension for a recording started at `date`: `<directory>/<prefix><date>`
    func newBase(date: Date = Date()) -> String {
        return RecordingFileStore.basePath(directory: directory, prefix: prefix, date: date)
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

    /// What a temporary name is made of: `<base>.<marker>.<ending>`
    struct Leftover {
        let url: URL
        /// Path of the final file without its extension
        let base: String
        /// What an interrupted mix had written, as opposed to a recording
        let isMix: Bool
        let ending: String
    }

    /// The files in the folder that this app left under a temporary name: `<prefix>….recording.<ext>` and
    /// `<prefix>….mixing.<ext>`. A file that merely has such an ending is someone else's and is left alone. Only
    /// call this when no recording is running or being finished, in this or in another instance of the app: until
    /// then such a file is not a leftover.
    func leftovers() -> [Leftover] {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return files.sorted { $0.path < $1.path }.compactMap { url in
            let ending = url.pathExtension
            guard ["mp4", "mov"].contains(ending.lowercased()) else { return nil }
            let stem = url.deletingPathExtension()
            let marker = stem.pathExtension
            guard marker == RecordingFileStore.rawMarker || marker == RecordingFileStore.mixMarker else { return nil }
            let name = stem.deletingPathExtension().lastPathComponent
            guard !prefix.isEmpty, name.hasPrefix(prefix), name.count > prefix.count else { return nil }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return Leftover(url: url, base: stem.deletingPathExtension().path, isMix: marker == RecordingFileStore.mixMarker, ending: ending)
        }
    }

    // MARK: - Disk guard

    /// Before a recording starts: the folder is there (it is created when it is not) and its volume has room
    /// (`DiskSpace.startMinimum`). Throws what to tell the user. `free` is how the free space is found out.
    func prepareForRecording(free: (String) -> Int64? = DiskSpace.available) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { throw RecordingError("The output path is a file instead of a folder!") }
        } else {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw RecordingError("Unable to create output folder!")
            }
        }
        if let free = free(directory), !DiskSpace.canStart(free: free) {
            throw RecordingError(String(format: "Not enough free disk space: only %@ is left on the output volume, and at least %@ is needed to start a recording.", DiskSpace.formatted(free), DiskSpace.formatted(DiskSpace.startMinimum)))
        }
    }

    /// While a recording runs: `onLow` is called once, on the main thread, with the free space when the volume is
    /// nearly full (`DiskSpace.stopMinimum`), until the watch that is returned is cancelled. Main thread.
    func watchFreeSpace(onLow: @escaping (Int64) -> Void) -> DiskSpace.Watch {
        return DiskSpace.Watch(directory, onLow: onLow)
    }

    /// Before the audio mix: whether a second file as large as `url` fits next to it. True when that cannot be determined.
    static func hasRoomForCopy(of url: URL) -> Bool {
        return DiskSpace.hasRoomForCopy(of: url)
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
    /// Audio-only recordings: the system audio file, and the microphone file when there is one
    let systemAudioURL: URL?
    let micAudioURL: URL?

    /// `videoEnding` and `audioEnding` are the file extensions of the chosen formats; `exportsMP3` says that the
    /// audio is recorded as AAC and converted to MP3 afterwards.
    init(base: String, audioOnly: Bool, recordMic: Bool, systemAudio: Bool, remuxAudio: Bool, videoEnding: String, audioEnding: String, exportsMP3: Bool) {
        if audioOnly {
            let exported = exportsMP3 ? "mp3" : audioEnding
            mixURL = nil
            unmixedURL = nil
            if recordMic {
                let package = URL(fileURLWithPath: "\(base).qma")
                rawURL = package
                systemAudioURL = package.appendingPathComponent("sys.\(audioEnding)")
                micAudioURL = package.appendingPathComponent("mic.\(audioEnding)")
                finalURL = remuxAudio ? URL(fileURLWithPath: "\(base).\(exported)") : package
            } else {
                let file = URL(fileURLWithPath: "\(base).\(audioEnding)")
                rawURL = file
                systemAudioURL = file
                micAudioURL = nil
                finalURL = exportsMP3 ? URL(fileURLWithPath: "\(base).mp3") : file
            }
        } else {
            finalURL = URL(fileURLWithPath: "\(base).\(videoEnding)")
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
