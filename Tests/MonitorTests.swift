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
    var backupEndPTS: CMTime?
    let hasSystemAudio: Bool
    var hasBackupAudio = false
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
    func fillBackupAudio(upTo time: CMTime) { fills.append("backup"); backupEndPTS = time }
    func repeatVideoFrame(at now: CMTime) { fills.append("video") }
    func currentPicture() -> CMSampleBuffer? { nil }
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
    /// The status item's warning, the part of it shown on screen, and whether the microphone is silent
    private(set) var warning: String?
    private(set) var onScreen: String?
    private(set) var silent: Bool?
    /// What is shown while no warning is: call audio is not being recorded
    private(set) var notice: String?
    /// An uptime far from zero, as the system's is
    private let zero: UInt64 = 1_000_000_000_000

    init(_ name: String, microphone: Bool = true, systemAudio: Bool = false, backup: Bool = false) throws {
        writer = MonitorWriter(folder: try Suite.folder(name), microphone: microphone, systemAudio: systemAudio)
        writer.hasBackupAudio = backup
        monitor = RecordingMonitor(queue: queue)
        writer.clockAnchor = (time(0), zero)
        monitor.notify = { [unowned self] title, text in notified.append(title); lastText = text }
        monitor.show = { [unowned self] display in warning = display.warning; onScreen = display.onScreen; silent = display.micSilent; notice = display.notice }
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

    func backup(upTo seconds: Double) {
        queue.sync {
            writer.backupEndPTS = time(seconds)
            monitor.backupAudioWritten(upTo: time(seconds))
        }
    }

    func fills(_ what: String) -> Int { queue.sync { writer.fills.filter { $0 == what }.count } }
}

func monitorTests() async {
    let micTitle = "Microphone Is Not Being Recorded"
    let systemTitle = "System Audio Is Not Being Recorded"
    let micWarning = "Microphone is not being recorded"
    let systemWarning = "System audio is not being recorded"

    await test("monitor: a microphone that delivers nothing is shown after 5 s, notified and put on screen after 15 s, and its return too") {
        let run = try MonitorRun("monitor-mic-silent")
        run.ticks(after: 0, through: 5) { run.microphone(upTo: $0) }
        expectEqual(run.notified, [], "nothing to report while the microphone delivers")
        expectEqual(run.silent, false, "it is shown as not silent")
        // The last microphone audio ends at 5 s
        run.ticks(after: 5, through: 10)
        expectEqual(run.warning, nil, "5 s without microphone audio is not yet a problem")
        run.tick(at: 10.5)
        expectEqual(run.warning, micWarning, "more than 5 s is, and the status item shows it")
        expectEqual(run.notified, [], "without a notification")
        expectEqual(run.onScreen, nil, "or a warning on screen")
        expect(RecLog.lines.contains { $0.hasPrefix(micTitle + ": No audio has arrived from the microphone") }, "the log has it: \(RecLog.lines)")
        run.ticks(after: 10.5, through: 19.5)
        expectEqual(run.notified, [], "not before it has lasted 15 s")
        run.tick(at: 20)
        expectEqual(run.notified, [micTitle], "15 s is long enough to be notified")
        expect(run.lastText.contains("No audio has arrived from the microphone for 15 seconds"), "saying how long: \(run.lastText)")
        expectEqual(run.onScreen, micWarning, "and shown on screen")
        expectEqual(run.warning, micWarning, "the status item still shows it")
        run.ticks(after: 20, through: 22)
        expectEqual(run.notified, [micTitle], "one notification for as long as it lasts")
        run.ticks(after: 22, through: 27) { run.microphone(upTo: $0) }
        expectEqual(run.notified, [micTitle], "back for less than 5 s is not yet back")
        expectEqual(run.onScreen, micWarning, "and stays on screen")
        run.microphone(upTo: 27.5)
        run.tick(at: 27.5)
        expectEqual(run.notified, [micTitle, "Microphone Is Back"], "and one when it has been back for 5 s")
        expectEqual(run.warning, nil, "the warning goes")
        expectEqual(run.onScreen, nil, "from the screen too")
        expect(run.fills("microphone") > 0, "the track is continued meanwhile")
    }

    await test("monitor: a microphone gap shorter than 15 s, a call app taking the microphone, is only shown in the status item") {
        let run = try MonitorRun("monitor-mic-short")
        run.ticks(after: 0, through: 5) { run.microphone(upTo: $0) }
        // The FaceTime call of the first real use: about 11 s without microphone audio
        run.ticks(after: 5, through: 16)
        expectEqual(run.warning, micWarning, "the status item shows it while it lasts")
        expectEqual(run.onScreen, nil, "nothing on screen")
        // Back for good: the problem has lasted more than 15 s once the microphone has been steady for 5 s, but
        // the time it was steady does not count
        run.ticks(after: 16, through: 21) { run.microphone(upTo: $0) }
        expectEqual(run.warning, micWarning, "shown until the microphone has been back for 5 s")
        run.microphone(upTo: 21.5)
        run.tick(at: 21.5)
        expectEqual(run.warning, nil, "the warning goes")
        expectEqual(run.notified, [], "no notification, neither of the problem nor of its end")
        expect(RecLog.lines.contains { $0.hasPrefix(micTitle + ":") }, "the log has the problem")
        expect(RecLog.lines.contains("Microphone Is Back (it lasted less than 15 s: not notified)"), "and its end: \(RecLog.lines)")
    }

    await test("monitor: a microphone that delivers only digital silence for 20 s is reported") {
        let run = try MonitorRun("monitor-mic-zeros")
        run.microphone(upTo: 1)
        run.ticks(after: 0, through: 21) { run.microphone(upTo: $0, peak: $0 <= 1 ? 0.3 : 0) }
        expectEqual(run.notified, [], "20 s of zeros is not yet a problem")
        expectEqual(run.warning, nil, "not even in the status item")
        expectEqual(run.silent, true, "but shows as silent")
        run.microphone(upTo: 21.5, peak: 0)
        run.tick(at: 21.5)
        expectEqual(run.notified, [micTitle], "more than 20 s is, and has lasted long enough to be notified at once")
        expect(run.lastText.contains("nothing but silence for 20 seconds"), "and says so: \(run.lastText)")
        expectEqual(run.onScreen, micWarning, "on screen too")
        run.ticks(after: 21.5, through: 27) { run.microphone(upTo: $0, peak: 0.005) }
        expectEqual(run.notified, [micTitle, "Microphone Is Back"], "any sound, for 5 s, ends it")
        expectEqual(run.silent, false, "a quiet microphone is not silent")
    }

    await test("monitor: system audio that stops is filled, shown after 5 s, notified after 15 s and when it is back") {
        let run = try MonitorRun("monitor-system", microphone: false, systemAudio: true)
        run.ticks(after: 0, through: 3) { run.systemAudio(upTo: $0) }
        expectEqual(run.fills("system audio"), 0, "no fill while it arrives")
        run.ticks(after: 3, through: 8)
        expect(run.fills("system audio") > 0, "filled with silence once it is more than a second behind")
        expectEqual(run.warning, nil, "5 s is not yet a problem")
        run.tick(at: 8.5)
        expectEqual(run.warning, systemWarning, "more than 5 s is shown")
        expectEqual(run.notified, [], "but not notified")
        run.ticks(after: 8.5, through: 18)
        expectEqual(run.notified, [systemTitle], "until it has lasted 15 s")
        expectEqual(run.onScreen, systemWarning, "then it is on screen too")
        run.ticks(after: 18, through: 23.5) { run.systemAudio(upTo: $0) }
        expectEqual(run.notified, [systemTitle, "System Audio Is Back"], "and its return, once it has been back for 5 s")
        expectEqual(run.warning, nil, "the warning goes")
    }

    await test("monitor: with the backup, system audio is a problem only while neither source delivers; a quiet tap is logged, and shown as missing call audio after 15 s") {
        let run = try MonitorRun("monitor-backup", microphone: false, systemAudio: true, backup: true)
        run.ticks(after: 0, through: 5) { run.systemAudio(upTo: $0); run.backup(upTo: $0) }
        // Today's case: the tap stops delivering, the backup goes on
        run.ticks(after: 5, through: 20) { run.backup(upTo: $0) }
        expectEqual(run.warning, nil, "no warning while the backup records")
        expectEqual(run.notice, nil, "and for 15 s, while the tap is rebuilt, nothing is shown at all")
        expectEqual(RecLog.lines.filter { $0.hasPrefix("System audio: the process tap has delivered nothing") }.count, 1, "the log says so after 5 s: \(RecLog.lines)")
        // Still dead after 15 s: every way of building it has failed twice, and a FaceTime call is being lost
        run.tick(at: 20.5)
        expectEqual(run.notice, "Call audio is not being recorded", "then the recording says that call audio is missing")
        expectEqual(run.warning, nil, "which is not the warning: system audio is being recorded")
        run.ticks(after: 20.5, through: 40) { run.backup(upTo: $0) }
        expectEqual(run.warning, nil, "no warning while the backup records")
        expectEqual(run.notified, [], "no notification")
        expectEqual(run.onScreen, nil, "no warning on screen")
        expectEqual(run.notice, "Call audio is not being recorded", "the notice stays while the tap is dead")
        expect(run.fills("system audio") > 0, "the tap's track is continued with silence")
        expectEqual(run.fills("backup"), 0, "the backup's needs nothing")
        expectEqual(RecLog.lines.filter { $0.hasPrefix("System audio: the process tap has delivered nothing") }.count, 1, "the log says so once: \(RecLog.lines)")
        expectEqual(RecLog.lines.filter { $0.hasPrefix("Call audio is not being recorded: the process tap has delivered nothing for 15 s") }.count, 1, "and once that call audio is missing: \(RecLog.lines)")
        run.ticks(after: 40, through: 45) { run.systemAudio(upTo: $0); run.backup(upTo: $0) }
        expect(RecLog.lines.contains("System audio: the process tap delivers again"), "and when it is back")
        expectEqual(run.notice, nil, "the notice goes with the tap's first audio")
        expect(RecLog.lines.contains("Call audio is being recorded again"), "logged: \(RecLog.lines)")
        expectEqual(RecordingMonitor.tapLostSeconds, 15, "how long a tap may be dead before it is shown")
        // FaceTime: only the tap hears the call; the backup that stops is no problem either
        run.ticks(after: 45, through: 70) { run.systemAudio(upTo: $0) }
        expectEqual(run.warning, nil, "no warning while the tap records")
        expect(run.fills("backup") > 0, "the backup's track is continued with silence")
        // Both stop: the warning, as for any silent track
        run.ticks(after: 70, through: 75.5)
        expectEqual(run.warning, systemWarning, "both silent for more than 5 s is a problem")
        run.ticks(after: 75.5, through: 85)
        expectEqual(run.notified, [systemTitle], "notified after 15 s")
        expectEqual(run.onScreen, systemWarning, "and shown on screen")
        run.ticks(after: 85, through: 91) { run.backup(upTo: $0) }
        expectEqual(run.notified, [systemTitle, "System Audio Is Back"], "either source coming back ends it")
        expectEqual(run.warning, nil, "the warning goes")
    }

    await test("monitor: a microphone that keeps dropping out, each gap under 15 s, is notified once and stays on screen") {
        // Weak Bluetooth, or a call app that keeps taking the microphone: half a second of audio every 10 s
        let run = try MonitorRun("monitor-mic-intermittent")
        run.ticks(after: 0, through: 10) { run.microphone(upTo: $0) }
        run.ticks(after: 10, through: 130) { at in
            if at.truncatingRemainder(dividingBy: 10) < 0.6 { run.microphone(upTo: at) }
        }
        expectEqual(run.notified, [micTitle], "one notification")
        expect(run.lastText.contains("kept dropping out"), "saying that it keeps dropping out: \(run.lastText)")
        expectEqual(run.onScreen, micWarning, "on screen for as long as it goes on")
        expectEqual(RecLog.lines.filter { $0.hasPrefix(micTitle + ":") && !$0.contains("still so") }.count, 1, "one problem in the log: \(RecLog.lines)")
        expect(RecLog.lines.allSatisfy { !$0.hasPrefix("Microphone Is Back") }, "and no end of it")
        run.ticks(after: 130, through: 135.5) { run.microphone(upTo: $0) }
        expectEqual(run.notified, [micTitle, "Microphone Is Back"], "back once it delivers steadily")
        expectEqual(run.onScreen, nil, "and off the screen")
    }

    await test("monitor: system audio that keeps dropping out for 6 to 14 s at a time is notified once") {
        let run = try MonitorRun("monitor-system-intermittent", microphone: false, systemAudio: true)
        run.ticks(after: 0, through: 5) { run.systemAudio(upTo: $0) }
        // Back for a second after 8 s, then after 12 s, and so on
        var next = 13.0
        var gap = 12.0
        run.ticks(after: 5, through: 95) { at in
            if at >= next && at < next + 1 { run.systemAudio(upTo: at) }
            if at >= next + 1 { next += gap + 1; gap = gap == 12 ? 6 : 12 }
        }
        expectEqual(run.notified, [systemTitle], "one notification")
        expectEqual(run.onScreen, systemWarning, "and on screen")
    }

    await test("monitor: a microphone that comes back with only digital silence is not back") {
        let run = try MonitorRun("monitor-mic-zeros-return")
        run.ticks(after: 0, through: 5) { run.microphone(upTo: $0) }
        run.ticks(after: 5, through: 20)
        expectEqual(run.notified, [micTitle], "15 s without audio is notified")
        // 16 s after the last sound it delivers again, but only zeros
        run.ticks(after: 20, through: 40) { at in if at >= 21 { run.microphone(upTo: at, peak: 0) } }
        expectEqual(run.notified, [micTitle], "no \"Microphone Is Back\", and no second notification when the zeros reach 20 s")
        expectEqual(run.onScreen, micWarning, "the warning stays on screen")
        run.ticks(after: 40, through: 45.5) { run.microphone(upTo: $0) }
        expectEqual(run.notified, [micTitle, "Microphone Is Back"], "sound for 5 s is back")
    }

    await test("monitor: only the problems that have lasted 15 s are on screen, every one is in the status item") {
        let run = try MonitorRun("monitor-both", microphone: true, systemAudio: true)
        // Nothing from the microphone ever; system audio up to 6 s
        run.ticks(after: 0, through: 15) { if $0 <= 6 { run.systemAudio(upTo: $0) } }
        expectEqual(run.notified, [micTitle], "the microphone has lasted 15 s")
        expectEqual(run.warning, micWarning + ". " + systemWarning, "both in the status line")
        expectEqual(run.onScreen, micWarning, "only the microphone on screen")
        run.ticks(after: 15, through: 21)
        expectEqual(run.notified, [micTitle, systemTitle], "then system audio")
        expectEqual(run.onScreen, micWarning + ". " + systemWarning, "both on screen")
    }

    await test("monitor: a recording whose file has not started is shown after 5 s, notified after 15 s, and its start too") {
        let run = try MonitorRun("monitor-no-session")
        run.writer.sessionStart = nil
        run.ticks(after: 0, through: 5)
        expectEqual(run.warning, nil, "5 s without a first picture is not yet a problem")
        run.tick(at: 5.5)
        expectEqual(run.warning, "Nothing is being recorded yet", "more than 5 s is shown")
        expectEqual(run.notified, [], "not notified yet")
        run.ticks(after: 5.5, through: 15)
        expectEqual(run.notified, ["Nothing Is Being Recorded Yet"], "15 s is")
        expectEqual(run.onScreen, "Nothing is being recorded yet", "and on screen")
        expectEqual(run.fills("video") + run.fills("microphone"), 0, "nothing is filled before the file starts")
        run.ticks(after: 15, through: 16)
        run.queue.sync {
            run.writer.sessionStart = time(16)
            run.writer.clockAnchor = (time(16), run.uptime(16))
        }
        run.microphone(upTo: 16.5)
        run.tick(at: 16.5)
        expectEqual(run.notified, ["Nothing Is Being Recorded Yet", "Recording Started"], "the start is reported")
        expectEqual(run.warning, nil, "and the warning goes")
        expectEqual(run.onScreen, nil, "from the screen too")
    }

    await test("monitor: a file that starts after 8 s is only shown in the status item meanwhile") {
        let run = try MonitorRun("monitor-late-session")
        run.writer.sessionStart = nil
        run.ticks(after: 0, through: 7.5)
        expectEqual(run.warning, "Nothing is being recorded yet", "shown")
        run.queue.sync {
            run.writer.sessionStart = time(8)
            run.writer.clockAnchor = (time(8), run.uptime(8))
        }
        run.microphone(upTo: 8.5)
        run.tick(at: 8.5)
        expectEqual(run.warning, nil, "gone once the file starts")
        expectEqual(run.notified, [], "without any notification")
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
