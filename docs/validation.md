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
digits' ink were centred on the same pixel row. Centred that way, the ring
still looked low beside the digits, as a circle centred on text does, so every
symbol beside the time is now drawn half a point (one pixel at 2x) higher.

## Tests

`Tools/test.sh` runs 106 tests in under half a minute, without the app, a screen
or a microphone. They compile the pipeline's own sources; the writer,
converter, mixer and recovery tests write real files with AVFoundation from
synthetic buffers and read them back.

| Area | Tests | What they cover |
| --- | ---: | --- |
| Microphone converter | 18 | Format changes (24 → 48 → 24 kHz, 44.1 kHz stereo), gaps as silence, jitter, late buffers dropped then shifted, full-length track, silence generation |
| System audio and timeline | 7 | Placement at the end of what was written, holes filled past 0.1 s, pause offsets |
| Writer | 14 | One file with three tracks of the same length, pause, mute, a source that stops, late frames, no empty file, every audio format |
| Session | 17 | Every state in order, stop while starting, repeated stops, failures, quitting while recording, starting or exporting, pause and the timer |
| Monitor | 7 | Fills and warnings for each track, the start warning, late ticks, resume |
| Files, names, disk | 18 | Temporary and final names, leftovers, staging, free-space thresholds, a moved or deleted folder |
| Mixer and recovery | 11 | Mix and its checks, MP3 and package mixes, every recovery outcome |
| Settings | 7 | Keys, defaults and stored types of earlier installations |
| Status item | 6 | Every state's symbol, title and sentence, the timer text, the item's width |
| Package | 1 | `.qma` info files of earlier versions |

## Not yet checked on the real machine

Set in code and covered where a test can reach them, but not yet seen in a real
recording:

- The warning panel over a full-screen meeting.
- The app's floating windows on a full-screen Space.
- "Leave Holdfast's Own Windows Out" with windows that open during the
  recording.
- The menu bar symbols at that higher position.
- A 90-minute recording. The longest measured here is six minutes.
