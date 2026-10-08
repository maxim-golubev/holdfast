//
//  SleepAssertion.swift
//  Holdfast
//
//  Created by apple on 2024/12/9.
//

import Foundation
import IOKit.pwr_mgt

/// One sleep assertion, held from its creation until `release` (or until nothing holds the object any more).
/// Every use has one of its own: a recording that runs keeps the display awake with one, and each recording that
/// is being saved keeps the system awake with another, so the Mac stays awake until the last of them is final and
/// none can release what another still needs.
final class SleepAssertion {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    /// `display: false` only keeps the system from sleeping, which is enough for work that needs no screen
    init(reason: String, display: Bool = true) {
        let type = (display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep") as CFString
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            RecLog.write("Sleep could not be prevented (error \(result)): the Mac may sleep while this recording is recorded or saved")
        }
    }

    deinit { release() }

    /// Gives the assertion up. Calls after the first do nothing. Any thread.
    func release() {
        lock.lock()
        let id = assertionID
        assertionID = nil
        lock.unlock()
        guard let id = id else { return }
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess { RecLog.write("A sleep assertion could not be released (error \(result))") }
    }
}
