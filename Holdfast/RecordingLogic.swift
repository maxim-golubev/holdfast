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
