# Holdfast architecture

How a recording is made: the types and the threads they live on, the state
machine, how buffers become tracks, what happens at the stop, and how a file
left by a crash is recovered. Each rule says why it exists; most of them are
there because breaking it loses audio. What was measured is in
[validation.md](validation.md).

Swift and SwiftUI on macOS 15, with an AppKit status item. ScreenCaptureKit
captures the picture and the microphone, a Core Audio process tap the system
audio, with ScreenCaptureKit's system audio recorded beside it as a backup
(alone when the tap is not allowed); AVFoundation writes, mixes and checks the
files. Two packages: KeyboardShortcuts for global
shortcuts and SwiftLAME for MP3 output. The app makes no network requests.

## Source map

```
Holdfast/
  RecorderController.swift  RecorderController (@MainActor): the one way in for the UI, shortcuts, script
                            commands, the auto-stop and quitting. Holds the RecordingSession that is starting or
                            running, those that are still being saved, and the launch recovery.
                            RecorderEnvironment: what the recorder needs from the app
                            (status item, alerts, the save step) as closures, so the tests can supply their own.
  RecordingStart.swift      RecorderController.shared, start (checked on the main thread), record (stream created
                            and started off it), prepareMicCapture, and RecorderEnvironment.app.
  RecordingSession.swift    One recording from the start request until its files are final: RecordingState, the
                            capture, the writer, the monitor, pause, mute, the timer, and the only stop.
  RecordingContext.swift    The files and the settings a recording keeps until it is saved; AudioFormat's file
                            endings; RecordingError.
  CaptureSource.swift       CaptureTarget, the SCContentFilter and SCStreamConfiguration for it, and the SCStream with
                            its three outputs, which hand every buffer on as a CaptureSample, plus the recording's
                            SystemAudioSource when a tap records the system audio; MicDevice and MicrophoneChoice, the
                            microphone a recording asked for and the one it uses.
  SystemAudioTap.swift      SystemAudioTap: one Core Audio process tap in a private aggregate device clocked as
                            TapClock says (built-in output, no sub-device, default output), with its IOProc;
                            TapHardware (the Core Audio calls, CoreAudioTapHardware the real ones); SystemAudioBuffers
                            (IO buffer to CMSampleBuffer, host time) and SystemAudioConverter (to ScreenCaptureKit's
                            format).
  SystemAudioSource.swift   SystemAudioSource: a recording's tap, rebuilt the moment it stops delivering (TapRepair:
                            which construction next, how long to wait); SystemAudioSelection (tap with backup, or
                            ScreenCaptureKit alone, the notice); SystemAudioPermission.
  MovieWriter.swift         CaptureSample; the AVAssetWriter and its inputs (or the files of a sound-only recording),
                            the timeline with its pauses, video frames, the placement of system audio and of its
                            backup, the fills, track titles, the tap's spans (TapSpanLog), finish().
  MicConverter.swift        Microphone buffers of any format to 48 kHz stereo on a continuous timeline;
                            AudioSilence, the one source of silent audio.
  RecordingMonitor.swift    A 0.5 s timer on the sample queue: keeps every track advancing, and the watchdog.
  RecordingLogic.swift      Pure rules: Timeline (pause offsets, the timer's text), SystemAudioPlacement, TapSpans (where
                            the tap delivered), SystemAudioChoice (tap or backup, stretch by stretch), SystemAudioAlignment
                            (how far apart the two tracks hold the same sound) and GainCurve.
  RecordingFileStore.swift  The save folder: names, temporary markers, leftovers of an earlier run, the disk guard;
                            RecordingFiles; QmaInfo (a .qma package's info.json); RecoveryNames.
  RecordingSaver.swift      After the stop (@MainActor): close the file, mix or convert, tell the user where it is.
  RecordingMixer.swift      The audio mix in one pass (its own: TrackPCM, MixedAudio), its checks (verify,
                            verifyConversion, checkTiming), the merge of a sound-only recording's two system audio
                            files, the .qma package mix, and inspect() for leftovers.
  RecordingRecovery.swift   At launch: every file an earlier run left under a temporary name gets a name that says
                            what it is, and a recording that opens gets its mix.
  MicDevices.swift          MicSelection (the chosen device) and MicDevices (follows device changes mid-recording).
  StatusDisplay.swift       Pure table from the recorder's state to the status item's symbol, title and sentence.
  AppSettings.swift         Every setting, one line each, the only code that touches UserDefaults.
  ScreenContent.swift       Screens, windows and applications from ScreenCaptureKit, and the permission.
  UserNotice.swift          Alerts and notifications (posted only as the Notifications setting allows); reportFailure.
  HoldfastApp.swift         AppDelegate: launch, shortcuts, quitting, SIGTERM.
  Supports/                 RecLog (the recordings log), DiskSpace, SleepAssertion, the AppleScript commands and
                            their dictionary, window identifiers, the window picker's highlight.
  ViewModel/                StatusItem (menu bar item, its menu, the warning panel), the main panel, the selectors,
                            Settings, the shared recording controls, the cursor highlight and magnifier, the preview,
                            the trimmer, the .qma player.
Tests/                      The logic tests (Tools/test.sh).
Tools/                      build.sh, test.sh, release.sh, app_icon.sh; rt.sh, the real-device test helpers; the
                            probes used for the measurements and tonegen, a test signal for both audio tracks.
```

## A recording, end to end

```text
 panel · menu · shortcut · AppleScript · auto-stop · quit
                         │
                         ▼
 RecorderController.start ──► begin: → starting, a new RecordingSession (earlier ones may still be saving)
   checks: save folder and 2 GB free, display, filter, microphone
   RecordingContext (file names, settings) ─► MovieWriter ─► session.install
                         │
                         ▼   off the main thread
 record: system audio from a process tap, or the stream when it cannot be started (SystemAudioSelection),
         SCStreamConfiguration, CaptureSource, prepareVideo, startCapture
                         │
                         ▼   main thread
 enterRecording: starting → recording (log, sleep assertion, disk watch)

 SCStream ── screen ──────┐
          ── microphone ──┤
          ── system audio ┤  (the backup while the tap records; the system audio without the tap)
 process tap ─ system audio ┴► sample queue ──► RecordingSession.received ──► MovieWriter.write
                                                   video: writeFrame
                                                   system audio and its backup: placeSystemAudio, the tap's spans
                                                   microphone: MicConverter.convert
                          RecordingMonitor, every 0.5 s on the same queue:
                            fill silent tracks, repeat the last frame, watchdog

 RecordingSession.stop ──► recording → stopping: UI torn down; the session leaves the recorder's place for the
                           running recording, so the next one can start at once
   await the capture's stop (5 s at most): the tap first, then the stream
   the monitor is stopped on the sample queue as the capture's stop returns, whatever the main thread is doing
   on the sample queue: MovieWriter.finish (pad microphone, mark inputs finished)
   stopping → finalizing: RecordingSaver.save
     finishWriting ─► RecordingMixer.mix to <name>.mixing.mp4 (system audio: the tap or its backup,
                      by <name>.tap-alive.txt) ─► verify ─► rename to <name>.mp4
     recording as written ─► <name> (unmixed, 3 audio tracks).mp4; <name>.tap-alive.txt removed
   finalizing → idle: the session is dropped; the recorder is idle when none is left
```

## The state machine

`RecordingSession.state` is `starting`, `recording`, `stopping` or
`finalizing`; with no session the recorder is `idle`. The recorder holds at
most one session that is starting or running (`session`) and any number that
were stopped and are still being saved (`finishing`). Only three methods change
it, all on the main thread: `enterRecording`, `abandonStart` and `stop`. No
transition is decided from whether a stream exists: the UI reads that only to
show or refuse a panel, a shortcut or the cursor highlight. A second way into a
state, or out of one, is how a recording gets lost between states.

- **One start.** Every start, from any source, ends in
  `RecorderController.start`, which begins with `begin`. `begin` refuses only
  while a recording is starting or running, or the app waits to quit.
- **A start never waits for a save.** A session that is stopped moves to
  `finishing` in the same call and goes on closing and mixing by itself, while
  the next start is accepted at once: a meeting that begins while the last
  one's 47-minute mix runs must be recorded from its first second. Nothing is
  shared between sessions but the sample queue, on which each reaches only its
  own writer and monitor: the capture, the tap, the writer, the monitor, the
  disk watch, the two sleep assertions (display while recording, system from
  the stop until its files are final) and the file names all belong to one
  session. A new recording gets no name a session that is not final holds
  (`RecorderController.basesInUse` → `RecordingFileStore.newBase(reserved:)`),
  so each mix reads and renames only its own files. Stop, pause and mute reach
  the running session only. Everything that belongs to one recording (its
  auto-stop, its pause and mute, its capture and writer) lives in its session,
  so a late report from one recording, a writer failure or a stream end, lands
  in that session and not in the next; a failure reported while another
  recording runs says which recording it is about
  (`RecorderController.failureMessage`).
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

All three stream outputs, and the process tap's buffers, are delivered on one
serial queue, `RecorderController.queue`. The writer and the monitor belong to it: nothing
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
  stop. That goes for a start as well, since a recording stopped a moment
  before may still be closing: "Microphone Not Available" is a run-loop block,
  and the start goes on from its answer. And the monitor of a recording is
  stopped on the sample queue the moment its capture has stopped, so whatever
  holds the main thread before the writer is taken cannot make it fill the
  tracks with silence or warn about sources that have gone.

## Capture

`CaptureSource` builds the content filter for a screen, an area, applications,
windows or sound only, and the stream configuration: the picture size, 48 kHz
stereo system audio whenever the recording has system audio (as the tap's
backup, or alone), Holdfast's own sound left out like the tap leaves it out,
`captureMicrophone` with the chosen device (nil follows the system default
input), and always an explicit `minimumFrameInterval` (1/fps, or 1 s for sound
only). A frame interval of 0, or an unthrottled stream, breaks
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

### System audio

ScreenCaptureKit's system audio leaves out what the system process
`avconferenced` plays: FaceTime calls and phone calls taken on the Mac. A
70-minute FaceTime call recorded with it held a notification tone and a
screenshot sound at full level and none of the call. So the system audio comes
from a Core Audio process tap (`SystemAudioSelection.choose`), and
ScreenCaptureKit's system audio is recorded beside it, for the whole recording,
on a track of its own: the backup. On the owner's Mac ScreenCaptureKit's audio
was checked to have Zoom, Meet and calls in a browser (2026-10-04), and the tap
to have FaceTime (2026-10-05). After the stop the mix takes, stretch by
stretch, the tap's audio where the tap delivered, else the backup's, never
both, with the tap's audio moved onto the backup's timeline. Without the permission the stream's system audio is the
system audio, alone. A sound-only recording uses the same sources. The tap is
global whatever is recorded: a window or application recording gets every
app's sound, because call audio comes from `avconferenced`, not from the call's
app, and a tap of chosen processes made at the start would miss one that
begins to play later. (The backup of a window or application recording has
only that app's sound, as ScreenCaptureKit filters it.)

Why the backup and the self-repair: a 47-minute Zoom meeting in a browser tab,
with AirPods, lost the other side entirely. The tap's aggregate device was
clocked by the AirPods (24 kHz, call mode); its IOProc delivered nothing for
the whole meeting (the first attempt stopped after about 27 s), nothing in Core
Audio reported it, no rebuild came, and the user only got a warning they could
do nothing about. Holdfast must capture the system audio by itself, every time.

- **The tap.** `SystemAudioTap` creates a private global stereo tap of every
  process but Holdfast's own (its process object from
  `kAudioHardwarePropertyTranslatePIDToProcessObject`), left audible
  (`muteBehavior = .unmuted`), and a private aggregate device with the tap as
  its sub-tap, drift compensation on. What clocks that device is a `TapClock`:
  the Mac's built-in output (its speakers, which are there and alive with the
  lid closed too), else no sub-device at all, and the default output only as a
  last resort (`TapClock.order`; the default output is not tried as such when
  it is the built-in one). Measured on the owner's Mac with
  `Tools/tapexp.swift`, run inside a bundle with Holdfast's identity and
  permission: all three constructions delivered about 94 IOProc calls a second
  of 1024 frames at 48 kHz and heard a quiet sound played to the AirPods at the
  same level (-47.7 dB), also while another process held the AirPods'
  microphone with voice processing. The tap follows the processes, not the
  device that clocks it, and the default output is the device that changes its
  mode under a call. (A process without the permission, such as one started
  from a terminal, gets a tap that runs and delivers only zeros, which is what
  had once been taken for "a tap alone delivers zeros".) The device runs from
  `AudioDeviceStart` on and delivers zeros while nothing plays, so the track
  is continuous from the start; `kAudioAggregateDeviceTapAutoStartKey` is left
  out, since it makes the start wait for the first sound. The IOProc uses only
  the tap's stream (`kAudioDevicePropertyIOProcStreamUsage`: the last input
  stream on, a clock device's own input and output streams off; a failure to
  set it is logged), so a clock device gives only the clock, and the
  microphone of a headset or AirPods is not opened, which would put them in
  their narrowband call mode. The IOProc copies the tap's buffers (the last
  ones of the input) into a `CMSampleBuffer` in the tap's format
  (`kAudioTapPropertyFormat`, interleaved or not) at the aggregate device's
  rate. Its time is the host time the IOProc reads as it is called
  (`mach_absolute_time`, on the host-time clock ScreenCaptureKit stamps its
  buffers with): the buffer ends then. The time stamps Core Audio hands the
  IOProc are never read. They are the aggregate device's, and around call
  events they were wrong on the owner's Mac while the audio itself kept
  coming: 12 s in the future as a FaceTime call connected, 1100 s as it ended,
  4.77 s as another app switched voice processing on with AirPods in call
  mode. The host clock cannot jump, and read on the IO thread it does not move
  with how long the buffer then waits for the sample queue. The IOProc does
  nothing else on the real-time thread.
- **The same path as the stream.** `SystemAudioSource` queues each buffer on
  the sample queue, where `SystemAudioConverter` turns it into
  ScreenCaptureKit's system audio format (48 kHz stereo float, one buffer per
  channel; a buffer already in it goes on unchanged, others are converted and
  resampled onto a continuous timeline), and hands it as an `.audio`
  `CaptureSample` to the same `onSample` as the stream's buffers, with the
  host time its IOProc read as its arrival time, which is where it ends. The
  stream's own system audio arrives as `.backupAudio`.
- **Self-repair.** A tap whose IOProc has handed on nothing for 1 s
  (`stallSeconds`, checked every 0.25 s on the source's own queue) is dead: it
  is torn down and built again at once, and logged. A change of the aggregate
  device's or its clock device's rate, or the clock device going away, counts
  the same (`SystemAudioTap`'s listeners close its gate at once, since its
  buffers would carry the old rate). A construction that failed twice in a
  row, by a build that throws or a tap that dies, gives way to the next in the
  order, and after the last the first comes again (`TapRepair`); the first
  attempt after a failure is at once, then the wait doubles from 0.5 s to at
  most 2 s, for as long as the recording runs: building a tap is cheap, and
  while it is dead a FaceTime call is not recorded. A tap that has delivered
  for 10 s starts the count anew. A tap that cannot be built at the start does
  not stop the start: it is tried in the background while the backup records.
  Nobody is asked to do anything; the log has each failure (the first ones of
  a run, then one in thirty) and the counts at the stop. Only a tap that has
  put nothing into its track for 15 s (`RecordingMonitor.tapLostSeconds`, by
  when each construction has failed twice) is shown, see the monitor below.
  The listeners (`CoreAudioTapHardware.watch`) are registered as a C function
  with a token as client data, never as a block: Core Audio finds the listener
  to remove by comparing, a Swift closure passed as a block is a new block
  object at every call, and so the removal of a block listener matched
  nothing and returned no error (checked on the owner's Mac with a
  property-only probe). Every tap ever built would have left two listeners
  on the built-in output for as long as the app ran. A token that has been
  removed does nothing, so a notification already on its way ends there, and
  a removal that fails is logged. Which device is the default output no longer matters, so nothing
  follows it: the listeners on the default output and on the device list are
  gone. They were there only to move the tap to the new default output, and the
  device list one needed its own guard against rebuilding whenever the tap's
  own aggregate device came or went; a real failure now shows as a tap that
  stops delivering. A rebuild stops handing on the old tap's buffers before it
  tears it down, and on the sample queue a buffer of an earlier tap than one
  already handed on is dropped, so nothing of the old tap follows the new one;
  the monitor's silence fill covers the moment between, and the mix takes the
  backup there.
- **The backup and the tap's spans.** The writer gives the backup its own
  track (or file), placed and filled exactly like the system audio, so the two
  share one timeline. While it writes, it records where real buffers of the tap
  went into the tap's track (`TapSpanLog`: a line at each start and end, in
  seconds of the file) in `<name>.tap-alive.txt` next to the recording, so a
  recording that is killed has them too; silence written into the tap's track
  ends a span. The file is removed once the final files are written (at the
  end of the save, and by recovery).
- **The choice** (`SystemAudioChoice`). The tap is the source for every
  stretch in which its spans say it delivered, whatever it delivered: a tap
  that is alive is not judged by its sound. The backup is the source where the
  tap was not alive (and past the end of the tap's track in a recording that
  was never closed), and in one case where it was: 2 s or more of digital
  silence in the tap's track (exact zeros as recorded, below -100 dBFS once
  through the codec) while the backup has signal (above -70 dBFS) more than
  0.3 s inside that silence. That is a tap that runs and delivers nothing, as
  a process without the permission gets; the 0.3 s keep the end of a sound the
  two tracks hold a little apart from counting as the backup's signal. Silence
  in both switches nothing. Less than 0.25 s without the tap at the very start
  or end of the recording stays the tap's, since the two tracks never begin and
  end on the same sample. So a recording whose tap was alive throughout has
  nothing from the backup, FaceTime, which only the tap hears, is the tap's,
  and nothing is heard twice. (Until 2026-10-07 every half second went to
  whichever source had sound in it. A 45 s recording on the owner's Mac whose
  tap was alive and right throughout came out with 11.8 s from the backup in
  four stretches, and each switch doubled or cut a sound, the two tracks being
  52 ms apart.) A switch is a linear crossfade of 5 ms on the side of the edge
  where the tap still has its sound: before the edge where it stopped, after
  the edge where it came back. It does not wait for a quiet moment: at the edge
  of an outage only one source has the sound, and a call may have no quiet
  moment for seconds. Without the spans (a file of an earlier version) the tap
  counts as alive for the whole of its track.
- **The alignment** (`SystemAudioAlignment`). The two tracks do not hold the
  same sound at the same time. Measured on the owner's Mac on 2026-10-07
  (AirPods in 24 kHz call mode, voice processing switched on mid-recording) by
  cross-correlation at five points: the tap's audio is a constant 52.4 ms later
  in its track than the backup's. ScreenCaptureKit stamps its audio to go with
  its pictures, so the backup's timeline is the one in step with the video; a
  tap buffer is stamped as ending when its IOProc is called, which leaves out
  what the device held it for. Before the mix the offset is measured from the
  sound: up to 16 windows of 1 s spread over the recording, each where both
  tracks are above -60 dBFS, the backup's window against the tap's track 0.3 s
  either way by normalised cross-correlation of the samples. A window counts
  when its best match is at least 0.5, lies within 250 ms, and has no rival
  (another peak at 0.9 of it or more, as a steady tone has one every period).
  At least three windows must count, and two in three of them lie within 5 ms
  of their median (the tap's track follows its device's clock within 10 ms,
  see the drift); the offset is the median of those, a whole number of
  samples. The mix then takes the tap's track that much earlier (and the
  stretches of the choice with it), so its system audio is in step with the
  picture and a switch between the sources joins the same sound to itself.
  When it cannot be measured (no sound in both, as in a recording of a
  FaceTime call alone, which the backup does not hear; only steady tones; no
  agreement) the tap's audio is used as it was stamped. The recording as
  written keeps both tracks as they were recorded. The offset is not taken out
  where the buffers are stamped: the figures the aggregate device gives for it
  (its input latency and safety offset, the tap stream's latency, its IO
  buffer) can only be read from a tap that exists, and those of the built-in
  output that clocks it (70 + 74 + 690 frames) with the tap's IO buffer of
  1024 frames come to 1858 of the 2515 frames measured. They are logged at
  every build ("System audio tap: its device reports …") to be held against
  what the mix measures.
- **Warnings.** System audio is reported missing only when neither the tap nor
  the backup has delivered for the monitor's 5 s; a tap that stops while the
  backup goes on is logged ("the process tap has delivered nothing for 5 s; the
  backup (screen capture) records the system audio meanwhile", and when it is
  back), and shown, as a notice, only when it has lasted 15 s. Sound-only
  recordings are watched the same way.
- **Teardown.** The device is stopped, then the IOProc, the aggregate device
  and the tap are destroyed, in that order, once: at the stop (the tap before
  the stream, both before the writer's inputs are finished), when a start
  fails or the stream ends (`releaseStream`), at quit
  (`SystemAudioSource.stopAll`) and in `deinit`. Tap and aggregate device are
  private to the process, and Core Audio destroys them with it, so a crash
  leaves neither behind.
- **Permission.** The tap needs "System Audio Recording Only"
  (`kTCCServiceAudioCapture`; `NSAudioCaptureUsageDescription` in `Info.plist`).
  macOS has no public call that reads it without asking; `SystemAudioPermission`
  uses the TCC framework's own `TCCAccessPreflight` and `TCCAccessRequest` when
  they are there. `start` asks before anything starts when it is not
  determined, like the microphone, and reads it once more to decide the route
  before the writer is made (`SystemAudioSelection.usesTap`), since the backup
  needs its track. Denied or unanswered, the recording uses ScreenCaptureKit's
  audio alone and logs why; when the state cannot be read the tap is tried (a
  tap without the permission delivers zeros, and the choice then takes the
  backup). "Call Audio Not Included" is posted once while the app runs
  (`SystemAudioSelection.notifies`, `callAudioNotice`), from `enterRecording`,
  for a recording that started without the tap. A tap that cannot run at
  all (its source throws, which takes a missing format converter) makes the
  recording show "Call audio is not being recorded" for as long as it runs
  (`Health.notice`); a tap that cannot be built yet is repaired, and reported
  the same way only once it has been dead for 15 s, until it delivers again.
- **Not yet verified in a real recording.** That the tap hears FaceTime was
  verified on 2026-10-05; a recording with this version during a FaceTime
  call, and during a browser call whose AirPods switch to 24 kHz, has not been
  made.

`MicDevices` installs CoreAudio listeners at launch. A change of the default
input, or the chosen device going or coming back, arms a check 0.7 s later that
points the running stream at the device that should be used now
(`updateConfiguration`) and logs it. A switch the stream refuses is undone in
the stored configuration and retried three times, 2 s apart, because AirPods
come and go.

## The writer

`MovieWriter` owns the `AVAssetWriter` and up to four inputs: video, system
audio, its backup (with the tap), microphone, added in that order and titled
("System audio (tap)" or "System audio", "System audio (backup)",
"Microphone"), which is how the mix and players tell them apart. One is made
per recording and nothing in it outlives the recording.

**The timeline.** The writer's session starts at the first complete frame (the
first system audio buffer for sound only), and `beginSession` is the only
caller of `startSession`. Every append path checks that the session has
started, because an append before it fails the writer. Audio that arrives
before the first frame is left out, and the monitor warns when no frame has
come 5 s after the start. A pause takes the paused time out of every track
alike: the first time placed after a resume sets `timeOffset` so the
recording continues where it left off, and the offset never shrinks. `lastPTS`
is the latest end of anything on the timeline, fills included.

**Placed by arrival, never past the present.** A timestamp comes from a
device, and around call events devices have stamped buffers wrongly while the
audio kept coming. In a 20-minute FaceTime call the process tap handed on one
buffer, as the call ended, stamped about 1100 s in the future. The writer
believed it: `lastPTS` jumped to that time and stayed there (it only ever
grows), the system audio track was filled with silence towards it until its
input stopped taking more (16 s), every real system audio buffer after it lay
before that end and was dropped, and the stop padded the microphone to
`lastPTS`: 38 minutes of audio for 20 of picture. On 2026-10-06 the other side
of a 47-minute meeting was lost: the working diagnosis is that the tap's
device stamped its buffers some seconds in the past, each then lay before the
end of its track and was left out, while the IOProc kept running and nothing
was rebuilt. So every buffer carries the host time at which it arrived
(`CaptureSource` reads it for the stream's buffers, the tap's IOProc for its
own), the writer reads the present from `presentClock` (the host clock; the
tests and the simulation give their own), and:
- The process tap's buffers have no other time than their arrival (see "System
  audio" below).
- ScreenCaptureKit's system audio keeps its own timestamps, which are smooth
  where arrivals come in bursts, while they agree with the arrival
  (`StreamStamps`). A buffer stamped more than 1 s after its arrival ends when
  it arrived instead, and the difference is kept for the buffers after it, so
  they stay as evenly spaced as the stream stamped them. Buffers stamped more
  than 1 s before their arrival, or before the end of what their track holds,
  are one of two things, which `LateRun` tells apart by their age (arrival
  minus the end of their audio), as it does for the microphone: a backlog,
  handed over faster than real time with the times its audio was captured at,
  whose age falls, or a clock that lags, whose buffers keep arriving at
  real-time pace with a steady age. Until that is clear (1.5 s of arrivals),
  and for a backlog all along, a buffer that lies before the end of its track
  is left out, because silence was written in its place while it was held up,
  and one that does not is written at its own time. The buffers of a lagging
  clock end when they arrived from then on, so no stream is left out for
  good. The first of a run, a backlog and the return of the stream's own time
  are logged, the totals at the stop.
- A complete frame is never left out for its timestamp: stamped more than 1 s
  before or after its arrival it is written at its arrival time, with one log
  line per run of such frames.
- A microphone buffer stamped more than 1 s after its arrival, or more than
  300 s before it, is given its arrival time less its length. A microphone
  backlog is left to the converter, which drops it where silence was filled,
  while given its arrival time it would put stale audio at the present,
  chopped up.
- A buffer without a picture and without a known arrival that ends more than
  1 s after the present is left out, logged once and counted at the stop.
- `lastPTS` takes no end more than 1 s after the present, and the monitor's
  fills and frame repeats are cut off there too.
- The stop pads the microphone only to the end of the video's last frame
  (`videoEnd`, repeated frames included), or for a sound-only recording to
  `lastPTS` but not after the present (`stopEnd`).

**Fragments.** The movie is written with `movieFragmentInterval` = 10 s, so a
file that is never closed still opens, missing up to about the last 12 s (one
fragment plus the slowest track's lag). The writer flushes a fragment only when
every track has data for it; with one unfed track the file does not open at
all. So a track is added only when it will be fed, and the monitor keeps every
track fed.

**Video.** Only complete frames are written. ScreenCaptureKit sends nothing
while the picture does not change, so the monitor has the last frame written
again once a second. A frame whose time is not later than that of the frame
before it (a repeated one, or one written at its arrival time) is moved just
after it, half a frame interval and at most 10 ms later, never dropped: the
writer fails on frames out of order, and the frame may be the only one of a
slide change. Only a writer input that is not ready loses a frame. The last frame is a
copy with pixels of its own once it is held for a repeat or a pause, because a
frame as delivered pins one of the stream's few surfaces.

**System audio.** AVAssetWriter plays audio buffers back to back whatever their
timestamps say. So system audio goes at `audioEndPTS`, the end of what was
actually written, not where a timestamp points, and a hole of more than 0.1 s
is filled with silence first; no buffer is written while the silence in front
of it could not be. The two sources differ in what may leave a buffer out:
- The tap's buffers go back to back by their sample count
  (`SystemAudioPlacement.placeArrived`). The host time their IOProc read is
  used for two things only: to see a real hole (the tap delivered nothing, or
  the writer did not take a buffer), and to see that the track already holds
  more than 0.1 s beyond the buffer's end, in which case it is not written a
  second time. That is the only tap buffer left out for its time, and no
  device clock can cause it: the host clock only moves forward at the pace of
  real time, and the track's end is a count of samples written. It happens
  when the monitor wrote silence over the buffer's time before the buffer
  reached the writer. It is logged the first time and counted at the stop.
  The count of samples follows the clock of the device that clocks the tap,
  which is not the host clock: a device 50 parts in a million slow delivers
  0.1 s too little in 33 minutes, which left alone would become a hole of
  0.1 s of silence in the middle of speech (and a stretch the mix takes from
  the backup), and a fast one a buffer left out again and again. `TapDrift`
  takes that up before it gets there: the difference between where a buffer
  arrived and where it goes is smoothed over 2 s, and once it is more than
  10 ms one frame is added to, or taken out of, a buffer every 0.1 s of audio
  (`MovieWriter.stretched`, where the samples around it differ least) until
  less than 2 ms is left. No silence is written and the tap's span is not
  broken. The first runs are logged, and the stop logs the frames and what
  they say about the device's rate. For this the tap's buffer is taken to end
  at its arrival also when it was converted from another format, whose
  buffers the converter puts on a timeline counted from their samples.
- The stream's buffers, on their own timestamps, are left out when they lie
  wholly before the end and written whole when they overlap it, late by less
  than one buffer (`SystemAudioPlacement.place`); what `StreamStamps` decides
  comes before that.
The tap's spans (`TapSpanLog`) are made from the buffers written to its track
and end where silence is written into it, so they say where the track holds
the tap's audio, not when its IOProc was called. The backup is filled the same
way on its own track. In a sound-only recording, whose files have no
timestamps, either source's first buffer starts the recording, and the file of
the source that began later starts with silence up to it.

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
- A buffer more than 0.1 s before the track's end is late, and the writer
  tells the converter when each buffer arrived (host clock, the clock of the
  timestamps). Late buffers are one of two things. A backlog: the microphone
  was held up (a call app taking it) and then hands over what piled up, with
  the times it was captured at, faster than real time, so each buffer's age
  (arrival minus the end of its audio) shrinks. Its time was already filled
  with silence, so it is dropped and the buffers after it sit at their own
  time: no offset. Or a microphone clock that lags: the buffers keep arriving
  at real-time pace, all behind, their age steady. Late buffers are dropped
  while their age varies by more than 0.25 s over the last 2 s of arrivals,
  falls by more than 0.02 s a second over the whole run (the least-squares
  slope: a backlog drained at 1.1 times real time falls 0.1 s a second, but
  only 0.2 s within 2 s), or their audio adds up to less than the time the
  first of them lay behind; only then is the timeline taken to have moved, and
  the buffers go at the end, late by that lag but recorded; the shift is given
  back at the next real gap.
  Silence the monitor wrote must never make the converter drop the microphone
  for good. Without arrival times the shift comes after 1 s of late audio.
  The log says which it was: a "Microphone backlog" line with what was dropped
  (from a quarter of a second up), or the shift with its lag.
- The owner's first FaceTime call came out with the microphone 11 s late for
  the whole call, and that was neither of the two. As the call connected
  (13.7 s in), a buffer stamped about 12 s in the future reached the writer:
  the video has one 12.06 s hole there (a frame at 13.690 s, the next at
  25.755 s), system audio is digital silence from 13.5 to 26.5 s, and the
  microphone from 14 to 25.5 s. The writer of the day believed it, so the
  monitor's present ran 12 s ahead: it filled the microphone and system audio
  that far, the frames and tap buffers on time were dropped as lying before
  what was written, and the microphone's buffers, arriving on time at real-time
  pace (49 dropped in 1 s), lay 11 s behind the filled track and were shifted
  by the 1-s rule of the day. The log's "Microphone buffers are 11.06 s behind"
  was that shift. What prevents it is "Never past the present" (nothing ends
  more than 1 s after the present, fills included), not the backlog rule; the
  test "a frame and a tap buffer stamped 12 s ahead as a call connects" runs
  that pattern through the writer and the monitor.
- It counts what it did (buffers in, written, dropped, failed, all-zero,
  seconds of silence, format changes, loudest peak) for the log line written
  when the recording finishes.

At the stop, `finish()` pads the microphone track to the end of the video
(`stopEnd`, see "Never past the present"): a recording with a microphone
always has a full-length microphone track, and never a longer one. A
muted microphone is the same mechanism: its buffers are left out, the monitor's
fill writes the silence, and the unmute is an anchor.

## The monitor

Each session has a `RecordingMonitor`: a `.strict` dispatch timer every 0.5 s
on the sample queue, which runs whether or not buffers arrive and also in the
background. Its idea of the present is the host time at which the last buffer
arrived plus the uptime since then (`clockAnchor`; a buffer that waited for
the sample queue counts from when it arrived, and one whose arrival is not
known from its end). No timestamp of a device moves it, ahead or back.

Each tick fills the microphone, the system audio and its backup with silence up
to 1 s behind the present, once at least half a second is missing, and has the writer repeat
the last frame when none has come for a second. A track whose source goes quiet
is therefore continued after about 1.5 s, and the file keeps its fragments. A
tick that comes late is passed over, but only one in a row: buffers that piled
up may be queued behind it, yet a timer that is always late must still fill and
warn. After a resume it waits one tick for the first buffer.

It is also the watchdog. No microphone audio written for 5 s, only exact zeros
for 20 s, or no system audio for 5 s from either of its sources (no first frame
5 s after the start) sets
the session's warning, which the status item shows, and writes a log line.
A tap that is silent while its backup records is no such problem: it is logged
after 5 s, and after 15 s (`tapLostSeconds`) the recording shows "Call audio is
not being recorded" as its notice (`Display.notice` → `Health.notice`, shown
where no warning is) until the tap's audio is back, because the backup does
not hear a FaceTime or phone call and nothing else would say that one is being
lost. It is not notified and is not the system audio warning.
A problem is over only once its source has delivered steadily for
`steadySeconds` (5 s): audio written up to within `steadyGap` (2 s) of the
present on every tick, and for the microphone audio that is not digital
silence, so a microphone that comes back with zeros is not back. Until then
it stays one problem, counted from where the audio stopped when it began,
whatever came back in between: a source that drops out again and again for
less than 15 s at a time, AirPods on a weak link or a tap rebuilt over and
over, adds up to one problem that is notified. Only a problem that has lasted
`announceSeconds` (15 s, counted from the last audio written, or from the
start) while its source is not steady is notified, once (saying that the
audio keeps dropping out when it came back in between), and put in
`Health.onScreen`, which `WarningPanel` shows; once it is over the warning
clears, and the "back" notification is posted only for a problem that was
notified (the log has both either way). A call app that takes the microphone
for a few seconds is therefore an orange item and nothing more. A muted
microphone raises no warning. It hears through the writer's
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
app unable to quit. Each session holds a sleep assertion of its own from its
stop until its files are final, because sleep during the mix would leave a
temporary file; the Mac stays awake until the last one is.

`save` closes the file with `finishWriting` (only for a writer in `.writing`,
and the result is checked), then:

- **The mix.** A video with system audio and a microphone, with "Mix
  Microphone into the Main Track" on, and every video with the tap, is written
  as `<name>.recording.mp4`. With room for a second copy on the disk,
  `RecordingMixer.mix` writes `<name>.mixing.mp4` in one pass: the video
  samples are copied as they are, and the audio tracks are decoded and added
  up sample by sample (`TrackPCM`, `MixedAudio`), each placed at its own time;
  with the tap, the tap's and the backup's tracks by the gain the choice gives
  them (`SystemAudioChoice.tapGain`, the backup one minus it), from the tap's
  spans in `<name>.tap-alive.txt`, the tap's track moved by what
  `SystemAudioAlignment` measured (`TrackPCM`'s `earlier`). Its own mix rather than
  `AVAssetReaderAudioMixOutput` with an `AVAudioMix`: the audio mix's volume
  ramps came out about 25 ms long and late (a 5 ms ramp at 1.5 s crossed half
  way at 1.5125 s), and a switch must land where the tap stopped. With "Mix
  Microphone into the Main Track" off, the system audio is still made one
  track and the microphone is copied as a second, titled "System audio" and
  "Microphone". The log has the measured offset ("System audio alignment: the
  tap's audio is 52.4 ms later than the backup's (11 of 12 windows agree) and
  is moved onto the backup's timeline", or "not measured (…): the tap's audio
  is used as it was stamped") and where the system audio came from ("System
  audio in the mix: … s from the process tap, … s from the backup in N
  stretches").
  Anything but `completed` is a failure, and a watchdog cancels when no sample
  has moved for 60 s.
- **The check.** `verify` runs before any rename: one video and one audio
  track, audio no more than 2 s longer or shorter than the video (for a
  leftover that was never closed, up to 12 s shorter: its tracks end where
  their last fragments did), the same duration to within 1 s, no track more
  than 1 s short, and in
  up to 30 one-second windows where the microphone has sound (above -60 dBFS)
  and system audio is below a quarter of it, the mix must reach a quarter of
  the microphone's level, and where the system audio has sound from one source
  (as the mix chose it) and the microphone is below a quarter of it, the mix
  must have it at half to one and a half times its level: neither missing, as
  a dead tap would leave it, nor twice; it fails when half or more of either
  kind do not.
- **The names.** On success the mix is renamed to `<name>.mp4`, then the
  recording to `<name> (unmixed, N audio tracks).mp4` (3 with the tap, its
  backup and the microphone), or deleted when "Keep the Unmixed Recording" is
  off. On any failure what the mix wrote is removed,
  the recording gets the unmixed name, and "Audio Mix Failed" says where it
  is. The recording as written is never touched until a complete, checked mix
  sits under the final name. Renames never replace a file.

A sound-only recording is renamed from its temporary name once closed, before
any MP3 conversion or package mix, because an audio file that was never closed
does not open. With the tap it has two system audio files, the tap's
(`sys.<ext>` in the package, or the recording's file) and the backup's
(`sys-backup.<ext>`, or `<name> (system audio backup).<ext>`);
`RecordingMixer.mergeSystemAudio` makes one of them by the same choice and
alignment, written
under a staging name, checked for its length, and only then given the tap's
file's name; the two sources are kept beside it with "Keep the Unmixed
Recording" (`sys-tap.<ext>`, `<name> (system audio tap).<ext>`) and deleted
otherwise. A merge that fails leaves the files as they are and is reported
("System Audio Not Merged"). Every file made from a recording (a mix, an MP3, a `.qma`
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
| `X.recording.mp4`, closed but not mixed | `X.mp4` (mixed now) and `X (unmixed, N audio tracks).mp4` |
| `X.recording.mp4`, never closed | `X (recovered).mp4` (mixed now) and `X (recovered, unmixed, N audio tracks).mp4` |
| either, when the mix fails | the recording renamed only |
| a sound-only file or package | `X (recovered)` when it opens, else `X (damaged)`; never mixed |

Whether a file was closed is read from the file itself: a recording still laid
out for fragments was not (`canContainFragments`). A recording made with the tap
is mixed by the spans it left in `X.tap-alive.txt` (a span still open lasts to
the end of the file; past the end of the tap's last fragment the backup's
audio is taken), and that file is removed once the
recording has its names. `recover` is the whole table
and runs in the tests against real files. It deletes nothing but its own failed
mix, uses the current audio settings (those of the lost run are not known),
holds its own sleep assertion, and is not a recording state: a new recording
may start while it runs. Quitting waits for it. One "Recording Recovered"
report lists every file.

## Quitting

`applicationShouldTerminate` asks `canQuit(orReply:)`, which is true only when
nothing is recording, saving, recovering or exporting. Otherwise it stops the
recording and replies once every session's files are final, the rest of that is done and any failure alert has been
dismissed, checked again together before the reply; meanwhile no new recording
can start, since the reply would end it. `applicationWillTerminate` stops the
same way for up to 30 s in case the app is terminated past that. SIGTERM is
ignored and handled by a dispatch source that calls `NSApp.terminate` from a
run-loop block, so `kill` takes the same path; inside a main-queue block the
wait for the reply would hold up the stop it waits for. A process tap that is
still running after that wait is torn down last (`SystemAudioSource.stopAll`).
`kill -9` cannot be handled, which is what fragments and recovery are for; the
tap and its aggregate device go with the process.

## The disk guard

No start with less than 2 GB free; a running recording is stopped while it can
still be closed, at under 500 MB (checked every 5 s); no mix or MP3 when a
second copy would not fit with 500 MB to spare, or with 2 GB to spare while
another recording is starting or running (`DiskSpace.copyReserve`; the
recorder tells `DiskSpace` when it has one, since the copies are checked off
the main thread): that recording passed its start check before the mix of the
one before it took its space, and would otherwise be stopped by it. The
recording is then kept unmixed and the report says why. The other order is
not guarded: a recording started while a mix is already being written is
checked against the space free at that moment. Free space counts what the system frees on demand,
as Finder does. The watch follows the open file by its descriptor (`F_GETPATH`),
so a moved folder keeps the guard, and it stops the recording when the file has
no name left: writing on into a deleted file would lose the rest of the meeting
silently.

## The status item

Holdfast is a menu bar app (`LSUIElement`): the item is always there by
default, the Dock icon only when "Show in the Dock" asks for it, and the main
panel opens at launch only with "Open the Panel When Holdfast Opens", or when
there is neither an item nor an icon (`AppSettings.opensPanelAtLaunch`).
`AppSettings.migrate` made installations from before this a menu bar app once
(`settingsVersion` 1). Opening the app again while it runs (Finder,
Spotlight, the Dock icon) shows the panel, or brings forward the window that is
open. As the app is usually not active, everything that opens a window or an
alert activates it first (`createNewWindow`, `openTrimmer`, `openSettings`,
`NSAlert.runInFront`); the floating panels and the preview are shown without
it.

`StatusDisplay` is a pure table from the recorder's state to a symbol, a title
and a sentence, tested without a menu bar. Every state has its own symbol, not
only a colour. The `StatusItemController` is a plain `NSStatusItem` with a menu:
AppKit lays out the button, and the controller sets only its length, which is
held while a recording runs (the time only grows) so the item does not jump.
The open menu is never rebuilt: titles change in place, so a click cannot land
on an item that just replaced another. The record symbol is drawn by the item
itself, on the pixel grid; every symbol beside a title is centred on the
middle of the timer digits.

While a warning that has lasted 15 s is up (`StatusDisplay.banner`, from
`Health.onScreen`, else the recording's notice), `WarningPanel` shows it at the
top right of the screen with the pointer: on every Space, at status bar level,
never key, and excluded from screen capture (`sharingType = .none`), so it is
not in the recording.

## Tests

`Tools/test.sh` compiles the pipeline sources with `Tests/*.swift` into one
executable and runs it in about two minutes, without the app, a screen or a
microphone. What it compiles uses no ScreenCaptureKit stream and no UI, which
is why the seams exist: the session sees its capture and writer through the
`RecordingCapture` and `RecordingWriter` protocols, the writer reports through
`events` closures, the app side is the closures of `RecorderEnvironment`, and
the monitor's `tick(at:)` takes its time as a parameter. The writer, converter,
mixer and recovery tests write real files with AVFoundation from synthetic
buffers and read them back; the session tests drive the state machine through a
fake capture and writer. The instant-start tests record two and three
recordings in a row through the real writer and mixer, each held before its mix
while the next one records, and check that every file is complete and holds only
its own sound. The system audio tests build and tear down
`SystemAudioTap` against fake Core Audio calls (`TapHardware`), feed its IOProc
buffer lists made in the test, and drive `SystemAudioSource`'s choice, its
construction order and its repair with fake taps and with the real tap on the
fake hardware; no tap is created. The backup tests record a tap (440 Hz) and
its backup (1000 Hz) through the real writer and mixer and find in the mix
which one each 10 ms holds. Settings are read from the argument domain, never
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
| Watchdog | `RecordingMonitor` | 5 s without audio, 20 s of zeros, 5 s without a first frame: status item; 15 s (`announceSeconds`), returns in between included: notification and on-screen panel; over after 5 s of steady audio (`steadySeconds`) |
| Capture stop wait | `RecordingSession.stopCapture` | 5 s |
| Mix stall limit | `RecordingMixer.stallLimit` | 60 s |
| Mix check | `RecordingMixer.verify` | audio within 2 s of the video (12 s shorter for a leftover never closed); length within 1 s; 30 windows; silence below -60 dBFS; system audio at 0.5 to 1.5 times its source |
| Timestamp check | `ArrivalCheck`, `StreamStamps` | the tap's audio has only its arrival time; stream audio and frames stamped over 1 s after their arrival, frames over 1 s before it, the microphone over 300 s before it, get their arrival time; stream audio stamped behind at real-time pace gets it after 1.5 s of arrivals; nothing ends over 1 s after the present |
| Disk | `DiskSpace` | start 2 GB, stop 500 MB, checked every 5 s |
| Device switch | `MicDevices` | check 0.7 s after a change; 3 retries, 2 s apart |
| Tap repair | `SystemAudioSource`, `TapRepair` | dead after 1 s without a buffer (checked every 0.25 s); rebuilt at once, then waits of 0.5 s doubling to 2 s, for the whole recording; next construction after two failures; healthy after 10 s; shown as "Call audio is not being recorded" after 15 s without tap audio (`RecordingMonitor.tapLostSeconds`) |
| Tap drift | `TapDrift` | smoothed over 2 s; one frame every 0.1 s of audio from 10 ms off until 2 ms |
| Room for a copy | `DiskSpace.copyReserve` | 500 MB to spare; 2 GB while a recording is starting or running |
| Tap or backup | `SystemAudioChoice` | the tap wherever its spans say it delivered; the backup elsewhere, and where the tap's track is digital silence (below -100 dBFS) for 2 s or more while the backup has signal (above -70 dBFS) more than 0.3 s inside it; less than 0.25 s at an end of the recording stays the tap's; 5 ms crossfade |
| Tap against backup | `SystemAudioAlignment` | up to 16 windows of 1 s, searched 0.3 s either way; likeness 0.5, no rival peak at 0.9 of the best; accepted up to 250 ms; at least 3 windows and two in three within 5 ms of the median |
| Quit wait | `applicationWillTerminate` | 30 s |
| Track format | `MicConverter.sampleRate`, `CaptureSource`, `SystemAudioConverter` | 48 kHz stereo |

## Local data

Recordings go to the save folder (the Desktop until another is chosen). The
log is `~/Library/Logs/Holdfast/recordings.log`, written on its own queue and
flushed when the app quits. Settings and shortcuts are in the app's own
defaults domain.
