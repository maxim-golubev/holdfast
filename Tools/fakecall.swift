// Simulates a call app taking the microphone: opens the default input with
// voice processing enabled (as Zoom/FaceTime/Meet do) for N seconds, then releases it.
// Usage: fakecall [seconds]
import AVFoundation
import Foundation

let secs = Double(CommandLine.arguments.dropFirst().first ?? "15") ?? 15
let engine = AVAudioEngine()
let input = engine.inputNode
do {
    try input.setVoiceProcessingEnabled(true)
} catch {
    print("fakecall: could not enable voice processing: \(error)")
}
let fmt = input.outputFormat(forBus: 0)
var buffers = 0
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { _, _ in buffers += 1 }
do {
    try engine.start()
    print("fakecall: mic open with voice processing, format \(fmt.sampleRate) Hz x\(fmt.channelCount), holding \(secs)s")
} catch {
    print("fakecall: engine failed to start: \(error)")
    exit(1)
}
Thread.sleep(forTimeInterval: secs)
input.removeTap(onBus: 0)
engine.stop()
print("fakecall: released mic after \(buffers) buffers")
