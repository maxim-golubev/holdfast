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
}

/// Runs twice a second on `SCContext.sampleQueue` while a recording is capturing, whether or not any buffer arrives.
///
/// It keeps every track of the file advancing when its source delivers nothing: silence for the microphone and for
/// system audio, the last frame again for video. A track that stops would hold back the fragments of all the others
/// and leave a hole that players handle badly. It is also the watchdog that tells the user while a source is not
/// being recorded. Everything here is only used on the sample queue.
enum RecordingMonitor {
    private static let interval: Double = 0.5
    /// How long a source may deliver nothing before its track is continued without it. The tracks are filled up to
    /// this far behind the present, so that a buffer which is merely late still fits.
    static let gapSeconds: Double = 1
    /// A hole between two system audio buffers shorter than this is not filled
    static let gapTolerance: Double = 0.1
    /// How long a source may deliver nothing before the user is warned
    static let silentSeconds: Double = 5
    /// How long the microphone may deliver nothing but zeros before the user is warned
    static let zeroSeconds: Double = 20

    private static var timer: DispatchSourceTimer?
    private static var lastTick: UInt64 = 0
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
        guard SCContext.isCapturing, SCContext.recording?.id == id else { return }
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: SCContext.sampleQueue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { tick(id) }
        timer = source
        source.resume()
    }

    static func stop() {
        timer?.cancel()
        timer = nil
        lastTick = 0
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
        guard SCContext.isCapturing, !SCContext.isPaused, SCContext.recording?.id == id,
              let sessionStart = SCContext.sessionStart, let anchor = SCContext.clockAnchor, uptime >= anchor.uptime else { return }
        // After the process was held up, the buffers that piled up may still be waiting behind this tick. Judging the
        // sources now would take them for stalled, put silence where their audio belongs and warn about nothing.
        // Only one tick in a row is passed over: by the next one those buffers have been handled, and a timer that
        // the system keeps firing late must not switch the monitor off.
        if sinceLastTick > interval * 2 && !skippedLateTick {
            skippedLateTick = true
            return
        }
        skippedLateTick = false
        if SCContext.isResume && !resumeWaited {
            resumeWaited = true
            return
        }
        resumeWaited = false
        if let writer = SCContext.vW, writer.status == .failed {
            SCContext.abortRecording(reason: SCContext.writeFailure(writer.error))
            return
        }
        // The present on the clock of the buffers, taken from the last buffer that arrived and the time since then.
        // That is the timestamp a buffer arriving now would carry, whatever clock the stream uses.
        let raw = CMTimeAdd(anchor.raw, CMTime(value: CMTimeValue(uptime - anchor.uptime), timescale: 1_000_000_000))
        let now = SCContext.timelineTime(raw)
        let target = CMTimeSubtract(now, CMTime(seconds: gapSeconds, preferredTimescale: 600))

        if let converter = SCContext.micConverter, let micInput = SCContext.micInput {
            converter.fill(upTo: target, atLeast: Int64(MicConverter.sampleRate / 2)) { SCContext.append($0, to: micInput) }
            SCContext.noteEnd(converter.end)
        }
        let hasSystemAudio = SCContext.awInput != nil || SCContext.audioFile != nil
        if hasSystemAudio, seconds(from: SCContext.audioEndPTS ?? sessionStart, to: target) >= 0.5 {
            fillSystemAudio(upTo: target)
        }
        repeatVideoFrame(at: now)
        guard SCContext.isCapturing else { return }

        var micProblem: String?
        var level: Int?
        if SCContext.micInput != nil {
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
            print("\(title): \(problem)")
            SCContext.showNotification(title: title, body: problem, id: "quickrecorder.watchdog.\(UUID().uuidString)")
        } else if problem == nil, previous != nil {
            print(backTitle)
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

    /// Where a system audio buffer that covers `pts` to `endPTS` goes: at the end of the system audio written so far.
    /// Nil when it must not be written: it lies before that end (silence was already written in its place), or the
    /// silence for a hole in front of it could not be written yet. That end is counted from what was written, not
    /// read from the timestamps, so a buffer the writer did not take leaves a hole that is still there for the next
    /// buffer to see. Holes add up and are filled with silence once they exceed `gapTolerance`; a buffer that
    /// overlaps the end is written whole, which puts the audio late by less than one buffer and no more.
    static func placeSystemAudio(from pts: CMTime, to endPTS: CMTime) -> CMTime? {
        guard let end = SCContext.audioEndPTS else { return pts }
        if pts < end { return endPTS > end ? end : nil }
        guard seconds(from: end, to: pts) > gapTolerance else { return end }
        fillSystemAudio(upTo: pts)
        guard let filled = SCContext.audioEndPTS, seconds(from: filled, to: pts) <= gapTolerance else { return nil }
        return filled
    }

    /// Appends silence to the system audio from where it ends up to `time`: to the audio track of a video recording,
    /// or to the system audio file of an audio-only recording, which has no timestamps and would otherwise come out
    /// shorter than the microphone file next to it.
    static func fillSystemAudio(upTo time: CMTime) {
        guard let from = SCContext.audioEndPTS ?? SCContext.sessionStart else { return }
        let file = SCContext.audioFile
        let input = SCContext.awInput
        var description = SCContext.audioFormatDescription
        var format: AVAudioFormat?
        if let file = file {
            format = file.processingFormat
        } else if let known = description {
            // The format ScreenCaptureKit delivered last, so the track does not change format for the silence
            format = AVAudioFormat(cmAudioFormatDescription: known)
        } else {
            // Nothing was delivered yet: what the stream is configured for
            format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
            description = format?.formatDescription
        }
        guard let format = format, format.sampleRate > 0 else { return }
        let scale = CMTimeScale(format.sampleRate)
        var position = CMTimeConvertScale(from, timescale: scale, method: .roundTowardPositiveInfinity)
        var left = CMTimeConvertScale(CMTimeSubtract(time, position), timescale: scale, method: .roundTowardNegativeInfinity).value
        while left > 0 {
            let count = min(left, Int64(scale / 2))
            guard let pcm = AudioSilence.pcm(format: format, frames: count) else { return }
            if let file = file {
                do {
                    try file.write(from: pcm)
                } catch {
                    SCContext.abortRecording(reason: SCContext.writeFailure(error))
                    return
                }
            } else {
                guard let input = input, let description = description,
                      let buffer = AudioSilence.sampleBuffer(from: pcm, description: description, at: position),
                      SCContext.append(buffer, to: input) else { return }
            }
            position = CMTimeAdd(position, CMTime(value: count, timescale: scale))
            left -= count
            SCContext.audioEndPTS = position
            SCContext.noteEnd(position)
        }
    }

    /// ScreenCaptureKit delivers no frames while the picture does not change (a static slide, a locked or sleeping
    /// display). The last frame is then written again once a second, so the video track keeps up with the audio.
    private static func repeatVideoFrame(at now: CMTime) {
        guard let vwInput = SCContext.vwInput, let last = SCContext.videoPTS, SCContext.lastVideoFrame != nil else { return }
        guard seconds(from: last, to: now) > SCContext.videoStallSeconds else { return }
        // The frame is going to be used for a while: give its surface back to the stream
        SCContext.detachLastVideoFrame()
        guard let repeated = SCContext.lastVideoFrame else { return }
        // A little in the past, so a frame that is on its way with an earlier timestamp than now still comes after it
        let time = CMTimeSubtract(now, CMTime(seconds: SCContext.videoStallSeconds / 2, preferredTimescale: 600))
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard let again = try? CMSampleBuffer(copying: repeated, withNewTiming: [timing]) else { return }
        if SCContext.append(again, to: vwInput) {
            SCContext.videoPTS = time
            SCContext.noteEnd(time)
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
        guard SCContext.recordsMic, let stream = SCContext.stream, let conf = SCContext.streamConfiguration else { return }
        let devices = SCContext.getMicrophone()
        let selection = SCContext.micSelection
        let selectedIsPresent = selection != "default" && devices.contains(where: { $0.uniqueID == selection })
        guard let wanted = selectedIsPresent ? selection : defaultInputUID() else { return }
        let previous = SCContext.micActiveDeviceID
        guard wanted != previous else { return }
        func name(_ id: String?) -> String {
            guard let id = id else { return "none" }
            return devices.first(where: { $0.uniqueID == id })?.localizedName ?? id
        }
        let wantedName = name(wanted)
        print("Microphone switch: from \"\(name(previous))\" to \"\(wantedName)\" (\(selection == "default" ? "the default input changed" : (selectedIsPresent ? "the chosen microphone is back" : "the chosen microphone is gone")))")
        // A default input that is not among the capture devices is left to the system to pick
        let previousCaptureID = conf.microphoneCaptureDeviceID
        conf.microphoneCaptureDeviceID = devices.contains(where: { $0.uniqueID == wanted }) ? wanted : nil
        SCContext.micActiveDeviceID = wanted
        if announce && selection != "default" && !selectedIsPresent {
            let body = String(format: "\"%@\" is not connected any more. Recording continues with the default microphone \"%@\".".local, SCContext.selectedMicName(), wantedName)
            SCContext.showNotification(title: "Microphone Unavailable".local, body: body, id: "quickrecorder.microphone.\(UUID().uuidString)")
        }
        stream.updateConfiguration(conf) { error in
            guard let error = error else {
                print("Microphone switch: now capturing \"\(wantedName)\"")
                return
            }
            print("Microphone switch to \"\(wantedName)\" failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                // Back to what the stream is still capturing, then a few more tries; after those, at the next device change
                guard SCContext.stream === stream, SCContext.micActiveDeviceID == wanted else { return }
                SCContext.micActiveDeviceID = previous
                conf.microphoneCaptureDeviceID = previousCaptureID
                if retriesLeft > 0 {
                    retriesLeft -= 1
                    schedule(after: 2, announce: false)
                }
            }
        }
    }
}
