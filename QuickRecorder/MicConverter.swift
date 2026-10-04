//
//  MicConverter.swift
//  QuickRecorder
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

    init?() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(MicConverter.sampleRate), channels: 2, interleaved: true) else { return nil }
        outputFormat = format
    }

    /// Starts the timeline at the writer session's start time, so a microphone that delivers late is padded with silence
    func start(at pts: CMTime) {
        if !nextPTS.isValid { nextPTS = CMTimeConvertScale(pts, timescale: MicConverter.sampleRate, method: .default) }
    }

    /// How far the track is behind `pts`, in seconds. Zero before the timeline has started.
    func lag(behind pts: CMTime) -> Double {
        guard nextPTS.isValid, pts.isValid else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(pts, nextPTS))
    }

    /// Converts one microphone buffer whose (pause adjusted) start time is `pts` and hands the result to `append`,
    /// which returns false when the writer did not take the buffer. Returns true when the buffer's audio was written.
    ///
    /// The writer plays audio buffers back to back whatever their timestamps say, so missing samples (a device
    /// switch, a buffer the writer was not ready for) are written as silence to keep the track in sync.
    @discardableResult
    func convert(_ sampleBuffer: CMSampleBuffer, at pts: CMTime, append: (CMSampleBuffer) -> Bool) -> Bool {
        let start = CMTimeConvertScale(pts, timescale: MicConverter.sampleRate, method: .default)
        guard start.isValid else { return false }
        if nextPTS.isValid {
            let missing = CMTimeSubtract(start, nextPTS).value
            if missing > tolerance {
                guard writeSilence(frames: min(missing, longestFill), append: append) else { return false }
                // Still behind after a long hole: keep filling on the next buffers before audio is written again
                if missing > longestFill { return false }
            } else if missing < -tolerance {
                // The device delivered more samples than time has passed: drop until the timeline catches up
                return false
            }
        } else {
            nextPTS = start
        }
        guard let converted = resample(sampleBuffer), let buffer = makeSampleBuffer(from: converted), append(buffer) else { return false }
        advance(by: Int64(converted.frameLength))
        var peak: Float = 0
        if let samples = converted.floatChannelData {
            // Interleaved: one buffer holds every channel
            vDSP_maxmgv(samples[0], 1, &peak, vDSP_Length(converted.frameLength) * vDSP_Length(outputFormat.channelCount))
        }
        lastPeak = peak
        return true
    }

    /// Writes silence from the end of the track up to `pts`, when at least `frames` are missing.
    /// Used while the microphone delivers nothing and to bring the track to full length when the recording stops.
    func fill(upTo pts: CMTime, atLeast frames: Int64 = 1, append: (CMSampleBuffer) -> Bool) {
        let end = CMTimeConvertScale(pts, timescale: MicConverter.sampleRate, method: .default)
        guard nextPTS.isValid, end.isValid else { return }
        let missing = CMTimeSubtract(end, nextPTS).value
        if missing >= max(frames, 1) { _ = writeSilence(frames: missing, append: append) }
    }

    /// Returns false when the writer stopped taking buffers before all of it was written
    private func writeSilence(frames: Int64, append: (CMSampleBuffer) -> Bool) -> Bool {
        var left = frames
        while left > 0 {
            let count = min(left, silenceChunk)
            guard let silent = silence(frames: count), append(silent) else { return false }
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
            if let old = inputFormat { print("Microphone format changed from \(old) to \(format)") }
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
                print("Microphone conversion failed: \(String(describing: error))")
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
