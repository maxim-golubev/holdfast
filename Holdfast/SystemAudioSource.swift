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
    /// What clocks it, for the log
    var clockText: String { get }
    var formatText: String { get }
    /// Stops the device and destroys the IOProc, the aggregate device and the tap, in that order; once
    func stop()
}

/// Where a recording's system audio comes from, decided once at its start (`SystemAudioSelection.choose`)
enum SystemAudioRoute: Equatable {
    /// The recording has no system audio
    case none
    /// A Core Audio process tap, which hears call audio too, with ScreenCaptureKit's system audio recorded as a
    /// backup next to it for the whole recording
    case tap
    /// ScreenCaptureKit's system audio, which leaves out FaceTime and phone calls; why the tap is not used, and
    /// whether it was tried and failed (rather than not allowed)
    case screenCaptureKit(reason: String, tapFailed: Bool)

    /// For the log
    var name: String {
        switch self {
        case .none: return "off"
        case .tap: return "on, process tap with screen capture as its backup"
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
    /// A recording without the tap is notified once while the app runs, whether the tap failed or was not allowed;
    /// every recording without the tap says why in the log
    static let callAudioNotice = NoticeOnce()
    /// The status line and on-screen warning of a recording whose tap could not be set up at all
    static let tapFailedWarning = "Call audio is not being recorded"

    /// Whether a recording that `wants` system audio gets it from the tap (with the backup), as `choose` decides
    /// for the same permission. Decided before the writer is made, which gives the backup its track.
    static func usesTap(wanted: Bool, permission: TapPermission) -> Bool {
        return wanted && (permission == .granted || permission == .unknown)
    }

    /// Decides where the system audio of a recording that `wants` it comes from. The tap is tried first (`startTap`
    /// starts its source, and throws only when it cannot run at all: a tap that cannot be built yet is retried by
    /// the source for the whole recording while the backup records); without the permission, or when it throws,
    /// ScreenCaptureKit records the system audio instead, so a recording that wants system audio always gets it.
    static func choose(wanted: Bool, permission: TapPermission, startTap: () throws -> Void) -> SystemAudioRoute {
        guard wanted else { return .none }
        switch permission {
        case .denied:
            return .screenCaptureKit(reason: "Holdfast is not allowed to record system audio (System Settings, Privacy & Security, Screen & System Audio Recording, System Audio Recording Only).", tapFailed: false)
        case .notDetermined:
            // Asked for before the start (`SystemAudioPermission.request`); still not answered means not allowed
            return .screenCaptureKit(reason: "Holdfast has not been allowed to record system audio yet.", tapFailed: false)
        case .granted, .unknown:
            do {
                try startTap()
                return .tap
            } catch {
                return .screenCaptureKit(reason: "The system audio tap could not be started: \(error.localizedDescription)", tapFailed: true)
            }
        }
    }

    /// What the user is told when the system audio comes from ScreenCaptureKit
    static func notice(for route: SystemAudioRoute) -> String? {
        guard case .screenCaptureKit(let reason, _) = route else { return nil }
        return "System audio is recorded through screen capture, which leaves out the audio of FaceTime calls and of phone calls taken on this Mac: the other side of such a call will not be in the recording. " + reason
    }

    /// Whether the notice is posted for this recording, which runs on `route`: only when it records without the tap,
    /// and then once while the app runs (`once`). A recording whose tap could not run at all also shows it for as
    /// long as it runs (`warning`), so later ones are not missed without a notification of their own.
    static func notifies(_ route: SystemAudioRoute, once: NoticeOnce) -> Bool {
        guard case .screenCaptureKit = route else { return false }
        return once.take()
    }

    /// What the recording shows for as long as it runs, in its status line and on screen like a track warning, when
    /// its tap could not run at all; nil otherwise. A tap that only fails to build, or dies, is not a warning: its
    /// source keeps rebuilding it and the backup records meanwhile.
    static func warning(for route: SystemAudioRoute) -> String? {
        guard case .screenCaptureKit(_, true) = route else { return nil }
        return tapFailedWarning
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

/// How a recording's tap is repaired: which construction (`TapClock`) is built next, and after how long. A failure
/// is a build that throws, or a tap that stopped delivering. The same construction is tried again once; after its
/// second failure in a row the next one in the order is, and after the last the first again. The first attempt after
/// a failure is at once, then the wait doubles from 0.5 s up to `longestWait`, for as long as the recording runs. A
/// tap that has delivered for `healthySeconds` starts the count anew.
struct TapRepair: Equatable {
    static let failuresPerConstruction = 2
    static let longestWait: Double = 10
    static let healthySeconds: Double = 10

    /// The construction tried last, and how often it failed in a row
    private(set) var current: TapClock?
    private(set) var failuresHere = 0
    /// Failures in a row, whatever the construction
    private(set) var failuresInRow = 0

    /// The construction to build next, of `order` (best first)
    func next(in order: [TapClock]) -> TapClock? {
        guard let first = order.first else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return first }
        return failuresHere >= TapRepair.failuresPerConstruction ? order[(index + 1) % order.count] : current
    }

    /// `clock` is being built
    mutating func trying(_ clock: TapClock) {
        if clock != current {
            current = clock
            failuresHere = 0
        }
    }

    mutating func failed() {
        failuresHere += 1
        failuresInRow += 1
    }

    /// The tap has delivered for `healthySeconds`
    mutating func healthy() {
        failuresHere = 0
        failuresInRow = 0
    }

    /// How long to wait before the next attempt
    var wait: Double {
        guard failuresInRow > 1 else { return 0 }
        return min(TapRepair.longestWait, 0.5 * pow(2, Double(failuresInRow - 2)))
    }
}

/// The system audio of one recording through a Core Audio process tap. It builds the tap at the start (`start`),
/// rebuilds it whenever it stops delivering, and tears it down at the stop. Every buffer is handed on as a
/// `CaptureSample` of kind `.audio`, on the sample queue, in ScreenCaptureKit's system audio format
/// (`SystemAudioConverter`), to the same `onSample` the stream's buffers go to. Its time is when it arrived in the
/// tap's IOProc, where it ends, and nothing else: no timestamp of the tap's device reaches the recording.
///
/// Self-repair: a tap whose IOProc has handed on nothing for `stallSeconds` (1 s) is dead. On the owner's Mac an
/// aggregate device clocked by AirPods in call mode stopped calling its IOProc 27 s into a meeting and never again,
/// with nothing in Core Audio saying so; only the silence tells. It is torn down and built again at once, logged,
/// with the next construction after the same one failed twice (`TapRepair`), and tried again with a growing wait
/// for as long as the recording runs. Nobody is asked to do anything, and nothing is shown: the backup track
/// (ScreenCaptureKit's system audio) records meanwhile, and the mix takes it where the tap was dead. A change of the
/// clock device's rate, or the device going away, is a failure too (`SystemAudioTap`'s listener). Which device is
/// the default output does not matter any more: the tap follows the processes, not the device.
///
/// Threads: building, rebuilding, the stall check and tearing down run one at a time on `control`. The IOProc only
/// checks that its tap is the current one (`delivering`, an atomic) and notes the time before it queues a buffer.
/// On the sample queue a buffer of an earlier tap than one already handed on is dropped, so nothing of an old tap
/// follows the new one, whatever order the old IOProc's last call and the new one's first end up in.
final class SystemAudioSource {
    /// Makes the taps: the real ones (`coreAudio`), or the tests' fakes
    struct Factory {
        /// The constructions to try, best first (`TapClock.order`)
        var constructions: () -> [TapClock]
        /// Builds and starts a tap with `clock`. `deliver` gets each of its buffers on the IO thread;
        /// `outputChanged` is called when its rate changes or its clock's device goes away.
        var makeTap: (_ clock: TapClock, _ queue: DispatchQueue, _ deliver: @escaping (CMSampleBuffer) -> Void, _ outputChanged: @escaping () -> Void) throws -> SystemAudioTapping

        static var coreAudio: Factory {
            let hardware = CoreAudioTapHardware()
            return Factory(constructions: {
                TapClock.order(builtIn: hardware.builtInOutputDevice(), defaultOutput: try? hardware.defaultOutputDevice())
            }, makeTap: { clock, queue, deliver, outputChanged in
                try SystemAudioTap(hardware: hardware, clock: clock, queue: queue, deliver: deliver, outputChanged: outputChanged)
            })
        }
    }

    /// How long a tap may hand on nothing before it counts as dead
    static let stallSeconds: Double = 1
    /// How often that is checked
    static let checkInterval: Double = 0.25

    /// The sources that have a tap running, so quitting can tear down any that is left (`stopAll`)
    private static let live = Mutex([ObjectIdentifier: Weak]())
    private struct Weak { weak var source: SystemAudioSource? }

    let control = DispatchQueue(label: "Holdfast.systemAudioTap")
    private let factory: Factory
    private let sampleQueue: DispatchQueue
    private let onSample: (CaptureSample) -> Void
    private let stallSeconds: Double
    private let checkInterval: Double
    /// Seconds to wait before an attempt, from the repair's own; the tests shorten it
    private let waitScale: Double
    /// Nil in the app: a buffer arrived when its tap's IOProc read the host clock, which is where the tap made it
    /// end (`SystemAudioTap`). The tests and the simulation give a clock of their own, read on the IO thread in the
    /// IOProc's place, and whatever time the buffer came with is then replaced by it.
    private let clock: (() -> CMTime)?
    /// The generation of the tap whose buffers are handed on; 0 while none is
    private let delivering = Atomic<Int>(0)
    /// When the current tap last handed a buffer on, in uptime nanoseconds; 0 before its first
    private let lastDelivery = Atomic<UInt64>(0)

    // On `control`
    private var tap: SystemAudioTapping?
    private var generation = 0
    /// When the current tap was built, and since when it has delivered without a stall (uptime nanoseconds)
    private var builtAt: UInt64 = 0
    private var repair = TapRepair()
    private var pending: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    /// How often a tap was built again, and attempts that failed, for the log
    private(set) var rebuilds = 0
    private(set) var failedAttempts = 0

    // On the sample queue
    private var latestGeneration = 0
    private let converter: SystemAudioConverter?
    private(set) var buffersHandedOn = 0
    private(set) var buffersDropped = 0

    init(factory: Factory, sampleQueue: DispatchQueue, stallSeconds: Double = SystemAudioSource.stallSeconds,
         checkInterval: Double = SystemAudioSource.checkInterval, waitScale: Double = 1,
         clock: (() -> CMTime)? = nil, onSample: @escaping (CaptureSample) -> Void) {
        self.factory = factory
        self.sampleQueue = sampleQueue
        self.stallSeconds = stallSeconds
        self.checkInterval = checkInterval
        self.waitScale = waitScale
        self.clock = clock
        self.onSample = onSample
        converter = SystemAudioConverter()
    }

    deinit {
        // Nothing else holds the source any more: what is waiting on `control` only holds it weakly
        tearDown()
    }

    /// Builds and starts the first tap and begins to watch it. A tap that cannot be built now is logged and tried
    /// again in the background, the backup recording meanwhile; this throws only when no tap can ever run (no
    /// converter to ScreenCaptureKit's format), and then nothing is left running. Not on `control`.
    func start() throws {
        guard converter != nil else { throw SystemAudioTapError("The system audio format is not available") }
        try control.sync {
            guard !stopped else { throw SystemAudioTapError("The system audio tap was stopped before it started") }
            attempt(reason: nil)
            let timer = DispatchSource.makeTimerSource(queue: control)
            timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
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

    private static func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Stops watching, stops handing buffers on and tears the tap down. Once.
    private func tearDown() {
        if !stopped {
            stopped = true
            pending?.cancel()
            pending = nil
            timer?.cancel()
            timer = nil
            delivering.store(0, ordering: .releasing)
            tap?.stop()
            tap = nil
            if generation > 0 {
                RecLog.write("System audio: process tap stopped (\(rebuilds) rebuilds, \(failedAttempts) failed attempts)")
            }
        }
        SystemAudioSource.live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
    }

    /// Builds a tap of the next construction, whose buffers are handed on from its first. `reason` is why the one
    /// before had to go, nil for the first.
    private func attempt(reason: String?) {
        guard !stopped, tap == nil else { return }
        let order = factory.constructions()
        guard let clock = repair.next(in: order) else { return }
        repair.trying(clock)
        generation += 1
        let mine = generation
        lastDelivery.store(0, ordering: .releasing)
        delivering.store(mine, ordering: .releasing)
        do {
            let made = try factory.makeTap(clock, control, { [weak self] buffer in
                self?.deliver(buffer, generation: mine)
            }, { [weak self] in
                guard let self = self else { return }
                self.control.async { self.failed(generation: mine, "its device changed its rate or went away") }
            })
            tap = made
            builtAt = SystemAudioSource.uptime()
            if reason == nil {
                RecLog.write("System audio: process tap with \(made.clockText) (\(made.formatText))")
            } else {
                rebuilds += 1
                if logs { RecLog.write("System audio: process tap rebuilt with \(made.clockText) (\(made.formatText))") }
            }
        } catch {
            delivering.store(0, ordering: .releasing)
            failedAttempts += 1
            repair.failed()
            if logs {
                RecLog.write("System audio: the process tap with \(clock.name) could not be built: \(error.localizedDescription); tried again \(waitText), the backup records meanwhile")
            }
            schedule()
        }
    }

    /// Whether this failure in a row is logged: the first ones, then one in thirty, so a tap that cannot be built
    /// for an hour does not fill the log
    private var logs: Bool { repair.failuresInRow <= 6 || repair.failuresInRow % 30 == 0 }

    private var waitText: String { repair.wait == 0 ? "at once" : String(format: "in %.1f s", repair.wait) }

    /// The next attempt, after the repair's wait
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = nil
            self.attempt(reason: "retry")
        }
        pending = work
        control.asyncAfter(deadline: .now() + repair.wait * waitScale, execute: work)
    }

    /// The tap of `generation` failed: torn down, and the next attempt scheduled
    private func failed(generation failing: Int, _ why: String) {
        guard !stopped, failing == generation, let current = tap else { return }
        // From here on nothing of the old tap is handed on
        delivering.store(0, ordering: .releasing)
        current.stop()
        tap = nil
        failedAttempts += 1
        repair.failed()
        if logs {
            RecLog.write("System audio: the process tap with \(current.clockText) failed (\(why)); rebuilding \(waitText), the backup records meanwhile")
        }
        schedule()
    }

    /// Every `checkInterval`: a tap that has handed nothing on for `stallSeconds` is dead; one that has delivered
    /// for `TapRepair.healthySeconds` is healthy
    private func check() {
        guard !stopped, tap != nil else { return }
        let now = SystemAudioSource.uptime()
        let last = lastDelivery.load(ordering: .acquiring)
        let since = max(builtAt, last)
        guard now > since else { return }
        let silent = Double(now - since) / 1_000_000_000
        if silent > stallSeconds {
            failed(generation: generation, String(format: "its IOProc handed on nothing for %.1f s", silent))
        } else if repair.failuresInRow > 0, last > 0, Double(now - builtAt) / 1_000_000_000 >= TapRepair.healthySeconds {
            repair.healthy()
            RecLog.write("System audio: the process tap with \(tap?.clockText ?? "?") has delivered for \(Int(TapRepair.healthySeconds)) s")
        }
    }

    // MARK: - IO thread

    /// From the IOProc of the tap of `generation`: queues the buffer, with the time it arrived, unless that tap has
    /// been replaced or stopped. The time is taken here, on the IO thread: however long the buffer then waits for
    /// the sample queue, it is recorded where it arrived.
    private func deliver(_ buffer: CMSampleBuffer, generation: Int) {
        guard delivering.load(ordering: .acquiring) == generation else { return }
        lastDelivery.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
        let arrival = clock.map { $0() } ?? CMTimeAdd(buffer.presentationTimeStamp, buffer.duration)
        sampleQueue.async { [weak self] in self?.handOn(buffer, generation: generation, arrival: arrival) }
    }

    // MARK: - Sample queue

    private func handOn(_ buffer: CMSampleBuffer, generation: Int, arrival: CMTime) {
        guard generation >= latestGeneration, let converter = converter else {
            buffersDropped += 1
            return
        }
        if generation != latestGeneration {
            // Another tap: its timeline and format start anew
            latestGeneration = generation
            converter.reset()
        }
        // The buffer ends when it arrived. The tap made it so; one given a clock's time instead is moved there.
        var stamped = buffer
        let start = CMTimeSubtract(arrival, buffer.duration)
        if start.isValid, start != buffer.presentationTimeStamp,
           let moved = MovieWriter.retime(buffer, by: CMTimeSubtract(buffer.presentationTimeStamp, start)) {
            stamped = moved
        }
        guard let converted = converter.convert(stamped) else { return }
        buffersHandedOn += 1
        onSample(CaptureSample(kind: .audio, buffer: converted, pts: converted.presentationTimeStamp, arrival: arrival))
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
