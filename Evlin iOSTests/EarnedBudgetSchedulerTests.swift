import XCTest
import DeviceActivity
import FamilyControls
@testable import Evlin_iOS

/// B4 — Pure threshold-planning logic tests.
///
/// These tests exercise `EarnedBudgetScheduler.thresholds(poolMinutes:capMinutes:)`
/// only. No DeviceActivity framework, no live system calls, no entitlements required.
final class EarnedBudgetSchedulerTests: XCTestCase {

    private func generation(
        id: String,
        deviceID: String = "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
        offset: Int = 5,
        signature: String = "signature",
        usageDate: String = "2026-07-11",
        timezone: String = "America/New_York",
        armedAt: Date? = nil
    ) -> EarnedActivityGeneration.Generation {
        EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(
                id: UUID(uuidString: id)!
            ),
            deviceID: deviceID,
            offsetMinutes: offset,
            armSignature: signature,
            usageDate: usageDate,
            timezoneIdentifier: timezone,
            armedAt: armedAt
        )
    }

    func test_plausibilityAcceptsThresholdAtExactCeiling() {
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let generation = generation(
            id: "00000000-0000-0000-0000-000000000001",
            offset: 10,
            armedAt: armedAt
        )

        let result = EarnedThresholdPlausibility.evaluate(
            generation: generation,
            adjustedEstimateMinutes: 20,
            callbackAt: armedAt.addingTimeInterval(5 * 60)
        )

        XCTAssertTrue(result.isPlausible)
        XCTAssertEqual(result.maximumTrusted, 20)
    }

    func test_plausibilityRejectsThresholdAboveCeiling() {
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let generation = generation(
            id: "00000000-0000-0000-0000-000000000002",
            offset: 10,
            armedAt: armedAt
        )

        let result = EarnedThresholdPlausibility.evaluate(
            generation: generation,
            adjustedEstimateMinutes: 21,
            callbackAt: armedAt.addingTimeInterval(5 * 60)
        )

        XCTAssertFalse(result.isPlausible)
        XCTAssertEqual(result.maximumTrusted, 20)
    }

    func test_plausibilityRejectsCallbackBeforeArm() {
        let armedAt = Date(timeIntervalSince1970: 1_784_003_200)
        let generation = generation(
            id: "00000000-0000-0000-0000-000000000003",
            offset: 10,
            armedAt: armedAt
        )

        let result = EarnedThresholdPlausibility.evaluate(
            generation: generation,
            adjustedEstimateMinutes: 10,
            callbackAt: armedAt.addingTimeInterval(-1)
        )

        XCTAssertFalse(result.isPlausible)
        XCTAssertEqual(result.maximumTrusted, 15)
    }

    func test_makeEventExcludesPastActivity() {
        let event = EarnedBudgetScheduler.makeEvent(
            selection: FamilyActivitySelection(),
            thresholdMinutes: 5
        )

        XCTAssertFalse(event.includesPastActivity)
    }

    func test_callbackFirewallAcceptsOnlyActiveGeneration() {
        let active = generation(id: "11111111-1111-1111-1111-111111111111")
        let stale = generation(id: "22222222-2222-2222-2222-222222222222")
        let lifecycle = EarnedActivityGeneration.Lifecycle(active: active, pending: nil)

        XCTAssertEqual(
            EarnedActivityGeneration.authorizedCallback(
                activityName: active.activityName,
                currentDeviceID: active.deviceID,
                lifecycle: lifecycle
            ),
            active
        )
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: stale.activityName,
            currentDeviceID: active.deviceID,
            lifecycle: lifecycle
        ))
    }

    func test_callbackFirewallRejectsActiveGenerationForDifferentChildDevice() {
        let active = generation(id: "10101010-1010-1010-1010-101010101010")

        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: active.activityName,
            currentDeviceID: "0d45589a-722c-4e43-a06e-7501f484a46c",
            lifecycle: .init(active: active, pending: nil)
        ))
    }

    func test_callbackFirewallRejectsPendingAndStoppedGenerations() {
        let pending = generation(id: "33333333-3333-3333-3333-333333333333")

        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: pending.activityName,
            currentDeviceID: pending.deviceID,
            lifecycle: .init(active: nil, pending: pending)
        ))
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: pending.activityName,
            currentDeviceID: pending.deviceID,
            lifecycle: .init(active: nil, pending: nil)
        ))
    }

    func test_legacyCallbackRequiresExplicitActiveLegacyProof() {
        let legacy = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.legacyActivityName,
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            offsetMinutes: 10,
            armSignature: "legacy-signature",
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/New_York"
        )
        let generated = generation(id: "44444444-4444-4444-4444-444444444444")

        XCTAssertEqual(EarnedActivityGeneration.authorizedCallback(
            activityName: EarnedActivityGeneration.legacyActivityName,
            currentDeviceID: legacy.deviceID,
            lifecycle: .init(active: legacy, pending: nil)
        ), legacy)
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: EarnedActivityGeneration.legacyActivityName,
            currentDeviceID: legacy.deviceID,
            lifecycle: .init(active: generated, pending: nil)
        ))
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: EarnedActivityGeneration.legacyActivityName,
            currentDeviceID: legacy.deviceID,
            lifecycle: .init(active: nil, pending: nil)
        ))
    }

    func test_legacyMigrationPersistsNarrowCallbackProof() throws {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.legacyActivityName,
            deviceID: "b21411cb-63a5-4489-bc68-bf8ac26ee15b",
            offsetMinutes: 10,
            armSignature: "legacy-signature",
            usageDate: "2026-07-11",
            timezoneIdentifier: "America/New_York"
        )

        EarnedActivityGeneration.migrateActiveIfNeeded(legacy, defaults: defaults)

        let lifecycle = EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        XCTAssertEqual(lifecycle?.active, legacy)
        XCTAssertEqual(EarnedActivityGeneration.authorizedCallback(
            activityName: EarnedActivityGeneration.legacyActivityName,
            currentDeviceID: legacy.deviceID,
            lifecycle: lifecycle
        ), legacy)
    }

    func test_preStartPendingIsPersistedAndRejectedByCallbackFirewall() throws {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pending = generation(id: "55555555-5555-5555-5555-555555555555")

        EarnedActivityGeneration.persistPending(pending, defaults: defaults)

        let lifecycle = try XCTUnwrap(EarnedActivityGeneration.loadLifecycle(defaults: defaults))
        XCTAssertNil(lifecycle.active)
        XCTAssertEqual(lifecycle.pending, pending)
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: pending.activityName,
            currentDeviceID: pending.deviceID,
            lifecycle: lifecycle
        ))
    }

    func test_recoveryStopsAndClearsCrashEquivalentPendingButPreservesActive() throws {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let active = generation(id: "66666666-6666-6666-6666-666666666666")
        let pending = generation(id: "77777777-7777-7777-7777-777777777777")
        EarnedActivityGeneration.persistLifecycle(
            .init(active: active, pending: pending),
            defaults: defaults
        )
        var stopped: [String] = []

        EarnedActivityGeneration.recoverPending(
            defaults: defaults,
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertEqual(stopped, [pending.activityName])
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults),
            .init(active: active, pending: nil)
        )
    }

    func test_recoveryStopsPostPromotionRetiringNamesAndPreservesNewActive() throws {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prior = generation(id: "12121212-1212-1212-1212-121212121212")
        let active = generation(id: "34343434-3434-3434-3434-343434343434")
        EarnedActivityGeneration.persistLifecycle(
            .init(
                active: active,
                pending: nil,
                retiringActivityNames: [
                    prior.activityName,
                    EarnedActivityGeneration.legacyActivityName,
                ]
            ),
            defaults: defaults
        )
        var stopped: [String] = []

        EarnedActivityGeneration.recoverPending(
            defaults: defaults,
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertEqual(stopped, [
            prior.activityName,
            EarnedActivityGeneration.legacyActivityName,
        ])
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults),
            .init(active: active, pending: nil)
        )
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: prior.activityName,
            currentDeviceID: active.deviceID,
            lifecycle: EarnedActivityGeneration.loadLifecycle(defaults: defaults)
        ))
    }

    func test_persistenceFailurePreventsStartMonitoring() {
        let next = generation(id: "56565656-5656-5656-5656-565656565656")
        var startCount = 0

        let installed = EarnedActivityGeneration.installReplacement(
            next,
            defaults: nil,
            startMonitoring: { _ in startCount += 1 },
            stopMonitoring: { _ in }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(startCount, 0)
    }

    func test_corruptLifecycleRecoveryStopsAllBreadcrumbNamesAndLeavesStoppedProof() throws {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let active = generation(id: "67676767-6767-6767-6767-676767676767")
        let pending = generation(id: "78787878-7878-7878-7878-787878787878")
        defaults.set(
            [active.activityName, pending.activityName],
            forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey
        )
        defaults.set(Data("corrupt".utf8), forKey: EarnedActivityGeneration.lifecycleKey)
        var stopped: [String] = []

        EarnedActivityGeneration.recoverPending(
            defaults: defaults,
            stopMonitoring: { stopped = $0 }
        )

        XCTAssertEqual(Set(stopped), Set([
            active.activityName,
            pending.activityName,
            EarnedActivityGeneration.legacyActivityName,
        ]))
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults)?.isStopped,
            true
        )
    }

    func test_lifecycleDecodeDefaultsNewVersionedFieldsForMigration() throws {
        let activeName = EarnedActivityGeneration.generatedActivityName(
            id: UUID(uuidString: "89898989-8989-8989-8989-898989898989")!
        )
        let json = """
        {"active":{"activityName":"\(activeName)","deviceID":"b21411cb-63a5-4489-bc68-bf8ac26ee15b","offsetMinutes":5,"armSignature":"sig","usageDate":"2026-07-11","timezoneIdentifier":"America/New_York"},"pending":null}
        """

        let decoded = try JSONDecoder().decode(
            EarnedActivityGeneration.Lifecycle.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.version, 1)
        XCTAssertFalse(decoded.isStopped)
        XCTAssertTrue(decoded.retiringActivityNames.isEmpty)
    }

    func test_successfulInstallPromotesBeforeRetiringPriorAndLegacy() throws {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prior = generation(id: "88888888-8888-8888-8888-888888888888")
        let next = generation(id: "99999999-9999-9999-9999-999999999999", offset: 15)
        EarnedActivityGeneration.persistLifecycle(
            .init(active: prior, pending: nil),
            defaults: defaults
        )
        var lifecycleWhenStopped: EarnedActivityGeneration.Lifecycle?

        let installed = EarnedActivityGeneration.installReplacement(
            next,
            defaults: defaults,
            startMonitoring: { _ in },
            stopMonitoring: { _ in
                lifecycleWhenStopped = EarnedActivityGeneration
                    .loadLifecycle(defaults: defaults)
            }
        )

        XCTAssertTrue(installed)
        XCTAssertEqual(lifecycleWhenStopped?.active, next)
        XCTAssertEqual(lifecycleWhenStopped?.retiringActivityNames, [
            prior.activityName,
            EarnedActivityGeneration.legacyActivityName,
        ])
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults),
            .init(active: next, pending: nil)
        )
    }

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

    func test_failedGenerationInstallPreservesPriorGenerationAndClearsFailedPending() {
        enum StartFailure: Error { case failed }
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prior = generation(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let failed = generation(id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", offset: 15)
        EarnedActivityGeneration.persistLifecycle(
            .init(active: prior, pending: nil),
            defaults: defaults
        )
        var stopped: [[String]] = []

        let installed = EarnedActivityGeneration.installReplacement(
            failed,
            defaults: defaults,
            startMonitoring: { _ in throw StartFailure.failed },
            stopMonitoring: { stopped.append($0) }
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults),
            .init(active: prior, pending: nil)
        )
        XCTAssertEqual(stopped, [[failed.activityName]])
    }

    func test_successiveGenerationInstallsStopPriorAndLegacyThenPersistFreshName() {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = generation(id: "11111111-1111-1111-1111-111111111111")
        let second = generation(id: "22222222-2222-2222-2222-222222222222")
        var started: [String] = []
        var stopped: [[String]] = []

        let firstInstalled = EarnedActivityGeneration.installReplacement(
            first,
            defaults: defaults,
            startMonitoring: { started.append($0) },
            stopMonitoring: { stopped.append($0) }
        )
        let secondInstalled = EarnedActivityGeneration.installReplacement(
            second,
            defaults: defaults,
            startMonitoring: { started.append($0) },
            stopMonitoring: { stopped.append($0) }
        )

        XCTAssertTrue(firstInstalled)
        XCTAssertTrue(secondInstalled)
        XCTAssertNotEqual(first.activityName, second.activityName)
        XCTAssertEqual(started, [first.activityName, second.activityName])
        XCTAssertEqual(stopped.first, [EarnedActivityGeneration.legacyActivityName])
        XCTAssertEqual(
            stopped.last,
            [first.activityName, EarnedActivityGeneration.legacyActivityName]
        )
        XCTAssertEqual(
            defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            second.activityName
        )
    }

    func test_stopPersistedGenerationStopsActiveAndLegacyThenRemovesPersistence() {
        let suiteName = "EarnedBudgetSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let active = generation(id: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        let pending = generation(id: "dddddddd-dddd-dddd-dddd-dddddddddddd")
        EarnedActivityGeneration.persistLifecycle(
            .init(active: active, pending: pending),
            defaults: defaults
        )
        var stopped: [String] = []
        var lifecycleWhenStopped: EarnedActivityGeneration.Lifecycle?

        EarnedActivityGeneration.stopPersisted(
            defaults: defaults,
            stopMonitoring: {
                stopped = $0
                lifecycleWhenStopped = EarnedActivityGeneration
                    .loadLifecycle(defaults: defaults)
            }
        )

        XCTAssertEqual(stopped, [
            pending.activityName,
            active.activityName,
            EarnedActivityGeneration.legacyActivityName,
        ])
        XCTAssertNil(lifecycleWhenStopped?.active)
        XCTAssertEqual(lifecycleWhenStopped?.retiringActivityNames, stopped)
        XCTAssertNil(EarnedActivityGeneration.authorizedCallback(
            activityName: active.activityName,
            currentDeviceID: active.deviceID,
            lifecycle: lifecycleWhenStopped
        ))
        XCTAssertEqual(
            EarnedActivityGeneration.loadLifecycle(defaults: defaults)?.isStopped,
            true
        )
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

    func test_thresholds_300MinutePolicyRetainsExactTerminalWithin48Events() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 300, capMinutes: 300)

        XCTAssertLessThanOrEqual(result.count, 48)
        XCTAssertEqual(result.last, 300)
        XCTAssertEqual(result, result.sorted())
        XCTAssertEqual(Set(result).count, result.count)
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

    func test_resumeScheduleUsesBackendTimezoneForPolicyDayBoundary() {
        let backendTimeZone = TimeZone(identifier: "America/Los_Angeles")!
        let deviceCalendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_768_173_300) // 2026-01-11T23:15:00Z

        let schedule = EarnedBudgetScheduler.resumeSchedule(
            startingAt: start,
            timeZone: backendTimeZone,
            calendar: deviceCalendar
        )

        XCTAssertEqual(schedule.intervalStart.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalStart.hour, 15)
        XCTAssertEqual(schedule.intervalEnd.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalEnd.hour, 23)
        XCTAssertEqual(schedule.intervalEnd.minute, 59)
    }

    func test_dailyScheduleCarriesBackendTimezoneInBothBoundaries() {
        let backendTimeZone = TimeZone(identifier: "Pacific/Honolulu")!

        let schedule = EarnedBudgetScheduler.dailySchedule(
            timeZone: backendTimeZone
        )

        XCTAssertEqual(schedule.intervalStart.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalStart.hour, 0)
        XCTAssertEqual(schedule.intervalEnd.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalEnd.hour, 23)
        XCTAssertEqual(schedule.intervalEnd.minute, 59)
        XCTAssertTrue(schedule.repeats)
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
