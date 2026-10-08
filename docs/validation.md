# What was measured

The measurements behind the claims in the [README](../README.md) and the design
in [architecture.md](architecture.md). They were taken from October 4 to 7, 2026 (each section says when
where it was not the 4th), on the developer's M-series MacBook Pro with macOS 15.7 and AirPods Pro 2.

A "simulated call" is `Tools/fakecall.swift`: a second process that opens the
default input with voice processing, as a call app does, holds it for the
number of seconds it is given, and lets it go. Microphone counts come from the
summary line Holdfast writes to its log at the end of every recording.

## The failure that started the project

A real 69-minute meeting, recorded with QuickRecorder 1.6.7: the microphone
track was exact digital silence from 24 s on, from the moment the meeting app
took the AirPods microphone. The other side of the call was intact.

## Capture methods compared

`Tools/micprobe.swift` captures the default microphone one way for 24 s and
prints the buffers received each second, while `Tools/fakecall.swift` takes the
microphone for 8 s during the run.

| Method | While the other process held the microphone, and after |
| --- | --- |
| AVAudioEngine input tap | 0 buffers, from the moment the other process took the microphone until the end of the run. `AVAudioEngineConfigurationChange` fired with the engine stopped. |
| AVAudioEngine, restarted on that notification | Still nothing. |
| AVCaptureSession on the default device | 50 buffers a second at 24 kHz throughout. |
| ScreenCaptureKit, `captureMicrophone` | 50 buffers a second at 24 kHz throughout. |

The engine tap is how QuickRecorder captures the microphone. Of the two
methods that survive a call, ScreenCaptureKit was chosen because its microphone
output shares the stream's clock with the picture and system audio, so the
three tracks are placed on one timeline.

To repeat it (the terminal needs Microphone and Screen Recording permission):

```sh
swiftc -O Tools/micprobe.swift -o build/micprobe
swiftc -O Tools/fakecall.swift -o build/fakecall
build/micprobe sck 24        # or: engine, engine-restart, capture
build/fakecall 8             # in a second terminal, during the run
```

## A call takes the microphone mid-recording

A recording with a real voice on AirPods, during which a simulated call took
the microphone for 9 s:

- 1,411 of 1,411 microphone buffers written, 0 dropped.
- 0.1 s of silence filled.
- The microphone track is at speech level throughout, before, during and after
  the call.

## Six minutes with two calls

A six-minute recording during which two simulated calls each took the
microphone for 20 s:

- 18,063 of 18,063 microphone buffers written, 0 dropped: 361.2 s of microphone
  audio in a 361.5 s recording.
- 0.3 s of silence filled.
- The video, system audio and microphone tracks within 0.1 s of each other in
  length.

## A device switch mid-recording

Switching the input from the MacBook Pro Microphone (48 kHz) to the AirPods
(24 kHz) during a recording: the recording followed the switch without losing
the microphone track.

## kill -9 and recovery

`kill -9` on Holdfast 35 s into a recording, then launching it again. The app
found the unfinished `.recording.` file, recovered 30 s of it (the file is
written in fragments every 10 s), wrote the mixed file, and kept the two-track
original next to it.

## Stopping and quitting

- **Quit during a recording:** the app finished and saved the file before it
  exited.
- **Stop pressed three times:** one recording, saved once.

## The menu bar item

Measured from a capture of the menu bar on a 2x display (a 4K display at
1920 × 1080 points, 24-point menu bar): the record symbol's ink and the timer
digits' ink are centred on the same pixel row (ring rows 11–35, digits 14–32
of the 48-row menu bar). The ring is drawn by the app rather than taken from SF
Symbols, because the symbol of that size is an even number of pixels tall and
sat half a pixel below the digits.

## Tests

`Tools/test.sh` runs 238 tests in about four minutes (250 s measured), without the
app, a screen or a microphone. They compile the pipeline's own sources; the writer,
converter, mixer and recovery tests write real files with AVFoundation from
synthetic buffers and read them back.

| Area | Tests | What they cover |
| --- | ---: | --- |
| Microphone converter | 23 | Format changes (24 → 48 → 24 kHz, 44.1 kHz stereo), gaps as silence, jitter, a backlog with its own timestamps dropped where silence was filled with no offset after it (drained at 3, 1.1 and 1.05 times real time, held 13 s or 40 s), a lagging clock shifted, full-length track, silence generation |
| System audio and timeline | 10 | Placement at the end of what was written, holes filled past 0.1 s, pause offsets; stream audio stamped 1.2 s behind at real-time pace placed by its arrival within 2 s, a backlog never; the tap's rule (back to back within 0.1 s of its arrival either way, a hole filled first, left out only when the track holds more than 0.1 s beyond it, the first buffer of a recording); the tap's drift (nothing for jitter, a frame every 0.1 s of audio from 10 ms off until 2 ms, a device 50 ppm slow or fast followed for 90 minutes within 12.5 ms) |
| Writer | 14 | One file with three tracks of the same length, pause, mute, a source that stops, late frames, no empty file, every audio format |
| Session | 19 | Every state in order, stop while starting, repeated stops, failures, quitting while recording, starting or exporting, pause and the timer; the monitor stopped as the capture stops, with the main thread held up before the writer is taken |
| Instant start | 8 | A recording started while the one before is held before its mix: it starts at once, is stopped and saved while the first still waits, and both files are complete, under their own names, each with only its own sound; three in a row with two mixes running while the third records; a mix that fails reported for its own recording, by name, the running one untouched; a stop, a pause and a late failure reaching only their own recording; quitting waiting for all of them, the Mac kept awake until the last; what the status item and its menu show in each combination; names taken by recordings that have no file yet |
| Monitor | 13 | Fills and warnings for each track, the start warning, late ticks, resume, a source that keeps dropping out notified once, a microphone back with only zeros not back, system audio missing only when neither the tap nor its backup delivers (a quiet tap logged after 5 s, shown as "Call audio is not being recorded" after 15 s until it is back, never as a warning or a notification) |
| Files, names, disk | 19 | Temporary and final names, leftovers, staging, free-space thresholds, a moved or deleted folder; a copy that must leave 2 GB while a recording is starting or running |
| Mixer and recovery | 15 | Mix and its checks, MP3 and package mixes, every recovery outcome; the folders recorded to remembered most recent first, eight at most; a launch that finds leftovers in the save folder and in an earlier folder (each recovered, one report with a part for each folder, the file of another app untouched, nothing deleted), forgets a folder that is gone, is a file or has none, and passes over one it may not list and one on a disk that is not connected, which are searched again at the next launch; a folder whose leftover could not be renamed stays remembered |
| Package mix | 6 | The mix of a sound-only recording's two files by the mixer's own sum against the audio engine's mix it replaces, in 32 bit float files of 12.5 s with both sides speaking at once: all 1,200,000 samples equal at the volumes 1 and 1, 1 and 0.5, 2 and 1, 4 and 0.25, 0 and 1; at 0.3 and 0.7, 60,382 samples differ, by 1.5e-8 at most (rounding). From files of each format: ALAC, FLAC and Opus equal sample for sample, AAC 71,760 samples different by 3.7e-8 at most; a package as the writer makes it (AAC, 3 s) 57,238 of 288,000 different by 1.2e-7 at most (the two readers do not decode AAC to the same last bit). With Level Voices: files recorded at -26.0 and -14.0 LUFS given +10.0 and -2.0 dB, each at -16 LUFS in the mix, every sample the two files at their gains, the same gains the player is given; with the volumes 0.5 and 4 on top the first side 6 dB lower and the second held by the limiter (5.5 dB taken off, every sample at or under -1 dBFS; between the samples of this noise-like test sound 0.939, measured at eight times the rate, which is -0.55 dBTP: the limiter's estimate from 12 samples reads low on sound up to half the sample rate); two loud voices at once in AAC and FLAC (-6 dB each, the limiter acting, the length kept); a silent side given nothing and a quiet one +12 dB; a file that does not open failing the mix |
| Level Voices | 11 | The loudness meter: a 1 kHz sine at -23 dBFS in both channels read as -22.99 LUFS at 48 and at 44.1 kHz, the same fed in pieces, 30 s of it between 40 s of silence -23.04 LUFS, beside a stretch 30 dB quieter -23.02 LUFS, silence without a reading. The gain rule (to -16 LUFS within -6 and +12 dB; nothing for a silent side, under 3 s of sound or under -50 LUFS). The limiter: tones up to 1.9 times full scale, and one at a quarter of the sample rate whose samples stay under the ceiling while its wave reaches 1.2, held at -1.00 dBFS and -1.00 dBTP (measured at eight times the rate), the same whatever pieces it comes in; quiet sound and everything from 1.9 s after a click passed bit for bit; a click of three times full scale at its sample. The mix, read back from a 32 bit float file: other side recorded at -26.4 LUFS and microphone at -14.5 LUFS, gains +10.4 and -1.5 dB, each -16.0 LUFS in the mix; a side at -30.5 LUFS given +12.0 dB and no more (-18.5 LUFS), a silent microphone nothing; two sides with the same sound and a click, 11.4 dB taken off, peak -1.00 dBFS; a click at frame 144,000 in the recording, the plain mix and the leveled one, every sample of the leveled mix the plain one times the gain, and with gains of 0 dB all 384,000 frames bit for bit the plain mix; with the setting off all 576,000 frames the sum of the two tracks, bit for bit; the check passing the mix it was made for and rejecting a mix without the gains, one with gains it was not told of, and a leveled one without the microphone; a leftover recording mixed with the setting as it is |
| Settings | 9 | Keys, defaults and stored types of earlier installations; a recording keeps the Level Voices setting it was started with |
| Status item | 6 | Every state's symbol, title and sentence, the timer text, the item's width, the call-audio warning |
| Package | 1 | `.qma` info files of earlier versions |
| Timestamps and length | 13 | The timeline never past the present: a buffer of the stream's audio stamped 1100 s in the future near the end of a call recorded at its arrival time, a tap buffer its device stamped 1100 s ahead recorded like the others (its source hands it on ending when it arrived), a frame and an audio buffer stamped 12 s ahead as a call connects (no video hole, no fill past the present, the microphone not shifted), a microphone stamped 400 s before its arrival, a microphone backlog 40 s old left to the converter, audio of unknown arrival in the future left out and such a frame written at the present, fills and repeats cut off a second after the present, the stop's padding up to the video's end (sound only: the present), a mix whose audio is over 2 s longer or shorter than its video rejected and the recording kept unmixed |
| System audio tap | 22 | Build and teardown order against fake Core Audio calls with each clock (built-in output, no sub-device, default output) and the order of constructions, cleanup after each failed step, the IOProc's stream usage (only the tap's stream), the IOProc's copy (interleaved, non-interleaved, behind other input streams, turned-off streams, malformed lists), nothing handed on once the rate changes or the clock device goes away, the IOProc called with the device's time stamp 12 s and 5 s ahead, 10 s and 1100 s behind and invalid (the buffer ends at the host time of the call each time), conversion and resampling to 48 kHz stereo, the choice between the tap with its backup and screen capture alone, with its notice and warning; the repair: a tap that hands on nothing rebuilt at once and the next construction after two failures, around and around, the waits (at once, then 0.5 s doubling to 2 s), the source as the app builds it (its stall limit of 1 s and check every 0.25 s: the second tap between 1 and 1.6 s), every listener removed as the one installed, a tap that cannot be built at the start built in the background, a rate change, nothing of an old tap after the new one, the real tap on fake hardware falling back from the built-in output to no sub-device to the default output, and a tap whose IOProc is never called; a sound-only file written from the tap's buffers; the failure injection of a device test in the source: a dead span in which every tap is held back and rebuilt as a dead one is (the same construction once more, then the next) until the span ends and the newest tap stays, a zeros span in which every buffer handed on is zeros, in the tap's own format and a converted one, and nowhere else, and a source without an injection untouched |
| Failure injection for device tests | 4 | The two environment variables: unset, nothing happens to any buffer and nothing is logged; a span is two numbers of seconds, the second the greater, and nineteen other values are ignored with a log line each, one malformed leaving the other in force; a buffer is held back or zeroed from the span's first second up to its last; both spans together, and dead where they overlap |
| Backup of the system audio | 12 | The tap's spans and the choice of source stretch by stretch; four titled tracks (the call tap's with its tone where it delivered and silence elsewhere) and both taps' spans through the real writer; today's meeting (the tap dead from 27 s to 28 s): the mix holds the backup exactly there and the tap elsewhere, the switches within 0.02 s; a tap dead from the start; FaceTime (backup silent) the tap's, both alive the tap's alone at its level, both dead silence; the check rejecting a mix without the system audio or with it twice; the microphone kept apart; a sound-only recording started by the backup and merged; a killed recording recovered with its spans; the report about a kept three-track recording (tap, backup, call tap) naming those tracks and no microphone |
| Alignment | 8 | The place of one piece of sound in another to the sample, none for a steady tone or past 250 ms; what the windows say together; the tap moved onto the backup's timeline in the mix, with tracks that begin as in a real recording; a call of three minutes in an hour's recording measured from 16 windows spread over the call (over the hour: two at most, not measured), one of five seconds from three |
| Call audio and the silent tap | 16 | The rule for a tap that hears nothing, fed a tenth of a second at a time: zeros against sound elsewhere rebuilt after 3 s; nothing for zeros with silence or with sound below -60 dBFS elsewhere, for a quiet tap, for a sound that begins a quarter of a second earlier in the backup or ends there first, or for zeros broken off by silence written in the tap's place; a tap deaf from the middle of a sound found 3 s later, one deaf through minutes of silence 0.6 s into the first sound; without the permission two rebuilds 3 s apart, the notice, then one rebuild a minute, and after the first sound nothing more and no second notice. Through the real writer: a tap that goes to zeros while the backup, or the call tap, has sound asks for one rebuild after 3 s with its log line, and for nothing while nothing plays. Its source rebuilding it (the same construction once more, then the next), and the session passing that on to its capture and posting one notification with where to allow system audio recording. The call tap's source with the real tap on fake Core Audio calls: nothing built while the call process has no audio object, a tap of that process's objects alone, without a sub-device, when they appear mid-recording, its buffer handed on as call audio ending at the host time of its IOProc, not rebuilt for other changes of the list, taken down when the objects go, a new one for the next call, every listener removed; the built-in output as its clock after no sub-device failed twice; a tap that cannot be built stopping nothing; the list read every 5 s when it cannot be listened to. The monitor: a dead process tap shown as missing call audio only while a call may be playing and the call tap has delivered nothing for 15 s, gone when the call tap delivers or the call ends; the system audio warning when the process tap and the backup are both silent for 5 s, whatever the call tap delivers. The mix, through the real writer and mixer with AAC tracks: a FaceTime call (backup silent) with the process tap dead for 3 s has the voice there from the call tap, each of four clicks once and within 1 ms of its time, one of them on each switch, the offset between the two taps measured as 14.6 ms; a browser call with the same outage is mixed as without a call tap, whether its track is empty or zeros; music and a call with the process tap dead: the backup plus the call tap is the two sounds together (likeness over 0.9 with what the tap would have held, level within 10%). In lossless files: a recording whose process tap was alive throughout, with a call in the call tap's track, mixed bit for bit like the same recording without that track (1,152,000 samples, 0 different, also with Level Voices) and every one of 573,485 frames the tap's audio plus the microphone. The choice of stretches; a sound-only recording with its call tap's file merged in; a killed recording recovered with the call tap's audio |
| Placed by arrival | 9 | Through the real tap source (given a clock in the IOProc's place), writer and monitor: the tap's device time stamps jump 10 s back, 5 s ahead and 1100 s back mid-recording and return (every sample in the file, once, in order, within one buffer of its arrival, no silence added, one unbroken span); tap buffers that wait 300 ms between the IOProc and the sample queue (nothing left out or shifted, the monitor's clock not set back). As the app is put together, with no clock given: the real tap on fake Core Audio calls, its IOProc called every 10 ms of real time with the device's time stamp 10 s behind and 5 s ahead, its source and the writer (every sample in the file; with the IOProc trusting a stamp behind, as the version that lost the meeting did, 120,000 of 192,000). A tap buffer that reaches the writer after silence was written over its time (left out, logged once, counted at the stop, the buffers after it recorded, one that arrived 30 ms early still written). A tap whose device runs 100 ppm slow or fast for 200 s (never more than 13 ms from its arrival, about 740 frames added or taken out, no silence, one span, nothing left out); the frame added or taken out where it is heard least. ScreenCaptureKit audio stamped a steady 10 s behind at real-time pace (recorded by its arrival within 2 s); a ScreenCaptureKit backlog of 5 s handed over in half a second after a 5 s stall (left out where silence was written, the audio after it in place); a frame stamped 12 s ahead and one 12 s behind (written at their arrival, every later frame in order, none left out) |

## Not yet checked on the real machine

Set in code and covered where a test can reach them, but not yet seen in a real
recording:

- The warning panel over a full-screen meeting.
- Level Voices on a real call: what real voices measure and how the leveled
  mix sounds. Covered by tests with synthetic sound and by the 90-minute
  simulation.
- Level Voices in a sound-only recording: the mixed file of a real recording,
  and the player, which plays a package at the same gains and has not been
  listened to. Covered by tests of the mix against the mix it replaces.
- Recovery in a folder that is no longer the save folder, after a real kill.
  Covered by tests on real folders and files.
- A recording started while a long one is still being saved. Seen once with a
  short one, on 2026-10-07: a recording of 5 min 12 s was stopped at
  22:32:25.5, the next one began 0.5 s later, and the first was mixed and
  saved 3 s into it (the log; both files saved). Not yet with a mix that
  takes most of a minute, as an hour's does, nor were the two files measured.
- The app's floating windows on a full-screen Space.
- "Leave Holdfast's Own Windows Out" with windows that open during the
  recording.
- The call tap during a real call. With no call on it was built and ran in
  the recordings of the evening of 2026-10-07 (see "The call tap with no call on", below):
  `avconferenced` has an audio process object outside calls too, so the tap
  exists for the whole recording. Not yet seen: that it delivers a live
  FaceTime or phone call (`build/tapprobe calltap`, in a bundle with
  Holdfast's identity, is that construction and has not been run during a
  call; `tapprobe calls`, the same tap clocked by the default output, has
  not either); how far its audio is from the process tap's in a real
  recording; and the mix of a real call in which the process tap was dead,
  which has not happened since.
- A live recording of 60 to 90 minutes. The longest live recording measured
  here is six minutes; the 90-minute simulation below is not a capture.
- The app's own wiring of the newest parts, which the tests do not compile
  (they cover the parts themselves, through stand-ins for the capture): that
  a recording's start creates the call tap's source and hands it to the
  capture, that the capture passes a rebuild of a deaf tap on to the tap's
  source, that a start puts its folder on the list recovery searches and the
  launch takes cleared folders off it, and that a sound-only recording's mix
  gets the recording's own Level Voices choice. The build fails when the
  capture is made without a call tap argument or lacks the rebuild; the rest
  is first shown by a recording on the device.
- The failure tests of "Failure tests on the device", below, with sound
  playing: the dead span was run once in silence (its log is in that
  section), the zeros span not at all, and neither during a call.
- The watch for a process tap that delivers only zeros, on the device: that a
  healthy tap is never taken for one (with the output muted or at volume zero,
  with AirPods in call mode, at the start and end of sounds), and what a real
  recording without the permission logs and shows.
- System audio through the process tap with its backup, beyond what "The tap
  against its backup" measures. The process tap has recorded real FaceTime
  calls (the owner's recordings; no figures of them are in this file). Not
  yet seen or not measured:
  - a real browser call on AirPods that go to 24 kHz, the final file having
    the other side throughout;
  - a tap that dies by itself being rebuilt within about a second, with the
    log's lines and no warning (the built-in failure of "Failure tests on the
    device" was);
  - the mixed sound in step with the picture (against the backup's track it
    is; the backup's own step with the picture is ScreenCaptureKit's and was
    not measured), and the same over a long recording;
  - the permission prompt and what the permission reads as before and after;
  - that with AirPods as the output the tap leaves their microphone closed.

## The tap against its backup

Measured on the owner's Mac on 2026-10-07 in a 45 s recording, with the AirPods
in their 24 kHz call mode and voice processing switched on by another process
mid-recording (the events that used to lose the tap's audio):

- The tap's track and the backup's track both held every sound; no rebuild and
  no timestamp warning in the log.
- The two tracks are a constant 52.4 ms apart: by cross-correlation at five
  points (music before the call; test sounds before, during and after call
  mode and voice processing) the backup's audio is 52.4 ms earlier than the
  tap's every time.
- The mix of that build, which gave each half second to whichever source had
  sound in it, logged "33.3 s from the process tap, 11.8 s from the backup in 4
  stretches" although the tap was alive throughout; with the tracks 52 ms
  apart every such switch doubles or cuts a sound. The mix now takes the tap
  wherever it was alive and moves its audio by the offset it measures (next
  list).
- Read without a tap, the built-in output that clocks the tap's device reports
  an output latency of 70, a safety offset of 74 and a stream latency of 690
  frames at 48 kHz (17.4 ms); with the tap's IO buffer of 1024 frames that is
  38.7 ms of the 52.4 ms.

The mix that measures and moves, on the owner's Mac the same day: a 50 s
recording with quiet speech played three times, the unmixed file kept.

- The log: "the tap's audio is 22.4 ms later than the backup's (12 of 13
  windows agree) and is moved onto the backup's timeline". So the offset is
  not the same from one recording to the next (52.4 ms in the one above).
- From the two files, each track decoded on the file's timeline and compared
  by normalised cross-correlation of one-second windows where the microphone
  is quiet (22.5, 30.5 and 40.5 s): the unmixed file's tap track is 22.35 ms
  later than its backup track (likeness 0.99); the mixed file's audio is
  0.00 ms from the backup track and 22.35 ms before the tap track (likeness
  0.99 and 1.00 at 22.5 s). Between 8 and 14 s the tap's track has sounds at
  -16 to -22 dBFS that the backup's does not, and the mix has them.
- The tracks of a recording do not begin together: in this file the tap's
  begins 18.0 ms (864 samples) after the picture and the backup's 12.1 ms
  (583), each with the first buffer of its source; the mix's audio begins with
  the picture. A player keeps to that. `ffmpeg -map 0:a:N` to a raw file does
  not: it writes each track from its first sample, and the same files then
  read tap against backup +16.50 ms, mix against backup +12.15 ms and mix
  against tap -4.35 ms, all three wrong by the beginnings left out. With
  `-af aresample=async=1:first_pts=0` ffmpeg keeps them and gives the figures
  above.
- "0.5 s from the backup in 2 stretches" in that log: the tap's track is
  digital silence from 17.29 to 17.57 s and from 31.74 to 31.97 s (0.51 s
  together), which is silence the writer put there for a tap that handed on
  nothing for more than 0.1 s; nothing was rebuilt (that takes 1 s). Those two
  holes are the backup's in the mix. The spans file of that recording was
  removed with the save, so this is read from the track, not from the spans.
- The tap's device reported an input latency of 33, a safety offset of 991, a
  stream latency of 0 and an IO buffer of 512 frames: 1536 frames, 32.0 ms,
  against 22.4 ms measured. They do not account for the offset either, and
  nothing is subtracted where the buffers are stamped.

## Failure tests on the device

This section says how they are run and what the log must show. Only its last
part, "The dead span, run once", is a measurement.

A real process tap cannot be made to fail on demand, so the app can be
launched with a failure built in. Two environment variables of the app's
process, read once at launch, each hold a span "from-to" in seconds, counted
from the moment a recording's process tap is started (a moment before the
first frame), in every recording of that launch:

- `HOLDFAST_TEST_TAP_DEAD=10-22`: from 10 s to 22 s the process tap's buffers
  are not handed on at all, as if its IOProc had stopped being called. The
  stall check (1 s), the rebuild and its growing wait run for real; a rebuilt
  tap is held back too until the span ends.
- `HOLDFAST_TEST_TAP_ZEROS=10-22`: in that span the process tap's buffers are
  handed on with every sample zero. The rule for a tap that delivers only
  zeros and its rebuild run for real; rebuilt taps go on delivering zeros
  until the span ends. That rule acts only while the Mac plays sound, so
  something must be playing throughout the span.

Both may be set, with different spans (where they overlap the tap is dead).
Fractions of a second are allowed. A value that is not such a span is ignored
and the log says so. Without the variables nothing differs: they are no
setting, are stored nowhere and do not show in the app. The call tap and the
backup are never touched.

To run one, quit Holdfast first (a second copy quits by itself), then:

```
open -n /Applications/Holdfast.app --env HOLDFAST_TEST_TAP_DEAD=10-22
open -n /Applications/Holdfast.app --env HOLDFAST_TEST_TAP_ZEROS=10-18
open -n /Applications/Holdfast.app --env HOLDFAST_TEST_TAP_DEAD=10-22 --env HOLDFAST_TEST_TAP_ZEROS=40-48
```

Play sound for the whole recording (music or a video; a FaceTime call to see
the call tap fill in), record for at least 15 s past the end of the last span,
stop, and read `~/Library/Logs/Holdfast/recordings.log`. Quit that copy
afterwards and open Holdfast as usual: the hook lasts as long as the process.

What the log shows, in order, for `HOLDFAST_TEST_TAP_DEAD=10-22`:

- at launch and again at the recording's start: `Test hook:
  HOLDFAST_TEST_TAP_DEAD is set: from 10 to 22 s of the recording the process
  tap's buffers are not handed on, as if its IOProc had stopped`
- at 10 s: `Test hook: from here the process tap's buffers are not handed on
  (HOLDFAST_TEST_TAP_DEAD, until 22 s)`
- about a second later: `System audio: the process tap with … failed (its
  IOProc handed on nothing for 1.x s); rebuilding at once, the backup records
  meanwhile` and `System audio: process tap rebuilt with …`; then the same
  pair about every 1 to 3 s with `rebuilding in 0.5 s`, `in 1.0 s`, `in
  2.0 s`, the construction changing after every second failure (built-in
  output, no sub-device, default output): five or six failures in 12 s
- about 5 s into the span: `System audio: the process tap has delivered nothing for 5 s;
  the backup (screen capture) records the system audio meanwhile`
- at 22 s: `Test hook: from here the process tap's buffers are handed on
  unchanged again` and `System audio: the process tap delivers again`
- 10 s after the last rebuild: `System audio: the process tap with … has
  delivered for 10 s`
- at the stop: `System audio: process tap stopped (N rebuilds, N failed
  attempts)` with N the number of failures above
- after the mix: `System audio in the mix: … s from the process tap, 12.x s
  from the backup in 1 stretch`

No warning and no notification may appear, and the final file must have the
sound throughout: from the backup in the span (from the call tap as well
during a FaceTime call, with a `Call audio in the mix: …` line).

For `HOLDFAST_TEST_TAP_ZEROS=10-18`, with sound playing:

- at launch and at the recording's start: `Test hook: HOLDFAST_TEST_TAP_ZEROS
  is set: from 10 to 18 s of the recording the process tap's buffers are
  handed on as zeros`
- at 10 s: `Test hook: from here the process tap's buffers are handed on as
  zeros (HOLDFAST_TEST_TAP_ZEROS, until 18 s)`
- 3 to 4 s later: `System audio: the process tap has delivered only zeros for
  3 s while the backup or the call tap has sound: it does not hear the Mac and
  is rebuilt (rebuild 1 since it last heard anything)`, `System audio: the
  process tap with … failed (it delivers only zeros while the Mac plays
  sound); rebuilding at once, the backup records meanwhile`, `System audio:
  process tap rebuilt with …`
- 3 to 4 s after that the same three with `rebuild 2` and `rebuilding in
  0.5 s`
- at 18 s: `Test hook: from here the process tap's buffers are handed on
  unchanged again` and `System audio: the process tap hears the Mac again`
- 10 s after the second rebuild: `System audio: the process tap with … has
  delivered for 10 s`
- at the stop: `System audio: process tap stopped (2 rebuilds, 2 failed
  attempts)`
- after the mix: `System audio in the mix: … s from the process tap, about
  8 s from the backup in …` (one stretch, or one on each side of a rebuild)

A span of zeros longer than about 10 s goes on to the third step of that rule:
`System audio: the process tap still delivers only zeros after 2 rebuilds;
from here on it is rebuilt once every 60 s, and the backup and the call tap
record meanwhile`, with the notification "Call Audio Not Included" (once
while the app runs).

A value that is not a span logs, at launch only, `Test hook:
HOLDFAST_TEST_TAP_DEAD="…" is not a span of seconds like 10-22 and is
ignored`.

### The dead span, run once

On 2026-10-07 at 22:37 the installed app was launched with
`HOLDFAST_TEST_TAP_DEAD=10-22` and recorded the screen for 35.6 s with nothing
playing and a silent microphone, so this run shows the repair and the choice
of source, not sound. The log, with the seconds of the recording:

| At | Log line |
| ---: | --- |
| launch, start | `Test hook: HOLDFAST_TEST_TAP_DEAD is set: from 10 to 22 s …` (both times) |
| 9.8 s | `Test hook: from here the process tap's buffers are not handed on (HOLDFAST_TEST_TAP_DEAD, until 22 s)` |
| 10.9 s | failed after 1.1 s, `rebuilding at once`; rebuilt with the built-in output 0.07 s later |
| 12.1 s | failed after 1.1 s, `rebuilding in 0.5 s`; rebuilt with no sub-device |
| 13.8 s | failed after 1.1 s, `rebuilding in 1.0 s`; rebuilt with no sub-device |
| 15.0 s | `the process tap has delivered nothing for 5 s; the backup (screen capture) records the system audio meanwhile` |
| 16.1 s | failed after 1.2 s, `rebuilding in 2.0 s`; rebuilt with the built-in output |
| 19.4 s | failed after 1.1 s, `rebuilding in 2.0 s`; rebuilt with the built-in output |
| 21.8 s | `Test hook: from here the process tap's buffers are handed on unchanged again` |
| 22.0 s | `System audio: the process tap delivers again` |
| 31.8 s | `the process tap with the built-in output "MacBook Pro Speakers" has delivered for 10 s` |
| stop | `process tap stopped (5 rebuilds, 5 failed attempts)`; `call tap stopped (0 rebuilds, 0 failed attempts)` |
| mix | `System audio in the mix: 23.7 s from the process tap, 12.0 s from the backup in 1 stretch` |

The order of constructions went from the built-in output to no sub-device and
back: the default output was the built-in device, which is not tried a second
time as such. No system audio warning and no "Call audio is not being
recorded" line came (no call was on); the one notification of the run,
"Microphone Is Not Being Recorded" after 20 s of zeros, was the silent
microphone's. Alignment was not measured (no sound in either track). Still to
do: the same with sound playing, so that the final file can be heard and
measured across the span, and the zeros span.

## The call tap with no call on

From the log of the six recordings made with the call tap on 2026-10-07 (12 s
to 5 min 12 s, with no call on; one of them was killed and recovered): at
every start `Call audio: avconferenced has an
audio object (…); a call tap is set up for it` and `Call audio: call tap with
no sub-device (…)`, in 48000 Hz or, with the AirPods in call mode, 24000 Hz;
at each of the five stops `call tap stopped (0 rebuilds, 0 failed attempts)`;
after each of those saves `the call tap delivered for N s in 1 stretch, between 0.0 s and N s of
the recording`, N the recording's length. So outside a call the process keeps
its audio object, the tap's IOProc keeps being called while that process
plays nothing, and its track is filled by the tap itself, with zeros. What it
delivers during a call has not been seen.

## Process tap constructions (Tools/tapexp)

Measured on the owner's Mac on 2026-10-06, after a 47-minute Zoom meeting in a
browser, on AirPods, lost the other side: the tap's aggregate device was then
clocked by the AirPods (24 kHz, call mode) and its IOProc delivered nothing.
`Tools/tapexp.swift` ran inside an app bundle with Holdfast's bundle id and
signature, so it had Holdfast's System Audio Recording permission (a process
started from a terminal without that permission gets a tap that runs and
delivers only zeros). Each construction had a global tap of every process but
its own, private, unmuted, drift compensated:

| Construction | IOProc | A quiet sound played to the AirPods |
| --- | --- | --- |
| Clocked by the default output (the AirPods) | about 94 calls a second, 1024 frames at 48 kHz | -47.7 dB |
| Clocked by the built-in output (MacBook Pro Speakers), the default output staying the AirPods | the same | -47.7 dB |
| No sub-device | the same | -47.7 dB |

With a second process holding the AirPods' microphone with voice processing,
all three kept running (that process's own ducking lowered the test sound to
-77.7 dB). The AirPods stayed at 48 kHz in that test, so the 24 kHz call mode of
the lost meeting could not be brought about on demand; the AirPods listed only
48000 Hz as available. With the lid closed (clamshell, external display) the
built-in speakers device was present, alive, at 48000 Hz. So the tap follows
the processes, not the device that clocks it, and Holdfast clocks it by the
built-in output, without a sub-device when there is none, and by the default
output only as a last resort.

## 90-minute simulation

This is a simulation of the pipeline with synthetic buffers, not a live
capture: `Tools/soak.sh` feeds the real writer, monitor, mixer and recovery
code as fast as they take it, on a simulated clock, without the app, the
screen or a microphone. The longest live recording measured is still six
minutes.

The simulated meeting runs 90 minutes, of which 2 are paused: 64 × 36 frames
at 5 fps with a time code in each, and a 5-minute static slide with no frames;
48 kHz stereo system audio with a tone every minute, from the process tap
(through its real source: each buffer stamped in the IOProc's place and handed
to the sample queue 5 to 25 ms later) and, with noise of its own and buffers
arriving on their own schedule, from its backup; the tap's device runs 50 ppm
slow against the stream's clock (0.27 s of audio less than time passes in the
90 minutes); a 24 kHz mono microphone with its own tone every minute, whose clock
runs 50 ppm fast, with irregular buffer sizes and arrival. At 10 minutes a call
app takes the microphone (10 s with nothing, then 3 minutes at 48 kHz), at 33
minutes the AirPods disconnect for 30 s, from 2,215 to 2,245 s the tap
delivers nothing (an outage, then the tap is back), and the microphone is
muted for 1 minute after the pause. A FaceTime call runs from 2,200 to
2,260 s, across that outage: the call process gets its audio object half a
second before and loses it half a second after, the call tap's source (the
real one, on a list of processes the simulation changes) builds its tap for
it and takes it down, and the call's sound, noise with four tone bursts of
its own, is in the tap's audio while the tap is alive and in the call tap's,
never in the backup's. Two of the bursts fall in the outage. The tap's device stamps its buffers 10 s
in the past from 1,745 to 1,815 s and 5 s in the future from 3,605 to 3,675 s
while their audio keeps coming, as it did around call events on the real
machine.

- **Lengths:** 88 minutes expected (5,279.9 s from the first frame). Video
  5,280.023 s, the tap's track 5,279.890 s, the backup's 5,279.857 s, the call
  tap's 5,279.823 s (silence but for the call, brought to the end at the
  stop), microphone 5,279.954 s; the mixed file the same. Every track within
  0.13 s.
- **Sync, from the files:** the picture is where its time code says to the
  millisecond. The backup is within 0.3 ms of its place until the pause and
  22.6 ms early after it (one 1024-frame buffer, the pause's alignment, within
  the 0.1 s the writer allows). The tap's track follows its slow device: its
  markers are between 0.4 and 10.4 ms early, 3 ms more each minute until the
  smoothed difference reaches 10 ms, then brought back to 2 ms a frame every
  0.1 s (the first ten such runs are in the log, one about every 215 s), with
  no silence written and no break in its spans; after the pause it is brought
  back the same way, so the tap's and the backup's markers lie up to 21.6 ms
  apart there. The microphone is late by its clock drift, up to
  68 ms, and back in place after each gap, pause or mute.
- **The tap's device clock:** the four markers that sounded while it was 10 s
  behind and 5 s ahead are in the tap's track where they belong (1.5 to
  4.5 ms early, the drift of that minute), the track has no silence
  there, its spans have no break, and the log has nothing to say: those time
  stamps are not read. Run against the version before, the same meeting has
  the tap's track silent for the 70 s its device clock was behind (both
  markers missing, a break in its spans), which is how the other side of a
  meeting was lost.
- **The tap's outage:** the tap's track is digital silence exactly from the
  end of its last buffer to its first one after the outage (2,214.920 to
  2,244.910 s of the file, found to within 21 ms), and its spans file has that
  gap, 2,214.898 to 2,244.921 s: 3.0 ms before the outage began, which is how
  early the track was by its device's drift at that moment, and 1.6 ms after
  its end (the first buffer after it goes where its IOProc was called); marker
  37, which fell in it, is missing from the tap's track and present in the
  backup's and in the mix. The monitor logged the tap's silence after 5 s
  and raised no warning (this tap is not rebuilt during the outage). It did
  not show "Call audio is not being recorded" either, as it did before there
  was a call tap: a call was on, and the call tap was recording it.
- **The call:** the call tap's source reported no call at the start, a call
  from 2,199.5 s and none from 2,260.5 s, and built one tap. Its track is
  digital silence from the start to 2,199.900 s of the file and from
  2,259.940 s to its end, and nowhere between; its spans file has the one
  span 2,199.901 to 2,259.912 s, 1.2 ms after the call's first buffer and its
  last (its buffers go where their IOProc was called). All four bursts of the
  call are in the call tap's track, 1.2 ms from their place; the two outside
  the outage are in the tap's track too (2.4 ms early and 1.5 ms late, its
  drift), the two inside it are not; none is in the backup's. No buffer of
  the call tap was refused by its track, and nothing in the log speaks of a
  tap of zeros.
- **Mix:** 5,249.9 s from the tap, 30.0 s from the backup in one stretch,
  2,214.898 to 2,244.921 s: the gap in the tap's spans and nothing else (the
  run fails when the backup is taken anywhere the tap was alive). The call
  tap's audio was added to the backup's in that same stretch and nowhere else
  (the run fails otherwise), so all four bursts of the call are in the mix,
  the two of the outage from the call tap, each within 2.5 ms of its place and
  0.1 ms of where its source has it. The offset
  between the tracks was not measured there, as intended: the simulation's
  system audio is bursts of a steady tone, which match themselves a period
  further on as well, in noise that each source has of its own (16 windows
  compared between tap and backup, one between call tap and tap, none
  counted), so the taps' audio went in as stamped. The check after the mix
  passed (with the Level Voices gains, 2 of 30 windows had the microphone
  alone, both audible in the mix; the one with system audio alone had it at
  its level); every marker of every source is in the mixed file
  within 0.1 ms of where it is in the recording, and the mixed track has no
  digital silence. Both spans files were removed afterwards.
- **Silence:** the microphone track is digital silence exactly where the
  microphone delivered nothing or was muted (10 s, 30 s, 60 s), to within the
  drift and one AAC frame, and nowhere else; the backup's track and the mix
  have none.
- **Monitor:** a microphone warning for the call app taking the microphone
  (shorter than 15 s: the status item only) and for the disconnect, notified
  with its all-clear; none for the mute, and none for the tap's outage, which
  the backup and the call tap covered (the log has it); the
  static slide's last frame was written again once a second (374 frames).
- **Killed at 45 minutes**, after the outage and the call, writer not
  finished: the file opened with its four audio tracks, recovery mixed it with
  the spans the run left (the outage from the backup and the call tap) and
  removed both spans files, and 2,694 s of the 2,699.9 s recorded were in it
  (the last 5.7 s of video, 10 s of the tap and of the backup, 7.4 s of the
  call tap's track and 6.2 to 6.8 s of microphone lost, in two runs; which
  fragment each track ends on differs from run to run); the two markers of
  the first clock jump and the four bursts of the call are in place in it.
- **Resources:** before there was a call tap, the whole run, mix and checks
  included, took 109 to 112 s (the mix of the 88 minutes 34 to 36 s, its
  first pass reading both system audio tracks included), and with Level
  Voices, which reads the audio tracks once more to measure them and runs the
  limiter, 124 to 125 s (the mix 48 s). With the call tap's track, which is
  encoded with the others, read for its levels before the mix and mixed in
  where it is taken, and with Level Voices: the mix took 51 to 53 s and the
  whole run 130 to 131 s (three runs): the system audio measured -26.7 LUFS
  and got +10.7 dB, the microphone -19.8 LUFS and +3.8 dB, the limiter took
  off 7.6 dB at most (the marker tones, half of full scale as recorded), and
  the check passed with those gains. Memory: 54 to 63 MB once the writer had
  caught up; 171 MB at most while it was fed about 120 times faster than
  real time.
