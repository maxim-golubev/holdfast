//
//  RecordingLogic.swift
//  Holdfast
//

import CoreMedia
import Foundation

// The parts of the recording pipeline that decide something without touching the capture, the writer or the
// app's state. They take what they need as parameters, so `Tools/test.sh` can run them without the app.

/// Times on the writer's timeline, and how they are shown
enum Timeline {
    /// "07:05" up to an hour, "1:07:05" from then on.
    static func lengthText(_ interval: TimeInterval) -> String {
        let total = interval.isFinite ? max(0, Int(interval)) : 0
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    /// The time taken out of every track for the pauses so far, once the first buffer after a pause has arrived
    /// with the time `raw` on the buffers' clock. `last` is where the timeline ended before the pause and
    /// `current` the time taken out until now. The recording continues where it left off, and the offset never
    /// gets smaller.
    static func pauseOffset(resumingAt raw: CMTime, last: CMTime, current: CMTime) -> CMTime {
        let offset = CMTimeSubtract(raw, last)
        return offset > current ? offset : current
    }

    /// The latest end time of anything on the timeline: `end` when it is valid and later than `last`, else `last`.
    /// An end after `limit` (the present plus a second, when known) is left out: nothing recorded ends in the future,
    /// and one such end would otherwise stay the recording's length for good.
    static func latestEnd(_ end: CMTime?, after last: CMTime?, limit: CMTime? = nil) -> CMTime? {
        guard let end = end, end.isValid else { return last }
        if let limit = limit, limit.isValid, end > limit { return last }
        if let last = last, end <= last { return last }
        return end
    }
}

/// Whether a buffer's own timestamp can be believed, judged against when it reached the app on the host clock that
/// timestamps are on. Audio is never stamped after it arrived: a buffer stamped later than `ahead` after its arrival
/// carries a time from another clock or none at all (a process tap's buffer was once stamped 1100 s in the future as
/// a call ended) and is given its arrival time instead. One stamped long before it arrived is either the same or a
/// backlog with its true times. For system audio, placed by what was written, more than `behind` is the former. The
/// microphone's converter tells a backlog from a lagging clock and drops a backlog whose time was filled with
/// silence; given its arrival time instead, a backlog's stale audio would be spliced in at the present, chopped,
/// where silence belongs. So the microphone is restamped only when it is `microphoneBehind` old, minutes, which is no
/// backlog but a time from another clock.
enum ArrivalCheck {
    /// Seconds a buffer may be stamped after its arrival
    static let ahead: Double = 1
    /// Seconds a system audio buffer may be stamped before its arrival
    static let behind: Double = 30
    /// Seconds a microphone buffer may be stamped before its arrival
    static let microphoneBehind: Double = 300

    enum Verdict: Equatable {
        case trusted
        /// Stamped this many seconds after it arrived
        case ahead(Double)
        /// Stamped this many seconds before it arrived
        case behind(Double)
    }

    /// What a buffer starting at `pts` that arrived at `arrival` is worth, when it may be stamped up to `behind`
    /// seconds before it. Trusted when the arrival is not known.
    static func verdict(pts: CMTime, arrival: CMTime, behind: Double = ArrivalCheck.behind) -> Verdict {
        guard pts.isValid, arrival.isValid else { return .trusted }
        let offset = CMTimeGetSeconds(CMTimeSubtract(pts, arrival))
        guard offset.isFinite else { return .trusted }
        if offset > ahead { return .ahead(offset) }
        if -offset > behind { return .behind(-offset) }
        return .trusted
    }

    /// The start given to a buffer of `duration` whose timestamp is not trusted: it ends when it arrived
    static func restamped(arrival: CMTime, duration: CMTime) -> CMTime {
        guard duration.isValid, duration > .zero else { return arrival }
        return CMTimeSubtract(arrival, duration)
    }
}

/// Where system audio goes on its track, which is counted from what was written and not read from the timestamps
enum SystemAudioPlacement {
    /// Where a buffer that covers `pts` to `endPTS` goes when the system audio written so far ends at `end`: at
    /// that end. Nil when it must not be written: it lies before that end (silence was already written in its
    /// place), or the silence for a hole in front of it could not be written yet. A hole of more than
    /// `tolerance` seconds is filled first: `fill` writes silence up to the time it is given and returns where the
    /// audio ends afterwards. A buffer that overlaps the end is written whole.
    static func place(from pts: CMTime, to endPTS: CMTime, end: CMTime?, tolerance: Double, fill: (CMTime) -> CMTime?) -> CMTime? {
        guard let end = end else { return pts }
        if pts < end { return endPTS > end ? end : nil }
        guard CMTimeGetSeconds(CMTimeSubtract(pts, end)) > tolerance else { return end }
        guard let filled = fill(pts), CMTimeGetSeconds(CMTimeSubtract(pts, filled)) <= tolerance else { return nil }
        return filled
    }

    /// The silence that continues audio ending at `from` up to `time` at `scale` samples a second: where it
    /// starts (the next whole sample) and how many whole frames fit. No frames when `time` is not later.
    static func silence(from: CMTime, upTo time: CMTime, scale: CMTimeScale) -> (position: CMTime, frames: Int64) {
        let position = CMTimeConvertScale(from, timescale: scale, method: .roundTowardPositiveInfinity)
        let frames = CMTimeConvertScale(CMTimeSubtract(time, position), timescale: scale, method: .roundTowardNegativeInfinity).value
        return (position, frames)
    }
}

/// The stretches of a recording in which the process tap delivered audio: where real buffers of the tap went into
/// its track, on the file's timeline (seconds from the start of the file), as the writer recorded them while it
/// wrote (`TapSpanLog`). Anywhere else the tap's track holds silence written in place of a tap that delivered
/// nothing: it was dead, being rebuilt, or not built yet. Kept next to the recording (`RecordingFiles.tapSpansURL`)
/// so the mix and launch recovery can read it, and deleted when the final files are written.
///
/// The file is a line per change: `alive <seconds>` where a stretch begins, `dead <seconds>` where it ends. A stretch
/// without an end (the recording was killed while the tap delivered) lasts to the end of the file.
struct TapSpans: Equatable {
    struct Span: Equatable {
        var start: Double
        var end: Double
    }
    /// In order, not overlapping
    private(set) var spans: [Span]

    init(_ spans: [Span]) {
        self.spans = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    static func line(alive start: Double) -> String { String(format: "alive %.6f\n", start) }
    static func line(dead end: Double) -> String { String(format: "dead %.6f\n", end) }

    /// Reads what `TapSpanLog` wrote. Lines it does not understand are passed over.
    static func parse(_ text: String) -> TapSpans {
        var spans = [Span]()
        var open: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let value = Double(parts[1]), value.isFinite else { continue }
            switch parts[0] {
            case "alive":
                if let start = open { spans.append(Span(start: start, end: value)) }
                open = max(0, value)
            case "dead":
                if let start = open { spans.append(Span(start: start, end: value)) }
                open = nil
            default:
                continue
            }
        }
        if let start = open { spans.append(Span(start: start, end: .infinity)) }
        return TapSpans(spans)
    }

    /// The spans written next to a recording; nil when there is no such file (a recording without the tap, or one
    /// from before the spans were kept)
    static func read(_ url: URL) -> TapSpans? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Whether the tap delivered all the way from `start` to `end`
    func covers(_ start: Double, _ end: Double) -> Bool {
        let slack = 0.000_5
        return spans.contains { $0.start <= start + slack && $0.end >= end - slack }
    }

    /// Whether the tap delivered just after (`after`) or just before `time`
    func isAlive(at time: Double, after: Bool) -> Bool {
        let probe = 0.001
        return after ? covers(time, time + probe) : covers(time - probe, time)
    }

    /// Where a stretch begins or ends, within `range`
    func edges(in range: ClosedRange<Double>) -> [Double] {
        return spans.flatMap { [$0.start, $0.end] }.filter { $0.isFinite && range.contains($0) }
    }

    /// Seconds in which the tap delivered, up to `duration`
    func aliveSeconds(upTo duration: Double) -> Double {
        return spans.reduce(0) { $0 + max(0, min($1.end, duration) - $1.start) }
    }
}

/// Which of the two system audio tracks of a recording made with the process tap goes into the mix, stretch by
/// stretch: the tap's, or the backup's (ScreenCaptureKit's system audio, recorded alongside for the whole recording).
/// Never both at once, so nothing is heard twice.
///
/// The timeline is cut into windows of `window` seconds, and further at every edge of the tap's recorded spans
/// (`TapSpans`), so a switch falls where the tap stopped or came back to the sample, not at the next window. Each
/// piece:
/// - where the tap delivered real buffers (its span covers the piece) and they have signal: the tap;
/// - otherwise, where the backup has signal: the backup;
/// - otherwise neither has anything above `signal` (-70 dBFS): the source before it goes on, which holds nothing but
///   silence there. Not switching in silence keeps the switches to where they matter. Where the tap was dead its
///   track is silence, so that is always the backup, which holds what ScreenCaptureKit heard or silence.
/// So a FaceTime call, which only the tap hears, is the tap's; a stretch in which the tap was dead is the backup's;
/// and with both alive and hearing the same sound, the tap's alone.
///
/// Content is judged per window because what counts is whether there is any sound worth taking, not where a word
/// starts: 0.5 s gives a steady level and costs at most half a second of the other source when one is silent. The
/// switch itself is a linear crossfade of `crossfade` seconds (the two sources carry the same sound within a buffer of
/// each other, so a short fade hides the seam without a dip or a click). It lies on the side of the switch where both
/// sources are good: before the edge where the tap died, after the edge where it came back, centred otherwise. It
/// does not wait for a quiet moment: in a call there may be none for many seconds, and at the edge of an outage only
/// one source has the sound.
enum SystemAudioChoice {
    enum Source: String, Equatable {
        case tap, backup
    }

    struct Segment: Equatable {
        var start: Double
        var end: Double
        var source: Source
    }

    static let window = 0.5
    /// Levels are given as the RMS of every `block` seconds
    static let block = 0.01
    /// RMS above which a source has signal: -70 dBFS
    static let signal: Float = 0.000_316
    static let crossfade = 0.005
    /// Pieces shorter than this do not count as the tap's, even where it delivered: a few milliseconds of tap
    /// between two switches would only be two fades
    static let shortest = 0.01

    /// RMS of `levels` (one per `block`) over `start` to `end` seconds
    static func level(_ levels: [Float], from start: Double, to end: Double) -> Float {
        let first = max(0, Int((start / block).rounded(.down)))
        let last = min(levels.count, Int((end / block - 0.000_001).rounded(.up)))
        guard first < last else { return 0 }
        var sum: Float = 0
        for index in first..<last { sum += levels[index] * levels[index] }
        return (sum / Float(last - first)).squareRoot()
    }

    /// The stretches of `duration` seconds and which source each takes. `tap` and `backup` are the levels of the two
    /// tracks per `block`; `spans` where the tap delivered, nil when that was not recorded (then the tap counts as
    /// delivering wherever its track has audio, and content alone decides).
    static func plan(tap: [Float], backup: [Float], spans: TapSpans?, duration: Double) -> [Segment] {
        guard duration > 0 else { return [] }
        var cuts = Set<Double>()
        var t = window
        while t < duration {
            cuts.insert(t)
            t += window
        }
        if let spans { cuts.formUnion(spans.edges(in: 0...duration)) }
        let points = [0] + cuts.filter { $0 > 0 && $0 < duration }.sorted() + [duration]
        var segments = [Segment]()
        var previous: Source?
        for index in 0..<(points.count - 1) {
            let start = points[index], end = points[index + 1]
            guard end > start else { continue }
            // A sliver between an edge and a window's end or the end of the audio is no stretch of its own
            if end - start < 0.001, !segments.isEmpty {
                segments[segments.count - 1].end = end
                continue
            }
            let alive = end - start >= shortest && (spans?.covers(start, end) ?? true)
            // The backup is judged over the window the piece is in; the tap over the piece itself where its spans are
            // known (the rest of the window may be silence written in its place), else over the window too
            let windowStart = (start / window).rounded(.down) * window
            let windowEnd = min(duration, windowStart + window)
            let source: Source
            if !alive {
                source = .backup
            } else if level(tap, from: spans == nil ? windowStart : start, to: spans == nil ? windowEnd : end) > signal {
                source = .tap
            } else if level(backup, from: windowStart, to: windowEnd) > signal {
                source = .backup
            } else {
                source = previous ?? .tap
            }
            previous = source
            if let last = segments.last, last.source == source, abs(last.end - start) < 1e-9 {
                segments[segments.count - 1].end = end
            } else {
                segments.append(Segment(start: start, end: end, source: source))
            }
        }
        return segments
    }

    /// The gain of the tap's track over time for `segments` (the backup's is one minus it): one in the tap's
    /// stretches, zero in the backup's, a linear fade of `crossfade` at each switch, placed where both sources are
    /// good (see the type)
    static func tapGain(for segments: [Segment], spans: TapSpans?) -> GainCurve {
        guard let first = segments.first else { return GainCurve(points: [(0, 1)]) }
        var points: [(time: Double, gain: Float)] = [(0, first.source == .tap ? 1 : 0)]
        for index in segments.indices.dropFirst() {
            let before = segments[index - 1], after = segments[index]
            let edge = after.start
            var from = edge - crossfade / 2, to = edge + crossfade / 2
            if before.source == .tap, let spans, !spans.isAlive(at: edge, after: true) {
                (from, to) = (edge - crossfade, edge)
            } else if after.source == .tap, let spans, !spans.isAlive(at: edge, after: false) {
                (from, to) = (edge, edge + crossfade)
            }
            // Never beyond the middle of a neighbouring stretch
            from = max(from, (before.start + edge) / 2)
            to = min(to, (edge + after.end) / 2)
            points.append((from, before.source == .tap ? 1 : 0))
            points.append((to, after.source == .tap ? 1 : 0))
        }
        return GainCurve(points: points)
    }

    /// Seconds each source has in `segments`, and how often it switches, for the log
    static func summary(_ segments: [Segment]) -> String {
        let tap = segments.filter { $0.source == .tap }.reduce(0) { $0 + $1.end - $1.start }
        let backup = segments.filter { $0.source == .backup }.reduce(0) { $0 + $1.end - $1.start }
        let stretches = segments.filter { $0.source == .backup }.count
        return String(format: "%.1f s from the process tap, %.1f s from the backup in %d %@", tap, backup, stretches, stretches == 1 ? "stretch" : "stretches")
    }
}

/// A gain that changes linearly between points in time and stays at the last point's value after it
struct GainCurve {
    /// In order of time
    let points: [(time: Double, gain: Float)]

    func value(at time: Double) -> Float {
        guard let first = points.first else { return 1 }
        if time <= first.time { return first.gain }
        for index in points.indices.dropFirst() {
            let a = points[index - 1], b = points[index]
            if time <= b.time {
                guard b.time > a.time else { return b.gain }
                return a.gain + (b.gain - a.gain) * Float((time - a.time) / (b.time - a.time))
            }
        }
        return points[points.count - 1].gain
    }

    /// The gains of `count` frames from `frame` on at `rate` frames a second. `cursor` remembers where the last call
    /// was in the points, so a curve read from start to end costs one pass.
    func values(from frame: Int64, count: Int, rate: Double, cursor: inout Int, into gains: inout [Float]) {
        if gains.count < count { gains = [Float](repeating: 0, count: count) }
        for offset in 0..<count {
            let time = Double(frame + Int64(offset)) / rate
            while cursor + 1 < points.count && points[cursor + 1].time <= time { cursor += 1 }
            if cursor + 1 < points.count, time >= points[cursor].time {
                let a = points[cursor], b = points[cursor + 1]
                gains[offset] = b.time > a.time ? a.gain + (b.gain - a.gain) * Float((time - a.time) / (b.time - a.time)) : b.gain
            } else if let first = points.first, time < first.time {
                gains[offset] = first.gain
            } else {
                gains[offset] = points.last?.gain ?? 1
            }
        }
    }
}
