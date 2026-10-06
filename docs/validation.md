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

`Tools/test.sh` runs 141 tests in under half a minute, without the app, a screen
or a microphone. They compile the pipeline's own sources; the writer,
converter, mixer and recovery tests write real files with AVFoundation from
synthetic buffers and read them back.

| Area | Tests | What they cover |
| --- | ---: | --- |
| Microphone converter | 21 | Format changes (24 → 48 → 24 kHz, 44.1 kHz stereo), gaps as silence, jitter, a backlog with its own timestamps dropped where silence was filled with no offset after it, a lagging clock shifted, full-length track, silence generation |
| System audio and timeline | 7 | Placement at the end of what was written, holes filled past 0.1 s, pause offsets |
| Writer | 14 | One file with three tracks of the same length, pause, mute, a source that stops, late frames, no empty file, every audio format |
| Session | 17 | Every state in order, stop while starting, repeated stops, failures, quitting while recording, starting or exporting, pause and the timer |
| Monitor | 7 | Fills and warnings for each track, the start warning, late ticks, resume |
| Files, names, disk | 18 | Temporary and final names, leftovers, staging, free-space thresholds, a moved or deleted folder |
| Mixer and recovery | 11 | Mix and its checks, MP3 and package mixes, every recovery outcome |
| Settings | 7 | Keys, defaults and stored types of earlier installations |
| Status item | 7 | Every state's symbol, title and sentence, the timer text, the item's width, the call-audio warning |
| Package | 1 | `.qma` info files of earlier versions |
| Timestamps and length | 11 | The timeline never past the present: a tap buffer stamped 1100 s in the future near the end of a call recorded at its arrival time (through the writer and through the tap's source), audio stamped 40 s before its arrival, a frame or audio of unknown arrival in the future left out, fills and repeats cut off a second after the present, the stop's padding up to the video's end (sound only: the present), a mix whose audio is over 2 s longer or shorter than its video rejected and the recording kept unmixed |
| System audio tap | 17 | Build and teardown order against fake Core Audio calls, cleanup after each failed step, the IOProc's stream usage (only the tap's stream), the IOProc's copy (interleaved, non-interleaved, behind other input streams, turned-off streams, malformed lists), nothing handed on once the output device changes its rate, host-time stamps, conversion and resampling to 48 kHz stereo, the choice between tap and screen capture with its notice and warning, rebuilds on device changes with nothing of the old device after the new, retries, no endless rebuild from the tap's own aggregate device, a sound-only file written from the tap's buffers |

## Not yet checked on the real machine

Set in code and covered where a test can reach them, but not yet seen in a real
recording:

- The warning panel over a full-screen meeting.
- The app's floating windows on a full-screen Space.
- "Leave Holdfast's Own Windows Out" with windows that open during the
  recording.
- System audio through the Core Audio process tap: that it hears a FaceTime
  call (`Tools/tapprobe`, then a recording during a call), its permission
  prompt and what the permission reads as before and after, its format and
  rate on the built-in speakers and on AirPods in their call mode, the rebuild
  when the output device changes, and the sync of tap audio with the picture
  over a long recording. Also that the tap runs from its start while nothing
  plays (`tapprobe global 5` in silence: callbacks every second at -180 dB),
  and that with AirPods as the output the tap leaves their microphone closed,
  so they stay out of their call mode (the IOProc uses only the tap's stream).

## 90-minute simulation

This is a simulation of the pipeline with synthetic buffers, not a live
capture: `Tools/soak.sh` feeds the real writer, monitor, mixer and recovery
code as fast as they take it, on a simulated clock, without the app, the
screen or a microphone. The longest live recording measured is still six
minutes.

The simulated meeting runs 90 minutes, of which 2 are paused: 64 × 36 frames
at 5 fps with a time code in each, and a 5-minute static slide with no frames;
48 kHz stereo system audio with a tone every minute; a 24 kHz mono microphone
with its own tone every minute, whose clock runs 50 ppm fast, with irregular
buffer sizes and arrival. At 10 minutes a call app takes the microphone (10 s
with nothing, then 3 minutes at 48 kHz), at 33 minutes the AirPods disconnect
for 30 s, and the microphone is muted for 1 minute after the pause.

- **Lengths:** 88 minutes expected (5,279.9 s from the first frame). Video
  5,280.005 s, system audio 5,279.879 s, microphone 5,279.936 s; the mixed
  file the same. Every track within 0.11 s.
- **Sync, from the files:** the picture is where its time code says to the
  millisecond. System audio within 0.2 ms of its place until the pause and
  4.9 ms early after it. The microphone is late by its clock drift, up to
  68 ms, and back in place after each gap, pause or mute; the largest
  microphone-to-system offset is 71 ms. Each is less than the 0.1 s the
  writer allows before it corrects.
- **Silence:** the microphone track is digital silence exactly where the
  microphone delivered nothing or was muted (10 s, 30 s, 60 s), to within the
  drift and one AAC frame, and nowhere else. The system audio and the mixed
  track have none.
- **Mix:** the check after the mix passed (29 of 30 windows had the microphone
  alone, all audible in the mix); every marker of both sources is in the mixed
  file within 0.1 ms of where it is in the recording.
- **Monitor:** a microphone warning and its all-clear for the call and the
  disconnect, none for the mute; the static slide's last frame was written
  again once a second (379 frames).
- **Killed at 45 minutes**, writer not finished: the file opened, recovery
  mixed it, and 2,694 s of the 2,699.9 s recorded were in it (the last 5.9 s
  of video, 10 s of system audio and 8 s of microphone lost).
- **Resources:** the whole run, mix and checks included, took 95 s.
  Memory: 37 to 74 MB once the writer had caught up; up to 480 MB while it
  was fed about 180 times faster than real time.
