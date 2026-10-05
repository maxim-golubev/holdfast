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

/// The files of one recording, from the path of its final file without the extension. See `RecordingMixer` for
/// the temporary names of a recording whose audio tracks are mixed afterwards.
struct RecordingFiles {
    /// What is written while recording: the video file, the audio file, or the .qma package for audio with a microphone
    let rawURL: URL
    /// What the audio mix after a video recording writes before it is checked and gets the final name, nil when
    /// the audio tracks are not mixed
    let mixURL: URL?
    /// The name the recording as it was written (two audio tracks) gets when it is kept, nil when the audio tracks are not mixed
    let unmixedURL: URL?
    /// What the user ends up with
    let finalURL: URL
    /// Audio-only recordings: the system audio file, and the microphone file when there is one
    let systemAudioURL: URL?
    let micAudioURL: URL?

    /// `videoEnding` and `audioEnding` are the file extensions of the chosen formats; `exportsMP3` says that the
    /// audio is recorded as AAC and converted to MP3 afterwards.
    init(base: String, audioOnly: Bool, recordMic: Bool, systemAudio: Bool, remuxAudio: Bool, videoEnding: String, audioEnding: String, exportsMP3: Bool) {
        if audioOnly {
            let exported = exportsMP3 ? "mp3" : audioEnding
            mixURL = nil
            unmixedURL = nil
            if recordMic {
                let package = URL(fileURLWithPath: "\(base).qma")
                rawURL = package
                systemAudioURL = package.appendingPathComponent("sys.\(audioEnding)")
                micAudioURL = package.appendingPathComponent("mic.\(audioEnding)")
                finalURL = remuxAudio ? URL(fileURLWithPath: "\(base).\(exported)") : package
            } else {
                let file = URL(fileURLWithPath: "\(base).\(audioEnding)")
                rawURL = file
                systemAudioURL = file
                micAudioURL = nil
                finalURL = exportsMP3 ? URL(fileURLWithPath: "\(base).mp3") : file
            }
        } else {
            finalURL = URL(fileURLWithPath: "\(base).\(videoEnding)")
            systemAudioURL = nil
            micAudioURL = nil
            if remuxAudio && recordMic && systemAudio {
                // Written under a temporary name, and so is the mix, which becomes the final file once it is
                // complete and checked. See RecordingMixer for the names.
                rawURL = RecordingMixer.temporaryURL(base: base, marker: RecordingMixer.rawMarker, ending: videoEnding)
                mixURL = RecordingMixer.temporaryURL(base: base, marker: RecordingMixer.mixMarker, ending: videoEnding)
                unmixedURL = RecordingMixer.unmixedURL(base: base, ending: videoEnding)
            } else {
                mixURL = nil
                unmixedURL = nil
                rawURL = finalURL
            }
        }
    }

    /// Path without extension for a file made at `date`: `<directory>/<prefix><date>`
    static func basePath(directory: String, prefix: String, date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return directory + "/" + prefix + dateFormatter.string(from: date)
    }

    /// Gives a recording that was written under its temporary name the name it is kept under. Nothing is deleted
    /// or replaced: when the name is taken or the rename fails, the recording stays where it is. Returns where it is afterwards.
    static func keep(written: URL, as kept: URL) -> URL {
        do {
            try FileManager.default.moveItem(at: written, to: kept)
            return kept
        } catch {
            print("Failed to rename the unmixed recording: \(error.localizedDescription)")
            return written
        }
    }
}

/// The labels launch recovery puts in the names of the files an earlier run left behind: `<name> (<label>).<ext>`
enum RecoveryNames {
    /// What an interrupted mix had written
    static let incompleteMix = "incomplete mix"
    /// A recording that does not open
    static let damaged = "damaged"
    static let recovered = "recovered"
    /// "unmixed, 2 audio tracks": the label of the recording as it was written, as after an ordinary mix
    static let unmixed = String(RecordingMixer.unmixedSuffix.dropFirst(2).dropLast())

    /// The mix of a recording that had been closed is complete and gets the final name, without a label
    static func mix(complete: Bool) -> String? {
        return complete ? nil : recovered
    }

    /// The recording itself, which is only ever renamed. `mixed` says whether its mix was written and checked.
    static func recording(complete: Bool, mixed: Bool) -> String {
        if mixed { return complete ? unmixed : recovered + ", " + unmixed }
        return complete ? unmixed : recovered
    }
}
