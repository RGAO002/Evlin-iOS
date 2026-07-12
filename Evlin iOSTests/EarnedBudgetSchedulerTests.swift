import XCTest
import DeviceActivity
@testable import Evlin_iOS

/// B4 — Pure threshold-planning logic tests.
///
/// These tests exercise `EarnedBudgetScheduler.thresholds(poolMinutes:capMinutes:)`
/// only. No DeviceActivity framework, no live system calls, no entitlements required.
final class EarnedBudgetSchedulerTests: XCTestCase {

    func test_generatedActivityNamesAreDistinctAndRecognized() {
        let first = EarnedActivityGeneration.generatedActivityName(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = EarnedActivityGeneration.generatedActivityName(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(EarnedActivityGeneration.isEarnedActivityName(first))
        XCTAssertTrue(EarnedActivityGeneration.isEarnedActivityName(second))
        XCTAssertTrue(EarnedActivityGeneration.isEarnedActivityName(
            EarnedActivityGeneration.legacyActivityName
        ))
        XCTAssertFalse(EarnedActivityGeneration.isEarnedActivityName("evlin.earned.other"))
    }

    func test_stopTargetsIncludePersistedGenerationAndLegacy() {
        let active = EarnedActivityGeneration.generatedActivityName(id: UUID())

        XCTAssertEqual(
            EarnedActivityGeneration.stopTargets(activeActivityName: active),
            [active, EarnedActivityGeneration.legacyActivityName]
        )
        XCTAssertEqual(
            EarnedActivityGeneration.stopTargets(activeActivityName: nil),
            [EarnedActivityGeneration.legacyActivityName]
        )
    }

    func test_failedGenerationInstallPreservesPriorGenerationAndStopsNothing() {
        enum StartFailure: Error { case failed }
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prior = EarnedActivityGeneration.generatedActivityName(id: UUID())
        defaults.set(prior, forKey: EarnedActivityGeneration.activeActivityNameKey)
        var stopped: [String] = []

        let installed = EarnedActivityGeneration.installReplacement(
            id: UUID(),
            defaults: defaults,
            startMonitoring: { _ in throw StartFailure.failed },
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertNil(installed)
        XCTAssertEqual(
            defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            prior
        )
        XCTAssertTrue(stopped.isEmpty)
    }

    func test_successiveGenerationInstallsStopPriorAndLegacyThenPersistFreshName() {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var started: [String] = []
        var stopped: [[String]] = []

        let first = EarnedActivityGeneration.installReplacement(
            id: firstID,
            defaults: defaults,
            startMonitoring: { started.append($0) },
            stopMonitoring: { stopped.append($0) }
        )
        let second = EarnedActivityGeneration.installReplacement(
            id: secondID,
            defaults: defaults,
            startMonitoring: { started.append($0) },
            stopMonitoring: { stopped.append($0) }
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(started, [first, second].compactMap { $0 })
        XCTAssertEqual(stopped.first, [EarnedActivityGeneration.legacyActivityName])
        XCTAssertEqual(
            stopped.last,
            [first!, EarnedActivityGeneration.legacyActivityName]
        )
        XCTAssertEqual(
            defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            second
        )
    }

    func test_stopPersistedGenerationStopsActiveAndLegacyThenRemovesPersistence() {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let active = EarnedActivityGeneration.generatedActivityName(id: UUID())
        defaults.set(active, forKey: EarnedActivityGeneration.activeActivityNameKey)
        var stopped: [String] = []

        EarnedActivityGeneration.stopPersisted(
            defaults: defaults,
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertEqual(stopped, [active, EarnedActivityGeneration.legacyActivityName])
        XCTAssertNil(defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey))
    }

    // MARK: - Bucket constant

    func test_bucketMinutes_isFive() {
        XCTAssertEqual(EarnedBudgetScheduler.earnedBucketMinutes, 5)
    }

    // MARK: - Basic capping at cap (cap < pool, multiple of bucket)

    func test_thresholds_pool120_cap90_stopsAtCap() {
        // cap=90, buckets: 5,10,15,...,90 (all multiples up to cap)
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 90)
        let expected = stride(from: 5, through: 90, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Exact cap appended when not a multiple of bucket

    func test_thresholds_pool120_cap95_appendsExactCap() {
        // cap=97, buckets up to 95 (last multiple ≤ 97), then 97 appended
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 97)
        let multiples = stride(from: 5, through: 95, by: 5).map { $0 }
        let expected = multiples + [97]
        XCTAssertEqual(result, expected)
    }

    // MARK: - pool == cap (full range)

    func test_thresholds_pool120_cap120_coversFullRange() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 120)
        let expected = stride(from: 5, through: 120, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Pool smaller than cap → capped at pool

    func test_thresholds_pool60_cap120_cappedAtPool() {
        // effective ceiling = min(60, 120) = 60
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 60, capMinutes: 120)
        let expected = stride(from: 5, through: 60, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
    }

    func test_thresholds_pool240_cap240_coversFourHoursAtFiveMinuteGranularity() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 240, capMinutes: 240)
        let expected = stride(from: 5, through: 240, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.count, 48)
        XCTAssertEqual(EarnedBudgetScheduler.guardEventCount, 48)
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
        // cap=90 is already a multiple of 5; it must appear exactly once
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
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 97)
        for i in 1..<result.count {
            XCTAssertLessThan(result[i - 1], result[i], "thresholds must be strictly ascending")
        }
    }

    func test_remainingPolicyArmsOnlyUncountedWindowAfterOffset() {
        let policy = EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: 20,
            capMinutes: 20,
            offsetMinutes: 5
        )

        XCTAssertEqual(policy?.poolMinutes, 15)
        XCTAssertEqual(policy?.capMinutes, 15)
        XCTAssertEqual(
            EarnedBudgetScheduler.thresholds(
                poolMinutes: policy?.poolMinutes ?? 0,
                capMinutes: policy?.capMinutes ?? 0
            ),
            [5, 10, 15]
        )
    }

    func test_remainingPolicyReturnsNilWhenOffsetAlreadyExhausted() {
        XCTAssertNil(EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: 20,
            capMinutes: 20,
            offsetMinutes: 20
        ))
        XCTAssertNil(EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: 20,
            capMinutes: 15,
            offsetMinutes: 15
        ))
    }

    func test_resumeScheduleStartsAtNowAndDoesNotRepeatFromMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 3,
            hour: 14,
            minute: 32,
            second: 16
        ).date!

        let schedule = EarnedBudgetScheduler.resumeSchedule(startingAt: start, calendar: calendar)

        XCTAssertEqual(schedule.intervalStart.year, 2026)
        XCTAssertEqual(schedule.intervalStart.month, 7)
        XCTAssertEqual(schedule.intervalStart.day, 3)
        XCTAssertEqual(schedule.intervalStart.hour, 14)
        XCTAssertEqual(schedule.intervalStart.minute, 32)
        XCTAssertEqual(schedule.intervalStart.second, 16)
        XCTAssertEqual(schedule.intervalEnd.hour, 23)
        XCTAssertEqual(schedule.intervalEnd.minute, 59)
        XCTAssertFalse(schedule.repeats)
    }
}
