//
//  Plan.swift
//  The simulated meeting: what each source delivers, when, and with what in it. Everything is generated from fixed
//  seeds, so the schedule is the same in every process (the recording, the killed run and its recovery).
//  Times are seconds on the stream's clock from the moment the capture began.
//

import AVFoundation
import Foundation

/// A small fast generator with a fixed seed
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1)
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * uniform() }
    /// Uniform in [-1, 1), as a Float
    mutating func noise() -> Float { Float(Int64(bitPattern: next()) >> 11) / Float(1 << 52) }
}

struct Marker {
    let index: Int
    /// When the tone starts, on the stream's clock
    let time: Double
    let frequency: Double
}

enum Plan {
    /// The stop, on the stream's clock: 90 minutes of capture, of which 2 are paused
    static let length = 5400.0
    /// Where a killed run is killed
    static let killAt = 2700.0
    /// The host clock the stream's timestamps are on is far from zero
    static let base = 50_000.0
    /// The uptime the simulated monitor ticks with, at time 0
    static let uptimeZero: UInt64 = 1_000_000_000_000

    // Video: 64 x 36 at 5 fps; a static slide delivers no frame at all for five minutes
    static let width = 64
    static let height = 36
    static let fps = 5
    static let firstFrame = 0.1
    static let staticSlide = (start: 1200.0, end: 1500.0)

    // Controls, on the stream's clock (the time the user acts)
    static let pause = (start: 3000.0, end: 3120.0)
    static let mute = (start: 4010.0, end: 4070.0)

    // System audio from the process tap, and the same sound from ScreenCaptureKit as its backup: 48 kHz stereo
    // float, 1024 frames a buffer, low noise with a tone burst every minute. The tap delivers nothing for 30 s, as
    // today's AirPods-clocked tap did, and is then repaired; the backup delivers throughout.
    static let tapOutage = (start: 2215.0, end: 2245.0)
    /// Where the tap's audio stops and starts again: at the edges of the buffers it delivered (those that start in
    /// the outage are not delivered)
    static var tapSilence: (start: Double, end: Double) {
        func edge(_ t: Double) -> Double { (t * systemRate / Double(systemFrames)).rounded(.up) * Double(systemFrames) / systemRate }
        return (edge(tapOutage.start), edge(tapOutage.end))
    }
    static let systemRate = 48000.0
    static let systemFrames = 1024
    static let systemNoise: Float = 0.0173      // uniform, RMS 0.01 (-40 dBFS)

    // Microphone: noise at speech level with a tone burst every minute, 30 s after the system audio's
    static let micNoise: Float = 0.0866         // uniform, RMS 0.05 (-26 dBFS)
    /// The microphone's sample clock runs this much fast against the stream's clock
    static let micClockError = 50e-6
    /// What the microphone delivers: 24 kHz mono AirPods; a call app takes the microphone at 600 s (nothing for
    /// 10 s, then 48 kHz mono for three minutes, then AirPods again); the AirPods disconnect at 2000 s for 30 s
    static let micSegments: [(start: Double, end: Double, rate: Double)] = [
        (0.03, 600, 24000),
        (610, 790, 48000),
        (790, 2000, 24000),
        (2030, 5401, 24000),
    ]

    static let burst = 0.25
    static let burstAmplitude: Float = 0.5
    static let markerCount = 90

    static let systemMarkers = (0..<markerCount).map { Marker(index: $0, time: 60 * Double($0) + 10, frequency: 1000 + 20 * Double($0)) }
    static let micMarkers = (0..<markerCount).map { Marker(index: $0, time: 60 * Double($0) + 40, frequency: 3000 + 20 * Double($0)) }

    /// The tone of the marker that sounds at `t`, if any (markers are 60 s apart, starting at `first`)
    @inline(__always)
    static func tone(at t: Double, first: Double, frequencyBase: Double) -> Float {
        let index = Int(((t - first) / 60).rounded(.down))
        guard index >= 0, index < markerCount else { return 0 }
        let start = 60 * Double(index) + first
        let into = t - start
        guard into >= 0, into < burst else { return 0 }
        return burstAmplitude * Float(sin(2 * Double.pi * (frequencyBase + 20 * Double(index)) * into))
    }

    /// A time on the stream's clock as the capture stamps it: nanoseconds of the host clock
    static func stamp(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue(((base + seconds) * 1_000_000_000).rounded()), timescale: 1_000_000_000)
    }

    static func seconds(_ time: CMTime) -> Double { CMTimeGetSeconds(time) - base }

    static func uptime(_ seconds: Double) -> UInt64 { uptimeZero + UInt64((seconds * 1_000_000_000).rounded()) }
}

// MARK: - Schedules

/// One microphone buffer: where its samples are in the device's stream, the time it is stamped with and when it arrives
struct MicBuffer {
    let segment: Int
    let firstSample: Int64
    let frames: Int
    let rate: Double
    /// Start of the first sample on the stream's clock, without the timestamp's jitter
    let start: Double
    /// The timestamp the capture gives it
    let pts: Double
    let end: Double
    let arrival: Double
}

/// The microphone's buffers in order of arrival: 20 ms on average at 24 kHz (as measured from ScreenCaptureKit with
/// AirPods), irregular in size (12 to 28 ms), stamped with 0.5 ms of jitter, arriving 3 to 30 ms after their end,
/// and one in 400 held up by 100 to 400 ms, after which the ones behind it arrive in a burst
struct MicSchedule {
    private var random = SplitMix(seed: 0x6D69_6372)
    private var segment = 0
    private var sample: Int64 = 0
    private var lastArrival = 0.0

    mutating func next() -> MicBuffer? {
        while segment < Plan.micSegments.count {
            let part = Plan.micSegments[segment]
            let rate = part.rate * (1 + Plan.micClockError)
            let start = part.start + Double(sample) / rate
            if start >= part.end - 1e-9 {
                segment += 1
                sample = 0
                continue
            }
            var frames = Int((part.rate / 50 * random.range(0.6, 1.4)).rounded())
            frames = max(1, min(frames, Int(((part.end - start) * rate).rounded(.up))))
            let end = part.start + Double(sample + Int64(frames)) / rate
            let jitter = random.range(-0.0005, 0.0005)
            var latency = random.range(0.003, 0.030)
            if random.uniform() < 1.0 / 400 { latency = random.range(0.1, 0.4) }
            let arrival = max(lastArrival, end + latency)
            lastArrival = arrival
            let buffer = MicBuffer(segment: segment, firstSample: sample, frames: frames, rate: part.rate, start: start, pts: start + jitter, end: end, arrival: arrival)
            sample += Int64(frames)
            return buffer
        }
        return nil
    }
}

struct SystemBuffer {
    let index: Int
    let pts: Double
    let end: Double
    let arrival: Double
}

/// System audio: 1024-frame buffers on the stream's own clock, arriving 5 to 25 ms after their end. The tap's and
/// the backup's have their own arrivals (`seed`).
struct SystemSchedule {
    private var random: SplitMix
    init(seed: UInt64 = 0x7379_7374) { random = SplitMix(seed: seed) }
    private var index = 0
    private var lastArrival = 0.0

    mutating func next() -> SystemBuffer {
        let pts = Double(index * Plan.systemFrames) / Plan.systemRate
        let end = Double((index + 1) * Plan.systemFrames) / Plan.systemRate
        let arrival = max(lastArrival, end + random.range(0.005, 0.025))
        lastArrival = arrival
        defer { index += 1 }
        return SystemBuffer(index: index, pts: pts, end: end, arrival: arrival)
    }
}

struct VideoFrame {
    /// The time code drawn into the frame
    let number: Int
    let pts: Double
    let arrival: Double
}

/// Frames every 0.2 s, none during the static slide, arriving 10 to 30 ms after their time
struct VideoSchedule {
    private var random = SplitMix(seed: 0x7669_6465)
    private var number = 0
    private var lastArrival = 0.0

    static func time(of number: Int) -> Double { Plan.firstFrame + Double(number) / Double(Plan.fps) }

    mutating func next() -> VideoFrame {
        while true {
            let pts = VideoSchedule.time(of: number)
            number += 1
            if pts >= Plan.staticSlide.start && pts < Plan.staticSlide.end { continue }
            let arrival = max(lastArrival, pts + random.range(0.010, 0.030))
            lastArrival = arrival
            return VideoFrame(number: number - 1, pts: pts, arrival: arrival)
        }
    }
}

// MARK: - What the recording should hold

/// Where things land on the recording's timeline, given where its session started and what its pause took out
struct OutputTimeline {
    let sessionStart: Double
    /// Time taken out for the pause (zero when the recording never got there)
    let pauseOffset: Double

    /// Position in the output file of a time on the stream's clock; nil while paused
    func output(_ t: Double) -> Double? {
        if t < Plan.pause.start { return t - sessionStart }
        if t < Plan.pause.end { return nil }
        return t - sessionStart - pauseOffset
    }

    /// The same for the end of a hole, which may lie just before the resume and still count from after it
    func outputAfterPause(_ t: Double) -> Double {
        if t < Plan.pause.start { return t - sessionStart }
        return t - sessionStart - pauseOffset
    }
}

/// Spans of the stream's clock in which the microphone track has nothing of the microphone: the holes between the
/// buffers the writer was given (not paused, not muted), as long as the capture ran up to `stop`. Holes shorter than
/// 0.1 s are written back to back and leave no silence.
func expectedMicrophoneHoles(stop: Double, sessionStart: Double) -> [(start: Double, end: Double)] {
    var schedule = MicSchedule()
    var holes = [(start: Double, end: Double)]()
    var coveredUntil = sessionStart
    while let buffer = schedule.next(), buffer.arrival <= stop {
        let paused = buffer.arrival >= Plan.pause.start && buffer.arrival < Plan.pause.end
        let muted = buffer.arrival >= Plan.mute.start && buffer.arrival < Plan.mute.end
        guard !paused, !muted, buffer.end > sessionStart else { continue }
        if buffer.pts - coveredUntil > 0.1 { holes.append((coveredUntil, buffer.pts)) }
        coveredUntil = max(coveredUntil, buffer.end)
    }
    return holes
}
