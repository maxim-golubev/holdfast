//
//  DiskSpace.swift
//  Holdfast
//

import Foundation
import Synchronization

/// Free space on the volume a recording is written to. A recording is not started with less than `startMinimum`
/// and is stopped while it can still be closed properly when less than `stopMinimum` is left. A second copy of a
/// recording (its mix, an MP3) is written only when it leaves `stopMinimum`, and `startMinimum` while another
/// recording is starting or running: that one passed its start check before the copy took its space, and would
/// otherwise be stopped by it in the middle of a meeting.
enum DiskSpace {
    static let startMinimum: Int64 = 2_000_000_000
    static let stopMinimum: Int64 = 500_000_000

    /// The recorders that have a recording starting or running. Kept here, behind a lock, because the copies are
    /// checked off the main thread, where the recorder's own state cannot be read.
    private static let recorders = Mutex(Set<ObjectIdentifier>())

    /// `recorder` has a recording starting or running, or no longer
    static func setRecording(_ runs: Bool, for recorder: ObjectIdentifier) {
        recorders.withLock { if runs { $0.insert(recorder) } else { $0.remove(recorder) } }
    }

    /// Whether a recording is starting or running
    static var isRecording: Bool { recorders.withLock { !$0.isEmpty } }

    /// What a second copy of a recording must leave free
    static func copyReserve(recording: Bool) -> Int64 {
        return recording ? startMinimum : stopMinimum
    }
    private static let interval: TimeInterval = 5

    /// Bytes available for a recording, counting the space the system frees on demand (purgeable space: local
    /// snapshots, caches), as Finder does. Counting only what is free right now would refuse or stop recordings
    /// that fit. Volumes that do not report this figure report zero for it, so the larger of the two is used.
    /// Nil when neither can be determined.
    static func available(at path: String) -> Int64? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        return usable(important: values.volumeAvailableCapacityForImportantUsage, free: values.volumeAvailableCapacity.map { Int64($0) })
    }

    /// The larger of the space counting what the system frees on demand and the space free right now
    static func usable(important: Int64?, free: Int64?) -> Int64? {
        guard let important = important else { return free }
        return max(important, free ?? 0)
    }

    /// A recording is not started with less than `startMinimum` free
    static func canStart(free: Int64) -> Bool {
        return free >= startMinimum
    }

    /// A running recording is stopped when less than `stopMinimum` is free
    static func mustStop(free: Int64) -> Bool {
        return free < stopMinimum
    }

    /// Whether a second file of `size` bytes fits with `reserve` to spare
    static func hasRoom(forCopyOf size: Int64, free: Int64, reserve: Int64 = stopMinimum) -> Bool {
        return free > size + reserve
    }

    static func formatted(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Whether a second file as large as `url` (a file or a package) fits in `folder`, next to it unless given, with
    /// `copyReserve` to spare: more while a recording is starting or running (`recording`), which is taken to be on
    /// the same volume. True when that cannot be determined. `free` is how the free space is found out.
    static func hasRoomForCopy(of url: URL, in folder: URL? = nil, recording: Bool = DiskSpace.isRecording,
                               free: (String) -> Int64? = DiskSpace.available) -> Bool {
        guard let size = size(of: url),
              let free = free((folder ?? url.deletingLastPathComponent()).path) else { return true }
        return hasRoom(forCopyOf: size, free: free, reserve: copyReserve(recording: recording))
    }

    /// What to say when there is no room for a copy: "Not enough free disk space to `purpose`.", and why when the
    /// space that is there is kept for a recording
    static func noRoom(to purpose: String, recording: Bool = DiskSpace.isRecording) -> String {
        let text = "Not enough free disk space to \(purpose)."
        guard recording else { return text }
        return text + " " + String(format: "What is left is kept for the recording that is running, which is stopped when less than %@ is free.", formatted(stopMinimum))
    }

    /// Bytes in the file at `url`, or in all files inside it when it is a folder (a .qma package). Nil when it is not there.
    static func size(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else { return values.fileSize.map { Int64($0) } }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// A recording's file as it is open, wherever its folder goes: whether it was deleted, and where it is now.
    /// Holds a descriptor for events only (`O_EVTONLY`), which does not keep its volume from being ejected.
    final class OpenFile {
        private let descriptor: Int32

        /// Nil when `url` cannot be opened
        init?(_ url: URL) {
            descriptor = open(url.path, O_RDONLY | O_EVTONLY)
            guard descriptor >= 0 else { return nil }
        }

        deinit { close(descriptor) }

        /// Its folder now: moving or renaming the folder or the file does not lose it. Nil once the file is deleted.
        var folder: String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard !isDeleted, fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
            return (String(cString: buffer) as NSString).deletingLastPathComponent
        }

        /// Whether the file has no name left: it was deleted, or its folder was, while it was open. Its data goes
        /// when it is closed.
        var isDeleted: Bool {
            var info = stat()
            return fstat(descriptor, &info) == 0 && info.st_nlink == 0
        }
    }

    /// Checks the volume of a recording every 5 seconds and calls `onLow` once, on the main thread, when less than
    /// `stopMinimum` is free, until it is cancelled; `onDeleted` once when `file` is deleted. The volume is the
    /// one `file` is on now, `folder` when it cannot be opened. Main thread only. A recording has its own.
    final class Watch {
        private var timer: Timer?

        init(file: URL, folder: String, onLow: @escaping (Int64) -> Void, onDeleted: @escaping () -> Void) {
            let opened = OpenFile(file)
            if opened == nil { RecLog.write("The recording's file cannot be watched: \(file.path)") }
            var unknownLogged = false
            let poll = Timer(timeInterval: DiskSpace.interval, repeats: true) { [weak self] _ in
                // A file that was replaced, not deleted, is still there under its name
                if let opened = opened, opened.isDeleted, !FileManager.default.fileExists(atPath: file.path) {
                    self?.cancel()
                    onDeleted()
                    return
                }
                guard let free = DiskSpace.available(at: opened?.folder ?? folder) else {
                    if !unknownLogged { RecLog.write("The free disk space of the recording cannot be determined") }
                    unknownLogged = true
                    return
                }
                guard DiskSpace.mustStop(free: free) else { return }
                self?.cancel()
                onLow(free)
            }
            poll.tolerance = 1
            // .common, because .default does not run while a menu is open
            RunLoop.main.add(poll, forMode: .common)
            timer = poll
        }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }
    }
}
