//
//  MicDevices.swift
//  QuickRecorder
//

import AppKit
import AVFoundation
import CoreAudio

/// Which microphone is recorded: the setting, and the devices it can name
enum MicSelection {
    static func performMicCheck() async {
        guard AppSettings.recordMic else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        AppSettings.recordMic = false
        UserNotice.onMainRunLoop {
            let alert = createAlert(title: "Permission Required",
                                                       message: "QuickRecorder needs permission to record your microphone.",
                                                       button1: "Open Settings",
                                                       button2: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                UserNotice.openPrivacySettings("Privacy_Microphone")
            }
        }
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    /// The chosen microphone: an AVCaptureDevice uniqueID, or "default" to follow the system default input.
    /// A selection is kept while its device is not connected.
    ///
    /// Earlier versions stored the device's name under "micDevice". That is converted the first time this is read;
    /// if the device is absent then, its name stands in for the ID until the device is seen again.
    static func selectedMicID() -> String {
        let mics = getMicrophone()
        if let id = AppSettings.storedMicDeviceID {
            if id != "default", !mics.contains(where: { $0.uniqueID == id }), let device = mics.first(where: { $0.localizedName == id }) {
                AppSettings.micDeviceID = device.uniqueID
                return device.uniqueID
            }
            return id
        }
        let name = AppSettings.micName
        let id = name == "default" ? name : (mics.first(where: { $0.localizedName == name })?.uniqueID ?? name)
        AppSettings.micDeviceID = id
        return id
    }
    
    /// Name of the chosen microphone for display, kept under "micDevice" so that it is known while the device is absent
    static func selectedMicName() -> String {
        let id = selectedMicID()
        if let device = getMicrophone().first(where: { $0.uniqueID == id }) { return device.localizedName }
        let name = AppSettings.micName
        return name == "default" ? id : name
    }
    
    /// Selects a microphone by name, or the system default for "default". Returns false when there is no such device.
    static func selectMic(named name: String) -> Bool {
        if name == "default" {
            AppSettings.micDeviceID = "default"
        } else if let device = getMicrophone().first(where: { $0.localizedName == name }) {
            AppSettings.micDeviceID = device.uniqueID
        } else {
            return false
        }
        AppSettings.micName = name
        return true
    }
}

/// Follows the audio input devices while a recording has a microphone track: when the system default input changes
/// (recording the default microphone) or the chosen device disappears or comes back, the stream is told to capture
/// from the device that should be used now. Main thread only.
enum MicDevices {
    private static var watching = false

    /// The capture of the recording in progress. What belongs to one recording, the switch that is waiting and
    /// the tries that are left, is kept in it (`micPendingSwitch`, `micRetriesLeft`) and goes with it.
    private static func currentCapture() -> CaptureSource? {
        return MainActor.assumeIsolated { RecorderController.shared.session?.capture as? CaptureSource }
    }

    /// UID of the system default input device, which is what `AVCaptureDevice.uniqueID` holds for audio devices
    static func defaultInputUID() -> String? {
        let fallback = AVCaptureDevice.default(for: .audio)?.uniqueID
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let found = uid else { return fallback }
        return found.takeRetainedValue() as String
    }

    /// Installs the listeners once. They stay for the life of the app and do nothing while no microphone is being recorded.
    static func watch() {
        guard !watching else { return }
        watching = true
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
                // A device change comes as a burst of notifications, and the device list lags a little behind them
                guard let capture = currentCapture() else { return }
                capture.micRetriesLeft = 3
                schedule(capture, after: 0.7, announce: true)
            }
            if status != noErr { print("Cannot watch the audio devices (selector \(selector)): \(status)") }
        }
    }

    private static func schedule(_ capture: CaptureSource, after delay: Double, announce: Bool) {
        capture.micPendingSwitch?.cancel()
        let work = DispatchWorkItem { followDevices(announce: announce) }
        capture.micPendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func followDevices(announce: Bool) {
        guard let capture = currentCapture(), capture.recordsMic else { return }
        let conf = capture.configuration
        let devices = MicSelection.getMicrophone()
        let selection = capture.micSelection
        let selectedIsPresent = selection != "default" && devices.contains(where: { $0.uniqueID == selection })
        guard let wanted = selectedIsPresent ? selection : defaultInputUID() else { return }
        let previous = capture.micActiveDeviceID
        guard wanted != previous else { return }
        func name(_ id: String?) -> String {
            guard let id = id else { return "none" }
            return devices.first(where: { $0.uniqueID == id })?.localizedName ?? id
        }
        let wantedName = name(wanted)
        RecLog.write("Microphone switch: from \"\(name(previous))\" to \"\(wantedName)\" (\(selection == "default" ? "the default input changed" : (selectedIsPresent ? "the chosen microphone is back" : "the chosen microphone is gone")))")
        // A default input that is not among the capture devices is left to the system to pick
        let previousCaptureID = conf.microphoneCaptureDeviceID
        conf.microphoneCaptureDeviceID = devices.contains(where: { $0.uniqueID == wanted }) ? wanted : nil
        capture.micActiveDeviceID = wanted
        if announce && selection != "default" && !selectedIsPresent {
            let body = String(format: "\"%@\" is not connected any more. Recording continues with the default microphone \"%@\".".local, MicSelection.selectedMicName(), wantedName)
            UserNotice.showNotification(title: "Microphone Unavailable".local, body: body, id: "quickrecorder.microphone.\(UUID().uuidString)")
        }
        capture.applyConfiguration { error in
            guard let error = error else {
                RecLog.write("Microphone switch: now capturing \"\(wantedName)\"")
                return
            }
            RecLog.write("Microphone switch to \"\(wantedName)\" failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                // Back to what the stream is still capturing, then a few more tries; after those, at the next device change
                guard currentCapture() === capture, capture.micActiveDeviceID == wanted else { return }
                capture.micActiveDeviceID = previous
                conf.microphoneCaptureDeviceID = previousCaptureID
                if capture.micRetriesLeft > 0 {
                    capture.micRetriesLeft -= 1
                    schedule(capture, after: 2, announce: false)
                }
            }
        }
    }
}
