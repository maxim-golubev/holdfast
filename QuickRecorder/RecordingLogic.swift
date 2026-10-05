//
//  RecordingLogic.swift
//  QuickRecorder
//

import CoreMedia
import Foundation

// The parts of the recording pipeline that decide something without touching the capture, the writer or the
// app's state. They take what they need as parameters, so `Tools/test.sh` can run them without the app.

/// Times on the writer's timeline, and how they are shown
enum Timeline {
    /// "07:05" up to an hour, "1:07:05" from then on. The status bar makes room for the longer form (`getStatusBarWidth`).
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

    /// The latest end time of anything on the timeline: `end` when it is valid and later than `last`, else `last`
    static func latestEnd(_ end: CMTime?, after last: CMTime?) -> CMTime? {
        guard let end = end, end.isValid else { return last }
        if let last = last, end <= last { return last }
        return end
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
