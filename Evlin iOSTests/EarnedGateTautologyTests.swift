import XCTest
@testable import Evlin_iOS

final class EarnedGateTautologyTests: XCTestCase {
    private let suiteName = "group.com.evlin.ios"
    override func setUp() { super.setUp(); EarnedTimeStore.shared.removeAll() }
    override func tearDown() { EarnedTimeStore.shared.removeAll(); super.tearDown() }

    // Re-arm ceiling: BigKidStatePoller must arm with the REAL pool/cap, not
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

    // bucketMinutes default is 5 (matches EarnedBudgetScheduler.earnedBucketMinutes).
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
