import XCTest
@testable import Evlin_iOS

/// B4 — Pure threshold-planning logic tests.
///
/// These tests exercise `EarnedBudgetScheduler.thresholds(poolMinutes:capMinutes:)`
/// only. No DeviceActivity framework, no live system calls, no entitlements required.
final class EarnedBudgetSchedulerTests: XCTestCase {

    // MARK: - Bucket constant

    func test_bucketMinutes_isTen() {
        XCTAssertEqual(EarnedBudgetScheduler.earnedBucketMinutes, 10)
    }

    // MARK: - Basic capping at cap (cap < pool, multiple of bucket)

    func test_thresholds_pool120_cap90_stopsAtCap() {
        // cap=90, buckets: 10,20,30,...,90 (all multiples up to cap)
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 90)
        let expected = stride(from: 10, through: 90, by: 10).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Exact cap appended when not a multiple of bucket

    func test_thresholds_pool120_cap95_appendsExactCap() {
        // cap=95, buckets up to 90 (last multiple ≤ 95), then 95 appended
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 95)
        let multiples = stride(from: 10, through: 90, by: 10).map { $0 }
        let expected = multiples + [95]
        XCTAssertEqual(result, expected)
    }

    // MARK: - pool == cap (full range)

    func test_thresholds_pool120_cap120_coversFullRange() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 120)
        let expected = stride(from: 10, through: 120, by: 10).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Pool smaller than cap → capped at pool

    func test_thresholds_pool60_cap120_cappedAtPool() {
        // effective ceiling = min(60, 120) = 60
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 60, capMinutes: 120)
        let expected = stride(from: 10, through: 60, by: 10).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Event count guard

    func test_thresholds_neverExceedsGuardConstant() {
        // Even with a very large pool/cap the count stays ≤ guardEventCount
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 10_000, capMinutes: 10_000)
        XCTAssertLessThanOrEqual(result.count, EarnedBudgetScheduler.guardEventCount)
    }

    // MARK: - Threshold list never exceeds min(pool, cap)

    func test_thresholds_neverExceedsMinPoolCap() {
        let cases: [(pool: Int, cap: Int)] = [
            (90, 90), (120, 90), (90, 120),
            (45, 50), (50, 45), (240, 240)
        ]
        for (pool, cap) in cases {
            let result = EarnedBudgetScheduler.thresholds(poolMinutes: pool, capMinutes: cap)
            let ceiling = min(pool, cap)
            XCTAssertTrue(
                result.allSatisfy { $0 <= ceiling },
                "pool=\(pool) cap=\(cap) — found threshold > \(ceiling): \(result)"
            )
        }
    }

    // MARK: - Exact cap NOT duplicated when already a bucket multiple

    func test_thresholds_capAlreadyMultipleOfBucket_notDuplicated() {
        // cap=90 is already a multiple of 10; it must appear exactly once
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 90)
        let count = result.filter { $0 == 90 }.count
        XCTAssertEqual(count, 1, "cap=90 (already a bucket multiple) must appear exactly once")
    }

    // MARK: - Edge: pool or cap ≤ 0 → empty

    func test_thresholds_zeroPool_isEmpty() {
        XCTAssertTrue(EarnedBudgetScheduler.thresholds(poolMinutes: 0, capMinutes: 60).isEmpty)
    }

    func test_thresholds_zeroCap_isEmpty() {
        XCTAssertTrue(EarnedBudgetScheduler.thresholds(poolMinutes: 60, capMinutes: 0).isEmpty)
    }

    // MARK: - Ascending order

    func test_thresholds_alwaysAscending() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 95)
        for i in 1..<result.count {
            XCTAssertLessThan(result[i - 1], result[i], "thresholds must be strictly ascending")
        }
    }
}
