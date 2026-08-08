import XCTest
@testable import Evlin_iOS

// MARK: - Spy / fake for putDeviceCap

/// Fake that records whether putDeviceCap was called. Used by cascade-gate tests
/// so we can assert that the API is NOT invoked when confirmation is pending.
final class DeviceCapAPISpy {
    private(set) var putDeviceCapCallCount = 0
    private(set) var lastCapMinutes: Int? = nil

    func putDeviceCap(childDeviceID: UUID, dailyCapMinutes: Int) async throws {
        putDeviceCapCallCount += 1
        lastCapMinutes = dailyCapMinutes
    }
}

// MARK: - Testable cascade-gate helper
//
// Mirrors the gate logic inside DeviceAppsSheet.saveDeviceCap so it can be
// exercised without SwiftUI @State.
//
// The gate:
//   • If confirmedCascade is false AND any enabled app has limitMin > newCap,
//     compute the cascade decision. If needsConfirmation, set pendingCascade
//     and return WITHOUT calling the API.
//   • Otherwise call the API (represented here as the spy).

struct DeviceCapSaveGateResult {
    let pendingCascade: EarnedCascadeDecision.Result?
    let apiWasCalled: Bool
}

@MainActor
func exerciseDeviceCapSaveGate(
    newCap: Int,
    confirmedCascade: Bool,
    enabledApps: [(name: String, bundleID: String, limitMin: Int)],
    poolMinutes: Int?,
    spy: DeviceCapAPISpy
) async -> DeviceCapSaveGateResult {
    // Build affected-app list exactly as saveDeviceCap does.
    let affectedApps = enabledApps
        .filter { $0.limitMin > newCap }
        .map { app in
            EarnedCascadeDecision.AffectedApp(
                bundleID: app.bundleID,
                name: app.name,
                currentBudgetMinutes: app.limitMin,
                newBudgetMinutes: newCap)
        }

    if !confirmedCascade {
        let currentPool = poolMinutes ?? newCap
        let decision = EarnedCascadeDecision.decide(
            newPoolMinutes: newCap,
            currentPoolMinutes: currentPool,
            affectedDevices: [],
            affectedApps: affectedApps)
        if decision.needsConfirmation {
            return DeviceCapSaveGateResult(pendingCascade: decision, apiWasCalled: false)
        }
    }

    // Gate passed (or confirmedCascade = true) → call API.
    try? await spy.putDeviceCap(
        childDeviceID: UUID(),
        dailyCapMinutes: newCap)
    return DeviceCapSaveGateResult(pendingCascade: nil, apiWasCalled: true)
}

// MARK: - Pure logic tests for B9 option generation + cascade-confirm decision.
//
// All tests are network-free and UI-free. They exercise two pure helpers
// introduced in EarnedScreenTimeHelpers.swift:
//
//   EarnedAppOptions.compute(...)     — dynamic limit picker options
//   EarnedCascadeDecision.decide(...) — should we show a confirm sheet?

final class EarnedConfigUITests: XCTestCase {

    func testDailyScreenTimeEditRequiresEffectiveDateChoiceWhenRaised() {
        XCTAssertTrue(
            PoolEditConfirmationPolicy.requiresEffectiveDateChoice(
                currentMinutes: 60,
                newMinutes: 120
            )
        )
    }

    func testDailyScreenTimeEditRequiresEffectiveDateChoiceWhenLowered() {
        XCTAssertTrue(
            PoolEditConfirmationPolicy.requiresEffectiveDateChoice(
                currentMinutes: 120,
                newMinutes: 60
            )
        )
    }

    func testDailyScreenTimeEditDoesNotRequireChoiceWhenValueIsUnchanged() {
        XCTAssertFalse(
            PoolEditConfirmationPolicy.requiresEffectiveDateChoice(
                currentMinutes: 120,
                newMinutes: 120
            )
        )
    }

    func testPoolEditWaitsForEditorDismissalBeforeRequestingCascadePresentation() {
        var handoff = PoolEditPresentationHandoff()

        handoff.submit(minutes: 60)

        XCTAssertEqual(handoff.pendingMinutes, 60)
        XCTAssertEqual(handoff.consumeAfterEditorDismissal(), 60)
        XCTAssertNil(handoff.pendingMinutes)
        XCTAssertNil(handoff.consumeAfterEditorDismissal())
    }

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

    // -------------------------------------------------------------------------
    // MARK: Device-cap save gate (R10/R11/R12)
    // -------------------------------------------------------------------------

    /// Lowering a device cap below an existing enabled app-limit rule gates on
    /// confirmation: pendingCascade is set and putDeviceCap is NOT called.
    func testDeviceCapSave_loweringBelowAppRule_setsPendingCascadeAndBlocksAPI() async {
        let spy = DeviceCapAPISpy()
        let result = await exerciseDeviceCapSaveGate(
            newCap: 30,
            confirmedCascade: false,
            enabledApps: [
                (name: "YouTube", bundleID: "com.google.youtube", limitMin: 60)
            ],
            poolMinutes: 120,
            spy: spy)

        XCTAssertNotNil(result.pendingCascade, "pendingCascade must be set when cap < app rule")
        XCTAssertTrue(result.pendingCascade?.needsConfirmation == true,
                      "needsConfirmation must be true")
        XCTAssertEqual(result.pendingCascade?.affectedApps.first?.name, "YouTube")
        XCTAssertFalse(result.apiWasCalled,
                       "putDeviceCap must NOT be called before the user confirms")
        XCTAssertEqual(spy.putDeviceCapCallCount, 0,
                       "Spy must record zero API calls before confirmation")
    }

    /// When the cap is NOT lower than any app rule, putDeviceCap is called
    /// immediately (no cascade confirmation needed).
    func testDeviceCapSave_noViolation_callsAPIDirectly() async {
        let spy = DeviceCapAPISpy()
        let result = await exerciseDeviceCapSaveGate(
            newCap: 90,
            confirmedCascade: false,
            enabledApps: [
                (name: "YouTube", bundleID: "com.google.youtube", limitMin: 60)
            ],
            poolMinutes: 120,
            spy: spy)

        XCTAssertNil(result.pendingCascade,
                     "pendingCascade must be nil when no app rule is exceeded")
        XCTAssertTrue(result.apiWasCalled, "putDeviceCap must be called when no cascade needed")
        XCTAssertEqual(spy.putDeviceCapCallCount, 1)
        XCTAssertEqual(spy.lastCapMinutes, 90)
    }

    /// After the user confirms (confirmedCascade = true), putDeviceCap is called
    /// even though the new cap is below the existing app rule.
    func testDeviceCapSave_confirmedCascade_callsAPI() async {
        let spy = DeviceCapAPISpy()
        let result = await exerciseDeviceCapSaveGate(
            newCap: 30,
            confirmedCascade: true,   // user already confirmed
            enabledApps: [
                (name: "YouTube", bundleID: "com.google.youtube", limitMin: 60)
            ],
            poolMinutes: 120,
            spy: spy)

        XCTAssertNil(result.pendingCascade,
                     "pendingCascade must be nil once the user has confirmed")
        XCTAssertTrue(result.apiWasCalled,
                      "putDeviceCap must be called after the user confirms")
        XCTAssertEqual(spy.putDeviceCapCallCount, 1)
        XCTAssertEqual(spy.lastCapMinutes, 30)
    }

    /// Multiple affected apps all appear in the cascade result.
    func testDeviceCapSave_multipleAppRulesExceeded_allAppearInCascade() async {
        let spy = DeviceCapAPISpy()
        let result = await exerciseDeviceCapSaveGate(
            newCap: 20,
            confirmedCascade: false,
            enabledApps: [
                (name: "YouTube", bundleID: "com.google.youtube", limitMin: 60),
                (name: "Instagram", bundleID: "com.burbn.instagram", limitMin: 45),
                (name: "TikTok", bundleID: "com.zhiliaoapp.musically", limitMin: 15) // 15 ≤ 20 — OK
            ],
            poolMinutes: 120,
            spy: spy)

        XCTAssertNotNil(result.pendingCascade)
        XCTAssertEqual(result.pendingCascade?.affectedApps.count, 2,
                       "Only apps exceeding the new cap should appear (TikTok at 15 is fine)")
        XCTAssertFalse(result.apiWasCalled)
    }
}
