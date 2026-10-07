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

/// Whether a timestamp can be believed, judged against when its buffer reached the app on the host clock the
/// timestamps are on. Timestamps come from devices, and around a call they have been wrong: a process tap's buffers
/// were stamped 12 s in the future as a FaceTime call connected, 1100 s as it ended, and 4.77 s as another app
/// switched voice processing on. So:
/// - the process tap's device timestamps are not used at all: its buffers are stamped in its IOProc with the host
///   time at which they arrived (`SystemAudioTap`) and placed by their sample count (`SystemAudioPlacement.placeArrived`);
/// - ScreenCaptureKit's system audio and its frames keep their own time while it is within `ahead` after and `behind`
///   before their arrival; otherwise they go where their arrival puts them (`StreamStamps` for the audio, which
///   also tells a backlog from a clock that lags; a frame simply at its arrival time);
/// - the microphone's converter tells a backlog from a lagging clock and drops a backlog whose time was filled with
///   silence; given its arrival time instead, a backlog's stale audio would be spliced in at the present, chopped,
///   where silence belongs. So the microphone is restamped only when it is stamped after its arrival or
///   `microphoneBehind` before it, minutes, which is no backlog but a time from another clock.
enum ArrivalCheck {
    /// Seconds a buffer may be stamped after its arrival
    static let ahead: Double = 1
    /// Seconds a frame, or a buffer of ScreenCaptureKit's system audio, may be stamped before its arrival and still
    /// be taken at its own time
    static let behind: Double = 1
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
    static func verdict(pts: CMTime, arrival: CMTime, behind: Double) -> Verdict {
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

/// Buffers of one source that lie before the end of its track, one after another. They are one of two things. A
/// backlog: the source was held up and then hands over what piled up meanwhile, with the times the audio was
/// captured at, faster than real time. Their time was filled with silence while they were held up, so they are
/// dropped, and the buffers after them are at their own time again. Or a source whose timestamps lag the recording's
/// clock: its buffers keep arriving at real-time pace, all of them behind, and dropping them would leave the track
/// silent for good. The age of a buffer (when it arrived minus when its audio ends) tells them apart: it falls while
/// a backlog drains and holds steady for a lagging clock. The microphone's converter and ScreenCaptureKit's system
/// audio (`StreamStamps`) both decide with it.
struct LateRun {
    /// How far the age of late buffers may vary within `window` and still count as steady
    static let steadyRange: Double = 0.25
    /// How fast the age of late buffers may fall, in seconds per second of arrivals over the whole run, and still
    /// count as steady. A backlog drained at rate r makes it fall by r - 1: drained at 1.1 times real time, its age
    /// falls by only 0.2 s over two seconds, within `steadyRange`, but by 0.1 s every second all along.
    static let steadyFall: Double = 0.02

    /// How far the first buffer was behind the end of the track: the time already filled that a backlog covers
    let span: Double
    /// Seconds of arrivals over which the age of late buffers must hold steady before they are taken to lag
    let window: Double
    var buffers = 0
    /// Seconds of audio in the late buffers so far
    var audio: Double = 0
    private(set) var firstAge: Double?
    private(set) var lastAge: Double?
    /// Arrival and age of the late buffers of about the last `window` seconds of arrivals
    private var recent = [(arrival: Double, age: Double)]()
    /// Sums for the least-squares slope of age against arrival over the whole run, relative to its first buffer
    private var firstArrival: Double?
    private var count: Double = 0
    private var sumX: Double = 0, sumY: Double = 0, sumXX: Double = 0, sumXY: Double = 0

    init(span: Double, window: Double) {
        self.span = span
        self.window = window
    }

    mutating func note(arrival: Double, age: Double) {
        if firstAge == nil { firstAge = age }
        lastAge = age
        recent.append((arrival, age))
        while recent.count > 2 && recent[1].arrival <= arrival - window { recent.removeFirst() }
        let origin = firstArrival ?? arrival
        firstArrival = origin
        let x = arrival - origin
        let y = age - (firstAge ?? age)
        count += 1
        sumX += x
        sumY += y
        sumXX += x * x
        sumXY += x * y
    }

    /// How fast the age changed over the whole run, in seconds per second of arrivals; nil before the arrivals
    /// span any time
    var ageSlope: Double? {
        let spread = count * sumXX - sumX * sumX
        guard count >= 2, spread > 1e-9 else { return nil }
        return (count * sumXY - sumX * sumY) / spread
    }

    /// The buffers have arrived at real-time pace for `window` at least: their age within `steadyRange` over that
    /// window, and not falling over the whole run (`steadyFall`), as it does while a backlog drains
    var isSteady: Bool {
        guard let first = recent.first, let last = recent.last, last.arrival - first.arrival >= window - 0.001 else { return false }
        var low = Double.infinity
        var high = -Double.infinity
        for entry in recent {
            low = min(low, entry.age)
            high = max(high, entry.age)
        }
        guard high - low <= LateRun.steadyRange, let slope = ageSlope else { return false }
        return slope >= -LateRun.steadyFall
    }
}

/// Where a buffer of ScreenCaptureKit's system audio (the backup of the process tap, or the system audio itself
/// when the tap is not used) starts on the recording's clock. The stream's own timestamps are kept while they agree
/// with the buffers' arrival: they are smooth, where arrivals come in bursts. When they do not agree the stream is
/// never given up, in either direction:
/// - stamped more than `ArrivalCheck.ahead` after its arrival: the buffer ends when it arrived, and the difference
///   is kept as `offset` for the buffers after it, which stay as smooth as the stream stamped them;
/// - stamped more than `ArrivalCheck.behind` before its arrival, or before the end of what its track already holds:
///   a backlog, handed over late with the times its audio was captured at, or a clock that lags, whose buffers
///   keep arriving at real-time pace. `LateRun` tells them apart within `steadyWindow`. Until it has, and for a
///   backlog all along, a buffer that lies before the end of its track is left out (silence was written in its
///   place while it was held up) and one that does not is written at its own time. A backlog drains faster than
///   real time, so it ends by itself and the buffers after it are at their own time. The buffers of a lagging clock
///   end when they arrived from then on, like the ones stamped ahead.
/// The offset goes as soon as the stream's own timestamps agree with the arrival again.
struct StreamStamps {
    /// Seconds of arrivals at real-time pace after which late buffers are taken to come from a lagging clock
    static let steadyWindow: Double = 1.5
    /// Seconds of late audio left out before buffers whose arrival is not known are placed at the end of their track
    static let longestDrop: Double = 1

    enum Event: Equatable {
        /// A run begins: a buffer is stamped this many seconds after it arrived
        case ahead(Double)
        /// A run begins: buffers stamped this many seconds before their place keep arriving at real-time pace;
        /// `dropped` seconds of them were left out until that was clear
        case lagging(behind: Double, dropped: Double)
        /// The stream's timestamps agree with the arrival again, after this many buffers placed by their arrival
        case agreesAgain(buffers: Int)
        /// Late buffers were followed by one at its own time: a backlog, of which this much was left out
        case backlog(buffers: Int, seconds: Double, firstAge: Double?, lastAge: Double?)
    }

    /// Added to the stream's timestamps; zero while they agree with the buffers' arrival
    private(set) var offset = CMTime.zero
    /// Buffers placed by their arrival: in the run that is going on, the runs, and in all
    private(set) var run = 0
    private(set) var runs = 0
    private(set) var total = 0
    /// Buffers left out because silence had been written in their place, and the seconds of audio in them
    private(set) var lateBuffers = 0
    private(set) var lateSeconds: Double = 0
    /// The late buffers that are arriving now; its `buffers` and `audio` count the ones left out
    private var late: LateRun?

    private static func agrees(_ lead: Double) -> Bool {
        return lead <= ArrivalCheck.ahead && -lead <= ArrivalCheck.behind
    }

    private mutating func count() -> Bool {
        let begins = run == 0
        if begins { runs += 1 }
        run += 1
        total += 1
        return begins
    }

    /// Where a buffer the stream stamped `pts`, `duration` long, that arrived at `arrival` starts; nil when it is
    /// left out. `end` is where the audio in its track ends, on the same clock; nil while nothing can lie before it
    /// (before the recording has begun, or while it resumes). A buffer whose arrival is not known keeps its time,
    /// and after `longestDrop` of them were left out the next goes at `end`.
    mutating func start(_ pts: CMTime, duration: CMTime, arrival: CMTime, end: CMTime?) -> (start: CMTime?, events: [Event]) {
        guard pts.isValid else { return (pts, []) }
        var events = [Event]()
        var start = CMTimeAdd(pts, offset)
        // Stamped before its arrival by more than a buffer waits, with or without the offset
        var behind = false
        let lead = arrival.isValid ? CMTimeGetSeconds(CMTimeSubtract(pts, arrival)) : Double.nan
        if lead.isFinite {
            let shiftedLead = CMTimeGetSeconds(CMTimeSubtract(start, arrival))
            if StreamStamps.agrees(lead) {
                if run > 0 { events.append(.agreesAgain(buffers: run)) }
                offset = .zero
                run = 0
                start = pts
            } else if offset != .zero, StreamStamps.agrees(shiftedLead) {
                _ = count()
            } else if lead > ArrivalCheck.ahead || shiftedLead > ArrivalCheck.ahead {
                // Not its time, with or without the offset: it ends when it arrived
                start = ArrivalCheck.restamped(arrival: arrival, duration: duration)
                offset = CMTimeSubtract(start, pts)
                if count() { events.append(.ahead(lead)) }
            } else {
                behind = true
                // An offset that puts it further from its arrival than its own time does is of no use any more
                if offset != .zero, abs(shiftedLead) > abs(lead) {
                    offset = .zero
                    run = 0
                    start = pts
                }
            }
        }
        let seconds = CMTimeGetSeconds(duration)
        let length = seconds.isFinite && seconds > 0 ? seconds : 0.02
        let liesBefore = end.map { CMTimeAdd(start, duration.isValid && duration > .zero ? duration : .zero) <= $0 } ?? false
        guard behind || liesBefore else {
            // At its own time: the late ones before it, if any, were a backlog. Less than a quarter of a second
            // left out is a hiccup, not worth a line.
            if let found = late, found.audio >= 0.25 {
                events.append(.backlog(buffers: found.buffers, seconds: found.audio, firstAge: found.firstAge, lastAge: found.lastAge))
            }
            late = nil
            return (start, events)
        }
        var found = late ?? LateRun(span: end.map { CMTimeGetSeconds(CMTimeSubtract($0, start)) } ?? 0, window: StreamStamps.steadyWindow)
        var placed: CMTime?
        if lead.isFinite {
            found.note(arrival: CMTimeGetSeconds(arrival), age: CMTimeGetSeconds(CMTimeSubtract(arrival, start)) - length)
            if found.isSteady { placed = ArrivalCheck.restamped(arrival: arrival, duration: duration) }
        } else if liesBefore, found.audio + length > StreamStamps.longestDrop {
            placed = end
        }
        if var placed {
            // Never before the end of the track, or it would be late again and the stream left out for good
            if let end, placed < end { placed = end }
            late = nil
            let lag = CMTimeGetSeconds(CMTimeSubtract(placed, start))
            offset = CMTimeSubtract(placed, pts)
            if count() { events.append(.lagging(behind: lag, dropped: found.audio)) }
            return (placed, events)
        }
        if liesBefore {
            found.buffers += 1
            found.audio += length
            lateBuffers += 1
            lateSeconds += length
        }
        late = found
        return (liesBefore ? nil : start, events)
    }

    /// The recording was paused or resumed: the late buffers before it say nothing about the ones after it
    mutating func interrupted() {
        late = nil
    }
}

/// Where system audio goes on its track, which is counted from what was written and not read from the timestamps
enum SystemAudioPlacement {
    /// Where a buffer of ScreenCaptureKit's system audio that covers `pts` to `endPTS` goes when the audio written
    /// to its track so far ends at `end`: at that end. Nil when it must not be written: it lies before that end (silence was already written in its
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

    /// Whether the track, which ends at `end`, already holds more than `tolerance` seconds beyond the end of a
    /// buffer that ends at `endPTS`: the buffer's time is taken
    static func isTaken(_ endPTS: CMTime, end: CMTime, tolerance: Double) -> Bool {
        return CMTimeGetSeconds(CMTimeSubtract(end, endPTS)) > tolerance
    }

    /// Where a buffer of the process tap goes. `pts` to `endPTS` is when it arrived (it ends at the host time its
    /// IOProc read, less the pauses); `end` is where the audio written to its track ends, and `floor` where the
    /// recording begins. Buffers go back to back, by their sample count: at `end`, wherever that is within
    /// `tolerance` of the buffer's arrival. The arrival is used for two things only. A hole of more than
    /// `tolerance` in front of the buffer is real (the tap delivered nothing, or the writer did not take a buffer)
    /// and is filled first, as in `place`. And a buffer whose time is taken (`isTaken`) is not written a second time.
    ///
    /// That is the only buffer of the tap left out for its time, and no device clock can cause it. Its time is the
    /// host clock read in the IOProc, which only moves forward at the pace of real time; the track's end is the count
    /// of the samples written, tap audio and silence. The end passes a buffer by more than `tolerance` only when
    /// silence was written over the buffer's time before it reached the writer (the monitor fills a track that is 1.5 s
    /// behind the present, so the buffer waited that long between the IOProc and the sample queue) or when the tap
    /// delivered that much more audio than time has passed. Either way the track already holds that time. Nil also
    /// while the silence for a hole in front of the buffer cannot be written, and before the recording begins.
    static func placeArrived(from pts: CMTime, to endPTS: CMTime, end: CMTime?, floor: CMTime, tolerance: Double, fill: (CMTime) -> CMTime?) -> CMTime? {
        guard let end = end else { return endPTS > floor ? pts : nil }
        if isTaken(endPTS, end: end, tolerance: tolerance) { return nil }
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
