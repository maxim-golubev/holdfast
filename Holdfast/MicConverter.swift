//
//  MicConverter.swift
//  Holdfast
//

import AVFoundation
import Accelerate

/// The one place silent audio is made, for the microphone track and the system audio track alike
enum AudioSilence {
    /// `frames` of silence in `format`
    static func pcm(format: AVAudioFormat, frames: Int64) -> AVAudioPCMBuffer? {
        guard frames > 0, frames <= Int64(UInt32.max) else { return nil }
        let count = AVAudioFrameCount(frames)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        pcm.frameLength = count
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return pcm
    }

    /// Wraps PCM audio in a sample buffer that starts at `pts`. `description` must describe the format of `pcm`.
    static func sampleBuffer(from pcm: AVAudioPCMBuffer, description: CMAudioFormatDescription, at pts: CMTime) -> CMSampleBuffer? {
        let rate = pcm.format.sampleRate
        guard rate > 0, pts.isValid else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var created: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &created
        ) == noErr, let sampleBuffer = created else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

/// Turns the microphone buffers ScreenCaptureKit delivers into one fixed format on a continuous timeline.
///
/// The buffers arrive in the device's own format (24 kHz mono for AirPods, for example), and that format changes when the
/// device changes. The writer input is only ever given 48 kHz stereo with timestamps that never go backwards, so
/// neither a format change nor a jump in the device's timestamps can make the writer fail.
/// Not thread safe: use it from the capture queue only.
final class MicConverter {
    static let sampleRate: Int32 = 48000

    private let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Where the next sample goes on the writer's timeline
    private var nextPTS = CMTime.invalid
    /// End of the track on the writer's timeline, invalid before it has started
    var end: CMTime { nextPTS }
    /// Largest sample magnitude of the last buffer `convert` wrote. Exactly zero for digital silence.
    private(set) var lastPeak: Float = 0
    /// How far the device's timestamps may drift from the sample count before the timeline is corrected, in frames
    private let tolerance = Int64(MicConverter.sampleRate / 10)
    private let silenceChunk = Int64(MicConverter.sampleRate / 2)
    /// Silence written per incoming buffer at most, to bound the work done in one callback
    private let longestFill = Int64(MicConverter.sampleRate * 10)
    /// Set where the timeline is anchored anew (the start of the session, after silence that was not measured from
    /// a buffer, a resume). The next buffer is then placed at its own time to the sample, not within the tolerance,
    /// or the track would keep an offset of up to 0.1 s against the others from there on.
    private var aligning = false
    /// Added to the time of every buffer. Zero unless the microphone's buffers kept arriving for a time the track
    /// has already passed; see `convert`.
    private var shift = CMTime.zero
    /// The buffers that arrived behind the end of the track since the last one written, nil while there are none
    private var late: LateRun?
    /// How much is dropped before a microphone whose arrival times are not known is taken to lag
    private let longestDrop: Double = 1
    /// Seconds of arrivals over which the age of late buffers must hold steady before they are taken to lag
    static let steadyWindow: Double = 2
    /// How far the age of late buffers may vary within `steadyWindow`, and how fast it may fall over a whole run,
    /// and still count as steady (`LateRun`)
    static let steadyRange = LateRun.steadyRange
    static let steadyFall = LateRun.steadyFall

    // The buffers that lie before the end of the track are a backlog, which is dropped, or come from a microphone
    // whose clock lags, and are shifted to the end of the track: see `LateRun`, which tells them apart.
    //
    // Neither is what moved the owner's FaceTime call 11 s late. There the end of the track itself had run ahead:
    // a buffer of another source stamped about 12 s in the future as the call connected moved the monitor's
    // present, the monitor filled the microphone that far, and the microphone's buffers, on time, then lay 11 s
    // "behind" it and were shifted. What keeps that from happening is that nothing on the timeline may end after
    // the present (`MovieWriter.endsByPresent`, `ArrivalCheck`); with it, such buffers are never late.

    /// What happened to the microphone during this recording, for the log
    private(set) var buffersIn = 0
    private(set) var buffersWritten = 0
    private(set) var buffersDropped = 0
    private(set) var buffersFailed = 0
    private(set) var buffersAllZero = 0
    private(set) var framesWritten: Int64 = 0
    private(set) var silenceFrames: Int64 = 0
    private(set) var formatChanges = 0
    private(set) var loudestPeak: Float = 0
    /// Seconds of audio in buffers dropped because they arrived behind the end of the track
    private(set) var lateSecondsDropped: Double = 0
    /// How many times late buffers were taken for a lagging clock and the timeline was shifted
    private(set) var shifts = 0

    var summary: String {
        let rate = Double(MicConverter.sampleRate)
        let format = inputFormat.map { "\(Int($0.sampleRate)) Hz x\($0.channelCount)" } ?? "none"
        return String(format: "microphone: %d buffers in, %d written (%.1f s of audio), %d dropped, %d failed, %d all-zero, %.1f s of silence filled, %d format changes, loudest peak %.1f dBFS, last device format %@",
                      buffersIn, buffersWritten, Double(framesWritten) / rate, buffersDropped, buffersFailed, buffersAllZero,
                      Double(silenceFrames) / rate, formatChanges, loudestPeak > 0 ? 20 * log10(Double(loudestPeak)) : -180, format)
    }

    init?() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(MicConverter.sampleRate), channels: 2, interleaved: true) else { return nil }
        outputFormat = format
    }

    /// Starts the timeline at the writer session's start time, so a microphone that delivers late is padded with silence
    func start(at pts: CMTime) {
        guard !nextPTS.isValid else { return }
        nextPTS = CMTimeConvertScale(pts, timescale: MicConverter.sampleRate, method: .default)
        aligning = true
    }

    /// The next buffer is placed at its own time exactly. For a point where the timeline is put together anew.
    func realign() {
        aligning = true
        endLateRun()
    }

    /// Converts one microphone buffer whose (pause adjusted) start time is `pts` and hands the result to `append`,
    /// which returns false when the writer did not take the buffer. Returns true when the buffer's audio was written.
    ///
    /// The writer plays audio buffers back to back whatever their timestamps say, so missing samples (a device
    /// switch, a buffer the writer was not ready for) are written as silence to keep the track in sync.
    ///
    /// A buffer that lies more than the tolerance before the end of the track is dropped: silence was written in its
    /// place while it was held up, or the device delivered more samples than time has passed. `arrival` is when the
    /// buffer reached the app, on the clock of `pts` (pause adjusted the same way), and tells a backlog from a
    /// microphone whose clock lags (see `LateRun`). While the late buffers' age falls (a backlog draining), varies,
    /// or the late audio adds up to less than the time it lies behind, they are dropped and the timeline stays as it
    /// is: the first buffer after a backlog sits at its own time. Only buffers that keep arriving at real-time pace,
    /// still behind, are taken to come from a clock that lags: dropping them would leave the track silent for the
    /// rest of the recording, so from then on they go at the end of the track (`shift`), late by that lag but
    /// recorded. The shift is given back as soon as the buffers are ahead of the track again. Without an arrival
    /// time the shift comes after `longestDrop` of late audio.
    @discardableResult
    func convert(_ sampleBuffer: CMSampleBuffer, at pts: CMTime, arrival: CMTime = .invalid, append: (CMSampleBuffer) -> Bool) -> Bool {
        buffersIn += 1
        var start = CMTimeConvertScale(CMTimeAdd(pts, shift), timescale: MicConverter.sampleRate, method: .default)
        guard start.isValid else { buffersFailed += 1; return false }
        // Frames to leave out at the front of this buffer, so that what follows starts exactly at the end of the track
        var skip: Int64 = 0
        if nextPTS.isValid {
            var missing = CMTimeSubtract(start, nextPTS).value
            if missing > tolerance && shift > .zero {
                // The buffers are no longer behind: take back as much of the shift as there is room for
                let back = min(shift, CMTime(value: missing, timescale: MicConverter.sampleRate))
                shift = CMTimeSubtract(shift, back)
                start = CMTimeSubtract(start, back)
                missing = CMTimeSubtract(start, nextPTS).value
            }
            if missing > tolerance {
                guard writeSilence(frames: min(missing, longestFill), append: append) else { buffersFailed += 1; return false }
                // Still behind after a long hole: keep filling on the next buffers before audio is written again
                if missing > longestFill { buffersDropped += 1; return false }
            } else if missing < -tolerance {
                let lag = CMTimeSubtract(nextPTS, start)
                guard lateBufferIsShifted(sampleBuffer, at: pts, arrival: arrival, lag: lag) else { buffersDropped += 1; return false }
                shift = CMTimeAdd(shift, lag)
            } else if aligning, missing > 0 {
                guard writeSilence(frames: missing, append: append) else { buffersFailed += 1; return false }
            } else if aligning, missing < 0 {
                skip = -missing
            }
        } else {
            nextPTS = start
        }
        guard var converted = resample(sampleBuffer) else { buffersFailed += 1; return false }
        if skip > 0 {
            // A buffer that ends before the end of the track has nothing to write; the next one is tried the same way
            guard let rest = MicConverter.dropping(skip, from: converted) else { buffersDropped += 1; return false }
            converted = rest
        }
        guard let buffer = makeSampleBuffer(from: converted), append(buffer) else { buffersFailed += 1; return false }
        buffersWritten += 1
        framesWritten += Int64(converted.frameLength)
        aligning = false
        endLateRun()
        advance(by: Int64(converted.frameLength))
        var peak: Float = 0
        if let samples = converted.floatChannelData {
            // Interleaved: one buffer holds every channel
            vDSP_maxmgv(samples[0], 1, &peak, vDSP_Length(converted.frameLength) * vDSP_Length(outputFormat.channelCount))
        }
        lastPeak = peak
        if peak == 0 { buffersAllZero += 1 }
        loudestPeak = max(loudestPeak, peak)
        return true
    }

    /// Counts a buffer that lies `lag` behind the end of the track and decides what becomes of it: false when it is
    /// dropped, true when the timeline is shifted by `lag` so that it goes at the end of the track. Logs the shift.
    private func lateBufferIsShifted(_ sampleBuffer: CMSampleBuffer, at pts: CMTime, arrival: CMTime, lag: CMTime) -> Bool {
        let duration = CMTimeGetSeconds(sampleBuffer.duration)
        let length = duration.isFinite && duration > 0 ? duration : 0.02
        let lagSeconds = CMTimeGetSeconds(lag)
        var run = late ?? LateRun(span: lagSeconds, window: MicConverter.steadyWindow)
        run.buffers += 1
        run.audio += length
        let shifted: Bool
        if arrival.isValid {
            run.note(arrival: CMTimeGetSeconds(arrival), age: CMTimeGetSeconds(CMTimeSubtract(arrival, pts)) - length)
            shifted = run.isSteady && run.audio >= run.span
        } else {
            shifted = run.audio > longestDrop
        }
        guard shifted else {
            late = run
            return false
        }
        // This buffer is written at the end of the track; the ones before it were dropped
        let dropped = run.audio - length
        lateSecondsDropped += dropped
        shifts += 1
        late = nil
        if let age = run.lastAge {
            RecLog.write(String(format: "Microphone buffers are %.2f s behind the recording and keep arriving at real-time pace, each %.2f s after its time: the microphone's clock lags. They are recorded that much late from here on (%.2f s of late audio dropped before)", lagSeconds, age, dropped))
        } else {
            RecLog.write(String(format: "Microphone buffers are %.2f s behind the recording (their arrival times are not known); they are recorded that much late from here on (%.2f s of late audio dropped before)", lagSeconds, dropped))
        }
        return true
    }

    /// The late buffers were followed by one at its own time: they were dropped and the timeline did not move
    private func endLateRun() {
        guard let run = late else { return }
        late = nil
        lateSecondsDropped += run.audio
        // Less than a quarter of a second is a hiccup, not worth a line
        guard run.audio >= 0.25 else { return }
        var ages = ""
        if let first = run.firstAge, let last = run.lastAge {
            ages = String(format: ", arriving %.2f s to %.2f s after their time", first, last)
        }
        RecLog.write(String(format: "Microphone backlog: %d buffers (%.2f s of audio) came in late%@, and were dropped, as silence had been written in their place; the microphone goes on at its own time", run.buffers, run.audio, ages))
    }

    /// Writes silence from the end of the track up to `pts`, when at least `frames` are missing.
    /// Used while the microphone delivers nothing and to bring the track to full length when the recording stops.
    func fill(upTo pts: CMTime, atLeast frames: Int64 = 1, append: (CMSampleBuffer) -> Bool) {
        let end = CMTimeConvertScale(pts, timescale: MicConverter.sampleRate, method: .default)
        guard nextPTS.isValid, end.isValid else { return }
        let missing = CMTimeSubtract(end, nextPTS).value
        guard missing >= max(frames, 1) else { return }
        _ = writeSilence(frames: missing, append: append)
        // The end of the track is now a time no buffer was measured against
        aligning = true
    }

    /// `pcm` without its first `frames` frames, nil when nothing is left. Interleaved audio only, which is what `resample` makes.
    private static func dropping(_ frames: Int64, from pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let total = Int64(pcm.frameLength)
        guard frames < total, pcm.format.isInterleaved else { return nil }
        let kept = AVAudioFrameCount(total - frames)
        guard let rest = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: kept) else { return nil }
        rest.frameLength = kept
        let frameBytes = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        guard frameBytes > 0, let source = pcm.audioBufferList.pointee.mBuffers.mData,
              let target = rest.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
        memcpy(target, source + Int(frames) * frameBytes, Int(kept) * frameBytes)
        return rest
    }

    /// Returns false when the writer stopped taking buffers before all of it was written
    private func writeSilence(frames: Int64, append: (CMSampleBuffer) -> Bool) -> Bool {
        var left = frames
        while left > 0 {
            let count = min(left, silenceChunk)
            guard let silent = silence(frames: count), append(silent) else { return false }
            silenceFrames += count
            advance(by: count)
            left -= count
        }
        return true
    }

    private func advance(by frames: Int64) {
        nextPTS = CMTimeAdd(nextPTS, CMTime(value: frames, timescale: MicConverter.sampleRate))
    }

    private func resample(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription, description.mediaType == .audio else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        if converter == nil || inputFormat != format {
            if let old = inputFormat {
                formatChanges += 1
                RecLog.write("Microphone format changed from \(old) to \(format)")
            }
            converter = AVAudioConverter(from: format, to: outputFormat)
            inputFormat = format
        }
        guard let converter = converter else { return nil }
        let outputRate = Double(MicConverter.sampleRate)
        let converted = try? sampleBuffer.withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return nil }
            let capacity = AVAudioFrameCount((Double(input.frameLength) * outputRate / format.sampleRate).rounded(.up)) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            // .noDataNow (rather than .endOfStream) keeps the resampler's state for the next buffer
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                RecLog.write("Microphone conversion failed: \(String(describing: error))")
                return nil
            }
            return output
        }
        guard let output = converted, output.frameLength > 0 else { return nil }
        return output
    }

    private func silence(frames: Int64) -> CMSampleBuffer? {
        guard let pcm = AudioSilence.pcm(format: outputFormat, frames: frames) else { return nil }
        return makeSampleBuffer(from: pcm)
    }

    /// Wraps converted audio in a sample buffer placed at the end of the timeline
    private func makeSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        return AudioSilence.sampleBuffer(from: pcm, description: outputFormat.formatDescription, at: nextPTS)
    }
}
