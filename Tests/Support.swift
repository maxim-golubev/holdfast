//
//  Support.swift
//  Tests of the recording pipeline's pure logic. Run with Tools/test.sh.
//

import AVFoundation
import Foundation

/// The app's log, replaced here so that the tests do not write to ~/Library/Logs
enum RecLog {
    static var lines = [String]()
    static func write(_ message: String) { lines.append(message) }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Suite {
    static var filter: String?
    static var verbose = false
    static var passed = 0
    static var failed = [String]()
    /// What went wrong in the test that is running
    static var problems = [String]()
    /// The terminal: standard output itself is sent to a file while the tests run, because the app code prints
    static var terminal = FileHandle.standardOutput
    static let workFolder = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory()).appendingPathComponent("QuickRecorderTests-\(UUID().uuidString)", isDirectory: true)

    static func say(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) { terminal.write(data) }
    }

    static func captureOutput(in log: String) {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0, freopen(log, "w", stdout) != nil else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        terminal = FileHandle(fileDescriptor: saved)
    }

    /// An empty folder for one test's files, removed at the end of the run
    static func folder(_ name: String) throws -> URL {
        let url = workFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func finish() -> Never {
        try? FileManager.default.removeItem(at: workFolder)
        if passed + failed.count == 0 {
            say("NO TESTS MATCHED" + (filter.map { ": no test name contains \"\($0)\"" } ?? ""))
            exit(1)
        }
        if failed.isEmpty {
            say("TESTS PASSED: \(passed) tests")
            exit(0)
        }
        say("TESTS FAILED: \(failed.count) of \(passed + failed.count) tests: " + failed.joined(separator: ", "))
        exit(1)
    }
}

func test(_ name: String, _ body: () async throws -> Void) async {
    if let filter = Suite.filter, !name.localizedCaseInsensitiveContains(filter) { return }
    Suite.problems = []
    RecLog.lines = []
    print("--- \(name)")
    let started = Date()
    do {
        try await body()
    } catch {
        Suite.problems.append("threw: \(error)")
    }
    let time = String(format: "%.2f s", Date().timeIntervalSince(started))
    if Suite.problems.isEmpty {
        Suite.passed += 1
        Suite.say("ok    \(name) (\(time))")
    } else {
        Suite.failed.append(name)
        Suite.say("FAIL  \(name) (\(time))")
        for problem in Suite.problems { Suite.say("        \(problem)") }
    }
}

func expect(_ condition: Bool, _ what: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    if !condition { Suite.problems.append("\(file):\(line): \(what())") }
}

func expectEqual<T: Equatable>(_ got: T, _ wanted: T, _ what: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    if got != wanted { Suite.problems.append("\(file):\(line): \(what()): got \(got), expected \(wanted)") }
}

func expectClose(_ got: Double, _ wanted: Double, within tolerance: Double, _ what: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    if !(abs(got - wanted) <= tolerance) { Suite.problems.append("\(file):\(line): \(what()): got \(got), expected \(wanted) ± \(tolerance)") }
}

/// Fails the test unless `body` throws; returns what the error says
@discardableResult
func expectThrows(_ what: String, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void) async -> String {
    do {
        try await body()
        Suite.problems.append("\(file):\(line): \(what): nothing was thrown")
        return ""
    } catch {
        return error.localizedDescription
    }
}

func require<T>(_ value: T?, _ what: String) throws -> T {
    guard let value = value else { throw TestError("missing: \(what)") }
    return value
}

/// A time in whole nanoseconds, like the timestamps of the capture
func time(_ seconds: Double) -> CMTime {
    return CMTime(value: CMTimeValue((seconds * 1_000_000_000).rounded()), timescale: 1_000_000_000)
}

/// A time in samples at 48 kHz, the scale of the microphone track
func samples(_ count: Int64) -> CMTime {
    return CMTime(value: count, timescale: 48000)
}

// MARK: - Audio

/// A tone as a device would deliver it: 32 bit float, one buffer per channel. Amplitude 0 is digital silence.
func audioBuffer(rate: Double, channels: UInt32 = 1, frames: Int, at pts: CMTime, amplitude: Float = 0.5) throws -> CMSampleBuffer {
    let format = try require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels), "format")
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), "pcm buffer")
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = try require(pcm.floatChannelData, "float data")
    for channel in 0..<Int(channels) {
        for frame in 0..<frames {
            data[channel][frame] = amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / rate))
        }
    }
    return try require(AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: pts), "sample buffer")
}

/// Largest magnitude in a buffer of 32 bit float samples
func peak(of buffer: CMSampleBuffer) -> Float {
    var loudest: Float = 0
    try? buffer.withAudioBufferList { list, _ in
        for part in list {
            guard let data = part.mData else { continue }
            let values = data.bindMemory(to: Float.self, capacity: Int(part.mDataByteSize) / MemoryLayout<Float>.size)
            for index in 0..<Int(part.mDataByteSize) / MemoryLayout<Float>.size { loudest = max(loudest, abs(values[index])) }
        }
    }
    return loudest
}

/// Stands in for the writer's audio input: takes what it is given, back to back, and notes where each piece claims to be
final class Track {
    struct Piece {
        let pts: CMTime
        let frames: Int64
        let peak: Float
    }
    var pieces = [Piece]()
    /// False while the "writer" is not ready
    var accepts = true
    var refused = 0
    /// Whether every piece started exactly where the one before it ended, which is how the writer plays them
    var contiguous = true
    var frames: Int64 { pieces.reduce(0) { $0 + $1.frames } }
    var silentFrames: Int64 { pieces.reduce(0) { $0 + ($1.peak == 0 ? $1.frames : 0) } }
    var start: CMTime? { pieces.first?.pts }
    var end: CMTime? {
        guard let last = pieces.last else { return nil }
        return CMTimeAdd(last.pts, CMTime(value: last.frames, timescale: 48000))
    }

    func append(_ buffer: CMSampleBuffer) -> Bool {
        guard accepts else { refused += 1; return false }
        let pts = buffer.presentationTimeStamp
        if let end = end, pts != end { contiguous = false }
        pieces.append(Piece(pts: pts, frames: Int64(buffer.numSamples), peak: peak(of: buffer)))
        return true
    }
}
