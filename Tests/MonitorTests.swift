//
//  MonitorTests.swift
//  The rules of RecordingMonitor, driven with a clock of the test's own: when tracks are continued, when the user
//  is warned and told that a source is back, and which ticks are passed over
//

import AVFoundation
import Foundation

/// A writer whose state the test sets; notes what the monitor asks of it
final class MonitorWriter: RecordingWriter {
    let recording: RecordingContext
    var events = MovieWriter.Events()
    var isCapturing = true
    var isPaused = false
    var isResume = false
    var sessionStart: CMTime? = time(0)
    var clockAnchor: (raw: CMTime, uptime: UInt64)?
    var audioEndPTS: CMTime?
    let hasSystemAudio: Bool
    let hasMicrophoneTrack: Bool
    var isMicrophoneMuted = false
    /// "microphone", "system audio" and "video", in the order the monitor filled them
    var fills = [String]()

    init(folder: URL, microphone: Bool, systemAudio: Bool) {
        recording = RecordingContext(audioOnly: false, recordMic: microphone, fastStart: false, saveDirectory: folder.path)
        hasMicrophoneTrack = microphone
        hasSystemAudio = systemAudio
    }

    func startCapturing() {}
    func togglePause() -> Bool { isPaused.toggle(); return isPaused }
    func setMicrophoneMuted(_ muted: Bool) { isMicrophoneMuted = muted }
    func write(_ sample: CaptureSample) {}
    func checkWriter() -> Bool { true }
    func timelineTime(_ raw: CMTime) -> CMTime { raw }
    func fillMicrophone(upTo time: CMTime) { fills.append("microphone") }
    func fillSystemAudio(upTo time: CMTime) { fills.append("system audio"); audioEndPTS = time }
    func repeatVideoFrame(at now: CMTime) { fills.append("video") }
    func finish() -> MovieWriter.Finished { MovieWriter.Finished(writer: nil, frame: nil, sessionStarted: true) }
    func cancel() {}
}

/// A monitor watching a `MonitorWriter` whose capture began at second 0. Times are seconds since then; the
/// buffers' clock and the writer's timeline are the same.
final class MonitorRun {
    let queue = DispatchQueue(label: "HoldfastTests.monitor-rules")
    let monitor: RecordingMonitor
    let writer: MonitorWriter
    /// Titles of the notifications, and the text of the last one
    private(set) var notified = [String]()
    private(set) var lastText = ""
    private(set) var warning: String?
    private(set) var level: Int?
    /// An uptime far from zero, as the system's is
    private let zero: UInt64 = 1_000_000_000_000

    init(_ name: String, microphone: Bool = true, systemAudio: Bool = false) throws {
        writer = MonitorWriter(folder: try Suite.folder(name), microphone: microphone, systemAudio: systemAudio)
        monitor = RecordingMonitor(queue: queue)
        writer.clockAnchor = (time(0), zero)
        monitor.notify = { [unowned self] title, text in notified.append(title); lastText = text }
        monitor.show = { [unowned self] shown, shownLevel in warning = shown; level = shownLevel }
        queue.sync { monitor.watch(writer, from: zero) }
    }

    func uptime(_ seconds: Double) -> UInt64 { zero + UInt64((seconds * 1_000_000_000).rounded()) }

    func tick(at seconds: Double) { queue.sync { monitor.tick(at: uptime(seconds)) } }

    /// A tick every half second after `start` up to and including `end`; before each, `each` with its time
    func ticks(after start: Double, through end: Double, each: (Double) -> Void = { _ in }) {
        var step = 1
        while start + Double(step) * 0.5 <= end + 0.001 {
            let at = start + Double(step) * 0.5
            each(at)
            tick(at: at)
            step += 1
        }
    }

    /// Microphone audio was written up to `seconds`; a peak of 0 is digital silence
    func microphone(upTo seconds: Double, peak: Float = 0.3) {
        queue.sync { monitor.microphoneWritten(upTo: time(seconds), peak: peak) }
    }

    func systemAudio(upTo seconds: Double) {
        queue.sync {
            writer.audioEndPTS = time(seconds)
            monitor.systemAudioWritten(upTo: time(seconds))
        }
    }

    func fills(_ what: String) -> Int { queue.sync { writer.fills.filter { $0 == what }.count } }
}

func monitorTests() async {
    let micTitle = "Microphone is not being recorded"
    let systemTitle = "System audio is not being recorded"

    await test("monitor: a microphone that delivers nothing for 5 s is reported once, and once when it is back") {
        let run = try MonitorRun("monitor-mic-silent")
        run.ticks(after: 0, through: 5) { run.microphone(upTo: $0) }
        expectEqual(run.notified, [], "nothing to report while the microphone delivers")
        expectEqual(run.level, 2, "its level is shown")
        // The last microphone audio ends at 5 s
        run.ticks(after: 5, through: 10)
        expectEqual(run.notified, [], "5 s without microphone audio is not yet a problem")
        run.tick(at: 10.5)
        expectEqual(run.notified, [micTitle], "more than 5 s is")
        expect(run.lastText.contains("No audio has arrived from the microphone"), "and says what happened: \(run.lastText)")
        expectEqual(run.warning, micTitle, "the status item shows it")
        run.ticks(after: 10.5, through: 12)
        expectEqual(run.notified, [micTitle], "one notification for as long as it lasts")
        run.microphone(upTo: 12.5)
        run.tick(at: 12.5)
        expectEqual(run.notified, [micTitle, "Microphone Is Back"], "and one when it is back")
        expectEqual(run.warning, nil, "the warning goes")
        expect(run.fills("microphone") > 0, "the track is continued meanwhile")
    }

    await test("monitor: a microphone that delivers only digital silence for 20 s is reported") {
        let run = try MonitorRun("monitor-mic-zeros")
        run.microphone(upTo: 1)
        run.ticks(after: 0, through: 21) { run.microphone(upTo: $0, peak: $0 <= 1 ? 0.3 : 0) }
        expectEqual(run.notified, [], "20 s of zeros is not yet a problem")
        expectEqual(run.level, 0, "but shows as silent")
        run.microphone(upTo: 21.5, peak: 0)
        run.tick(at: 21.5)
        expectEqual(run.notified, [micTitle], "more than 20 s is")
        expect(run.lastText.contains("nothing but silence"), "and says so: \(run.lastText)")
        run.microphone(upTo: 22, peak: 0.005)
        run.tick(at: 22)
        expectEqual(run.notified, [micTitle, "Microphone Is Back"], "any sound ends it")
        expectEqual(run.level, 1, "a quiet microphone shows as quiet")
    }

    await test("monitor: system audio that stops is filled, reported after 5 s and when it is back") {
        let run = try MonitorRun("monitor-system", microphone: false, systemAudio: true)
        run.ticks(after: 0, through: 3) { run.systemAudio(upTo: $0) }
        expectEqual(run.fills("system audio"), 0, "no fill while it arrives")
        run.ticks(after: 3, through: 8)
        expect(run.fills("system audio") > 0, "filled with silence once it is more than a second behind")
        expectEqual(run.notified, [], "5 s is not yet a problem")
        run.tick(at: 8.5)
        expectEqual(run.notified, [systemTitle], "more than 5 s is")
        expectEqual(run.warning, systemTitle, "and shown")
        run.systemAudio(upTo: 9)
        run.tick(at: 9)
        expectEqual(run.notified, [systemTitle, "System Audio Is Back"], "and its return")
        expectEqual(run.warning, nil, "the warning goes")
    }

    await test("monitor: a recording whose file has not started after 5 s is reported, and its start too") {
        let run = try MonitorRun("monitor-no-session")
        run.writer.sessionStart = nil
        run.ticks(after: 0, through: 5)
        expectEqual(run.notified, [], "5 s without a first picture is not yet a problem")
        run.tick(at: 5.5)
        expectEqual(run.notified, ["Nothing is being recorded yet"], "more than 5 s is")
        expectEqual(run.warning, "Nothing is being recorded yet", "and shown")
        expectEqual(run.fills("video") + run.fills("microphone"), 0, "nothing is filled before the file starts")
        run.queue.sync {
            run.writer.sessionStart = time(6)
            run.writer.clockAnchor = (time(6), run.uptime(6))
        }
        run.microphone(upTo: 6.5)
        run.tick(at: 6.5)
        expectEqual(run.notified, ["Nothing is being recorded yet", "Recording Started"], "the start is reported")
        expectEqual(run.warning, nil, "and the warning goes")
    }

    await test("monitor: one late tick in a row is passed over, not two") {
        let run = try MonitorRun("monitor-late")
        run.ticks(after: 0, through: 1) { run.microphone(upTo: $0) }
        let before = run.fills("video")
        expect(before > 0, "a tick on time works")
        run.tick(at: 3)
        expectEqual(run.fills("video"), before, "a late tick does nothing: buffers may be waiting behind it")
        run.tick(at: 5)
        expectEqual(run.fills("video"), before + 1, "the next one does, late as it is")
        run.tick(at: 7)
        expectEqual(run.fills("video"), before + 1, "a late tick after one that worked is passed over again")
    }

    await test("monitor: after a resume one tick waits for the first buffer, and a paused writer is left alone") {
        let run = try MonitorRun("monitor-resume")
        run.ticks(after: 0, through: 1) { run.microphone(upTo: $0) }
        let before = run.fills("video")
        run.queue.sync { run.writer.isPaused = true }
        run.ticks(after: 1, through: 3)
        expectEqual(run.fills("video"), before, "nothing while paused")
        run.queue.sync {
            run.writer.isPaused = false
            run.writer.isResume = true
            run.monitor.pauseToggled()
        }
        run.tick(at: 3.5)
        expectEqual(run.fills("video"), before, "the first tick after the resume waits")
        run.tick(at: 4)
        expectEqual(run.fills("video"), before + 1, "the second continues the tracks")
        expectEqual(run.notified, [], "and nothing was reported about the pause")
    }
}
