//
//  main.swift
//  The 90-minute simulation (Tools/soak.sh). Modes:
//    record <folder>    the whole meeting, stopped as the app stops, mixed and verified as the app does, then measured
//    kill <folder>      the same meeting up to Plan.killAt, then the process kills itself without finishing the writer
//    recover <folder>   what the app does at launch with what the killed run left, then measured
//

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

/// The settings of a meeting recording, in the argument domain: this process only, nothing is written
UserDefaults.standard.setVolatileDomain([
    "frameRate": Plan.fps, "recordWinSound": true, "remuxAudio": true, "keepUnmixed": true,
    "audioFormat": "aac", "videoFormat": "mp4", "showPreview": false,
], forName: UserDefaults.argumentDomain)

func peakMemory() -> String {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return String(format: "%.0f MB", Double(usage.ru_maxrss) / 1_048_576)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    say("usage: soak record|kill|recover <folder>")
    exit(2)
}
let mode = arguments[1]
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let began = Date()
enum Found { static var problems = [String]() }

func describe(_ stats: RunStats, _ recording: SimulatedRecording) {
    say(String(format: "  fed in %.1f s of wall time: %d events (%d frames, %d system audio buffers, %d microphone buffers, %d monitor ticks)",
               stats.feedSeconds, stats.events, stats.frames, stats.systemBuffers, stats.micBuffers, stats.ticks))
    say(String(format: "  waited for the writer's inputs %d times, %.1f s in all; not taken by an input: %d frames, %d system audio buffers",
               stats.waits, stats.waitSeconds, stats.framesNotTaken, stats.systemNotTaken))
    say(String(format: "  session start %.3f s on the stream's clock; time taken out for the pause %.3f s (pause pressed for %.0f s)",
               stats.sessionStart ?? -1, stats.pauseOffset, Plan.pause.end - Plan.pause.start))
    say("  frames written again by the monitor: \(stats.repeats), outside the static slide at \(stats.repeatsElsewhere.map { String(format: "%.1f", $0) })")
    say("  microphone buffers the converter dropped, by arrival: \(stats.micDrops)")
    say("  memory footprint every 5 simulated minutes (MB): " + stats.footprints.map { String(format: "%.0f", $0.megabytes) }.joined(separator: " "))
    for entry in stats.settled {
        say(String(format: "  memory footprint at %.0f s: %.0f MB while fed at full speed, %.0f MB once the writer had 5 s to catch up", entry.time, entry.before, entry.after))
    }
    say("  monitor notifications:")
    for note in stats.notifications { say(String(format: "    %8.2f s  %@", note.time, note.title)) }
    say("  log:")
    for line in RecLog.lines { say("    " + line) }
    if !stats.failures.isEmpty { Found.problems.append("writer failures: \(stats.failures)") }
}

/// Everything measured in one file: lengths, markers, time code, silence
func measure(raw: URL?, mixed: URL?, timeline: OutputTimeline, stop: Double, expectedLength: Double, cutOff: Bool = false) async throws {
    let holes = expectedMicrophoneHoles(stop: stop, sessionStart: timeline.sessionStart)
    let outputHoles = holes.map { (start: timeline.outputAfterPause($0.start), end: timeline.outputAfterPause($0.end)) }.filter { $0.end - $0.start >= 0.03 }
    func micAbsent(_ marker: Marker) -> Bool {
        let muted = marker.time + Plan.burst > Plan.mute.start && marker.time < Plan.mute.end
        return muted || holes.contains { marker.time + Plan.burst > $0.start && marker.time < $0.end }
    }

    say("")
    say("1. Durations (expected \(String(format: "%.3f", expectedLength)) s of output)")
    var rawTracks = [TrackInfo](), mixedTracks = [TrackInfo]()
    if let raw = raw { rawTracks = try await Checks.durations(raw, expected: expectedLength, label: "two-track recording") }
    if let mixed = mixed { mixedTracks = try await Checks.durations(mixed, expected: expectedLength, label: "mixed recording") }
    if cutOff {
        // A file cut off by a kill: each track ends where its last fragment on disk does
        for (label, tracks) in [("recording", rawTracks), ("mix", mixedTracks)] {
            for track in tracks {
                say(String(format: "    %@ track %d: %.3f s of the %.3f s recorded before the kill, %.3f s lost", label, track.id, track.duration, expectedLength, expectedLength - track.duration))
            }
        }
    } else {
        for track in rawTracks + mixedTracks where abs(track.duration - expectedLength) > 0.2 {
            Found.problems.append(String(format: "track %d is %.3f s, expected %.3f s", track.id, track.duration, expectedLength))
        }
    }

    say("")
    say("2. Markers and time code")
    var rawVideo = [(number: Int, offset: Double)]()
    var system = [(marker: Marker, offset: Double)](), mic = [(marker: Marker, offset: Double)]()
    if let raw = raw {
        let audio = rawTracks.filter { $0.type == .audio }
        guard audio.count == 2 else { throw SoakError("the recording has \(audio.count) audio tracks") }
        let end = audio.map(\.end).min() ?? 0
        say("  two-track recording:")
        system = try Checks.markers(raw, track: audio[0].id, Plan.systemMarkers, timeline: timeline, until: end, absent: { _ in false }, label: "system audio", report: &Found.problems)
        Checks.printOffsets(system, label: "system audio", timeline: timeline)
        mic = try Checks.markers(raw, track: audio[1].id, Plan.micMarkers, timeline: timeline, until: end, absent: micAbsent, label: "microphone", report: &Found.problems)
        Checks.printOffsets(mic, label: "microphone", timeline: timeline)
        let absent = Plan.micMarkers.filter { timeline.output($0.time) != nil && micAbsent($0) }.map(\.index)
        say("    microphone markers that fall where the microphone delivered nothing or was muted (checked absent): \(absent)")
        rawVideo = try Checks.video(raw, timeline: timeline, until: stop, cutOff: cutOff, label: "video", report: &Found.problems)
        // A/V: each system audio marker against the picture whose time code is nearest to it
        var av = [(index: Int, offset: Double)]()
        for entry in system {
            let time = entry.marker.time
            guard let nearest = rawVideo.min(by: { abs(VideoSchedule.time(of: $0.number) - time) < abs(VideoSchedule.time(of: $1.number) - time) }),
                  abs(VideoSchedule.time(of: nearest.number) - time) < 0.5 else { continue }
            av.append((entry.marker.index, entry.offset - nearest.offset))
        }
        if let worst = av.max(by: { abs($0.offset) < abs($1.offset) }) {
            say(String(format: "    A/V (system audio marker minus the picture next to it): %d pairs, largest %@ at marker %d, first %@, last %@",
                       av.count, ms(worst.offset), worst.index, ms(av.first!.offset), ms(av.last!.offset)))
        }
        var pairs = [(index: Int, offset: Double)]()
        for entry in mic { if let other = system.first(where: { $0.marker.index == entry.marker.index }) { pairs.append((entry.marker.index, entry.offset - other.offset)) } }
        if let worst = pairs.max(by: { abs($0.offset) < abs($1.offset) }) {
            say(String(format: "    microphone minus system audio (same minute): %d pairs, largest %@ at minute %d, first %@, last %@",
                       pairs.count, ms(worst.offset), worst.index, ms(pairs.first!.offset), ms(pairs.last!.offset)))
        }
        for (label, offsets) in [("system audio", system), ("microphone", mic)] {
            if let worst = offsets.max(by: { abs($0.offset) < abs($1.offset) }), abs(worst.offset) > 0.1 {
                Found.problems.append(String(format: "%@ marker %d is %@ from where it belongs", label, worst.marker.index, ms(worst.offset)))
            }
        }
        if let worst = rawVideo.max(by: { abs($0.offset) < abs($1.offset) }), abs(worst.offset) > 0.1 {
            Found.problems.append(String(format: "frame %d is %@ from where it belongs", worst.number, ms(worst.offset)))
        }
    }
    if let mixed = mixed {
        guard let audio = mixedTracks.first(where: { $0.type == .audio }) else { throw SoakError("the mix has no audio track") }
        say("  mixed recording (one audio track holding both):")
        let mixedSystem = try Checks.markers(mixed, track: audio.id, Plan.systemMarkers, timeline: timeline, until: audio.end, absent: { _ in false }, label: "mix, system audio", report: &Found.problems)
        Checks.printOffsets(mixedSystem, label: "system audio in the mix", timeline: timeline)
        let mixedMic = try Checks.markers(mixed, track: audio.id, Plan.micMarkers, timeline: timeline, until: audio.end, absent: micAbsent, label: "mix, microphone", report: &Found.problems)
        Checks.printOffsets(mixedMic, label: "microphone in the mix", timeline: timeline)
        if raw != nil {
            // Against the recording it was made from: the mix must not move anything
            var moved = 0.0
            for entry in mixedSystem { if let r = system.first(where: { $0.marker.index == entry.marker.index }) { moved = max(moved, abs(entry.offset - r.offset)) } }
            for entry in mixedMic { if let r = mic.first(where: { $0.marker.index == entry.marker.index }) { moved = max(moved, abs(entry.offset - r.offset)) } }
            say("    largest difference between a marker in the mix and in the recording: \(ms(moved))")
        }
        let mixedVideo = try Checks.video(mixed, timeline: timeline, until: stop, cutOff: cutOff, label: "mix video", report: &Found.problems)
        if !rawVideo.isEmpty {
            let same = zip(rawVideo, mixedVideo).allSatisfy { $0.number == $1.number && abs($0.offset - $1.offset) < 1e-6 }
            say("    the mix's pictures are those of the recording at the same times: \(same && rawVideo.count == mixedVideo.count)")
        }
    }

    say("")
    say("3. Silence")
    if let raw = raw {
        let audio = rawTracks.filter { $0.type == .audio }
        // The microphone's lag at a time: that of the last microphone marker before it
        let lag: (Double) -> Double = { t in mic.last { (timeline.output($0.marker.time) ?? .infinity) < t }?.offset ?? 0 }
        try Checks.silence(raw, track: audio[1].id, expectedHoles: outputHoles, lag: lag, label: "microphone track", report: &Found.problems)
        try Checks.silence(raw, track: audio[0].id, expectedHoles: [], label: "system audio track", report: &Found.problems)
    }
    if let mixed = mixed, let audio = mixedTracks.first(where: { $0.type == .audio }) {
        try Checks.silence(mixed, track: audio.id, expectedHoles: [], label: "mixed track", report: &Found.problems)
    }
}

switch mode {
case "record", "kill":
    let killed = mode == "kill"
    let stop = killed ? Plan.killAt : Plan.length
    say("Holdfast soak: simulated \(killed ? "recording killed at \(Int(stop)) s" : "90-minute recording") (synthetic buffers through the real pipeline)")
    let sim = try SimulatedRecording(folder: folder)
    try sim.prepare()
    say("  recording file: \(sim.recording.rawURL.lastPathComponent)")
    let started = Date()
    try sim.run(until: stop, realTimeFrom: killed ? stop - 20 : nil)
    describe(sim.stats, sim)
    say("  peak memory while recording: \(peakMemory())")
    if killed {
        // As a kill -9 leaves it: the writer is neither finished nor closed
        say(String(format: "  killing the process %.1f s after the start, without finishing the writer", Date().timeIntervalSince(started)))
        kill(getpid(), SIGKILL)
    }

    // The stop: RecordingSession.takeWriter, then RecordingSaver.save (close, mix, verify, names)
    let finished = sim.finish()
    say("  " + (sim.writer.micConverter?.summary ?? ""))
    guard let file = finished.writer, finished.sessionStarted else { throw SoakError("nothing to close") }
    let closing = Date()
    if file.status == .writing { await file.finishWriting() }
    guard file.status == .completed else { throw SoakError("the file did not close: \(String(describing: file.error))") }
    say(String(format: "  closed in %.1f s", Date().timeIntervalSince(closing)))
    let recording = sim.recording
    guard let mixURL = recording.mixURL, let unmixedURL = recording.unmixedURL else { throw SoakError("no mix names") }
    var verified = "not run"
    let mixing = Date()
    if !RecordingFileStore.hasRoomForCopy(of: recording.rawURL) {
        verified = "not run: no room for a copy"
        Found.problems.append("no room to mix")
    } else {
        do {
            var lastPercent = -10
            try await RecordingMixer.mix(source: recording.rawURL, output: mixURL, fileType: recording.fileType, audioSettings: recording.audioSettings) { fraction in
                let percent = Int(fraction * 100)
                if percent >= lastPercent + 25 { lastPercent = percent; say("    mixing \(percent)%") }
            }
            let mixed = Date()
            say(String(format: "  mixed in %.1f s", mixed.timeIntervalSince(mixing)))
            try await RecordingMixer.verify(source: recording.rawURL, output: mixURL)
            say(String(format: "  verified in %.1f s", Date().timeIntervalSince(mixed)))
            try FileManager.default.moveItem(at: mixURL, to: recording.finalURL)
            _ = RecordingFileStore.keep(written: recording.rawURL, as: unmixedURL)
            verified = "passed"
        } catch {
            verified = "FAILED: \(error.localizedDescription)"
            Found.problems.append("mix or verify failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: mixURL)
            _ = RecordingFileStore.keep(written: recording.rawURL, as: unmixedURL)
        }
    }
    say("  mixer verification: \(verified)")
    say("  peak memory up to the end of the mix: \(peakMemory())")
    say(String(format: "  wall time up to the end of the mix: %.1f s", Date().timeIntervalSince(began)))
    let timeline = OutputTimeline(sessionStart: sim.stats.sessionStart ?? Plan.firstFrame, pauseOffset: sim.stats.pauseOffset)
    let expected = stop - timeline.sessionStart - (Plan.pause.end - Plan.pause.start)
    let mixedFile = FileManager.default.fileExists(atPath: recording.finalURL.path) ? recording.finalURL : nil
    try await measure(raw: unmixedURL, mixed: mixedFile, timeline: timeline, stop: stop, expectedLength: expected)

case "recover":
    say("Holdfast soak: launch recovery of what the killed run left")
    let store = RecordingFileStore(directory: folder.path)
    let found = store.leftovers()
    say("  leftovers: \(found.map { $0.url.lastPathComponent })")
    guard let leftover = found.first(where: { !$0.isMix }) else { throw SoakError("no leftover recording") }
    let attributes = try FileManager.default.attributesOfItem(atPath: leftover.url.path)
    say(String(format: "  left on disk: %.1f MB", Double((attributes[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576))
    let inspection = await RecordingMixer.inspect(leftover.url)
    say("  inspect: \(inspection.seconds.map { String(format: "%.3f s", $0) } ?? "does not open"), \(inspection.fragmented ? "still in fragments (never closed)" : "closed"), \(inspection.mixable ? "one video and two audio tracks" : "not mixable")")
    let recovering = Date()
    let lines = await RecordingRecovery.recover(found, audioSettings: ["mp4": MovieWriter.audioSettings(videoFormat: "mp4")]) { _ in }
    say(String(format: "  recovery took %.1f s and reports:", Date().timeIntervalSince(recovering)))
    for line in lines { say("    " + line) }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    say("  folder afterwards: \(names)")
    let base = leftover.base
    let recoveredMix = URL(fileURLWithPath: base + " (recovered).mp4")
    let recoveredRaw = URL(fileURLWithPath: base + " (recovered, unmixed, 2 audio tracks).mp4")
    let timeline = OutputTimeline(sessionStart: Plan.firstFrame, pauseOffset: 0)
    let delivered = Plan.killAt - timeline.sessionStart
    say(String(format: "  recorded before the kill: %.3f s", delivered))
    let raw = FileManager.default.fileExists(atPath: recoveredRaw.path) ? recoveredRaw : nil
    let mixed = FileManager.default.fileExists(atPath: recoveredMix.path) ? recoveredMix : nil
    if raw == nil || mixed == nil { Found.problems.append("recovery did not leave both files") }
    // Measured against what is in the files, not what was recorded: the end is expected to be missing
    var length = 0.0
    if let raw = raw { length = CMTimeGetSeconds(try await AVURLAsset(url: raw).load(.duration)) }
    say(String(format: "  recovered %.3f s of %.3f s: %.1f%%, the last %.3f s are lost", length, delivered, 100 * length / delivered, delivered - length))
    try await measure(raw: raw, mixed: mixed, timeline: timeline, stop: timeline.sessionStart + length, expectedLength: delivered, cutOff: true)

default:
    say("unknown mode \(mode)")
    exit(2)
}

say("")
say("5. Resources")
say(String(format: "  wall time of this process: %.1f s; peak memory (getrusage): %@", Date().timeIntervalSince(began), peakMemory()))
say("")
if Found.problems.isEmpty {
    say("SOAK \(mode.uppercased()): no problems found")
} else {
    say("SOAK \(mode.uppercased()): \(Found.problems.count) problems")
    for problem in Found.problems { say("  - " + problem) }
}
exit(Found.problems.isEmpty ? 0 : 1)
