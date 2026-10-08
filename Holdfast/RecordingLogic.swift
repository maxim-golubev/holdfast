//
//  RecordingLogic.swift
//  Holdfast
//

import Accelerate
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
    /// behind the present, so the buffer waited that long between the IOProc and the sample queue). The tap's device
    /// delivering a little more or less audio than time passes, its clock not being the host clock, does not get
    /// that far: `TapDrift` takes it up a sample at a time. Nil also while the silence for a hole in front of the
    /// buffer cannot be written, and before the recording begins.
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

/// Keeps the tap's track on the host clock while the tap's device runs on a clock of its own. The tap's buffers go
/// back to back by their sample count (`SystemAudioPlacement.placeArrived`), and the count follows the crystal of the
/// device that clocks the tap's aggregate device, not the host clock the rest of the recording is on. A device 50
/// parts in a million slow delivers 0.1 s too little in 33 minutes. Left alone, the track would run early until the
/// tolerance made it a hole of 0.1 s of silence in the middle of speech (and, in the mix, a stretch taken from the
/// backup that repeats what was just heard); a fast device would have one buffer in fifty dropped from then on.
///
/// So the difference between where a buffer arrived and where it goes is smoothed over `window` seconds (single
/// arrivals jitter by milliseconds), and once that is more than `begins` the track is brought back a frame at a
/// time: one frame added to, or taken out of, a buffer every `spacing` seconds of audio, until less than `ends` is
/// left. One frame in 4,800 follows a clock up to about 200 parts in a million off, more than any real device, and
/// is not heard: the frame goes where the samples around it differ least (`MovieWriter.stretched`). What the
/// smoothing cannot follow, a real hole, is still filled with silence by `placeArrived`.
struct TapDrift {
    /// Seconds the track may be from the arrivals, smoothed, before frames are added or taken out, and where that ends
    static let begins = 0.010
    static let ends = 0.002
    /// Seconds of audio the difference is smoothed over
    static let window = 2.0
    /// Seconds of audio between two frames added or taken out
    static let spacing = 0.1

    /// How far behind its arrival the tap's audio goes into the track, smoothed, in seconds: positive when the
    /// track is behind (the device delivers less audio than time passes), negative when it is ahead
    private(set) var behind = 0.0
    private(set) var isCorrecting = false
    private var sinceFrame = 0.0
    /// Frames added and taken out so far, the runs of them, and the seconds of the tap's audio they were for
    private(set) var added = 0
    private(set) var removed = 0
    private(set) var runs = 0
    private(set) var seconds = 0.0

    /// A buffer `duration` seconds long goes at the end of its track, `offset` seconds before where it arrived
    /// (negative: after). Returns the frames to add to it: 1, -1 to take one out, or 0. `applied` says it was done.
    mutating func next(offset: Double, duration: Double) -> Int {
        guard offset.isFinite, duration.isFinite, duration > 0 else { return 0 }
        seconds += duration
        behind += (offset - behind) * min(1, duration / TapDrift.window)
        if !isCorrecting, abs(behind) > TapDrift.begins {
            isCorrecting = true
            runs += 1
            sinceFrame = TapDrift.spacing
        } else if isCorrecting, abs(behind) < TapDrift.ends {
            isCorrecting = false
        }
        guard isCorrecting else { return 0 }
        sinceFrame += duration
        // Less a microsecond: buffers of exactly `spacing` must not miss it by the rounding of their length
        guard sinceFrame >= TapDrift.spacing - 0.000_001 else { return 0 }
        return behind > 0 ? 1 : -1
    }

    /// `frames` (1 or -1) were added to a buffer, each `frame` seconds long
    mutating func applied(_ frames: Int, frame: Double) {
        sinceFrame = 0
        behind -= Double(frames) * frame
        if frames > 0 { added += frames } else { removed -= frames }
    }

    /// Silence was written up to the buffer's arrival, or the track begins: the track is where the arrivals are
    mutating func restart() {
        behind = 0
        isCorrecting = false
        sinceFrame = 0
    }

    /// How much less (positive) or more audio than time passed the tap delivered, in parts per million: the frames
    /// added and taken out, and what the track is still off by, against the audio they were for. Nil before any audio.
    /// A figure for the log: silence written into the track in between starts the measure of what is left anew.
    var partsPerMillion: Double? {
        guard seconds > 0 else { return nil }
        return (Double(added - removed) / 48000 + behind) / seconds * 1_000_000
    }
}

/// Tells, while a recording runs, a process tap that runs and hears nothing from one that has nothing to hear. A tap
/// built by a process without the System Audio Recording grant delivers buffers at its usual pace, every sample an
/// exact zero, and nothing in Core Audio says so; a tap that is merely idle delivers the same while nothing plays.
/// The other sources decide: the tap is deaf when its track has held exact zeros for `zeroSeconds` and the backup
/// (ScreenCaptureKit's system audio) or the call tap had a sample above `level` in that time. Their signal must lie
/// more than `inside` from both ends of the zeros: the tracks hold the same sound up to a quarter of a second apart,
/// so a sound that begins or ends is in one track a moment before it is in the other, and that is not a deaf tap.
///
/// A deaf tap is rebuilt at once (`rebuild`), and the comparison goes on with the new one. After `quickRebuilds`
/// rebuilds that changed nothing (no sample other than zero in between) it is the grant that is missing, or
/// something a rebuild does not cure: the user is told once (`notice`) and the tap is rebuilt only every `backoff`
/// seconds from then on. The backup and the call tap record meanwhile. The first sample that is not zero ends all
/// of it (`hears`, when a rebuild came before).
///
/// Times are seconds on the recording's timeline, of audio as it was written to the tracks. Pure: the writer feeds
/// it on the sample queue with the peak of each buffer it wrote, nothing here runs on the IO thread.
struct SilentTap: Equatable {
    /// How long the tap's track must hold exact zeros
    static let zeroSeconds = 3.0
    /// How far from the ends of those zeros the other sources' signal must be
    static let inside = 0.5
    /// A sample above this in the backup or the call tap is signal: -60 dBFS
    static let level: Float = 0.001
    /// Rebuilds at once before backing off
    static let quickRebuilds = 2
    /// Seconds between rebuilds after that
    static let backoff = 60.0

    enum Action: Equatable {
        case none
        /// Rebuild the tap now; `attempt` counts the rebuilds since it last heard anything, this one included
        case rebuild(attempt: Int)
        /// `quickRebuilds` rebuilds changed nothing: tell the user, once
        case notice
        /// The tap delivers sound again after it was rebuilt for delivering none
        case hears
    }

    /// Where the exact zeros in the tap's track began and where they end now; nil while its last audio was not zeros
    private(set) var zerosSince: Double?
    private var zerosEnd = 0.0
    /// The last stretch in which another source had signal, and the earliest time in the tap's zeros, `inside`
    /// from their beginning, at which one had
    private var signal: (start: Double, end: Double)?
    private var signalAt: Double?
    /// Rebuilds since the tap last delivered a sample that was not zero, and where the last one was
    private(set) var rebuilds = 0
    private var lastRebuild: Double?
    private(set) var noticed = false

    static func == (a: SilentTap, b: SilentTap) -> Bool {
        return a.zerosSince == b.zerosSince && a.zerosEnd == b.zerosEnd && a.signal?.start == b.signal?.start && a.signal?.end == b.signal?.end
            && a.signalAt == b.signalAt && a.rebuilds == b.rebuilds && a.lastRebuild == b.lastRebuild && a.noticed == b.noticed
    }

    /// Audio the tap delivered went into its track from `start` to `end`; `peak` is its largest sample
    mutating func tap(from start: Double, to end: Double, peak: Float) -> Action {
        guard peak == 0 else {
            zerosSince = nil
            signalAt = nil
            let rebuilt = rebuilds > 0
            rebuilds = 0
            lastRebuild = nil
            return rebuilt ? .hears : .none
        }
        if zerosSince == nil {
            zerosSince = start
            signalAt = nil
            // The other tracks may already hold this time
            if let signal, signal.end >= start + SilentTap.inside { signalAt = max(signal.start, start + SilentTap.inside) }
        }
        zerosEnd = max(zerosEnd, end)
        return judge()
    }

    /// Audio of the backup or of the call tap went into its track from `start` to `end`
    mutating func other(from start: Double, to end: Double, peak: Float) -> Action {
        guard peak > SilentTap.level, end > start else { return .none }
        if let known = signal, start >= known.start, start <= known.end + 0.1 {
            signal = (known.start, max(known.end, end))
        } else {
            signal = (start, end)
        }
        if let since = zerosSince, signalAt == nil, end >= since + SilentTap.inside { signalAt = max(start, since + SilentTap.inside) }
        return judge()
    }

    /// Silence was written into the tap's track in its place (it delivered nothing, which its source repairs), or
    /// the recording was paused: the zeros before it are not continued by the ones after it
    mutating func tapInterrupted() {
        zerosSince = nil
        signalAt = nil
    }

    private mutating func judge() -> Action {
        guard let since = zerosSince, let signalAt, zerosEnd - since >= SilentTap.zeroSeconds, signalAt <= zerosEnd - SilentTap.inside else { return .none }
        if rebuilds >= SilentTap.quickRebuilds {
            if !noticed {
                noticed = true
                return .notice
            }
            guard let last = lastRebuild, zerosEnd - last >= SilentTap.backoff else { return .none }
        }
        rebuilds += 1
        lastRebuild = zerosEnd
        // The next tap is judged by what it delivers
        zerosSince = nil
        self.signalAt = nil
        return .rebuild(attempt: rebuilds)
    }
}

/// What a recording knows about the call tap, the second tap that records only what `avconferenced` plays
enum CallAudioState: Equatable {
    /// Nothing looks for a call (no call tap source runs): the recording cannot tell whether one is on
    case unknown
    /// No call: `avconferenced` has no audio object, and there is no call tap
    case idle
    /// A call may be playing: `avconferenced` has an audio object, and the call tap is built for it
    case active
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
/// The tap is the source wherever its recorded spans (`TapSpans`) say it delivered, whatever it delivered: a tap
/// that is alive is not judged by its sound. (Up to 2026-10-07 each half second went to whichever source had sound
/// in it; a 45 s recording whose tap was alive and right throughout came out with 11.8 s from the backup in four
/// stretches, each switch doubling or cutting a sound because the two tracks were 52 ms apart.) The backup is the
/// source
/// - where the tap was not alive: its track holds silence written in its place there, and past the end of the tap's
///   track in a recording that was never closed (less than `tail` at the very start or end of the recording does
///   not count: the two tracks never begin and end on the same sample);
/// - in one case where it was: `silentRun` seconds or more of digital silence in the tap's track while the backup has
///   signal there. That is a tap that runs and delivers nothing (a process without the permission gets exactly that).
///   Digital silence is exact zeros as recorded, below `silent` once through the codec; the backup's signal must lie
///   more than `inside` from the ends of the silence, so that the end of a sound the two tracks hold a little apart
///   is not taken for it. Silence in both is no reason to switch, and the tap is silent whenever nothing plays.
/// So a FaceTime call, which only the tap hears, is the tap's; a stretch in which the tap was dead is the backup's;
/// and with both alive and hearing the same sound, the tap's alone, with no switch at all.
///
/// A switch is a linear crossfade of `crossfade` seconds on the side of the edge where the tap still has its sound:
/// before the edge where it stopped, after the edge where it came back. It does not wait for a quiet moment: in a call
/// there may be none for many seconds, and at the edge of an outage only one source has the sound. It is seamless when
/// the two tracks are in step, which `SystemAudioAlignment` sees to before the mix.
enum SystemAudioChoice {
    enum Source: String, Equatable {
        case tap, backup
    }

    struct Segment: Equatable {
        var start: Double
        var end: Double
        var source: Source
    }

    /// Levels are given as the RMS of every `block` seconds
    static let block = 0.01
    /// RMS above which a source has signal: -70 dBFS
    static let signal: Float = 0.000_316
    /// RMS below which a block of the tap's track is digital silence: -100 dBFS. What was recorded is exact zeros; a
    /// codec gives them back as zeros or next to it.
    static let silent: Float = 0.000_01
    /// How long the tap's track must be digital silence, while the backup has signal, to count as a tap that delivers
    /// nothing
    static let silentRun = 2.0
    /// How far from the ends of such a silence the backup's signal must be: more than the two tracks can be apart
    /// (`SystemAudioAlignment.limit`)
    static let inside = 0.3
    static let crossfade = 0.005
    /// Pieces shorter than this do not count as the tap's, even where it delivered: a few milliseconds of tap
    /// between two switches would only be two fades
    static let shortest = 0.01
    /// Less than this without the tap at the very start or end of the recording is left to the tap all the same
    static let tail = 0.25

    /// RMS of `levels` (one per `block`) over `start` to `end` seconds
    static func level(_ levels: [Float], from start: Double, to end: Double) -> Float {
        let first = max(0, Int((start / block).rounded(.down)))
        let last = min(levels.count, Int((end / block - 0.000_001).rounded(.up)))
        guard first < last else { return 0 }
        var sum: Float = 0
        for index in first..<last { sum += levels[index] * levels[index] }
        return (sum / Float(last - first)).squareRoot()
    }

    /// The stretches of `duration` seconds and which source each takes, on the timeline of the mix. `tap` and `backup`
    /// are the levels of the two tracks per `block`, each on its own track's timeline; `spans` where the tap
    /// delivered, nil when that was not recorded (then it counts as alive for the whole of its track, and only its
    /// digital silence against the backup's signal gives a stretch to the backup). `offset` is how many seconds the
    /// tap's audio is later in its track than the same audio in the backup's (`SystemAudioAlignment`): the mix moves
    /// the tap's audio that much earlier, and the stretches with it.
    ///
    /// `call` are the levels of the call tap's track, which holds only what `avconferenced` plays (FaceTime and phone
    /// calls) and which ScreenCaptureKit's audio never has; `callOffset` is how many seconds its audio is later in
    /// its track than the same audio in the tap's. A tap that is digital silence for `silentRun` while the call tap
    /// has signal there delivers nothing either, and that stretch is not the tap's: the mix has the backup plus the
    /// call tap's audio in every stretch that is not the tap's (`callStretches`).
    static func plan(tap: [Float], backup: [Float], spans: TapSpans?, duration: Double, offset: Double = 0,
                     call: [Float] = [], callOffset: Double = 0) -> [Segment] {
        guard duration > 0 else { return [] }
        // On the timeline of the tap's track first. Where the tap's track has ended there is no tap.
        let tapEnd = min(duration, Double(tap.count) * block)
        var alive = [(start: Double, end: Double)]()
        for span in spans?.spans ?? [TapSpans.Span(start: 0, end: .infinity)] {
            let start = max(0, span.start), end = min(span.end, tapEnd)
            if end - start >= shortest { alive.append((start, end)) }
        }
        // The backup's stretches: all that is not alive, and the tap's long silences the backup has signal in
        var taken = [(start: Double, end: Double)]()
        var cursor = 0.0
        for piece in alive {
            if piece.start > cursor { taken.append((cursor, piece.start)) }
            cursor = max(cursor, piece.end)
        }
        if cursor < duration { taken.append((cursor, duration)) }
        var index = 0
        while index < tap.count {
            guard tap[index] < silent else { index += 1; continue }
            var end = index
            while end < tap.count && tap[end] < silent { end += 1 }
            let from = Double(index) * block, to = end == tap.count ? tapEnd : min(Double(end) * block, duration)
            if to - from >= silentRun - 0.000_001,
               hasSignal(backup, from: from + inside - offset, to: to - inside - offset)
                || hasSignal(call, from: from + inside + callOffset, to: to - inside + callOffset) {
                taken.append((from, to))
            }
            index = end
        }
        taken.sort { $0.start < $1.start }
        var merged = [(start: Double, end: Double)]()
        for piece in taken where piece.end > piece.start {
            // The tap between two of the backup's stretches for less than `shortest` is not worth its two fades
            if let last = merged.last, piece.start - last.end < shortest {
                merged[merged.count - 1].end = max(last.end, piece.end)
            } else {
                merged.append(piece)
            }
        }
        // A tap that begins a buffer after the recording, or ends one before it, was alive throughout: the tracks
        // never begin and end on the same sample, and less than `tail` at an end is not worth a switch
        if let first = merged.first, first.start <= 0, first.end < tail { merged.removeFirst() }
        if let last = merged.last, last.end >= duration, duration - last.start < tail { merged.removeLast() }
        // Onto the timeline of the mix: the tap's audio, and with it every edge, `offset` earlier. Moving the tap's
        // track leaves up to `offset` at one end of the recording without it; the tap stays the source there, so a
        // tap alive throughout has no stretch from the backup.
        var segments = [Segment]()
        var position = 0.0
        func add(_ end: Double, _ source: Source) {
            let end = min(duration, max(position, end))
            guard end > position else { return }
            if let last = segments.last, last.source == source {
                segments[segments.count - 1].end = end
            } else {
                segments.append(Segment(start: position, end: end, source: source))
            }
            position = end
        }
        for piece in merged {
            // A stretch that begins or ends with the recording does so in the mix too
            let start = piece.start <= 0 ? 0 : piece.start - offset
            let end = piece.end >= duration ? duration : piece.end - offset
            add(start, .tap)
            add(end, .backup)
        }
        add(duration, .tap)
        return segments
    }

    /// The stretches of `segments` (on the mix's timeline) that are not the tap's and in which the call tap's track
    /// has signal: where the mix takes the call audio from the call tap. `call` are that track's levels and `shift`
    /// how many seconds later its audio is in its track than in the mix.
    static func callStretches(_ segments: [Segment], call: [Float], shift: Double) -> [(start: Double, end: Double)] {
        return segments.filter { $0.source == .backup && hasSignal(call, from: $0.start + shift, to: $0.end + shift) }.map { ($0.start, $0.end) }
    }

    /// Seconds the call tap has in the mix and in how many stretches, for the log
    static func callSummary(_ stretches: [(start: Double, end: Double)]) -> String {
        guard !stretches.isEmpty else { return "none needed: the process tap was alive wherever the call tap has sound" }
        let seconds = stretches.reduce(0) { $0 + $1.end - $1.start }
        return String(format: "%.1f s from the call tap in %d %@, added to the backup there", seconds, stretches.count, stretches.count == 1 ? "stretch" : "stretches")
    }

    /// Whether any block of `levels` between `start` and `end` seconds is above `signal`
    static func hasSignal(_ levels: [Float], from start: Double, to end: Double) -> Bool {
        let first = max(0, Int((start / block).rounded(.up)))
        let last = min(levels.count, Int((end / block).rounded(.down)))
        guard first < last else { return false }
        return levels[first..<last].contains { $0 > signal }
    }

    /// The gain of the tap's track over time for `segments` (the backup's is one minus it): one in the tap's
    /// stretches, zero in the backup's, a linear fade of `crossfade` at each switch, inside the tap's stretch: the
    /// backup's stretches are those in which the tap's track has nothing
    static func tapGain(for segments: [Segment]) -> GainCurve {
        guard let first = segments.first else { return GainCurve(points: [(0, 1)]) }
        var points: [(time: Double, gain: Float)] = [(0, first.source == .tap ? 1 : 0)]
        for index in segments.indices.dropFirst() {
            let before = segments[index - 1], after = segments[index]
            let edge = after.start
            var from = edge, to = edge
            if before.source == .tap {
                // Never beyond the middle of the tap's stretch
                from = max(edge - crossfade, (before.start + edge) / 2)
            } else {
                to = min(edge + crossfade, (edge + after.end) / 2)
            }
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

/// How far apart the process tap's and the backup's tracks hold the same sound, measured from the sound itself
/// before the mix, so the mix can put the tap's audio on the backup's timeline.
///
/// Measured on the owner's Mac on 2026-10-07 (AirPods in 24 kHz call mode, voice processing switched on mid-way):
/// the tap's audio was 52.4 ms later in its track than the backup's, the same at five points of the recording.
/// ScreenCaptureKit stamps its audio to go with its pictures, so the backup's timeline is the one in step with the
/// video; a tap buffer is stamped as ending when its IOProc was called, which leaves out whatever the device held it
/// for before that. With the two tracks apart, a switch between them doubles or cuts a sound.
///
/// `windows` stretches of `window` seconds spread over the recording, each where both tracks have sound, are compared:
/// the backup's stretch against the tap's track `reach` either way, by normalised cross-correlation of the samples.
/// A window counts when its best match is at least `likeness`, lies within `limit`, and has no rival (another peak
/// nearly as good, as any steady tone has one every period). The windows must agree: at least `fewest` of them, and
/// two in three of those that count, within `agreement` of their median. Anything else is "not known", and the tap
/// is then used as it was stamped: a FaceTime call, which the backup does not hear, has no common sound at all.
enum SystemAudioAlignment {
    /// The most the tracks may be apart for a measurement to be believed
    static let limit = 0.25
    /// How far each way the tap's track is searched: past `limit`, so a match at the limit is a peak, not an edge
    static let reach = 0.3
    static let window = 1.0
    static let windows = 16
    /// Both tracks must be above this RMS in a window: -60 dBFS
    static let level: Float = 0.001
    static let likeness: Float = 0.5
    /// Another peak at this share of the best one, or more, makes a window ambiguous
    static let rival: Float = 0.9
    /// Peaks nearer the best one than this are the same peak
    static let peakWidth = 0.000_5
    /// The tap's track follows its device's clock within `TapDrift.begins`, so windows may differ by a few
    /// milliseconds and still measure the same thing
    static let agreement = 0.005
    static let fewest = 3

    struct Measurement: Equatable {
        /// Seconds the tap's audio is later in its track than the same audio in the backup's (negative: earlier),
        /// a whole number of samples; nil when it could not be measured
        var offset: Double?
        /// Windows whose measurements agree, of those compared
        var agreeing: Int
        var windows: Int

        static let none = Measurement(offset: nil, agreeing: 0, windows: 0)

        /// For the log
        var text: String {
            guard let offset else {
                let why = windows == 0 ? "no stretch with sound in both the tap's and the backup's audio"
                    : "of \(windows) \(windows == 1 ? "window" : "windows") with sound in both, \(agreeing) \(agreeing == 1 ? "gives" : "agree on") an offset"
                return "not measured (\(why)): the tap's audio is used as it was stamped"
            }
            let side = offset < 0 ? "earlier" : "later"
            return String(format: "the tap's audio is %.1f ms %@ than the backup's (%d of %d windows agree) and is moved onto the backup's timeline", abs(offset) * 1000, side, agreeing, windows)
        }
    }

    /// The same measurement taken between the call tap's track and the process tap's, for the log: `offset` is then
    /// how much later the call tap's audio is in its track than the same audio in the process tap's. Without one
    /// the call tap's audio is moved like the process tap's: both are stamped in an IOProc.
    static func callText(_ measured: Measurement) -> String {
        guard let offset = measured.offset else {
            let why = measured.windows == 0 ? "no stretch with sound in both the call tap's and the process tap's audio"
                : "of \(measured.windows) \(measured.windows == 1 ? "window" : "windows") with sound in both, \(measured.agreeing) \(measured.agreeing == 1 ? "gives" : "agree on") an offset"
            return "not measured (\(why)): the call tap's audio is moved like the process tap's"
        }
        return String(format: "the call tap's audio is %.1f ms %@ than the process tap's (%d of %d windows agree) and is moved onto the mix's timeline with it",
                      abs(offset) * 1000, offset < 0 ? "earlier" : "later", measured.agreeing, measured.windows)
    }

    /// Where the windows to compare start, in seconds: in each of up to `windows` equal parts of the recording the
    /// one in which the quieter of the two tracks is loudest, when both are above `level` there. `tap` and `backup`
    /// are the tracks' levels per `SystemAudioChoice.block`.
    static func starts(tap: [Float], backup: [Float], duration: Double) -> [Double] {
        let first = reach, last = min(duration, Double(min(tap.count, backup.count)) * SystemAudioChoice.block) - window - reach
        guard last > first else { return [] }
        let parts = max(1, min(windows, Int((last - first) / window)))
        let length = (last - first) / Double(parts)
        var starts = [Double]()
        for part in 0..<parts {
            var best: (start: Double, level: Float)?
            var start = first + Double(part) * length
            let end = part == parts - 1 ? last : start + length
            while start <= end {
                let quieter = min(SystemAudioChoice.level(tap, from: start, to: start + window), SystemAudioChoice.level(backup, from: start, to: start + window))
                if quieter > level, quieter > best?.level ?? 0 { best = (start, quieter) }
                start += window / 4
            }
            if let best, best.start - (starts.last ?? -.infinity) >= window / 2 { starts.append(best.start) }
        }
        return starts
    }

    /// How many frames later `reference` is found in `searched` than at `margin` frames from its start, where it would
    /// be with the two in step; nil when no place matches well enough or more than one does. `searched` is longer than
    /// `reference` by twice `margin`; a match is accepted up to `most` frames either way, and peaks within `width`
    /// frames of each other are one.
    static func lag(of reference: [Float], in searched: [Float], margin: Int, most: Int, width: Int) -> Int? {
        let count = reference.count, lags = searched.count - count + 1
        guard count > 0, lags > 0 else { return nil }
        var products = [Float](repeating: 0, count: lags)
        vDSP_conv(searched, 1, reference, 1, &products, 1, vDSP_Length(lags), vDSP_Length(count))
        var referenceEnergy: Float = 0
        vDSP_svesq(reference, 1, &referenceEnergy, vDSP_Length(count))
        guard referenceEnergy > 0 else { return nil }
        // The energy of the part of `searched` under the reference, for each place
        var sums = [Double](repeating: 0, count: searched.count + 1)
        for index in searched.indices { sums[index + 1] = sums[index] + Double(searched[index]) * Double(searched[index]) }
        let loudest = (0..<lags).reduce(0.0) { max($0, sums[$1 + count] - sums[$1]) }
        guard loudest > 0 else { return nil }
        var likeness = [Float](repeating: 0, count: lags)
        for index in 0..<lags {
            let energy = sums[index + count] - sums[index]
            // A place with next to nothing in it matches nothing
            guard energy > loudest / 100 else { continue }
            likeness[index] = products[index] / Float((Double(referenceEnergy) * energy).squareRoot())
        }
        guard let best = likeness.indices.max(by: { likeness[$0] < likeness[$1] }), likeness[best] >= SystemAudioAlignment.likeness,
              abs(best - margin) <= most else { return nil }
        for index in likeness.indices where abs(index - best) > width && likeness[index] >= rival * likeness[best] {
            let before = index > 0 ? likeness[index - 1] : -1, after = index + 1 < lags ? likeness[index + 1] : -1
            if likeness[index] >= before && likeness[index] >= after { return nil }
        }
        return best - margin
    }

    /// What the windows' offsets, in frames at `rate`, say together; `windows` is how many were compared
    static func agree(_ offsets: [Int], windows: Int, rate: Double) -> Measurement {
        guard !offsets.isEmpty else { return Measurement(offset: nil, agreeing: 0, windows: windows) }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let middle = median(offsets)
        let near = offsets.filter { Double(abs($0 - middle)) <= agreement * rate }
        guard near.count >= fewest, near.count * 3 >= offsets.count * 2 else { return Measurement(offset: nil, agreeing: near.count, windows: windows) }
        return Measurement(offset: Double(median(near)) / rate, agreeing: near.count, windows: windows)
    }

    /// Measures the offset of a recording. `tap` and `backup` are the tracks' levels, `read` gives `count` frames of
    /// one of the tracks from frame `first` on as one channel (silence where the track has none; `first` may be
    /// negative), at `rate` frames a second.
    static func measure(tap: [Float], backup: [Float], duration: Double, rate: Double,
                        read: (SystemAudioChoice.Source, Int64, Int) throws -> [Float]) rethrows -> Measurement {
        let starts = starts(tap: tap, backup: backup, duration: duration)
        let count = Int((window * rate).rounded()), margin = Int((reach * rate).rounded())
        var offsets = [Int]()
        for start in starts {
            let first = Int64((start * rate).rounded())
            let reference = try read(.backup, first, count)
            let searched = try read(.tap, first - Int64(margin), count + 2 * margin)
            guard reference.count == count, searched.count == count + 2 * margin else { continue }
            if let lag = lag(of: reference, in: searched, margin: margin, most: Int((limit * rate).rounded()), width: Int((peakWidth * rate).rounded())) {
                offsets.append(lag)
            }
        }
        return agree(offsets, windows: starts.count, rate: rate)
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
