// Plays a pulsed tone so microphone tests have a real acoustic signal even in a silent room: on the output device
// whose name contains the given text, or else on the Mac's built-in speakers (the system default output when it
// has none).
// Usage: tonegen [seconds] [device-name-substring] [volume 0-1]
import AVFoundation
import CoreAudio
import Foundation

let secs = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let want = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let vol = Float(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "0.5") ?? 0.5

struct Output {
    let id: AudioDeviceID
    let name: String
    let builtIn: Bool
}

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var request = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &request, 0, nil, &size, &value) == noErr ? value : nil
}

func name(of device: AudioDeviceID) -> String {
    var request = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &request, 0, nil, &size, &name) == noErr, let name else { return "?" }
    return name.takeRetainedValue() as String
}

func outputs() -> [Output] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &devices, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &devices, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
        return Output(id: id, name: name(of: id), builtIn: uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn)
    }
}

let available = outputs()
let defaultID = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
let chosen = want.map { name in available.first { $0.name.localizedCaseInsensitiveContains(name) } }
    ?? available.first { $0.builtIn } ?? available.first { $0.id == defaultID }
guard let device = chosen else {
    print("tonegen: no output device\(want.map { " matching '\($0)'" } ?? ""). Outputs: \(available.map(\.name))")
    exit(1)
}
let engine = AVAudioEngine()
guard let outputUnit = engine.outputNode.audioUnit else {
    print("tonegen: the engine has no output unit")
    exit(1)
}
var deviceID = device.id
let err = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
if err != noErr { print("tonegen: could not select device (\(err))"); exit(1) }
let sr = engine.outputNode.inputFormat(forBus: 0).sampleRate
var phase = 0.0, n = 0.0
// 0.35 s beep at 880 Hz, 0.15 s gap: easy to tell from noise, continuous enough for 2 s windows.
let src = AVAudioSourceNode { _, _, frames, abl in
    let bufs = UnsafeMutableAudioBufferListPointer(abl)
    for i in 0..<Int(frames) {
        let t = n / sr
        let on = t.truncatingRemainder(dividingBy: 0.5) < 0.35
        let v = on ? Float(sin(phase)) * vol : 0
        phase += 2 * .pi * 880 / sr; n += 1
        for b in bufs { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
    }
    return noErr
}
guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
    print("tonegen: no stereo format at \(sr) Hz")
    exit(1)
}
engine.attach(src)
engine.connect(src, to: engine.mainMixerNode, format: format)
do { try engine.start() } catch { print("tonegen: \(error)"); exit(1) }
print("tonegen: pulsing 880 Hz on '\(device.name)' for \(secs)s at volume \(vol)"); fflush(stdout)
Thread.sleep(forTimeInterval: secs)
engine.stop()
