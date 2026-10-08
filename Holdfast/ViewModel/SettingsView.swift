//
//  SettingsView.swift
//  Holdfast
//
//  Created by apple on 2024/4/19.
//

import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// The content of the Settings scene: standard tabs of grouped forms. Every control binds to `AppSettings`;
/// what the main panel and the selectors show as well comes from `RecordingControls.swift`.
struct SettingsView: View {
    var body: some View {
        TabView {
            tab("Recording", "record.circle") { RecordingSettings() }
            tab("Audio", "waveform") { AudioSettings() }
            tab("Output", "folder") { OutputSettings() }
            tab("Shortcuts", "keyboard") { ShortcutSettings() }
            tab("General", "gearshape") { GeneralSettings() }
        }
        .frame(width: 560, height: 540)
    }

    /// The rows show their titles only; the symbols of the shared controls are for the compact places
    private func tab(_ title: String, _ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        content()
            .formStyle(.grouped)
            .labelStyle(.titleOnly)
            .tabItem { Label(title, systemImage: symbol) }
    }
}

/// A row's title with a line of explanation under it, for rows whose meaning is not obvious
private struct RowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        Text(title)
        Text(detail)
    }
}

/// A sentence under a section, set like the rows above it
private struct SectionNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordingSettings: View {
    @AppStorage(AppSettings.$encoder)          private var encoder: Encoder
    @AppStorage(AppSettings.$videoFormat)      private var videoFormat: VideoFormat
    @AppStorage(AppSettings.$withAlpha)        private var withAlpha: Bool
    @AppStorage(AppSettings.$highlightMouse)   private var highlightMouse: Bool
    @AppStorage(AppSettings.$includeMenuBar)   private var includeMenuBar: Bool
    @AppStorage(AppSettings.$hideDesktopFiles) private var hideDesktopFiles: Bool
    @AppStorage(AppSettings.$hideSelf)         private var hideSelf: Bool
    @AppStorage(AppSettings.$hideCCenter)      private var hideCCenter: Bool
    @AppStorage(AppSettings.$preventSleep)     private var preventSleep: Bool

    var body: some View {
        Form {
            Section("Video") {
                Picker("Format", selection: $videoFormat) {
                    Text("MP4").tag(VideoFormat.mp4)
                    Text("MOV").tag(VideoFormat.mov)
                }
                .disabled(withAlpha)
                Picker(selection: $encoder) {
                    Text("H.264").tag(Encoder.h264)
                    Text("H.265 (HEVC)").tag(Encoder.h265)
                } label: {
                    RowLabel("Encoder", "H.265 makes files about half the size. H.264 plays on older devices.")
                }
                .disabled(withAlpha)
                VideoQualityPicker()
                FrameRatePicker()
                ResolutionPicker()
                CursorToggle()
                HDRToggle()
                Toggle(isOn: $withAlpha) {
                    RowLabel("Record with Alpha Channel", "Keeps transparency. Uses H.265 in a MOV file.")
                }
            }
            Section("On Screen") {
                Toggle("Leave Holdfast's Own Windows Out", isOn: $hideSelf)
                Toggle("Include the Menu Bar", isOn: $includeMenuBar)
                Toggle(isOn: $hideCCenter) {
                    RowLabel("Hide Control Center Icons", "The clock, Wi-Fi, Bluetooth, volume and the other system icons in the menu bar.")
                }
                Toggle("Hide Files on the Desktop", isOn: $hideDesktopFiles)
                Toggle(isOn: $highlightMouse) {
                    RowLabel("Highlight the Cursor", "A ring around the cursor. Not available when a single window is recorded.")
                }
            }
            ExcludedApps()
            Section {
                Toggle("Keep the Mac Awake While Recording", isOn: $preventSleep)
            }
        }
        .onChange(of: withAlpha) { _, alpha in
            if alpha { encoder = Encoder.h265; videoFormat = VideoFormat.mov }
        }
        // A running recording starts or stops listening to the mouse, once the setting is stored
        .onChange(of: highlightMouse) { DispatchQueue.main.async { AppDelegate.shared.updateRecordingMouseMonitor() } }
    }
}

/// The apps that are left out of screen and screen area recordings
struct ExcludedApps: View {
    @State private var apps = AppSettings.hiddenApps
    @State private var isShowingFilePicker = false

    var body: some View {
        Section {
            ForEach(apps, id: \.self) { app in
                LabeledContent(app.name) {
                    Button("Remove") { store(apps.filter { $0 != app }) }
                        .accessibilityLabel("Remove \(app.name)")
                }
            }
            Button("Add App…") { isShowingFilePicker = true }
                .fileImporter(isPresented: $isShowingFilePicker, allowedContentTypes: [.application]) { result in
                    guard let url = try? result.get(), let bundle = Bundle(url: url), let appID = bundle.bundleIdentifier else {
                        print("No application was chosen for the excluded apps")
                        return
                    }
                    // Each app once, whatever name an earlier version stored it under
                    guard !apps.contains(where: { $0.bundleID == appID }) else { return }
                    store(apps + [AppInfo(bundleID: appID, displayName: bundle.appName)])
                }
        } header: {
            Text("Excluded Apps")
        } footer: {
            SectionNote("These apps are left out of screen and screen area recordings. An app that is launched after the recording has started cannot be left out.")
        }
    }

    private func store(_ list: [AppInfo]) {
        apps = list
        AppSettings.hiddenApps = list
    }
}

struct AudioSettings: View {
    @AppStorage(AppSettings.$audioFormat)  private var audioFormat: AudioFormat
    @AppStorage(AppSettings.$audioQuality) private var audioQuality: AudioQuality
    @AppStorage(AppSettings.$remuxAudio)   private var remuxAudio: Bool
    @AppStorage(AppSettings.$keepUnmixed)  private var keepUnmixed: Bool
    @AppStorage(AppSettings.$levelVoices)  private var levelVoices: Bool
    @AppStorage(AppSettings.$micDeviceID)  private var micDeviceID: String
    @AppStorage(AppSettings.$recordMic)    private var recordMic: Bool
    @State private var micIsUnavailable = false

    private var isLossless: Bool { audioFormat == .alac || audioFormat == .flac }

    var body: some View {
        Form {
            Section("Sources") {
                SystemAudioToggle()
                MicToggle()
                MicPicker()
                if micIsUnavailable {
                    Label("The chosen microphone is not connected. Until it is back, a recording uses the system default microphone.", systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Tracks") {
                Toggle(isOn: $remuxAudio) {
                    RowLabel("Mix Microphone into the Main Track", "After a recording, system audio and microphone are mixed into one audio track, which every player plays; an audio-only recording gets the mix as a file next to its .qma package. Off: a video keeps system audio and microphone as two audio tracks, and an audio-only recording is only its .qma package, which plays in Holdfast.")
                }
                Toggle(isOn: $keepUnmixed) {
                    RowLabel("Keep the Unmixed Recording", "After a video recording, the recording as it was written stays next to the final file as \"<name> (unmixed, N audio tracks)\": system audio and microphone, and with the process tap also screen capture's system audio, recorded as its backup, and the call tap's track. After a sound-only recording with the process tap, its system audio files stay next to the one made from them. The .qma package of an audio-only recording is always kept.")
                }
            }
            Section("Loudness") {
                Toggle(isOn: $levelVoices) {
                    RowLabel("Level Voices", "In the mixed file of a video recording, the other side of the call and your microphone are each brought to the same loudness, the one spoken content is usually played at, and a limiter keeps the sum from clipping. The unmixed recording keeps every track as it was recorded.")
                }
            }
            Section("Encoding") {
                Picker(selection: $audioFormat) {
                    Text("AAC").tag(AudioFormat.aac)
                    Text("MP3").tag(AudioFormat.mp3)
                    Text("ALAC (Lossless)").tag(AudioFormat.alac)
                    Text("FLAC (Lossless)").tag(AudioFormat.flac)
                    Text("Opus").tag(AudioFormat.opus)
                } label: {
                    RowLabel("Format", "MP3 is for audio-only recordings and Opus needs a MOV file; otherwise the audio of a video is AAC.")
                }
                Picker("Quality", selection: $audioQuality) {
                    if isLossless { Text("Lossless").tag(audioQuality) }
                    Text("Normal (128 kbit/s)").tag(AudioQuality.normal)
                    Text("Good (192 kbit/s)").tag(AudioQuality.good)
                    Text("High (256 kbit/s)").tag(AudioQuality.high)
                    Text("Extreme (320 kbit/s)").tag(AudioQuality.extreme)
                }
                .disabled(isLossless)
            }
        }
        .onAppear { checkMicrophone() }
        .onChange(of: micDeviceID) { checkMicrophone() }
        .onChange(of: recordMic) { checkMicrophone() }
        .onReceive(MicSelection.devicesChanged) { checkMicrophone() }
    }

    private func checkMicrophone() {
        micIsUnavailable = recordMic && MicPicker.isUnavailable(MicSelection.selectedMicID(), among: MicSelection.getMicrophone())
    }
}

struct OutputSettings: View {
    @AppStorage(AppSettings.$saveDirectory)   private var saveDirectory: String
    @AppStorage(AppSettings.$showPreview)     private var showPreview: Bool
    @AppStorage(AppSettings.$trimAfterRecord) private var trimAfterRecord: Bool
    @AppStorage(AppSettings.$videoFormat)     private var videoFormat: VideoFormat

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Save Folder") {
                    Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(saveDirectory)
                    Button("Choose…") { chooseSaveFolder() }
                        .accessibilityLabel("Choose Save Folder")
                }
                LabeledContent {
                    Text(exampleName)
                } label: {
                    RowLabel("File Name", "The date and time the recording started. Not adjustable: recordings left by a crash are found by this name.")
                }
                LabeledContent("Recordings Folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: saveDirectory, isDirectory: true)) }
                        .accessibilityLabel("Show Recordings Folder")
                }
            }
            Section("After a Recording") {
                Toggle(isOn: $showPreview) {
                    RowLabel("Show a Preview", "A small floating picture of the recording for a few seconds, with its file name and folder. Click the picture to open the file; Done closes the preview and keeps the recording.")
                }
                Toggle("Open the Video Trimmer", isOn: $trimAfterRecord)
            }
            Section("Log") {
                LabeledContent {
                    Button("Open") { openLog() }
                        .accessibilityLabel("Open Recordings Log")
                } label: {
                    RowLabel("Recordings Log", "What happened to each recording: its start and stop, where it was saved, microphone switches and format changes, mute, track warnings, a summary of its microphone track, and every failure. Kept in ~/Library/Logs/Holdfast/recordings.log.")
                }
            }
        }
    }

    private var exampleName: String {
        let base = RecordingFileStore(directory: saveDirectory).newBase()
        return (base as NSString).lastPathComponent + "." + videoFormat.rawValue
    }

    private func chooseSaveFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.directoryURL = URL(fileURLWithPath: saveDirectory, isDirectory: true)
        if openPanel.runModal() == .OK, let path = openPanel.urls.first?.path { saveDirectory = path }
    }

    /// The log, or its folder while nothing has been written yet
    private func openLog() {
        guard let log = RecLog.url else { return }
        let target = FileManager.default.fileExists(atPath: log.path) ? log : log.deletingLastPathComponent()
        NSWorkspace.shared.open(target)
    }
}

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section("While Recording") {
                shortcut("Stop Recording", .stop)
                shortcut("Pause / Resume", .pauseResume)
                shortcut("Mute / Unmute Microphone", .muteMicrophone)
                shortcut("Save Current Frame", .saveFrame)
                shortcut("Toggle Screen Magnifier", .screenMagnifier)
            }
            Section {
                shortcut("Record System Audio", .startWithAudio)
                shortcut("Record Current Screen", .startWithScreen)
                shortcut("Record Topmost Window", .startWithWindow)
                shortcut("Select Area to Record", .startWithArea)
            } header: {
                Text("Start")
            } footer: {
                SectionNote("The first three start at once, without a countdown, and always with system audio.")
            }
            Section("App") {
                shortcut("Open Main Panel", .showPanel)
            }
        }
    }

    private func shortcut(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        LabeledContent(title) {
            KeyboardShortcuts.Recorder(for: name).accessibilityLabel(title)
        }
    }
}

struct GeneralSettings: View {
    @AppStorage(AppSettings.$showOnDock)  private var showOnDock: Bool
    @AppStorage(AppSettings.$showMenubar) private var showMenubar: Bool
    @AppStorage(AppSettings.$openPanelAtLaunch) private var openPanelAtLaunch: Bool
    @AppStorage(AppSettings.$showDuringScreenSharing) private var showDuringScreenSharing: Bool
    @AppStorage(AppSettings.$countdown)   private var countdown: Int
    @AppStorage(AppSettings.$notifications) private var notifications: Notifications
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Presence") {
                Toggle(isOn: $showMenubar) {
                    RowLabel("Show in the Menu Bar", "Its menu starts a recording and opens the main panel. During a recording the item is always there, with the time and Stop Recording.")
                }
                Toggle(isOn: $showOnDock) {
                    RowLabel("Show in the Dock", "Off (the default): Holdfast has no Dock icon and lives in the menu bar. Its windows still come to the front when they open.")
                }
                Toggle(isOn: $openPanelAtLaunch) {
                    RowLabel("Open the Panel When Holdfast Opens", "Off: Holdfast opens in the menu bar only. The panel still opens from the menu bar item, the Open Main Panel shortcut, or by opening Holdfast again. With neither a menu bar item nor a Dock icon it always opens.")
                }
                .help("Whether the main panel appears in the middle of the screen when you open Holdfast")
                Toggle(isOn: $showDuringScreenSharing) {
                    RowLabel("Show During Screen Sharing", "Off (the default): when you share your screen in a call, or another app records it, the others do not see Holdfast's menu bar item, panel, preview or settings. Holdfast's own recordings leave them out either way.")
                }
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    RowLabel("Launch at Login", "At login Holdfast waits in the menu bar; the panel does not open.")
                }
            }
            Section("Start") {
                LabeledContent {
                    Text(countdown == 0 ? "None" : String(format: "%d s", countdown))
                        .monospacedDigit()
                    Stepper("Countdown Before a Recording", value: $countdown, in: 0...99)
                        .labelsHidden()
                } label: {
                    RowLabel("Countdown Before a Recording", "Seconds counted down on screen after Start. A recording started directly by a shortcut begins at once.")
                }
            }
            Section("Notifications") {
                Picker(selection: $notifications) {
                    ForEach(Notifications.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Notifications", "A problem during a recording is notified once it has lasted 15 seconds, and then also shown on screen over every app; a shorter one only turns the menu bar item orange. Finished recordings are notified quietly, and only when no preview shows them. With None, problems are still shown in the menu bar and on screen.")
                }
                .help("Which notifications Holdfast posts")
            }
            Section("About") {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    LabeledContent("Version", value: version)
                }
                LabeledContent {
                    if let upstream = URL(string: "https://github.com/lihaoyun6/QuickRecorder") {
                        Link("Original Project", destination: upstream)
                    }
                } label: {
                    RowLabel("Based on QuickRecorder", "Holdfast is a modified version of QuickRecorder by lihaoyun6, modified in 2026 by Maxim Golubev, under the same GNU AGPL-3.0 license. It is not an official QuickRecorder release.")
                }
            }
        }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
        // Once the setting is stored
        .onChange(of: showMenubar) { DispatchQueue.main.async { StatusItemController.shared.refresh() } }
        .onChange(of: showDuringScreenSharing) { DispatchQueue.main.async { ScreenSharingPrivacy.apply() } }
        .onChange(of: showOnDock) { _, shown in
            if shown {
                NSApp.setActivationPolicy(.regular)
            } else {
                NSApp.setActivationPolicy(.accessory)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        var failure: Error?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error
        }
        // What the system says now, so that the switch never shows what was not done
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if enabled && status == .requiresApproval {
            // Holdfast was switched off in Login Items once; only the user can switch it on there again. The error
            // register() throws for it says the same in fewer words, so this is the one message.
            let answer = createAlert(level: .informational, title: "Launch at Login Needs Your Approval",
                                     message: "Holdfast is switched off in System Settings → General → Login Items. Switch it on there to have it open at login.",
                                     button1: "Open Login Items", button2: "Cancel").runInFront()
            if answer == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        } else if let failure {
            UserNotice.showAlertLater(title: enabled ? "Launch at Login Not Turned On" : "Launch at Login Not Turned Off", message: failure.localizedDescription)
        }
    }
}

extension KeyboardShortcuts.Name {
    static let startWithAudio = Self("startWithAudio")
    static let startWithScreen = Self("startWithScreen")
    static let startWithWindow = Self("startWithWindow")
    static let startWithArea = Self("startWithArea")
    static let screenMagnifier = Self("screenMagnifier")
    static let saveFrame = Self("saveFrame")
    static let pauseResume = Self("pauseResume")
    static let muteMicrophone = Self("muteMicrophone")
    static let stop = Self("stop")
    static let showPanel = Self("showPanel")
}
