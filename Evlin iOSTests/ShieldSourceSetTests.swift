import XCTest
@testable import Evlin_iOS

/// Task B1 — ShieldRecord.sources set + .earnedTime case + ShieldSourceLogic.
///
/// All tests here are PURE LOGIC (Codable + set operations + mergeShield
/// branching via ActiveLockStore). No device features needed.
final class ShieldSourceSetTests: XCTestCase {

    func test_unknownFutureSource_survivesSetMergeAndRoundTrip() throws {
        let source = try JSONDecoder().decode(ShieldSource.self, from: Data("\"schedule\"".utf8))
        let merged = ShieldSourceLogic.unioning(makeRecord(sources: [.limit]), intoSources: [source])
        let data = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(ShieldRecord.self, from: data)

        XCTAssertEqual(decoded.sources.map(\.rawValue).sorted(), ["limit", "schedule"])
    }

    // MARK: - Helpers

    private func evlinDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func evlinEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Minimal ShieldRecord fixture. `expiresAt:nil` = permanent.
    private func makeRecord(
        recordKey: String = "exactApp:com.example.app",
        tier: ShieldTier = .exactApp,
        targetKey: String = "com.example.app",
        expiresAt: Date? = nil,
        sources: Set<ShieldSource> = [.manual]
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: "Example",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: expiresAt,
            originalRequest: "test",
            targetChildID: UUID(),
            sources: sources
        )
    }

    private let suiteName = "group.com.evlin.ios"
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey  = "evlin.blockRecords"

    override func setUp() async throws {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: shieldsKey)
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: blocksKey)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: shieldsKey)
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: blocksKey)
    }

    // MARK: - Legacy decode: no source/sources key → {.manual}

    func test_legacy_noSourceKey_decodesAsManualSet() throws {
        let json = """
        {
          "recordKey": "exactApp:com.burbn.instagram",
          "tier": "exactApp",
          "targetKey": "com.burbn.instagram",
          "displayName": "Instagram",
          "lastCommandID": "11111111-1111-1111-1111-111111111111",
          "appTokens": [],
          "categoryTokens": [],
          "webDomainTokens": [],
          "appliesToAll": false,
          "issuedAt": "2026-01-02T03:04:05Z",
          "expiresAt": "2026-01-02T04:04:05Z",
          "originalRequest": "lock instagram",
          "targetChildID": "22222222-2222-2222-2222-222222222222"
        }
        """
        let record = try evlinDecoder().decode(ShieldRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.sources, [.manual],
                       "Legacy record with no source/sources key must decode as {.manual}")
    }

    // MARK: - Legacy decode: scalar source:"limit" → {.limit}

    func test_legacy_scalarSourceLimit_decodesAsLimitSet() throws {
        let json = """
        {
          "recordKey": "exactApp:com.burbn.instagram",
          "tier": "exactApp",
          "targetKey": "com.burbn.instagram",
          "displayName": "Instagram",
          "lastCommandID": "11111111-1111-1111-1111-111111111111",
          "appTokens": [],
          "categoryTokens": [],
          "webDomainTokens": [],
          "appliesToAll": false,
          "issuedAt": "2026-01-02T03:04:05Z",
          "originalRequest": "lock instagram",
          "targetChildID": "22222222-2222-2222-2222-222222222222",
          "source": "limit"
        }
        """
        let record = try evlinDecoder().decode(ShieldRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.sources, [.limit],
                       "Legacy scalar source:\"limit\" must decode as {.limit}, NOT {.manual}")
    }

    // MARK: - Legacy decode: scalar source:"earnedTime" → {.earnedTime}

    func test_legacy_scalarSourceEarnedTime_decodesAsEarnedTimeSet() throws {
        let json = """
        {
          "recordKey": "exactApp:com.burbn.instagram",
          "tier": "exactApp",
          "targetKey": "com.burbn.instagram",
          "displayName": "Instagram",
          "lastCommandID": "11111111-1111-1111-1111-111111111111",
          "appTokens": [],
          "categoryTokens": [],
          "webDomainTokens": [],
          "appliesToAll": false,
          "issuedAt": "2026-01-02T03:04:05Z",
          "originalRequest": "lock instagram",
          "targetChildID": "22222222-2222-2222-2222-222222222222",
          "source": "earnedTime"
        }
        """
        let record = try evlinDecoder().decode(ShieldRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.sources, [.earnedTime],
                       "Legacy scalar source:\"earnedTime\" must decode as {.earnedTime}")
    }

    // MARK: - New format: sources array round-trips correctly

    func test_sourcesSet_roundTrips() throws {
        let original = makeRecord(sources: [.earnedTime, .manual])
        let data = try evlinEncoder().encode(original)
        let decoded = try evlinDecoder().decode(ShieldRecord.self, from: data)
        XCTAssertEqual(decoded.sources, [.earnedTime, .manual])
    }

    // MARK: - Unknown future source survives in set context

    func test_unknownSourceInSet_roundTripsLosslessly() throws {
        let json = """
        {
          "recordKey": "exactApp:com.example.app",
          "tier": "exactApp",
          "targetKey": "com.example.app",
          "displayName": "Example",
          "lastCommandID": "11111111-1111-1111-1111-111111111111",
          "appTokens": [],
          "categoryTokens": [],
          "webDomainTokens": [],
          "appliesToAll": false,
          "issuedAt": "2026-01-02T03:04:05Z",
          "originalRequest": "lock",
          "targetChildID": "22222222-2222-2222-2222-222222222222",
          "source": "schedule"
        }
        """
        let record = try evlinDecoder().decode(ShieldRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.sources.map(\.rawValue), ["schedule"])
    }

    // MARK: - addShield: earnedTime then manual on same recordKey → union {earnedTime, manual}
    // This hits the existingPermanent && newPermanent branch — which today returns
    // .noOpAlreadyPermanent WITHOUT merging. The union MUST still happen.

    func test_addShield_earnedTimeThenManual_sameKey_unionsSourcesInPermanentBranch() async {
        let store = ActiveLockStore()
        let key = "exactApp:com.example.app"

        // 1. Add an earnedTime permanent shield.
        let earnedTime = makeRecord(recordKey: key, expiresAt: nil, sources: [.earnedTime])
        _ = await store.addShield(earnedTime)

        // 2. Add a manual permanent shield at the same recordKey.
        let manual = makeRecord(recordKey: key, expiresAt: nil, sources: [.manual])
        _ = await store.addShield(manual)

        // Both are permanent → hits the existingPermanent && newPermanent branch.
        // The sources must be UNIONED (not clobbered).
        let shields = await store.allCurrent().shields
        let record = shields.first(where: { $0.recordKey == key })
        XCTAssertNotNil(record, "Shield record must still exist after second addShield")
        XCTAssertEqual(
            record?.sources, [.earnedTime, .manual],
            "Two permanent shields at same key must union sources; got: \(String(describing: record?.sources))"
        )
    }

    // MARK: - removeSource: removes one source, keeps record when others remain

    func test_removeSource_earnedTimeFromMultiSet_keepsRecordWithRemainingSource() async {
        let store = ActiveLockStore()
        let key = "exactApp:com.example.app"

        let r = makeRecord(recordKey: key, sources: [.earnedTime, .manual])
        _ = await store.addShield(r)

        await store.removeSource(.earnedTime, fromRecordKey: key)

        let shields = await store.allCurrent().shields
        let record = shields.first(where: { $0.recordKey == key })
        XCTAssertNotNil(record, "Record must survive when .manual source remains")
        XCTAssertEqual(record?.sources, [.manual])
    }

    // MARK: - removeSource: deletes record when set empties

    func test_removeSource_lastSource_deletesRecord() async {
        let store = ActiveLockStore()
        let key = "exactApp:com.example.app"

        let r = makeRecord(recordKey: key, sources: [.manual])
        _ = await store.addShield(r)

        await store.removeSource(.manual, fromRecordKey: key)

        let shields = await store.allCurrent().shields
        XCTAssertFalse(
            shields.contains(where: { $0.recordKey == key }),
            "Record must be deleted when sources set empties"
        )
    }

    // MARK: - removeLimitShields uses sources.contains(.limit), not equality

    func test_removeLimitShields_matchesRecordWithLimitInSources_leavesManualSource() async {
        let store = ActiveLockStore()
        let key = "exactApp:com.example.app"

        // A record that has BOTH .limit and .manual in its sources set.
        let r = makeRecord(recordKey: key, targetKey: "com.example.app", sources: [.limit, .manual])
        _ = await store.addShield(r)

        // removeLimitShields should REMOVE the record that has .limit in sources.
        // (After this the .manual source is gone too — the whole record is removed
        //  because removeLimitShields removes the RECORD, not just the .limit source.
        //  The .contains(.limit) predicate fix is what makes this match at all.)
        let removed = await store.removeLimitShields(appTokens: [], bundleID: "com.example.app")
        XCTAssertEqual(removed.count, 1,
                       "removeLimitShields must match a record whose sources.contains(.limit)")
        XCTAssertEqual(removed.first?.recordKey, key)

        let after = await store.allCurrent().shields
        XCTAssertFalse(after.contains(where: { $0.recordKey == key }))
    }

    func test_removeLimitShields_doesNotMatchPureManualRecord() async {
        let store = ActiveLockStore()
        let key = "exactApp:com.example.app"

        let r = makeRecord(recordKey: key, targetKey: "com.example.app", sources: [.manual])
        _ = await store.addShield(r)

        let removed = await store.removeLimitShields(appTokens: [], bundleID: "com.example.app")
        XCTAssertEqual(removed.count, 0,
                       "removeLimitShields must NOT match a pure .manual record")

        let after = await store.allCurrent().shields
        XCTAssertTrue(after.contains(where: { $0.recordKey == key }),
                      "Manual-only record must survive removeLimitShields")
    }

    // MARK: - ShieldSourceLogic pure function tests

    func test_shieldSourceLogic_unioning_addsNewSources() {
        let record = makeRecord(sources: [.manual])
        let updated = ShieldSourceLogic.unioning(record, intoSources: [.earnedTime])
        XCTAssertEqual(updated.sources, [.manual, .earnedTime])
    }

    func test_shieldSourceLogic_unioning_isIdempotent() {
        let record = makeRecord(sources: [.manual, .earnedTime])
        let updated = ShieldSourceLogic.unioning(record, intoSources: [.earnedTime])
        XCTAssertEqual(updated.sources, [.manual, .earnedTime])
    }

    func test_shieldSourceLogic_removing_returnsRecordWithSourceRemoved() {
        let record = makeRecord(sources: [.manual, .earnedTime])
        let result = ShieldSourceLogic.removing(.earnedTime, from: record)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sources, [.manual])
    }

    func test_shieldSourceLogic_removing_returnsNilWhenSetEmpties() {
        let record = makeRecord(sources: [.manual])
        let result = ShieldSourceLogic.removing(.manual, from: record)
        XCTAssertNil(result, "removing the last source must return nil")
    }

    func test_shieldSourceLogic_removingSourceFromRecordKey_removesFromDict() {
        let record = makeRecord(sources: [.manual, .limit])
        let dict: [String: ShieldRecord] = [record.recordKey: record]
        let result = ShieldSourceLogic.removingSource(.limit, fromRecordKey: record.recordKey, in: dict)
        XCTAssertEqual(result[record.recordKey]?.sources, [.manual])
    }

    func test_shieldSourceLogic_removingSourceFromRecordKey_deletesKeyWhenEmpty() {
        let record = makeRecord(sources: [.manual])
        let dict: [String: ShieldRecord] = [record.recordKey: record]
        let result = ShieldSourceLogic.removingSource(.manual, fromRecordKey: record.recordKey, in: dict)
        XCTAssertNil(result[record.recordKey], "Key must be deleted when sources become empty")
    }

    func test_shieldSourceLogic_strippingSource_removesMatchingRecords() {
        let limitRecord = makeRecord(
            recordKey: "exactApp:com.example.app",
            sources: [.limit]
        )
        let manualRecord = makeRecord(
            recordKey: "exactApp:com.other.app",
            targetKey: "com.other.app",
            sources: [.manual]
        )
        let dict: [String: ShieldRecord] = [
            limitRecord.recordKey: limitRecord,
            manualRecord.recordKey: manualRecord
        ]
        // strippingSource removes records that ONLY have .limit (set becomes empty → delete).
        let result = ShieldSourceLogic.strippingSource(.limit, from: dict)
        XCTAssertNil(result[limitRecord.recordKey], "Pure .limit record must be stripped")
        XCTAssertNotNil(result[manualRecord.recordKey], "Manual record must survive")
    }

    func test_shieldSourceLogic_strippingSource_keepsRecordsWithOtherSources() {
        let multiRecord = makeRecord(
            recordKey: "exactApp:com.example.app",
            sources: [.limit, .manual]
        )
        let dict: [String: ShieldRecord] = [multiRecord.recordKey: multiRecord]
        let result = ShieldSourceLogic.strippingSource(.limit, from: dict)
        // The record survives but .limit is removed from its sources.
        XCTAssertNotNil(result[multiRecord.recordKey])
        XCTAssertEqual(result[multiRecord.recordKey]?.sources, [.manual])
    }
}
