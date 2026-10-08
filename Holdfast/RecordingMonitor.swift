//
//  RecordingMonitor.swift
//  Holdfast
//

import AVFoundation

/// Runs twice a second on the sample queue while a recording is capturing, whether or not any buffer arrives.
/// Every `RecordingSession` has its own.
///
/// It has the recording's writer keep every track of the file advancing when its source delivers nothing:
/// silence for the microphone and for system audio, the last frame again for video. A track that stops would hold back the fragments of all the others
/// and leave a hole that players handle badly. It is also the watchdog that tells the user while a source is not
/// being recorded: a problem shows in the status item at once, and only one that lasts `announceSeconds` is notified
/// and shown on screen, so that a call app taking the microphone for a few seconds interrupts nobody. A problem ends
/// only once its source has delivered steadily again for `steadySeconds`, so a source that keeps dropping out and
/// coming back for a moment is one problem, counted from its first gap, not many short ones that are never
/// notified. System audio recorded with the process tap has a backup (ScreenCaptureKit's system audio, on a track of
/// its own) and a call tap (a second tap of the process that plays FaceTime and phone calls, on a third track): all
/// three tracks are continued, and system audio is a problem only while neither the tap nor its backup delivers (the
/// call tap hears one process only, so what it delivers does not stand for system audio). A tap that stops
/// while the backup goes on is only logged at first: the recording has the sound, and the tap's source is rebuilding
/// it. One that has put nothing into its track for `tapLostSeconds` is shown, as a notice and not as a warning, when
/// the call tap delivers nothing either while a call may be playing (`CallAudioState`), or when nothing looks for a
/// call: the backup does not hear a FaceTime or phone call, so the other side of one is not being recorded and
/// nothing else would say so. With no call on there is nothing of that kind to lose, and with the call tap
/// delivering the call is being recorded.
/// Everything here is only used on the sample queue; the methods the session calls and the timer trap elsewhere.
final class RecordingMonitor {
    static let interval: Double = 0.5
    /// How long a source may deliver nothing before its track is continued without it. The tracks are filled up to
    /// this far behind the present, so that a buffer which is merely late still fits.
    static let gapSeconds: Double = 1
    /// How long a source may deliver nothing before the status item shows it as a problem (and the log has it)
    static let silentSeconds: Double = 5
    /// How long the microphone may deliver nothing but zeros before that
    static let zeroSeconds: Double = 20
    /// How long a problem must have lasted before it is notified and shown on screen, over every app. A shorter
    /// one is only the status item's warning while it lasts, and its end is notified only when it was.
    static let announceSeconds: Double = 15
    /// How long a source must deliver steadily before its problem is over: audio written up to within
    /// `steadyGap` of the present on every tick (for the microphone, audio that is not digital silence)
    static let steadySeconds: Double = 5
    static let steadyGap: Double = 2
    /// How long the process tap may put nothing into its track, while its backup records, before the recording
    /// shows that call audio is not being recorded
    static let tapLostSeconds: Double = 15

    /// What the status item and the on-screen warning show
    struct Display: Equatable {
        /// Every problem there is now, as one status line
        var warning: String?
        /// The problems among them that have lasted `announceSeconds`: shown on screen
        var onScreen: String?
        /// Nil without a microphone track; true while it delivers nothing or digital silence
        var micSilent: Bool?
        /// Shown like a warning while there is none: the process tap has delivered nothing for `tapLostSeconds`
        /// while its backup records, and the call tap does not record the call either, so call audio is missing
        var notice: String?
    }

    /// A problem that is up: its status line, and whether it was notified
    private struct Problem {
        let line: String
        var announced = false
        /// For a source: where its audio last reached when the problem began, on the timeline. The problem has
        /// lasted from then, whatever came in between, until it is over.
        var began: CMTime?
        /// Since when the source has delivered steadily again, on the timeline; nil while it does not
        var steadySince: CMTime?
    }

    private let queue: DispatchQueue
    /// A problem has lasted `announceSeconds`, or such a problem is over: title and text of the notification.
    /// Called on the sample queue.
    var notify: (String, String) -> Void = { _, _ in }
    /// What the status bar and the on-screen warning show changed. Called on the sample queue.
    var show: (Display) -> Void = { _ in }
    /// The writer of the recording, while it is being watched
    private var writer: RecordingWriter?
    private var timer: DispatchSourceTimer?
    private var lastTick: UInt64 = 0
    /// When the monitor was started, which is when the capture began to run
    private var started: UInt64 = 0
    private var startProblem: Problem?
    private var skippedLateTick = false
    /// A resumed recording continues at the first buffer that arrives. Only when none has arrived a whole tick later
    /// does the monitor continue it.
    private var resumeWaited = false
    /// End of the last microphone audio written, and of the last that was not digital silence
    private var micHeard: CMTime?
    private var micSound: CMTime?
    private var micPeak: Float = 0
    /// End of the last system audio that its source delivered and that was written, and the same for its backup.
    /// With the backup, system audio is missing only while neither delivers: a process tap that stops while the
    /// backup goes on is only logged (`tapQuiet`), since the recording has the sound.
    private var audioHeard: CMTime?
    private var backupHeard: CMTime?
    /// The same for the call tap's audio, whether a call may be playing, and where on the timeline that last became so
    private var callHeard: CMTime?
    private var callState = CallAudioState.unknown
    private var callStateChanged = false
    private var callActiveSince: CMTime?
    /// Whether the log says that the tap is quiet while the backup records
    private var tapQuiet = false
    /// Whether the tap has been quiet for `tapLostSeconds`: the recording shows that call audio is missing
    private var tapLost = false
    private var micProblem: Problem?
    private var audioProblem: Problem?
    private var shown = Display()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Watches `writer` from now on, with a tick every `interval`
    func start(_ writer: RecordingWriter) {
        watch(writer, from: DispatchTime.now().uptimeNanoseconds)
        guard self.writer != nil else { return }
        let interval = RecordingMonitor.interval
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.tick(at: DispatchTime.now().uptimeNanoseconds) }
        timer = source
        source.resume()
    }

    /// Watches `writer`, whose capture began at `uptime` (nanoseconds of `DispatchTime`), without a timer: the
    /// ticks come from `start`'s timer, or from a test with times of its own
    func watch(_ writer: RecordingWriter, from uptime: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        guard writer.isCapturing else { return }
        self.writer = writer
        started = uptime
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        timer = nil
        writer = nil
        lastTick = 0
        started = 0
        startProblem = nil
        skippedLateTick = false
        resumeWaited = false
        micHeard = nil
        micSound = nil
        micPeak = 0
        audioHeard = nil
        backupHeard = nil
        callHeard = nil
        callStateChanged = false
        callActiveSince = nil
        tapQuiet = false
        tapLost = false
        micProblem = nil
        audioProblem = nil
        update(Display())
    }

    /// The recording was paused or resumed: after a resume the monitor waits a tick for the first buffer again
    func pauseToggled() {
        dispatchPrecondition(condition: .onQueue(queue))
        resumeWaited = false
    }

    /// From the writer, on the path of a delivered buffer, which does not trap (see `RecordingSession.received`)
    func microphoneWritten(upTo end: CMTime, peak: Float) {
        micHeard = end
        if peak > 0 { micSound = end }
        micPeak = max(micPeak, peak)
    }

    func systemAudioWritten(upTo end: CMTime) {
        audioHeard = end
    }

    func backupAudioWritten(upTo end: CMTime) {
        backupHeard = end
    }

    func callAudioWritten(upTo end: CMTime) {
        callHeard = end
    }

    /// From the recording's call tap source, on the sample queue: whether a call may be playing. It may come before
    /// the monitor watches a writer, and is kept through `stop`: the source is the recording's, like the monitor.
    func callAudioChanged(_ state: CallAudioState) {
        guard state != callState else { return }
        callState = state
        callStateChanged = true
    }

    private func seconds(from start: CMTime, to end: CMTime) -> Double {
        return CMTimeGetSeconds(CMTimeSubtract(end, start))
    }

    /// What the monitor does every `interval`, at the time `uptime` (nanoseconds of `DispatchTime`)
    func tick(at uptime: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        let interval = RecordingMonitor.interval
        let silentSeconds = RecordingMonitor.silentSeconds
        let zeroSeconds = RecordingMonitor.zeroSeconds
        let sinceLastTick = lastTick == 0 ? 0 : Double(uptime &- lastTick) / 1_000_000_000
        lastTick = uptime
        guard let writer = writer, writer.isCapturing, !writer.isPaused else { return }
        let recording = writer.recording
        // A title for the notifications, a sentence for the status line
        let startTitle = "Nothing Is Being Recorded Yet"
        guard let sessionStart = writer.sessionStart else {
            // The file starts with the first complete picture (the first system audio of an audio-only recording),
            // and all audio that arrives before it is left out. When that takes this long it may never come, a
            // window that is minimized or a display that is asleep for example, and the user must know.
            let waited = started != 0 && uptime >= started ? Double(uptime - started) / 1_000_000_000 : 0
            var problem: String?
            if waited > silentSeconds {
                problem = recording.audioOnly
                    ? "No system audio has arrived since the recording was started, so nothing has been recorded so far."
                    : "No picture has arrived from the screen or window since the recording was started, so nothing has been recorded so far, audio included. Check that the window is visible and the display is awake."
            }
            startProblem = reportStart(problem, lasted: waited, line: "Nothing is being recorded yet", was: startProblem, title: startTitle, backTitle: "", backBody: "")
            update(display([startProblem], micSilent: nil))
            return
        }
        if startProblem != nil {
            startProblem = reportStart(nil, lasted: 0, line: "", was: startProblem, title: startTitle, backTitle: "Recording Started", backBody: "The recording has started now. What came before is not in it.")
        }
        guard let anchor = writer.clockAnchor, uptime >= anchor.uptime else { return }
        // After the process was held up, the buffers that piled up may still be waiting behind this tick. Judging the
        // sources now would take them for stalled, put silence where their audio belongs and warn about nothing.
        // Only one tick in a row is passed over: by the next one those buffers have been handled, and a timer that
        // the system keeps firing late must not switch the monitor off.
        if sinceLastTick > interval * 2 && !skippedLateTick {
            skippedLateTick = true
            return
        }
        skippedLateTick = false
        if writer.isResume && !resumeWaited {
            resumeWaited = true
            return
        }
        resumeWaited = false
        guard writer.checkWriter() else { return }
        // The present on the clock of the buffers, taken from the last buffer that arrived and the time since then.
        // That is the timestamp a buffer arriving now would carry, whatever clock the stream uses.
        let raw = CMTimeAdd(anchor.raw, CMTime(value: CMTimeValue(uptime - anchor.uptime), timescale: 1_000_000_000))
        let now = writer.timelineTime(raw)
        let target = CMTimeSubtract(now, CMTime(seconds: RecordingMonitor.gapSeconds, preferredTimescale: 600))

        writer.fillMicrophone(upTo: target)
        let hasSystemAudio = writer.hasSystemAudio
        if hasSystemAudio, seconds(from: writer.audioEndPTS ?? sessionStart, to: target) >= 0.5 {
            writer.fillSystemAudio(upTo: target)
        }
        if writer.hasBackupAudio, seconds(from: writer.backupEndPTS ?? sessionStart, to: target) >= 0.5 {
            writer.fillBackupAudio(upTo: target)
        }
        if writer.hasCallAudio, seconds(from: writer.callEndPTS ?? sessionStart, to: target) >= 0.5 {
            writer.fillCallAudio(upTo: target)
        }
        writer.repeatVideoFrame(at: now)
        guard writer.isCapturing else { return }

        var micSilent: Bool?
        if writer.hasMicrophoneTrack, writer.isMicrophoneMuted {
            // Silence the user asked for is no problem to report. The time muted does not count towards a
            // warning afterwards either, and a warning that was up goes without a "Microphone Is Back".
            micHeard = now
            micSound = now
            if micProblem != nil { RecLog.write("Microphone muted: its warning goes") }
            micProblem = nil
            micPeak = 0
            micSilent = true
        } else if writer.hasMicrophoneTrack {
            let heard = micHeard ?? sessionStart
            let sounded = micSound ?? sessionStart
            let unheard = seconds(from: heard, to: now)
            let unsounded = seconds(from: sounded, to: now)
            var failing: Failing?
            if unheard > silentSeconds {
                failing = Failing(since: heard, text: String(format: "No audio has arrived from the microphone for %d seconds. The recording continues with silence in its place until the microphone comes back.", Int(unheard)))
            } else if unsounded > zeroSeconds {
                failing = Failing(since: sounded, text: String(format: "The microphone has delivered nothing but silence for %d seconds. Check that it is not muted or in use by another app.", Int(unsounded)))
            }
            // Audio that is digital silence does not end a problem: a microphone that comes back delivering only
            // zeros is still not recorded
            let steady = unheard <= RecordingMonitor.steadyGap && unsounded <= RecordingMonitor.steadyGap
            micProblem = report(failing, steady: steady, now: now, was: micProblem, line: "Microphone is not being recorded", title: "Microphone Is Not Being Recorded",
                                intermittent: "Audio from the microphone has kept dropping out for %d seconds. The recording continues with silence in its place while it is missing.",
                                backTitle: "Microphone Is Back", backBody: "Microphone audio is being recorded again.")
            // Nothing, or nothing but digital zeros, since the last tick
            micSilent = micPeak == 0
            micPeak = 0
        }
        if hasSystemAudio {
            let tapHeard = audioHeard ?? sessionStart
            var heard = tapHeard
            if writer.hasBackupAudio {
                let backup = backupHeard ?? sessionStart
                if backup > heard { heard = backup }
                // The tap's own silence is the log's business only: the backup has the sound
                let tapUnheard = seconds(from: tapHeard, to: now)
                if !tapQuiet && tapUnheard > silentSeconds && seconds(from: backup, to: now) <= RecordingMonitor.steadyGap {
                    tapQuiet = true
                    RecLog.write(String(format: "System audio: the process tap has delivered nothing for %d s; the backup (screen capture) records the system audio meanwhile", Int(tapUnheard)))
                } else if tapQuiet && tapUnheard <= RecordingMonitor.steadyGap {
                    tapQuiet = false
                    RecLog.write("System audio: the process tap delivers again")
                }
                // The call tap decides whether a dead tap costs a call: from when a call may be playing it has
                // `tapLostSeconds` to deliver. Its buffers do not count as system audio that arrived: it hears one
                // process only and delivers, zeros too, for as long as that process has an audio object, so with
                // the tap and the backup both gone everything else the Mac plays is not being recorded.
                if callStateChanged {
                    callStateChanged = false
                    callActiveSince = callState == .active ? now : nil
                }
                var callLost = callState == .unknown
                var callRecorded = false
                if callState == .active {
                    var last = callActiveSince ?? sessionStart
                    if let callHeard, callHeard > last { last = callHeard }
                    callLost = seconds(from: last, to: now) > RecordingMonitor.tapLostSeconds
                    callRecorded = callHeard.map { seconds(from: $0, to: now) <= RecordingMonitor.steadyGap } ?? false
                }
                // Still nothing after every construction of the tap has failed more than once: what the backup does
                // not hear, a FaceTime or phone call, is being lost unless the call tap records it, and that is shown
                // until the tap is back, the call tap delivers, or no call is on
                if !tapLost && tapUnheard > RecordingMonitor.tapLostSeconds && callLost {
                    tapLost = true
                    RecLog.write(String(format: "Call audio is not being recorded: the process tap has delivered nothing for %d s", Int(tapUnheard))
                                 + (callState == .active ? ", and the call tap nothing either" : ""))
                } else if tapLost && (tapUnheard <= RecordingMonitor.steadyGap || callRecorded || callState == .idle) {
                    tapLost = false
                    RecLog.write(tapUnheard <= RecordingMonitor.steadyGap ? "Call audio is being recorded again" : callRecorded
                                 ? "Call audio is being recorded again, by the call tap" : "No call is on any more: no call audio is being lost")
                }
            }
            let unheard = seconds(from: heard, to: now)
            var failing: Failing?
            if unheard > silentSeconds {
                failing = Failing(since: heard, text: String(format: "No system audio has arrived for %d seconds. The recording continues with silence in its place until it comes back.", Int(unheard)))
            }
            audioProblem = report(failing, steady: unheard <= RecordingMonitor.steadyGap, now: now, was: audioProblem, line: "System audio is not being recorded",
                                  title: "System Audio Is Not Being Recorded",
                                  intermittent: "System audio has kept dropping out for %d seconds. The recording continues with silence in its place while it is missing.",
                                  backTitle: "System Audio Is Back", backBody: "System audio is being recorded again.")
        }
        var current = display([micProblem, audioProblem], micSilent: micSilent)
        if tapLost { current.notice = SystemAudioSelection.tapFailedWarning }
        update(current)
    }

    /// What is wrong with a source on this tick: since when (where its audio last reached, on the timeline), and
    /// the text of the notification
    private struct Failing {
        let since: CMTime
        let text: String
    }

    /// The problem of a source that is up after this tick, at `now` on the timeline. `failing` is what is wrong with
    /// it now, nil when nothing is; `steady` whether it delivered as it should up to now. A problem begins when the
    /// source starts failing and lasts, through any short return, until it has been steady for `steadySeconds`; it
    /// is notified once it has lasted `announceSeconds` (not while the source is steady), with `intermittent` (one
    /// `%d` for the seconds) as its text when the source came back in between. Its end is notified only when it was.
    private func report(_ failing: Failing?, steady: Bool, now: CMTime, was previous: Problem?, line: String, title: String,
                        intermittent: String, backTitle: String, backBody: String) -> Problem? {
        var current: Problem
        if let previous {
            current = previous
        } else {
            guard let failing else { return nil }
            current = Problem(line: line, began: failing.since)
            RecLog.write("\(title): \(failing.text)")
        }
        if failing == nil && steady {
            let since = current.steadySince ?? now
            current.steadySince = since
            guard seconds(from: since, to: now) >= RecordingMonitor.steadySeconds else { return current }
            RecLog.write(current.announced ? backTitle : backTitle + " (it lasted less than \(Int(RecordingMonitor.announceSeconds)) s: not notified)")
            if current.announced { notify(backTitle, backBody) }
            return nil
        }
        current.steadySince = nil
        let lasted = seconds(from: current.began ?? now, to: now)
        if !current.announced && lasted >= RecordingMonitor.announceSeconds {
            current.announced = true
            // The text of the failure when it has lasted all along, else one that says it kept coming and going
            let text: String
            if let failing, let began = current.began, failing.since <= began {
                text = failing.text
            } else {
                text = String(format: intermittent, Int(lasted))
            }
            if previous != nil { RecLog.write("\(title): still so after \(Int(lasted)) s, notified") }
            notify(title, text)
        }
        return current
    }

    /// The problem that is up after this tick, for the start of the recording. `problem` is the text of its
    /// notification, nil when there is none (any more); `lasted` how long it has been going on. The log has it when
    /// it begins and ends; the user is notified of it once it has lasted `announceSeconds`, and of its end only
    /// when that was the case.
    private func reportStart(_ problem: String?, lasted: Double, line: String, was previous: Problem?, title: String, backTitle: String, backBody: String) -> Problem? {
        guard let problem else {
            if let previous {
                RecLog.write(previous.announced ? backTitle : backTitle + " (it lasted less than \(Int(RecordingMonitor.announceSeconds)) s: not notified)")
                if previous.announced { notify(backTitle, backBody) }
            }
            return nil
        }
        var current = previous ?? Problem(line: line)
        if previous == nil { RecLog.write("\(title): \(problem)") }
        if !current.announced && lasted >= RecordingMonitor.announceSeconds {
            current.announced = true
            if previous != nil { RecLog.write("\(title): still so after \(Int(lasted)) s, notified") }
            notify(title, problem)
        }
        return current
    }

    /// The status line has every problem as a sentence; the on-screen warning only those that were notified
    private func display(_ problems: [Problem?], micSilent: Bool?) -> Display {
        let up = problems.compactMap { $0 }
        func joined(_ lines: [String]) -> String? { lines.isEmpty ? nil : lines.joined(separator: ". ") }
        return Display(warning: joined(up.map(\.line)), onScreen: joined(up.filter(\.announced).map(\.line)), micSilent: micSilent)
    }

    private func update(_ display: Display) {
        guard display != shown else { return }
        shown = display
        show(display)
    }
}
