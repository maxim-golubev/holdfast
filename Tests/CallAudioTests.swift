//
//  CallAudioTests.swift
//  The call tap, a second process tap of the process that plays FaceTime and phone calls: its source, built when that
//  process gets an audio object; its track in the mix, added to the backup's wherever the process tap is not the
//  source; and the process tap that runs and hears nothing, found while the recording runs.
//

import AVFoundation
import CoreAudio
import Foundation

/// How many samples later the call tap's track has a sound than the process tap's: 14.6 ms
let callDelay = 700

/// Sample `n` of a sound, silence outside it
func value(_ sound: TestSound, _ n: Int) -> Float {
    let index = n + TestSound.lead
    return index >= 0 && index < sound.samples.count ? sound.samples[index] : 0
}

/// A tenth of a second of audio in ScreenCaptureKit's format, frame `first + i` being `sample(first + i)` in both channels
func sampledBuffer(from first: Int, pts: CMTime, _ sample: (Int) -> Float) throws -> CMSampleBuffer {
    let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), "format")
    let pcm = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800), "pcm")
    pcm.frameLength = 4800
    let data = try require(pcm.floatChannelData, "data")
    for frame in 0..<4800 {
        let value = sample(first + frame)
        data[0][frame] = value
        data[1][frame] = value
    }
    return try require(AudioSilence.sampleBuffer(from: pcm, description: format.formatDescription, at: pts), "sample buffer")
}

/// A recording made with the process tap through the real writer, without a microphone, every source given sample by
/// sample of its own track: the tap (nothing where `tapDead` says), the backup, and the call tap, which delivers
/// where `callAlive` says and not at all without `call`. Tracks without a source are continued as the monitor does.
func recordSources(_ folder: String, seconds: Double, tap: (Int) -> Float, backup: (Int) -> Float, call: ((Int) -> Float)?,
                   tapDead: (Double) -> Bool = { _ in false }, callAlive: (Double) -> Bool = { _ in true },
                   silent: ((SilentTap.Action) -> Void)? = nil) async throws -> TestRecording {
    let run = try TestRecording(folder: folder, microphone: false, settings: ["remuxAudio": true, "recordWinSound": true], tap: true)
    let writer = run.writer
    if let silent { writer.events.tapSilent = silent }
    try writer.prepareVideo(width: 320, height: 240)
    writer.startCapturing()
    var step = 0
    while Double(step) / 10 < seconds - 0.001 {
        let t = Double(step) / 10
        let pts = run.at(t)
        try run.frame(t)
        if !tapDead(t) { writer.write(CaptureSample(kind: .audio, buffer: try sampledBuffer(from: step * 4800, pts: pts, tap), pts: pts)) }
        writer.write(CaptureSample(kind: .backupAudio, buffer: try sampledBuffer(from: step * 4800, pts: pts, backup), pts: pts))
        if let call, callAlive(t) { writer.write(CaptureSample(kind: .callAudio, buffer: try sampledBuffer(from: step * 4800, pts: pts, call), pts: pts)) }
        let target = run.at(t + 0.1 - 1)
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.audioEndPTS ?? run.at(0))) >= 0.5 { writer.fillSystemAudio(upTo: target) }
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.backupEndPTS ?? run.at(0))) >= 0.5 { writer.fillBackupAudio(upTo: target) }
        if CMTimeGetSeconds(CMTimeSubtract(target, writer.callEndPTS ?? run.at(0))) >= 0.5 { writer.fillCallAudio(upTo: target) }
        usleep(15_000)
        step += 1
    }
    _ = try await run.close()
    expect(run.failures.isEmpty, "no failure: \(run.failures)")
    return run
}

/// A capture that notes what the session asks of its tap
final class TapCapture: RecordingCapture {
    let journal: Journal
    init(_ journal: Journal) { self.journal = journal }
    func stop(_ done: @escaping (Error?) -> Void) { DispatchQueue.global().async { done(nil) } }
    func releaseStream() {}
    func rebuildDeafTap() { journal.note("rebuild") }
    func tapHeardAgain() { journal.note("heard") }
}

@MainActor
func callAudioTests() async {
    /// The mix of a recording as the app makes it, checked as the app checks it
    func mixed(_ run: TestRecording) async throws -> (url: URL, plan: RecordingMixer.MixPlan) {
        let mixURL = try require(run.recording.mixURL, "mix name")
        let spans = try require(TapSpans.read(try require(run.recording.tapSpansURL, "spans file")), "spans")
        let plan = try await RecordingMixer.mix(source: run.recording.rawURL, output: mixURL, fileType: .mp4, audioSettings: run.recording.audioSettings, tapSpans: spans) { _ in }
        try await RecordingMixer.verify(source: run.recording.rawURL, output: mixURL, plan: plan)
        return (mixURL, plan)
    }
    /// What a track should hold, as `monoTrack` reads it: `sample(n)` in both channels at frame n, for `seconds`. Two
    /// channels with the same sound come out as one at the square root of two times it.
    func reference(_ seconds: Double, _ sample: (Int) -> Float) -> [Float] { (0..<Int(seconds * 48000)).map { sample($0) * Float(2).squareRoot() } }
    let delay = Double(tapDelay) / 48000

    // MARK: The rule for a tap that hears nothing

    await test("silent tap: exact zeros for 3 s while another source has sound rebuild the tap; silence everywhere, a quiet tap, and a sound that only begins or ends do not") {
        /// Feeds a tenth of a second at a time from `start` to `end`: the tap's peak and the other source's at each time
        func run(_ watch: inout SilentTap, from start: Double, to end: Double, tap: (Double) -> Float?, other: (Double) -> Float) -> [(time: Double, action: SilentTap.Action)] {
            var found = [(time: Double, action: SilentTap.Action)]()
            var step = Int((start * 10).rounded())
            while Double(step) / 10 < end - 0.001 {
                let t = Double(step) / 10
                // The backup's buffer reaches the writer first, as a tap's buffer is the later one in its track
                for action in [watch.other(from: t, to: t + 0.1, peak: other(t)), tap(t).map { watch.tap(from: t, to: t + 0.1, peak: $0) } ?? .none] where action != .none {
                    found.append((t + 0.1, action))
                }
                if tap(t) == nil { watch.tapInterrupted() }
                step += 1
            }
            return found
        }
        var deaf = SilentTap()
        let first = run(&deaf, from: 0, to: 4, tap: { _ in 0 }, other: { _ in 0.2 })
        expectEqual(first.map(\.action), [.rebuild(attempt: 1)], "zeros against sound: rebuilt")
        expectClose(first.first?.time ?? 0, 3, within: 0.11, "after 3 s")
        var idle = SilentTap()
        expectEqual(run(&idle, from: 0, to: 120, tap: { _ in 0 }, other: { _ in 0 }).count, 0, "zeros with silence elsewhere: nothing plays, nothing is done")
        expectEqual(run(&idle, from: 120, to: 240, tap: { _ in 0 }, other: { _ in 0.000_5 }).count, 0, "nor with what is below -60 dBFS elsewhere")
        var quiet = SilentTap()
        expectEqual(run(&quiet, from: 0, to: 60, tap: { _ in 0.000_001 }, other: { _ in 0.3 }).count, 0, "a tap that delivers anything but zeros hears")
        // A sound begins after ten seconds of nothing: the backup has it a quarter of a second before the tap
        var begins = SilentTap()
        expectEqual(run(&begins, from: 0, to: 30, tap: { $0 < 10.25 ? 0 : 0.2 }, other: { $0 < 10 ? 0 : 0.2 }).count, 0, "a sound that begins in the backup first is no deaf tap")
        // And ends: the tap's zeros begin where the backup's sound has just ended
        var ends = SilentTap()
        expectEqual(run(&ends, from: 0, to: 60, tap: { $0 < 10.3 ? 0.2 : 0 }, other: { $0 < 10 ? 0.2 : 0 }).count, 0, "nor one that ends")
        // A tap that goes deaf in the middle of a sound
        var mid = SilentTap()
        let found = run(&mid, from: 0, to: 40, tap: { $0 < 30 ? 0.2 : 0 }, other: { _ in 0.2 })
        expectEqual(found.first?.action, .rebuild(attempt: 1), "deaf from 30 s")
        expectClose(found.first?.time ?? 0, 33, within: 0.11, "found 3 s later")
        // One that has heard nothing for minutes of silence, when a sound comes: found half a second into it
        var late = SilentTap()
        let sudden = run(&late, from: 0, to: 110, tap: { _ in 0 }, other: { $0 < 100 ? 0 : 0.2 })
        expectEqual(sudden.first?.action, .rebuild(attempt: 1), "the first sound shows it")
        expectClose(sudden.first?.time ?? 0, 100.6, within: 0.11, "as soon as it is not just a sound beginning")
        // Silence written in the tap's place (it delivered nothing: its source's business) is not the tap's zeros
        var gaps = SilentTap()
        expectEqual(run(&gaps, from: 0, to: 60, tap: { Int($0) % 2 == 0 ? 0 : nil }, other: { _ in 0.2 }).count, 0, "zeros broken off every second are not 3 s of them")
    }

    await test("silent tap: without the grant it is rebuilt twice, then once a minute, and the user is told once; the first sound it delivers ends that") {
        var watch = SilentTap()
        var found = [(time: Double, action: SilentTap.Action)]()
        func feed(from start: Int, to end: Int, tap: Float) {
            for step in start..<end {
                let t = Double(step) / 10
                for action in [watch.other(from: t, to: t + 0.1, peak: 0.2), watch.tap(from: t, to: t + 0.1, peak: tap)] where action != .none { found.append((t + 0.1, action)) }
            }
        }
        feed(from: 0, to: 2000, tap: 0)
        expectEqual(found.map(\.action), [.rebuild(attempt: 1), .rebuild(attempt: 2), .notice, .rebuild(attempt: 3), .rebuild(attempt: 4), .rebuild(attempt: 5)],
                    "two rebuilds, the notice, then one a minute: \(found)")
        let times = found.map(\.time)
        if times.count == 6 {
            expectClose(times[0], 3, within: 0.11, "the first after 3 s")
            expectClose(times[1] - times[0], 3, within: 0.7, "the second 3 s of zeros later")
            expectClose(times[2] - times[1], 3, within: 0.7, "the notice when that changed nothing either")
            expectClose(times[3] - times[1], 60, within: 0.2, "then a minute after the last rebuild")
            expectClose(times[4] - times[3], 60, within: 0.2, "and every minute")
            expectClose(times[5] - times[4], 60, within: 0.2, "for as long as it hears nothing")
        }
        // Allowed in the meantime: the tap rebuilt last delivers sound
        found = []
        feed(from: 2000, to: 2100, tap: 0.2)
        expectEqual(found.map(\.action), [.hears], "the first sound says so, once")
        expectEqual(watch.rebuilds, 0, "and the count begins anew")
        // Deaf again later: rebuilt at once again, and no second notice
        found = []
        feed(from: 2100, to: 3000, tap: 0)
        expectEqual(found.prefix(3).map(\.action), [.rebuild(attempt: 1), .rebuild(attempt: 2), .rebuild(attempt: 3)], "rebuilt, without telling the user twice: \(found)")
        if found.count >= 3 { expectClose(found[2].time - found[1].time, 60, within: 0.2, "the third a minute after the second") }
    }

    await test("silent tap: the writer finds a tap that delivers zeros while the backup has sound, logs it and asks for a rebuild; with silence elsewhere it asks for nothing") {
        let sound = TestSound(seconds: 8, clicks: [])
        var actions = [SilentTap.Action]()
        // The tap hears for 2 s, then delivers exact zeros for 5 s; the backup has the sound throughout
        let deaf = try await recordSources("silent-writer", seconds: 7, tap: { $0 < 96000 ? value(sound, $0) : 0 }, backup: { value(sound, $0) }, call: nil,
                                           silent: { actions.append($0) })
        expectEqual(actions, [.rebuild(attempt: 1)], "one rebuild is asked for, after 3 s of zeros; the next would be due after 3 s more of them")
        expect(RecLog.lines.contains { $0.hasPrefix("System audio: the process tap has delivered only zeros for 3 s while the backup or the call tap has sound") && $0.contains("rebuilt") },
               "the log says why: \(RecLog.lines)")
        let spans = try require(TapSpans.read(try require(deaf.recording.tapSpansURL, "spans file")), "spans")
        expectEqual(spans.spans.count, 1, "its IOProc ran throughout: one span, \(spans.spans)")
        // The call tap's sound shows it as well as the backup's
        actions = []
        _ = try await recordSources("silent-writer-call", seconds: 6, tap: { _ in 0 }, backup: { _ in 0 }, call: { value(sound, $0) }, silent: { actions.append($0) })
        expectEqual(actions.first, .rebuild(attempt: 1), "zeros against the call tap's sound: \(actions)")
        // Nothing plays: the tap's zeros are what there is to hear
        actions = []
        RecLog.lines = []
        _ = try await recordSources("silent-writer-idle", seconds: 6, tap: { _ in 0 }, backup: { _ in 0 }, call: nil, silent: { actions.append($0) })
        expectEqual(actions, [], "zeros with silence elsewhere")
        expect(!RecLog.lines.contains { $0.contains("only zeros") }, "and nothing in the log: \(RecLog.lines)")
        // The largest sample of a buffer, as the writer reads it
        expectEqual(MovieWriter.peak(of: try sampledBuffer(from: 0, pts: time(1)) { _ in 0 }), 0, "exact zeros")
        expectEqual(MovieWriter.peak(of: try sampledBuffer(from: 0, pts: time(1)) { $0 == 4000 ? -0.25 : 0 }), 0.25, "one sample")
    }

    await test("silent tap: its source builds it again like one that stopped, the next construction after two failures") {
        let fakes = FakeTapFactory()
        let source = SystemAudioSource(factory: fakes.factory, sampleQueue: DispatchQueue(label: "HoldfastTests.tap"), stallSeconds: 5, checkInterval: 0.02, waitScale: 0.02) { _ in }
        try source.start()
        var live = [try LiveTap(try require(fakes.taps.first, "a tap"))]
        try? await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(fakes.taps.count, 1, "a tap whose IOProc runs is not rebuilt for that")
        for count in 2...4 {
            source.rebuildDeaf()
            expect(await waitUntil { fakes.taps.count == count }, "rebuilt when it is said to hear nothing (\(count))")
            live.append(try LiveTap(try require(fakes.taps.last, "the new tap")))
        }
        expectEqual(fakes.taps.map(\.clock), [.builtInOutput, .builtInOutput, .none, .none], "the same construction once more, then the next: \(fakes.journal.all)")
        expect(fakes.journal.all.starts(with: ["tap1.make: builtInOutput", "tap1.stop", "tap2.make: builtInOutput", "tap2.stop", "tap3.make: none"]), "each torn down before the next is made")
        expect(RecLog.lines.contains { $0.contains("failed (it delivers only zeros while the Mac plays sound)") }, "logged: \(RecLog.lines)")
        source.heardAgain()
        source.stopNow()
        live.forEach { $0.stop() }
    }

    await test("silent tap: the session has its capture rebuild the tap and tells the user once how to allow system audio recording") {
        let journal = Journal()
        let queue = DispatchQueue(label: "HoldfastTests.silent-session")
        var environment = RecorderEnvironment()
        environment.notify = { title, text in journal.note("notify: \(title): \(text)") }
        let controller = RecorderController(queue: queue, environment: environment)
        let session = try require(controller.begin(.screen), "an accepted start")
        let writer = FakeWriter(journal, queue: queue, folder: try Suite.folder("silent-session"))
        session.install(writer)
        session.attach(TapCapture(journal))
        session.startCapturing()
        session.enterRecording()
        queue.sync { writer.events.tapSilent(.rebuild(attempt: 1)) }
        expect(await waitUntil { journal.count("rebuild") == 1 }, "the capture rebuilds its tap")
        queue.sync {
            writer.events.tapSilent(.rebuild(attempt: 2))
            writer.events.tapSilent(.notice)
            writer.events.tapSilent(.notice)
        }
        expect(await waitUntil { journal.count("rebuild") == 2 }, "and again")
        let notices = journal.all.filter { $0.hasPrefix("notify: ") }
        expectEqual(notices.count, 1, "one notification, however often it is found: \(notices)")
        expect(notices.first?.hasPrefix("notify: Call Audio Not Included: ") == true, "under the title of a recording without the tap")
        expect(notices.first?.contains("System Settings, Privacy & Security, Screen & System Audio Recording, System Audio Recording Only") == true, "saying where to allow it: \(notices)")
        expect(notices.first?.contains("screen capture's system audio and the call tap") == true, "and what records meanwhile")
        queue.sync { writer.events.tapSilent(.hears) }
        expect(await waitUntil { journal.count("heard") == 1 }, "its source hears that the tap delivers sound again")
        controller.stop()
        expect(await waitUntil { controller.state == .idle }, "the recording ends as any")
    }

    // MARK: The call tap's source

    await test("call tap: no tap while the call process has no audio object; one is built when it appears mid-recording, of that process alone and without a sub-device, and taken down when it goes") {
        let journal = Journal()
        let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
        let queue = DispatchQueue(label: "HoldfastTests.call-tap")
        var samples = [CaptureSample]()
        var states = [CallAudioState]()
        let stateLock = NSLock()
        let source = CallAudioSource(factory: .hardware(hardware), sampleQueue: queue, stallSeconds: 30, checkInterval: 0.02, waitScale: 0.02,
                                     onSample: { samples.append($0) }, onState: { state in stateLock.lock(); states.append(state); stateLock.unlock() })
        func seen() -> [CallAudioState] { stateLock.lock(); defer { stateLock.unlock() }; return states }
        source.start()
        expectEqual(seen(), [.idle], "no call at the start")
        expectEqual(journal.all, ["watch"], "only the list of audio processes is listened to: no tap, no aggregate device, no IOProc")
        expectEqual(hardware.watchedObjects, [CoreAudioTapHardware.system], "on the system object")
        // Other processes come and go: the list changes, the call process is not in it
        hardware.notifyProcessList()
        source.control.sync {}
        try? await Task.sleep(nanoseconds: 50_000_000)
        source.control.sync {}
        expectEqual(journal.all, ["watch"], "still nothing built")
        // A call starts: avconferenced gets its audio objects
        hardware.callObjects = [501, 502]
        hardware.notifyProcessList()
        expect(await waitUntil { journal.count("start") == 1 }, "the call tap is built and started")
        expectEqual(hardware.tappedProcesses, [[501, 502]], "a tap of the call process's objects only")
        expectEqual(journal.count("createTap"), 0, "not a tap of everything")
        expectEqual(hardware.mains, [nil], "alone in its aggregate device: no sub-device, unlike the process tap")
        expectEqual(seen(), [.idle, .active], "a call may be playing")
        expect(RecLog.lines.contains { $0.hasPrefix("Call audio: avconferenced has 2 audio objects (501, 502)") }, "logged: \(RecLog.lines)")
        expect(RecLog.lines.contains("Call audio: call tap with no sub-device (48000 Hz, 2 ch, float32 interleaved)"), "with its construction: \(RecLog.lines)")
        // Its IOProc is called: the buffer reaches the recording as call audio, stamped where it arrived
        var asbd = hardware.format
        let pcm = try require(AVAudioPCMBuffer(pcmFormat: try require(AVAudioFormat(streamDescription: &asbd), "format"), frameCapacity: 512), "pcm")
        pcm.frameLength = 512
        fill(pcm)
        let before = CMClockGetHostTimeClock().time
        hardware.runIO(pcm.audioBufferList, host: hostTicks(-10))
        let after = CMClockGetHostTimeClock().time
        expect(await waitUntil { queue.sync { samples.count } == 1 }, "handed on")
        if let sample = queue.sync(execute: { samples.first }) {
            if case .callAudio = sample.kind {} else { expect(false, "as call audio, for the call tap's track") }
            expect(sample.arrival >= before && sample.arrival <= after, "it ends when its IOProc was called, whatever its device stamped it")
            expect(SystemAudioConverter.isDelivered(as: sample.buffer.formatDescription?.audioStreamBasicDescription ?? AudioStreamBasicDescription()), "in ScreenCaptureKit's format")
        }
        // The list changes again with the call still on: the tap stays
        hardware.notifyProcessList()
        source.control.sync {}
        try? await Task.sleep(nanoseconds: 50_000_000)
        expectEqual(journal.count("createCallTap"), 1, "not rebuilt for a change elsewhere in the list")
        // The call ends
        hardware.callObjects = []
        hardware.notifyProcessList()
        expect(await waitUntil { journal.count("destroyTap") == 1 }, "the tap is taken down with the call")
        expectEqual(seen(), [.idle, .active, .idle], "no call any more")
        expect(journal.all.suffix(4) == ["stop", "destroyIOProc", "destroyAggregate", "destroyTap"], "in the order of every tap: \(journal.all)")
        // And the next call gets a new one
        hardware.callObjects = [777]
        hardware.notifyProcessList()
        expect(await waitUntil { hardware.tappedProcesses.count == 2 }, "a second call, a second tap")
        expectEqual(hardware.tappedProcesses.last, [777], "of the process as it is then")
        source.stopNow()
        expectEqual(hardware.strayUnwatches, 0, "every listener that is removed was installed")
        expect(hardware.watching.isEmpty, "and none is left: \(hardware.watching)")
        expectEqual(journal.count("destroyTap"), 2, "the running tap is taken down at the stop")
        hardware.callObjects = [888]
        hardware.notifyProcessList()
        try? await Task.sleep(nanoseconds: 80_000_000)
        expectEqual(hardware.tappedProcesses.count, 2, "nothing is built after the stop")
    }

    await test("call tap: a call that is on at the start is tapped at once; without a sub-device failing twice, the built-in output clocks it; a tap that cannot be built at all stops nothing") {
        let journal = Journal()
        let hardware = FakeTapHardware(journal, format: tapFormat(interleaved: true))
        hardware.callObjects = [501]
        hardware.refusedClocks = [nil]
        let source = CallAudioSource(factory: .hardware(hardware), sampleQueue: DispatchQueue(label: "HoldfastTests.call-tap"), stallSeconds: 30, checkInterval: 0.02, waitScale: 0.02, onSample: { _ in })
        source.start()
        expect(await waitUntil { journal.count("start") == 1 }, "built")
        expectEqual(hardware.mains, [nil, nil, "builtin-uid"], "no sub-device twice, then the built-in output as its clock")
        expectEqual(hardware.tappedProcesses.last, [501], "of the call process")
        source.stopNow()
        expectEqual(TapClock.callOrder(builtIn: hardware.builtIn), [.none, .builtInOutput], "the call tap's order")
        expectEqual(TapClock.callOrder(builtIn: nil), [.none], "on a Mac without a built-in output")
        expect(TapClock.callOrder(builtIn: hardware.builtIn).first != TapClock.order(builtIn: hardware.builtIn, defaultOutput: hardware.output).first, "not built like the process tap")
        // Nothing can be built: the start returns, the attempts go on in the background, the stop ends them
        let broken = FakeTapHardware(Journal(), format: tapFormat(interleaved: true))
        broken.callObjects = [501]
        broken.failing = "createCallTap"
        var states = [CallAudioState]()
        let failing = CallAudioSource(factory: .hardware(broken), sampleQueue: DispatchQueue(label: "HoldfastTests.call-tap"), checkInterval: 0.02, waitScale: 0.02,
                                      onSample: { _ in }, onState: { states.append($0) })
        failing.start()
        expectEqual(states, [.idle, .active], "a call may be playing, whether or not its tap is up yet")
        expect(RecLog.lines.contains { $0.hasPrefix("Call audio: the call tap with no sub-device could not be built") }, "logged: \(RecLog.lines)")
        failing.stopNow()
        expectEqual(broken.journal.all.filter { $0.hasPrefix("destroy") }, [], "nothing was built, nothing is left")
        // A list that cannot be listened to is read every few seconds instead
        let deafList = CallAudioSource.Factory(processes: { [] }, watch: { _, _ in nil }, unwatch: { _ in }, constructions: { [.none] }, makeTap: { _, _, _, _, _ in throw TestError("not asked for") })
        let polling = CallAudioSource(factory: deafList, sampleQueue: DispatchQueue(label: "HoldfastTests.call-tap"), onSample: { _ in })
        polling.start()
        expect(RecLog.lines.contains { $0.contains("cannot be watched; it is read every 5 s instead") }, "said in the log: \(RecLog.lines)")
        polling.stopNow()
    }

    // MARK: The monitor

    await test("monitor: with the call tap, a dead process tap is shown as missing call audio only while a call may be playing and the call tap delivers nothing either") {
        // No call: the process tap is dead for a minute, the backup records. Nothing of a call can be lost.
        let idle = try MonitorRun("monitor-call-idle", microphone: false, systemAudio: true, backup: true, call: true)
        idle.call(.idle)
        idle.ticks(after: 0, through: 5) { idle.systemAudio(upTo: $0); idle.backup(upTo: $0) }
        idle.ticks(after: 5, through: 60) { idle.backup(upTo: $0) }
        expectEqual(idle.notice, nil, "no call, no notice")
        expectEqual(idle.warning, nil, "and no warning: the backup records")
        expect(idle.fills("call") > 0, "the call tap's track is continued with silence while there is no call")
        // A call starts and its tap delivers: the call is being recorded
        idle.call(.active)
        idle.ticks(after: 60, through: 100) { idle.backup(upTo: $0); idle.callAudio(upTo: $0) }
        expectEqual(idle.notice, nil, "the call tap records the call: nothing to tell")
        // The call tap stops too: after 15 s the call is being lost
        idle.ticks(after: 100, through: 115) { idle.backup(upTo: $0) }
        expectEqual(idle.notice, nil, "not within 15 s")
        idle.ticks(after: 115, through: 116) { idle.backup(upTo: $0) }
        expectEqual(idle.notice, "Call audio is not being recorded", "then the recording says so")
        expect(RecLog.lines.contains { $0.hasPrefix("Call audio is not being recorded: the process tap has delivered nothing for") && $0.hasSuffix("and the call tap nothing either") }, "the log: \(RecLog.lines)")
        // The call tap comes back: the notice goes, though the process tap is still dead
        idle.ticks(after: 116, through: 118) { idle.backup(upTo: $0); idle.callAudio(upTo: $0) }
        expectEqual(idle.notice, nil, "recorded again by the call tap")
        expect(RecLog.lines.contains("Call audio is being recorded again, by the call tap"), "the log: \(RecLog.lines)")
        // Both dead again, then the call ends: nothing is being lost any more
        idle.ticks(after: 118, through: 140) { idle.backup(upTo: $0) }
        expectEqual(idle.notice, "Call audio is not being recorded", "both taps dead during a call")
        idle.call(.idle)
        idle.ticks(after: 140, through: 141) { idle.backup(upTo: $0) }
        expectEqual(idle.notice, nil, "the call is over")
        expectEqual(idle.notified, [], "none of it was a notification")

        // A call whose tap never delivers, from the moment it starts
        let dead = try MonitorRun("monitor-call-dead", microphone: false, systemAudio: true, backup: true, call: true)
        dead.call(.idle)
        dead.ticks(after: 0, through: 30) { dead.backup(upTo: $0) }
        expectEqual(dead.notice, nil, "the process tap dead for 30 s without a call: nothing")
        dead.call(.active)
        dead.ticks(after: 30, through: 45) { dead.backup(upTo: $0) }
        expectEqual(dead.notice, nil, "the call tap has 15 s from the start of the call")
        dead.ticks(after: 45, through: 46.5) { dead.backup(upTo: $0) }
        expectEqual(dead.notice, "Call audio is not being recorded", "then it is shown")
        dead.ticks(after: 46.5, through: 50) { dead.backup(upTo: $0); dead.systemAudio(upTo: $0) }
        expectEqual(dead.notice, nil, "and goes when the process tap is back")
    }

    await test("monitor: a call tap that delivers does not stand for system audio: with the process tap and the backup both silent the warning comes") {
        let run = try MonitorRun("monitor-call-warning", microphone: false, systemAudio: true, backup: true, call: true)
        run.call(.active)
        run.ticks(after: 0, through: 3) { run.systemAudio(upTo: $0); run.backup(upTo: $0); run.callAudio(upTo: $0) }
        // The process tap dies and the stream's system audio stops; the call tap's IOProc goes on handing over
        // buffers (zeros, or one process's sound), as it does for as long as that process has an audio object
        run.ticks(after: 3, through: 8) { run.callAudio(upTo: $0) }
        expectEqual(run.warning, nil, "5 s without the tap and the backup is not yet a problem")
        run.ticks(after: 8, through: 9) { run.callAudio(upTo: $0) }
        expectEqual(run.warning, "System audio is not being recorded", "more than 5 s is, whatever the call tap delivers")
        expectEqual(run.notice, nil, "the call itself is being recorded: no call-audio notice")
        expect(run.fills("system audio") > 0 && run.fills("backup") > 0, "the other two tracks are continued with silence")
        expectEqual(run.fills("call"), 0, "its own needs nothing")
        run.ticks(after: 9, through: 18) { run.callAudio(upTo: $0) }
        expectEqual(run.notified, ["System Audio Is Not Being Recorded"], "notified after 15 s")
        expectEqual(run.onScreen, "System audio is not being recorded", "and shown on screen")
        run.ticks(after: 18, through: 30) { run.callAudio(upTo: $0) }
        expectEqual(run.warning, "System audio is not being recorded", "the call tap does not end it")
        expectEqual(run.notified, ["System Audio Is Not Being Recorded"], "one notification")
        // The backup comes back
        run.ticks(after: 30, through: 36) { run.callAudio(upTo: $0); run.backup(upTo: $0) }
        expectEqual(run.warning, nil, "the backup, or the tap, ends it")
        expectEqual(run.notified, ["System Audio Is Not Being Recorded", "System Audio Is Back"], "and its return is notified")
        // The same with no call on and no call tap built: nothing changes
        let idle = try MonitorRun("monitor-call-warning-idle", microphone: false, systemAudio: true, backup: true, call: true)
        idle.call(.idle)
        idle.ticks(after: 0, through: 3) { idle.systemAudio(upTo: $0); idle.backup(upTo: $0) }
        idle.ticks(after: 3, through: 9)
        expectEqual(idle.warning, "System audio is not being recorded", "without a call the two silent sources are the same problem")
    }

    // MARK: The mix

    await test("call audio: FaceTime with the process tap dead for a stretch: the mix has the voice there from the call tap, once, within 1 ms, and a click on each switch once") {
        // Only the taps hear the call. The process tap has nothing from 8 s to 11 s; the call tap has the voice
        // throughout, 14.6 ms later in its track. A click right on each edge, one inside the outage, one far from it.
        let edges = [8 * 48000 - tapDelay, 11 * 48000 - tapDelay]
        let voice = TestSound(seconds: 16, clicks: edges + [Int(9.5 * 48000) - tapDelay, 4 * 48000 - tapDelay], seed: 0x0C0F_FEE1_2345_6789)
        let run = try await recordSources("call-facetime", seconds: 16, tap: { value(voice, $0 - tapDelay) }, backup: { _ in 0 },
                                          call: { value(voice, $0 - tapDelay - callDelay) }, tapDead: { $0 >= 8 && $0 < 11 })
        let (mixURL, plan) = try await mixed(run)
        expectEqual(plan.alignment, SystemAudioAlignment.Measurement.none, "nothing in the backup to measure the tap by")
        expectClose(plan.callAlignment?.offset ?? 0, Double(callDelay) / 48000, within: 0.000_5, "the call tap's audio 14.6 ms later than the tap's: \(String(describing: plan.callAlignment))")
        expectEqual(plan.segments.map(\.source), [.tap, .backup, .tap], "the tap, not the tap, the tap: \(plan.segments)")
        expectEqual(plan.callStretches.count, 1, "the call tap in the one stretch the tap is not the source: \(plan.callStretches)")
        expectClose(plan.callStretches.first?.start ?? 0, 8, within: 0.001, "from where the tap's audio ends")
        expectClose(plan.callStretches.first?.end ?? 0, 11, within: 0.001, "to where it begins again")
        expect(RecLog.lines.contains { $0.hasPrefix("Call audio alignment: the call tap's audio is 14.6 ms later than the process tap's") }, "the log, alignment: \(RecLog.lines)")
        expect(RecLog.lines.contains { $0.hasPrefix("Call audio in the mix: 3.0 s from the call tap in 1 stretch") }, "the log, what was taken: \(RecLog.lines)")
        // What the tap would have held had it lived: the voice where its track has it
        let whole = reference(16) { value(voice, $0 - tapDelay) }
        let mix = try monoTrack(mixURL, track: 0), callTrack = try monoTrack(run.recording.rawURL, track: 2), tapTrack = try monoTrack(run.recording.rawURL, track: 0)
        expect(clicks(in: tapTrack, from: 9, to: 10).isEmpty, "the tap's track has nothing in its outage")
        expectEqual(clicks(in: callTrack, from: 9, to: 10).count, 1, "the call tap's track has the voice there")
        for (name, time) in [("where the tap died", 8.0), ("where it came back", 11.0), ("inside the outage", 9.5), ("far from it", 4.0)] {
            let inMix = clicks(in: mix, from: time - 0.3, to: time + 0.3), wanted = clicks(in: whole, from: time - 0.3, to: time + 0.3)
            expectEqual(inMix.count, 1, "the click \(name) is in the mix once: \(inMix)")
            guard let mixClick = inMix.first, let click = wanted.first else { continue }
            expectClose(mixClick.time, time, within: 0.001, "the click \(name), within 1 ms of its time")
            expectClose(mixClick.energy / click.energy, 1, within: 0.25, "the click \(name), whole and not doubled")
            expect(likeness(mix, whole, from: time - 0.25, to: time + 0.25) > 0.8, "the voice goes on unbroken \(name): \(likeness(mix, whole, from: time - 0.25, to: time + 0.25))")
        }
        expect(likeness(mix, whole, from: 8.2, to: 10.8) > 0.8, "the voice in the outage: \(likeness(mix, whole, from: 8.2, to: 10.8))")
        expect(likeness(mix, whole, from: 1, to: 15) > 0.8, "one voice from start to end: \(likeness(mix, whole, from: 1, to: 15))")
        let searched = Array(mix[(9 * 48000 - 14400)..<(10 * 48000 + 14400)])
        let lag = SystemAudioAlignment.lag(of: Array(whole[(9 * 48000)..<(10 * 48000)]), in: searched, margin: 14400, most: 12000, width: 24)
        expect(abs(lag ?? 1000) <= 48, "in the outage the voice is within 1 ms of where the tap would have had it: \(String(describing: lag))")
    }

    await test("call audio: a browser call with the process tap dead for a stretch: the backup has the voice, the call tap's track is silent or empty, and the mix is as without a call tap") {
        let edges = [8 * 48000 - tapDelay, 11 * 48000 - tapDelay]
        let sound = TestSound(seconds: 16, clicks: edges + [Int(9.5 * 48000), 4 * 48000])
        // Once with a call tap that never ran (no call process), once with one that ran and delivered zeros
        for (name, call) in [("absent", nil), ("silent", { _ in 0 })] as [(String, ((Int) -> Float)?)] {
            RecLog.lines = []
            let run = try await recordSources("call-zoom-\(name)", seconds: 16, tap: { value(sound, $0 - tapDelay) }, backup: { value(sound, $0) }, call: call,
                                              tapDead: { $0 >= 8 && $0 < 11 })
            let (mixURL, plan) = try await mixed(run)
            expectClose(plan.alignment?.offset ?? 0, delay, within: 0.000_5, "\(name): the tap measured against the backup")
            expectEqual(plan.segments.map(\.source), [.tap, .backup, .tap], "\(name): the tap, the backup, the tap")
            expect(plan.callStretches.isEmpty && plan.callAlignment == nil, "\(name): nothing is taken from the call tap's track: \(plan.callStretches)")
            expect(!RecLog.lines.contains { $0.hasPrefix("Call audio") }, "\(name): and nothing is said of it: \(RecLog.lines)")
            let backup = try monoTrack(run.recording.rawURL, track: 1), mix = try monoTrack(mixURL, track: 0)
            for time in [8 - delay, 11 - delay, 9.5, 4.0] {
                let inMix = clicks(in: mix, from: time - 0.3, to: time + 0.3)
                expectEqual(inMix.count, 1, "\(name): the click at \(time) s is in the mix once: \(inMix)")
                expectClose(inMix.first?.time ?? 0, time, within: 0.001, "\(name): at its time")
            }
            expect(likeness(mix, backup, from: 1, to: 15) > 0.8, "\(name): one sound from start to end: \(likeness(mix, backup, from: 1, to: 15))")
        }
    }

    await test("call audio: a call and other sound while the process tap is dead: the backup plus the call tap is what the tap would have held") {
        // The tap hears both, the backup only the music, the call tap only the voice; the tap is dead from 8 s to 11 s
        let music = TestSound(seconds: 16, clicks: [4 * 48000])
        let voice = TestSound(seconds: 16, clicks: [Int(9.5 * 48000)], seed: 0x0C0F_FEE1_2345_6789)
        let run = try await recordSources("call-both", seconds: 16, tap: { value(music, $0 - tapDelay) + value(voice, $0 - tapDelay) }, backup: { value(music, $0) },
                                          call: { value(voice, $0 - tapDelay - callDelay) }, tapDead: { $0 >= 8 && $0 < 11 })
        let (mixURL, plan) = try await mixed(run)
        expectClose(plan.alignment?.offset ?? 0, delay, within: 0.000_5, "the tap against the backup, by the music: \(String(describing: plan.alignment))")
        expectClose(plan.callAlignment?.offset ?? 0, Double(callDelay) / 48000, within: 0.000_5, "the call tap against the tap, by the voice: \(String(describing: plan.callAlignment))")
        expectEqual(plan.segments.map(\.source), [.tap, .backup, .tap], "the tap, the backup with the call tap, the tap")
        expectEqual(plan.callStretches.count, 1, "the call tap in the outage")
        // On the mix's timeline, which is the backup's: both sounds where they were played
        let both = reference(16) { value(music, $0) + value(voice, $0) }
        let onlyMusic = reference(16) { value(music, $0) }, onlyVoice = reference(16) { value(voice, $0) }
        let mix = try monoTrack(mixURL, track: 0)
        func level(_ audio: [Float], _ start: Double, _ end: Double) -> Double {
            let range = Int(start * 48000)..<Int(end * 48000)
            return (range.reduce(0.0) { $0 + Double(audio[$1]) * Double(audio[$1]) } / Double(range.count)).squareRoot()
        }
        let inside = (start: 8.2, end: 10.8)
        expect(likeness(mix, both, from: inside.start, to: inside.end) > 0.9, "in the outage the mix is the two sounds together: \(likeness(mix, both, from: inside.start, to: inside.end))")
        expect(likeness(mix, onlyMusic, from: inside.start, to: inside.end) < 0.85 && likeness(mix, onlyVoice, from: inside.start, to: inside.end) < 0.85,
               "neither alone: \(likeness(mix, onlyMusic, from: inside.start, to: inside.end)), \(likeness(mix, onlyVoice, from: inside.start, to: inside.end))")
        expectClose(level(mix, inside.start, inside.end) / level(both, inside.start, inside.end), 1, within: 0.1, "at the level the tap would have had")
        expectClose(level(mix, 2, 7) / level(both, 2, 7), 1, within: 0.1, "as where the tap had it")
        expect(likeness(mix, both, from: 1, to: 15) > 0.9, "one sound from start to end, across both switches: \(likeness(mix, both, from: 1, to: 15))")
        expectEqual(clicks(in: mix, from: 9.2, to: 9.8).count, 1, "the voice's click in the outage, once")
        expectClose(clicks(in: mix, from: 9.2, to: 9.8).first?.time ?? 0, 9.5, within: 0.001, "within 1 ms of its time")
        expectEqual(clicks(in: mix, from: 3.7, to: 4.3).count, 1, "the music's click, where the tap had both, once")
        for edge in [8 - delay, 11 - delay] {
            expect(likeness(mix, both, from: edge - 0.25, to: edge + 0.25) > 0.9, "unbroken across the switch at \(edge) s: \(likeness(mix, both, from: edge - 0.25, to: edge + 0.25))")
        }
    }

    await test("call audio: a process tap alive throughout: the mix is bit for bit the mix of the same recording without a call tap's track, and the tap's audio plus the microphone") {
        // Lossless files, so that the samples read are the samples written. The tap hears music and a call, the
        // backup the music, the call tap the call; the tap never stops.
        let music = TestSound(seconds: 12, clicks: [4 * 48000])
        let voice = TestSound(seconds: 12, clicks: [], seed: 0x0C0F_FEE1_2345_6789)
        let tap: (Int) -> Float = { value(music, $0 - tapDelay) + value(voice, $0 - tapDelay) }
        let backup: (Int) -> Float = { value(music, $0) }
        let call: (Int) -> Float = { value(voice, $0 - tapDelay - callDelay) }
        let microphone: (Int) -> Float = { Float(0.05 * sin(2 * Double.pi * 300 * Double($0) / 48000)) }
        let folder = try Suite.folder("call-identical")
        let without = folder.appendingPathComponent("three tracks.recording.mov"), with = folder.appendingPathComponent("four tracks.recording.mov")
        try await TestMovie.write(to: without, seconds: 12, samples: [tap, backup, microphone], settings: TestLoudness.lossless, fileType: .mov)
        try await TestMovie.write(to: with, seconds: 12, samples: [tap, backup, call, microphone], settings: TestLoudness.lossless, fileType: .mov)
        let alive = TapSpans([.init(start: 0, end: .infinity)])
        func mix(_ raw: URL, _ name: String, level: Bool = false) async throws -> (plan: RecordingMixer.MixPlan, audio: [Float]) {
            let url = folder.appendingPathComponent("\(name).mov")
            let plan = try await RecordingMixer.mix(source: raw, output: url, fileType: .mov, audioSettings: TestLoudness.lossless, tapSpans: alive, levelVoices: level) { _ in }
            try await RecordingMixer.verify(source: raw, output: url, plan: plan)
            return (plan, try await TestLoudness.track(url))
        }
        let before = try await mix(without, "mix of three")
        RecLog.lines = []
        let after = try await mix(with, "mix of four")
        expectEqual(after.plan.alignment, before.plan.alignment, "the same offset measured")
        expectEqual(before.plan.alignment?.offset, Double(tapDelay) / 48000, "the tap 52.4 ms later than the backup")
        expectEqual(after.plan.segments, [.init(start: 0, end: 12, source: .tap)], "the tap throughout")
        expect(after.plan.callStretches.isEmpty, "nothing taken from the call tap: \(after.plan.callStretches)")
        expectClose(after.plan.callAlignment?.offset ?? 0, Double(callDelay) / 48000, within: 0.000_1, "though it was measured")
        expect(RecLog.lines.contains("Call audio in the mix: none needed: the process tap was alive wherever the call tap has sound"), "the log says so: \(RecLog.lines)")
        expectEqual(after.audio.count, before.audio.count, "the same length")
        var different = 0
        for index in 0..<min(before.audio.count, after.audio.count) where before.audio[index].bitPattern != after.audio[index].bitPattern { different += 1 }
        expectEqual(different, 0, "samples that differ between the two mixes")
        // And both are what a mix with the tap alive has always been: the tap's audio on the backup's timeline, plus the microphone
        var wrong = 0
        let frames = before.audio.count / 2
        for frame in 0..<(frames - tapDelay) {
            let sum = tap(frame + tapDelay) + microphone(frame)
            if after.audio[frame * 2] != sum || after.audio[frame * 2 + 1] != sum { wrong += 1 }
        }
        expectEqual(wrong, 0, "frames that are not the tap's audio plus the microphone, of \(frames - tapDelay)")
        // With Level Voices too
        let leveledBefore = try await mix(without, "leveled mix of three", level: true), leveledAfter = try await mix(with, "leveled mix of four", level: true)
        expectEqual(leveledAfter.plan.leveling?.text, leveledBefore.plan.leveling?.text, "the same gains")
        var leveledDifferent = leveledBefore.audio.count == leveledAfter.audio.count ? 0 : 1
        for index in 0..<min(leveledBefore.audio.count, leveledAfter.audio.count) where leveledBefore.audio[index].bitPattern != leveledAfter.audio[index].bitPattern { leveledDifferent += 1 }
        expectEqual(leveledDifferent, 0, "samples that differ between the two leveled mixes")
        print("        measured: \(before.audio.count) samples compared between the mixes with and without the call tap's track, \(different) different; \(frames - tapDelay) frames against the tap plus the microphone, \(wrong) different; leveled, \(leveledDifferent) different")
    }

    await test("call audio: the choice counts a tap that is digital silence while the call tap has sound as not the tap's, and adds the call tap only where it has sound") {
        let blocks = 3000
        let sound = [Float](repeating: 0.1, count: blocks), nothing = [Float](repeating: 0, count: blocks)
        let alive = TapSpans([.init(start: 0, end: 30)])
        func levels(_ loud: (Double) -> Bool) -> [Float] { (0..<blocks).map { loud(Double($0) / 100) ? 0.1 : 0 } }
        // FaceTime: the backup has nothing, and the tap delivers zeros for five seconds while the call tap has the voice
        let deaf = SystemAudioChoice.plan(tap: levels { !($0 >= 10 && $0 < 15) }, backup: nothing, spans: alive, duration: 30, call: sound)
        expectEqual(deaf, [.init(start: 0, end: 10, source: .tap), .init(start: 10, end: 15, source: .backup), .init(start: 15, end: 30, source: .tap)], "five seconds of zeros against the call tap's sound")
        expectEqual(SystemAudioChoice.callStretches(deaf, call: sound, shift: 0).map(\.start), [10], "the call tap's audio is taken there")
        expectEqual(SystemAudioChoice.plan(tap: levels { !($0 >= 10 && $0 < 15) }, backup: nothing, spans: alive, duration: 30, call: nothing), [.init(start: 0, end: 30, source: .tap)],
                    "silence in all three is silence: the tap throughout")
        // The end of a sound the call tap holds a little later than the tap is not its signal
        let tail = SystemAudioChoice.plan(tap: levels { $0 < 10 }, backup: nothing, spans: alive, duration: 30, call: levels { $0 < 10.25 })
        expectEqual(tail, [.init(start: 0, end: 30, source: .tap)], "250 ms of the same sound's end")
        // Two outages, a call only in the second
        let dead = TapSpans([.init(start: 0, end: 5), .init(start: 8, end: 15), .init(start: 18, end: 30)])
        let two = SystemAudioChoice.plan(tap: levels { !($0 >= 5 && $0 < 8) && !($0 >= 15 && $0 < 18) }, backup: sound, spans: dead, duration: 30, call: levels { $0 >= 14 && $0 < 20 })
        expectEqual(two.map(\.source), [.tap, .backup, .tap, .backup, .tap], "both outages are the backup's")
        let stretches = SystemAudioChoice.callStretches(two, call: levels { $0 >= 14 && $0 < 20 }, shift: 0)
        expectEqual(stretches.map(\.start), [15], "the call tap is added in the one it has sound in")
        expect(SystemAudioChoice.callSummary(stretches).hasPrefix("3.0 s from the call tap in 1 stretch"), "for the log: \(SystemAudioChoice.callSummary(stretches))")
        expect(SystemAudioChoice.callSummary([]).hasPrefix("none needed"), "and when nothing is")
        // The call tap's track read where its audio is: 50 ms later than in the mix
        let late = SystemAudioChoice.callStretches([.init(start: 0, end: 10, source: .tap), .init(start: 10, end: 10.04, source: .backup), .init(start: 10.04, end: 30, source: .tap)],
                                                   call: levels { $0 >= 10.05 && $0 < 10.09 }, shift: 0.05)
        expectEqual(late.count, 1, "found by the shift")
    }

    await test("call audio: a sound-only recording has a file for the call tap, and its audio is merged in where the process tap is not the source") {
        let run = try TestRecording(folder: "call-sound", audioOnly: true, microphone: false, settings: ["recordWinSound": true, "audioFormat": "aac"], tap: true)
        let writer = run.writer
        try writer.prepareAudio()
        let callURL = try require(run.recording.callAudioURL, "the call tap's file")
        expect(callURL.lastPathComponent.hasSuffix(" (call audio).recording.m4a"), "written next to the recording: \(callURL.lastPathComponent)")
        writer.startCapturing()
        // The tap (440 Hz) is dead from 2 s to 3 s; the backup is silent (a FaceTime call); the call tap has 2000 Hz from 1 s on
        for step in 0..<50 {
            let t = Double(step) / 10
            if !(t >= 2 && t < 3) { writer.write(CaptureSample(kind: .audio, buffer: try toneBuffer(frequency: 440, at: t, pts: run.at(t)), pts: run.at(t))) }
            writer.write(CaptureSample(kind: .backupAudio, buffer: try toneBuffer(frequency: 1000, at: t, pts: run.at(t), amplitude: 0), pts: run.at(t)))
            if t >= 1 { writer.write(CaptureSample(kind: .callAudio, buffer: try toneBuffer(frequency: 2000, at: t, pts: run.at(t)), pts: run.at(t))) }
            let target = run.at(t + 0.1 - 1)
            if CMTimeGetSeconds(CMTimeSubtract(target, writer.audioEndPTS ?? run.at(0))) >= 0.5 { writer.fillSystemAudio(upTo: target) }
            if CMTimeGetSeconds(CMTimeSubtract(target, writer.callEndPTS ?? run.at(0))) >= 0.5 { writer.fillCallAudio(upTo: target) }
        }
        _ = try await run.close()
        expect(run.failures.isEmpty, "no failure: \(run.failures)")
        let tapURL = try require(run.recording.systemAudioURL, "tap file"), backupURL = try require(run.recording.backupAudioURL, "backup file")
        let spans = try require(TapSpans.read(try require(run.recording.tapSpansURL, "spans file")), "spans")
        let callSpans = try require(TapSpans.read(try require(run.recording.callSpansURL, "the call tap's spans")), "the call tap's spans")
        expectClose(callSpans.spans.first?.start ?? 0, 1, within: 0.001, "the call tap from 1 s: \(callSpans.spans)")
        let merged = tapURL.deletingLastPathComponent().appendingPathComponent("merged.m4a")
        try RecordingMixer.mergeSystemAudio(tap: tapURL, backup: backupURL, call: callURL, spans: spans, to: merged, settings: run.recording.audioSettings)
        let strengths = try toneStrengths(merged, track: nil, frequencies: [440, 2000])
        let tapTone = strengths[0], callTone = strengths[1]
        expect(tapTone[110..<190].allSatisfy { $0 > 0.05 } && tapTone[310..<480].allSatisfy { $0 > 0.05 }, "the tap's audio where it was alive")
        expect(callTone[110..<190].allSatisfy { $0 < 0.01 } && callTone[310..<480].allSatisfy { $0 < 0.01 }, "and nothing of the call tap's there: the tap has the call")
        expect(callTone[210..<290].allSatisfy { $0 > 0.05 }, "the call tap's audio where the tap was dead")
        expect(tapTone[210..<290].allSatisfy { $0 < 0.01 }, "and nothing else there")
        expect(RecLog.lines.contains { $0.hasPrefix("Call audio of the sound-only recording: 1.0 s from the call tap in 1 stretch") }, "the log: \(RecLog.lines)")
        // A call tap's file that is not there changes nothing
        let plain = tapURL.deletingLastPathComponent().appendingPathComponent("merged plain.m4a")
        try RecordingMixer.mergeSystemAudio(tap: tapURL, backup: backupURL, call: tapURL.deletingLastPathComponent().appendingPathComponent("missing.m4a"), spans: spans, to: plain, settings: run.recording.audioSettings)
        expect(try toneStrengths(plain, track: nil, frequencies: [2000])[0][210..<290].allSatisfy { $0 < 0.01 }, "without it the outage is the backup's silence")
        // The merged file takes the tap's name; the sources go unless they are kept
        let keptTap = try require(run.recording.tapKeptURL, "name of the kept tap file")
        try RecordingFileStore.adoptMergedSystemAudio(merged: merged, tap: tapURL, keptTap: keptTap, backup: backupURL, call: callURL, keepSources: false)
        expect(FileManager.default.fileExists(atPath: tapURL.path), "the merged file under the tap's name")
        expect(![keptTap, backupURL, callURL].contains { FileManager.default.fileExists(atPath: $0.path) }, "the three sources deleted")
    }

    await test("call audio: a recording killed after an outage during a call is recovered with the call tap's audio, and both taps' spans go") {
        let run = try recordWithBackup("call-kill", seconds: 12, tapDead: { $0 >= 5 && $0 < 6 }, backupSilent: { _ in true }, call: { $0 >= 3 && $0 < 9 })
        let folder = try Suite.folder("call-recovery")
        let snapshot = folder.appendingPathComponent("Recording at C.recording.mp4")
        var copied = false
        for _ in 0..<50 where !copied {
            try? FileManager.default.removeItem(at: snapshot)
            try FileManager.default.copyItem(at: run.recording.rawURL, to: snapshot)
            if let seconds = await RecordingMixer.inspect(snapshot).seconds, seconds >= 9 { copied = true } else { usleep(100_000) }
        }
        let base = folder.appendingPathComponent("Recording at C").path
        try FileManager.default.copyItem(at: try require(run.recording.tapSpansURL, "spans"), to: RecordingFileStore.tapSpansURL(base: base))
        try FileManager.default.copyItem(at: try require(run.recording.callSpansURL, "the call tap's spans"), to: RecordingFileStore.callSpansURL(base: base))
        _ = try await run.close()
        expect(copied, "a fragment reached the disk: every track was fed, the call tap's with silence before and after the call")
        let lines = await RecordingRecovery.recover(RecordingFileStore(directory: folder.path).leftovers(), audioSettings: ["mp4": TestMovie.aac]) { _ in }
        expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                    ["Recording at C (recovered).mp4", "Recording at C (recovered, unmixed, 4 audio tracks).mp4"], "the folder afterwards, without either tap's spans")
        expect(lines.count == 1 && lines[0].contains("mixed now"), "the report: \(lines)")
        let strengths = try toneStrengths(folder.appendingPathComponent("Recording at C (recovered).mp4"), frequencies: [440, 2000])
        expect(strengths[1][510..<590].allSatisfy { $0 > 0.05 }, "the call tap's audio in the outage")
        expect(strengths[0][510..<590].allSatisfy { $0 < 0.01 }, "where the tap had nothing")
        expect(strengths[1][310..<490].allSatisfy { $0 < 0.01 } && strengths[0][310..<490].allSatisfy { $0 > 0.05 }, "and the tap alone where it was alive, though the call tap had sound too")
    }
}
