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
/// real time, so the anchor is given the simulated uptime at which that buffer arrived (for a buffer of the tap,
/// when its IOProc was called, before it waited for the sample queue). The monitor then tells the present exactly
/// as it would in a live recording.
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
            clockAnchor = (anchor.raw, sample.arrival.isValid ? Plan.uptime(Plan.seconds(sample.arrival)) : uptime)
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
    var backupEndPTS: CMTime? { real.backupEndPTS }
    var hasSystemAudio: Bool { real.hasSystemAudio }
    var hasBackupAudio: Bool { real.hasBackupAudio }
    func fillBackupAudio(upTo time: CMTime) { real.fillBackupAudio(upTo: time) }
    var callEndPTS: CMTime? { real.callEndPTS }
    var hasCallAudio: Bool { real.hasCallAudio }
    func fillCallAudio(upTo time: CMTime) { real.fillCallAudio(upTo: time) }
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

/// Stands in for the process tap: `SystemAudioSource` builds it, and the simulation calls `deliver` in its IOProc's place
final class SimulatedTap: SystemAudioTapping {
    let clockText = "a simulated clock"
    let formatText = "48000 Hz, 2 channels"
    let deliver: (CMSampleBuffer) -> Void
    init(deliver: @escaping (CMSampleBuffer) -> Void) { self.deliver = deliver }
    func stop() {}
}

/// What the simulated recording did, for the report
struct RunStats {
    var events = 0
    var frames = 0
    var systemBuffers = 0
    var backupBuffers = 0
    /// Tap buffers not delivered: the outage
    var tapSkipped = 0
    /// Tap buffers its device stamped with another time than theirs
    var tapMisstamped = 0
    /// Buffers the call tap delivered, and those its track's input did not take
    var callBuffers = 0
    var callNotTaken = 0
    /// What the call tap's source said about a call, and when
    var callStates = [(time: Double, state: CallAudioState)]()
    var micBuffers = 0
    var ticks = 0
    /// Times the feed waited for a writer input that was not ready, and for how long in all
    var waits = 0
    var waitSeconds = 0.0
    /// Buffers delivered while the recording was taking them that the writer's input did not take
    var framesNotTaken = 0
    var systemNotTaken = 0
    var backupNotTaken = 0
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
    /// The tap's source, as in the app, with a tap the simulation delivers through. It hands its buffers on on a
    /// queue of its own, from which the feed takes them when they arrive on the sample queue.
    private var tapSource: SystemAudioSource?
    private var tap: SimulatedTap?
    /// The call tap's source, as in the app, on a Core Audio of the simulation's: the call process has an audio
    /// object while `callOn`, the list's listener is called by the feed, and the tap it builds is a `SimulatedTap`
    private var callSource: CallAudioSource?
    private var callTap: SimulatedTap?
    private var callOn = false
    private var processListChanged: (() -> Void)?
    private var reportedStates = [CallAudioState]()
    private var callSignal = SplitMix(seed: 0x4353_4947)
    private let tapQueue = DispatchQueue(label: "Soak.tap-hand-off")
    private var handedOn = [CaptureSample]()
    /// When the tap's IOProc is called, on the stream's clock
    private var ioTime = 0.0
    var stats = RunStats()
    private var inputs = [AVAssetWriterInput]()
    private var pixelPool: CVPixelBufferPool?
    private var systemSignal = SplitMix(seed: 0x5353_4947)
    private var backupSignal = SplitMix(seed: 0x4253_4947)
    private var micSignal = SplitMix(seed: 0x4D53_4947)

    init(folder: URL) throws {
        // System audio from the process tap, with the backup on a track of its own
        recording = RecordingContext(audioOnly: false, recordMic: true, fastStart: false, saveDirectory: folder.path, tap: true)
        guard let converter = MicConverter() else { throw SoakError("no microphone converter") }
        writer = MovieWriter(recording: recording, micConverter: converter)
        // The present the writer checks the buffers' times against is the simulated one
        writer.presentClock = { Plan.stamp(RecLog.now) }
        clockWriter = SimulatedClockWriter(writer)
        monitor = RecordingMonitor(queue: queue)
    }

    /// Creates the file as `record()` does, and wires the writer to the monitor as `RecordingSession.install` does
    func prepare() throws {
        try writer.prepareVideo(width: Plan.width, height: Plan.height)
        // The writer's inputs, to wait for them the way a machine that keeps up in real time never has to: its video
        // and microphone inputs, and those of its two system audio tracks
        func inputs(of subject: Any) -> [AVAssetWriterInput] {
            return Mirror(reflecting: subject).children.flatMap { child -> [AVAssetWriterInput] in
                if let input = child.value as? AVAssetWriterInput { return [input] }
                guard let label = child.label, label == "system" || label == "backup" || label == "call" || label == "some" else { return [] }
                return inputs(of: child.value)
            }
        }
        self.inputs = inputs(of: writer)
        guard self.inputs.count == 5 else { throw SoakError("expected five writer inputs, found \(self.inputs.count)") }
        writer.events.failed = { [unowned self] reason in stats.failures.append(String(format: "%.3f s: ", RecLog.now) + reason) }
        writer.events.microphoneWritten = { [monitor] end, peak in monitor.microphoneWritten(upTo: end, peak: peak) }
        writer.events.systemAudioWritten = { [monitor] end in monitor.systemAudioWritten(upTo: end) }
        writer.events.backupAudioWritten = { [monitor] end in monitor.backupAudioWritten(upTo: end) }
        writer.events.callAudioWritten = { [monitor] end in monitor.callAudioWritten(upTo: end) }
        monitor.notify = { [unowned self] title, _ in stats.notifications.append((RecLog.now, title)) }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Plan.width,
            kCVPixelBufferHeightKey as String: Plan.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pixelPool)
        // The tap's source as `record()` starts it. Its host clock is the simulated one, read where the IOProc reads it.
        let factory = SystemAudioSource.Factory(constructions: { [.builtInOutput] }, makeTap: { [unowned self] _, _, deliver, _ in
            let made = SimulatedTap(deliver: deliver)
            tap = made
            return made
        })
        let source = SystemAudioSource(factory: factory, sampleQueue: tapQueue, stallSeconds: 1_000_000,
                                       clock: { [unowned self] in Plan.stamp(ioTime) }) { [unowned self] sample in
            handedOn.append(sample)
        }
        try source.start()
        tapSource = source
        guard tap != nil else { throw SoakError("no tap was built") }
        // The call tap's source as `record()` starts it, beside the tap's
        let callFactory = CallAudioSource.Factory(processes: { [unowned self] in callOn ? [501] : [] }, watch: { [unowned self] queue, changed in
            processListChanged = { queue.async(execute: changed) }
            return TapListener(object: CoreAudioTapHardware.system)
        }, unwatch: { _ in }, constructions: { TapClock.callOrder(builtIn: nil) }, makeTap: { [unowned self] _, _, _, deliver, _ in
            let made = SimulatedTap(deliver: deliver)
            callTap = made
            return made
        })
        let calls = CallAudioSource(factory: callFactory, sampleQueue: tapQueue, stallSeconds: 1_000_000, clock: { [unowned self] in Plan.stamp(ioTime) },
                                    onSample: { [unowned self] sample in handedOn.append(sample) }, onState: { [unowned self] state in reportedStates.append(state) })
        calls.start()
        callSource = calls
        guard callTap == nil else { throw SoakError("a call tap was built without a call") }
    }

    /// The call process gets or loses its audio object: the list of process objects changes, the call tap's source
    /// hears of it on its queue and builds or takes down its tap. What it reports reaches the monitor on the sample queue.
    private func setCall(_ on: Bool) {
        callOn = on
        if !on { callTap = nil }
        processListChanged?()
        callSource?.control.sync {}
        callSource?.control.sync {}
        passOnCallStates()
    }

    private func passOnCallStates() {
        guard let source = callSource else { return }
        let states = source.control.sync { () -> [CallAudioState] in
            defer { reportedStates = [] }
            return reportedStates
        }
        for state in states {
            stats.callStates.append((RecLog.now, state))
            monitor.callAudioChanged(state)
        }
    }

    /// The call tap's IOProc is called at `buffer.io`; what its source hands on
    private func callSamples(_ buffer: SystemBuffer) throws -> [CaptureSample] {
        guard let callTap else { return [] }
        ioTime = buffer.io
        let first = buffer.index * Plan.systemFrames
        callTap.deliver(try pcmBuffer(rate: Plan.systemRate, channels: 2, frames: Plan.systemFrames, at: Plan.stamp(buffer.pts)) { data in
            for i in 0..<Plan.systemFrames {
                let tone = Plan.callTone(at: Double(first + i) / Plan.systemRate)
                data[0][i] = tone + Plan.systemNoise * callSignal.noise()
                data[1][i] = tone + Plan.systemNoise * callSignal.noise()
            }
        })
        return tapQueue.sync {
            let samples = handedOn
            handedOn = []
            return samples
        }
    }

    /// The tap's IOProc is called at `buffer.io` with a buffer its device stamped `stamp`; what its source hands on
    private func tapSamples(_ buffer: SystemBuffer, stamped stamp: Double) throws -> [CaptureSample] {
        ioTime = buffer.io
        tap?.deliver(try systemBuffer(buffer, stamped: stamp))
        return tapQueue.sync {
            let samples = handedOn
            handedOn = []
            return samples
        }
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

    /// The sound the Mac plays, as the tap (`backup` false) or ScreenCaptureKit hears it: the same tones, each with
    /// noise of its own
    private func systemBuffer(_ buffer: SystemBuffer, backup: Bool = false, stamped stamp: Double? = nil) throws -> CMSampleBuffer {
        let first = buffer.index * Plan.systemFrames
        return try pcmBuffer(rate: Plan.systemRate, channels: 2, frames: Plan.systemFrames, at: Plan.stamp(stamp ?? buffer.pts)) { data in
            for i in 0..<Plan.systemFrames {
                // When the sample was played: the tap's device counts its samples by a clock of its own
                let t = Double(first + i) / (backup ? Plan.systemRate : Plan.tapRate)
                // The tap hears the call too; ScreenCaptureKit never does
                let tone = Plan.tone(at: t, first: 10, frequencyBase: 1000) + (backup ? 0 : Plan.callTone(at: t))
                data[0][i] = tone + Plan.systemNoise * (backup ? backupSignal.noise() : systemSignal.noise())
                data[1][i] = tone + Plan.systemNoise * (backup ? backupSignal.noise() : systemSignal.noise())
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
        case frame(VideoFrame), system(SystemBuffer), backup(SystemBuffer), call(SystemBuffer), mic(MicBuffer), tick(Double), control(Double, String)
        var time: Double {
            switch self {
            case .frame(let f): return f.arrival
            case .system(let s): return s.arrival
            case .backup(let s): return s.arrival
            case .call(let s): return s.arrival
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
        var system = SystemSchedule(rate: Plan.tapRate)
        var backup = SystemSchedule(seed: 0x6261_636B)
        var mic = MicSchedule()
        var tickRandom = SplitMix(seed: 0x7469_636B)
        var tickIndex = 1
        var controls: [(Double, String)] = [
            (Plan.pause.start, "pause"), (Plan.pause.end, "resume"),
            (Plan.mute.start, "mute"), (Plan.mute.end, "unmute"),
            (Plan.call.start - 0.5, "call begins"), (Plan.call.end + 0.5, "call ends"),
        ].sorted { $0.0 < $1.0 }
        // The call tap's buffers: only those of the call are ever delivered
        var callSchedule = SystemSchedule(seed: 0x6361_6C6C)
        var nextCall: SystemBuffer? = callSchedule.next()
        while let buffer = nextCall, buffer.pts < Plan.call.start { nextCall = callSchedule.next() }
        passOnCallStates()
        var nextFrame = video.next()
        var nextSystem = system.next()
        var nextBackup = backup.next()
        var nextMic = mic.next()
        var nextTick = 0.5 * Double(tickIndex) + tickRandom.range(0, 0.002)
        var paceStart: Date?
        var nextProgress = 300.0

        writer.startCapturing()
        monitor.watch(clockWriter, from: Plan.uptime(0))
        while true {
            var candidates: [Next] = [.frame(nextFrame), .system(nextSystem), .backup(nextBackup), .tick(nextTick)]
            if let m = nextMic { candidates.append(.mic(m)) }
            if let c = nextCall { candidates.append(.call(c)) }
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
                    clockWriter.deliver(CaptureSample(kind: .screen(complete: true), buffer: try frameBuffer(frame), pts: Plan.stamp(frame.pts), arrival: Plan.stamp(now)), at: uptime)
                    if taking && writer.videoPTS == before { stats.framesNotTaken += 1 }
                    if stats.sessionStart == nil, let start = writer.sessionStart { stats.sessionStart = Plan.seconds(start) }
                    stats.frames += 1
                    nextFrame = video.next()
                case .system(let buffer):
                    if buffer.pts >= Plan.tapOutage.start && buffer.pts < Plan.tapOutage.end {
                        // The tap is dead: its IOProc delivers nothing until it is rebuilt
                        stats.tapSkipped += 1
                    } else {
                        // Through the tap's source, as in the app: the IOProc was called at `buffer.io` with a buffer
                        // its device stamped as `Plan.tapDeviceStamp` says, and it reaches the sample queue now
                        let before = writer.audioEndPTS
                        let stamp = Plan.tapDeviceStamp(buffer.pts)
                        if stamp != buffer.pts { stats.tapMisstamped += 1 }
                        for sample in try tapSamples(buffer, stamped: stamp) { clockWriter.deliver(sample, at: uptime) }
                        if taking && writer.audioEndPTS == before { stats.systemNotTaken += 1 }
                        stats.systemBuffers += 1
                    }
                    nextSystem = system.next()
                case .backup(let buffer):
                    let before = writer.backupEndPTS
                    clockWriter.deliver(CaptureSample(kind: .backupAudio, buffer: try systemBuffer(buffer, backup: true), pts: Plan.stamp(buffer.pts), arrival: Plan.stamp(now)), at: uptime)
                    if taking && writer.backupEndPTS == before { stats.backupNotTaken += 1 }
                    stats.backupBuffers += 1
                    nextBackup = backup.next()
                case .call(let buffer):
                    let before = writer.callEndPTS
                    let samples = try callSamples(buffer)
                    for sample in samples { clockWriter.deliver(sample, at: uptime) }
                    if !samples.isEmpty {
                        if taking && writer.callEndPTS == before { stats.callNotTaken += 1 }
                        stats.callBuffers += 1
                    }
                    nextCall = callSchedule.next()
                    if let following = nextCall, following.pts >= Plan.call.end { nextCall = nil }
                case .mic(let buffer):
                    let dropped = writer.micConverter?.buffersDropped ?? 0
                    clockWriter.deliver(CaptureSample(kind: .microphone, buffer: try micBuffer(buffer), pts: Plan.stamp(buffer.pts), arrival: Plan.stamp(now)), at: uptime)
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
                    case "unmute": writer.setMicrophoneMuted(false)
                    case "call begins": setCall(true)
                    default: setCall(false)
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
        tapSource?.stopNow()
        callSource?.stopNow()
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
