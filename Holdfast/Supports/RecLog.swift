//
//  RecLog.swift
//  Holdfast
//

import Foundation

/// Appends one line per event to ~/Library/Logs/Holdfast/recordings.log, so what happened to a recording's
/// tracks can be read afterwards. Also printed.
enum RecLog {
    private static let queue = DispatchQueue(label: "reclog")
    /// The log file, also for the "Open Recordings Log" button
    static let url: URL? = {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Holdfast", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("recordings.log")
    }()
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        print(message)
        queue.async {
            guard let url = url, let data = "\(stamp.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
