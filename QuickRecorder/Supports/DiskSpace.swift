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
    private static var timer: Timer?
    
    /// Bytes that can be written right now, without counting on the system purging anything. Nil when it cannot be determined.
    static func available(at path: String) -> Int64? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }
    
    static func formatted(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    /// Whether a second file as large as `url` fits next to it with `stopMinimum` to spare. True when that cannot be determined.
    static func hasRoomForCopy(of url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize,
              let free = available(at: url.deletingLastPathComponent().path) else { return true }
        return free > Int64(size) + stopMinimum
    }
    
    /// Checks the volume of `path` every 5 seconds and calls `onLow` once, on the main thread, when less than
    /// `stopMinimum` is free. Replaces an earlier monitor. Main thread only, like `stopMonitoring`.
    static func startMonitoring(_ path: String, onLow: @escaping (Int64) -> Void) {
        stopMonitoring()
        let poll = Timer(timeInterval: interval, repeats: true) { _ in
            guard let free = available(at: path), free < stopMinimum else { return }
            stopMonitoring()
            onLow(free)
        }
        poll.tolerance = 1
        // .common, because .default does not run while a menu is open
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }
    
    static func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}
