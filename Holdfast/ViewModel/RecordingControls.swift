//
//  RecordingControls.swift
//  Holdfast
//
//  The controls for what a recording captures. The settings window, the main panel and the selectors all show
//  these views, so a setting has one control, one wording and one binding wherever it appears.
//

import SwiftUI
import AVFoundation
import Combine

/// A control's title with its symbol, which has the same width in every row so that the titles line up
struct ControlLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, _ symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).frame(width: 18)
        }
    }
}

// MARK: - Microphone

extension MicSelection {
    /// Fires on the main thread when a capture device is connected or disconnected, so that what a view shows
    /// of the microphones follows them. These are notifications only; nothing is opened.
    static var devicesChanged: AnyPublisher<Void, Never> {
        let center = NotificationCenter.default
        return center.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: center.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .map { _ in () }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }
}

/// "Record Microphone". Asks for the permission when it is switched on, in the view the user switched it in.
struct MicToggle: View {
    @AppStorage(AppSettings.$recordMic) private var recordMic: Bool
    @State private var hasDevices = !MicSelection.getMicrophone().isEmpty

    var body: some View {
        Toggle(isOn: Binding(get: { recordMic }, set: { isOn in
            recordMic = isOn
            if isOn { Task { await MicSelection.performMicCheck() } }
        })) {
            ControlLabel("Record Microphone", "mic.fill")
        }
        .disabled(!hasDevices)
        .help(hasDevices ? "Record the microphone along with the recording" : "No microphone is connected")
        .onAppear { hasDevices = !MicSelection.getMicrophone().isEmpty }
        .onReceive(MicSelection.devicesChanged) { hasDevices = !MicSelection.getMicrophone().isEmpty }
    }
}

/// The microphone menu. The selection is the device's uniqueID, or "default" for the system default input.
/// A selected device that is not connected stays selected and is listed as unavailable. The menu is disabled
/// while "Record Microphone" is off, wherever it is shown.
struct MicPicker: View {
    @State private var devices = MicSelection.getMicrophone()
    @AppStorage(AppSettings.$recordMic) private var recordMic: Bool
    @AppStorage(AppSettings.$micDeviceID) private var micDeviceID: String
    @AppStorage(AppSettings.$micName) private var micName: String

    /// Whether the chosen device is not connected now
    static func isUnavailable(_ id: String, among devices: [AVCaptureDevice]) -> Bool {
        return id != "default" && !devices.contains(where: { $0.uniqueID == id })
    }

    var body: some View {
        Picker("Microphone", selection: $micDeviceID) {
            Text("System Default").tag("default")
            ForEach(devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(device.uniqueID)
            }
            if MicPicker.isUnavailable(micDeviceID, among: devices) {
                Text(String(format: "%@ (unavailable)", micName == "default" ? micDeviceID : micName)).tag(micDeviceID)
            }
        }
        .disabled(!recordMic)
        .help("The microphone to record. \"System Default\" follows the input chosen in System Settings.")
        .onAppear {
            devices = MicSelection.getMicrophone()
            micDeviceID = MicSelection.selectedMicID()
        }
        .onReceive(MicSelection.devicesChanged) { devices = MicSelection.getMicrophone() }
        .onChange(of: micDeviceID) { _, id in
            // The name is stored next to the ID so that the device can still be named while it is absent
            if id == "default" {
                micName = "default"
            } else if let device = devices.first(where: { $0.uniqueID == id }) {
                micName = device.localizedName
            }
        }
    }
}

// MARK: - Video

struct ResolutionPicker: View {
    @AppStorage(AppSettings.$highRes) private var highRes: Int

    var body: some View {
        Picker("Resolution", selection: $highRes) {
            Text("Full (display pixels)").tag(2)
            Text("Standard (1x)").tag(1)
            // A value stored by an earlier version or a script
            if highRes != 1 && highRes != 2 {
                Text(AppSettings.recordsPixels(highRes) ? "Full (display pixels)" : "Standard (1x)").tag(highRes)
            }
        }
        .help("Full records every pixel of the display. Standard records at 1x, a quarter of the pixels of a Retina display, and makes smaller files.")
    }
}

struct FrameRatePicker: View {
    @AppStorage(AppSettings.$frameRate) private var frameRate: Int
    private static let rates = [240, 144, 120, 90, 60, 30, 24, 15, 10]

    var body: some View {
        Picker("Frame Rate", selection: $frameRate) {
            if !FrameRatePicker.rates.contains(frameRate) {
                Text("\(frameRate) FPS").tag(frameRate)
            }
            ForEach(FrameRatePicker.rates, id: \.self) { rate in
                Text("\(rate) FPS").tag(rate)
            }
        }
        .help("Frames per second. 30 is enough for meetings and slides.")
    }
}

struct VideoQualityPicker: View {
    @AppStorage(AppSettings.$videoQuality) private var videoQuality: Double

    var body: some View {
        Picker("Quality", selection: $videoQuality) {
            Text("High").tag(1.0)
            Text("Medium").tag(0.7)
            Text("Low").tag(0.3)
            // Any other stored value is recorded as high
            if ![1.0, 0.7, 0.3].contains(videoQuality) {
                Text("High (custom)").tag(videoQuality)
            }
        }
        .help("The video bitrate. Higher quality makes larger files.")
    }
}

struct CursorToggle: View {
    @AppStorage(AppSettings.$showMouse) private var showMouse: Bool

    var body: some View {
        Toggle(isOn: $showMouse) { ControlLabel("Record Cursor", "cursorarrow") }
            .help("Show the mouse cursor in the recording")
    }
}

struct HDRToggle: View {
    @AppStorage(AppSettings.$recordHDR) private var recordHDR: Bool

    var body: some View {
        Toggle(isOn: $recordHDR) { ControlLabel("Record HDR", "sparkles.square.filled.on.square") }
            .help("Record in HDR. Always uses H.265 and doubles the bitrate.")
    }
}

struct SystemAudioToggle: View {
    @AppStorage(AppSettings.$recordWinSound) private var recordWinSound: Bool

    var body: some View {
        Toggle(isOn: $recordWinSound) { ControlLabel("Record System Audio", "speaker.wave.2.fill") }
            .help("Record what the Mac plays. A recording started with a shortcut always has it.")
    }
}

// MARK: - The selectors' controls

/// The recording options as the selectors show them, next to their Start button
struct OptionsView: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Resolution")
                    ResolutionPicker()
                }
                GridRow {
                    Text("Frame Rate")
                    FrameRatePicker()
                }
                GridRow {
                    Text("Quality")
                    VideoQualityPicker()
                }
            }
            .labelsHidden()
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HDRToggle()
                CursorToggle()
                SystemAudioToggle()
                HStack(spacing: 6) {
                    MicToggle().labelStyle(.iconOnly)
                    MicPicker().labelsHidden().frame(maxWidth: 160)
                }
            }
            .toggleStyle(.checkbox)
        }
        .controlSize(.small)
        .fixedSize()
    }
}

/// A large symbol over its caption: Refresh, Start, Cancel
struct SymbolButton<Icon: View>: View {
    let title: String
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}

extension SymbolButton where Icon == AnyView {
    init(_ title: String, symbol: String, color: Color, help: String, action: @escaping () -> Void) {
        self.init(title: title, help: help, action: action) {
            AnyView(Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(color))
        }
    }
}

/// The timer button of a selector: the recording stops by itself after this many minutes, 0 for never
struct AutoStopButton: View {
    @Binding var minutes: Int
    @State private var isShowing = false
    static let range = 0...1440

    /// What the field and the stepper edit: a typed number outside the range becomes its nearest end
    private var limited: Binding<Int> {
        Binding(get: { minutes }, set: { minutes = min(max($0, AutoStopButton.range.lowerBound), AutoStopButton.range.upperBound) })
    }

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Label(minutes > 0 ? String(format: "%d min", minutes) : "No Limit", systemImage: "timer")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Stop the recording automatically after a number of minutes")
        .accessibilityLabel("Stop Automatically")
        .accessibilityValue(minutes > 0 ? String(format: "After %d minutes", minutes) : "Off")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            HStack {
                Text("Stop after")
                TextField("Minutes", value: limited, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 50)
                Stepper("Minutes", value: limited, in: AutoStopButton.range)
                Text("minutes")
            }
            .labelsHidden()
            .fixedSize()
            .padding()
        }
    }
}

/// The row under a selector: what the selector adds on the left, then the options, the timer and Start
struct SelectorBar<Leading: View>: View {
    @Binding var autoStop: Int
    var canStart = true
    let start: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading()
            Spacer(minLength: 12)
            OptionsView()
            Spacer(minLength: 12)
            AutoStopButton(minutes: $autoStop)
            SymbolButton("Start", symbol: "record.circle.fill", color: .red, help: "Start recording", action: start)
                .disabled(!canStart)
        }
    }
}

/// The window of the screen, application and window selectors: a prompt, what there is to choose from, the bar
struct SelectorWindow<Content: View, Bar: View>: View {
    let prompt: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        VStack(spacing: 12) {
            Text(prompt)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            bar()
        }
        .padding([.horizontal, .bottom], 20)
        .frame(width: 780, height: 555)
    }
}

/// The mark on a chosen screen, application or window
struct SelectionBadge: View {
    var size: CGFloat = 27

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .accessibilityHidden(true)
    }
}

/// What a selector's item looks like around its content: tinted when chosen, with the mark in its corner
struct SelectableItem: ViewModifier {
    let isSelected: Bool
    var badgeSize: CGFloat = 27

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(Color.blue.opacity(isSelected ? 0.2 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottomTrailing) {
                if isSelected { SelectionBadge(size: badgeSize).padding(6) }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A screen's or a window's picture, with a thin outline so that it stands out from the background
struct Thumbnail: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .shadow(color: .primary.opacity(0.6), radius: 0.5)
    }
}
