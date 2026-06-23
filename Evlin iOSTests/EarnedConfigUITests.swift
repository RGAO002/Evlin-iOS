import XCTest
@testable import Evlin_iOS

// MARK: - Pure logic tests for B9 option generation + cascade-confirm decision.
//
// All tests are network-free and UI-free. They exercise two pure helpers
// introduced in EarnedScreenTimeHelpers.swift:
//
//   EarnedAppOptions.compute(...)     — dynamic limit picker options
//   EarnedCascadeDecision.decide(...) — should we show a confirm sheet?

final class EarnedConfigUITests: XCTestCase {

    // -------------------------------------------------------------------------
    // MARK: App option generation
    // -------------------------------------------------------------------------

    /// When `policyOptions` is supplied by the backend, the returned set equals
    /// those options filtered to values ≤ deviceCap. Values above cap are
    /// excluded even if the backend returned them (defensive).
    func testAppOptions_policyOptionsFilteredByCap() {
        let opts = EarnedAppOptions.compute(
            policyOptions: [15, 30, 60, 90, 120],
            deviceCap: 60,
            existingBudget: nil,
            isDebug: false
        )
        XCTAssertEqual(opts.selectable, [15, 30, 60])
    }

    /// When no policy options are supplied (offline / unconfigured), the
    /// fallback base set (DeviceAppsMockData.limitOptions) is used, again
    /// filtered to ≤ deviceCap.
    func testAppOptions_fallbackBaseSetFilteredByCap() {
        let opts = EarnedAppOptions.compute(
            policyOptions: nil,
            deviceCap: 45,
            existingBudget: nil,
            isDebug: false
        )
        // Fallback base (release): [15, 20, 30, 45, 60, 90, 120] → ≤ 45 → [15, 20, 30, 45]
        XCTAssertEqual(opts.selectable, [15, 20, 30, 45])
    }

    /// DEBUG mode injects the 1-minute option at the front.
    func testAppOptions_debugInjectsOneMinute() {
        let opts = EarnedAppOptions.compute(
            policyOptions: nil,
            deviceCap: 60,
            existingBudget: nil,
            isDebug: true
        )
        XCTAssertTrue(opts.selectable.contains(1), "DEBUG should inject 1-minute option")
        XCTAssertEqual(opts.selectable.first, 1, "1-minute should be first in DEBUG")
    }

    /// The injected 1-minute option in DEBUG is never added when cap < 1
    /// (edge case: cap = 0 means no time; this should never occur but be safe).
    func testAppOptions_debugDoesNotInjectOneAboveCap() {
        let opts = EarnedAppOptions.compute(
            policyOptions: nil,
            deviceCap: 0,
            existingBudget: nil,
            isDebug: true
        )
        XCTAssertFalse(opts.selectable.contains(1), "1-minute must not be injected above cap=0")
    }

    /// An existing rule whose budget > a newly-lowered cap is NOT offered as a
    /// selectable option, but IS surfaced in the over-cap list with a
    /// "changes tomorrow" flag.
    func testAppOptions_overCapExistingRuleKeptAndFlagged() {
        let opts = EarnedAppOptions.compute(
            policyOptions: nil,
            deviceCap: 30,
            existingBudget: 60,   // existing rule is 60m but cap dropped to 30m
            isDebug: false
        )
        // 60m must NOT appear as a selectable new option
        XCTAssertFalse(opts.selectable.contains(60),
                       "Over-cap existing budget must not appear as selectable")
        // It must appear in the over-cap list
        XCTAssertTrue(opts.overCapExisting.contains(60),
                      "Over-cap existing budget must be flagged in overCapExisting")
    }

    /// The default pill for a new app is min(60, deviceCap).
    func testAppOptions_defaultPillIsMin60Cap() {
        XCTAssertEqual(EarnedAppOptions.defaultPill(deviceCap: 60), 60)
        XCTAssertEqual(EarnedAppOptions.defaultPill(deviceCap: 30), 30)
        XCTAssertEqual(EarnedAppOptions.defaultPill(deviceCap: 120), 60)
    }

    // -------------------------------------------------------------------------
    // MARK: Device-cap option generation
    // -------------------------------------------------------------------------

    /// Cap options supplied by the backend are filtered to ≤ pool.
    func testCapOptions_policyCapOptionsFilteredByPool() {
        let opts = EarnedCapOptions.compute(
            policyCapOptions: [30, 60, 90, 120, 180],
            poolMinutes: 90
        )
        XCTAssertEqual(opts, [30, 60, 90])
    }

    /// When no policy cap options are provided, an empty array is returned (no
    /// sensible fallback for device-cap — the UI should hide the picker until
    /// a policy is loaded).
    func testCapOptions_noPolicyReturnsEmpty() {
        let opts = EarnedCapOptions.compute(
            policyCapOptions: nil,
            poolMinutes: 120
        )
        XCTAssertEqual(opts, [])
    }

    // -------------------------------------------------------------------------
    // MARK: Cascade-confirm decision
    // -------------------------------------------------------------------------

    /// Lowering the pool below a device's existing cap triggers needs_confirmation
    /// and the affected device appears in the result.
    func testCascade_loweringPoolBelowDeviceCapNeedsConfirm() {
        let decision = EarnedCascadeDecision.decide(
            newPoolMinutes: 60,
            currentPoolMinutes: 120,
            affectedDevices: [
                .init(deviceID: "dev-1", name: "iPhone 13", currentCapMinutes: 90, newCapMinutes: 60)
            ],
            affectedApps: []
        )
        XCTAssertEqual(decision.needsConfirmation, true)
        XCTAssertEqual(decision.affectedDevices.count, 1)
        XCTAssertEqual(decision.affectedDevices.first?.deviceID, "dev-1")
    }

    /// Lowering the cap below an app's existing budget triggers needs_confirmation
    /// and the affected app appears in the result.
    func testCascade_loweringCapBelowAppBudgetNeedsConfirm() {
        let decision = EarnedCascadeDecision.decide(
            newPoolMinutes: 120,
            currentPoolMinutes: 120,
            affectedDevices: [],
            affectedApps: [
                .init(bundleID: "com.google.youtube", name: "YouTube",
                      currentBudgetMinutes: 90, newBudgetMinutes: 60)
            ]
        )
        XCTAssertEqual(decision.needsConfirmation, true)
        XCTAssertEqual(decision.affectedApps.count, 1)
        XCTAssertEqual(decision.affectedApps.first?.name, "YouTube")
    }

    /// No reduction → no confirmation needed.
    func testCascade_noReductionNoConfirm() {
        let decision = EarnedCascadeDecision.decide(
            newPoolMinutes: 120,
            currentPoolMinutes: 120,
            affectedDevices: [],
            affectedApps: []
        )
        XCTAssertEqual(decision.needsConfirmation, false)
    }

    /// Default action for a cascade confirm is "tomorrow" (not immediate).
    func testCascade_defaultActionIsTomorrow() {
        let decision = EarnedCascadeDecision.decide(
            newPoolMinutes: 60,
            currentPoolMinutes: 120,
            affectedDevices: [
                .init(deviceID: "dev-1", name: "iPhone 13", currentCapMinutes: 90, newCapMinutes: 60)
            ],
            affectedApps: []
        )
        XCTAssertEqual(decision.defaultAction, .applyTomorrow)
    }

    /// Description strings follow the "{name} {old}m → {new}m tomorrow" format.
    func testCascade_descriptionFormat() {
        let affectedApp = EarnedCascadeDecision.AffectedApp(
            bundleID: "com.google.youtube",
            name: "YouTube",
            currentBudgetMinutes: 90,
            newBudgetMinutes: 60
        )
        XCTAssertEqual(affectedApp.description, "YouTube 90m → 60m tomorrow")
    }
}
