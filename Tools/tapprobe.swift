// Measures what a Core Audio process tap hears, to find out whether call audio (FaceTime, phone calls through the
// iPhone) reaches it. FaceTime and Continuity calls play through the system process avconferenced.
// A private tap, left audible, in a private aggregate device with drift compensation, and an IOProc that uses only
// the tap's stream (an output device's own input and output streams are turned off, so a headset's microphone is not
// opened). The aggregate device runs from the start, also while nothing plays (no
// kAudioAggregateDeviceTapAutoStartKey, which makes the start wait for the first sound): run it in silence and every
// second must still have callbacks, at -180 dB.
// Usage: tapprobe [global|calls|calltap] [seconds]
//   global:  everything the Mac plays, in an aggregate device whose main sub-device is the default output
//   calls:   only avconferenced (start the call first: it has no audio object before), built the same way
//   calltap: only avconferenced, alone in its aggregate device, with no sub-device: Holdfast's call tap
//            (SystemAudioTap with TapClock.callOrder), the second tap that records call audio on its own track
// Prints the formats, the IO buffers of the first callback, then the level once a second. Needs the "System Audio
// Recording Only" permission for the process it runs in (macOS asks the first time); a process without it gets a
// tap that runs and delivers only zeros.
// Build: swiftc -O Tools/tapprobe.swift -o build/tapprobe
import AudioToolbox
import CoreAudio
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "global"
let seconds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 30 : 30
guard mode == "global" || mode == "calls" || mode == "calltap" else {
    print("usage: tapprobe [global|calls|calltap] [seconds]")
    exit(2)
}
let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    return AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var where_ = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &where_, 0, nil, &size, $0) }
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var value: Unmanaged<CFString>?
    guard property(object, selector, &value) == noErr, let found = value else { return nil }
    return found.takeRetainedValue() as String
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    let float = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    return "\(Int(f.mSampleRate)) Hz, \(f.mChannelsPerFrame) ch, \(float ? "float" : "int")\(f.mBitsPerChannel), \(interleaved ? "interleaved" : "non-interleaved"), \(f.mBytesPerFrame) bytes/frame"
}

func processObjects() -> [(AudioObjectID, pid_t, String)] {
    var where_ = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        var pid: pid_t = 0
        _ = property(id, kAudioProcessPropertyPID, &pid)
        let bundle = string(id, kAudioProcessPropertyBundleID) ?? ""
        var path = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &path, UInt32(path.count))
        let name = String(cString: path).components(separatedBy: "/").last ?? "?"
        return (id, pid, bundle.isEmpty ? name : bundle)
    }
}

// The default output device, which drives the aggregate device's clock
var output = AudioObjectID(kAudioObjectUnknown)
guard property(system, kAudioHardwarePropertyDefaultOutputDevice, &output) == noErr, output != AudioObjectID(kAudioObjectUnknown),
      let outputUID = string(output, kAudioDevicePropertyDeviceUID) else {
    print("no default output device")
    exit(1)
}
var outputRate: Float64 = 0
_ = property(output, kAudioDevicePropertyNominalSampleRate, &outputRate)
print("default output: \(string(output, kAudioObjectPropertyName) ?? outputUID) (\(Int(outputRate)) Hz)")

let description: CATapDescription
switch mode {
case "calls", "calltap":
    let calls = processObjects().filter { $0.2.contains("avconferenced") }
    print("avconferenced audio objects: \(calls.map { "pid \($0.1) object \($0.0)" })")
    guard !calls.isEmpty else { print("avconferenced has no audio object now (no call running?)"); exit(1) }
    description = CATapDescription(stereoMixdownOfProcesses: calls.map { $0.0 })
default:
    description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
}
description.name = "tapprobe"
description.isPrivate = true
description.muteBehavior = .unmuted
var tap = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(description, &tap)
guard status == noErr else { print("cannot create the tap: \(status)"); exit(1) }
guard let tapUID = string(tap, kAudioTapPropertyUID) else { print("cannot read the tap's UID"); exit(1) }
var tapFormat = AudioStreamBasicDescription()
_ = property(tap, kAudioTapPropertyFormat, &tapFormat)
print("tap format: \(describe(tapFormat))")

var aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: "tapprobe",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
]
if mode == "calltap" {
    print("aggregate device: the tap alone, no sub-device")
} else {
    aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
    aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
}
var device = AudioObjectID(kAudioObjectUnknown)
status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
guard status == noErr else { print("cannot create the aggregate device: \(status)"); AudioHardwareDestroyProcessTap(tap); exit(1) }
var aggregateRate: Float64 = 0
_ = property(device, kAudioDevicePropertyNominalSampleRate, &aggregateRate)
print("aggregate device: \(Int(aggregateRate)) Hz")

final class Meter: @unchecked Sendable {
    let lock = NSLock()
    var sumSq = 0.0, count = 0, peak: Float = 0, callbacks = 0
    var firstLayout: String?
}
let meter = Meter()
// The tap's stream is the last of the input: one buffer when interleaved, one per channel otherwise
let tapBuffers = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : Int(tapFormat.mChannelsPerFrame)
var procID: AudioDeviceIOProcID?
status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    var layout: String?
    if meter.firstLayout == nil {
        layout = "\(buffers.count) input buffers: " + buffers.map { "\($0.mNumberChannels) ch \($0.mDataByteSize) bytes" }.joined(separator: ", ")
            + "; host time \(inputTime.pointee.mFlags.contains(.hostTimeValid) ? "valid" : "not valid")"
    }
    var s = 0.0, n = 0
    var p: Float = 0
    for buffer in buffers.suffix(tapBuffers) {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let c = Int(buffer.mDataByteSize) / 4
        for i in 0..<c { let v = samples[i]; s += Double(v * v); p = max(p, abs(v)) }
        n += c
    }
    meter.lock.lock()
    if let layout = layout { meter.firstLayout = layout }
    meter.sumSq += s; meter.count += n; meter.peak = max(meter.peak, p); meter.callbacks += 1
    meter.lock.unlock()
}
guard status == noErr, let procID else {
    print("cannot create the IO proc: \(status)")
    AudioHardwareDestroyAggregateDevice(device)
    AudioHardwareDestroyProcessTap(tap)
    exit(1)
}
// Only the tap's stream, the last input stream; none of the output device's own streams
for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
    let input = scope == kAudioObjectPropertyScopeInput
    var streamsAddress = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &size) == noErr else { print("cannot read the \(input ? "input" : "output") streams"); continue }
    let streams = Int(size) / MemoryLayout<AudioStreamID>.size
    guard streams > 0 else { continue }
    let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12
    let bytes = max(MemoryLayout<AudioHardwareIOProcStreamUsage>.size, flagsOffset + 4 * streams)
    let usage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
    usage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    usage.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), toByteOffset: 0, as: UnsafeMutableRawPointer.self)
    usage.storeBytes(of: UInt32(streams), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
    for index in 0..<streams { usage.storeBytes(of: input && index == streams - 1 ? 1 : 0, toByteOffset: flagsOffset + 4 * index, as: UInt32.self) }
    var usageAddress = address(kAudioDevicePropertyIOProcStreamUsage, scope)
    let result = AudioObjectSetPropertyData(device, &usageAddress, 0, nil, UInt32(bytes), usage)
    usage.deallocate()
    print("\(input ? "input" : "output") streams: \(streams), \(input ? "only the last (the tap's) on" : "all off")\(result == noErr ? "" : " FAILED (\(result))")")
}
status = AudioDeviceStart(device, procID)
guard status == noErr else {
    print("cannot start: \(status)")
    AudioDeviceDestroyIOProcID(device, procID)
    AudioHardwareDestroyAggregateDevice(device)
    AudioHardwareDestroyProcessTap(tap)
    exit(1)
}
print("tap '\(mode)' running for \(seconds) s; -180 dB is digital silence (no sound, or no permission)")
var printedLayout = false
for t in 1...max(1, seconds) {
    sleep(1)
    meter.lock.lock()
    let rms = meter.count > 0 ? (meter.sumSq / Double(meter.count)).squareRoot() : 0
    let line = String(format: "t=%2d callbacks=%3d rms=%6.1f dB peak=%6.1f dB", t, meter.callbacks, rms > 0 ? 20 * log10(rms) : -180, meter.peak > 0 ? 20 * log10(Double(meter.peak)) : -180)
    let layout = printedLayout ? nil : meter.firstLayout
    meter.sumSq = 0; meter.count = 0; meter.peak = 0; meter.callbacks = 0
    meter.lock.unlock()
    if let layout = layout { print(layout); printedLayout = true }
    print(line); fflush(stdout)
}
// The order Holdfast tears down in: stop, IOProc, aggregate device, tap
AudioDeviceStop(device, procID)
AudioDeviceDestroyIOProcID(device, procID)
AudioHardwareDestroyAggregateDevice(device)
AudioHardwareDestroyProcessTap(tap)
