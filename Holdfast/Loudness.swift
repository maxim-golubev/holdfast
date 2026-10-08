//
//  Loudness.swift
//  Holdfast
//

import Foundation

/// The integrated loudness of audio as ITU-R BS.1770 defines it: K-weighting, blocks of 400 ms every 100 ms, an
/// absolute gate at -70 LUFS and a relative gate 10 LU under the mean of what passed the first. Fed piece by piece
/// (`add`); it keeps one number per 100 ms, so a 90-minute recording costs half a megabyte.
struct LoudnessMeter {
    /// What a meter has heard
    struct Reading: Equatable {
        /// In LUFS; nil when no block passed the gates (silence)
        let loudness: Double?
        /// How much sound passed both gates, in seconds
        let gatedSeconds: Double
    }

    static let absoluteGate = -70.0
    static let relativeGate = -10.0
    /// The 100 ms pieces a block is made of
    private static let piecesInBlock = 4

    /// One second-order section, transposed direct form II
    private struct Section {
        let b0, b1, b2, a1, a2: Double
        var s1 = 0.0, s2 = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            return y
        }
    }

    private let channels: Int
    private let pieceFrames: Int
    /// Per channel: the shelf that stands for the head, then the high-pass
    private var shelf: [Section]
    private var highPass: [Section]
    /// The squares of the piece being filled, all channels, and how many frames it has
    private var sum = 0.0
    private var filled = 0
    /// The sums of the last pieces, newest last
    private var recent = [Double]()
    /// The mean square of every block, the channels added up
    private var blocks = [Double]()

    /// A meter for interleaved audio of `channels` channels (one or two: each counts fully) at `rate`
    init(rate: Double, channels: Int) {
        self.channels = max(1, channels)
        pieceFrames = max(1, Int((rate * 0.1).rounded()))
        // The two filters of BS.1770 as analogue prototypes, so that any sample rate gets the same curve; at 48 kHz
        // these are the coefficients the recommendation lists
        let shelfK = tan(Double.pi * 1681.974450955533 / rate), shelfQ = 0.7071752369554196
        let high = pow(10, 3.999843853973347 / 20), band = pow(high, 0.4996667741545416)
        let shelfA0 = 1 + shelfK / shelfQ + shelfK * shelfK
        let shelfSection = Section(b0: (high + band * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
                                   b1: 2 * (shelfK * shelfK - high) / shelfA0,
                                   b2: (high - band * shelfK / shelfQ + shelfK * shelfK) / shelfA0,
                                   a1: 2 * (shelfK * shelfK - 1) / shelfA0,
                                   a2: (1 - shelfK / shelfQ + shelfK * shelfK) / shelfA0)
        let passK = tan(Double.pi * 38.13547087602444 / rate), passQ = 0.5003270373238773
        let passA0 = 1 + passK / passQ + passK * passK
        let passSection = Section(b0: 1, b1: -2, b2: 1, a1: 2 * (passK * passK - 1) / passA0, a2: (1 - passK / passQ + passK * passK) / passA0)
        shelf = [Section](repeating: shelfSection, count: self.channels)
        highPass = [Section](repeating: passSection, count: self.channels)
    }

    /// `frames` frames of interleaved samples, following those before them
    mutating func add(_ samples: UnsafeBufferPointer<Float>, frames: Int) {
        let count = min(frames, samples.count / channels)
        guard count > 0 else { return }
        for frame in 0..<count {
            for channel in 0..<channels {
                let weighted = highPass[channel].run(shelf[channel].run(Double(samples[frame * channels + channel])))
                sum += weighted * weighted
            }
            filled += 1
            if filled == pieceFrames { closePiece() }
        }
    }

    private mutating func closePiece() {
        recent.append(sum)
        sum = 0
        filled = 0
        if recent.count > LoudnessMeter.piecesInBlock { recent.removeFirst() }
        guard recent.count == LoudnessMeter.piecesInBlock else { return }
        blocks.append(recent.reduce(0, +) / Double(LoudnessMeter.piecesInBlock * pieceFrames))
    }

    /// The loudness of a mean square, in LUFS
    static func loudness(ofPower power: Double) -> Double { -0.691 + 10 * log10(power) }
    private static func power(ofLoudness loudness: Double) -> Double { pow(10, (loudness + 0.691) / 10) }

    /// The integrated loudness of everything added so far
    var reading: Reading {
        let floor = LoudnessMeter.power(ofLoudness: LoudnessMeter.absoluteGate)
        let heard = blocks.filter { $0 > floor }
        guard !heard.isEmpty else { return Reading(loudness: nil, gatedSeconds: 0) }
        let threshold = heard.reduce(0, +) / Double(heard.count) * pow(10, LoudnessMeter.relativeGate / 10)
        let gated = heard.filter { $0 > threshold }
        guard !gated.isEmpty else { return Reading(loudness: nil, gatedSeconds: 0) }
        return Reading(loudness: LoudnessMeter.loudness(ofPower: gated.reduce(0, +) / Double(gated.count)), gatedSeconds: Double(gated.count) * 0.1)
    }
}

/// "Level Voices": what the mix does to the two sides of a call, which seldom arrive equally loud and usually quiet.
/// Each side gets one gain for the whole recording, from its own loudness, and the sum goes through `PeakLimiter`.
enum VoiceLeveling {
    /// Where spoken content online sits, in LUFS
    static let target = -16.0
    /// The gain a side may get, in dB: no more than a quiet side can take before its noise is what is heard, and no
    /// less than a loud one needs
    static let range = -6.0...12.0
    /// A side with less sound than this past the gates, in seconds, is not measured
    static let shortest = 3.0
    /// A side quieter than this, in LUFS, holds no voice, only the noise of a room or a line: raising it would
    /// raise that
    static let quietest = -50.0

    /// One side of the recording: what was measured and what the mix did with it
    struct Side: Equatable {
        let reading: LoudnessMeter.Reading
        /// In dB
        let gain: Double

        init(_ reading: LoudnessMeter.Reading) {
            self.reading = reading
            gain = VoiceLeveling.gain(for: reading)
        }

        /// The gain as a factor
        var factor: Float { Float(pow(10, gain / 20)) }

        var text: String {
            guard let loudness = reading.loudness else { return "silent, not changed" }
            let measured = String(format: "%.1f LUFS", loudness)
            if reading.gatedSeconds < VoiceLeveling.shortest {
                return measured + String(format: " over only %.1f s, not changed", reading.gatedSeconds)
            }
            if loudness < VoiceLeveling.quietest { return measured + ", too quiet to hold a voice, not changed" }
            return measured + String(format: ", %+.1f dB", gain)
        }
    }

    /// What was done to a mix
    struct Applied: Equatable {
        var system: Side
        /// Nil when the mix has no microphone in it
        var microphone: Side?
        /// The most the limiter took off, in dB (0: it never acted)
        var limiterReduction = 0.0

        var text: String {
            var parts = ["system audio " + system.text]
            if let microphone { parts.append("microphone " + microphone.text) }
            let limiter = limiterReduction > 0 ? String(format: "the limiter took off %.1f dB at most", limiterReduction) : "the limiter had nothing to do"
            return parts.joined(separator: "; ") + "; " + limiter
        }
    }

    /// The gain in dB for a side that measured `reading`: what brings it to `target`, within `range`; 0 for a side
    /// that could not be measured
    static func gain(for reading: LoudnessMeter.Reading) -> Double {
        guard let loudness = reading.loudness, reading.gatedSeconds >= shortest, loudness >= quietest else { return 0 }
        return min(range.upperBound, max(range.lowerBound, target - loudness))
    }
}

/// A look-ahead limiter for interleaved audio: keeps every sample, and what a player reconstructs between the
/// samples (the true peak, estimated at four times the rate), at or below `ceiling`. One gain for all channels, so
/// the stereo picture does not move. The gain falls over the look-ahead before a peak arrives and recovers with
/// `release`. While nothing exceeds the ceiling the samples pass unchanged, bit for bit.
///
/// Its output is `delay` frames behind its input: whoever uses it leaves out the first `delay` frames it returns
/// and feeds it `delay` frames of silence at the end.
struct PeakLimiter {
    /// -1 dBFS
    static let ceiling = pow(10, -1.0 / 20)
    /// How far ahead of a peak the gain starts to fall, in seconds
    static let lookAhead = 0.005
    /// The time in which the gain recovers to within a third of where it was, in seconds
    static let release = 0.15
    /// Samples on each side of a point between two samples that the estimate of it reads
    private static let reach = 6
    /// Within this of 1 the recovering gain is 1 again
    private static let settled = 1e-4

    let channels: Int
    let ceiling: Double
    /// Frames by which the output is behind the input
    let delay: Int
    /// The lowest gain it applied, 1 when it never acted
    private(set) var lowestGain = 1.0

    /// Frames in the look-ahead
    private let window: Int
    private let releaseStep: Double
    /// The three points between two samples, each from the `2 * reach` samples around them
    private let phases: [[Float]]
    /// Below this no point between samples can reach the ceiling, whatever the samples around it are
    private let threshold: Float

    /// The input, interleaved, a ring of `ringFrames` frames (a power of two)
    private var ring: [Float]
    private let ringMask: Int
    private var written = 0
    /// Frames since one at or above `threshold`
    private var sinceHot = Int.max / 2
    /// The peak between the frame before the last one judged and that one
    private var lastPeak: Float = 0
    /// Frames in a row that needed no reduction
    private var quietRun = Int.max / 2
    /// The lowest gain any of the last `window` frames asks for: values and frame numbers, increasing values
    private var lowValues: [Double]
    private var lowFrames: [Int]
    private var lowHead = 0
    private var lowCount = 0
    /// The gain as it recovers
    private var envelope = 1.0
    /// The last `window` values of the envelope, their sum, and how many of them are below 1
    private var envelopes: [Double]
    private var envelopeAt = 0
    private var envelopeSum: Double
    private var envelopesBelow = 0

    /// The most it took off, in dB (0: nothing)
    var reduction: Double { lowestGain < 1 ? -20 * log10(lowestGain) : 0 }

    init(rate: Double, channels: Int = 2, ceiling: Double = PeakLimiter.ceiling) {
        self.channels = max(1, channels)
        self.ceiling = ceiling
        window = max(2, Int((rate * PeakLimiter.lookAhead).rounded()))
        delay = window + PeakLimiter.reach - 1
        releaseStep = 1 - exp(-1 / (PeakLimiter.release * rate))
        // A windowed sinc (Kaiser, beta 6) for the points a quarter, a half and three quarters of the way from one
        // sample to the next
        let reach = PeakLimiter.reach
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<30 {
                term *= (x / 2) / Double(k)
                sum += term * term
            }
            return sum
        }
        var made = [[Float]]()
        var widest = 1.0
        for phase in 1...3 {
            let fraction = Double(phase) / 4
            var taps = [Double]()
            for tap in 0..<(2 * reach) {
                // The sample `tap - (reach - 1)` frames from the one before the point
                let distance = Double(tap - (reach - 1)) - fraction
                let sinc = distance == 0 ? 1 : sin(Double.pi * distance) / (Double.pi * distance)
                let inside = max(0, 1 - (distance / Double(reach)) * (distance / Double(reach)))
                taps.append(sinc * bessel(6 * inside.squareRoot()) / bessel(6))
            }
            let total = taps.reduce(0, +)
            taps = taps.map { $0 / total }
            widest = max(widest, taps.reduce(0) { $0 + abs($1) })
            made.append(taps.map { Float($0) })
        }
        phases = made
        threshold = Float(ceiling / widest * 0.999)
        var size = 1
        while size < delay + 2 * reach + 2 { size *= 2 }
        ring = [Float](repeating: 0, count: size * self.channels)
        ringMask = size - 1
        lowValues = [Double](repeating: 1, count: window + 1)
        lowFrames = [Int](repeating: 0, count: window + 1)
        envelopes = [Double](repeating: 1, count: window)
        envelopeSum = Double(window)
    }

    /// Limits `frames` frames of interleaved samples in place; what comes out is what went in `delay` frames
    /// earlier (silence at first)
    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>, frames: Int) {
        let count = min(frames, samples.count / channels)
        guard count > 0 else { return }
        let reach = PeakLimiter.reach
        let ceilingValue = Float(ceiling)
        for frame in 0..<count {
            let slot = (written & ringMask) * channels
            var loudest: Float = 0
            for channel in 0..<channels {
                let value = samples[frame * channels + channel]
                ring[slot + channel] = value
                loudest = max(loudest, abs(value))
            }
            sinceHot = loudest >= threshold ? 0 : min(sinceHot + 1, Int.max / 2)
            // The frame that can be judged now: the points after it are estimated from the frames up to this one
            let judged = written - reach
            var peak: Float = 0
            if sinceHot < 2 * reach {
                for channel in 0..<channels {
                    peak = max(peak, abs(ring[((judged & ringMask) * channels) + channel]))
                    for taps in phases {
                        var value: Float = 0
                        for tap in 0..<(2 * reach) {
                            value += taps[tap] * ring[(((judged - (reach - 1) + tap) & ringMask) * channels) + channel]
                        }
                        peak = max(peak, abs(value))
                    }
                }
            }
            // What lies between the frame before it and the one after it
            let around = max(peak, lastPeak)
            lastPeak = peak
            let wanted = around > ceilingValue ? ceiling / Double(around) : 1
            quietRun = wanted < 1 ? 0 : min(quietRun + 1, Int.max / 2)
            var gain = 1.0
            if !(quietRun >= window && envelope == 1 && envelopesBelow == 0) {
                // The lowest gain wanted in the look-ahead: frames not noted (while all was quiet) wanted 1
                while lowCount > 0 && lowValues[(lowHead + lowCount - 1) % lowValues.count] >= wanted { lowCount -= 1 }
                let end = (lowHead + lowCount) % lowValues.count
                lowValues[end] = wanted
                lowFrames[end] = written
                lowCount += 1
                if lowFrames[lowHead] <= written - window {
                    lowHead = (lowHead + 1) % lowValues.count
                    lowCount -= 1
                }
                let lowest = lowValues[lowHead]
                // Down at once, up slowly
                if lowest < envelope {
                    envelope = lowest
                } else {
                    envelope += (lowest - envelope) * releaseStep
                    if 1 - envelope < PeakLimiter.settled && lowest == 1 { envelope = 1 }
                }
                // The mean over the look-ahead: the fall before a peak is a ramp, and at the peak every value in
                // it is at or below what the peak asks for
                let leaving = envelopes[envelopeAt]
                envelopes[envelopeAt] = envelope
                envelopeAt = (envelopeAt + 1) % window
                envelopeSum += envelope - leaving
                if leaving < 1 { envelopesBelow -= 1 }
                if envelope < 1 { envelopesBelow += 1 }
                if envelopesBelow == 0 {
                    // Exactly, so that no rounding is left over from the reduction
                    envelopeSum = Double(window)
                } else {
                    gain = min(1, envelopeSum / Double(window))
                    lowestGain = min(lowestGain, gain)
                }
            } else {
                lowCount = 0
            }
            let out = ((written - delay) & ringMask) * channels
            if gain == 1 {
                for channel in 0..<channels { samples[frame * channels + channel] = ring[out + channel] }
            } else {
                for channel in 0..<channels { samples[frame * channels + channel] = Float(Double(ring[out + channel]) * gain) }
            }
            written += 1
        }
    }
}
