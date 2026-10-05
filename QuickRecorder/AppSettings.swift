//
//  AppSettings.swift
//  QuickRecorder
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

    // General
    @Setting("showOnDock", default: true) static var showOnDock: Bool
    @Setting("showMenubar", default: false) static var showMenubar: Bool
    @Setting("miniStatusBar", default: false) static var miniStatusBar: Bool
    /// Seconds counted down before a recording starts, 0 for none
    @Setting("countdown", default: 0) static var countdown: Int
    @Setting("preventSleep", default: true) static var preventSleep: Bool
    @Setting("showPreview", default: true) static var showPreview: Bool
    @Setting("trimAfterRecord", default: false) static var trimAfterRecord: Bool
    /// The folder recordings are written to
    @Setting("saveDirectory", default: NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? (NSHomeDirectory() + "/Desktop"))
    static var saveDirectory: String

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
    /// A script can store any number; `SCContext.captureFrameRate` makes it usable
    @Setting("frameRate", default: 30) static var frameRate: Int
    /// 0.3 low, 0.7 medium, anything else high
    @Setting("videoQuality", default: 0.7) static var videoQuality: Double
    @Setting("recordHDR", default: false) static var recordHDR: Bool
    @Setting("encoder", default: Encoder.preferred) static var encoder: Encoder
    @Setting("videoFormat", default: .mp4) static var videoFormat: VideoFormat
    @Setting("withAlpha", default: false) static var withAlpha: Bool

    // Audio
    @Setting("recordWinSound", default: true) static var recordWinSound: Bool
    @Setting("recordMic", default: false) static var recordMic: Bool
    /// "Record Microphone to Main Track": system audio and microphone are mixed into one track after the recording
    @Setting("remuxAudio", default: true) static var remuxAudio: Bool
    @Setting("keepUnmixed", default: true) static var keepUnmixed: Bool
    @Setting("audioFormat", default: .aac) static var audioFormat: AudioFormat
    @Setting("audioQuality", default: .high) static var audioQuality: AudioQuality
    /// The chosen microphone: an `AVCaptureDevice.uniqueID`, or "default" for the system default input. Read it
    /// through `SCContext.selectedMicID()`, which converts what earlier versions stored.
    @Setting("micDeviceID", default: "default") static var micDeviceID: String
    /// The chosen microphone's name, for display while the device is absent. Earlier versions stored the selection here.
    @Setting("micDevice", default: "default") static var micName: String

    // Area selector
    @Setting("areaWidth", default: 600) static var areaWidth: Int
    @Setting("areaHeight", default: 450) static var areaHeight: Int
    /// The last area recorded on each screen, by screen name. Use `SCContext.savedArea(forScreen:)` and `saveArea`.
    @Setting("savedArea", default: [:]) static var savedAreas: [String: Any]

    /// nil until a microphone has been chosen or `SCContext.selectedMicID()` has converted the old "micDevice" selection
    static var storedMicDeviceID: String? { _micDeviceID.isStored ? micDeviceID : nil }

    /// Whether a recording gets the display's pixels rather than its points
    static var recordsPixels: Bool { recordsPixels(highRes) }

    /// A stored 0 means pixels like 2 does: versions before this type rewrote it to 2 at launch
    static func recordsPixels(_ highRes: Int) -> Bool { highRes == 2 || highRes == 0 }

    static var hiddenApps: [AppInfo] {
        get { (try? JSONDecoder().decode([AppInfo].self, from: hiddenAppsData)) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { hiddenAppsData = data } }
    }
}

/// An app left out of screen recordings
struct AppInfo: Hashable, Codable {
    let bundleID: String
    let displayName: String
}

/// kbit/s
enum AudioQuality: Int { case normal = 128, good = 192, high = 256, extreme = 320 }

enum AudioFormat: String { case aac, alac, flac, opus, mp3 }

enum VideoFormat: String { case mov, mp4 }

enum Encoder: String {
    case h264, h265

    /// The encoder used while the user has not chosen one: HEVC where the Mac encodes it in hardware (every Apple
    /// Silicon Mac does), which gives about half the file size of H.264 for the same picture, and H.264 otherwise.
    static let preferred: Encoder = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session = session { VTCompressionSessionInvalidate(session) }
        return status == noErr ? .h265 : .h264
    }()
}
