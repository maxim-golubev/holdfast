//
//  MicConverter.swift
//  QuickRecorder
//

import AVFoundation

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

    /// Converts one microphone buffer whose (pause adjusted) start time is `pts` and hands the result to `append`,
    /// which returns false when the writer did not take the buffer.
    ///
    /// The writer plays audio buffers back to back whatever their timestamps say, so missing samples (a device
    /// switch, a buffer the writer was not ready for) are written as silence to keep the track in sync.
    func convert(_ sampleBuffer: CMSampleBuffer, at pts: CMTime, append: (CMSampleBuffer) -> Bool) {
        let start = CMTimeConvertScale(pts, timescale: MicConverter.sampleRate, method: .default)
        guard start.isValid else { return }
        if nextPTS.isValid {
            var missing = CMTimeSubtract(start, nextPTS).value
            if missing > tolerance {
                var filled: Int64 = 0
                while missing > 0 && filled < longestFill {
                    let count = min(missing, silenceChunk)
                    guard let silent = silence(frames: count), append(silent) else { return }
                    advance(by: count)
                    missing -= count
                    filled += count
                }
                // Still behind after a long hole: keep filling on the next buffers before audio is written again
                if missing > 0 { return }
            } else if missing < -tolerance {
                // The device delivered more samples than time has passed: drop until the timeline catches up
                return
            }
        } else {
            nextPTS = start
        }
        guard let converted = resample(sampleBuffer), let buffer = makeSampleBuffer(from: converted), append(buffer) else { return }
        advance(by: Int64(converted.frameLength))
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
        let count = AVAudioFrameCount(frames)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: count) else { return nil }
        pcm.frameLength = count
        let buffer = pcm.audioBufferList.pointee.mBuffers
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        return makeSampleBuffer(from: pcm)
    }

    /// Wraps converted audio in a sample buffer placed at the end of the timeline
    private func makeSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: MicConverter.sampleRate),
            presentationTimeStamp: nextPTS,
            decodeTimeStamp: .invalid
        )
        var created: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: outputFormat.formatDescription,
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
