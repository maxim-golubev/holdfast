// Plays a pulsed tone on a named output device (default: built-in speakers) so microphone
// tests have a real acoustic signal even in a silent room.
// Usage: tonegen [seconds] [device-name-substring] [volume 0-1]
import AVFoundation
import CoreAudio
import Foundation

let secs = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let want = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "MacBook Pro Speakers"
let vol = Float(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "0.5") ?? 0.5

func devices() -> [(AudioDeviceID, String, Bool)] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids.map { id in
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &n, 0, nil, &s, &name)
        var o = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var os: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &o, 0, nil, &os)
        return (id, (name?.takeRetainedValue() as String?) ?? "?", os > 0)
    }
}
guard let dev = devices().first(where: { $0.2 && $0.1.localizedCaseInsensitiveContains(want) }) else {
    print("tonegen: no output device matching '\(want)'. Outputs: \(devices().filter { $0.2 }.map { $0.1 })"); exit(1)
}
let engine = AVAudioEngine()
var id = dev.0
let err = AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
if err != noErr { print("tonegen: could not select device (\(err))"); exit(1) }
let fmt = engine.outputNode.inputFormat(forBus: 0)
let sr = fmt.sampleRate
var phase = 0.0, n = 0.0
// 0.35 s beep at 880 Hz, 0.15 s gap: easy to tell from noise, continuous enough for 2 s windows.
let src = AVAudioSourceNode { _, _, frames, abl in
    let bufs = UnsafeMutableAudioBufferListPointer(abl)
    for i in 0..<Int(frames) {
        let t = n / sr
        let on = t.truncatingRemainder(dividingBy: 0.5) < 0.35
        let v = on ? Float(sin(phase)) * vol : 0
        phase += 2 * .pi * 880 / sr; n += 1
        for b in bufs { b.mData!.assumingMemoryBound(to: Float.self)[i] = v }
    }
    return noErr
}
engine.attach(src)
engine.connect(src, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
do { try engine.start() } catch { print("tonegen: \(error)"); exit(1) }
print("tonegen: pulsing 880 Hz on '\(dev.1)' for \(secs)s at volume \(vol)"); fflush(stdout)
Thread.sleep(forTimeInterval: secs)
engine.stop()
