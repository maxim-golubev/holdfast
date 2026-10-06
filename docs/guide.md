# Using Holdfast

Everything the app does for a meeting recording and where it keeps things. How
it works inside is in [architecture.md](architecture.md); what was measured is
in [validation.md](validation.md).

## Before the first meeting

Holdfast is a menu bar app: it has an item in the menu bar, no Dock icon, and
opens no window when it starts. Click the item for its menu; **Open Main
Panel** there shows the panel with what to record and the recording options.
**Settings → General** can add the Dock icon back, open the panel whenever
Holdfast opens, or hide the menu bar item between recordings (see
[Settings that matter for meetings](#settings-that-matter-for-meetings)).

Holdfast needs three permissions. macOS asks for **Screen Recording** at the
first launch; allow it under **System Settings → Privacy & Security → Screen &
System Audio Recording** and open Holdfast again, since macOS applies it only
to a new launch. A start without it explains this and quits. The **Microphone**
permission is asked for when **Record Microphone** is first turned on, or at the
first start that wants the microphone.

The third is **System Audio Recording**. The first time a recording with system
audio starts, macOS asks whether Holdfast may record the sound the Mac plays
("Holdfast records the sound your Mac plays, including calls, so both sides of a
meeting are in the recording."); the recording starts once you answer. Allow
it: Holdfast then records system audio through a Core Audio process tap, which
hears FaceTime calls and phone calls taken on the Mac. Screen capture's own
system audio leaves those out. If you don't allow it, the recording still has
system audio, from screen capture, and a notification, **Call Audio Not
Included**, says once while Holdfast runs, when such a recording has started,
that the other side of a FaceTime or phone call will be missing. To change your answer later, turn Holdfast on under
**System Settings → Privacy & Security → Screen & System Audio Recording →
System Audio Recording Only**; it applies from the next recording.

Then check three settings once:

- **Record Microphone** is off until you turn it on, in the panel's recording
  options or under **Settings → Audio**. **Record System Audio** is on.
- **Microphone** (next to it) is **System Default**, which follows the input
  chosen in System Settings, or a device you name, such as your AirPods.
- **Settings → Output → Save Folder** is the Desktop until you choose another.

## Starting a recording

- **The panel.** **Open Main Panel** in the menu bar item's menu, the **Open
  Main Panel** shortcut, or opening Holdfast again while it runs (from Finder,
  Spotlight, or the Dock icon if you turned it on) shows the main panel with
  five tiles: **System Audio**, **Screen**, **Screen Area**,
  **Application** and **Window**. For a meeting, choose **Screen**, click the
  screen the meeting is on, and press **Start**. The bar under the screens
  repeats the options that matter (resolution, frame rate, quality, HDR,
  cursor, system audio, microphone and its device), and the timer button next
  to Start stops the recording by itself after a number of minutes (0 is no
  limit). **System Audio** records sound only, without a picture. The system
  audio of an **Application** or **Window** recording is every app's sound, not
  only that app's: call audio is played by macOS itself, not by the call's app
  (see [System audio and calls](#system-audio-and-calls)).
- **The menu bar.** The menu bar item's menu has **Open Main Panel** and the
  same five starts. With **Show in the Dock** on, the Dock icon's menu is the
  same menu.
- **Shortcuts.** None are set until you choose them under **Settings →
  Shortcuts**. **Record Current Screen** (the screen with the pointer), **Record
  Topmost Window** and **Record System Audio** start at once, without a
  countdown, and always with system audio; **Select Area to Record** opens the
  area selector.

**Settings → General → Countdown Before a Recording** shows that many seconds
on screen before a start from the panel, the menu, or a script command that
names a screen, application or window; its **Cancel** button, the **Stop
Recording** shortcut or `stop recording` calls the start off. The shortcuts
that start a recording, and `record system audio`, begin at once. A start is
refused with a message while the previous recording is still being saved: a
second recording can only start once the first one's files are final.

If **Record Microphone** is on and the microphone cannot be recorded (no
permission, no input device), the start stops at **Microphone Not Available**,
with **Cancel** as the default: a microphone track cannot be added once the
recording runs. **Record Without Microphone** goes on without one. If the device
you chose is not connected, the recording uses the system default microphone
and a notification names both.

## What the menu bar item shows

During a recording the menu bar item is always there, even with **Show in the
Menu Bar** off.
Each state has its own symbol, never only a colour:

| Symbol | Next to it | State |
| --- | --- | --- |
| A ring around a dot (red) | the time | Recording |
| A crossed-out microphone (red) | the time | Recording, microphone muted |
| A pause symbol | the time, standing still | Paused |
| A triangle (orange) | the time | Recording, but a track is not being recorded |
| A dotted circle | Starting | The capture is starting |
| An arrow into a tray | Saving | The file is being closed and its audio mixed |
| Two circling arrows | Recovering | A recording an earlier run did not finish is being mixed |
| An arrow out of a tray | Exporting | A file you exported is being written |

When more than one applies, paused comes before the warning, and the warning
before muted. The time is the length of the recording so far, without the time
spent paused: "07:05", then "1:07:05" from the first hour.

Clicking the item opens its menu. While recording: **Stop Recording** first,
then **Pause Recording** / **Resume Recording**, **Mute Microphone** / **Unmute
Microphone**, and a status line: "Recording — microphone OK", "microphone
silent" (nothing, or only digital zeros, in the last half second), "microphone
muted" or "no microphone". While saving, the line says "Saving the recording",
then "Mixing the audio tracks of the recording" with a percentage. Clicking the
item never stops a recording by itself, and **Quit Holdfast** is not in the menu
while recording.

## The microphone warning and mute

Holdfast watches its tracks while it records. Any of these turns the item into
the orange triangle, with the problem in the menu's status line, and writes a
line in the log:

- **Microphone Is Not Being Recorded:** no audio from the microphone for 5
  seconds, or nothing but digital silence for 20 seconds.
- **System Audio Is Not Being Recorded:** no system audio for 5 seconds.
- **Nothing Is Being Recorded Yet:** no picture 5 seconds after the start (a
  minimized window, a sleeping display). The file starts with the first picture;
  audio before it is not in it.

The recording goes on, with silence in place of the missing audio, so the
tracks stay in step. A short problem stays in the menu bar: a call app taking
the microphone for a few seconds, for example, turns the item orange until the
audio is back, and nothing else. A problem that has lasted 15 seconds (counted
from when the audio stopped, so 10 seconds after the item turned orange; at
once for 20 seconds of digital silence) also posts one notification and is
shown in a small panel at the top right of the screen with the pointer, over
every app and every Space, a full-screen meeting included: the meeting hides
the menu bar, and macOS holds back notifications while the screen is shared.
The panel is not captured in the recording. Its close button hides it until the
warning changes. When the audio is back, the warning clears, and a second
notification says so if the first one was posted.

**Mute Microphone** (menu, shortcut, or `mute microphone`) records silence in
place of the microphone until you unmute; the track stays as long as the
recording, and a muted microphone raises no warning. macOS keeps showing its
microphone indicator, because the device stays open. Mute and pause work only
while recording, not while starting or saving.

When the microphone device changes during a recording (AirPods connected or
disconnected, the system input changed, the chosen device gone or back), the
recording switches to the device that should be used now and goes on. A switch
macOS refuses is tried again three times, two seconds apart.

## Stopping

**Stop Recording** in the menu, the **Stop Recording** shortcut, `stop
recording`, or the timer all stop the same way. The item says **Saving** while
the file is closed and its audio mixed; for a long meeting the mix takes a while,
with its percentage in the menu. Then a preview of the recording appears at the
bottom right of the screen for a few seconds: its first frame (click it to open
the file), its file name, and where it was saved (**Saved to Desktop**). The
folder button shows it in Finder. **Done** only closes the preview; the
recording is kept. Nothing on the preview removes the recording: **Move to
Trash…** is only in its context menu (Control-click), and asks first, naming
the file. Hold the pointer on the preview to keep it open. With
**Settings → Output → Show a Preview** off, the item simply goes back to idle;
with **Notifications** set to **Problems and Finished Recordings** a quiet
**Recording Completed** notification (no sound) says where the file is.

Quitting during a recording (from the Dock icon, at logout, or with `kill`) stops it
and quits only once the final file is there. So does quitting while a recording
from an earlier run is being recovered or an export is being written.

A recording also stops by itself, and says why in **Recording Stopped Early**,
when it cannot go on: the disk has less than 500 MB free, the file cannot be
written, its file or folder was deleted, or the capture ended. What was recorded
up to then is kept, unless its file was deleted. A recording is not started
with less than 2 GB free.

A stop within 3 seconds of the start that recorded nothing is a cancelled start:
no file, no message, a line in the log. Any other stop before the first picture
is **Recording Not Saved**, and no empty file is left.

## Files

Recordings are named by the date and time they started, in the save folder:

| File | What it is |
| --- | --- |
| `Recording at 2026-10-04 14.03.22.mp4` | The recording, with system audio and microphone mixed into one audio track. This is the file to keep. |
| `Recording at 2026-10-04 14.03.22 (unmixed, 2 audio tracks).mp4` | The same recording as it was written: system audio is the first audio track, the microphone the second. Many players play only the first. |
| `Recording at 2026-10-04 14.03.22.recording.mp4` | A recording that is still running, or one a crash left behind. |
| `Recording at 2026-10-04 14.03.22.mixing.mp4` | A mix being written. It gets the final name only once it is complete and checked. |

The mix is checked before anything is renamed: one video and one audio track,
the same length as the recording to within a second, and the microphone audible
in the mix wherever it was alone in the recording. If the mix fails, **Audio
Mix Failed** says so and the recording is kept as the "(unmixed, 2 audio
tracks)" file, which has everything. Turn off **Settings → Audio → Keep the
Unmixed Recording** to have it deleted after a successful mix. With **Mix
Microphone into the Main Track** off, a video is written under its final name
with the two audio tracks separate.

**Recovered files.** At launch, Holdfast looks in the current save folder for
files an earlier run left under a `.recording.` or `.mixing.` name, gives each
a name that says what it is, and lists them in one **Recording Recovered**
report. No recording is deleted.

- A recording that was never closed (a crash, a kill, a power loss) plays,
  missing up to about its last 12 seconds. Its mix becomes
  `… (recovered).mp4`, and the recording as written
  `… (recovered, unmixed, 2 audio tracks).mp4`.
- A recording that was closed but not yet mixed is mixed now and gets the
  ordinary names.
- A file that does not open becomes `… (damaged)`. What an interrupted mix had
  written becomes `… (incomplete mix)` and can be deleted.

The menu bar item says **Recovering** while this runs; you can record
meanwhile.

**Sound only.** **System Audio** writes one audio file (`.m4a` in the default
AAC format, as set under **Settings → Audio → Format**). With the microphone it
writes a `.qma` package, which holds system audio and microphone as two files
and opens in Holdfast's player, and with **Mix Microphone into the Main Track**
on, a mixed audio file next to it.

**Save Current Frame** (a shortcut) saves the picture the recording shows as
`Capturing at <date>.png` in the save folder.

## Settings that matter for meetings

- **Audio:** **Record Microphone** on, the **Microphone** device, **Mix
  Microphone into the Main Track** (on) and **Keep the Unmixed Recording** (on).
- **Recording:** **Keep the Mac Awake While Recording** (on). The video
  defaults are chosen for long meetings: MP4, H.265 on Apple Silicon, medium
  quality, 30 frames a second, the display's full resolution. H.264 plays on
  older devices and makes larger files.
- **Recording → On Screen:** **Leave Holdfast's Own Windows Out** (on) keeps
  Holdfast's windows out of the picture.
- **Recording → Excluded Apps:** apps left out of screen and screen area
  recordings; one launched after the start cannot be left out.
- **Output:** **Save Folder**, **Show a Preview**, and **Recordings Log**, which
  opens the log.
- **General:** **Show in the Menu Bar** (on), **Show in the Dock** (off),
  **Open the Panel When Holdfast Opens** (off: Holdfast opens in the menu bar
  only; with neither a menu bar item nor a Dock icon the panel always opens),
  **Launch at Login** (the panel does not open at login), **Countdown Before a
  Recording**, and **Notifications**:
  - **Problems Only** (the default): a track problem that has lasted 15
    seconds and its end, a failure, a microphone that is not connected, call
    audio not included.
  - **Problems and Finished Recordings**: also one quiet notification when a
    recording is saved and no preview shows it, and when a clip or an export
    is saved.
  - **None**: no notifications. Problems still turn the menu bar item orange
    and, after 15 seconds, show the panel on screen; failures still show an
    alert.

  Routine events (permission answers, the start, tap rebuilds, device
  switches) are only in the log.

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

- `record screen`, `record application` and `record window` without a
  parameter open the matching selector; `record screen area` always does.
  `record system audio` starts at once; `microphone` applies to that recording
  only. Every record command returns an error while a recording runs or is
  being saved, and one that names a screen, application or window it cannot
  find shows **Failed to Record**.
- `stop recording` returns at once and the file is saved in the background. It
  also cancels a countdown, and does nothing when idle. With the audio mixed,
  the file is final once no `.recording.` or `.mixing.` file is left in the
  save folder.
- `mute microphone` and `unmute microphone` each say what the track is to be,
  so running one twice changes nothing; both return an error when no
  recording with a microphone is running.
- `configure` takes any of its parameters and returns an error while
  recording. `quality` is 1 (low), 2 (medium) or 3 (high); `mic device` must
  name a connected input, or "default".

A meeting recorded from a script, stopped after 90 minutes:

```applescript
tell application "Holdfast"
    configure sound true microphone true mic device "default"
    record screen numbered 1
end tell
delay 90 * 60
tell application "Holdfast" to stop recording
```

## System audio and calls

System audio is everything the Mac plays except Holdfast itself, taken from a
Core Audio process tap. You keep hearing it as usual. When the output device
changes during a recording (headphones plugged in or out, AirPods connecting or
switching to their call mode), the tap is rebuilt on the new device within
about a second; the moment in between is recorded as silence, and the log
says so. A rebuild that fails is tried three more times, two seconds apart;
after that, **System Audio Is Not Being Recorded** warns you as for any silent
track, and the tap is tried again when the output device changes.

When the tap cannot be used (no permission, or macOS refuses it), the system
audio comes from screen capture for that recording, as before, without call
audio, and the log says why. The **Call Audio Not Included** notification
comes once while Holdfast runs, for the first recording that started that way.
When the tap fails although it is allowed, the recording also shows **Call
audio is not being recorded** as its warning for as long as it runs: in the
menu bar and on screen, so you see it during the meeting even while sharing
your screen.

The tap records everything the Mac plays, whatever the recording shows: an
**Application** or **Window** recording has the sound of every app, its
notifications included. FaceTime and phone calls are played by a part of macOS,
not by the app on screen, so a tap of only the recorded app would leave the
call out.

## The log

`~/Library/Logs/Holdfast/recordings.log` (**Settings → Output → Recordings
Log**) has one line per event, with the time: each recording's start (its file,
what it records, whether system audio and microphone are on, and whether system
audio comes from the process tap, on which output device and in which format, or
from screen capture and why) and its video settings; every rebuild of the tap; its stop, with the reason when it stopped by itself; where it was
saved; microphone device switches and format changes; microphone audio that
came in late (a backlog dropped, or a microphone clock found to lag and recorded
that much late); system audio or microphone buffers whose timestamps were
too far from when they arrived to be believed, which are recorded at their
arrival time instead, and anything left out for lying in the future; mute and
unmute; every
track warning and its end; every failure that was reported; and at the end of
each recording with a microphone, a summary of its microphone track: buffers
received, written, dropped, failed and all zero, seconds of audio, seconds of
silence filled, format changes, the loudest peak, and the device's last format.
After a meeting, that summary says whether anything went missing.

## Known limits

- Call audio from FaceTime and from phone calls taken on the Mac is recorded
  through the process tap; this has not yet been checked on a real FaceTime
  call. Without the System Audio Recording permission it is missing (screen
  capture leaves it out); your own microphone is recorded either way. Calls in
  other apps and in browsers are system audio like any other sound.
- A file that was never closed misses up to about its last 12 seconds (one
  10-second fragment plus the lag of the slowest track). While paused, nothing
  reaches the disk, so the seconds before a pause are safe only once the
  recording resumes.
- In a sound-only recording, the system audio file, and a FLAC or Opus
  microphone file, are not written in fragments and do not survive a crash.
- Only the current save folder is searched for interrupted recordings.
- If macOS never answers the start of a capture, the item stays at
  **Starting**: a stop is remembered, quitting waits, and only Force Quit ends
  it.
- With QuickRecorder installed too, Finder may open `.qma` packages in it.
  Holdfast opens them as well: choose Holdfast under **Get Info → Open with**
  and click **Change All**.
