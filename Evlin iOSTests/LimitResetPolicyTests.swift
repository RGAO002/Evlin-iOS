import XCTest
@testable import Evlin_iOS

/// Live incident 2026-07-03 06:27 UTC: `DeviceActivityMonitorExtension.resetLimitShields`
/// fires on `intervalDidStart` for ANY limit activity — including the mid-day
/// interval restart that happens every time a per-app limit is re-armed (every
/// `set_limit` command). The unguarded sweep stripped EVERY `.limit`-source
/// `ShieldRecord`, not just the one being re-armed, silently unlocking every
/// other at-budget app. `LimitShieldLogic.isDayBoundaryReset` is the pure guard
/// that distinguishes a genuine midnight reset (different day key) from a
/// same-day re-arm restart (same day key) — only the former should sweep.
final class LimitResetPolicyTests: XCTestCase {

    /// Same stored day and today: this is a mid-day re-arm restart, not a
    /// midnight boundary. Must NOT sweep.
    func test_sameDay_isNotDayBoundary() {
        XCTAssertFalse(
            LimitShieldLogic.isDayBoundaryReset(storedDayKey: "2026-07-03", today: "2026-07-03")
        )
    }

    /// Stored day differs from today: a real midnight has passed. Must sweep.
    func test_differentDay_isDayBoundary() {
        XCTAssertTrue(
            LimitShieldLogic.isDayBoundaryReset(storedDayKey: "2026-07-02", today: "2026-07-03")
        )
    }

    /// First run / fresh install / upgrade: no day key persisted yet. Treated
    /// as NOT a boundary so we don't wrongly sweep on the very first interval
    /// start — we just record today's key and the next genuine midnight (a
    /// different day string) will sweep normally.
    func test_nilStoredDayKey_isNotDayBoundary() {
        XCTAssertFalse(
            LimitShieldLogic.isDayBoundaryReset(storedDayKey: nil, today: "2026-07-03")
        )
    }

    /// Empty-string stored day key (defensive: e.g. a corrupted/blank default)
    /// is treated the same as nil — not a boundary.
    func test_emptyStoredDayKey_isNotDayBoundary() {
        XCTAssertFalse(
            LimitShieldLogic.isDayBoundaryReset(storedDayKey: "", today: "2026-07-03")
        )
    }

    /// A v2 provenance rollover is authoritative evidence that midnight passed.
    /// It must survive a crash window where the older day-key marker was never
    /// persisted, otherwise yesterday's limit shield can remain into the new day.
    func test_confirmedV2RolloverForcesResetWithoutStoredDayKey() {
        XCTAssertTrue(
            LimitShieldLogic.shouldResetAtV2IntervalStart(
                confirmedRollover: true,
                storedDayKey: nil,
                today: "2026-07-03"
            )
        )
        XCTAssertFalse(
            LimitShieldLogic.shouldResetAtV2IntervalStart(
                confirmedRollover: false,
                storedDayKey: nil,
                today: "2026-07-03"
            )
        )
    }
}
