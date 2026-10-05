//
//  SystemAudioTests.swift
//  System audio through a Core Audio process tap, without Core Audio: the tap's build and teardown against fake
//  hardware, its IOProc fed with buffer lists made here, the conversion to ScreenCaptureKit's format, the choice
//  between the tap and ScreenCaptureKit, and the rebuild when the output device changes, with fake taps.
//

import AVFoundation
import CoreAudio
import Foundation

/// Core Audio as `SystemAudioTap` uses it, taking notes. `failing` makes that step fail.
final class FakeTapHardware: TapHardware {
    let journal: Journal
    var failing: String?
    var output = TapOutputDevice(id: 40, uid: "speakers-uid", name: "Speakers")
    var own: AudioObjectID? = 77
    var format: AudioStreamBasicDescription
    var deviceRate: Double? = nil
    var alive = true
    /// The aggregate device's input and output streams
    var streams = (input: 1, output: 2)
    /// The IOProc's stream usage that was set, by scope (true: input)
    private(set) var usage = [Bool: [Bool]]()
    /// The IOProc the tap installed, to be called as Core Audio would
    private(set) var ioBlock: AudioDeviceIOBlock?
    private(set) var excluded = [AudioObjectID]()
    private(set) var aggregateMain: String?
    private(set) var aggregateTap: String?
    private(set) var watched: (() -> Void)?

    init(_ journal: Journal, format: AudioStreamBasicDescription) {
        self.journal = journal
        self.format = format
    }

    private func step(_ name: String) throws {
        if failing == name { throw SystemAudioTapError(name, -50) }
        journal.note(name)
    }

    func ownProcessObject() -> AudioObjectID? { own }
    func defaultOutputDevice() throws -> TapOutputDevice {
        if failing == "output" { throw SystemAudioTapError("There is no output device") }
        return output
    }
    func isAlive(deviceUID: String) -> Bool { alive }
    func createTap(excluding excluded: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String) {
        try step("createTap")
        self.excluded = excluded
        return (100, "tap-uid")
    }
    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        if failing == "tapFormat" { throw SystemAudioTapError("Reading the tap's format", -50) }
        return format
    }
    func createAggregateDevice(name: String, uid: String, mainUID: String, tapUID: String) throws -> AudioObjectID {
        try step("createAggregate")
        aggregateMain = mainUID
        aggregateTap = tapUID
        return 200
    }
    func nominalSampleRate(_ device: AudioObjectID) -> Double? { deviceRate }
    func createIOProc(_ device: AudioObjectID, _ block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID {
        try step("createIOProc")
        ioBlock = block
        let proc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in 0 }
        return proc
    }
    func streamCount(_ device: AudioObjectID, input: Bool) throws -> Int {
        if failing == "streams" { throw SystemAudioTapError("Reading the aggregate device's streams", -50) }
        return input ? streams.input : streams.output
    }
    func setStreamUsage(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID, input: Bool, _ isOn: [Bool]) throws {
        try step(input ? "usage in" : "usage out")
        usage[input] = isOn
    }
    func startDevice(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws { try step("start") }
    func stopDevice(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus { journal.note("stop"); return noErr }
    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus { journal.note("destroyIOProc"); return noErr }
    func destroyAggregateDevice(_ device: AudioObjectID) -> OSStatus { journal.note("destroyAggregate"); return noErr }
    func destroyTap(_ tap: AudioObjectID) -> OSStatus { journal.note("destroyTap"); return noErr }
    func watch(_ object: AudioObjectID, _ selectors: [AudioObjectPropertySelector], queue: DispatchQueue, _ changed: @escaping () -> Void) -> TapListener? {
        journal.note("watch")
        watched = changed
        return TapListener(object: object, entries: [], queue: queue)
    }
    func unwatch(_ listener: TapListener) { journal.note("unwatch") }

    /// Calls the IOProc with `input` as the input buffers at the host time `host` (0: no valid host time), and an
    /// output buffer full of ones; returns whether the IOProc cleared the output
    @discardableResult
    func runIO(_ input: UnsafePointer<AudioBufferList>, host: UInt64) -> Bool {
        guard let block = ioBlock else { return false }
        var now = AudioTimeStamp()
        var inputTime = AudioTimeStamp()
        inputTime.mHostTime = host
        if host != 0 { inputTime.mFlags = .hostTimeValid }
        var outputTime = AudioTimeStamp()
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(output.unsafeMutablePointer) }
        var ones = [Float](repeating: 1, count: 64)
        return ones.withUnsafeMutableBytes { bytes -> Bool in
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            block(&now, input, &inputTime, output.unsafeMutablePointer, &outputTime)
            return bytes.allSatisfy { $0 == 0 }
        }
    }
}

/// A tap as `SystemAudioSource` sees it
final class FakeTap: SystemAudioTapping {
    let number: Int
    let deliver: (CMSampleBuffer) -> Void
    let outputChanged: () -> Void
    private let journal: Journal
    var isCurrent = true
    let deviceName: String
    let formatText = "48000 Hz, 2 ch, float32 interleaved"
    init(_ number: Int, device: String, journal: Journal, deliver: @escaping (CMSampleBuffer) -> Void, outputChanged: @escaping () -> Void) {
        self.number = number
        deviceName = device
        self.journal = journal
        self.deliver = deliver
        self.outputChanged = outputChanged
    }
    func stop() { journal.note("tap\(number).stop") }
}

/// Makes `FakeTap`s, fails while `fails` is above zero, and lets a test announce device changes
final class FakeTapFactory {
    let journal = Journal()
    private let lock = NSLock()
    private var made = [FakeTap]()
    var fails = 0
    var device = "Speakers"
    /// A failed make announces a device-list change, as the aggregate device a real one creates and destroys does
    var failureChangesDevices = false
    private(set) var announce: ((String) -> Void)?
    private(set) var watching = false

    var taps: [FakeTap] { lock.lock(); defer { lock.unlock() }; return made }

    var factory: SystemAudioSource.Factory {
        return SystemAudioSource.Factory(makeTap: { [self] _, deliver, outputChanged in
            lock.lock()
            defer { lock.unlock() }
            if fails > 0 {
                fails -= 1
                journal.note("make failed")
                if failureChangesDevices {
                    announce?("the audio devices changed")
                    announce?("the audio devices changed")
                }
                throw SystemAudioTapError("Creating the process tap failed ('!hog')")
            }
            let tap = FakeTap(made.count + 1, device: device, journal: journal, deliver: deliver, outputChanged: outputChanged)
            made.append(tap)
            journal.note("tap\(tap.number).make on \(device)")
            return tap
        }, watchDevices: { [self] queue, changed in
            watching = true
            announce = { reason in queue.async { changed(reason) } }
            return { [self] in
                watching = false
                journal.note("unwatch devices")
            }
        }, defaultOutput: { [self] in
            lock.lock()
            defer { lock.unlock() }
            return device
        })
    }
}

/// Interleaved or not, as a tap's format can be
func tapFormat(rate: Double = 48000, channels: UInt32 = 2, interleaved: Bool) -> AudioStreamBasicDescription {
    let bytes = UInt32(MemoryLayout<Float>.size)
    var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
    return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                       mBytesPerPacket: interleaved ? bytes * channels : bytes, mFramesPerPacket: 1,
                                       mBytesPerFrame: interleaved ? bytes * channels : bytes, mChannelsPerFrame: channels,
                                       mBitsPerChannel: 32, mReserved: 0)
}

/// A buffer of the tap's format, sample `i` of channel `c` being `(i + 1) * 0.001 * (c + 1)`, wrapped as a sample buffer
func tapBuffer(_ format: AudioStreamBasicDescription, frames: Int, at pts: CMTime, amplitude: Float? = nil) throws -> CMSampleBuffer {
    var asbd = format
    let audioFormat = try require(AVAudioFormat(streamDescription: &asbd), "format")
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)), "pcm")
    pcm.frameLength = AVAudioFrameCount(frames)
    fill(pcm, amplitude: amplitude)
    let description = try SystemAudioBuffers.formatDescription(format)
    return try require(AudioSilence.sampleBuffer(from: pcm, description: description, at: pts), "sample buffer")
}

/// Ramps that tell channels and frames apart, or a 440 Hz tone of `amplitude`
func fill(_ pcm: AVAudioPCMBuffer, amplitude: Float? = nil) {
    let channels = Int(pcm.format.channelCount)
    let frames = Int(pcm.frameLength)
    func value(_ frame: Int, _ channel: Int) -> Float {
        if let amplitude = amplitude { return amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / pcm.format.sampleRate)) }
        return Float(frame + 1) * 0.001 * Float(channel + 1)
    }
    let list = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for (index, buffer) in list.enumerated() {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        if pcm.format.isInterleaved {
            for frame in 0..<frames { for channel in 0..<channels { data[frame * channels + channel] = value(frame, channel) } }
        } else {
            for frame in 0..<frames { data[frame] = value(frame, index) }
        }
    }
}

/// Every sample of a buffer of 32 bit float, per channel
func samplesByChannel(of buffer: CMSampleBuffer) -> [[Float]] {
    guard let asbd = buffer.formatDescription?.audioStreamBasicDescription else { return [] }
    let count = Int(asbd.mChannelsPerFrame)
    let interleaved = SystemAudioBuffers.isInterleaved(asbd)
    var result = [[Float]](repeating: [], count: count)
    try? buffer.withAudioBufferList { list, _ in
        for (index, part) in list.enumerated() {
            guard let data = part.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let values = Array(UnsafeBufferPointer(start: data, count: Int(part.mDataByteSize) / MemoryLayout<Float>.size))
            if interleaved {
                for channel in 0..<count { result[channel] = stride(from: channel, to: values.count, by: count).map { values[$0] } }
            } else if index < count {
                result[index] = values
            }
        }
    }
    return result
}

/// A host time `seconds` from now in host ticks
func hostTicks(_ seconds: Double = 0) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    return mach_absolute_time() &+ UInt64(max(0, ticks))
}

func systemAudioTests() async {
    await test("system audio tap: built on the default output device, torn down in order, once") {
        let journal = Journal()
        let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
        var tap: SystemAudioTap? = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(journal.all, ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start", "watch"], "the order it is built in")
        expectEqual(hardware.excluded, [77], "Holdfast's own process is left out of the tap")
        expectEqual(hardware.aggregateMain, "speakers-uid", "the default output device is the aggregate device's main sub-device")
        expectEqual(hardware.aggregateTap, "tap-uid", "with the tap as its sub-tap")
        expect(tap?.isCurrent == true, "on the default output")
        var changes = 0
        let watching = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        watching.deviceRate = 48000
        let watched = try SystemAudioTap(hardware: watching, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: { changes += 1 })
        watching.watched?()
        expectEqual(changes, 0, "a notification from the output device that changed nothing does not rebuild")
        watching.deviceRate = 24000
        watching.watched?()
        expectEqual(changes, 1, "a new rate does (AirPods in their call mode)")
        watching.deviceRate = 48000
        watching.alive = false
        watching.watched?()
        expectEqual(changes, 2, "and so does a device that went away")
        watched.stop()
        expectEqual(hardware.usage[true], [true], "the IOProc uses the tap's stream")
        expectEqual(hardware.usage[false], [false, false], "and none of the output device's output streams")
        hardware.output = TapOutputDevice(id: 41, uid: "airpods-uid", name: "AirPods")
        expect(tap?.isCurrent == false, "not any more once the default output is another device")
        tap?.stop()
        tap?.stop()
        tap = nil
        expectEqual(journal.all, ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start", "watch",
                                  "unwatch", "stop", "destroyIOProc", "destroyAggregate", "destroyTap"],
                    "stopped, then the IOProc, the aggregate device and the tap destroyed, once whatever stops it")

        let second = Journal()
        let alone = FakeTapHardware(second, format: tapFormat(interleaved: false))
        alone.own = nil
        _ = try SystemAudioTap(hardware: alone, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(alone.excluded, [], "a process that has no audio object yet excludes nothing")
        expectEqual(second.all, ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start", "watch",
                                 "unwatch", "stop", "destroyIOProc", "destroyAggregate", "destroyTap"],
                    "a tap that is let go of is torn down the same way")
    }

    await test("system audio tap: a step that fails leaves nothing behind") {
        let cases: [(String, [String])] = [
            ("output", []),
            ("createTap", []),
            ("tapFormat", ["createTap", "destroyTap"]),
            ("createAggregate", ["createTap", "destroyTap"]),
            ("createIOProc", ["createTap", "createAggregate", "destroyAggregate", "destroyTap"]),
            ("start", ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "destroyIOProc", "destroyAggregate", "destroyTap"]),
        ]
        for (failing, expected) in cases {
            let journal = Journal()
            let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
            hardware.failing = failing
            await expectThrows("\(failing) fails") {
                _ = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
            }
            expectEqual(journal.all, expected, "\(failing) fails: what was created is destroyed, the last first")
        }
        let journal = Journal()
        var odd = tapFormat(interleaved: true)
        odd.mFormatID = kAudioFormatMPEG4AAC
        await expectThrows("a tap that does not deliver linear PCM") {
            _ = try SystemAudioTap(hardware: FakeTapHardware(journal, format: odd), queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        }
        expectEqual(journal.all, ["createTap", "createAggregate", "destroyAggregate", "destroyTap"], "is not recorded, and nothing is left")
    }

    await test("system audio tap: the IOProc uses only the tap's stream, and the output device is only the clock") {
        expectEqual(SystemAudioTap.streamUsage(streams: 3, input: true), [false, false, true], "of the input streams only the last, the tap's")
        expectEqual(SystemAudioTap.streamUsage(streams: 1, input: true), [true], "the tap alone")
        expectEqual(SystemAudioTap.streamUsage(streams: 2, input: false), [false, false], "no output stream")
        expectEqual(SystemAudioTap.streamUsage(streams: 0, input: true), [], "nothing to say for no stream")

        // AirPods: the main device has an input stream (its microphone), in front of the tap's
        let journal = Journal()
        let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
        hardware.streams = (input: 2, output: 1)
        var tap: SystemAudioTap? = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(hardware.usage[true], [false, true], "the headset's microphone is not opened")
        expectEqual(hardware.usage[false], [false], "nothing is played")
        expectEqual(journal.all.prefix(6), ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start"], "set before the device starts")
        tap = nil

        // A device without output streams of its own: only the input is set
        let quiet = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        quiet.streams = (input: 1, output: 0)
        _ = try SystemAudioTap(hardware: quiet, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expect(quiet.usage[true] == [true] && quiet.usage[false] == nil, "no output usage to set")

        // When the usage cannot be set, the tap still records, and the log says so
        for failing in ["streams", "usage in"] {
            let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
            hardware.failing = failing
            let lines = RecLog.lines.count
            var delivered = 0
            let tap = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { _ in delivered += 1 }, outputChanged: {})
            expect(hardware.journal.all.contains("start"), "\(failing) fails: started all the same")
            expect(RecLog.lines.dropFirst(lines).contains { $0.contains("input streams stay on") }, "\(failing) fails: logged: \(RecLog.lines.suffix(2))")
            var asbd = tapFormat(interleaved: true)
            let pcm = try require(AVAudioPCMBuffer(pcmFormat: try require(AVAudioFormat(streamDescription: &asbd), "format"), frameCapacity: 64), "pcm")
            pcm.frameLength = 64
            hardware.runIO(pcm.audioBufferList, host: hostTicks())
            expectEqual(delivered, 1, "\(failing) fails: its buffers are handed on")
            tap.stop()
        }
    }

    await test("system audio tap: once the output device changes its rate, nothing more is handed on") {
        let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        hardware.deviceRate = 48000
        var delivered = 0
        var changes = 0
        let tap = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { _ in delivered += 1 }, outputChanged: { changes += 1 })
        var asbd = tapFormat(interleaved: true)
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: try require(AVAudioFormat(streamDescription: &asbd), "format"), frameCapacity: 64), "pcm")
        pcm.frameLength = 64
        hardware.runIO(pcm.audioBufferList, host: hostTicks())
        expectEqual(delivered, 1, "handed on at the rate it was built for")
        // AirPods switching to their call mode: half the rate, which the buffers would still be labelled with
        hardware.deviceRate = 24000
        hardware.watched?()
        expectEqual(changes, 1, "the rebuild is asked for")
        hardware.runIO(pcm.audioBufferList, host: hostTicks())
        hardware.runIO(pcm.audioBufferList, host: hostTicks())
        expectEqual(delivered, 1, "and from that moment on nothing goes on with the old rate on it")
        let cleared = hardware.runIO(pcm.audioBufferList, host: hostTicks())
        expect(cleared, "the output is still cleared")
        tap.stop()
    }

    await test("system audio tap: the IOProc copies the tap's buffers, stamped with their host time") {
        for interleaved in [true, false] {
            let journal = Journal()
            let format = tapFormat(interleaved: interleaved)
            let hardware = FakeTapHardware(journal, format: format)
            var delivered = [CMSampleBuffer]()
            let tap = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { delivered.append($0) }, outputChanged: {})
            var asbd = format
            let pcm = try require(AVAudioPCMBuffer(pcmFormat: try require(AVAudioFormat(streamDescription: &asbd), "format"), frameCapacity: 512), "pcm")
            pcm.frameLength = 512
            fill(pcm)
            let host = hostTicks()
            let cleared = hardware.runIO(pcm.audioBufferList, host: host)
            expect(cleared, "nothing is played through the aggregate device's output")
            // The IO buffer is reused by Core Audio once the IOProc returns: what was handed on must be a copy
            fill(pcm, amplitude: 0)
            let buffer = try require(delivered.first, "a buffer is handed on")
            expectEqual(buffer.numSamples, 512, "every frame (\(interleaved ? "interleaved" : "non-interleaved"))")
            expectEqual(buffer.presentationTimeStamp, CMClockMakeHostTimeFromSystemUnits(host), "stamped with the IO's host time")
            let asbdOut = try require(buffer.formatDescription?.audioStreamBasicDescription, "format")
            expectEqual(SystemAudioBuffers.isInterleaved(asbdOut), interleaved, "in the tap's own layout")
            expectEqual(asbdOut.mSampleRate, 48000, "at its rate")
            let samples = samplesByChannel(of: buffer)
            expectEqual(samples.count, 2, "two channels")
            expectEqual(samples.first?.prefix(3).map { ($0 * 1000).rounded() }, [1, 2, 3], "left channel copied")
            expectEqual(samples.last?.prefix(3).map { ($0 * 1000).rounded() }, [2, 4, 6], "right channel copied")
            tap.stop()
        }
    }

    await test("system audio tap: only the tap's buffers are taken, at the device's rate, and nothing malformed") {
        let journal = Journal()
        let format = tapFormat(rate: 48000, interleaved: false)
        let hardware = FakeTapHardware(journal, format: format)
        hardware.deviceRate = 44100
        var delivered = [CMSampleBuffer]()
        let tap = try SystemAudioTap(hardware: hardware, queue: DispatchQueue(label: "test"), deliver: { delivered.append($0) }, outputChanged: {})
        expectEqual(tap.format.mSampleRate, 44100, "the aggregate device's rate, which the tap is brought to")
        expect(RecLog.lines.contains { $0.contains("the device's rate is used") }, "and the difference is logged")
        // A main device with an input stream of its own comes first in the aggregate device's input
        var microphone = [Float](repeating: 9, count: 256)
        var left = [Float](repeating: 0.25, count: 256)
        var right = [Float](repeating: -0.25, count: 256)
        let list = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(list.unsafeMutablePointer) }
        microphone.withUnsafeMutableBytes { mic in left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r in
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(mic.count), mData: mic.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
            list[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
            hardware.runIO(list.unsafePointer, host: hostTicks())
            // Buffers of different lengths are not the tap's stream
            list[2].mDataByteSize = UInt32(r.count / 2)
            hardware.runIO(list.unsafePointer, host: hostTicks())
            list[2].mDataByteSize = 0
            hardware.runIO(list.unsafePointer, host: hostTicks())
            // The main device's input stream turned off for this IOProc: a NULL buffer in front of the tap's
            list[2].mDataByteSize = UInt32(r.count)
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
            hardware.runIO(list.unsafePointer, host: hostTicks())
        } } }
        expectEqual(delivered.count, 2, "only the well-formed buffers are handed on")
        expectEqual(delivered.last.map { samplesByChannel(of: $0).map { $0.first ?? 0 } }, [0.25, -0.25], "a turned-off stream in front of the tap's is passed over")
        let buffer = try require(delivered.first, "a buffer")
        expectEqual(buffer.numSamples, 256, "its frames")
        expectEqual(samplesByChannel(of: buffer).map { $0.first ?? 0 }, [0.25, -0.25], "the tap's channels, not the main device's input")
        expectClose(CMTimeGetSeconds(buffer.duration), 256.0 / 44100, within: 0.000_01, "lasting as long as at the device's rate")
        tap.stop()
    }

    await test("system audio buffers: host time is the host-time clock ScreenCaptureKit stamps with") {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var stamp = AudioTimeStamp()
        stamp.mHostTime = mach_absolute_time()
        stamp.mFlags = .hostTimeValid
        let pts = SystemAudioBuffers.presentationTime(of: stamp, frames: 480, rate: 48000)
        expectClose(CMTimeGetSeconds(CMTimeSubtract(pts, now)), 0, within: 0.005, "the IO's host time on the host-time clock")
        stamp.mHostTime = hostTicks(2)
        let later = SystemAudioBuffers.presentationTime(of: stamp, frames: 480, rate: 48000)
        expectClose(CMTimeGetSeconds(CMTimeSubtract(later, now)), 2, within: 0.005, "two seconds of host ticks are two seconds")
        stamp.mFlags = []
        let guessed = SystemAudioBuffers.presentationTime(of: stamp, frames: 4800, rate: 48000)
        expectClose(CMTimeGetSeconds(CMTimeSubtract(guessed, now)), -0.1, within: 0.005, "without a valid host time: just captured, ending now")
    }

    await test("system audio buffers: the IO format is linear PCM at the device's rate") {
        let tap = tapFormat(rate: 48000, interleaved: true)
        expectEqual(try SystemAudioBuffers.ioFormat(tap: tap, deviceRate: nil).mSampleRate, 48000, "the tap's rate without the device's")
        expectEqual(try SystemAudioBuffers.ioFormat(tap: tap, deviceRate: 24000).mSampleRate, 24000, "the device's rate")
        expectEqual(try SystemAudioBuffers.ioFormat(tap: tap, deviceRate: 0).mSampleRate, 48000, "a rate of 0 is not one")
        var broken = tap
        broken.mChannelsPerFrame = 0
        await expectThrows("no channels") { _ = try SystemAudioBuffers.ioFormat(tap: broken, deviceRate: nil) }
        expectEqual(SystemAudioBuffers.describe(tapFormat(rate: 44100, interleaved: false)), "44100 Hz, 2 ch, float32 non-interleaved", "for the log")
        expectEqual(SystemAudioBuffers.bufferCount(tapFormat(interleaved: true)), 1, "one buffer when interleaved")
        expectEqual(SystemAudioBuffers.bufferCount(tapFormat(interleaved: false)), 2, "one per channel otherwise")
    }

    await test("system audio converter: ScreenCaptureKit's format goes through, everything else becomes it") {
        let converter = try require(SystemAudioConverter(), "converter")
        // 48 kHz stereo float, one buffer per channel: ScreenCaptureKit's own format, passed on as it is
        let native = try tapBuffer(tapFormat(interleaved: false), frames: 480, at: time(10))
        expect(converter.convert(native) === native, "passed on unchanged")
        // Interleaved at 48 kHz: the same samples, one buffer per channel
        let interleaved = try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(11))
        let converted = try require(converter.convert(interleaved), "converted")
        let asbd = try require(converted.formatDescription?.audioStreamBasicDescription, "format")
        expect(SystemAudioConverter.isDelivered(as: asbd), "in ScreenCaptureKit's format")
        expectEqual(converted.numSamples, 480, "no frame lost or added")
        expectEqual(converted.presentationTimeStamp, time(11), "at its own time")
        expectEqual(samplesByChannel(of: converted).map { $0.prefix(2).map { ($0 * 1000).rounded() } }, [[1, 2], [2, 4]], "each channel's samples")
    }

    await test("system audio converter: other rates are resampled onto a continuous timeline") {
        for (rate, channelCount) in [(24000.0, UInt32(1)), (44100, 2), (16000, 2)] {
            let converter = try require(SystemAudioConverter(), "converter")
            let format = tapFormat(rate: rate, channels: channelCount, interleaved: channelCount > 1)
            let frames = Int(rate / 100)
            var total = 0
            var expectedStart: CMTime?
            var contiguous = true
            var peakSeen: Float = 0
            for index in 0..<200 {
                let buffer = try tapBuffer(format, frames: frames, at: time(100 + Double(index) / 100), amplitude: 0.5)
                guard let out = converter.convert(buffer) else { continue }
                if let expected = expectedStart, abs(CMTimeGetSeconds(CMTimeSubtract(out.presentationTimeStamp, expected))) > 0.000_001 { contiguous = false }
                expectedStart = CMTimeAdd(out.presentationTimeStamp, CMTime(value: CMTimeValue(out.numSamples), timescale: 48000))
                total += out.numSamples
                expect(SystemAudioConverter.isDelivered(as: try require(out.formatDescription?.audioStreamBasicDescription, "format")), "48 kHz stereo float")
                peakSeen = max(peakSeen, samplesByChannel(of: out).map { $0.map(abs).max() ?? 0 }.min() ?? 0)
            }
            expectClose(Double(total), 96000, within: 1000, "\(Int(rate)) Hz: two seconds in, two seconds out")
            expect(contiguous, "\(Int(rate)) Hz: every buffer starts where the one before it ended")
            expect(peakSeen > 0.4, "\(Int(rate)) Hz: the sound reaches both channels (\(peakSeen))")
            // A gap of a second: the next buffer starts at its own time, not where the last one ended
            let after = try tapBuffer(format, frames: frames, at: time(103), amplitude: 0.5)
            let next = try tapBuffer(format, frames: frames, at: time(103.01), amplitude: 0.5)
            let restarted = converter.convert(after) ?? converter.convert(next)
            let start = try require(restarted, "audio after the gap").presentationTimeStamp
            expectClose(CMTimeGetSeconds(start), 103, within: 0.011, "\(Int(rate)) Hz: after a gap the timeline starts again at the buffer's time")
        }
    }

    await test("system audio selection: the tap first, ScreenCaptureKit when it cannot be used, never both") {
        var tries = 0
        let tap = SystemAudioSelection.choose(wanted: true, permission: .granted) { tries += 1 }
        expectEqual(tap, .tap, "the tap when it starts")
        expect(!tap.streamCapturesAudio, "and then the stream captures no audio: nothing is recorded twice")
        expect(SystemAudioSelection.notice(for: tap) == nil, "nothing to tell")
        expectEqual(SystemAudioSelection.choose(wanted: true, permission: .unknown) { tries += 1 }, .tap, "tried when the permission cannot be read")
        expectEqual(tries, 2, "the tap was tried twice")

        let failed = SystemAudioSelection.choose(wanted: true, permission: .granted) { throw SystemAudioTapError("Creating the process tap", -50) }
        guard case .screenCaptureKit(let reason, let tapFailed) = failed else { return expect(false, "a tap that fails falls back to the stream") }
        expect(reason.contains("Creating the process tap failed"), "saying why: \(reason)")
        expect(tapFailed, "because the tap failed")
        expect(failed.streamCapturesAudio, "the stream records the system audio instead")
        let notice = try require(SystemAudioSelection.notice(for: failed), "the user is told")
        expect(notice.contains("FaceTime") && notice.contains("phone calls"), "that call audio is not included: \(notice)")

        let denied = SystemAudioSelection.choose(wanted: true, permission: .denied) { tries += 1 }
        expect(denied.streamCapturesAudio, "no permission: the stream records it")
        expect(SystemAudioSelection.notice(for: denied)?.contains("System Audio Recording Only") == true, "and the notice says where to allow it")
        expect(SystemAudioSelection.choose(wanted: true, permission: .notDetermined) { tries += 1 }.streamCapturesAudio, "not answered: the stream records it")
        expectEqual(tries, 2, "without trying the tap")

        let none = SystemAudioSelection.choose(wanted: false, permission: .granted) { tries += 1 }
        expectEqual(none, .none, "no system audio wanted, none recorded")
        expect(!none.streamCapturesAudio && tries == 2, "by neither source")
        expectEqual([SystemAudioRoute.none, .tap, failed].map(\.name), ["off", "on, process tap", "on, screen capture"], "for the log")

        let once = NoticeOnce()
        expectEqual([once.take(), once.take(), once.take()], [true, false, false], "the notice is shown once")

        // A tap that failed although it was allowed: every recording is told, and shows it while it runs. Not
        // allowed (the user's answer): one notification while the app runs, nothing on screen.
        let launch = NoticeOnce()
        expectEqual([failed, failed, failed].map { SystemAudioSelection.notifies($0, once: launch) }, [true, true, true], "a failed tap is notified every time")
        expectEqual(SystemAudioSelection.warning(for: failed), "Call audio is not being recorded", "and is the recording's warning")
        expectEqual([denied, denied, failed, denied].map { SystemAudioSelection.notifies($0, once: launch) }, [true, false, true, false], "not allowed: once while the app runs")
        expect(SystemAudioSelection.warning(for: denied) == nil, "without a warning on screen")
        expect(!SystemAudioSelection.notifies(tap, once: NoticeOnce()) && SystemAudioSelection.warning(for: tap) == nil, "with the tap: nothing to tell")
        expect(!SystemAudioSelection.notifies(none, once: NoticeOnce()) && SystemAudioSelection.warning(for: none) == nil, "nor without system audio")
    }

    await test("system audio source: the tap's buffers reach the recording as ScreenCaptureKit's system audio") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tap")
        let received = Journal()
        var samples = [CaptureSample]()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue) { sample in
            dispatchPrecondition(condition: .onQueue(queue))
            samples.append(sample)
            received.note("sample")
        }
        try source.start()
        let tap = try require(fakes.taps.first, "a tap")
        expect(fakes.watching, "the devices are followed")
        expect(RecLog.lines.contains("System audio: process tap on \"Speakers\" (48000 Hz, 2 ch, float32 interleaved)"), "the log says where the system audio comes from: \(RecLog.lines)")
        tap.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(20)))
        tap.deliver(try tapBuffer(tapFormat(interleaved: false), frames: 480, at: time(20.01)))
        expect(await waitUntil { received.count("sample") == 2 }, "both are handed on")
        queue.sync {}
        for sample in samples {
            guard case .audio = sample.kind else { expect(false, "as system audio"); continue }
            expect(SystemAudioConverter.isDelivered(as: sample.buffer.formatDescription?.audioStreamBasicDescription ?? AudioStreamBasicDescription()), "in ScreenCaptureKit's format")
            expectEqual(sample.pts, sample.buffer.presentationTimeStamp, "the sample's time is the buffer's")
        }
        expectEqual(samples.map(\.pts), [time(20), time(20.01)], "at their own times")
        var stopped = false
        source.stop { stopped = true }
        expect(await waitUntil { stopped }, "stopped")
        expectEqual(fakes.journal.all, ["tap1.make on Speakers", "unwatch devices", "tap1.stop"], "the devices are no longer followed and the tap is torn down")
        tap.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(20.02)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        expectEqual(received.count("sample"), 2, "nothing is handed on after the stop")
    }

    await test("system audio source: a tap that cannot be made leaves nothing running") {
        let fakes = FakeTapFactory()
        fakes.fails = 1
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap")) { _ in }
        let message = await expectThrows("the start fails") { try source.start() }
        expect(message.contains("!hog"), "with Core Audio's reason: \(message)")
        expect(!fakes.watching, "no devices are followed")
        source.stopNow()
        expectEqual(fakes.journal.all, ["make failed"], "nothing to tear down")
        let route = SystemAudioSelection.choose(wanted: true, permission: .granted) { try SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "x")) { _ in }.start() }
        expect(route == .tap, "the next recording tries again and gets it")
    }

    await test("system audio source: a new output device rebuilds the tap once, and nothing of the old one comes after the new") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tap")
        var times = [Double]()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue, settleDelay: 0.05, retryDelay: 0.05) { times.append(CMTimeGetSeconds($0.pts)) }
        try source.start()
        let first = try require(fakes.taps.first, "the first tap")
        let announce = try require(fakes.announce, "the devices are followed")
        first.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(30)))
        // A burst of changes: the AirPods connect and become the default output
        first.isCurrent = false
        fakes.device = "AirPods"
        announce("the audio devices changed")
        announce("the default output device changed")
        announce("the audio devices changed")
        expect(await waitUntil { fakes.taps.count == 2 }, "rebuilt")
        try? await Task.sleep(nanoseconds: 150_000_000)
        expectEqual(fakes.journal.all, ["tap1.make on Speakers", "tap1.stop", "tap2.make on AirPods"], "once, the old tap torn down before the new one is made")
        let second = try require(fakes.taps.last, "the second tap")
        second.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(31)))
        // The old IOProc's last call, late: it must not follow the new tap's audio
        first.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(30.5)))
        queue.sync {}
        second.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(31.01)))
        expect(await waitUntil { times.count >= 3 }, "the new tap's audio arrives")
        queue.sync {}
        expectEqual(times, [30, 31, 31.01], "nothing of the old device after the new one started")
        expect(RecLog.lines.contains("System audio: rebuilding the process tap (the audio devices changed)"), "the rebuild is logged: \(RecLog.lines)")
        expect(RecLog.lines.contains("System audio: process tap rebuilt on \"AirPods\" (48000 Hz, 2 ch, float32 interleaved)"), "and where it is now")

        // Holdfast's own aggregate device coming and going changes the device list too: a tap that is still on
        // the default output stays
        announce("the audio devices changed")
        try? await Task.sleep(nanoseconds: 150_000_000)
        expectEqual(fakes.taps.count, 2, "a tap on the default output is kept")
        // The output device changes its rate (AirPods switching to their call mode): rebuilt although still current
        second.outputChanged()
        expect(await waitUntil { fakes.taps.count == 3 }, "rebuilt for the device's own change")
        source.stopNow()
        expectEqual(fakes.journal.all.suffix(3), ["tap3.make on AirPods", "unwatch devices", "tap3.stop"], "and torn down at the stop")
    }

    await test("system audio source: a rebuild that fails is retried, and a stop ends it") {
        let fakes = FakeTapFactory()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), settleDelay: 0.02, retryDelay: 0.02) { _ in }
        try source.start()
        let first = try require(fakes.taps.first, "the first tap")
        let announce = try require(fakes.announce, "the devices are followed")
        first.isCurrent = false
        fakes.fails = 2
        announce("the default output device changed")
        expect(await waitUntil { fakes.taps.count == 2 }, "made on the third try")
        expectEqual(fakes.journal.all, ["tap1.make on Speakers", "tap1.stop", "make failed", "make failed", "tap2.make on Speakers"], "tried again after each failure")
        expectEqual(RecLog.lines.filter { $0.contains("rebuilding the process tap failed") }.count, 2, "each failure is logged")

        fakes.fails = 10
        let second = try require(fakes.taps.last, "the second tap")
        second.isCurrent = false
        announce("the default output device changed")
        try? await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(fakes.journal.count("make failed"), 2 + 1 + SystemAudioSource.retries, "given up after \(SystemAudioSource.retries) retries")
        // Without a tap the next device change tries again, and a stop while it waits ends that
        fakes.fails = 0
        announce("the audio devices changed")
        source.stopNow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(fakes.taps.count, 2, "no tap is made after the stop")
        expect(!fakes.watching, "and the devices are not followed any more")
    }

    await test("system audio source: a tap that fails on an output is not rebuilt for its own device-list changes") {
        let fakes = FakeTapFactory()
        fakes.failureChangesDevices = true
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), settleDelay: 0.02, retryDelay: 0.04) { _ in }
        try source.start()
        let first = try require(fakes.taps.first, "the first tap")
        let announce = try require(fakes.announce, "the devices are followed")
        // An output on which the aggregate device never starts (held by another app): each failed build creates
        // and destroys an aggregate device, which changes the device list
        first.isCurrent = false
        fakes.fails = 1000
        fakes.device = "Hogged"
        announce("the default output device changed")
        try? await Task.sleep(nanoseconds: 700_000_000)
        expectEqual(fakes.journal.count("make failed"), 1 + SystemAudioSource.retries, "tried once and retried \(SystemAudioSource.retries) times, not for ever")
        // Other devices coming and going on the same output do not start it again either
        announce("the audio devices changed")
        try? await Task.sleep(nanoseconds: 200_000_000)
        expectEqual(fakes.journal.count("make failed"), 1 + SystemAudioSource.retries, "nor does a device-list change on the same output")
        // A forced change still counts: the output device changed its format
        first.outputChanged()
        try? await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(fakes.journal.count("make failed"), 2 * (1 + SystemAudioSource.retries), "a format change is tried again, as often")
        // Another output device: built there
        fakes.fails = 0
        fakes.device = "Headphones"
        announce("the default output device changed")
        expect(await waitUntil { fakes.taps.count == 2 }, "built on the next output device")
        expectEqual(fakes.journal.all.last, "tap2.make on Headphones", "on the new output")
        // Its own aggregate device changes the list once more: the tap that works stays
        announce("the audio devices changed")
        try? await Task.sleep(nanoseconds: 150_000_000)
        expectEqual(fakes.taps.count, 2, "and stays")
        source.stopNow()
    }

    await test("system audio source: the writer records the tap's audio like ScreenCaptureKit's") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tapWriter")
        let run = try TestRecording(folder: "tap-writer", audioOnly: true, microphone: false)
        try run.writer.prepareAudio()
        run.writer.startCapturing()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue) { run.writer.write($0) }
        try source.start()
        let tap = try require(fakes.taps.first, "a tap")
        // Two seconds from an output device at 44.1 kHz, interleaved, as a tap may deliver them
        let format = tapFormat(rate: 44100, interleaved: true)
        for index in 0..<200 {
            tap.deliver(try tapBuffer(format, frames: 441, at: run.at(Double(index) / 100), amplitude: 0.3))
        }
        source.stopNow()
        queue.sync {}
        let finished = queue.sync { run.writer.finish() }
        expect(finished.sessionStarted, "the tap's first buffer starts the session of a sound-only recording")
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let seconds = try await TestMovie.seconds(of: try require(run.recording.systemAudioURL, "system audio file"))
        expectClose(seconds, 2, within: 0.05, "two seconds in the file")
    }
}
