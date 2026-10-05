<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/icon-dark.png">
    <img src="docs/images/icon-light.png" width="128" height="128" alt="Holdfast app icon">
  </picture>
</p>

# Holdfast

A meeting recorder for macOS. Holdfast is a modified version of [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) by lihaoyun6, the screen recorder built on ScreenCaptureKit; it is not an official QuickRecorder release.

It is narrowed to one job: recording 60 to 90 minute video meetings (screen, system audio and a Bluetooth microphone, mixed to one audio track) without losing any of it. It runs on macOS 15 or later on Apple Silicon, has no updater and makes no network requests.

## What it records

- A screen, a screen area, an application, a window, or system audio alone.
- System audio and the microphone as two tracks, mixed into one after the recording (Settings, Audio, "Mix Microphone into the Main Track").
- The menu bar item shows the elapsed time while recording; its menu has Stop Recording, Pause and Mute Microphone. The same menu is on the Dock icon.

Removed from upstream: the updater, iPhone/iPad recording, the camera and Presenter Overlay, GIF export, the background colour option and localizations (English only).

## Reliability

| Guarantee | How |
| --- | --- |
| The microphone keeps recording when a call app (Zoom, Meet, Teams) takes it | The microphone is captured through ScreenCaptureKit only, never through an audio engine tap, which goes silent for good when another app opens the microphone with voice processing. The device's changing format is converted to one continuous 48 kHz track. |
| The microphone follows the device | When AirPods disconnect, reconnect or the default input changes, the running recording switches device and says so in the log. |
| A crash, kill or power loss leaves a playable file | The movie is written in 10 second fragments, and a timer keeps every track fed (silence, or the last frame again) so fragments keep reaching the disk even when a source delivers nothing. |
| An interrupted recording is finished at the next launch | Files left under a temporary name are found, mixed, checked and renamed; one report lists what was recovered. Nothing is deleted. |
| The mix cannot cost you the recording | The mix is written under a temporary name and checked (tracks, length, and that the microphone is audible in it) before anything is renamed. The recording as written is kept next to it as "(unmixed, 2 audio tracks)". If the mix fails, that file is what you get, with a report. |
| A silent track is noticed while it happens | No microphone or system audio for 5 seconds, or only digital silence from the microphone for 20 seconds, turns the menu bar item into an orange warning and posts a notification; another one when the audio is back. |
| No silent failures | A start that cannot record what was asked for (no microphone, no permission, under 2 GB free) is refused with an alert. A write error, a full disk (under 500 MB) or a stream that dies stops the recording, closes the file and reports it. |
| Quitting never truncates | Quit while recording, saving or mixing waits for the final file. |

## Known limits

- **FaceTime call audio cannot be recorded.** macOS keeps it out of system audio capture, so no ScreenCaptureKit recorder gets the other side of a FaceTime call. Your own microphone is still recorded. Zoom, Meet, Teams and browser calls are captured.
- **A file that was never closed misses its end.** After a crash or kill, about the last 12 seconds are lost (one fragment plus the lag of the slowest track). While paused nothing reaches the disk, so the seconds just before a pause are only safe after resuming.
- In an audio-only recording, the system audio file and a FLAC or Opus microphone file (`.caf`) are not written in fragments and do not survive a crash.
- Only the current save folder is searched for interrupted recordings.
- A second recording cannot start until the first one's file is final.
- A muted microphone is recorded as silence; the system's microphone indicator stays on.

## Build

Requires Xcode 26 or later: the app icon is an Icon Composer document, which earlier versions cannot compile. The app runs on macOS 15 and later. There are no binary releases.

```
Tools/build.sh    # Release build into build/Build/Products/Release/Holdfast.app
Tools/test.sh     # logic tests, a few seconds, no app, screen or microphone needed
Tools/app_icon.sh # renders the README icons from Holdfast/Holdfast.icon
```

The project signs with the owner's development team; set your own team and bundle identifier in Xcode to build it yourself. A different bundle identifier means its own settings and its own Screen Recording and Microphone permissions.

## AppleScript

```applescript
tell application "Holdfast"
    record screen numbered 1
    record screen area
    record application named "Safari"
    record window titled "Notes" in application "Notes"
    record system audio microphone true
    mute microphone
    unmute microphone
    stop recording
    configure fps 30 quality 2 hires true cursor true sound true microphone true mic device "default" hdr false
end tell
```

- `record screen`, `record application` and `record window` without a parameter open the matching selector; `record screen area` always does. `record system audio` starts at once. Every record command returns an error when a recording is already running or still being saved, and one that names a screen, application or window it cannot record shows "Failed to Record".
- `stop recording` returns at once and the file is saved in the background: wait until the menu bar item no longer says "Saving" (or, right after launch, "Recovering"). It also cancels a countdown and does nothing when idle.
- `mute microphone` and `unmute microphone` return an error when no recording with a microphone is running.
- `configure` takes any subset of its parameters; `mic device` must name a connected input.

## Log

`~/Library/Logs/Holdfast/recordings.log` (Settings, Output, "Recordings Log") has one line per event: microphone device switches and format changes, mute and unmute, track warnings, and a summary of the microphone track for every recording (buffers written and dropped, seconds of silence filled, loudest peak).

## Credits and license

- [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) by lihaoyun6: the original app, of which Holdfast is a modified version. Its recording engine began from [Azayaka](https://github.com/Mnpn/Azayaka) by Mnpn.
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus: global shortcuts.
- [SwiftLAME](https://github.com/hidden-spectrum/SwiftLAME) by Hidden Spectrum: MP3 output.

Licensed under the [GNU AGPL-3.0](./LICENSE), like the original. Copyright © 2024 lihaoyun6; modifications by Maxim Golubev.
