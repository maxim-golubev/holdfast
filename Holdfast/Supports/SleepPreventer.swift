//
//  SleepPreventer.swift
//  Holdfast
//
//  Created by apple on 2024/12/9.
//

import Foundation
import IOKit.pwr_mgt

/// Holds at most one sleep assertion. Asking twice creates one, releasing twice releases one.
class SleepPreventer {
    static let shared = SleepPreventer()
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    
    /// `display: false` only keeps the system from sleeping, which is enough for work that needs no screen.
    /// When an assertion is already held it is kept as it is.
    func preventSleep(reason: String, display: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard assertionID == nil else { return }
        let type = (display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep") as CFString
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            print("Failure to prevent sleep, error: \(result)")
        }
    }
    
    func allowSleep() {
        lock.lock()
        defer { lock.unlock() }
        guard let id = assertionID else { return }
        assertionID = nil
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess { print("Failed to release assertion, error: \(result)") }
    }
}
