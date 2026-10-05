//
//  DiskSpace.swift
//  QuickRecorder
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
    
    /// Whether a second file as large as `url` fits next to it with `stopMinimum` to spare. True when that cannot be determined.
    static func hasRoomForCopy(of url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize,
              let free = available(at: url.deletingLastPathComponent().path) else { return true }
        return hasRoom(forCopyOf: Int64(size), free: free)
    }
    
    /// Checks the volume of `path` every 5 seconds and calls `onLow` once, on the main thread, when less than
    /// `stopMinimum` is free, until it is cancelled. Main thread only. A recording has its own.
    final class Watch {
        private var timer: Timer?

        init(_ path: String, onLow: @escaping (Int64) -> Void) {
            let poll = Timer(timeInterval: DiskSpace.interval, repeats: true) { [weak self] _ in
                guard let free = DiskSpace.available(at: path), DiskSpace.mustStop(free: free) else { return }
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
