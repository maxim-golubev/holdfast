# What was measured

The measurements behind the claims in the [README](../README.md) and the design
in [architecture.md](architecture.md). They were taken on October 4, 2026, on
the developer's M-series MacBook Pro with macOS 15.7 and AirPods Pro 2.

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
- **Start while the previous recording was saving:** refused, with a message
  saying why.

## The menu bar item

Measured from a capture of the menu bar on a 2x display (a 4K display at
1920 × 1080 points, 24-point menu bar): the record symbol's ink and the timer
digits' ink are centred on the same pixel row (ring rows 11–35, digits 14–32
of the 48-row menu bar). The ring is drawn by the app rather than taken from SF
Symbols, because the symbol of that size is an even number of pixels tall and
sat half a pixel below the digits.

## Tests

`Tools/test.sh` runs 163 tests in about a minute (63 s measured), without the
app, a screen or a microphone. They compile the pipeline's own sources; the writer,
converter, mixer and recovery tests write real files with AVFoundation from
synthetic buffers and read them back.

| Area | Tests | What they cover |
| --- | ---: | --- |
| Microphone converter | 23 | Format changes (24 → 48 → 24 kHz, 44.1 kHz stereo), gaps as silence, jitter, a backlog with its own timestamps dropped where silence was filled with no offset after it (drained at 3, 1.1 and 1.05 times real time, held 13 s or 40 s), a lagging clock shifted, full-length track, silence generation |
| System audio and timeline | 7 | Placement at the end of what was written, holes filled past 0.1 s, pause offsets |
| Writer | 14 | One file with three tracks of the same length, pause, mute, a source that stops, late frames, no empty file, every audio format |
| Session | 17 | Every state in order, stop while starting, repeated stops, failures, quitting while recording, starting or exporting, pause and the timer |
| Monitor | 11 | Fills and warnings for each track, the start warning, late ticks, resume, a source that keeps dropping out notified once, a microphone back with only zeros not back, system audio missing only when neither the tap nor its backup delivers (a quiet tap only logged) |
| Files, names, disk | 18 | Temporary and final names, leftovers, staging, free-space thresholds, a moved or deleted folder |
| Mixer and recovery | 11 | Mix and its checks, MP3 and package mixes, every recovery outcome |
| Settings | 7 | Keys, defaults and stored types of earlier installations |
| Status item | 7 | Every state's symbol, title and sentence, the timer text, the item's width, the call-audio warning |
| Package | 1 | `.qma` info files of earlier versions |
| Timestamps and length | 13 | The timeline never past the present: a tap buffer stamped 1100 s in the future near the end of a call recorded at its arrival time (through the writer and through the tap's source), a frame and a tap buffer stamped 12 s ahead as a call connects (no video hole, no fill past the present, the microphone not shifted), a microphone stamped 400 s before its arrival, a microphone backlog 40 s old left to the converter, a frame or audio of unknown arrival in the future left out, fills and repeats cut off a second after the present, the stop's padding up to the video's end (sound only: the present), a mix whose audio is over 2 s longer or shorter than its video rejected and the recording kept unmixed |
| System audio tap | 19 | Build and teardown order against fake Core Audio calls with each clock (built-in output, no sub-device, default output) and the order of constructions, cleanup after each failed step, the IOProc's stream usage (only the tap's stream), the IOProc's copy (interleaved, non-interleaved, behind other input streams, turned-off streams, malformed lists), nothing handed on once the rate changes or the clock device goes away, host-time stamps, conversion and resampling to 48 kHz stereo, the choice between the tap with its backup and screen capture alone, with its notice and warning; the repair: a tap that hands on nothing rebuilt at once and the next construction after two failures, around and around, the waits (at once, then 0.5 s doubling to 10 s), a tap that cannot be built at the start built in the background, a rate change, nothing of an old tap after the new one, the real tap on fake hardware falling back from the built-in output to no sub-device to the default output, and a tap whose IOProc is never called; a sound-only file written from the tap's buffers |
| Backup of the system audio | 11 | The tap's spans and the choice of source stretch by stretch; three titled tracks and the spans through the real writer; today's meeting (the tap dead from 27 s to 28 s): the mix holds the backup exactly there and the tap elsewhere, the switches within 0.02 s; a tap dead from the start; FaceTime (backup silent) the tap's, both alive the tap's alone at its level, both dead silence; the check rejecting a mix without the system audio or with it twice; the microphone kept apart; a sound-only recording started by the backup and merged; a killed recording recovered with its spans |

## Not yet checked on the real machine

Set in code and covered where a test can reach them, but not yet seen in a real
recording:

- The warning panel over a full-screen meeting.
- The app's floating windows on a full-screen Space.
- "Leave Holdfast's Own Windows Out" with windows that open during the
  recording.
- System audio through the process tap with its backup, in a real recording:
  a FaceTime call (the tap was checked to hear one, 2026-10-05) and a browser
  call on AirPods that go to 24 kHz, the final file having the other side
  throughout; the tap clocked by the built-in output in such a recording (the
  constructions were measured with `Tools/tapexp`, below, not yet in the app);
  a tap that dies being rebuilt within about a second, with the log's lines and
  no warning; the backup's sound, from screen capture, in step with the tap's;
  its permission prompt and what the permission reads as before and after; the
  sync of tap audio with the picture over a long recording; that with AirPods
  as the output the tap leaves their microphone closed.

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
48 kHz stereo system audio with a tone every minute, from the process tap and,
with noise of its own and buffers arriving on their own schedule, from its
backup; a 24 kHz mono microphone with its own tone every minute, whose clock
runs 50 ppm fast, with irregular buffer sizes and arrival. At 10 minutes a call
app takes the microphone (10 s with nothing, then 3 minutes at 48 kHz), at 33
minutes the AirPods disconnect for 30 s, from 2,215 to 2,245 s the tap
delivers nothing (an outage, then the tap is back), and the microphone is
muted for 1 minute after the pause.

- **Lengths:** 88 minutes expected (5,279.9 s from the first frame). Video
  5,280.022 s, the tap's track 5,279.879 s, the backup's 5,279.857 s,
  microphone 5,279.952 s; the mixed file the same. Every track within 0.13 s.
- **Sync, from the files:** the picture is where its time code says to the
  millisecond. System audio within 0.2 ms of its place until the pause and
  21.3 ms early after it (one 1024-frame buffer, the pause's alignment, within
  the 0.1 s the writer allows; the tap's and the backup's markers lie within
  0.1 ms of each other). The microphone is late by its clock drift, up to
  68 ms, and back in place after each gap, pause or mute.
- **The tap's outage:** the tap's track is digital silence exactly from the
  end of its last buffer to its first one after the outage (2,214.919 to
  2,244.913 s of the file, found to within 21 ms), and its spans file has that
  gap to the sample; marker 37, which fell in it, is missing from the tap's
  track and present in the backup's and in the mix. The monitor logged the
  tap's silence after 5 s and its return, and raised no warning.
- **Mix:** 5,249.9 s from the tap, 30.0 s from the backup in one stretch,
  2,214.919 to 2,244.913 s. The check after the mix passed (29 of 30 windows had
  the microphone alone, all audible in the mix; the one with system audio alone
  had it at its level); every marker of every source is in the mixed file
  within 0.1 ms of where it is in the recording, and the mixed track has no
  digital silence. The spans file was removed afterwards.
- **Silence:** the microphone track is digital silence exactly where the
  microphone delivered nothing or was muted (10 s, 30 s, 60 s), to within the
  drift and one AAC frame, and nowhere else; the backup's track and the mix
  have none.
- **Monitor:** a microphone warning for the call (shorter than 15 s: the
  status item only) and for the disconnect, notified with its all-clear; none
  for the mute, and none for the tap's outage, which the backup covered (the
  log has it); the static slide's last frame was written again once a second
  (375 frames).
- **Killed at 45 minutes**, after the outage, writer not finished: the file
  opened, recovery mixed it with the spans the run left (the outage from the
  backup) and removed them, and 2,694 s of the 2,699.9 s recorded were in it
  (the last 5.9 s of video, 8 s of the tap, 10 s of the backup and 7 s of
  microphone lost).
- **Resources:** the whole run, mix and checks included, took 113 s (the mix
  of the 88 minutes about 37 s, its first pass reading both system audio
  tracks included). Memory: 61 to 71 MB once the writer had caught up; 180 to
  200 MB at most (two runs) while it was fed about 120 times faster than real
  time.
