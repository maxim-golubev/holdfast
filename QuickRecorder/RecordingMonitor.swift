//
//  RecordingMonitor.swift
//  QuickRecorder
//

import AVFoundation
import CoreAudio
import ScreenCaptureKit
import SwiftUI

/// What the status bar shows about the recording in progress. Main thread only.
final class RecordingHealth: ObservableObject {
    static let shared = RecordingHealth()
    /// Set while a track is not being recorded: the status bar turns into its warning state and shows this as its tooltip
    @Published var warning: String?
    /// Nil without a microphone track. 0: digital silence or nothing at all, 1: quiet, 2: sound.
    @Published var micLevel: Int?
    /// True from the moment a recording is stopped until its files are final (`SCContext.isSaving`)
    @Published var saving = false
    /// From 0 to 1 while the audio tracks of a stopped recording are being mixed, nil otherwise
    @Published var mixProgress: Double?
    /// From 0 to 1 while a recording left by an earlier run is being mixed at launch, nil otherwise
    @Published var recoveryProgress: Double?
}

/// Runs twice a second on `SCContext.sampleQueue` while a recording is capturing, whether or not any buffer arrives.
///
/// It has the recording's `MovieWriter` keep every track of the file advancing when its source delivers nothing:
/// silence for the microphone and for system audio, the last frame again for video. A track that stops would hold back the fragments of all the others
/// and leave a hole that players handle badly. It is also the watchdog that tells the user while a source is not
/// being recorded. Everything here is only used on the sample queue.
enum RecordingMonitor {
    private static let interval: Double = 0.5
    /// How long a source may deliver nothing before its track is continued without it. The tracks are filled up to
    /// this far behind the present, so that a buffer which is merely late still fits.
    static let gapSeconds: Double = 1
    /// How long a source may deliver nothing before the user is warned
    static let silentSeconds: Double = 5
    /// How long the microphone may deliver nothing but zeros before the user is warned
    static let zeroSeconds: Double = 20

    private static var timer: DispatchSourceTimer?
    private static var lastTick: UInt64 = 0
    /// When the monitor was started, which is when the capture began to run
    private static var started: UInt64 = 0
    private static var startWarning: String?
    private static var skippedLateTick = false
    /// A resumed recording continues at the first buffer that arrives. Only when none has arrived a whole tick later
    /// does the monitor continue it.
    static var resumeWaited = false
    /// End of the last microphone audio written, and of the last that was not digital silence
    private static var micHeard: CMTime?
    private static var micSound: CMTime?
    private static var micPeak: Float = 0
    /// End of the last system audio that ScreenCaptureKit delivered and that was written
    private static var audioHeard: CMTime?
    private static var micWarning: String?
    private static var audioWarning: String?
    private static var shownWarning: String?
    private static var shownLevel: Int?

    static func start(for id: UUID) {
        stop()
        guard let writer = SCContext.writer, writer.isCapturing, writer.recording.id == id else { return }
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: SCContext.sampleQueue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { tick(id) }
        timer = source
        started = DispatchTime.now().uptimeNanoseconds
        source.resume()
    }

    static func stop() {
        timer?.cancel()
        timer = nil
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
        show(warning: nil, level: nil)
    }

    static func microphoneWritten(upTo end: CMTime, peak: Float) {
        micHeard = end
        if peak > 0 { micSound = end }
        micPeak = max(micPeak, peak)
    }

    static func systemAudioWritten(upTo end: CMTime) {
        audioHeard = end
    }

    private static func seconds(from start: CMTime, to end: CMTime) -> Double {
        return CMTimeGetSeconds(CMTimeSubtract(end, start))
    }

    private static func tick(_ id: UUID) {
        let uptime = DispatchTime.now().uptimeNanoseconds
        let sinceLastTick = lastTick == 0 ? 0 : Double(uptime &- lastTick) / 1_000_000_000
        lastTick = uptime
        guard let writer = SCContext.writer, writer.isCapturing, !writer.isPaused, writer.recording.id == id else { return }
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
            if problem != nil { show(warning: startTitle, level: nil) }
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
        let target = CMTimeSubtract(now, CMTime(seconds: gapSeconds, preferredTimescale: 600))

        writer.fillMicrophone(upTo: target)
        let hasSystemAudio = writer.hasSystemAudio
        if hasSystemAudio, seconds(from: writer.audioEndPTS ?? sessionStart, to: target) >= 0.5 {
            writer.fillSystemAudio(upTo: target)
        }
        writer.repeatVideoFrame(at: now)
        guard writer.isCapturing else { return }

        var micProblem: String?
        var level: Int?
        if writer.hasMicrophoneTrack {
            if seconds(from: micHeard ?? sessionStart, to: now) > silentSeconds {
                micProblem = String(format: "No audio has arrived from the microphone for %d seconds. The recording continues with silence in its place until the microphone comes back.".local, Int(silentSeconds))
            } else if seconds(from: micSound ?? sessionStart, to: now) > zeroSeconds {
                micProblem = String(format: "The microphone has delivered nothing but silence for %d seconds. Check that it is not muted or in use by another app.".local, Int(zeroSeconds))
            }
            level = micPeak >= 0.01 ? 2 : (micPeak > 0 ? 1 : 0)
            micPeak = 0
        }
        var audioProblem: String?
        if hasSystemAudio, seconds(from: audioHeard ?? sessionStart, to: now) > silentSeconds {
            audioProblem = String(format: "No system audio has arrived for %d seconds. The recording continues with silence in its place until it comes back.".local, Int(silentSeconds))
        }
        report(micProblem, was: micWarning, title: "Microphone is not being recorded".local,
               backTitle: "Microphone Is Back".local, backBody: "Microphone audio is being recorded again.".local)
        micWarning = micProblem
        report(audioProblem, was: audioWarning, title: "System audio is not being recorded".local,
               backTitle: "System Audio Is Back".local, backBody: "System audio is being recorded again.".local)
        audioWarning = audioProblem
        var warning: String?
        if micProblem != nil { warning = "Microphone is not being recorded".local }
        if audioProblem != nil { warning = (warning.map { $0 + ". " } ?? "") + "System audio is not being recorded".local }
        show(warning: warning, level: level)
    }

    /// One notification when a problem starts and one when it is over
    private static func report(_ problem: String?, was previous: String?, title: String, backTitle: String, backBody: String) {
        if let problem = problem, previous == nil {
            RecLog.write("\(title): \(problem)")
            SCContext.showNotification(title: title, body: problem, id: "quickrecorder.watchdog.\(UUID().uuidString)")
        } else if problem == nil, previous != nil {
            RecLog.write(backTitle)
            SCContext.showNotification(title: backTitle, body: backBody, id: "quickrecorder.watchdog.\(UUID().uuidString)")
        }
    }

    private static func show(warning: String?, level: Int?) {
        guard warning != shownWarning || level != shownLevel else { return }
        shownWarning = warning
        shownLevel = level
        DispatchQueue.main.async {
            RecordingHealth.shared.warning = warning
            RecordingHealth.shared.micLevel = level
        }
    }
}

/// Follows the audio input devices while a recording has a microphone track: when the system default input changes
/// (recording the default microphone) or the chosen device disappears or comes back, the stream is told to capture
/// from the device that should be used now. Main thread only.
enum MicDevices {
    private static var watching = false
    private static var pending: DispatchWorkItem?
    /// How often a switch the stream refused is tried again before the next device change
    private static var retriesLeft = 0

    /// UID of the system default input device, which is what `AVCaptureDevice.uniqueID` holds for audio devices
    static func defaultInputUID() -> String? {
        let fallback = AVCaptureDevice.default(for: .audio)?.uniqueID
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let found = uid else { return fallback }
        return found.takeRetainedValue() as String
    }

    /// Installs the listeners once. They stay for the life of the app and do nothing while no microphone is being recorded.
    static func watch() {
        guard !watching else { return }
        watching = true
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
                // A device change comes as a burst of notifications, and the device list lags a little behind them
                retriesLeft = 3
                schedule(after: 0.7, announce: true)
            }
            if status != noErr { print("Cannot watch the audio devices (selector \(selector)): \(status)") }
        }
    }

    private static func schedule(after delay: Double, announce: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { followDevices(announce: announce) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func followDevices(announce: Bool) {
        guard let capture = SCContext.capture, capture.recordsMic else { return }
        let conf = capture.configuration
        let devices = SCContext.getMicrophone()
        let selection = capture.micSelection
        let selectedIsPresent = selection != "default" && devices.contains(where: { $0.uniqueID == selection })
        guard let wanted = selectedIsPresent ? selection : defaultInputUID() else { return }
        let previous = capture.micActiveDeviceID
        guard wanted != previous else { return }
        func name(_ id: String?) -> String {
            guard let id = id else { return "none" }
            return devices.first(where: { $0.uniqueID == id })?.localizedName ?? id
        }
        let wantedName = name(wanted)
        RecLog.write("Microphone switch: from \"\(name(previous))\" to \"\(wantedName)\" (\(selection == "default" ? "the default input changed" : (selectedIsPresent ? "the chosen microphone is back" : "the chosen microphone is gone")))")
        // A default input that is not among the capture devices is left to the system to pick
        let previousCaptureID = conf.microphoneCaptureDeviceID
        conf.microphoneCaptureDeviceID = devices.contains(where: { $0.uniqueID == wanted }) ? wanted : nil
        capture.micActiveDeviceID = wanted
        if announce && selection != "default" && !selectedIsPresent {
            let body = String(format: "\"%@\" is not connected any more. Recording continues with the default microphone \"%@\".".local, SCContext.selectedMicName(), wantedName)
            SCContext.showNotification(title: "Microphone Unavailable".local, body: body, id: "quickrecorder.microphone.\(UUID().uuidString)")
        }
        capture.applyConfiguration { error in
            guard let error = error else {
                RecLog.write("Microphone switch: now capturing \"\(wantedName)\"")
                return
            }
            RecLog.write("Microphone switch to \"\(wantedName)\" failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                // Back to what the stream is still capturing, then a few more tries; after those, at the next device change
                guard SCContext.capture === capture, capture.micActiveDeviceID == wanted else { return }
                capture.micActiveDeviceID = previous
                conf.microphoneCaptureDeviceID = previousCaptureID
                if retriesLeft > 0 {
                    retriesLeft -= 1
                    schedule(after: 2, announce: false)
                }
            }
        }
    }
}
