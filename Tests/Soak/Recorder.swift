//
//  Recorder.swift
//  Drives the real MovieWriter and RecordingMonitor through the planned meeting on a simulated clock, as fast as
//  the writer takes the buffers.
//

import AVFoundation
import Foundation

/// The app's log, replaced here so that nothing is written to ~/Library/Logs. Lines carry the simulated time.
enum RecLog {
    static var now = 0.0
    static var lines = [String]()
    static func write(_ message: String) {
        let line = String(format: "[%8.3f s] ", now) + message
        lines.append(line)
    }
}

/// The real writer as the monitor sees it. Everything goes to the `MovieWriter`; only `clockAnchor` differs: the
/// writer stamps the arrival of a buffer with the real uptime, and this simulation delivers buffers far faster than
/// real time, so the anchor is given the simulated uptime at which that buffer arrived. The monitor then tells the
/// present exactly as it would in a live recording.
final class SimulatedClockWriter: RecordingWriter {
    let real: MovieWriter
    private var realAnchor: (raw: CMTime, uptime: UInt64)?
    private(set) var clockAnchor: (raw: CMTime, uptime: UInt64)?

    init(_ real: MovieWriter) { self.real = real }

    /// A buffer of the capture arrives at `uptime` (simulated)
    func deliver(_ sample: CaptureSample, at uptime: UInt64) {
        real.write(sample)
        if let anchor = real.clockAnchor, realAnchor.map({ $0.raw != anchor.raw || $0.uptime != anchor.uptime }) ?? true {
            realAnchor = anchor
            clockAnchor = (anchor.raw, uptime)
        }
    }

    var recording: RecordingContext { real.recording }
    var events: MovieWriter.Events {
        get { real.events }
        set { real.events = newValue }
    }
    var isCapturing: Bool { real.isCapturing }
    var isPaused: Bool { real.isPaused }
    var isResume: Bool { real.isResume }
    var sessionStart: CMTime? { real.sessionStart }
    var audioEndPTS: CMTime? { real.audioEndPTS }
    var hasSystemAudio: Bool { real.hasSystemAudio }
    var hasMicrophoneTrack: Bool { real.hasMicrophoneTrack }
    var isMicrophoneMuted: Bool { real.isMicrophoneMuted }
    func startCapturing() { real.startCapturing() }
    func togglePause() -> Bool { real.togglePause() }
    func setMicrophoneMuted(_ muted: Bool) { real.setMicrophoneMuted(muted) }
    func write(_ sample: CaptureSample) { real.write(sample) }
    func checkWriter() -> Bool { real.checkWriter() }
    func timelineTime(_ raw: CMTime) -> CMTime { real.timelineTime(raw) }
    func fillMicrophone(upTo time: CMTime) { real.fillMicrophone(upTo: time) }
    func fillSystemAudio(upTo time: CMTime) { real.fillSystemAudio(upTo: time) }
    func repeatVideoFrame(at now: CMTime) { real.repeatVideoFrame(at: now) }
    func currentPicture() -> CMSampleBuffer? { real.currentPicture() }
    func finish() -> MovieWriter.Finished { real.finish() }
    func cancel() { real.cancel() }
}

/// What the simulated recording did, for the report
struct RunStats {
    var events = 0
    var frames = 0
    var systemBuffers = 0
    var micBuffers = 0
    var ticks = 0
    /// Times the feed waited for a writer input that was not ready, and for how long in all
    var waits = 0
    var waitSeconds = 0.0
    /// Buffers delivered while the recording was taking them that the writer's input did not take
    var framesNotTaken = 0
    var systemNotTaken = 0
    var notifications = [(time: Double, title: String)]()
    var failures = [String]()
    var sessionStart: Double?
    var pauseOffset = 0.0
    var feedSeconds = 0.0
    /// Microphone buffers the converter dropped: when they arrived
    var micDrops = [String]()
    /// Frames the monitor wrote again, and when, outside the static slide
    var repeats = 0
    var repeatsElsewhere = [Double]()
    /// The process's memory footprint every ten simulated minutes, in MB
    var footprints = [(time: Double, megabytes: Double)]()
    /// The footprint before and after the writer was given 5 s to catch up, in MB
    var settled = [(time: Double, before: Double, after: Double)]()
}

/// The memory the system counts against the process now (what Activity Monitor shows), in MB
func currentFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

final class SimulatedRecording {
    let queue = DispatchQueue(label: "Soak.sample-queue")
    let recording: RecordingContext
    let writer: MovieWriter
    let clockWriter: SimulatedClockWriter
    let monitor: RecordingMonitor
    var stats = RunStats()
    private var inputs = [AVAssetWriterInput]()
    private var pixelPool: CVPixelBufferPool?
    private var systemSignal = SplitMix(seed: 0x5353_4947)
    private var micSignal = SplitMix(seed: 0x4D53_4947)

    init(folder: URL) throws {
        recording = RecordingContext(audioOnly: false, recordMic: true, fastStart: false, saveDirectory: folder.path)
        guard let converter = MicConverter() else { throw SoakError("no microphone converter") }
        writer = MovieWriter(recording: recording, micConverter: converter)
        clockWriter = SimulatedClockWriter(writer)
        monitor = RecordingMonitor(queue: queue)
    }

    /// Creates the file as `record()` does, and wires the writer to the monitor as `RecordingSession.install` does
    func prepare() throws {
        try writer.prepareVideo(width: Plan.width, height: Plan.height)
        // The writer's inputs, to wait for them the way a machine that keeps up in real time never has to
        inputs = Mirror(reflecting: writer).children.compactMap { child in
            guard let label = child.label, label.hasSuffix("Input") else { return nil }
            return child.value as? AVAssetWriterInput
        }
        guard inputs.count == 3 else { throw SoakError("expected three writer inputs, found \(inputs.count)") }
        writer.events.failed = { [unowned self] reason in stats.failures.append(String(format: "%.3f s: ", RecLog.now) + reason) }
        writer.events.microphoneWritten = { [monitor] end, peak in monitor.microphoneWritten(upTo: end, peak: peak) }
        writer.events.systemAudioWritten = { [monitor] end in monitor.systemAudioWritten(upTo: end) }
        monitor.notify = { [unowned self] title, _ in stats.notifications.append((RecLog.now, title)) }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Plan.width,
            kCVPixelBufferHeightKey as String: Plan.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pixelPool)
    }

    private func waitForInputs() {
        guard !inputs.allSatisfy({ $0.isReadyForMoreMediaData }) else { return }
        let started = Date()
        stats.waits += 1
        while !inputs.allSatisfy({ $0.isReadyForMoreMediaData }) && Date().timeIntervalSince(started) < 30 {
            usleep(100)
        }
        stats.waitSeconds += Date().timeIntervalSince(started)
    }

    // MARK: - Buffers

    /// A frame with its time code: 16 bits of the frame number and their complement as 8 x 9 blocks, black or white
    private func frameBuffer(_ frame: VideoFrame) throws -> CMSampleBuffer {
        var made: CVPixelBuffer?
        if let pool = pixelPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) }
        guard let pixels = made else { throw SoakError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<Plan.height {
                for x in 0..<Plan.width {
                    let block = (y / 9) * 8 + x / 8
                    let bit = block < 16 ? (frame.number >> block) & 1 : 1 - ((frame.number >> (block - 16)) & 1)
                    let value: UInt8 = bit == 1 ? 255 : 0
                    let pixel = bytes + y * row + x * 4
                    pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let description = try CMVideoFormatDescription(imageBuffer: pixels)
        // ScreenCaptureKit's frames carry no duration
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: Plan.stamp(frame.pts), decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixels, formatDescription: description, sampleTiming: timing)
    }

    private func pcmBuffer(rate: Double, channels: UInt32, frames: Int, at pts: CMTime, fill: (UnsafePointer<UnsafeMutablePointer<Float>>) -> Void) throws -> CMSampleBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = pcm.floatChannelData else { throw SoakError("no audio buffer") }
        pcm.frameLength = AVAudioFrameCount(frames)
        fill(data)
        guard let buffer = AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: pts) else { throw SoakError("no sample buffer") }
        return buffer
    }

    private func systemBuffer(_ buffer: SystemBuffer) throws -> CMSampleBuffer {
        let first = buffer.index * Plan.systemFrames
        return try pcmBuffer(rate: Plan.systemRate, channels: 2, frames: Plan.systemFrames, at: Plan.stamp(buffer.pts)) { data in
            for i in 0..<Plan.systemFrames {
                let t = Double(first + i) / Plan.systemRate
                let tone = Plan.tone(at: t, first: 10, frequencyBase: 1000)
                data[0][i] = tone + Plan.systemNoise * systemSignal.noise()
                data[1][i] = tone + Plan.systemNoise * systemSignal.noise()
            }
        }
    }

    /// The device's samples are spaced by its own (fast) clock; what they carry is what sounded at that time
    private func micBuffer(_ buffer: MicBuffer) throws -> CMSampleBuffer {
        let rate = buffer.rate * (1 + Plan.micClockError)
        let start = Plan.micSegments[buffer.segment].start
        return try pcmBuffer(rate: buffer.rate, channels: 1, frames: buffer.frames, at: Plan.stamp(buffer.pts)) { data in
            for i in 0..<buffer.frames {
                let t = start + Double(buffer.firstSample + Int64(i)) / rate
                data[0][i] = Plan.tone(at: t, first: 40, frequencyBase: 3000) + Plan.micNoise * micSignal.noise()
            }
        }
    }

    // MARK: - The run

    private enum Next {
        case frame(VideoFrame), system(SystemBuffer), mic(MicBuffer), tick(Double), control(Double, String)
        var time: Double {
            switch self {
            case .frame(let f): return f.arrival
            case .system(let s): return s.arrival
            case .mic(let m): return m.arrival
            case .tick(let t): return t
            case .control(let t, _): return t
            }
        }
    }

    /// Feeds everything that arrives up to `stop` on the sample queue. With `realTimeFrom`, what arrives from then on
    /// is fed at the pace of a live recording.
    func run(until stop: Double, realTimeFrom: Double? = nil) throws {
        var problem: Error?
        queue.sync {
            do { try feed(until: stop, realTimeFrom: realTimeFrom) } catch { problem = error }
        }
        if let problem = problem { throw problem }
    }

    /// Simulated times at which the feed stops for a few seconds to let the writer catch up, and the footprint is taken
    private let settleAt: Set<Double> = [1800, 3600]

    /// Waits 5 s without feeding anything and returns the footprint then, in MB
    private func settle() -> Double {
        sleep(5)
        return currentFootprint()
    }

    private func feed(until stop: Double, realTimeFrom: Double?) throws {
        let started = Date()
        var video = VideoSchedule()
        var system = SystemSchedule()
        var mic = MicSchedule()
        var tickRandom = SplitMix(seed: 0x7469_636B)
        var tickIndex = 1
        var controls: [(Double, String)] = [
            (Plan.pause.start, "pause"), (Plan.pause.end, "resume"),
            (Plan.mute.start, "mute"), (Plan.mute.end, "unmute"),
        ]
        var nextFrame = video.next()
        var nextSystem = system.next()
        var nextMic = mic.next()
        var nextTick = 0.5 * Double(tickIndex) + tickRandom.range(0, 0.002)
        var paceStart: Date?
        var nextProgress = 300.0

        writer.startCapturing()
        monitor.watch(clockWriter, from: Plan.uptime(0))
        while true {
            var candidates: [Next] = [.frame(nextFrame), .system(nextSystem), .tick(nextTick)]
            if let m = nextMic { candidates.append(.mic(m)) }
            if let c = controls.first { candidates.append(.control(c.0, c.1)) }
            guard let next = candidates.min(by: { $0.time < $1.time }), next.time <= stop else { break }
            let now = next.time
            RecLog.now = now
            if now >= nextProgress {
                if settleAt.contains(nextProgress) {
                    // Fed this fast, the writer holds a backlog; a live recording never gets ahead of it
                    stats.settled.append((now, currentFootprint(), settle()))
                }
                let footprint = currentFootprint()
                stats.footprints.append((now, footprint))
                FileHandle.standardError.write(Data(String(format: "  %4.0f simulated s after %5.1f s, footprint %.0f MB\n", now, Date().timeIntervalSince(started), footprint).utf8))
                nextProgress += 300
            }
            if let from = realTimeFrom, now >= from {
                let pace = paceStart ?? Date()
                paceStart = pace
                let due = now - from - Date().timeIntervalSince(pace)
                if due > 0 { usleep(useconds_t(due * 1_000_000)) }
            }
            // One autorelease pool per buffer, as each delivery of the stream is a block of its own in the app
            try autoreleasepool {
                waitForInputs()
                stats.events += 1
                let uptime = Plan.uptime(now)
                let taking = writer.isCapturing && !writer.isPaused && writer.sessionStart != nil
                switch next {
                case .frame(let frame):
                    let before = writer.videoPTS
                    clockWriter.deliver(CaptureSample(kind: .screen(complete: true), buffer: try frameBuffer(frame), pts: Plan.stamp(frame.pts)), at: uptime)
                    if taking && writer.videoPTS == before { stats.framesNotTaken += 1 }
                    if stats.sessionStart == nil, let start = writer.sessionStart { stats.sessionStart = Plan.seconds(start) }
                    stats.frames += 1
                    nextFrame = video.next()
                case .system(let buffer):
                    let before = writer.audioEndPTS
                    clockWriter.deliver(CaptureSample(kind: .audio, buffer: try systemBuffer(buffer), pts: Plan.stamp(buffer.pts)), at: uptime)
                    if taking && writer.audioEndPTS == before { stats.systemNotTaken += 1 }
                    stats.systemBuffers += 1
                    nextSystem = system.next()
                case .mic(let buffer):
                    let dropped = writer.micConverter?.buffersDropped ?? 0
                    clockWriter.deliver(CaptureSample(kind: .microphone, buffer: try micBuffer(buffer), pts: Plan.stamp(buffer.pts)), at: uptime)
                    stats.micBuffers += 1
                    if (writer.micConverter?.buffersDropped ?? 0) > dropped {
                        stats.micDrops.append(String(format: "%.3f s (stamped %.3f s, %.1f ms)", now, buffer.pts, 1000 * (buffer.end - buffer.start)))
                    }
                    nextMic = mic.next()
                case .tick:
                    let before = writer.videoPTS
                    monitor.tick(at: uptime)
                    if writer.videoPTS != before {
                        stats.repeats += 1
                        if now < Plan.staticSlide.start || now > Plan.staticSlide.end + 1 { stats.repeatsElsewhere.append(now) }
                    }
                    stats.ticks += 1
                    tickIndex += 1
                    nextTick = 0.5 * Double(tickIndex) + tickRandom.range(0, 0.002)
                case .control(_, let action):
                    // What RecordingSession.togglePause and setMicrophoneMuted do on the sample queue
                    switch action {
                    case "pause", "resume":
                        monitor.pauseToggled()
                        _ = writer.togglePause()
                    case "mute": writer.setMicrophoneMuted(true)
                    default: writer.setMicrophoneMuted(false)
                    }
                    RecLog.write("control: \(action)")
                    controls.removeFirst()
                }
            }
        }
        if realTimeFrom == nil { stats.settled.append((stop, currentFootprint(), settle())) }
        stats.pauseOffset = CMTimeGetSeconds(writer.timeOffset)
        stats.feedSeconds = Date().timeIntervalSince(started)
    }

    /// What `RecordingSession.takeWriter` does on the sample queue once the capture has stopped
    func finish() -> MovieWriter.Finished {
        return queue.sync {
            monitor.stop()
            return writer.finish()
        }
    }
}

struct SoakError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
