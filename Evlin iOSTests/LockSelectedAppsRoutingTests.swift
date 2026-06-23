// LockSelectedAppsRoutingTests.swift
// Evlin iOSTests
//
// Task 8 — verify the confirm-card resend phrase satisfies the loop-safety
// invariant: contains "locked set" + the duration, never contains "list"
// (which would trip GUARD_OTHER_FAMILY and bypass the app-control fastpath).

import XCTest
@testable import Evlin_iOS

final class LockSelectedAppsRoutingTests: XCTestCase {
    // The loop-safety invariant: the confirm resend names the list by plain name,
    // contains the duration, and never contains the word "list" (which would trip
    // GUARD_OTHER_FAMILY and bypass the app-control fastpath).
    func testSelectedSetLockPhraseIsListGuardSafe() {
        let p = AppControlRouter.selectedSetLockPhrase(durationMinutes: 30)
        XCTAssertTrue(p.lowercased().contains("locked set"))
        XCTAssertTrue(p.contains("30"))
        XCTAssertFalse(p.lowercased().contains("list"))
    }
}
