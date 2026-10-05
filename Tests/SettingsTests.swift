//
//  SettingsTests.swift
//  AppSettings: the keys and defaults an existing installation relies on, and how stored values are read
//

import Foundation

/// Runs `body` with `values` as stored settings. They go into the argument domain, which is searched first and
/// lives in this process only, so nothing is written to any preferences file.
private func withStored(_ values: [String: Any], _ body: () -> Void) {
    let defaults = UserDefaults.standard
    let before = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    body()
    defaults.setVolatileDomain(before, forName: UserDefaults.argumentDomain)
}

func settingsTests() async {
    await test("Settings: keys and defaults are those of the versions before AppSettings") {
        func check<T: Equatable>(_ key: SettingKey<T>, _ name: String, _ fallback: T, line: Int = #line) {
            expectEqual(key.name, name, "key", line: line)
            expectEqual(key.fallback, fallback, "default of \(name)", line: line)
        }
        check(AppSettings.$showOnDock, "showOnDock", true)
        check(AppSettings.$showMenubar, "showMenubar", false)
        check(AppSettings.$miniStatusBar, "miniStatusBar", false)
        check(AppSettings.$countdown, "countdown", 0)
        check(AppSettings.$preventSleep, "preventSleep", true)
        check(AppSettings.$showPreview, "showPreview", true)
        check(AppSettings.$trimAfterRecord, "trimAfterRecord", false)
        check(AppSettings.$hideSelf, "hideSelf", true)
        check(AppSettings.$includeMenuBar, "includeMenuBar", true)
        check(AppSettings.$hideCCenter, "hideCCenter", false)
        check(AppSettings.$hideDesktopFiles, "hideDesktopFiles", false)
        check(AppSettings.$highlightMouse, "highlightMouse", false)
        check(AppSettings.$showMouse, "showMouse", true)
        check(AppSettings.$dismissedTips, "neverRemindMe", [])
        check(AppSettings.$highRes, "highRes", 2)
        check(AppSettings.$frameRate, "frameRate", 30)
        check(AppSettings.$videoQuality, "videoQuality", 0.7)
        check(AppSettings.$recordHDR, "recordHDR", false)
        check(AppSettings.$encoder, "encoder", Encoder.preferred)
        check(AppSettings.$videoFormat, "videoFormat", .mp4)
        check(AppSettings.$withAlpha, "withAlpha", false)
        check(AppSettings.$recordWinSound, "recordWinSound", true)
        check(AppSettings.$recordMic, "recordMic", false)
        check(AppSettings.$remuxAudio, "remuxAudio", true)
        check(AppSettings.$keepUnmixed, "keepUnmixed", true)
        check(AppSettings.$audioFormat, "audioFormat", .aac)
        check(AppSettings.$audioQuality, "audioQuality", .high)
        check(AppSettings.$micDeviceID, "micDeviceID", "default")
        check(AppSettings.$micName, "micDevice", "default")
        check(AppSettings.$areaWidth, "areaWidth", 600)
        check(AppSettings.$areaHeight, "areaHeight", 450)
        expectEqual(AppSettings.$savedAreas.name, "savedArea", "key")
        expectEqual(AppSettings.$saveDirectory.name, "saveDirectory", "key")
        expect(AppSettings.$saveDirectory.fallback.hasSuffix("/Desktop"), "recordings go to the Desktop until a folder is chosen: \(AppSettings.$saveDirectory.fallback)")
        // What the stored values are: the raw values of the cases
        expectEqual([AudioQuality.normal, .good, .high, .extreme].map(\.rawValue), [128, 192, 256, 320], "audio quality in kbit/s")
        expectEqual([AudioFormat.aac, .alac, .flac, .opus, .mp3].map(\.rawValue), ["aac", "alac", "flac", "opus", "mp3"], "audio formats")
        expectEqual([VideoFormat.mov, .mp4].map(\.rawValue), ["mov", "mp4"], "video formats")
        expectEqual([Encoder.h264, .h265].map(\.rawValue), ["h264", "h265"], "encoders")
    }

    await test("Settings: nothing stored reads as the default") {
        withStored([:]) {
            expectEqual(AppSettings.recordMic, false, "recordMic")
            expectEqual(AppSettings.remuxAudio, true, "remuxAudio")
            expectEqual(AppSettings.keepUnmixed, true, "keepUnmixed")
            expectEqual(AppSettings.frameRate, 30, "frameRate")
            expectEqual(AppSettings.videoQuality, 0.7, "videoQuality")
            expectEqual(AppSettings.videoFormat, .mp4, "videoFormat")
            expectEqual(AppSettings.audioFormat, .aac, "audioFormat")
            expectEqual(AppSettings.audioQuality, .high, "audioQuality")
            expectEqual(AppSettings.encoder, Encoder.preferred, "encoder")
            expectEqual(AppSettings.saveDirectory, AppSettings.$saveDirectory.fallback, "saveDirectory")
            expectEqual(AppSettings.micName, "default", "micName")
            expectEqual(AppSettings.micDeviceID, "default", "micDeviceID")
            expect(AppSettings.storedMicDeviceID == nil, "no microphone ID is stored, so the old selection is still to be converted")
            expect(AppSettings.hiddenApps.isEmpty, "no hidden apps")
            expect(AppSettings.savedAreas.isEmpty, "no saved areas")
            expect(AppSettings.dismissedTips.isEmpty, "no dismissed tips")
        }
    }

    await test("Settings: stored values are read with their types") {
        let apps = try JSONEncoder().encode([AppInfo(bundleID: "com.example.chat", displayName: "Chat")])
        withStored(["recordMic": true, "remuxAudio": false, "frameRate": 60, "videoQuality": 0.3, "videoFormat": "mov",
                    "audioFormat": "flac", "audioQuality": 320, "encoder": "h264", "saveDirectory": "/Volumes/Meetings",
                    "micDeviceID": "AirPods-ID", "micDevice": "AirPods", "hiddenApps": apps, "neverRemindMe": ["a", "b"],
                    "savedArea": ["Built-in": ["x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0]]]) {
            expectEqual(AppSettings.recordMic, true, "recordMic")
            expectEqual(AppSettings.remuxAudio, false, "remuxAudio")
            expectEqual(AppSettings.frameRate, 60, "frameRate")
            expectEqual(AppSettings.videoQuality, 0.3, "videoQuality")
            expectEqual(AppSettings.videoFormat, .mov, "videoFormat")
            expectEqual(AppSettings.audioFormat, .flac, "audioFormat")
            expectEqual(AppSettings.audioQuality, .extreme, "audioQuality")
            expectEqual(AppSettings.encoder, .h264, "encoder")
            expectEqual(AppSettings.saveDirectory, "/Volumes/Meetings", "saveDirectory")
            expectEqual(AppSettings.storedMicDeviceID, "AirPods-ID", "micDeviceID")
            expectEqual(AppSettings.micName, "AirPods", "micName")
            expectEqual(AppSettings.hiddenApps, [AppInfo(bundleID: "com.example.chat", displayName: "Chat")], "hiddenApps")
            expectEqual(AppSettings.dismissedTips, ["a", "b"], "dismissedTips")
            expectEqual((AppSettings.savedAreas["Built-in"] as? [String: Double])?["width"], 3.0, "savedAreas")
        }
    }

    await test("Settings: a value written by hand as text still counts, and one that is no case falls back") {
        // `defaults write <id> recordMic YES` and `frameRate 24` store strings
        withStored(["recordMic": "YES", "hideSelf": "NO", "frameRate": "24", "videoQuality": "1",
                    "videoFormat": "avi", "audioFormat": "wav", "audioQuality": 100, "encoder": "av1"]) {
            expectEqual(AppSettings.recordMic, true, "recordMic")
            expectEqual(AppSettings.hideSelf, false, "hideSelf")
            expectEqual(AppSettings.frameRate, 24, "frameRate")
            expectEqual(AppSettings.videoQuality, 1.0, "videoQuality")
            expectEqual(AppSettings.videoFormat, .mp4, "an unknown video format")
            expectEqual(AppSettings.audioFormat, .aac, "an unknown audio format")
            expectEqual(AppSettings.audioQuality, .high, "an unknown audio quality")
            expectEqual(AppSettings.encoder, Encoder.preferred, "an unknown encoder")
        }
    }
}
