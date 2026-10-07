//
//  SystemAudioTap.swift
//  Holdfast
//

import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import Synchronization

// System audio through a Core Audio process tap (macOS 14.2+). ScreenCaptureKit's system audio leaves out what the
// system process avconferenced plays, which is the audio of FaceTime calls and of iPhone calls taken on the Mac; a
// tap of every process hears it. `SystemAudioTap` is one tap with its aggregate device and IOProc; what clocks that
// device is a `TapClock`. `SystemAudioSource` (SystemAudioSource.swift) keeps one running for a recording and
// rebuilds it the moment it stops delivering.
//
// Nothing here is left behind when the process ends, a crash included: the tap is created private
// (`CATapDescription.isPrivate`) and so is the aggregate device (`kAudioAggregateDeviceIsPrivateKey`), and Core
// Audio's headers (AudioHardware.h, CATapDescription.h) say a private tap or aggregate device is visible only to the
// process that created it and is destroyed with that process. `stop` still destroys both as soon as they are not
// needed, and every path out of a recording calls it.

/// The Core Audio calls a tap is made of, so the order of building and tearing down can be tested without the
/// hardware (`CoreAudioTapHardware` is the real one). Every call that can fail throws `SystemAudioTapError`.
protocol TapHardware {
    /// Holdfast's own audio process object, nil when it has none (a process gets one once it uses audio)
    func ownProcessObject() -> AudioObjectID?
    /// The current default output device
    func defaultOutputDevice() throws -> TapOutputDevice
    /// The Mac's built-in output (its speakers), nil when it has none that is alive
    func builtInOutputDevice() -> TapOutputDevice?
    /// Whether the device with this UID is connected and alive
    func isAlive(deviceUID: String) -> Bool
    /// A private global stereo tap of every process but `excluded`, which leaves what it taps audible
    func createTap(excluding excluded: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String)
    /// `kAudioTapPropertyFormat`
    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription
    /// A private aggregate device with the tap as its sub-tap, drift compensated, and the output device `mainUID` as
    /// its main sub-device; with no sub-device at all when `mainUID` is nil
    func createAggregateDevice(name: String, uid: String, mainUID: String?, tapUID: String) throws -> AudioObjectID
    /// The device's nominal sample rate, nil when it cannot be read
    func nominalSampleRate(_ device: AudioObjectID) -> Double?
    func createIOProc(_ device: AudioObjectID, _ block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID
    /// How many streams the device has in its input (`input`) or output scope
    func streamCount(_ device: AudioObjectID, input: Bool) throws -> Int
    /// Which of the device's streams in the input or output scope the IOProc uses
    /// (`kAudioDevicePropertyIOProcStreamUsage`), one entry for each of them
    func setStreamUsage(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID, input: Bool, _ isOn: [Bool]) throws
    func startDevice(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws
    func stopDevice(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus
    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus
    func destroyAggregateDevice(_ device: AudioObjectID) -> OSStatus
    func destroyTap(_ tap: AudioObjectID) -> OSStatus
    /// Calls `changed` on `queue` when one of `selectors` of `object` changes; nil when it cannot be watched
    func watch(_ object: AudioObjectID, _ selectors: [AudioObjectPropertySelector], queue: DispatchQueue, _ changed: @escaping () -> Void) -> TapListener?
    func unwatch(_ listener: TapListener)
}

struct TapOutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// Listeners installed by `TapHardware.watch`, which `unwatch` removes. `queue` is the queue Core Audio calls them on.
final class TapListener {
    let object: AudioObjectID
    let entries: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)]
    let queue: DispatchQueue
    init(object: AudioObjectID, entries: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)], queue: DispatchQueue) {
        self.object = object
        self.entries = entries
        self.queue = queue
    }
}

/// A Core Audio call that failed, in words for the log and the notice
struct SystemAudioTapError: LocalizedError {
    let message: String
    init(_ step: String, _ status: OSStatus) {
        message = "\(step) failed (\(SystemAudioTapError.code(status)))"
    }
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// A four-character code where the status is one ('!obj'), the number otherwise
    static func code(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return "'\(String(decoding: bytes, as: UTF8.self))'" }
        return "\(status)"
    }
}

/// What clocks the private aggregate device a tap is in. Measured on the owner's Mac (Tools/tapexp.swift, in a
/// bundle with Holdfast's identity and permission): with the built-in output as the clock, with no sub-device at
/// all, and with the default output (AirPods) as the clock, the tap delivered the same ~94 buffers a second and heard
/// a sound played to the AirPods at the same level, also while another process held the AirPods' microphone with
/// voice processing. The tap follows the processes, not the device that clocks it. The default output is a poor
/// clock: AirPods change mode under a call (24 kHz), and an aggregate device clocked by them delivered nothing for a
/// whole 47-minute meeting. So the order is the built-in output, then no sub-device, then the default output last.
enum TapClock: String, Equatable, CaseIterable {
    /// The Mac's built-in output (its speakers, there in clamshell mode too), whatever the default output is
    case builtInOutput
    /// No sub-device: the tap alone
    case none
    /// The current default output device, the last resort
    case defaultOutput

    /// For the log
    var name: String {
        switch self {
        case .builtInOutput: return "the built-in output"
        case .none: return "no sub-device"
        case .defaultOutput: return "the default output"
        }
    }

    /// The constructions to try, best first: the built-in output when there is one, no sub-device, and the default
    /// output when it is another device than the built-in one
    static func order(builtIn: TapOutputDevice?, defaultOutput: TapOutputDevice?) -> [TapClock] {
        var order = [TapClock]()
        if builtIn != nil { order.append(.builtInOutput) }
        order.append(.none)
        if let output = defaultOutput, output.uid != builtIn?.uid { order.append(.defaultOutput) }
        return order
    }
}

/// One process tap: the tap, a private aggregate device clocked as `TapClock` says, and an IOProc that copies every
/// buffer into a `CMSampleBuffer` stamped on the host-time clock, the clock ScreenCaptureKit stamps its buffers with.
/// Built and started by `init`, torn down by `stop` (and by `deinit`), each once.
///
/// The IOProc uses only the tap's stream (`useTapStreamOnly`): an output device in the aggregate device is there for
/// its clock alone. The aggregate device runs from `AudioDeviceStart` on, delivering zeros while nothing plays, so
/// the track is continuous from the first moment (it is not made to wait for the first sound, which
/// `kAudioAggregateDeviceTapAutoStartKey` would do).
///
/// Threads: `init` and `stop` run on the thread of the owner (`SystemAudioSource`'s queue). The IOProc runs on Core
/// Audio's real-time IO thread and only copies the audio out of the IO buffer, stamps it and calls `deliver`.
final class SystemAudioTap: SystemAudioTapping {
    /// The name of the aggregate device. `MicSelection.getMicrophone` leaves it out: inside this process it is an
    /// input device like any.
    static let deviceName = "Holdfast System Audio"

    let clock: TapClock
    /// The device that clocks it, nil for `TapClock.none`
    let clockDevice: TapOutputDevice?
    /// What the IOProc delivers: the tap's format at the rate of the aggregate device
    let format: AudioStreamBasicDescription
    private let hardware: TapHardware
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let proc: AudioDeviceIOProcID
    private var listeners = [TapListener]()
    private var stopped = false

    /// Closed once the aggregate device or the device that clocks it has changed its rate, or that device has gone
    /// away: from then on the IOProc hands nothing on until the tap is rebuilt, since its buffers may come at the new
    /// rate and `format` still says the old one
    final class Gate: Sendable {
        private let closed = Atomic<Bool>(false)
        var isOpen: Bool { !closed.load(ordering: .acquiring) }
        func close() { closed.store(true, ordering: .releasing) }
    }

    /// Builds the tap clocked as `clock` says and starts it. `deliver` gets every buffer, on the IO thread;
    /// `outputChanged` is called when the rate changes or the clock's device goes away (AirPods switching to their
    /// call mode change their rate), which the tap must be rebuilt for. Throws, with everything it created destroyed
    /// again, when any step fails.
    init(hardware: TapHardware, clock: TapClock, queue: DispatchQueue, deliver: @escaping (CMSampleBuffer) -> Void, outputChanged: @escaping () -> Void) throws {
        self.hardware = hardware
        let gate = Gate()
        let own = hardware.ownProcessObject()
        let clockDevice: TapOutputDevice?
        switch clock {
        case .builtInOutput:
            guard let device = hardware.builtInOutputDevice() else { throw SystemAudioTapError("This Mac has no built-in output device") }
            clockDevice = device
        case .none:
            clockDevice = nil
        case .defaultOutput:
            clockDevice = try hardware.defaultOutputDevice()
        }
        let tap = try hardware.createTap(excluding: own.map { [$0] } ?? [])
        // Undone in reverse order when a later step fails
        var undo: [() -> Void] = [{ _ = hardware.destroyTap(tap.id) }]
        func fail(_ error: Error) -> Error {
            undo.reversed().forEach { $0() }
            return error
        }
        let format: AudioStreamBasicDescription
        let aggregate: AudioObjectID
        let proc: AudioDeviceIOProcID
        do {
            let tapFormat = try hardware.tapFormat(tap.id)
            let uid = "\(Bundle.main.bundleIdentifier ?? "Holdfast").systemaudio.\(UUID().uuidString)"
            aggregate = try hardware.createAggregateDevice(name: SystemAudioTap.deviceName, uid: uid, mainUID: clockDevice?.uid, tapUID: tap.uid)
            undo.append { _ = hardware.destroyAggregateDevice(aggregate) }
            format = try SystemAudioBuffers.ioFormat(tap: tapFormat, deviceRate: hardware.nominalSampleRate(aggregate))
            if format.mSampleRate != tapFormat.mSampleRate {
                RecLog.write("System audio tap: the tap's format is \(Int(tapFormat.mSampleRate)) Hz, the device's \(Int(format.mSampleRate)) Hz; the device's rate is used")
            }
            let description = try SystemAudioBuffers.formatDescription(format)
            proc = try hardware.createIOProc(aggregate) { _, input, inputTime, output, _ in
                // The aggregate device has its main device's output streams too, turned off for this IOProc (their
                // buffers are then NULL); should that have failed, nothing is played through them
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                guard gate.isOpen, let sample = SystemAudioBuffers.sampleBuffer(from: input, format: format, description: description,
                                                                    at: SystemAudioBuffers.presentationTime(of: inputTime.pointee, list: input, format: format)) else { return }
                deliver(sample)
            }
            undo.append { _ = hardware.destroyIOProc(aggregate, proc) }
            SystemAudioTap.useTapStreamOnly(hardware, aggregate, proc)
            try hardware.startDevice(aggregate, proc)
        } catch {
            throw fail(error)
        }
        self.clock = clock
        self.clockDevice = clockDevice
        self.format = format
        self.tap = tap.id
        self.aggregate = aggregate
        self.proc = proc
        // Only a real change is passed on: a notification that changed nothing must not rebuild the tap, which would
        // notify again. A real one stops the buffers at once, not only once the rebuild comes: AirPods switching to
        // their call mode deliver at half the rate, which `format` would label as the old one (double speed).
        let aggregateRate = hardware.nominalSampleRate(aggregate)
        let clockRate = clockDevice.flatMap { hardware.nominalSampleRate($0.id) }
        let changed = {
            let rateChanged = { (device: AudioObjectID, built: Double?) -> Bool in
                guard let now = hardware.nominalSampleRate(device), let built else { return false }
                return now != built
            }
            let gone = clockDevice.map { !hardware.isAlive(deviceUID: $0.uid) } ?? false
            if rateChanged(aggregate, aggregateRate) || clockDevice.map({ rateChanged($0.id, clockRate) }) == true || gone {
                gate.close()
                outputChanged()
            }
        }
        let selectors = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive]
        listeners = ([aggregate] + (clockDevice.map { [$0.id] } ?? [])).compactMap { hardware.watch($0, selectors, queue: queue, changed) }
    }

    /// Which of the aggregate device's streams its IOProc uses: of the input streams only the last, the tap's (the
    /// main device's own input streams come first), and none of the output streams
    static func streamUsage(streams: Int, input: Bool) -> [Bool] {
        return (0..<max(0, streams)).map { input && $0 == streams - 1 }
    }

    /// Turns off, for the IOProc, every stream of the aggregate device but the tap's, so the output device in it gives
    /// only the clock. Its input, the microphone of a headset or AirPods, is then not opened: an open microphone puts
    /// Bluetooth headphones in their narrowband call mode, for what the user hears too, and shows Holdfast as using
    /// the microphone. A failure is logged and the tap is used all the same.
    private static func useTapStreamOnly(_ hardware: TapHardware, _ aggregate: AudioObjectID, _ proc: AudioDeviceIOProcID) {
        for input in [true, false] {
            do {
                let streams = try hardware.streamCount(aggregate, input: input)
                guard streams > 0 else { continue }
                try hardware.setStreamUsage(aggregate, proc, input: input, streamUsage(streams: streams, input: input))
            } catch {
                RecLog.write("System audio tap: the output device's own \(input ? "input" : "output") streams stay on: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        stop()
    }

    /// What clocks it, for the log: `the built-in output "MacBook Pro Speakers"`, `no sub-device`
    var clockText: String { clockDevice.map { "\(clock.name) \"\($0.name)\"" } ?? clock.name }

    var formatText: String { SystemAudioBuffers.describe(format) }

    /// Stops the device, then destroys the IOProc, the aggregate device and the tap, in that order. Once: later calls
    /// do nothing. When it returns the IOProc is not called any more.
    func stop() {
        guard !stopped else { return }
        stopped = true
        listeners.forEach { hardware.unwatch($0) }
        listeners = []
        let steps: [(String, () -> OSStatus)] = [
            ("Stopping the device", { [hardware, aggregate, proc] in hardware.stopDevice(aggregate, proc) }),
            ("Destroying the IOProc", { [hardware, aggregate, proc] in hardware.destroyIOProc(aggregate, proc) }),
            ("Destroying the aggregate device", { [hardware, aggregate] in hardware.destroyAggregateDevice(aggregate) }),
            ("Destroying the tap", { [hardware, tap] in hardware.destroyTap(tap) }),
        ]
        for (step, call) in steps {
            let status = call()
            if status != noErr { RecLog.write("System audio tap: \(step) failed (\(SystemAudioTapError.code(status)))") }
        }
    }
}

// MARK: - Buffers

/// What the IOProc does with a buffer, and the formats involved. Pure, so the tests run it with buffers of their own.
enum SystemAudioBuffers {
    /// The format of the IO buffers: the tap's (channels, sample type, interleaving) at the aggregate device's rate,
    /// which is the main device's: drift compensation brings the tap to that clock. Throws for anything but linear PCM.
    static func ioFormat(tap: AudioStreamBasicDescription, deviceRate: Double?) throws -> AudioStreamBasicDescription {
        guard tap.mFormatID == kAudioFormatLinearPCM, tap.mChannelsPerFrame > 0, tap.mBytesPerFrame > 0, tap.mBitsPerChannel > 0 else {
            throw SystemAudioTapError("The tap delivers a format that cannot be recorded (\(describe(tap)))")
        }
        var format = tap
        if let rate = deviceRate, rate > 0 { format.mSampleRate = rate }
        guard format.mSampleRate > 0 else { throw SystemAudioTapError("The tap has no sample rate") }
        return format
    }

    static func isInterleaved(_ format: AudioStreamBasicDescription) -> Bool {
        return format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    /// "48000 Hz, 2 ch, float32 interleaved"
    static func describe(_ format: AudioStreamBasicDescription) -> String {
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(float ? "float" : "int")\(format.mBitsPerChannel) \(isInterleaved(format) ? "interleaved" : "non-interleaved")"
    }

    /// The format description of buffers in `format`, with a stereo or mono layout where it has two or one channels
    static func formatDescription(_ format: AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
        var asbd = format
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = format.mChannelsPerFrame == 2 ? kAudioChannelLayoutTag_Stereo
            : format.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Unknown | format.mChannelsPerFrame
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                                    layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let made = description else { throw SystemAudioTapError("Describing the tap's format", status) }
        return made
    }

    /// How many buffers of an AudioBufferList one stream in `format` takes
    static func bufferCount(_ format: AudioStreamBasicDescription) -> Int {
        return isInterleaved(format) ? 1 : Int(format.mChannelsPerFrame)
    }

    /// Frames in an IO buffer list, counted from the tap's buffers (the last ones of the list: an aggregate device
    /// lists its main device's input streams, if it has any, before its taps; those are turned off, their buffers
    /// NULL, and not looked at). Nil when the list does not hold the tap's stream in `format`.
    static func frames(in list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) -> Int? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = bufferCount(format)
        guard count > 0, buffers.count >= count, format.mBytesPerFrame > 0 else { return nil }
        let channels = isInterleaved(format) ? format.mChannelsPerFrame : 1
        var frames: Int?
        for index in (buffers.count - count)..<buffers.count {
            let buffer = buffers[index]
            guard buffer.mData != nil, buffer.mNumberChannels == channels, buffer.mDataByteSize % format.mBytesPerFrame == 0 else { return nil }
            let these = Int(buffer.mDataByteSize / format.mBytesPerFrame)
            if let known = frames, known != these { return nil }
            frames = these
        }
        guard let found = frames, found > 0 else { return nil }
        return found
    }

    /// When the first frame of an IO buffer list was played, on the host-time clock: the IO time stamp's host time
    /// (`mHostTime`, in host ticks). A time stamp without a valid host time is taken as just captured.
    static func presentationTime(of timeStamp: AudioTimeStamp, list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) -> CMTime {
        return presentationTime(of: timeStamp, frames: frames(in: list, format: format) ?? 0, rate: format.mSampleRate)
    }

    static func presentationTime(of timeStamp: AudioTimeStamp, frames: Int, rate: Double) -> CMTime {
        if timeStamp.mFlags.contains(.hostTimeValid) && timeStamp.mHostTime != 0 {
            return CMClockMakeHostTimeFromSystemUnits(timeStamp.mHostTime)
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard rate > 0, frames > 0 else { return now }
        return CMTimeSubtract(now, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate.rounded())))
    }

    /// A sample buffer holding a copy of the tap's audio in an IO buffer list, starting at `pts`. Nil when the list
    /// does not hold the tap's stream in `format`. Called on the IO thread: it allocates the copy and nothing else
    /// (an AudioBufferList as well only when the list has other streams in front of the tap's), and does not wait.
    static func sampleBuffer(from list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription,
                             description: CMAudioFormatDescription, at pts: CMTime) -> CMSampleBuffer? {
        guard pts.isValid, format.mSampleRate > 0, let frames = frames(in: list, format: format) else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.mSampleRate.rounded())),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var created: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: description, sampleCount: CMItemCount(frames),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &created) == noErr,
              let sampleBuffer = created else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = bufferCount(format)
        // Copies the audio into a block buffer of the sample buffer's own
        func copy(_ tapList: UnsafePointer<AudioBufferList>) -> Bool {
            return CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                                                                  blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                                  bufferList: tapList) == noErr
        }
        if buffers.count == count { return copy(list) ? sampleBuffer : nil }
        // Only the tap's buffers, the last ones
        let tapOnly = AudioBufferList.allocate(maximumBuffers: count)
        defer { free(tapOnly.unsafeMutablePointer) }
        for index in 0..<count { tapOnly[index] = buffers[buffers.count - count + index] }
        return copy(tapOnly.unsafePointer) ? sampleBuffer : nil
    }
}

/// Turns the tap's buffers into the format ScreenCaptureKit delivers system audio in, 48 kHz stereo 32-bit float with
/// one buffer per channel, so the writer and the monitor take them exactly like ScreenCaptureKit's. A buffer already
/// in that format is passed on as it is. Others are converted, resampled when their rate differs (an output device
/// at 44.1 kHz, AirPods in their call mode), and each converted buffer starts where the one before it ended as long
/// as that is within `tolerance` of its own time; otherwise, after a gap or once the device's clock has drifted that
/// far, it starts at its own time. Sample queue only.
final class SystemAudioConverter {
    static let sampleRate: Double = 48000
    static let tolerance: Double = 0.1

    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    /// Where the next converted buffer starts, and where the next input buffer is expected
    private var nextOutput = CMTime.invalid
    private var nextInput = CMTime.invalid

    init?() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: SystemAudioConverter.sampleRate, channels: 2) else { return nil }
        outputFormat = format
    }

    /// Whether buffers in `format` go on as they are
    static func isDelivered(as format: AudioStreamBasicDescription) -> Bool {
        return format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == sampleRate && format.mChannelsPerFrame == 2
            && format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    }

    /// Forgets the timeline and the resampler's state: the next buffer comes from another device
    func reset() {
        converter = nil
        inputFormat = nil
        nextOutput = .invalid
        nextInput = .invalid
    }

    /// The buffer in the delivered format, nil when there is nothing to hand on yet (a resampler that is filling up)
    /// or it cannot be converted
    func convert(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let description = sampleBuffer.formatDescription, let asbd = description.audioStreamBasicDescription else { return nil }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isValid else { return nil }
        if SystemAudioConverter.isDelivered(as: asbd) {
            reset()
            return sampleBuffer
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        if converter == nil || inputFormat != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
            inputFormat = format
            nextOutput = .invalid
            nextInput = .invalid
        }
        guard let converter = converter else { return nil }
        let inputFrames = sampleBuffer.numSamples
        let follows = nextInput.isValid && abs(CMTimeGetSeconds(CMTimeSubtract(pts, nextInput))) <= SystemAudioConverter.tolerance
        if !follows { converter.reset() }
        nextInput = CMTimeAdd(pts, CMTime(value: CMTimeValue(inputFrames), timescale: CMTimeScale(format.sampleRate.rounded())))
        var start = pts
        if follows, nextOutput.isValid, abs(CMTimeGetSeconds(CMTimeSubtract(nextOutput, pts))) <= SystemAudioConverter.tolerance {
            start = nextOutput
        }
        let outputRate = SystemAudioConverter.sampleRate
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
            return status == .error ? nil : output
        }
        guard let output = converted else { return nil }
        nextOutput = start
        guard output.frameLength > 0,
              let buffer = AudioSilence.sampleBuffer(from: output, description: outputFormat.formatDescription, at: start) else { return nil }
        nextOutput = CMTimeAdd(start, CMTime(value: CMTimeValue(output.frameLength), timescale: CMTimeScale(outputRate)))
        return buffer
    }
}

// MARK: - The hardware

/// The Core Audio calls behind `SystemAudioTap`
struct CoreAudioTapHardware: TapHardware {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Where Core Audio calls the listeners, which only pass the change on to the queue they were given: a listener is
    /// removed on that queue, and never has to wait for a listener running on it
    private static let listenerQueue = DispatchQueue(label: "Holdfast.systemAudioTap.listeners")

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard read(object, selector, &value) == noErr, let found = value else { return nil }
        return found.takeRetainedValue() as String
    }

    func ownProcessObject() -> AudioObjectID? {
        var address = CoreAudioTapHardware.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(CoreAudioTapHardware.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    func defaultOutputDevice() throws -> TapOutputDevice {
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = CoreAudioTapHardware.read(CoreAudioTapHardware.system, kAudioHardwarePropertyDefaultOutputDevice, &device)
        guard status == noErr else { throw SystemAudioTapError("Reading the default output device", status) }
        guard device != AudioObjectID(kAudioObjectUnknown), let uid = CoreAudioTapHardware.string(device, kAudioDevicePropertyDeviceUID) else {
            throw SystemAudioTapError("There is no output device")
        }
        return TapOutputDevice(id: device, uid: uid, name: CoreAudioTapHardware.string(device, kAudioObjectPropertyName) ?? uid)
    }

    func builtInOutputDevice() -> TapOutputDevice? {
        var address = CoreAudioTapHardware.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(CoreAudioTapHardware.system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CoreAudioTapHardware.system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        var found = [TapOutputDevice]()
        for device in devices {
            var transport: UInt32 = 0
            guard CoreAudioTapHardware.read(device, kAudioDevicePropertyTransportType, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn,
                  ((try? streamCount(device, input: false)) ?? 0) > 0,
                  let uid = CoreAudioTapHardware.string(device, kAudioDevicePropertyDeviceUID), isAlive(deviceUID: uid) else { continue }
            found.append(TapOutputDevice(id: device, uid: uid, name: CoreAudioTapHardware.string(device, kAudioObjectPropertyName) ?? uid))
        }
        // The speakers rather than a headphone jack, which comes and goes with the headphones
        return found.first { $0.uid.localizedCaseInsensitiveContains("speaker") } ?? found.first { $0.name.localizedCaseInsensitiveContains("speaker") } ?? found.first
    }

    func isAlive(deviceUID: String) -> Bool {
        var address = CoreAudioTapHardware.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = deviceUID as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(CoreAudioTapHardware.system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return false }
        var alive: UInt32 = 0
        return CoreAudioTapHardware.read(device, kAudioDevicePropertyDeviceIsAlive, &alive) == noErr && alive != 0
    }

    func createTap(excluding excluded: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String) {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = SystemAudioTap.deviceName
        description.isPrivate = true
        // What is tapped stays audible
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else { throw SystemAudioTapError("Creating the process tap", status) }
        guard let uid = CoreAudioTapHardware.string(tap, kAudioTapPropertyUID) else {
            _ = AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioTapError("Reading the tap's UID")
        }
        return (tap, uid)
    }

    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        let status = CoreAudioTapHardware.read(tap, kAudioTapPropertyFormat, &format)
        guard status == noErr else { throw SystemAudioTapError("Reading the tap's format", status) }
        return format
    }

    func createAggregateDevice(name: String, uid: String, mainUID: String?, tapUID: String) throws -> AudioObjectID {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // No kAudioAggregateDeviceTapAutoStartKey: with it the start waits for the first sound a tapped process
            // plays, and a recording started in silence would get no system audio until then
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let mainUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = mainUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: mainUID]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { throw SystemAudioTapError("Creating the aggregate device", status) }
        return device
    }

    func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var rate: Float64 = 0
        guard CoreAudioTapHardware.read(device, kAudioDevicePropertyNominalSampleRate, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    func createIOProc(_ device: AudioObjectID, _ block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID {
        var proc: AudioDeviceIOProcID?
        // No queue: the block runs on the device's IO thread
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, block)
        guard status == noErr, let made = proc else { throw SystemAudioTapError("Creating the IOProc", status) }
        return made
    }

    func streamCount(_ device: AudioObjectID, input: Bool) throws -> Int {
        var address = CoreAudioTapHardware.address(kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else { throw SystemAudioTapError("Reading the aggregate device's streams", status) }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    func setStreamUsage(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID, input: Bool, _ isOn: [Bool]) throws {
        // AudioHardwareIOProcStreamUsage: the IOProc, the number of streams, then a UInt32 for each stream
        typealias Usage = AudioHardwareIOProcStreamUsage
        guard let procOffset = MemoryLayout<Usage>.offset(of: \Usage.mIOProc),
              let countOffset = MemoryLayout<Usage>.offset(of: \Usage.mNumberStreams),
              let flagsOffset = MemoryLayout<Usage>.offset(of: \Usage.mStreamIsOn) else {
            throw SystemAudioTapError("The stream usage cannot be described")
        }
        let size = max(MemoryLayout<Usage>.size, flagsOffset + isOn.count * MemoryLayout<UInt32>.size)
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<Usage>.alignment)
        defer { usage.deallocate() }
        usage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        usage.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), toByteOffset: procOffset, as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(isOn.count), toByteOffset: countOffset, as: UInt32.self)
        for (index, on) in isOn.enumerated() {
            usage.storeBytes(of: on ? 1 : 0, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = CoreAudioTapHardware.address(kAudioDevicePropertyIOProcStreamUsage, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage)
        guard status == noErr else { throw SystemAudioTapError("Setting the IOProc's stream usage", status) }
    }

    func startDevice(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws {
        let status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw SystemAudioTapError("Starting the aggregate device", status) }
    }

    func stopDevice(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        return AudioDeviceStop(device, proc)
    }

    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        return AudioDeviceDestroyIOProcID(device, proc)
    }

    func destroyAggregateDevice(_ device: AudioObjectID) -> OSStatus {
        return AudioHardwareDestroyAggregateDevice(device)
    }

    func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        return AudioHardwareDestroyProcessTap(tap)
    }

    func watch(_ object: AudioObjectID, _ selectors: [AudioObjectPropertySelector], queue: DispatchQueue, _ changed: @escaping () -> Void) -> TapListener? {
        var entries = [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)]()
        for selector in selectors {
            var address = CoreAudioTapHardware.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in queue.async { changed() } }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, CoreAudioTapHardware.listenerQueue, block)
            if status == noErr {
                entries.append((address, block))
            } else {
                RecLog.write("System audio tap: cannot watch property \(SystemAudioTapError.code(Int32(bitPattern: selector))) (\(SystemAudioTapError.code(status)))")
            }
        }
        return entries.isEmpty ? nil : TapListener(object: object, entries: entries, queue: CoreAudioTapHardware.listenerQueue)
    }

    func unwatch(_ listener: TapListener) {
        for entry in listener.entries {
            var address = entry.address
            _ = AudioObjectRemovePropertyListenerBlock(listener.object, &address, listener.queue, entry.block)
        }
    }
}
