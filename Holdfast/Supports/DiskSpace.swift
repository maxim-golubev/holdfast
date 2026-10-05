//
//  DiskSpace.swift
//  Holdfast
//

import Foundation

/// Free space on the volume a recording is written to. A recording is not started with less than `startMinimum`
/// and is stopped while it can still be closed properly when less than `stopMinimum` is left.
enum DiskSpace {
    static let startMinimum: Int64 = 2_000_000_000
    static let stopMinimum: Int64 = 500_000_000
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
    
    /// Whether a second file of `size` bytes fits with `stopMinimum` to spare
    static func hasRoom(forCopyOf size: Int64, free: Int64) -> Bool {
        return free > size + stopMinimum
    }
    
    static func formatted(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    /// Whether a second file as large as `url` (a file or a package) fits in `folder`, next to it unless given, with
    /// `stopMinimum` to spare. True when that cannot be determined.
    static func hasRoomForCopy(of url: URL, in folder: URL? = nil) -> Bool {
        guard let size = size(of: url),
              let free = available(at: (folder ?? url.deletingLastPathComponent()).path) else { return true }
        return hasRoom(forCopyOf: size, free: free)
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
