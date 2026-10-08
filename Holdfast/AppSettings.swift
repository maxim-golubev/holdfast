//
//  AppSettings.swift
//  Holdfast
//
//  Every value the app keeps in UserDefaults: its key, its type and the value it has while nothing is stored,
//  each written down once, here.
//

import Foundation
import SwiftUI
import VideoToolbox

/// The name a setting is stored under and the value it has while nothing is stored
struct SettingKey<Value> {
    let name: String
    let fallback: Value
}

/// A setting as a typed property. Declared in `AppSettings` only. The projected value (`AppSettings.$name`) is the
/// key, which is what a view hands to `@AppStorage`, so a view cannot have a key or a default of its own.
@propertyWrapper
struct Setting<Value> {
    let projectedValue: SettingKey<Value>
    /// nil when nothing usable is stored
    private let read: (UserDefaults, String) -> Value?
    private let stored: (Value) -> Any

    private init(_ name: String, _ fallback: Value, read: @escaping (UserDefaults, String) -> Value?, stored: @escaping (Value) -> Any = { $0 }) {
        projectedValue = SettingKey(name: name, fallback: fallback)
        self.read = read
        self.stored = stored
    }

    var wrappedValue: Value {
        get { read(AppSettings.store, projectedValue.name) ?? projectedValue.fallback }
        nonmutating set { AppSettings.store.set(stored(newValue), forKey: projectedValue.name) }
    }

    /// Whether a value is stored, whatever it is
    var isStored: Bool { AppSettings.store.object(forKey: projectedValue.name) != nil }

    init(_ name: String, default fallback: Value) where Value == Bool {
        self.init(name, fallback, read: { $0.object(forKey: $1) == nil ? nil : $0.bool(forKey: $1) })
    }

    init(_ name: String, default fallback: Value) where Value == Int {
        self.init(name, fallback, read: { $0.object(forKey: $1) == nil ? nil : $0.integer(forKey: $1) })
    }

    init(_ name: String, default fallback: Value) where Value == Double {
        self.init(name, fallback, read: { $0.object(forKey: $1) == nil ? nil : $0.double(forKey: $1) })
    }

    init(_ name: String, default fallback: Value) where Value == String {
        self.init(name, fallback, read: { $0.string(forKey: $1) })
    }

    init(_ name: String, default fallback: Value) where Value == Data {
        self.init(name, fallback, read: { $0.data(forKey: $1) })
    }

    init(_ name: String, default fallback: Value) where Value == [String] {
        self.init(name, fallback, read: { $0.stringArray(forKey: $1) })
    }

    init(_ name: String, default fallback: Value) where Value == [String: Any] {
        self.init(name, fallback, read: { $0.dictionary(forKey: $1) })
    }

    /// Stored as the raw value; a stored value that is no case of the type counts as not stored
    init(_ name: String, default fallback: Value) where Value: RawRepresentable, Value.RawValue == String {
        self.init(name, fallback, read: { $0.string(forKey: $1).flatMap(Value.init(rawValue:)) }, stored: { $0.rawValue })
    }

    init(_ name: String, default fallback: Value) where Value: RawRepresentable, Value.RawValue == Int {
        self.init(name, fallback, read: { $0.object(forKey: $1) == nil ? nil : Value(rawValue: $0.integer(forKey: $1)) }, stored: { $0.rawValue })
    }
}

/// `@AppStorage(AppSettings.$frameRate) private var frameRate: Int`: the same key and the same default as the
/// typed property. There is deliberately no other way a view declares a setting.
extension AppStorage {
    init(_ key: SettingKey<Value>) where Value == Bool { self.init(wrappedValue: key.fallback, key.name) }
    init(_ key: SettingKey<Value>) where Value == Int { self.init(wrappedValue: key.fallback, key.name) }
    init(_ key: SettingKey<Value>) where Value == Double { self.init(wrappedValue: key.fallback, key.name) }
    init(_ key: SettingKey<Value>) where Value == String { self.init(wrappedValue: key.fallback, key.name) }
    init(_ key: SettingKey<Value>) where Value: RawRepresentable, Value.RawValue == String { self.init(wrappedValue: key.fallback, key.name) }
    init(_ key: SettingKey<Value>) where Value: RawRepresentable, Value.RawValue == Int { self.init(wrappedValue: key.fallback, key.name) }
}

/// The settings. Views bind to them with `@AppStorage(AppSettings.$name)`; everything else reads and writes the
/// properties. Nothing is registered with `UserDefaults.register`: a value that is not stored is the default below.
/// The keys and the stored representations are those of the versions before this type existed; changing a name or
/// a default here changes the app for an installation that is set up already.
enum AppSettings {
    static let store = UserDefaults.standard

    // General. Holdfast is a menu bar app: the item is always there, there is no Dock icon, and the main panel does
    // not open by itself when the app launches (`opensPanelAtLaunch`).
    @Setting("showOnDock", default: false) static var showOnDock: Bool
    @Setting("showMenubar", default: true) static var showMenubar: Bool
    /// "Open the Panel When Holdfast Opens"
    @Setting("openPanelAtLaunch", default: false) static var openPanelAtLaunch: Bool
    /// "Show During Screen Sharing": off, the app's windows and menu bar item are left out of other apps' captures
    @Setting("showDuringScreenSharing", default: false) static var showDuringScreenSharing: Bool
    /// The last of the one-time changes to stored settings (`migrate`) that this installation has had
    @Setting("settingsVersion", default: 0) private static var settingsVersion: Int
    /// Seconds counted down before a recording starts, 0 for none
    @Setting("countdown", default: 0) static var countdown: Int
    @Setting("preventSleep", default: true) static var preventSleep: Bool
    @Setting("showPreview", default: true) static var showPreview: Bool
    @Setting("trimAfterRecord", default: false) static var trimAfterRecord: Bool
    /// Which notifications are posted (`Notifications.posts`). Problems are shown in the menu bar, and on screen once
    /// they have lasted a while, whatever this says.
    @Setting("notifications", default: .problems) static var notifications: Notifications
    /// The folder recordings are written to
    @Setting("saveDirectory", default: NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? (NSHomeDirectory() + "/Desktop"))
    static var saveDirectory: String
    /// The folders recordings were written to and that launch recovery has not yet found free of leftovers, most
    /// recent first (`RecordingFolders`): a recording interrupted in a folder that is no longer the save folder is
    /// still found
    @Setting("recordingFolders", default: []) static var recordingFolders: [String]

    // What is captured
    @Setting("hideSelf", default: true) static var hideSelf: Bool
    @Setting("includeMenuBar", default: true) static var includeMenuBar: Bool
    @Setting("hideCCenter", default: false) static var hideCCenter: Bool
    @Setting("hideDesktopFiles", default: false) static var hideDesktopFiles: Bool
    @Setting("highlightMouse", default: false) static var highlightMouse: Bool
    @Setting("showMouse", default: true) static var showMouse: Bool
    /// The apps left out of screen recordings, as JSON (`hiddenApps`)
    @Setting("hiddenApps", default: Data()) private static var hiddenAppsData: Data
    /// The ids of the tips the user does not want to see again
    @Setting("neverRemindMe", default: []) static var dismissedTips: [String]

    // Video. The defaults are chosen for long meetings.
    /// 2: the display's pixels (Retina), 1: its points. Decide with `recordsPixels`, not by comparing the number.
    @Setting("highRes", default: 2) static var highRes: Int
    /// A script can store any number; `captureFrameRate` makes it usable
    @Setting("frameRate", default: 30) static var frameRate: Int
    /// 0.3 low, 0.7 medium, anything else high
    @Setting("videoQuality", default: 0.7) static var videoQuality: Double
    @Setting("recordHDR", default: false) static var recordHDR: Bool
    /// HDR is only written as HEVC, whatever the encoder setting says
    static var usesHEVC: Bool { encoder == .h265 || recordHDR }
    @Setting("encoder", default: Encoder.preferred) static var encoder: Encoder
    @Setting("videoFormat", default: .mp4) static var videoFormat: VideoFormat
    @Setting("withAlpha", default: false) static var withAlpha: Bool

    // Audio
    @Setting("recordWinSound", default: true) static var recordWinSound: Bool
    @Setting("recordMic", default: false) static var recordMic: Bool
    /// "Mix Microphone into the Main Track": system audio and microphone are mixed into one track after the recording
    @Setting("remuxAudio", default: true) static var remuxAudio: Bool
    @Setting("keepUnmixed", default: true) static var keepUnmixed: Bool
    /// "Level Voices": in the mixed file each side of the call is brought to the same loudness (`VoiceLeveling`)
    @Setting("levelVoices", default: true) static var levelVoices: Bool
    @Setting("audioFormat", default: .aac) static var audioFormat: AudioFormat
    @Setting("audioQuality", default: .high) static var audioQuality: AudioQuality
    /// The chosen microphone: an `AVCaptureDevice.uniqueID`, or "default" for the system default input. Read it
    /// through `MicSelection.selectedMicID()`, which converts what earlier versions stored.
    @Setting("micDeviceID", default: "default") static var micDeviceID: String
    /// The chosen microphone's name, for display while the device is absent. Earlier versions stored the selection here.
    @Setting("micDevice", default: "default") static var micName: String

    // Area selector
    @Setting("areaWidth", default: 600) static var areaWidth: Int
    @Setting("areaHeight", default: 450) static var areaHeight: Int
    /// The last area recorded on each screen, by screen name. Use `ScreenContent.savedArea(forScreen:)` and `saveArea`.
    @Setting("savedArea", default: [:]) static var savedAreas: [String: Any]

    /// Once per installation, at launch, before any setting is read: version 1 makes an installation that had the
    /// Dock icon (the earlier default) a menu bar app like a new one. The two settings can be changed back afterwards.
    static func migrate() {
        guard settingsVersion < 1 else { return }
        showMenubar = true
        showOnDock = false
        settingsVersion = 1
    }

    /// Whether the main panel opens when Holdfast is opened (not at login): when the setting says so, and always when
    /// Holdfast has neither a menu bar item nor a Dock icon, since nothing else would show that it opened
    static var opensPanelAtLaunch: Bool { openPanelAtLaunch || (!showMenubar && !showOnDock) }

    /// nil until a microphone has been chosen or `MicSelection.selectedMicID()` has converted the old "micDevice" selection
    static var storedMicDeviceID: String? { _micDeviceID.isStored ? micDeviceID : nil }

    /// Whether a recording gets the display's pixels rather than its points
    static var recordsPixels: Bool { recordsPixels(highRes) }

    /// A stored 0 means pixels like 2 does: versions before this type rewrote it to 2 at launch
    static func recordsPixels(_ highRes: Int) -> Bool { highRes == 2 || highRes == 0 }

    /// The frame rate a recording is captured and encoded at, whatever "frameRate" holds
    static var captureFrameRate: Int { captureFrameRate(frameRate) }

    /// Never 0 or negative, which would make an invalid frame interval
    static func captureFrameRate(_ setting: Int) -> Int { min(240, max(1, setting)) }

    static var hiddenApps: [AppInfo] {
        get { (try? JSONDecoder().decode([AppInfo].self, from: hiddenAppsData)) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { hiddenAppsData = data } }
    }
}

/// An app left out of screen recordings
struct AppInfo: Hashable, Codable {
    let bundleID: String
    let displayName: String

    /// What the settings show: earlier versions stored the app's file name ("zoom.us.app"), shown without ".app"
    var name: String {
        return displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
    }
}

/// Which notifications Holdfast posts: the "Notifications" setting
enum Notifications: String, CaseIterable {
    /// A problem that lasts (`RecordingMonitor.announceSeconds`), a failure, a microphone that is not there
    case problems
    /// Those, and a quiet one when a recording or an export is saved and no preview shows it
    case problemsAndFinished
    /// None at all ("None"). Problems are still shown in the menu bar and on screen, and failures in an alert.
    case off

    /// What a notification is about
    enum Kind {
        /// Something the user has to know or act on
        case problem
        /// A recording or an export was saved: posted without a sound
        case finished
    }

    func posts(_ kind: Kind) -> Bool {
        switch self {
        case .problems: return kind == .problem
        case .problemsAndFinished: return true
        case .off: return false
        }
    }

    /// In the settings
    var title: String {
        switch self {
        case .problems: return "Problems Only"
        case .problemsAndFinished: return "Problems and Finished Recordings"
        case .off: return "None"
        }
    }
}

/// kbit/s
enum AudioQuality: Int { case normal = 128, good = 192, high = 256, extreme = 320 }

enum AudioFormat: String { case aac, alac, flac, opus, mp3 }

enum VideoFormat: String { case mov, mp4 }

enum Encoder: String {
    case h264, h265

    /// The encoder used while the user has not chosen one: HEVC where the Mac encodes it in hardware (every Apple
    /// Silicon Mac does), which gives about half the file size of H.264 for the same picture, and H.264 otherwise.
    static let preferred: Encoder = encodesInHardware(kCMVideoCodecType_HEVC, width: 1920, height: 1080) ? .h265 : .h264

    /// Whether this Mac has a hardware encoder for `codec` at that size. The session made to find out is torn down at once.
    static func encodesInHardware(_ codec: CMVideoCodecType, width: Int32, height: Int32) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: codec,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session = session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }
}
