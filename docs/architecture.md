# Holdfast architecture

How a recording is made: the types and the threads they live on, the state
machine, how buffers become tracks, what happens at the stop, and how a file
left by a crash is recovered. Each rule says why it exists; most of them are
there because breaking it loses audio. What was measured is in
[validation.md](validation.md).

Swift and SwiftUI on macOS 15, with an AppKit status item. ScreenCaptureKit
captures the picture, system audio and the microphone; AVFoundation writes,
mixes and checks the files. Two packages: KeyboardShortcuts for global
shortcuts and SwiftLAME for MP3 output. The app makes no network requests.

## Source map

```
Holdfast/
  RecorderController.swift  RecorderController (@MainActor): the one way in for the UI, shortcuts, script
                            commands, the auto-stop and quitting. Holds the current RecordingSession, or none while
                            idle, and the launch recovery. RecorderEnvironment: what the recorder needs from the app
                            (status item, alerts, the save step) as closures, so the tests can supply their own.
  RecordingStart.swift      RecorderController.shared, start (checked on the main thread), record (stream created
                            and started off it), prepareMicCapture, and RecorderEnvironment.app.
  RecordingSession.swift    One recording from the start request until its files are final: RecordingState, the
                            capture, the writer, the monitor, pause, mute, the timer, and the only stop.
  RecordingContext.swift    The files and the settings a recording keeps until it is saved; AudioFormat's file
                            endings; RecordingError.
  CaptureSource.swift       The SCContentFilter and SCStreamConfiguration for a target, the SCStream with its three
                            outputs, and CaptureSample, which hands every buffer on to the sample queue.
  MovieWriter.swift         The AVAssetWriter and its inputs (or the files of a sound-only recording), the timeline
                            with its pauses, video frames, system audio placement, the fills, finish().
  MicConverter.swift        Microphone buffers of any format to 48 kHz stereo on a continuous timeline;
                            AudioSilence, the one source of silent audio.
  RecordingMonitor.swift    A 0.5 s timer on the sample queue: keeps every track advancing, and the watchdog.
  RecordingLogic.swift      Pure rules: Timeline (pause offsets, the timer's text), SystemAudioPlacement.
  RecordingFileStore.swift  The save folder: names, temporary markers, leftovers of an earlier run, the disk guard;
                            RecordingFiles; QmaInfo (a .qma package's info.json); RecoveryNames.
  RecordingSaver.swift      After the stop (@MainActor): close the file, mix or convert, tell the user where it is.
  RecordingMixer.swift      The audio mix in one pass, its checks (verify, verifyConversion, checkTiming), the
                            .qma package mix, and inspect() for leftovers.
  RecordingRecovery.swift   At launch: every file an earlier run left under a temporary name gets a name that says
                            what it is, and a recording that opens gets its mix.
  MicDevices.swift          MicSelection (the chosen device) and MicDevices (follows device changes mid-recording).
  StatusDisplay.swift       Pure table from the recorder's state to the status item's symbol, title and sentence.
  AppSettings.swift         Every setting, one line each, the only code that touches UserDefaults.
  ScreenContent.swift       Screens, windows and applications from ScreenCaptureKit, and the permission.
  UserNotice.swift          Alerts and notifications; reportFailure.
  HoldfastApp.swift         AppDelegate: launch, shortcuts, quitting, SIGTERM.
  Supports/                 RecLog (the recordings log), DiskSpace, SleepPreventer, the AppleScript commands and
                            their dictionary, window identifiers, the window picker's highlight.
  ViewModel/                StatusItem (menu bar item, its menu, the warning panel), the main panel, the selectors,
                            Settings, the shared recording controls, the cursor highlight and magnifier, the preview,
                            the trimmer, the .qma player.
Tests/                      The logic tests (Tools/test.sh).
Tools/                      build.sh, test.sh, release.sh, app_icon.sh, and the probes used for the measurements.
```

## A recording, end to end

```text
 panel · menu · shortcut · AppleScript · auto-stop · quit
                         │
                         ▼
 RecorderController.start ──► begin: idle → starting, a new RecordingSession
   checks: save folder and 2 GB free, display, filter, microphone
   RecordingContext (file names, settings) ─► MovieWriter ─► session.install
                         │
                         ▼   off the main thread
 record: SCStreamConfiguration, CaptureSource, prepareVideo, startCapture
                         │
                         ▼   main thread
 enterRecording: starting → recording (log, sleep assertion, disk watch)

 SCStream ── screen ──────┐
          ── system audio ┼──► sample queue ──► RecordingSession.received ──► MovieWriter.write
          ── microphone ──┘                        video: writeFrame
                                                   system audio: placeSystemAudio
                                                   microphone: MicConverter.convert
                          RecordingMonitor, every 0.5 s on the same queue:
                            fill silent tracks, repeat the last frame, watchdog

 RecordingSession.stop ──► recording → stopping: UI torn down
   await the capture's stop (5 s at most)
   on the sample queue: monitor stopped, MovieWriter.finish (pad microphone, mark inputs finished)
   stopping → finalizing: RecordingSaver.save
     finishWriting ─► RecordingMixer.mix to <name>.mixing.mp4 ─► verify ─► rename to <name>.mp4
     recording as written ─► <name> (unmixed, 2 audio tracks).mp4
   finalizing → idle: the session is dropped
```

## The state machine

`RecordingSession.state` is `starting`, `recording`, `stopping` or
`finalizing`; with no session the recorder is `idle`. Only three methods change
it, all on the main thread: `enterRecording`, `abandonStart` and `stop`. The UI
never decides from whether a stream exists. A second way into a state, or out
of one, is how a recording gets lost between states.

- **One start.** Every start, from any source, ends in
  `RecorderController.start`, which begins with `begin`. `begin` refuses unless
  the recorder is idle, with an alert while the previous recording is still
  being saved: a second recording must not start before the first one's files
  are final. Everything that belongs to one recording (its auto-stop, its
  pause and mute, its capture and writer) lives in its session, so a late
  report from one recording, a writer failure or a stream end, lands in that
  session and not in the next.
- **One failed start.** Every start that cannot go on ends in `abandonStart`,
  which removes the writer (its `cancel` deletes the empty file it created, and
  only that), the stream and the session, and the reason is shown in one
  "Failed to Record" alert unless the user cancelled. No half-started state
  survives.
- **One stop.** `RecordingSession.stop(earlyReason:)` is the only stop: the
  menu, the shortcut, the script command, the auto-stop, a writer failure, the
  disk guard, a stream that ended by itself, and quitting. It acts in
  `recording`, is remembered in `starting` and carried out by `enterRecording`,
  and is ignored otherwise, so repeated and re-entrant stops are harmless. It
  never blocks the main thread.
- **The writer before the file.** The session gets its writer (`install`)
  before any file exists, so a stop before the file was created still finds a
  writer and reports "Recording Not Saved" instead of saying nothing.
- **Everything after the stop works from the context.** `RecordingContext`
  holds the output URLs and the settings the save step needs, read once at the
  start; settings may change while a recording runs. Stream and encoder
  settings are read from `AppSettings` once, while the recording starts.

Pause and mute act only in `recording`. The status item's timer is the wall
clock since the writer's session began, frozen while paused and moved on at
resume, so the time it shows and the auto-stop agree with the file.

## The sample queue

All three stream outputs are delivered on one serial queue,
`RecorderController.queue`. The writer and the monitor belong to it: nothing
else appends, so appends are ordered without locks. The session reaches its
writer only through `queueWriter`, which traps (`dispatchPrecondition`) on any
other queue, and so do the monitor's entry points.

- The main thread enters the queue with `queue.sync`; the queue never waits for
  the main thread. Both waiting for each other would deadlock.
- The path of a delivered buffer (`received`, `microphoneWritten`,
  `systemAudioWritten`) has no trap: a wrong assumption about where
  ScreenCaptureKit delivers must not crash every recording at its first buffer.
- `MovieWriter` decides from its own state only, so the tests can run it
  without a session.
- Modal alerts during a recording are run from a run-loop block, never inside a
  main-queue block, where a modal would hold up the main queue and with it the
  stop.

## Capture

`CaptureSource` builds the content filter for a screen, an area, applications,
windows or sound only, and the stream configuration: the picture size, 48 kHz
stereo system audio, `captureMicrophone` with the chosen device (nil follows the
system default input), and always an explicit `minimumFrameInterval` (1/fps, or
1 s for sound only). A frame interval of 0, or an unthrottled stream, breaks
long recordings.

The microphone is captured by ScreenCaptureKit and nothing else. An
AVAudioEngine tap stops delivering when a call app opens the microphone with
voice processing, and does not recover; ScreenCaptureKit's microphone output
keeps delivering, on the same clock as the picture and system audio
([measured](validation.md#capture-methods-compared)).

`record()` runs off the main thread, because `startCapture` can block for
seconds, and ends on the main thread with `enterRecording`. Known limit:
nothing times the start out, so a `startCapture` that never returns leaves the
recording in `starting` until the app is force quit.

`MicDevices` installs CoreAudio listeners at launch. A change of the default
input, or the chosen device going or coming back, arms a check 0.7 s later that
points the running stream at the device that should be used now
(`updateConfiguration`) and logs it. A switch the stream refuses is undone in
the stored configuration and retried three times, 2 s apart, because AirPods
come and go.

## The writer

`MovieWriter` owns the `AVAssetWriter` and up to three inputs: video, system
audio, microphone. One is made per recording and nothing in it outlives the
recording.

**The timeline.** The writer's session starts at the first complete frame (the
first system audio buffer for sound only), and `beginSession` is the only
caller of `startSession`. Every append path checks that the session has
started, because an append before it fails the writer. Audio that arrives
before the first frame is left out, and the monitor warns when no frame has
come 5 s after the start. A pause takes the paused time out of every track
alike: the first time placed after a resume sets `timeOffset` so the
recording continues where it left off, and the offset never shrinks. `lastPTS` is the
latest end of anything on the timeline, fills included.

**Fragments.** The movie is written with `movieFragmentInterval` = 10 s, so a
file that is never closed still opens, missing up to about the last 12 s (one
fragment plus the slowest track's lag). The writer flushes a fragment only when
every track has data for it; with one unfed track the file does not open at
all. So a track is added only when it will be fed, and the monitor keeps every
track fed.

**Video.** Only complete frames are written. ScreenCaptureKit sends nothing
while the picture does not change, so the monitor has the last frame written
again once a second. A real frame that is not later than a repeated one is
moved just after it rather than dropped: the writer fails on frames out of
order, and the frame may be the only one of a slide change. The last frame is a
copy with pixels of its own once it is held for a repeat or a pause, because a
frame as delivered pins one of the stream's few surfaces.

**System audio.** AVAssetWriter plays audio buffers back to back whatever their
timestamps say. So system audio goes at `audioEndPTS`, the end of what was
actually written, not where its timestamp points: a hole of more than 0.1 s is
filled with silence first, a buffer wholly before the end is dropped, and none
is written while the silence in front of it could not be. It is never more than
0.1 s early or a buffer late.

**Failures.** Every append goes through `append(_:to:)`. A failed append, a
writer found in `.failed`, or a failed audio file write calls `fail`, which
reports once through `events.failed` into that session's
`stop(earlyReason:)`. There is one early-stop path and no silent one.

## The microphone converter

`MicConverter` turns whatever the device delivers (24 kHz mono from AirPods,
48 kHz from the built-in microphone, a different format after every device
switch) into 48 kHz stereo float on a continuous timeline. The `AVAudioConverter`
is rebuilt when the input format changes, and each change is logged.

- Within 0.1 s of the track's end a buffer goes back to back, so jitter makes
  no holes. At an anchor (the session start, after silence the monitor wrote, a
  resume, an unmute) the next buffer is placed to the sample, because an offset
  taken at an anchor would stay for the rest of the recording.
- A hole is written as silence of the same length, at most 10 s per incoming
  buffer, so a gap never shifts the audio after it.
- A buffer more than 0.1 s before the track's end is dropped, but for at most
  1 s in a row. After that the microphone's timeline is taken to have moved,
  and its buffers go at the end, late by that lag but recorded; the shift is
  given back at the next real gap. Silence the monitor wrote must never make
  the converter drop the microphone for good.
- It counts what it did (buffers in, written, dropped, failed, all-zero,
  seconds of silence, format changes, loudest peak) for the log line written
  when the recording finishes.

At the stop, `finish()` pads the microphone track to the recording's length:
a recording with a microphone always has a full-length microphone track. A
muted microphone is the same mechanism: its buffers are left out, the monitor's
fill writes the silence, and the unmute is an anchor.

## The monitor

Each session has a `RecordingMonitor`: a `.strict` dispatch timer every 0.5 s
on the sample queue, which runs whether or not buffers arrive and also in the
background. Its idea of the present is the last buffer's end plus the uptime
since it arrived (`clockAnchor`), which is the timestamp a buffer arriving now
would carry.

Each tick fills the microphone and system audio with silence up to 1 s behind
the present, once at least half a second is missing, and has the writer repeat
the last frame when none has come for a second. A track whose source goes quiet
is therefore continued after about 1.5 s, and the file keeps its fragments. A
tick that comes late is passed over, but only one in a row: buffers that piled
up may be queued behind it, yet a timer that is always late must still fill and
warn. After a resume it waits one tick for the first buffer.

It is also the watchdog. No microphone audio written for 5 s, only exact zeros
for 20 s, or no system audio for 5 s posts one notification, sets the
session's warning (the status item and `WarningPanel` show it), and writes a
log line; when audio is back, a second notification and the warning clears. A
muted microphone raises no warning. It hears through the writer's
`microphoneWritten` and `systemAudioWritten` events, so it reports what reached
the file, not what was delivered.

## Stop, save, mix

The stop sets `stopping` and tears down the UI, then awaits the capture's stop
(5 s at most; buffers that arrive meanwhile are still recorded). On the sample
queue it stops the monitor and calls `finish()`, which ends capturing, pads
the microphone, marks every input finished and, when the session never
started, removes the empty file. Nothing can append after `markAsFinished`, and
nothing is lost before it. Then `finalizing` and `RecordingSaver.save`, which
is `async` and returns on every path: one that never returned would leave the
app unable to record or quit. A sleep assertion is held from `finalizing` to
idle, because sleep during the mix would leave a temporary file.

`save` closes the file with `finishWriting` (only for a writer in `.writing`,
and the result is checked), then:

- **The mix.** A video with system audio and a microphone, with "Mix
  Microphone into the Main Track" on, is written as `<name>.recording.mp4`. With room for a second copy on the disk,
  `RecordingMixer.mix` writes `<name>.mixing.mp4` in one pass: the video
  samples are copied as they are, and an `AVAssetReaderAudioMixOutput` mixes the
  two audio tracks into one. Anything but `completed` is a failure, and a
  watchdog cancels when no sample has moved for 60 s.
- **The check.** `verify` runs before any rename: one video and one audio
  track, the same duration to within 1 s, no track more than 1 s short, and in
  up to 30 one-second windows where the microphone has sound (above -60 dBFS)
  and system audio is below a quarter of it, the mix must reach a quarter of
  the microphone's level; it fails when half or more do not.
- **The names.** On success the mix is renamed to `<name>.mp4`, then the
  recording to `<name> (unmixed, 2 audio tracks).mp4`, or deleted when "Keep
  the Unmixed Recording" is off. On any failure what the mix wrote is removed,
  the recording gets the unmixed name, and "Audio Mix Failed" says where it
  is. The recording as written is never touched until a complete, checked mix
  sits under the final name. Renames never replace a file.

A sound-only recording is renamed from its temporary name once closed, before
any MP3 conversion or package mix, because an audio file that was never closed
does not open. Every file made from a recording (a mix, an MP3, a `.qma`
export) is written under a `.mixing.` name, checked (it opens, and its length
matches to within 1 s; a package mix also has its first 30 s compared with its
sources in 10 ms steps, which catches a mix that starts late), and only then
given its name. The MP3 encoder does not report a failed write, so the check is
what finds an empty file on a full disk.

Every failure after the stop is reported with the path of the file, or, when
the file is not where it was written (its folder was moved during the
recording), with where to look for it.

## Recovery

Names carry the state. A file named `<name>.recording.<ext>` is a recording
still running or left by a crash; `<name>.mixing.<ext>` is a mix in progress or
interrupted. Neither is ever a final name, and the real extension stays last,
so a leftover is both findable and openable.

At launch, `RecordingRecovery` takes the files in the current save folder that
start with "Recording at " and carry a marker, unless another copy of the app
is running (they could be its recording):

| Found | Becomes |
| --- | --- |
| `X.mixing.mp4` | `X (incomplete mix).mp4` |
| `X.recording.mp4` that does not open | `X (damaged).mp4` |
| `X.recording.mp4`, closed but not mixed | `X.mp4` (mixed now) and `X (unmixed, 2 audio tracks).mp4` |
| `X.recording.mp4`, never closed | `X (recovered).mp4` (mixed now) and `X (recovered, unmixed, 2 audio tracks).mp4` |
| either, when the mix fails | the recording renamed only |
| a sound-only file or package | `X (recovered)` when it opens, else `X (damaged)`; never mixed |

Whether a file was closed is read from the file itself: a recording still laid
out for fragments was not (`canContainFragments`). `recover` is the whole table
and runs in the tests against real files. It deletes nothing but its own failed
mix, uses the current audio settings (those of the lost run are not known),
holds its own sleep assertion, and is not a recording state: a new recording
may start while it runs. Quitting waits for it. One "Recording Recovered"
report lists every file.

## Quitting

`applicationShouldTerminate` asks `canQuit(orReply:)`, which is true only when
nothing is recording, saving, recovering or exporting. Otherwise it stops the
recording and replies once all of that is done and any failure alert has been
dismissed, checked again together before the reply; meanwhile no new recording
can start, since the reply would end it. `applicationWillTerminate` stops the
same way for up to 30 s in case the app is terminated past that. SIGTERM is
ignored and handled by a dispatch source that calls `NSApp.terminate` from a
run-loop block, so `kill` takes the same path; inside a main-queue block the
wait for the reply would hold up the stop it waits for. `kill -9` cannot be
handled, which is what fragments and recovery are for.

## The disk guard

No start with less than 2 GB free; a running recording is stopped while it can
still be closed, at under 500 MB (checked every 5 s); no mix or MP3 when a
second copy would not fit. Free space counts what the system frees on demand,
as Finder does. The watch follows the open file by its descriptor (`F_GETPATH`),
so a moved folder keeps the guard, and it stops the recording when the file has
no name left: writing on into a deleted file would lose the rest of the meeting
silently.

## The status item

`StatusDisplay` is a pure table from the recorder's state to a symbol, a title
and a sentence, tested without a menu bar. Every state has its own symbol, not
only a colour. The `StatusItemController` is a plain `NSStatusItem` with a menu:
AppKit lays out the button, and the controller sets only its length, which is
held while a recording runs (the time only grows) so the item does not jump.
The open menu is never rebuilt: titles change in place, so a click cannot land
on an item that just replaced another. The record symbol is drawn by the item
itself, centred on the timer digits.

While a warning is up, `WarningPanel` shows it at the top right of the screen
with the pointer: on every Space, at status bar level, never key, and excluded
from screen capture (`sharingType = .none`), so it is not in the recording.

## Tests

`Tools/test.sh` compiles the pipeline sources with `Tests/*.swift` into one
executable and runs it in a few seconds, without the app, a screen or a
microphone. What it compiles uses no ScreenCaptureKit stream and no UI, which
is why the seams exist: the session sees its capture and writer through the
`RecordingCapture` and `RecordingWriter` protocols, the writer reports through
`events` closures, the app side is the closures of `RecorderEnvironment`, and
the monitor's `tick(at:)` takes its time as a parameter. The writer, converter,
mixer and recovery tests write real files with AVFoundation from synthetic
buffers and read them back; the session tests drive the state machine through
a fake capture and writer. Settings are read from the argument domain, never
written, and the log is kept in memory.

## Key constants

| Constant | Where | Value |
| --- | --- | --- |
| Movie fragment interval | `MovieWriter.fragmentInterval` | 10 s |
| Monitor tick | `RecordingMonitor.interval` | 0.5 s |
| Fill target | `RecordingMonitor.gapSeconds` | 1 s behind the present, once 0.5 s is missing |
| Frame repeat | `MovieWriter.videoStallSeconds` | after 1 s without a frame |
| Audio gap tolerance | `MovieWriter.gapTolerance`, `MicConverter` | 0.1 s |
| Microphone drop limit | `MicConverter.longestDrop` | 1 s in a row, then shift |
| Silence per buffer | `MicConverter.longestFill` | 10 s |
| Watchdog | `RecordingMonitor` | 5 s without audio, 20 s of zeros, 5 s without a first frame |
| Capture stop wait | `RecordingSession.stopCapture` | 5 s |
| Mix stall limit | `RecordingMixer.stallLimit` | 60 s |
| Mix check | `RecordingMixer.verify` | length within 1 s; 30 windows; silence below -60 dBFS |
| Disk | `DiskSpace` | start 2 GB, stop 500 MB, checked every 5 s |
| Device switch | `MicDevices` | check 0.7 s after a change; 3 retries, 2 s apart |
| Quit wait | `applicationWillTerminate` | 30 s |
| Track format | `MicConverter.sampleRate`, `CaptureSource` | 48 kHz stereo |

## Local data

Recordings go to the save folder (the Desktop until another is chosen). The
log is `~/Library/Logs/Holdfast/recordings.log`, written on its own queue and
flushed when the app quits. Settings and shortcuts are in the app's own
defaults domain.
