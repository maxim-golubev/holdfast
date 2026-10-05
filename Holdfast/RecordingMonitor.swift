//
//  RecordingMonitor.swift
//  Holdfast
//

import AVFoundation
import Foundation

/// Runs twice a second on the sample queue while a recording is capturing, whether or not any buffer arrives.
/// Every `RecordingSession` has its own.
///
/// It has the recording's writer keep every track of the file advancing when its source delivers nothing:
/// silence for the microphone and for system audio, the last frame again for video. A track that stops would hold back the fragments of all the others
/// and leave a hole that players handle badly. It is also the watchdog that tells the user while a source is not
/// being recorded. Everything here is only used on the sample queue; the methods the session calls and the timer trap elsewhere.
final class RecordingMonitor {
    static let interval: Double = 0.5
    /// How long a source may deliver nothing before its track is continued without it. The tracks are filled up to
    /// this far behind the present, so that a buffer which is merely late still fits.
    static let gapSeconds: Double = 1
    /// How long a source may deliver nothing before the user is warned
    static let silentSeconds: Double = 5
    /// How long the microphone may deliver nothing but zeros before the user is warned
    static let zeroSeconds: Double = 20

    private let queue: DispatchQueue
    /// A problem began or is over: title and text of the notification. Called on the sample queue.
    var notify: (String, String) -> Void = { _, _ in }
    /// What the status bar shows changed: the warning, and whether the microphone is silent (nil without one).
    /// Called on the sample queue.
    var show: (String?, Bool?) -> Void = { _, _ in }
    /// The writer of the recording, while it is being watched
    private var writer: RecordingWriter?
    private var timer: DispatchSourceTimer?
    private var lastTick: UInt64 = 0
    /// When the monitor was started, which is when the capture began to run
    private var started: UInt64 = 0
    private var startWarning: String?
    private var skippedLateTick = false
    /// A resumed recording continues at the first buffer that arrives. Only when none has arrived a whole tick later
    /// does the monitor continue it.
    private var resumeWaited = false
    /// End of the last microphone audio written, and of the last that was not digital silence
    private var micHeard: CMTime?
    private var micSound: CMTime?
    private var micPeak: Float = 0
    /// End of the last system audio that ScreenCaptureKit delivered and that was written
    private var audioHeard: CMTime?
    private var micWarning: String?
    private var audioWarning: String?
    private var shownWarning: String?
    private var shownSilent: Bool?

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
        startWarning = nil
        skippedLateTick = false
        resumeWaited = false
        micHeard = nil
        micSound = nil
        micPeak = 0
        audioHeard = nil
        micWarning = nil
        audioWarning = nil
        show(warning: nil, silent: nil)
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
        let startTitle = "Nothing is being recorded yet".local
        guard let sessionStart = writer.sessionStart else {
            // The file starts with the first complete picture (the first system audio of an audio-only recording),
            // and all audio that arrives before it is left out. When that takes this long it may never come, a
            // window that is minimized or a display that is asleep for example, and the user must know.
            var problem: String?
            if started != 0, uptime >= started, Double(uptime - started) / 1_000_000_000 > silentSeconds {
                problem = recording.audioOnly
                    ? "No system audio has arrived since the recording was started, so nothing has been recorded so far.".local
                    : "No picture has arrived from the screen or window since the recording was started, so nothing has been recorded so far, audio included. Check that the window is visible and the display is awake.".local
            }
            report(problem, was: startWarning, title: startTitle, backTitle: "", backBody: "")
            startWarning = problem
            if problem != nil { show(warning: startTitle, silent: nil) }
            return
        }
        if startWarning != nil {
            report(nil, was: startWarning, title: startTitle, backTitle: "Recording Started".local, backBody: "The recording has started now. What came before is not in it.".local)
            startWarning = nil
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
        writer.repeatVideoFrame(at: now)
        guard writer.isCapturing else { return }

        var micProblem: String?
        var micSilent: Bool?
        if writer.hasMicrophoneTrack, writer.isMicrophoneMuted {
            // Silence the user asked for is no problem to report. The time muted does not count towards a
            // warning afterwards either, and a warning that was up goes without a "Microphone Is Back".
            micHeard = now
            micSound = now
            micWarning = nil
            micPeak = 0
            micSilent = true
        } else if writer.hasMicrophoneTrack {
            if seconds(from: micHeard ?? sessionStart, to: now) > silentSeconds {
                micProblem = String(format: "No audio has arrived from the microphone for %d seconds. The recording continues with silence in its place until the microphone comes back.".local, Int(silentSeconds))
            } else if seconds(from: micSound ?? sessionStart, to: now) > zeroSeconds {
                micProblem = String(format: "The microphone has delivered nothing but silence for %d seconds. Check that it is not muted or in use by another app.".local, Int(zeroSeconds))
            }
            // Nothing, or nothing but digital zeros, since the last tick
            micSilent = micPeak == 0
            micPeak = 0
        }
        var audioProblem: String?
        if hasSystemAudio, seconds(from: audioHeard ?? sessionStart, to: now) > silentSeconds {
            audioProblem = String(format: "No system audio has arrived for %d seconds. The recording continues with silence in its place until it comes back.".local, Int(silentSeconds))
        }
        report(micProblem, was: micWarning, title: "Microphone Is Not Being Recorded".local,
               backTitle: "Microphone Is Back".local, backBody: "Microphone audio is being recorded again.".local)
        micWarning = micProblem
        report(audioProblem, was: audioWarning, title: "System Audio Is Not Being Recorded".local,
               backTitle: "System Audio Is Back".local, backBody: "System audio is being recorded again.".local)
        audioWarning = audioProblem
        // The status line is a sentence, the notifications have titles
        var warning: String?
        if micProblem != nil { warning = "Microphone is not being recorded".local }
        if audioProblem != nil { warning = (warning.map { $0 + ". " } ?? "") + "System audio is not being recorded".local }
        show(warning: warning, silent: micSilent)
    }

    /// One notification when a problem starts and one when it is over
    private func report(_ problem: String?, was previous: String?, title: String, backTitle: String, backBody: String) {
        if let problem = problem, previous == nil {
            RecLog.write("\(title): \(problem)")
            notify(title, problem)
        } else if problem == nil, previous != nil {
            RecLog.write(backTitle)
            notify(backTitle, backBody)
        }
    }

    private func show(warning: String?, silent: Bool?) {
        guard warning != shownWarning || silent != shownSilent else { return }
        shownWarning = warning
        shownSilent = silent
        show(warning, silent)
    }
}
