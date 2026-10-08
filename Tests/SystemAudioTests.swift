//
//  SystemAudioTests.swift
//  System audio through a Core Audio process tap, without Core Audio: the tap's build and teardown against fake
//  hardware, its IOProc fed with buffer lists made here, the conversion to ScreenCaptureKit's format, the choice
//  between the tap and ScreenCaptureKit, and the rebuild when the output device changes, with fake taps.
//

import AVFoundation
import CoreAudio
import Foundation

/// Core Audio as `SystemAudioTap` uses it, taking notes. `failing` makes that step fail; `refusedClocks` makes the
/// aggregate device fail with those main sub-devices (nil: the one without a sub-device).
final class FakeTapHardware: TapHardware {
    let journal: Journal
    var failing: String?
    var output = TapOutputDevice(id: 40, uid: "speakers-uid", name: "Speakers")
    var builtIn: TapOutputDevice? = TapOutputDevice(id: 30, uid: "builtin-uid", name: "MacBook Pro Speakers")
    var own: AudioObjectID? = 77
    var format: AudioStreamBasicDescription
    var deviceRate: Double? = nil
    var alive = true
    var refusedClocks = [String?]()
    /// The aggregate device's input and output streams
    var streams = (input: 1, output: 2)
    /// The IOProc's stream usage that was set, by scope (true: input)
    private(set) var usage = [Bool: [Bool]]()
    /// The IOProc the tap installed, to be called as Core Audio would
    private(set) var ioBlock: AudioDeviceIOBlock?
    private(set) var excluded = [AudioObjectID]()
    /// The main sub-device of every aggregate device asked for, nil for none
    private(set) var mains = [String?]()
    var aggregateMain: String? { mains.last ?? nil }
    private(set) var aggregateTap: String?
    private(set) var watchers = [() -> Void]()
    private(set) var watchedObjects = [AudioObjectID]()
    private var watcherQueues = [DispatchQueue]()
    /// The audio process objects of the process that plays calls, and what the call taps were made of
    var callObjects = [AudioObjectID]()
    private(set) var tappedProcesses = [[AudioObjectID]]()
    /// The listeners that are installed, by the token each was given, and removals of one that was not
    private(set) var watching = Set<UInt>()
    private(set) var strayUnwatches = 0
    private var tokens: UInt = 0

    init(_ journal: Journal, format: AudioStreamBasicDescription) {
        self.journal = journal
        self.format = format
    }

    private func step(_ name: String) throws {
        if failing == name { throw SystemAudioTapError(name, -50) }
        journal.note(name)
    }

    /// What the listeners hear when a watched property changes
    func notifyWatchers() { watchers.forEach { $0() } }

    /// The list of audio process objects changed: its listeners hear of it on their queues, as Core Audio's do
    func notifyProcessList() {
        for (index, object) in watchedObjects.enumerated() where object == CoreAudioTapHardware.system { watcherQueues[index].async(execute: watchers[index]) }
    }

    func callProcessObjects() -> [AudioObjectID] { callObjects }
    func createCallTap(of processes: [AudioObjectID]) throws -> (id: AudioObjectID, uid: String) {
        try step("createCallTap")
        tappedProcesses.append(processes)
        return (101, "call-tap-uid")
    }

    func ownProcessObject() -> AudioObjectID? { own }
    func defaultOutputDevice() throws -> TapOutputDevice {
        if failing == "output" { throw SystemAudioTapError("There is no output device") }
        return output
    }
    func builtInOutputDevice() -> TapOutputDevice? { failing == "builtIn" ? nil : builtIn }
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
    func createAggregateDevice(name: String, uid: String, mainUID: String?, tapUID: String) throws -> AudioObjectID {
        mains.append(mainUID)
        if refusedClocks.contains(mainUID) { throw SystemAudioTapError("Creating the aggregate device", -50) }
        try step("createAggregate")
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
        watchers.append(changed)
        watchedObjects.append(object)
        watcherQueues.append(queue)
        tokens += 1
        watching.insert(tokens)
        return TapListener(object: object, token: tokens)
    }
    func unwatch(_ listener: TapListener) {
        journal.note("unwatch")
        if watching.remove(listener.token) == nil { strayUnwatches += 1 }
    }

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
    let clock: TapClock
    let deliver: (CMSampleBuffer) -> Void
    let outputChanged: () -> Void
    private let journal: Journal
    let formatText = "48000 Hz, 2 ch, float32 interleaved"
    var clockText: String { clock.name }
    init(_ number: Int, clock: TapClock, journal: Journal, deliver: @escaping (CMSampleBuffer) -> Void, outputChanged: @escaping () -> Void) {
        self.number = number
        self.clock = clock
        self.journal = journal
        self.deliver = deliver
        self.outputChanged = outputChanged
    }
    func stop() { journal.note("tap\(number).stop") }
}

/// Makes `FakeTap`s in the order `constructions` says, failing while `fails` is above zero or for the clocks in
/// `refused`
final class FakeTapFactory {
    let journal = Journal()
    private let lock = NSLock()
    private var made = [FakeTap]()
    var fails = 0
    var refused = Set<TapClock>()
    var constructions: [TapClock] = [.builtInOutput, .none, .defaultOutput]

    var taps: [FakeTap] { lock.lock(); defer { lock.unlock() }; return made }

    var factory: SystemAudioSource.Factory {
        return SystemAudioSource.Factory(constructions: { [self] in
            lock.lock()
            defer { lock.unlock() }
            return constructions
        }, makeTap: { [self] clock, _, deliver, outputChanged in
            lock.lock()
            defer { lock.unlock() }
            if fails > 0 || refused.contains(clock) {
                if fails > 0 { fails -= 1 }
                journal.note("make failed: \(clock)")
                throw SystemAudioTapError("Creating the process tap failed ('!hog')")
            }
            let tap = FakeTap(made.count + 1, clock: clock, journal: journal, deliver: deliver, outputChanged: outputChanged)
            made.append(tap)
            journal.note("tap\(tap.number).make: \(clock)")
            return tap
        })
    }
}

/// Keeps `tap` delivering a buffer every 10 ms on a queue of its own, as a live IOProc does, until `stop`
final class LiveTap {
    private let stopped = NSLock()
    private var running = true
    init(_ tap: FakeTap) throws {
        let buffer = try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(1))
        DispatchQueue.global().async { [self] in
            while isRunning {
                tap.deliver(buffer)
                usleep(10_000)
            }
        }
    }
    private var isRunning: Bool { stopped.lock(); defer { stopped.unlock() }; return running }
    func stop() { stopped.lock(); running = false; stopped.unlock() }
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

/// A host time `seconds` from now, also before now, in host ticks; never 0, which stands for no host time
func hostTicks(_ seconds: Double = 0) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = (seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)).rounded()
    let now = mach_absolute_time()
    if ticks >= 0 { return now &+ UInt64(ticks) }
    let back = UInt64(-ticks)
    return now > back ? now - back : 1
}

func systemAudioTests() async {
    await test("system audio tap: clocked by the built-in output, no sub-device or the default output, torn down in order, once") {
        let journal = Journal()
        let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
        var tap: SystemAudioTap? = try SystemAudioTap(hardware: hardware, clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(journal.all, ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start", "watch", "watch"], "the order it is built in")
        expectEqual(hardware.excluded, [77], "Holdfast's own process is left out of the tap")
        expectEqual(hardware.aggregateMain, "builtin-uid", "the built-in output is the aggregate device's main sub-device, not the default output")
        expectEqual(hardware.aggregateTap, "tap-uid", "with the tap as its sub-tap")
        expectEqual(hardware.watchedObjects, [200, 30], "the aggregate device and the device that clocks it are watched")
        expectEqual(hardware.watching.count, 2, "each with a listener of its own")
        expectEqual(tap?.clockText, "the built-in output \"MacBook Pro Speakers\"", "for the log")
        hardware.output = TapOutputDevice(id: 41, uid: "airpods-uid", name: "AirPods")
        hardware.notifyWatchers()
        tap?.stop()
        tap?.stop()
        tap = nil
        expectEqual(journal.all, ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start", "watch", "watch",
                                  "unwatch", "unwatch", "stop", "destroyIOProc", "destroyAggregate", "destroyTap"],
                    "stopped, then the IOProc, the aggregate device and the tap destroyed, once whatever stops it")
        expect(hardware.watching.isEmpty && hardware.strayUnwatches == 0, "and every listener removed as the one that was installed: \(hardware.watching) left, \(hardware.strayUnwatches) unknown")

        let alone = Journal()
        let tapOnly = FakeTapHardware(alone, format: tapFormat(interleaved: false))
        tapOnly.own = nil
        tapOnly.streams = (input: 1, output: 0)
        let none = try SystemAudioTap(hardware: tapOnly, clock: .none, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(tapOnly.mains, [nil], "no sub-device at all")
        expectEqual(tapOnly.excluded, [], "a process that has no audio object yet excludes nothing")
        expectEqual(tapOnly.watchedObjects, [200], "only the aggregate device is watched")
        expectEqual(none.clockText, "no sub-device", "for the log")
        none.stop()
        expectEqual(alone.all, ["createTap", "createAggregate", "createIOProc", "usage in", "start", "watch",
                                "unwatch", "stop", "destroyIOProc", "destroyAggregate", "destroyTap"], "built and torn down the same way")

        let last = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        last.output = TapOutputDevice(id: 41, uid: "airpods-uid", name: "AirPods")
        let output = try SystemAudioTap(hardware: last, clock: .defaultOutput, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(last.aggregateMain, "airpods-uid", "the last resort: the default output")
        expectEqual(output.clockText, "the default output \"AirPods\"", "for the log")
        output.stop()
    }

    await test("system audio tap: the order of constructions") {
        let builtIn = TapOutputDevice(id: 30, uid: "builtin-uid", name: "MacBook Pro Speakers")
        let airPods = TapOutputDevice(id: 41, uid: "airpods-uid", name: "AirPods")
        expectEqual(TapClock.order(builtIn: builtIn, defaultOutput: airPods), [.builtInOutput, .none, .defaultOutput], "the built-in output, no sub-device, the default output last")
        expectEqual(TapClock.order(builtIn: builtIn, defaultOutput: builtIn), [.builtInOutput, .none], "the default output that is the built-in one is not tried twice")
        expectEqual(TapClock.order(builtIn: nil, defaultOutput: airPods), [.none, .defaultOutput], "a Mac without a built-in output")
        expectEqual(TapClock.order(builtIn: nil, defaultOutput: nil), [.none], "and without any output device")
    }

    await test("system audio tap: a step that fails leaves nothing behind") {
        let cases: [(String, TapClock, [String])] = [
            ("output", .defaultOutput, []),
            ("builtIn", .builtInOutput, []),
            ("createTap", .builtInOutput, []),
            ("tapFormat", .builtInOutput, ["createTap", "destroyTap"]),
            ("createAggregate", .none, ["createTap", "destroyTap"]),
            ("createIOProc", .builtInOutput, ["createTap", "createAggregate", "destroyAggregate", "destroyTap"]),
            ("start", .builtInOutput, ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "destroyIOProc", "destroyAggregate", "destroyTap"]),
        ]
        for (failing, clock, expected) in cases {
            let journal = Journal()
            let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
            hardware.failing = failing
            await expectThrows("\(failing) fails") {
                _ = try SystemAudioTap(hardware: hardware, clock: clock, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
            }
            expectEqual(journal.all, expected, "\(failing) fails: what was created is destroyed, the last first")
        }
        let journal = Journal()
        var odd = tapFormat(interleaved: true)
        odd.mFormatID = kAudioFormatMPEG4AAC
        await expectThrows("a tap that does not deliver linear PCM") {
            _ = try SystemAudioTap(hardware: FakeTapHardware(journal, format: odd), clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        }
        expectEqual(journal.all, ["createTap", "createAggregate", "destroyAggregate", "destroyTap"], "is not recorded, and nothing is left")
    }

    await test("system audio tap: the IOProc uses only the tap's stream, and the output device is only the clock") {
        expectEqual(SystemAudioTap.streamUsage(streams: 3, input: true), [false, false, true], "of the input streams only the last, the tap's")
        expectEqual(SystemAudioTap.streamUsage(streams: 1, input: true), [true], "the tap alone")
        expectEqual(SystemAudioTap.streamUsage(streams: 2, input: false), [false, false], "no output stream")
        expectEqual(SystemAudioTap.streamUsage(streams: 0, input: true), [], "nothing to say for no stream")

        // AirPods as the last resort: the main device has an input stream (its microphone), in front of the tap's
        let journal = Journal()
        let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
        hardware.streams = (input: 2, output: 1)
        var tap: SystemAudioTap? = try SystemAudioTap(hardware: hardware, clock: .defaultOutput, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expectEqual(hardware.usage[true], [false, true], "the headset's microphone is not opened")
        expectEqual(hardware.usage[false], [false], "nothing is played")
        expectEqual(journal.all.prefix(6), ["createTap", "createAggregate", "createIOProc", "usage in", "usage out", "start"], "set before the device starts")
        tap = nil

        // A device without output streams of its own: only the input is set
        let quiet = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        quiet.streams = (input: 1, output: 0)
        _ = try SystemAudioTap(hardware: quiet, clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: {})
        expect(quiet.usage[true] == [true] && quiet.usage[false] == nil, "no output usage to set")

        // When the usage cannot be set, the tap still records, and the log says so
        for failing in ["streams", "usage in"] {
            let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
            hardware.failing = failing
            let lines = RecLog.lines.count
            var delivered = 0
            let tap = try SystemAudioTap(hardware: hardware, clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { _ in delivered += 1 }, outputChanged: {})
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

    await test("system audio tap: once its rate changes or its clock goes away, nothing more is handed on") {
        for clock in [TapClock.builtInOutput, .none, .defaultOutput] {
            let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
            hardware.deviceRate = 48000
            var delivered = 0
            var changes = 0
            let tap = try SystemAudioTap(hardware: hardware, clock: clock, queue: DispatchQueue(label: "test"), deliver: { _ in delivered += 1 }, outputChanged: { changes += 1 })
            var asbd = tapFormat(interleaved: true)
            let pcm = try require(AVAudioPCMBuffer(pcmFormat: try require(AVAudioFormat(streamDescription: &asbd), "format"), frameCapacity: 64), "pcm")
            pcm.frameLength = 64
            hardware.runIO(pcm.audioBufferList, host: hostTicks())
            expectEqual(delivered, 1, "\(clock): handed on at the rate it was built for")
            hardware.notifyWatchers()
            expectEqual(changes, 0, "\(clock): a notification that changed nothing does not rebuild")
            // AirPods switching to their call mode: half the rate, which the buffers would still be labelled with
            hardware.deviceRate = 24000
            hardware.notifyWatchers()
            expect(changes > 0, "\(clock): the rebuild is asked for")
            hardware.runIO(pcm.audioBufferList, host: hostTicks())
            expectEqual(delivered, 1, "\(clock): and from that moment on nothing goes on with the old rate on it")
            expect(hardware.runIO(pcm.audioBufferList, host: hostTicks()), "\(clock): the output is still cleared")
            tap.stop()
        }
        let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        var changes = 0
        let tap = try SystemAudioTap(hardware: hardware, clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { _ in }, outputChanged: { changes += 1 })
        hardware.alive = false
        hardware.notifyWatchers()
        expect(changes > 0, "a clock device that went away asks for the rebuild too")
        tap.stop()
    }

    await test("system audio tap: the IOProc copies the tap's buffers and stamps them with the host time it is called at, whatever the device's time stamp says") {
        // What the device's time stamp says against the time of the call: 12 s in the future, as it did when a
        // FaceTime call connected, 5 s (voice processing switched on), and in the past, 10 s and 1100 s: a stamp
        // behind is what a guard against stamps ahead lets through, and what loses everything after it
        for (interleaved, stamp) in [(true, 12.0), (false, 12.0), (true, 5.0), (false, -10.0), (true, -10.0), (true, -1100.0), (false, 0.0)] {
            let journal = Journal()
            let format = tapFormat(interleaved: interleaved)
            let hardware = FakeTapHardware(journal, format: format)
            var delivered = [CMSampleBuffer]()
            let tap = try SystemAudioTap(hardware: hardware, clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { delivered.append($0) }, outputChanged: {})
            var asbd = format
            let pcm = try require(AVAudioPCMBuffer(pcmFormat: try require(AVAudioFormat(streamDescription: &asbd), "format"), frameCapacity: 512), "pcm")
            pcm.frameLength = 512
            fill(pcm)
            let what = "\(interleaved ? "interleaved" : "non-interleaved"), stamped \(stamp) s from the call"
            let before = CMClockGetHostTimeClock().time
            // A stamp of 0 is one without a valid host time
            let cleared = hardware.runIO(pcm.audioBufferList, host: stamp == 0 ? 0 : hostTicks(stamp))
            let after = CMClockGetHostTimeClock().time
            expect(cleared, "nothing is played through the aggregate device's output")
            // The IO buffer is reused by Core Audio once the IOProc returns: what was handed on must be a copy
            fill(pcm, amplitude: 0)
            let buffer = try require(delivered.first, "a buffer is handed on (\(what))")
            expectEqual(buffer.numSamples, 512, "every frame (\(what))")
            let end = CMTimeAdd(buffer.presentationTimeStamp, buffer.duration)
            expect(end >= before && end <= after, "\(what): it ends at the host time the IOProc was called at, and is \(CMTimeGetSeconds(CMTimeSubtract(end, before))) s after the call began")
            expectClose(CMTimeGetSeconds(buffer.duration), 512.0 / 48000, within: 0.000_001, "and starts its frames before that")
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
        let tap = try SystemAudioTap(hardware: hardware, clock: .builtInOutput, queue: DispatchQueue(label: "test"), deliver: { delivered.append($0) }, outputChanged: {})
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

    await test("system audio buffers: a buffer ends at the host time it arrived at, on the clock ScreenCaptureKit stamps with") {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let start = SystemAudioBuffers.startTime(arrivedAt: mach_absolute_time(), frames: 4800, rate: 48000)
        expectClose(CMTimeGetSeconds(CMTimeSubtract(start, now)), -0.1, within: 0.005, "a tenth of a second of frames starts a tenth before")
        let later = SystemAudioBuffers.startTime(arrivedAt: hostTicks(2), frames: 480, rate: 48000)
        expectClose(CMTimeGetSeconds(CMTimeSubtract(later, now)), 1.99, within: 0.005, "two seconds of host ticks are two seconds")
        let none = SystemAudioBuffers.startTime(arrivedAt: mach_absolute_time(), frames: 0, rate: 48000)
        expectClose(CMTimeGetSeconds(CMTimeSubtract(none, now)), 0, within: 0.005, "nothing to go back by without frames")
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

    await test("system audio selection: the tap with the stream's audio as its backup, ScreenCaptureKit alone when the tap cannot be used") {
        var tries = 0
        let tap = SystemAudioSelection.choose(wanted: true, permission: .granted) { tries += 1 }
        expectEqual(tap, .tap, "the tap when it starts")
        expect(SystemAudioSelection.usesTap(wanted: true, permission: .granted), "and the writer gets a track for the backup")
        expect(SystemAudioSelection.notice(for: tap) == nil, "nothing to tell")
        expectEqual(SystemAudioSelection.choose(wanted: true, permission: .unknown) { tries += 1 }, .tap, "tried when the permission cannot be read")
        expect(SystemAudioSelection.usesTap(wanted: true, permission: .unknown), "with its backup")
        expectEqual(tries, 2, "the tap was tried twice")

        let failed = SystemAudioSelection.choose(wanted: true, permission: .granted) { throw SystemAudioTapError("The system audio format is not available") }
        guard case .screenCaptureKit(let reason, let tapFailed) = failed else { return expect(false, "a tap that cannot run at all falls back to the stream") }
        expect(reason.contains("format is not available"), "saying why: \(reason)")
        expect(tapFailed, "because the tap failed")
        let notice = try require(SystemAudioSelection.notice(for: failed), "the user is told")
        expect(notice.contains("FaceTime") && notice.contains("phone calls"), "that call audio is not included: \(notice)")

        let denied = SystemAudioSelection.choose(wanted: true, permission: .denied) { tries += 1 }
        expect(!SystemAudioSelection.usesTap(wanted: true, permission: .denied), "no permission: the stream records it, without a backup")
        expect(SystemAudioSelection.notice(for: denied)?.contains("System Audio Recording Only") == true, "and the notice says where to allow it")
        guard case .screenCaptureKit = SystemAudioSelection.choose(wanted: true, permission: .notDetermined, startTap: { tries += 1 }) else { return expect(false, "not answered: the stream records it") }
        expect(!SystemAudioSelection.usesTap(wanted: true, permission: .notDetermined), "without a backup")
        expectEqual(tries, 2, "without trying the tap")

        let none = SystemAudioSelection.choose(wanted: false, permission: .granted) { tries += 1 }
        expectEqual(none, .none, "no system audio wanted, none recorded")
        expect(!SystemAudioSelection.usesTap(wanted: false, permission: .granted) && tries == 2, "by neither source")
        expectEqual([SystemAudioRoute.none, .tap, failed].map(\.name), ["off", "on, process tap with screen capture as its backup", "on, screen capture"], "for the log")

        let once = NoticeOnce()
        expectEqual([once.take(), once.take(), once.take()], [true, false, false], "the notice is shown once")

        // Without the tap, failed or not allowed: one notification while the app runs. Only a tap that cannot run at
        // all is a warning; one that cannot be built yet is repaired by its source while the backup records.
        let launch = NoticeOnce()
        expectEqual([failed, failed, denied, failed].map { SystemAudioSelection.notifies($0, once: launch) }, [true, false, false, false], "once while the app runs")
        expectEqual(SystemAudioSelection.warning(for: failed), "Call audio is not being recorded", "a tap that cannot run is the recording's warning")
        expect(SystemAudioSelection.warning(for: denied) == nil, "not allowed: no warning on screen")
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
        expectEqual(tap.clock, .builtInOutput, "clocked by the built-in output first")
        expect(RecLog.lines.contains("System audio: process tap with the built-in output (48000 Hz, 2 ch, float32 interleaved)"), "the log says where the system audio comes from: \(RecLog.lines)")
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
        expectEqual(fakes.journal.all, ["tap1.make: builtInOutput", "tap1.stop"], "the tap is torn down")
        tap.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(20.02)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        expectEqual(received.count("sample"), 2, "nothing is handed on after the stop")
    }

    await test("system audio source: a tap that cannot be built at the start is built again in the background, and a stop ends that") {
        let fakes = FakeTapFactory()
        fakes.fails = 1
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), stallSeconds: 0.5, checkInterval: 0.02, waitScale: 0.02) { _ in }
        try source.start()
        expect(RecLog.lines.contains { $0.contains("could not be built") && $0.contains("the backup records meanwhile") }, "the start goes on, and the log says why: \(RecLog.lines)")
        expect(await waitUntil { fakes.taps.count == 1 }, "built on the next attempt, at once")
        expectEqual(fakes.journal.all, ["make failed: builtInOutput", "tap1.make: builtInOutput"], "the same construction once more")
        source.stopNow()
        // A stop while it waits ends the attempts
        let later = FakeTapFactory()
        later.fails = 1000
        let waiting = SystemAudioSource(factory: later.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), checkInterval: 0.02, waitScale: 0.02) { _ in }
        try waiting.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiting.stopNow()
        let attempts = later.journal.all.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        expectEqual(later.journal.all.count, attempts, "nothing is tried after the stop")
        expect(later.taps.isEmpty, "and no tap is made")
    }

    await test("system audio source: as the app builds it, a tap that hands on nothing for a second is dead and the next is built at once") {
        expectEqual(SystemAudioSource.stallSeconds, 1, "a second without a buffer")
        expectEqual(SystemAudioSource.checkInterval, 0.25, "looked for four times a second")
        // With the defaults, as `record()` makes it: the fake's IOProc is never called
        let fakes = FakeTapFactory()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap")) { _ in }
        let started = Date()
        try source.start()
        try? await Task.sleep(nanoseconds: 800_000_000)
        expectEqual(fakes.taps.count, 1, "not before a second has passed")
        expect(await waitUntil { fakes.taps.count >= 2 }, "then rebuilt")
        let took = Date().timeIntervalSince(started)
        expect(took > 1 && took < 1.6, "between a second and a check or two after it: \(took) s")
        expectEqual(fakes.journal.all.prefix(3), ["tap1.make: builtInOutput", "tap1.stop", "tap2.make: builtInOutput"], "the dead one torn down first")
        source.stopNow()
    }

    await test("system audio source: a tap that hands on nothing is rebuilt at once, the next construction after two failures") {
        let fakes = FakeTapFactory()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), stallSeconds: 0.1, checkInterval: 0.02, waitScale: 0.02) { _ in }
        try source.start()
        // No tap delivers anything: each is dead a tenth of a second after it was built
        expect(await waitUntil { fakes.taps.count >= 6 }, "rebuilt again and again")
        let made = fakes.taps.prefix(6).map(\.clock)
        expectEqual(made, [.builtInOutput, .builtInOutput, .none, .none, .defaultOutput, .defaultOutput], "each construction twice, in order")
        expect(fakes.journal.all.starts(with: ["tap1.make: builtInOutput", "tap1.stop", "tap2.make: builtInOutput", "tap2.stop", "tap3.make: none"]), "the dead tap torn down before the next is made: \(fakes.journal.all)")
        expect(RecLog.lines.contains { $0.contains("failed (its IOProc handed on nothing for") }, "each failure is logged: \(RecLog.lines)")
        // Then the order again from the top, for as long as the recording runs
        expect(await waitUntil { fakes.taps.count >= 8 }, "and around again")
        expectEqual(fakes.taps[6].clock, .builtInOutput, "after the last the first")
        // One that delivers stays
        let count = fakes.taps.count
        let live = try LiveTap(try require(fakes.taps.last, "the newest tap"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let kept = fakes.taps.count
        expect(kept <= count + 1, "at most the one being built when it began to deliver")
        let alive = try LiveTap(try require(fakes.taps.last, "the tap that is kept"))
        try? await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(fakes.taps.count, kept, "a tap that delivers is never rebuilt")
        source.stopNow()
        live.stop()
        alive.stop()
        expect(RecLog.lines.last?.contains("process tap stopped") == true, "the stop is logged with the count: \(RecLog.lines.suffix(2))")
    }

    await test("system audio source: a construction that cannot be built is passed over, and the failures wait longer and longer") {
        let fakes = FakeTapFactory()
        fakes.refused = [.builtInOutput]
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), stallSeconds: 0.5, checkInterval: 0.02, waitScale: 0.02) { _ in }
        try source.start()
        expect(await waitUntil { fakes.taps.count == 1 }, "built")
        expectEqual(fakes.journal.all, ["make failed: builtInOutput", "make failed: builtInOutput", "tap1.make: none"], "the built-in output twice, then no sub-device")
        source.stopNow()

        var repair = TapRepair()
        let order: [TapClock] = [.builtInOutput, .none, .defaultOutput]
        var tried = [TapClock]()
        var waits = [Double]()
        for _ in 0..<9 {
            let next = try require(repair.next(in: order), "a construction")
            tried.append(next)
            repair.trying(next)
            repair.failed()
            waits.append(repair.wait)
        }
        expectEqual(tried, [.builtInOutput, .builtInOutput, .none, .none, .defaultOutput, .defaultOutput, .builtInOutput, .builtInOutput, .none], "each twice, around and around")
        expectEqual(waits, [0, 0.5, 1, 2, 2, 2, 2, 2, 2], "at once, then doubling up to 2 s: a dead tap is never left alone for longer")
        expectEqual(TapRepair.longestWait, 2, "the longest wait")
        expectEqual(TapRepair.failuresPerConstruction, 2, "each construction twice")
        expectEqual(TapRepair.healthySeconds, 10, "and what counts as delivering again")
        repair.healthy()
        expectEqual(repair.wait, 0, "a tap that delivered long enough starts the count anew")
        expectEqual(repair.next(in: order), TapClock.none, "and keeps its construction")
        expectEqual(repair.next(in: [TapClock.none]), TapClock.none, "the order can change: what is left of it")
        expect(TapRepair().next(in: []) == nil, "nothing to build without any construction")
    }

    await test("system audio source: a rate change rebuilds at once, and nothing of an old tap comes after the new one") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tap")
        var times = [Double]()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue, stallSeconds: 5, checkInterval: 0.02, waitScale: 0.02) { times.append(CMTimeGetSeconds($0.pts)) }
        try source.start()
        let first = try require(fakes.taps.first, "the first tap")
        first.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(30)))
        first.outputChanged()
        expect(await waitUntil { fakes.taps.count == 2 }, "rebuilt")
        expectEqual(fakes.journal.all, ["tap1.make: builtInOutput", "tap1.stop", "tap2.make: builtInOutput"], "the old tap torn down before the new one is made")
        expect(RecLog.lines.contains { $0.contains("its device changed its rate or went away") }, "logged: \(RecLog.lines)")
        let second = try require(fakes.taps.last, "the second tap")
        second.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(31)))
        // The old IOProc's last call, late: it must not follow the new tap's audio
        first.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(30.5)))
        queue.sync {}
        second.deliver(try tapBuffer(tapFormat(interleaved: true), frames: 480, at: time(31.01)))
        expect(await waitUntil { times.count >= 3 }, "the new tap's audio arrives")
        queue.sync {}
        expectEqual(times, [30, 31, 31.01], "nothing of the old tap after the new one started")
        source.stopNow()
    }

    await test("system audio source: the order and the fallback with the real tap on fake hardware") {
        func run(_ setUp: (FakeTapHardware) -> Void, deliver: Bool = true) async throws -> FakeTapHardware {
            let hardware = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
            hardware.output = TapOutputDevice(id: 41, uid: "airpods-uid", name: "AirPods")
            setUp(hardware)
            let factory = SystemAudioSource.Factory(constructions: {
                TapClock.order(builtIn: hardware.builtInOutputDevice(), defaultOutput: try? hardware.defaultOutputDevice())
            }, makeTap: { clock, queue, deliver, changed in
                try SystemAudioTap(hardware: hardware, clock: clock, queue: queue, deliver: deliver, outputChanged: changed)
            })
            let source = SystemAudioSource(factory: factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), stallSeconds: deliver ? 5 : 0.1, checkInterval: 0.02, waitScale: 0.02) { _ in }
            try source.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            source.stopNow()
            return hardware
        }
        expectEqual(try await run { _ in }.mains, ["builtin-uid"], "the built-in output, while the default output is the AirPods")
        expectEqual(try await run { $0.refusedClocks = ["builtin-uid"] }.mains, ["builtin-uid", "builtin-uid", nil], "then no sub-device")
        expectEqual(try await run { $0.refusedClocks = ["builtin-uid", nil] }.mains, ["builtin-uid", "builtin-uid", nil, nil, "airpods-uid"], "the default output last")
        expectEqual(try await run { $0.builtIn = nil }.mains, [nil], "a Mac without a built-in output starts without a sub-device")
        expectEqual(try await run({ $0.output = TapOutputDevice(id: 30, uid: "builtin-uid", name: "MacBook Pro Speakers"); $0.refusedClocks = ["builtin-uid", nil] }).mains.prefix(5),
                    ["builtin-uid", "builtin-uid", nil, nil, "builtin-uid"], "the built-in output as the default output is not tried as such again")
        // A tap whose IOProc is never called, as today's AirPods were: dead within the stall time, the next one built
        let dead = try await run({ _ in }, deliver: false)
        expect(dead.mains.prefix(3) == ["builtin-uid", "builtin-uid", nil], "an IOProc that is never called is rebuilt, then the next construction: \(dead.mains)")
        expect(dead.journal.all.filter { $0 == "destroyTap" }.count >= 2, "and each dead tap is torn down")
    }

    await test("system audio source: the writer records the tap's audio like ScreenCaptureKit's") {
        let fakes = FakeTapFactory()
        let queue = DispatchQueue(label: "HoldfastTests.tapWriter")
        let run = try TestRecording(folder: "tap-writer", audioOnly: true, microphone: false, tap: true)
        try run.writer.prepareAudio()
        run.writer.startCapturing()
        // Each buffer arrives as its last frame is captured
        var arrival = 0.0
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: queue, stallSeconds: 60, clock: { run.at(arrival) }) { run.writer.write($0) }
        try source.start()
        let tap = try require(fakes.taps.first, "a tap")
        // Two seconds from an output device at 44.1 kHz, interleaved, as a tap may deliver them
        let format = tapFormat(rate: 44100, interleaved: true)
        for index in 0..<200 {
            arrival = Double(index + 1) / 100
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
