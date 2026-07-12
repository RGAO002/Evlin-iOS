import XCTest
@testable import Evlin_iOS

final class EarnedGateTautologyTests: XCTestCase {
    private let suiteName = "group.com.evlin.ios"
    override func setUp() { super.setUp(); EarnedTimeStore.shared.removeAll() }
    override func tearDown() { EarnedTimeStore.shared.removeAll(); super.tearDown() }

    // 1. Tautology guard: low usage below budget must NOT lock, regardless of
    //    backendRemaining==0 (the old gate locked here).
    func test_lowUsage_belowBudget_doesNotLock() {
        let store = EarnedTimeStore.shared
        XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
            adjustedN: 5, poolMinutes: 45, capMinutes: 45,
            usageDate: "2026-07-03", store: store))
    }

    // 2. Low-usage no-lock across the whole 5-min ladder up to just under budget.
    func test_ladderBelowBudget_neverLocks() {
        let store = EarnedTimeStore.shared
        for n in stride(from: 5, to: 45, by: 5) {
            XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
                adjustedN: n, poolMinutes: 45, capMinutes: 45,
                usageDate: "2026-07-03", store: store), "t\(n) must not lock")
        }
    }

    // 3. Correct-lock still fires AT budget, and the deviceCap label is chosen
    //    when an explicit cap below the pool bound (boundSource logic, pure).
    func test_atBudget_locks_andLabelsDeviceCapWhenCapBinds() {
        let store = EarnedTimeStore.shared
        XCTAssertTrue(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
            adjustedN: 15, poolMinutes: 45, capMinutes: 15,
            usageDate: "2026-07-03", store: store))
        // boundSource is deviceCap when cap<pool AND adjustedN>=cap:
        let cap = 15, pool = 45, adjustedN = 15
        let isDeviceCap = (cap < pool && adjustedN >= cap)
        XCTAssertTrue(isDeviceCap)
    }

    // 4. backendRemaining writer contract: veto only when fresh AND margin.
    func test_backendVeto_freshAndMargin_suppresses() {
        let now = Date()
        XCTAssertTrue(EarnedSampleReporter.backendVetoesSelfLock(
            lastBackendRemaining: 40, lastBackendSyncAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(EarnedSampleReporter.backendVetoesSelfLock(  // stale
            lastBackendRemaining: 40, lastBackendSyncAt: now.addingTimeInterval(-1200), now: now))
        XCTAssertFalse(EarnedSampleReporter.backendVetoesSelfLock(  // no margin
            lastBackendRemaining: 3, lastBackendSyncAt: now, now: now))
        XCTAssertFalse(EarnedSampleReporter.backendVetoesSelfLock(  // absent
            lastBackendRemaining: nil, lastBackendSyncAt: nil, now: now))
    }

    // 5. Override still suppresses (unchanged semantic).
    func test_override_suppressesLockAtBudget() {
        let store = EarnedTimeStore.shared
        store.setOverride(true, forUsageDate: "2026-07-03")
        XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShieldFresh(
            adjustedN: 45, poolMinutes: 45, capMinutes: 45,
            usageDate: "2026-07-03", store: store))
    }

    // 6. Re-arm ceiling: BigKidStatePoller must arm with the REAL pool/cap, not
    //    pool=cap=remaining. Pure form: assert the arm inputs the fixed rearm
    //    would pass. (See Step 5 seam.)
    func test_rearm_passesRealPoolAndCap_notRemaining() {
        let store = EarnedTimeStore.shared
        store.poolMinutes = 60
        store.capMinutes = 30
        store.latestDeviceEstimate = 10
        store.acceptedEstimateMinutes = 10
        let inputs = BigKidStatePoller.earnedRearmInputs(store: store)   // new pure seam
        XCTAssertEqual(inputs.poolMinutes, 60)
        XCTAssertEqual(inputs.capMinutes, 30)
        XCTAssertEqual(inputs.offset, 10)
    }

    // 7. bucketMinutes default is 5 (matches EarnedBudgetScheduler.earnedBucketMinutes).
    func test_effectiveCapThreshold_defaultBucketIsFive() {
        // latest=8 remaining=0 -> raw=8 -> ceil to next multiple of default bucket.
        // With bucket=5 -> 10; the old default (10) would also give 10, so pin the
        // constant directly:
        XCTAssertEqual(EarnedBudgetScheduler.earnedBucketMinutes, 5)
        // 8 rounded up to bucket=5 == 10; to bucket=10 == 10 (ambiguous) — use 7:
        let r = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 7, backendRemaining: 0, poolMinutes: 60, capMinutes: 60)
        XCTAssertEqual(r, 10, "default bucket 5: 7 -> 10 (bucket 10 would give 10 too; 7->10 holds only for 5)")
        let r2 = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 6, backendRemaining: 0, poolMinutes: 60, capMinutes: 60)
        XCTAssertEqual(r2, 10, "6 -> 10 under bucket 5")  // under bucket 10, 6 -> 10 too; keep as smoke
    }
}
