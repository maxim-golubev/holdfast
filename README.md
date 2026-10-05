> **Note:** this is a modified personal fork of [lihaoyun6/QuickRecorder](https://github.com/lihaoyun6/QuickRecorder), distributed under the same [AGPL-3.0](./LICENSE) license. It targets macOS 15+ on Apple Silicon, has no auto-updater and makes no network requests. For official releases, use the upstream project.

<p align="center">
<img src="./QuickRecorder/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="200" height="200" />
<h1 align="center">QuickRecorder</h1>
<h3 align="center">A lightweight and high-performance screen recorder for macOS</h3>
</p>

## Screenshot
<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./img/preview_en_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./img/preview_en.png">
  <img alt="QuickRecorder Screenshots" src="./img/preview_en.png" width="840"/>
</picture>
</p>

## Installation and Usage
### System Requirements:
- macOS 15.0 and later

### Install:
This fork has no binary releases. Build it from source with `Tools/build.sh` (requires Xcode); the app is written to `build/Build/Products/Release/`.

### Features/Usage:
- You can use QuickRecorder to record your screens / screen areas / windows / applications, or system audio alone.

- QuickRecorder supports driver-free audio loopback recording, mouse highlighting, screen magnifier and many more useful features.  
- QuickRecorder is able to record `HEVC with Alpha` video format, that can contain alpha channel in the output file *(currently only iMovie and FCPX support this feature)*  

## Q&A
**1. Where can I reopen the main panel after closing it?**
> Click the Dock tile of QuickRecorder, or "Open Main Panel" in its menu bar item, to reopen the main panel at any time. While recording, the menu bar item shows the elapsed time, and its menu has Stop Recording, Pause and Mute Microphone.

**2. Why does QuickRecorder not a sandbox app?**
> QuickRecorder has no plans to be uploaded to the App Store, so it does not need to be designed as a sandbox app.  

**3. How to independently control the volume of system sound and sound from microphone in other video editor?**
> QuickRecorder will merge the audio input from the microphone to the main audio track after recording by default. If you need to edit the video, you can turn off the `Record Microphone to Main Track` option in the settings panel. After turning off, the system sound and sound from microphone will be recorded into two audio tracks and can be edited independently.  

## Thanks
[Azayaka](https://github.com/Mnpn/Azayaka) @Mnpn
> The source of inspiration and part of the code of the screen recording engine comes from the Azayaka project, and I am also one of the code contributors to this project

[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) @sindresorhus  
> QuickRecorder uses this swift library to handle shortcut key events  

[SwiftLAME](https://github.com/hidden-spectrum/SwiftLAME) @Hidden Spectrum
> QuickRecorder uses this swift library to handle MP3 output

[ChatGPT](https://chat.openai.com) @OpenAI
> Note: Part of the code in this project was generated or refactored using ChatGPT.
