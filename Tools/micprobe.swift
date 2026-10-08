// Compares microphone capture strategies under a mid-capture "call" (run fakecall alongside).
// Usage: micprobe [engine|engine-restart|capture|sck] [seconds] (engine when none is given)
// Prints buffers received and RMS per second so stalls are visible.
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "engine"
let secs = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 30 : 30

final class Stats {
    let lock = NSLock()
    var bufs = 0, frames = 0, sumSq = 0.0, rate = 0.0
    func add(frames n: Int, sumSq s: Double, rate r: Double) { lock.lock(); bufs += 1; frames += n; sumSq += s; rate = r; lock.unlock() }
    func take() -> (Int, Int, Double, Double) { lock.lock(); defer { bufs = 0; frames = 0; sumSq = 0; lock.unlock() }; return (bufs, frames, sumSq, rate) }
}
let stats = Stats()
func note(_ s: String) { print(s); fflush(stdout) }

func measure(_ b: AVAudioPCMBuffer) {
    let n = Int(b.frameLength); var s = 0.0
    if let d = b.floatChannelData { for i in 0..<n { let v = Double(d[0][i]); s += v * v } }
    stats.add(frames: n, sumSq: s, rate: b.format.sampleRate)
}
func measure(_ sb: CMSampleBuffer) {
    var s = 0.0, n = 0
    let rate = sb.formatDescription?.audioStreamBasicDescription?.mSampleRate ?? 0
    let asbd = sb.formatDescription?.audioStreamBasicDescription
    try? sb.withAudioBufferList { abl, _ in
        guard let b = abl.first, let p = b.mData, let a = asbd else { return }
        if a.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let c = Int(b.mDataByteSize) / 4; let f = p.bindMemory(to: Float.self, capacity: c)
            for i in 0..<c { s += Double(f[i] * f[i]) }; n = c
        } else {
            let c = Int(b.mDataByteSize) / 2; let f = p.bindMemory(to: Int16.self, capacity: c)
            for i in 0..<c { let v = Double(f[i]) / 32768; s += v * v }; n = c
        }
    }
    stats.add(frames: n, sumSq: s, rate: rate)
}

// MARK: engine / engine-restart
let engine = AVAudioEngine()
func startEngine() {
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let fmt = input.inputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in measure(b) }
    do { try engine.start(); note("  engine started, input \(fmt.sampleRate) Hz x\(fmt.channelCount)") } catch { note("  engine start failed: \(error)") }
}

// MARK: capture session
final class Cap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    func start() {
        guard let dev = AVCaptureDevice.default(for: .audio), let inp = try? AVCaptureDeviceInput(device: dev) else { note("  no capture device"); return }
        note("  capture device: \(dev.localizedName)")
        session.addInput(inp)
        let out = AVCaptureAudioDataOutput(); out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cap"))
        session.addOutput(out); session.startRunning()
        for n in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification, AVCaptureSession.didStopRunningNotification] {
            NotificationCenter.default.addObserver(forName: n, object: session, queue: nil) { x in note("  capture notification: \(x.name.rawValue) \(x.userInfo ?? [:])") }
        }
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) { measure(sb) }
}
let cap = Cap()

// MARK: ScreenCaptureKit microphone
final class SCK: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let cfg = SCStreamConfiguration()
            cfg.width = 2; cfg.height = 2; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.capturesAudio = true
            cfg.captureMicrophone = true
            let s = SCStream(filter: SCContentFilter(display: content.displays[0], excludingWindows: []), configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "sckmic"))
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sckaud"))
            try await s.startCapture(); stream = s
            note("  sck stream started with captureMicrophone")
        } catch { note("  sck start failed: \(error)") }
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .microphone { measure(sb) }
    }
    func stream(_ s: SCStream, didStopWithError e: Error) { note("  sck stopped: \(e)") }
}
let sck = SCK()

NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    note("  AVAudioEngineConfigurationChange (engine running: \(engine.isRunning))")
    if mode == "engine-restart" { DispatchQueue.main.async { startEngine() } }
}

note("mode=\(mode) for \(secs)s")
switch mode {
case "engine", "engine-restart": startEngine()
case "capture": cap.start()
case "sck": Task { await sck.start() }
default: note("unknown mode"); exit(2)
}
var t = 0
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    t += 1
    let (b, f, s, r) = stats.take()
    let db = f > 0 && s > 0 ? 20 * log10((s / Double(f)).squareRoot()) : -180
    note(String(format: "t=%2d bufs=%3d frames=%6d rate=%5.0f rms=%6.1f dB%@", t, b, f, r, db, b == 0 ? "   <-- NO DATA" : ""))
    if t >= secs { exit(0) }
}
RunLoop.main.run()
