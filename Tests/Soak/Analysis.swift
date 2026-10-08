//
//  Analysis.swift
//  Reads the files the recording left and measures them: track lengths, where each marker and each frame's time
//  code is, and where the audio is digital silence.
//

import AVFoundation
import Foundation

func say(_ line: String = "") {
    print(line)
    fflush(stdout)
}

func ms(_ seconds: Double) -> String { String(format: "%+.1f ms", seconds * 1000) }

struct TrackInfo {
    let id: CMPersistentTrackID
    let type: AVMediaType
    let start: Double
    let duration: Double
    var end: Double { start + duration }
}

enum Analysis {
    static func tracks(of url: URL) async throws -> [TrackInfo] {
        let asset = AVURLAsset(url: url)
        var found = [TrackInfo]()
        for track in try await asset.load(.tracks) {
            let range = try await track.load(.timeRange)
            found.append(TrackInfo(id: track.trackID, type: track.mediaType, start: CMTimeGetSeconds(range.start), duration: CMTimeGetSeconds(range.duration)))
        }
        return found.sorted { $0.id < $1.id }
    }

    /// Stream durations as ffprobe reads them, as a second opinion; empty when ffprobe is not there
    static func ffprobe(_ url: URL) -> String {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-v", "error", "-show_entries", "stream=index,codec_type,codec_name,duration,nb_frames:format=duration", "-of", "compact=p=0:nk=0", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio

    private static let pcm: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
    ]

    /// Reads one audio track, from `start` for `duration` seconds (the whole track without them), as mono 48 kHz,
    /// handing on pieces with the time of their first sample
    static func readAudio(_ url: URL, track id: CMPersistentTrackID, start: Double? = nil, duration: Double? = nil, each: (Double, [Float]) -> Void) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks.first(where: { $0.trackID == id }) else { throw SoakError("no track \(id) in \(url.lastPathComponent)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        if let start = start, let duration = duration {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 48000), duration: CMTime(seconds: duration, preferredTimescale: 48000))
        }
        guard reader.startReading() else { throw reader.error ?? SoakError("cannot read \(url.lastPathComponent)") }
        var interleaved = [Float]()
        var more = true
        while more {
            autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { more = false; return }
                guard let block = buffer.dataBuffer else { return }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count >= 2 else { return }
                if interleaved.count < count { interleaved = [Float](repeating: 0, count: count) }
                _ = interleaved.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: $0.baseAddress!) }
                var mono = [Float](repeating: 0, count: count / 2)
                for i in 0..<(count / 2) { mono[i] = 0.5 * (interleaved[2 * i] + interleaved[2 * i + 1]) }
                each(CMTimeGetSeconds(buffer.presentationTimeStamp), mono)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? SoakError("reading \(url.lastPathComponent) stopped") }
    }

    /// RMS of every 10 ms of a whole audio track
    static func levels(_ url: URL, track id: CMPersistentTrackID) throws -> [Float] {
        var levels = [Float]()
        var sum: Float = 0
        var count = 0
        try readAudio(url, track: id) { _, samples in
            for value in samples {
                sum += value * value
                count += 1
                if count == 480 {
                    levels.append((sum / 480).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { levels.append((sum / Float(count)).squareRoot()) }
        return levels
    }

    struct Hit {
        /// Where the tone starts in the file
        let onset: Double
        let length: Double
        /// Strength of the tone against the level around it
        let contrast: Double
    }

    /// Finds the burst of `frequency` within `window` seconds of `expected`: where it starts (half its strength,
    /// in 2 ms windows every 0.5 ms) and how long it lasts. Nil when there is none.
    static func findTone(_ url: URL, track id: CMPersistentTrackID, frequency: Double, expected: Double, window: Double = 1.5) throws -> Hit? {
        let from = max(0, expected - window)
        var samples = [Float]()
        var first: Double?
        try readAudio(url, track: id, start: from, duration: 2 * window + Plan.burst) { time, piece in
            if first == nil { first = time }
            samples.append(contentsOf: piece)
        }
        guard let t0 = first, samples.count > 200 else { return nil }
        let size = 96, hop = 24
        let omega = 2 * Double.pi * frequency / 48000
        let cosine = (0..<size).map { Float(cos(omega * Double($0))) }
        let sine = (0..<size).map { Float(sin(omega * Double($0))) }
        var strength = [Float]()
        var index = 0
        while index + size <= samples.count {
            var re: Float = 0, im: Float = 0
            for k in 0..<size {
                re += samples[index + k] * cosine[k]
                im += samples[index + k] * sine[k]
            }
            strength.append((re * re + im * im).squareRoot())
            index += hop
        }
        guard let peak = strength.indices.max(by: { strength[$0] < strength[$1] }) else { return nil }
        let top = strength[peak]
        let sorted = strength.sorted()
        let floor = sorted[sorted.count / 2]
        guard top > 10 * max(floor, 1e-6) else { return nil }
        func center(_ w: Double) -> Double { t0 + (w * Double(hop) + Double(size) / 2) / 48000 }
        var rise = peak
        while rise > 0 && strength[rise - 1] >= top / 2 { rise -= 1 }
        var fall = peak
        while fall < strength.count - 1 && strength[fall + 1] >= top / 2 { fall += 1 }
        // Where the strength crosses half, between two windows
        func crossing(_ below: Int, _ above: Int) -> Double {
            let a = Double(strength[below]), b = Double(strength[above])
            let half = Double(top) / 2
            let f = b == a ? 0 : (half - a) / (b - a)
            return center(Double(below) + f * Double(above - below))
        }
        let onset = rise > 0 ? crossing(rise - 1, rise) : center(0)
        let end = fall < strength.count - 1 ? crossing(fall + 1, fall) : center(Double(fall))
        return Hit(onset: onset, length: end - onset, contrast: Double(top / max(floor, 1e-6)))
    }

    // MARK: - Video

    struct Frame {
        let time: Double
        /// The time code, nil when it does not read
        let number: Int?
    }

    static func frames(_ url: URL) throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw SoakError("no video in \(url.lastPathComponent)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SoakError("cannot read the video") }
        var found = [Frame]()
        var more = true
        while more {
          autoreleasepool {
            guard let buffer = output.copyNextSampleBuffer() else { more = false; return }
            let time = CMTimeGetSeconds(buffer.presentationTimeStamp)
            guard let pixels = buffer.imageBuffer else { return }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            var number: Int?
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let row = CVPixelBufferGetBytesPerRow(pixels)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                var bits = [Int]()
                for block in 0..<32 {
                    let x = (block % 8) * 8 + 4, y = (block / 8) * 9 + 4
                    let pixel = bytes + y * row + x * 4
                    let luma = (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
                    bits.append(luma > 127 ? 1 : 0)
                }
                if (0..<16).allSatisfy({ bits[$0] != bits[$0 + 16] }) {
                    number = (0..<16).reduce(0) { $0 | (bits[$1] << $1) }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            found.append(Frame(time: time, number: number))
          }
        }
        guard reader.status == .completed else { throw reader.error ?? SoakError("reading the video stopped") }
        return found.sorted { $0.time < $1.time }
    }
}

// MARK: - The checks

enum Checks {
    /// Track lengths against `expected` (seconds of output)
    static func durations(_ url: URL, expected: Double, label: String) async throws -> [TrackInfo] {
        let tracks = try await Analysis.tracks(of: url)
        let asset = AVURLAsset(url: url)
        let total = CMTimeGetSeconds(try await asset.load(.duration))
        say("  \(label): \(url.lastPathComponent)")
        say(String(format: "    file duration %.3f s (expected %.3f s, %@)", total, expected, ms(total - expected)))
        for track in tracks {
            let name = track.type == .video ? "video" : "audio"
            say(String(format: "    track %d %@: start %.3f s, length %.3f s, difference %@", track.id, name, track.start, track.duration, ms(track.duration - expected)))
        }
        let probe = Analysis.ffprobe(url)
        if !probe.isEmpty {
            say("    ffprobe:")
            for line in probe.split(separator: "\n") { say("      " + line) }
        }
        return tracks
    }

    /// Finds every marker of `markers` in the track; returns where each was against where it belongs
    static func markers(_ url: URL, track id: CMPersistentTrackID, _ markers: [Marker], timeline: OutputTimeline, until end: Double,
                        absent: (Marker) -> Bool, label: String, report: inout [String]) throws -> [(marker: Marker, offset: Double)] {
        var offsets = [(marker: Marker, offset: Double)]()
        var missing = [Int](), unexpected = [Int](), odd = [String]()
        for marker in markers {
            guard let out = timeline.output(marker.time), out + Plan.burst < end - 0.05 else {
                if let out = timeline.output(marker.time), out < end {
                    // Cut off at the end of the file: say so only
                    odd.append("marker \(marker.index) is at the end of the file")
                }
                continue
            }
            let hit = try autoreleasepool { try Analysis.findTone(url, track: id, frequency: marker.frequency, expected: out) }
            if absent(marker) {
                if hit != nil { unexpected.append(marker.index) }
                continue
            }
            guard let hit = hit else { missing.append(marker.index); continue }
            offsets.append((marker, hit.onset - out))
            if abs(hit.length - Plan.burst) > 0.02 { odd.append(String(format: "marker %d lasts %.3f s", marker.index, hit.length)) }
        }
        if !missing.isEmpty { report.append("\(label): markers not found: \(missing)") }
        if !unexpected.isEmpty { report.append("\(label): markers found where none should be: \(unexpected)") }
        for line in odd { report.append("\(label): \(line)") }
        return offsets
    }

    static func printOffsets(_ offsets: [(marker: Marker, offset: Double)], label: String, timeline: OutputTimeline) {
        guard let first = offsets.first, let last = offsets.last else {
            say("    \(label): no markers")
            return
        }
        let values = offsets.map(\.offset)
        let worst = offsets.max { abs($0.offset) < abs($1.offset) }!
        say(String(format: "    %@: %d markers, offset min %@ max %@ mean %@; largest %@ at marker %d (%.0f s); drift first to last %@",
                   label, offsets.count, ms(values.min()!), ms(values.max()!), ms(values.reduce(0, +) / Double(values.count)),
                   ms(worst.offset), worst.marker.index, timeline.output(worst.marker.time) ?? 0, ms(last.offset - first.offset)))
        let middle = offsets.count / 2
        let picks = Array(offsets.prefix(3)) + Array(offsets[max(0, middle - 1)..<min(offsets.count, middle + 2)]) + Array(offsets.suffix(3))
        let line = picks.map { String(format: "#%d @%.0fs %@", $0.marker.index, timeline.output($0.marker.time) ?? 0, ms($0.offset)) }.joined(separator: ", ")
        say("      start / middle / end: " + line)
    }

    /// Frames against their time code: offset of every new picture, gaps between frames, repeats
    static func video(_ url: URL, timeline: OutputTimeline, until stop: Double, cutOff: Bool = false, label: String, report: inout [String]) throws -> [(number: Int, offset: Double)] {
        let frames = try Analysis.frames(url)
        var offsets = [(number: Int, offset: Double)]()
        var unreadable = 0, repeats = 0, backwards = 0
        var largestGap = (gap: 0.0, at: 0.0)
        var gapInStatic = 0.0
        var last: Int?
        for (index, frame) in frames.enumerated() {
            if index > 0 {
                let gap = frame.time - frames[index - 1].time
                if gap > largestGap.gap { largestGap = (gap, frame.time) }
                let staticOut = (timeline.output(Plan.staticSlide.start) ?? 0, timeline.output(Plan.staticSlide.end) ?? 0)
                if frame.time > staticOut.0 + 1, frame.time < staticOut.1 { gapInStatic = max(gapInStatic, gap) }
            }
            guard let number = frame.number else { unreadable += 1; continue }
            if number == last { repeats += 1; continue }
            if let previous = last, number < previous { backwards += 1 }
            last = number
            guard let expected = timeline.output(VideoSchedule.time(of: number)) else { continue }
            offsets.append((number, frame.time - expected))
        }
        // Frames that should be there and are not: delivered while recording, not in the static slide
        var expectedNumbers = Set<Int>()
        var schedule = VideoSchedule()
        while true {
            let frame = schedule.next()
            if frame.arrival > stop { break }
            let paused = frame.arrival >= Plan.pause.start && frame.arrival < Plan.pause.end
            if !paused, frame.pts >= timeline.sessionStart { expectedNumbers.insert(frame.number) }
        }
        let seen = Set(offsets.map(\.number))
        let missing = expectedNumbers.subtracting(seen).sorted()
        // The last frames before a kill may not have reached the disk: count those apart
        let values = offsets.map(\.offset)
        let worst = offsets.max { abs($0.offset) < abs($1.offset) }
        say(String(format: "    video: %d frames, %d new pictures with a time code, %d repeated (monitor), %d unreadable, %d out of order",
                   frames.count, offsets.count, repeats, unreadable, backwards))
        if let worst = worst, let first = offsets.first, let lastOffset = offsets.last {
            say(String(format: "    video time code: offset min %@ max %@; largest %@ at frame %d (%.1f s); drift first to last %@",
                       ms(values.min()!), ms(values.max()!), ms(worst.offset), worst.number, VideoSchedule.time(of: worst.number), ms(lastOffset.offset - first.offset)))
        }
        say(String(format: "    video: largest gap between frames %.3f s (at %.1f s); during the static slide %.3f s", largestGap.gap, largestGap.at, gapInStatic))
        let lastFrame = frames.last.map { String(format: "%.3f s", $0.time) } ?? "none"
        say("    video: last frame at \(lastFrame), last time code \(last.map(String.init) ?? "none") (\(last.map { String(format: "%.1f s", VideoSchedule.time(of: $0)) } ?? "-") on the stream's clock)")
        if !missing.isEmpty {
            let lastTime = frames.last?.time ?? 0
            let tail = missing.filter { $0 > (seen.max() ?? 0) }
            // Within the last second of a file cut off by a kill, a frame whose reference was never written does not decode
            let atCut = missing.filter { $0 <= (seen.max() ?? 0) && cutOff && (timeline.output(VideoSchedule.time(of: $0)) ?? 0) > lastTime - 1 }
            let inside = missing.filter { $0 <= (seen.max() ?? 0) && !atCut.contains($0) }
            if !inside.isEmpty { report.append("\(label): \(inside.count) frames missing inside the file, first \(Array(inside.prefix(10)))") }
            if !atCut.isEmpty { say("    video: frames \(atCut) are missing within the last second before the cut") }
            if !tail.isEmpty { say("    video: \(tail.count) frames delivered after the last one in the file") }
        }
        if unreadable > 0 { report.append("\(label): \(unreadable) frames whose time code does not read") }
        if backwards > 0 { report.append("\(label): \(backwards) frames out of order") }
        return offsets
    }

    /// Runs of digital silence in a track against the holes that should be silent; every other 10 ms with sound
    /// `lag(t)` is how late the source's audio is at `t` (the microphone's drift, measured from its markers): its
    /// last sound before a hole ends that much after the hole begins
    /// The shortest hole that must show as digital silence. The levels are read in 10 ms windows and AAC spreads
    /// sound over up to a frame (21 ms) next to silence, so a hole of 30 ms, as the splice of the pause leaves in
    /// the microphone track, may not hold one silent window; one of 50 ms always does.
    static let shortestHole = 0.05

    static func silence(_ url: URL, track id: CMPersistentTrackID, expectedHoles: [(start: Double, end: Double)], lag: (Double) -> Double = { _ in 0 }, label: String, report: inout [String]) throws {
        let levels = try Analysis.levels(url, track: id)
        let silent: Float = 1e-5     // -100 dBFS
        let sound: Float = 0.003     // -50 dBFS
        var runs = [(start: Double, end: Double)]()
        var runStart: Int?
        for (index, level) in levels.enumerated() {
            if level < silent {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append((Double(start) * 0.01, Double(index) * 0.01))
                runStart = nil
            }
        }
        if let start = runStart { runs.append((Double(start) * 0.01, Double(levels.count) * 0.01)) }
        let quietWindows = levels.enumerated().filter { $0.element >= silent && $0.element < sound }.map { Double($0.offset) * 0.01 }
        say(String(format: "    %@: %.2f s scanned, %d runs of digital silence, %d windows of 10 ms between -100 and -50 dBFS", label, Double(levels.count) * 0.01, runs.count, quietWindows.count))
        var matched = Set<Int>()
        for hole in expectedHoles where hole.end - hole.start >= Checks.shortestHole {
            let overlapping = runs.indices.filter { runs[$0].end > hole.start - 0.05 && runs[$0].start < hole.end + 0.05 }
            guard !overlapping.isEmpty else {
                report.append(String(format: "%@: no silence where the microphone delivered nothing, %.3f-%.3f s", label, hole.start, hole.end))
                continue
            }
            overlapping.forEach { matched.insert($0) }
            let start = runs[overlapping.first!].start, end = runs[overlapping.last!].end
            let late = lag(hole.start)
            say(String(format: "      hole %9.3f-%9.3f s (%6.3f s), silence found %9.3f-%9.3f s (%6.3f s): starts %@ after the hole (%@ after the microphone's lag of %@ there), ends %@",
                       hole.start, hole.end, hole.end - hole.start, start, end, end - start, ms(start - hole.start), ms(start - hole.start - late), ms(late), ms(end - hole.end)))
            // 10 ms windows, and AAC spreads sound over up to a frame (21 ms) next to silence
            if abs(start - hole.start - late) > 0.035 || abs(end - hole.end) > 0.035 {
                report.append(String(format: "%@: silence %.3f-%.3f s does not match the hole %.3f-%.3f s", label, start, end, hole.start, hole.end))
            }
        }
        let unexpected = runs.indices.filter { !matched.contains($0) }
        for index in unexpected {
            let run = runs[index]
            say(String(format: "      UNEXPECTED digital silence %.3f-%.3f s (%.3f s)", run.start, run.end, run.end - run.start))
        }
        if !unexpected.isEmpty {
            report.append("\(label): \(unexpected.count) runs of unexpected digital silence")
        }
        // Quiet windows that are not at the edge of a silence: the track should be at the source's level there. At an
        // edge AAC spreads the sound over up to a frame (21 ms) into the silence, read in windows of 10 ms.
        let edges = runs.flatMap { [$0.start, $0.end] }
        let stray = quietWindows.filter { t in !edges.contains { abs($0 - t) <= 0.035 } }
        if !stray.isEmpty {
            say("      quiet windows away from any silence: \(stray.count), first at \(stray.prefix(5).map { String(format: "%.2f", $0) })")
            report.append("\(label): \(stray.count) windows of 10 ms below -50 dBFS away from any silence")
        }
    }
}
