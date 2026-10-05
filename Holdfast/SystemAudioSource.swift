//
//  SystemAudioSource.swift
//  Holdfast
//

import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// A running tap as `SystemAudioSource` uses it (`SystemAudioTap`; the tests have their own)
protocol SystemAudioTapping: AnyObject {
    var deviceName: String { get }
    var formatText: String { get }
    /// Whether it is still built on the default output device, and that device is there
    var isCurrent: Bool { get }
    /// Stops the device and destroys the IOProc, the aggregate device and the tap, in that order; once
    func stop()
}

/// Where a recording's system audio comes from, decided once at its start (`SystemAudioSelection.choose`)
enum SystemAudioRoute: Equatable {
    /// The recording has no system audio
    case none
    /// A Core Audio process tap, which hears call audio too
    case tap
    /// ScreenCaptureKit's system audio, which leaves out FaceTime and phone calls; why the tap is not used
    case screenCaptureKit(reason: String)

    /// Whether the stream captures audio. Never with the tap: the recording would have the system audio twice.
    var streamCapturesAudio: Bool {
        if case .screenCaptureKit = self { return true }
        return false
    }

    /// For the log
    var name: String {
        switch self {
        case .none: return "off"
        case .tap: return "on, process tap"
        case .screenCaptureKit: return "on, screen capture"
        }
    }
}

/// The "System Audio Recording Only" permission (kTCCServiceAudioCapture), which a process tap needs
enum TapPermission: Equatable {
    case granted, denied, notDetermined
    /// It cannot be read: the tap is tried and its failure decides
    case unknown
}

enum SystemAudioSelection {
    /// The title of the notice when the tap is not used
    static let noticeTitle = "Call Audio Not Included"
    /// The notice is shown once while the app runs; every recording without the tap says why in the log
    static let callAudioNotice = NoticeOnce()

    /// Decides where the system audio of a recording that `wants` it comes from. The tap is tried first (`startTap`
    /// builds and starts it, and throws when it cannot); without the permission, or when it fails, ScreenCaptureKit
    /// records the system audio instead, so a recording that wants system audio always gets it when either works.
    static func choose(wanted: Bool, permission: TapPermission, startTap: () throws -> Void) -> SystemAudioRoute {
        guard wanted else { return .none }
        switch permission {
        case .denied:
            return .screenCaptureKit(reason: "Holdfast is not allowed to record system audio (System Settings, Privacy & Security, Screen & System Audio Recording, System Audio Recording Only).")
        case .notDetermined:
            // Asked for before the start (`SystemAudioPermission.request`); still not answered means not allowed
            return .screenCaptureKit(reason: "Holdfast has not been allowed to record system audio yet.")
        case .granted, .unknown:
            do {
                try startTap()
                return .tap
            } catch {
                return .screenCaptureKit(reason: "The system audio tap could not be started: \(error.localizedDescription)")
            }
        }
    }

    /// What the user is told when the system audio comes from ScreenCaptureKit
    static func notice(for route: SystemAudioRoute) -> String? {
        guard case .screenCaptureKit(let reason) = route else { return nil }
        return "System audio is recorded through screen capture, which leaves out the audio of FaceTime calls and of phone calls taken on this Mac: the other side of such a call will not be in the recording. " + reason
    }
}

/// True the first time only: a notice that is shown once while the app runs
final class NoticeOnce {
    private let shown = Mutex(false)
    func take() -> Bool {
        return shown.withLock { shown in
            defer { shown = true }
            return !shown
        }
    }
}

/// The system audio of one recording through a Core Audio process tap. It builds the tap at the start (`start`),
/// rebuilds it when the output changes (the default output device, the list of devices, the tap's own device going
/// or changing its rate), and tears it down at the stop. Every buffer is handed on as a `CaptureSample` of kind
/// `.audio`, on the sample queue, in ScreenCaptureKit's system audio format (`SystemAudioConverter`), to the same
/// `onSample` the stream's buffers go to: the writer and the monitor cannot tell where it came from.
///
/// Threads: building, rebuilding and tearing down run one at a time on `control`. The IOProc only checks that its
/// tap is the current one (`delivering`, an atomic) before it queues a buffer. On the sample queue a buffer of an
/// earlier tap than one already handed on is dropped, so nothing of an old device follows the new one, whatever
/// order the old IOProc's last call and the new one's first end up in.
final class SystemAudioSource {
    /// Makes the taps: the real ones (`coreAudio`), or the tests' fakes
    struct Factory {
        /// Builds and starts a tap on the current default output device. `deliver` gets each of its buffers on the
        /// IO thread; `outputChanged` is called when its device changes rate or goes away.
        var makeTap: (_ queue: DispatchQueue, _ deliver: @escaping (CMSampleBuffer) -> Void, _ outputChanged: @escaping () -> Void) throws -> SystemAudioTapping
        /// Calls `changed` on `queue`, with what changed, when the default output device or the device list
        /// changes; returns what stops watching
        var watchDevices: (_ queue: DispatchQueue, _ changed: @escaping (String) -> Void) -> () -> Void

        static var coreAudio: Factory {
            let hardware = CoreAudioTapHardware()
            return Factory(makeTap: { queue, deliver, outputChanged in
                try SystemAudioTap(hardware: hardware, queue: queue, deliver: deliver, outputChanged: outputChanged)
            }, watchDevices: { queue, changed in
                let system = AudioObjectID(kAudioObjectSystemObject)
                let output = hardware.watch(system, [kAudioHardwarePropertyDefaultOutputDevice], queue: queue) { changed("the default output device changed") }
                let devices = hardware.watch(system, [kAudioHardwarePropertyDevices], queue: queue) { changed("the audio devices changed") }
                return {
                    if let output = output { hardware.unwatch(output) }
                    if let devices = devices { hardware.unwatch(devices) }
                }
            })
        }
    }

    /// How long after a device change the tap is rebuilt: changes come in bursts
    static let settleDelay: Double = 0.5
    /// A rebuild that failed is tried again this often, this far apart, before the next device change
    static let retries = 3
    static let retryDelay: Double = 2

    /// The sources that have a tap running, so quitting can tear down any that is left (`stopAll`)
    private static let live = Mutex([ObjectIdentifier: Weak]())
    private struct Weak { weak var source: SystemAudioSource? }

    let control = DispatchQueue(label: "Holdfast.systemAudioTap")
    private let factory: Factory
    private let sampleQueue: DispatchQueue
    private let onSample: (CaptureSample) -> Void
    private let settleDelay: Double
    private let retryDelay: Double
    /// The generation of the tap whose buffers are handed on; 0 while none is
    private let delivering = Atomic<Int>(0)

    // On `control`
    private var tap: SystemAudioTapping?
    private var generation = 0
    private var stopWatching: (() -> Void)?
    private var pending: DispatchWorkItem?
    private var retriesLeft = 0
    /// Whether the rebuild that is waiting replaces a tap that is still on the default output device
    private var forcePending = false
    private var stopped = false
    /// How often the tap was rebuilt, for the log
    private(set) var rebuilds = 0

    // On the sample queue
    private var latestGeneration = 0
    private let converter: SystemAudioConverter?
    private(set) var buffersHandedOn = 0
    private(set) var buffersDropped = 0

    init(factory: Factory, sampleQueue: DispatchQueue, settleDelay: Double = SystemAudioSource.settleDelay,
         retryDelay: Double = SystemAudioSource.retryDelay, onSample: @escaping (CaptureSample) -> Void) {
        self.factory = factory
        self.sampleQueue = sampleQueue
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
        self.onSample = onSample
        converter = SystemAudioConverter()
    }

    deinit {
        // Nothing else holds the source any more: what is waiting on `control` only holds it weakly
        tearDown()
    }

    /// Builds and starts the first tap and begins to follow the devices. Throws when the tap cannot be made; then
    /// nothing is left running. Not on `control`.
    func start() throws {
        guard converter != nil else { throw SystemAudioTapError("The system audio format is not available") }
        try control.sync {
            guard !stopped else { throw SystemAudioTapError("The system audio tap was stopped before it started") }
            try build()
            RecLog.write("System audio: process tap on \"\(tap?.deviceName ?? "?")\" (\(tap?.formatText ?? "?"))")
            stopWatching = factory.watchDevices(control) { [weak self] reason in self?.devicesChanged(reason, force: false) }
        }
        SystemAudioSource.live.withLock { $0[ObjectIdentifier(self)] = Weak(source: self) }
    }

    /// Tears the tap down; `done` is called, on `control`, once its IOProc is not called any more. Any thread.
    func stop(_ done: @escaping () -> Void = {}) {
        control.async { [self] in
            tearDown()
            done()
        }
    }

    /// Tears the tap down before returning. Not on `control`.
    func stopNow() {
        control.sync { tearDown() }
    }

    /// For quitting: tears down every tap that is still running
    static func stopAll() {
        let sources = live.withLock { $0.values.compactMap { $0.source } }
        sources.forEach { $0.stopNow() }
    }

    // MARK: - Control queue

    /// Stops following the devices, stops handing buffers on and tears the tap down. Once.
    private func tearDown() {
        if !stopped {
            stopped = true
            pending?.cancel()
            pending = nil
            stopWatching?()
            stopWatching = nil
            delivering.store(0, ordering: .releasing)
            if let tap = tap {
                tap.stop()
                RecLog.write("System audio: process tap stopped (\(rebuilds) rebuilds)")
            }
            tap = nil
        }
        SystemAudioSource.live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
    }

    /// Makes a tap of the next generation, whose buffers are handed on from its first
    private func build() throws {
        generation += 1
        let mine = generation
        delivering.store(mine, ordering: .releasing)
        do {
            tap = try factory.makeTap(control, { [weak self] buffer in
                self?.deliver(buffer, generation: mine)
            }, { [weak self] in
                guard let self = self else { return }
                self.control.async { self.devicesChanged("the output device changed its format or went away", force: true) }
            })
        } catch {
            delivering.store(0, ordering: .releasing)
            throw error
        }
    }

    /// A device change: the tap is rebuilt once the burst of changes is over. `force` rebuilds a tap that is
    /// still on the default output device, whose format changed under it.
    private func devicesChanged(_ reason: String, force: Bool) {
        guard !stopped else { return }
        retriesLeft = SystemAudioSource.retries
        // A forced rebuild that is waiting stays forced
        schedule(after: settleDelay, reason: reason, force: force || (pending != nil && forcePending))
    }

    private func schedule(after delay: Double, reason: String, force: Bool) {
        pending?.cancel()
        forcePending = force
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = nil
            self.forcePending = false
            self.rebuild(reason: reason, force: force)
        }
        pending = work
        control.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Replaces the tap by one on the current default output device. A tap that is still on it is kept unless
    /// `force`: the device list also changes when Holdfast's own aggregate device comes and goes.
    private func rebuild(reason: String, force: Bool) {
        guard !stopped else { return }
        if !force, let tap = tap, tap.isCurrent { return }
        RecLog.write("System audio: rebuilding the process tap (\(reason))")
        // From here on nothing of the old tap is handed on
        delivering.store(0, ordering: .releasing)
        tap?.stop()
        tap = nil
        do {
            try build()
            rebuilds += 1
            RecLog.write("System audio: process tap rebuilt on \"\(tap?.deviceName ?? "?")\" (\(tap?.formatText ?? "?"))")
        } catch {
            RecLog.write("System audio: rebuilding the process tap failed: \(error.localizedDescription)")
            guard retriesLeft > 0 else { return }
            retriesLeft -= 1
            schedule(after: retryDelay, reason: "retry", force: true)
        }
    }

    // MARK: - IO thread

    /// From the IOProc of the tap of `generation`: queues the buffer unless that tap has been replaced or stopped
    private func deliver(_ buffer: CMSampleBuffer, generation: Int) {
        guard delivering.load(ordering: .acquiring) == generation else { return }
        sampleQueue.async { [weak self] in self?.handOn(buffer, generation: generation) }
    }

    // MARK: - Sample queue

    private func handOn(_ buffer: CMSampleBuffer, generation: Int) {
        guard generation >= latestGeneration, let converter = converter else {
            buffersDropped += 1
            return
        }
        if generation != latestGeneration {
            // Another device: its timeline and format start anew
            latestGeneration = generation
            converter.reset()
        }
        guard let converted = converter.convert(buffer) else { return }
        buffersHandedOn += 1
        onSample(CaptureSample(kind: .audio, buffer: converted, pts: converted.presentationTimeStamp))
    }
}

/// The "System Audio Recording Only" permission. macOS has no public call that reads it without asking; the TCC
/// framework's own `TCCAccessPreflight` (read) and `TCCAccessRequest` (ask) are used when they are there. When they
/// are not, the state is `unknown` and the tap is simply tried.
enum SystemAudioPermission {
    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let framework: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework = framework, let symbol = dlsym(framework, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// Reads the permission without asking for it
    static func status() -> TapPermission {
        guard let preflight = function("TCCAccessPreflight", as: Preflight.self) else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Asks for the permission (macOS shows its prompt); `done` gets the answer, on any thread, or nil when it
    /// cannot be asked for
    static func request(_ done: @escaping (Bool?) -> Void) {
        guard let request = function("TCCAccessRequest", as: Request.self) else { return done(nil) }
        request(service, nil) { granted in done(granted) }
    }
}
