import XCTest
@testable import Evlin_iOS

/// B5 — Pure-logic tests for earned-time sample reporting + cap/tripwire math.
///
/// These tests cover:
///   1. Sample body shape + stable `client_sample_id`
///   2. Retry-queue enqueue on simulated POST failure
///   3. Tripwire math (`latestEstimate + backendRemaining`, rounded up to next armed
///      threshold, capped at `min(pool, cap)`)
///   4. Override flag present → no `.earnedTime` applied
///   5. Daily strip removes ONLY `.earnedTime` (preserves `.manual`/`.limit`)
///   6. Mixed `{.limit, .earnedTime}` strip of `.earnedTime` leaves `{.limit}` — B1 carry
///
/// No DeviceActivity types, no network calls, no ManagedSettingsStore — all pure logic.
final class EarnedSampleReporterTests: XCTestCase {

    private let suiteName = "group.com.evlin.ios"
    private let retryKey  = "evlin.earnedSampleRetryQueue"
    private let shieldsKey = "evlin.shieldRecords"

    override func setUp() {
        super.setUp()
        let d = UserDefaults(suiteName: suiteName)
        d?.removeObject(forKey: retryKey)
        d?.removeObject(forKey: shieldsKey)
        EarnedTimeStore.shared.removeAll()
    }

    override func tearDown() {
        let d = UserDefaults(suiteName: suiteName)
        d?.removeObject(forKey: retryKey)
        d?.removeObject(forKey: shieldsKey)
        EarnedTimeStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - 1. Sample body shape + stable client_sample_id

    func test_sampleBody_hasRequiredFields() throws {
        let deviceID = UUID()
        let usageDate = "2026-06-23"
        let n = 30
        let body = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: "America/Los_Angeles",
            thresholdMinutes: n,
            estimatedMinutes: n,
            observedAt: "2026-06-23T10:00:00Z"
        )

        XCTAssertEqual(body["device_id"] as? String, deviceID.uuidString)
        XCTAssertEqual(body["usage_date"] as? String, usageDate)
        XCTAssertEqual(body["timezone"] as? String, "America/Los_Angeles")
        XCTAssertEqual(body["activity_name"] as? String, "evlin.earned.budget")
        XCTAssertEqual(body["event_name"] as? String, "evlin.earned.t\(n)")
        XCTAssertEqual(body["threshold_minutes"] as? Int, n)
        XCTAssertEqual(body["estimated_minutes"] as? Int, n)
        XCTAssertEqual(body["observed_at"] as? String, "2026-06-23T10:00:00Z")
        XCTAssertNotNil(body["client_sample_id"])
    }

    func test_sampleBody_clientSampleId_isStable() {
        // Same inputs → same id (idempotency key).
        let deviceID = UUID()
        let usageDate = "2026-06-23"
        let n = 20

        let body1 = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: "UTC",
            thresholdMinutes: n,
            estimatedMinutes: n,
            observedAt: "2026-06-23T08:00:00Z"
        )
        let body2 = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: usageDate,
            timezone: "UTC",
            thresholdMinutes: n,
            estimatedMinutes: n + 5, // estimatedMinutes intentionally different
            observedAt: "2026-06-23T09:00:00Z"
        )

        // client_sample_id is derived from deviceID + usageDate + thresholdN only.
        XCTAssertEqual(
            body1["client_sample_id"] as? String,
            body2["client_sample_id"] as? String,
            "client_sample_id must be stable across varying estimated_minutes / observed_at"
        )
    }

    func test_sampleBody_clientSampleId_format() {
        let deviceID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let body = EarnedSampleReporter.makeSampleBody(
            deviceID: deviceID,
            usageDate: "2026-06-23",
            timezone: "UTC",
            thresholdMinutes: 40,
            estimatedMinutes: 40,
            observedAt: "2026-06-23T10:00:00Z"
        )
        // Expected format: "earned:<device_id_uuidstring_lowercased>:<usage_date>:t<N>"
        let id = body["client_sample_id"] as? String ?? ""
        XCTAssertTrue(
            id.hasPrefix("earned:"),
            "client_sample_id must start with 'earned:' — got '\(id)'"
        )
        XCTAssertTrue(
            id.contains(":2026-06-23:"),
            "client_sample_id must include usage_date — got '\(id)'"
        )
        XCTAssertTrue(
            id.hasSuffix(":t40"),
            "client_sample_id must end with ':t<N>' — got '\(id)'"
        )
    }

    func test_sampleBody_clientSampleId_differsByThreshold() {
        let deviceID = UUID()
        let usageDate = "2026-06-23"

        let body10 = EarnedSampleReporter.makeSampleBody(deviceID: deviceID, usageDate: usageDate,
                                                          timezone: "UTC", thresholdMinutes: 10,
                                                          estimatedMinutes: 10, observedAt: "2026-06-23T10:00:00Z")
        let body20 = EarnedSampleReporter.makeSampleBody(deviceID: deviceID, usageDate: usageDate,
                                                          timezone: "UTC", thresholdMinutes: 20,
                                                          estimatedMinutes: 20, observedAt: "2026-06-23T10:00:00Z")

        XCTAssertNotEqual(
            body10["client_sample_id"] as? String,
            body20["client_sample_id"] as? String,
            "client_sample_id must differ across different threshold N values"
        )
    }

    // MARK: - 2. Retry-queue enqueue on simulated POST failure

    func test_enqueueRetry_appendsToAppGroup() throws {
        let deviceID = UUID()
        let entry = EarnedSampleReporter.RetryEntry(
            deviceID: deviceID,
            usageDate: "2026-06-23",
            timezone: "UTC",
            thresholdMinutes: 30,
            estimatedMinutes: 30,
            observedAt: "2026-06-23T10:00:00Z"
        )

        EarnedSampleReporter.enqueueRetry(entry, suiteName: suiteName)

        let queue = EarnedSampleReporter.loadRetryQueue(suiteName: suiteName)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.thresholdMinutes, 30)
        XCTAssertEqual(queue.first?.deviceID, deviceID)
    }

    func test_enqueueRetry_multipleEntries_accumulatesOrdered() {
        let deviceID = UUID()
        for n in [10, 20, 30] {
            EarnedSampleReporter.enqueueRetry(
                EarnedSampleReporter.RetryEntry(
                    deviceID: deviceID,
                    usageDate: "2026-06-23",
                    timezone: "UTC",
                    thresholdMinutes: n,
                    estimatedMinutes: n,
                    observedAt: "2026-06-23T10:00:00Z"
                ),
                suiteName: suiteName
            )
        }
        let queue = EarnedSampleReporter.loadRetryQueue(suiteName: suiteName)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.map(\.thresholdMinutes), [10, 20, 30])
    }

    func test_clearRetryQueue_emptiesQueue() {
        let deviceID = UUID()
        EarnedSampleReporter.enqueueRetry(
            EarnedSampleReporter.RetryEntry(
                deviceID: deviceID,
                usageDate: "2026-06-23",
                timezone: "UTC",
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: "2026-06-23T10:00:00Z"
            ),
            suiteName: suiteName
        )
        EarnedSampleReporter.clearRetryQueue(suiteName: suiteName)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: suiteName).isEmpty)
    }

    // MARK: - 3. Tripwire math

    func test_effectiveCap_latestPlusRemaining_roundedUp_thenCappedAtMinPoolCap() {
        // latest=25 + remaining=12 = 37, nearest armed threshold (bucket=10) → 40
        // min(pool=60, cap=50) = 50, 40 < 50 → result = 40
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 25,
            backendRemaining: 12,
            poolMinutes: 60,
            capMinutes: 50,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 40)
    }

    func test_effectiveCap_cappedAtMinPoolCap() {
        // latest=45 + remaining=20 = 65, rounded to 70, but min(pool=60, cap=80) = 60 → capped at 60
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 45,
            backendRemaining: 20,
            poolMinutes: 60,
            capMinutes: 80,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 60)
    }

    func test_effectiveCap_alreadyOnBoundary_noRoundUp() {
        // latest=20 + remaining=10 = 30, already a multiple of 10 → stays at 30
        // min(pool=60, cap=90) = 60, 30 ≤ 60 → result = 30
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 20,
            backendRemaining: 10,
            poolMinutes: 60,
            capMinutes: 90,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 30)
    }

    func test_effectiveCap_zeroRemaining_usesLatestRounded() {
        // latest=33 + remaining=0 = 33, rounded up to 40; min(pool=60, cap=60)=60 → result=40
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 33,
            backendRemaining: 0,
            poolMinutes: 60,
            capMinutes: 60,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 40)
    }

    func test_effectiveCap_sumExceedsMinPoolCap_cappedAtCeiling() {
        // latest=70 + remaining=30 = 100, rounded=100; min(pool=80, cap=90)=80 → 80
        let result = EarnedSampleReporter.effectiveCapThreshold(
            latestEstimate: 70,
            backendRemaining: 30,
            poolMinutes: 80,
            capMinutes: 90,
            bucketMinutes: 10
        )
        XCTAssertEqual(result, 80)
    }

    // MARK: - 4. Override flag present → no .earnedTime apply

    func test_shouldApplyEarnedShield_overridePresent_returnsFalse() {
        let store = EarnedTimeStore.shared
        store.setOverride(true, forUsageDate: "2026-06-23")
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertFalse(result, "override flag set → must not apply .earnedTime shield")
    }

    func test_shouldApplyEarnedShield_noOverride_thresholdMeetsCap_returnsTrue() {
        let store = EarnedTimeStore.shared
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertTrue(result, "no override, threshold meets cap → should apply .earnedTime shield")
    }

    func test_shouldApplyEarnedShield_thresholdBelowCap_returnsFalse() {
        let store = EarnedTimeStore.shared
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 50,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertFalse(result, "threshold below cap → must not apply .earnedTime shield yet")
    }

    func test_shouldApplyEarnedShield_thresholdExceedsCap_returnsTrue() {
        let store = EarnedTimeStore.shared
        // threshold > cap is treated as >= cap — the cap was reached
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 70,
            effectiveCap: 60,
            usageDate: "2026-06-23",
            store: store
        )
        XCTAssertTrue(result, "threshold exceeds cap → should apply .earnedTime shield")
    }

    // MARK: - 5. Daily strip removes ONLY .earnedTime

    func test_stripEarnedTime_removesOnlyEarnedTimeSource() {
        // A dict with one .manual, one .limit, one .earnedTime, one mixed record.
        let manual  = Self.makeRecord(key: "savedList:list1", sources: [.manual])
        let limit   = Self.makeRecord(key: "exactApp:com.foo", sources: [.limit])
        let earned  = Self.makeRecord(key: "savedList:lockedSet", sources: [.earnedTime])
        let mixed   = Self.makeRecord(key: "savedList:list2", sources: [.manual, .earnedTime])

        let input: [String: ShieldRecord] = [
            manual.recordKey: manual,
            limit.recordKey: limit,
            earned.recordKey: earned,
            mixed.recordKey: mixed,
        ]

        let result = ShieldSourceLogic.strippingSource(.earnedTime, from: input)

        // .manual record untouched
        XCTAssertNotNil(result[manual.recordKey])
        XCTAssertEqual(result[manual.recordKey]?.sources, [.manual])

        // .limit record untouched
        XCTAssertNotNil(result[limit.recordKey])
        XCTAssertEqual(result[limit.recordKey]?.sources, [.limit])

        // .earnedTime-only record deleted
        XCTAssertNil(result[earned.recordKey])

        // mixed record: .earnedTime stripped, .manual preserved
        XCTAssertNotNil(result[mixed.recordKey])
        XCTAssertEqual(result[mixed.recordKey]?.sources, [.manual])
    }

    // MARK: - 6. Mixed-source strip — B1 carry

    func test_mixedLimitEarnedTime_stripEarnedTime_leavesLimit() {
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let input = [mixed.recordKey: mixed]

        let result = ShieldSourceLogic.strippingSource(.earnedTime, from: input)

        // Record must survive with only .limit
        let surviving = result[mixed.recordKey]
        XCTAssertNotNil(surviving, "record with {.limit, .earnedTime} must survive after .earnedTime strip")
        XCTAssertEqual(surviving?.sources, [.limit])
    }

    func test_mixedLimitEarnedTime_stripLimit_leavesEarnedTime() {
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let input = [mixed.recordKey: mixed]

        let result = ShieldSourceLogic.strippingSource(.limit, from: input)

        let surviving = result[mixed.recordKey]
        XCTAssertNotNil(surviving, "record with {.limit, .earnedTime} must survive after .limit strip")
        XCTAssertEqual(surviving?.sources, [.earnedTime])
    }

    func test_strippingLimitShields_mixedRecord_preservesNonLimitSources() {
        // The B1 carry fix: LimitShieldLogic.strippingLimitShields must use
        // source-aware removal, not a blanket filter-out of any record with .limit.
        let pure  = Self.makeRecord(key: "exactApp:com.roblox", sources: [.limit])
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let input = [pure.recordKey: pure, mixed.recordKey: mixed]

        let result = LimitShieldLogic.strippingLimitShields(from: input)

        // Pure .limit record must be fully deleted
        XCTAssertNil(result[pure.recordKey])

        // Mixed record: .limit stripped, .earnedTime preserved
        let surviving = result[mixed.recordKey]
        XCTAssertNotNil(surviving, "mixed {.limit,.earnedTime} record must survive after limit strip")
        XCTAssertEqual(surviving?.sources, [.earnedTime])
    }

    func test_reconcileLimitShieldsFromDisk_mixedRecord_preservesNonLimitSources() {
        // Simulates the B1 carry scenario: a record on disk transitions from
        // {.limit, .earnedTime} → {.earnedTime} (extension stripped .limit at reset).
        // reconcileLimitShieldsFromDisk must NOT delete the whole in-memory record;
        // it should update it to match disk (remove .limit, keep .earnedTime).
        // We test via ShieldSourceLogic.strippingSource directly since the pure
        // helper is what the B1-carry-fixed reconcile delegates to.
        let mixed = Self.makeRecord(key: "savedList:lockedSet", sources: [.limit, .earnedTime])
        let inMemory: [String: ShieldRecord] = [mixed.recordKey: mixed]

        // Disk equivalent: the extension stripped .limit → disk record has only .earnedTime
        // Reconcile should bring in-memory in line: remove .limit, keep .earnedTime.
        let diskAfterLimitReset = ShieldSourceLogic.removing(.limit, from: mixed)
        XCTAssertNotNil(diskAfterLimitReset, "removing .limit from {.limit,.earnedTime} must not return nil")
        XCTAssertEqual(diskAfterLimitReset?.sources, [.earnedTime])

        // Also verify that a record with only .limit resolves to nil (full delete)
        let pureLimit = Self.makeRecord(key: "exactApp:com.foo", sources: [.limit])
        XCTAssertNil(ShieldSourceLogic.removing(.limit, from: pureLimit),
                     "removing .limit from {.limit} must return nil → caller deletes record")

        // Verify dict-level helper: strippingSource on a dict with only .limit records
        // should leave any record missing that source intact
        let manualOnly = Self.makeRecord(key: "savedList:other", sources: [.manual])
        let dictInput = [inMemory, [pureLimit.recordKey: pureLimit, manualOnly.recordKey: manualOnly]]
            .reduce([String:ShieldRecord]()) { acc, d in acc.merging(d) { _, new in new } }

        let stripped = ShieldSourceLogic.strippingSource(.limit, from: dictInput)
        XCTAssertNil(stripped[pureLimit.recordKey])
        XCTAssertNotNil(stripped[manualOnly.recordKey])
        XCTAssertEqual(stripped[mixed.recordKey]?.sources, [.earnedTime])
    }

    // MARK: - Helpers

    private static func makeRecord(key: String, sources: Set<ShieldSource>) -> ShieldRecord {
        // Derive tier from recordKey prefix; default to savedList.
        let tier: ShieldTier
        let targetKey: String
        if key.hasPrefix("savedList:") {
            tier = .savedList
            targetKey = String(key.dropFirst("savedList:".count))
        } else if key.hasPrefix("exactApp:") {
            tier = .exactApp
            targetKey = String(key.dropFirst("exactApp:".count))
        } else {
            tier = .savedList
            targetKey = key
        }
        return ShieldRecord(
            recordKey: key,
            tier: tier,
            targetKey: targetKey,
            displayName: "Test \(key)",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID(),
            sources: sources
        )
    }
}
