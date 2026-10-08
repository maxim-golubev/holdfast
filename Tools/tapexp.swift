// Compares process-tap constructions under a Bluetooth headset's call mode, to find one whose IOProc never stops.
// Usage: tapexp <output|builtin|taponly> [seconds] [outfile]
//   output:  the aggregate device's clock is the current default output (Holdfast 1.0's construction)
//   builtin: its clock is the Mac's built-in output, whatever the default output is doing
//   taponly: no sub-device at all, the tap alone
// Prints IOProc callbacks and the level once a second; "<-- DEAD" marks a second with no callback. With `outfile`
// it writes there instead of to standard output.
//
// It must run inside an app bundle with Holdfast's identity to hear anything: bundle id com.maximgolubev.Holdfast,
// NSAudioCaptureUsageDescription in its Info.plist, signed with the project's Apple Development identity, launched
// with `open`, so macOS gives it Holdfast's "System Audio Recording Only" permission. Started from a terminal it has
// no such grant: its tap runs and its IOProc is called, but every buffer is zeros (-180 dB), whatever plays.
// To build and launch it that way, from the repository's root:
//   b=build/TapExp.app; rm -rf $b; mkdir -p $b/Contents/MacOS
//   swiftc -O Tools/tapexp.swift -o $b/Contents/MacOS/tapexp
//   /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.maximgolubev.Holdfast" \
//     -c "Add :CFBundleExecutable string tapexp" -c "Add :CFBundlePackageType string APPL" -c "Add :LSUIElement bool true" \
//     -c "Add :NSAudioCaptureUsageDescription string 'Holdfast records the sound your Mac plays.'" $b/Contents/Info.plist
//   codesign --force --sign "Apple Development" --options runtime $b
//   open -n -W $b --args builtin 10 "$PWD/build/tapexp-builtin.txt"; cat build/tapexp-builtin.txt
// Remove build/TapExp.app afterwards.
import AudioToolbox
import CoreAudio
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "output"
let seconds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 10 : 10
// A bundle launched with `open` has no terminal: the report goes to the file named
if CommandLine.arguments.count > 3, freopen(CommandLine.arguments[3], "w", stdout) == nil {
    FileHandle.standardError.write(Data("cannot write \(CommandLine.arguments[3])\n".utf8))
    exit(1)
}
let system = AudioObjectID(kAudioObjectSystemObject)

func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
}
func uid(_ device: AudioObjectID) -> String {
    var u: Unmanaged<CFString>?
    _ = get(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &u)
    return (u?.takeRetainedValue() as String?) ?? ""
}
func name(_ device: AudioObjectID) -> String {
    var u: Unmanaged<CFString>?
    _ = get(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &u)
    return (u?.takeRetainedValue() as String?) ?? "?"
}
func devices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
    return ids
}
func rate(_ device: AudioObjectID) -> Double { var r: Float64 = 0; _ = get(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &r); return r }
func transport(_ device: AudioObjectID) -> UInt32 { var t: UInt32 = 0; _ = get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &t); return t }

var defaultOut = AudioObjectID(0)
_ = get(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &defaultOut)
print("default output: \(name(defaultOut)) \(Int(rate(defaultOut))) Hz")

var me = AudioObjectID(0)
var pid = getpid()
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
let description = CATapDescription(stereoGlobalTapButExcludeProcesses: me == 0 ? [] : [me])
description.isPrivate = true
description.muteBehavior = .unmuted
var tap = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { print("cannot create the tap"); exit(1) }
var tapUID: Unmanaged<CFString>?
_ = get(tap, kAudioTapPropertyUID, kAudioObjectPropertyScopeGlobal, &tapUID)
let tapID = (tapUID?.takeRetainedValue() as String?) ?? ""

var dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "tapexp", kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapID, kAudioSubTapDriftCompensationKey: true]],
]
switch mode {
case "output":
    dict[kAudioAggregateDeviceMainSubDeviceKey] = uid(defaultOut)
    dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid(defaultOut)]]
case "builtin":
    guard let builtin = devices().first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn && name($0).contains("Speakers") }) else { print("no built-in speakers"); exit(1) }
    print("clock: \(name(builtin)) \(Int(rate(builtin))) Hz")
    dict[kAudioAggregateDeviceMainSubDeviceKey] = uid(builtin)
    dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid(builtin)]]
default:
    break
}
var device = AudioObjectID(kAudioObjectUnknown)
let created = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &device)
guard created == noErr else { print("cannot create the aggregate device: \(created)"); exit(1) }
print("aggregate: \(Int(rate(device))) Hz")

final class Meter: @unchecked Sendable { let lock = NSLock(); var calls = 0, n = 0, bad = 0, buffers = 0; var sum = 0.0 }
let meter = Meter()
var proc: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
    var s = 0.0, c = 0, bad = 0, buffers = 0
    for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
        buffers += 1
        guard let d = b.mData else { continue }
        let f = d.assumingMemoryBound(to: Float.self); let k = Int(b.mDataByteSize) / 4
        for i in 0..<k { let v = f[i]; if v.isFinite { s += Double(v * v); c += 1 } else { bad += 1 } }
    }
    meter.lock.lock(); meter.calls += 1; meter.sum += s; meter.n += c; meter.bad += bad; meter.buffers = buffers; meter.lock.unlock()
}
guard let proc, AudioDeviceStart(device, proc) == noErr else { print("cannot start"); exit(1) }
for t in 1...seconds {
    sleep(1)
    meter.lock.lock()
    let rms = meter.n > 0 ? (meter.sum / Double(meter.n)).squareRoot() : 0
    let db = rms > 0 ? 20 * log10(rms) : -180.0
    print("  t=\(t) calls=\(meter.calls) buffers/call=\(meter.buffers) samples=\(meter.n) level=\(String(format: "%.1f", db)) dB non-finite=\(meter.bad)" + (meter.calls == 0 ? "   <-- DEAD" : ""))
    meter.calls = 0; meter.sum = 0; meter.n = 0; meter.bad = 0
    meter.lock.unlock(); fflush(stdout)
}
AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc)
AudioHardwareDestroyAggregateDevice(device); AudioHardwareDestroyProcessTap(tap)
