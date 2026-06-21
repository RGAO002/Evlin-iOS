import XCTest
import FamilyControls
import ManagedSettings
@testable import Evlin_iOS

/// P7. The DeviceActivity extension's `eventDidReachThreshold` /
/// `intervalDidStart` callbacks take framework types that can't be invoked in a
/// unit test, so the enforcement DECISION logic lives in `LimitShieldLogic` as
/// pure dict→dict functions. These tests pin that logic plus the cross-piece
/// invariants that make the whole feature hang together:
///
///  - A threshold-reached limit writes a `source == .limit` ShieldRecord shaped so
///    `ActiveLockStore.removeLimitShields` (P6's clear path) WILL match it.
///  - The daily reset strips ONLY `source == .limit`, never `.manual` (parent).
///  - The window-activity prefix the extension switches on matches the planner's.
///
/// `ApplicationToken`s are opaque, picker-minted values that cannot be
/// constructed in a unit test, so token sets are empty here and the bundleID /
/// `targetKey` matching path is what's exercised — which is exactly the
/// cross-process path that survives the App Group JSON round-trip.
final class LimitShieldLogicTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRule(
        id: UUID = UUID(),
        bundleID: String = "com.burbn.instagram",
        displayName: String = "Instagram",
        budgetMinutes: Int = 45
    ) -> AppLimitRule {
        AppLimitRule(
            id: id,
            appTokens: [],
            bundleID: bundleID,
            displayName: displayName,
            budgetMinutes: budgetMinutes,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
    }

    private func manualRecord(
        recordKey: String = "exactApp:com.toyopagroup.picaboo",
        targetKey: String = "com.toyopagroup.picaboo"
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: .exactApp,
            targetKey: targetKey,
            displayName: "Snapchat",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            originalRequest: "lock snapchat",
            targetChildID: UUID(),
            source: .manual
        )
    }

    /// The exact match predicate `ActiveLockStore.removeLimitShields` uses (P6).
    /// Mirrored here so a round-trip test can assert agreement WITHOUT mutating
    /// the `ActiveLockStore` singleton. If P6's predicate changes this test should
    /// be updated in lockstep — that's the point: it's the cross-piece contract.
    private func removeLimitShieldsMatches(
        _ record: ShieldRecord,
        appTokens: Set<ApplicationToken>,
        bundleID: String?
    ) -> Bool {
        guard record.source == .limit else { return false }
        if !appTokens.isEmpty, !record.appTokens.isDisjoint(with: appTokens) { return true }
        let bidKey = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let bidKey, !bidKey.isEmpty, record.targetKey == bidKey { return true }
        return false
    }

    // MARK: - applyingLimit

    func test_applyingLimit_addsLimitSourcedRecord_matchableByTokenAndBundle() {
        let rule = makeRule(bundleID: "com.burbn.instagram", displayName: "Instagram")
        let updated = LimitShieldLogic.applyingLimit(to: [:], rule: rule)

        let key = LimitShieldLogic.recordKey(for: rule)
        XCTAssertEqual(key, "exactApp:com.burbn.instagram")
        let record = try! XCTUnwrap(updated[key])

        // Shape the recompute + P6 clear both depend on.
        XCTAssertEqual(record.source, .limit)
        XCTAssertEqual(record.tier, .exactApp)
        XCTAssertEqual(record.targetKey, "com.burbn.instagram")
        XCTAssertEqual(record.recordKey, key)
        XCTAssertEqual(record.appTokens, rule.appTokens)
        XCTAssertNil(record.expiresAt, "Limit shields are day-permanent; the reset clears them, not an expiry")
        XCTAssertFalse(record.appliesToAll)
    }

    /// Cross-piece contract with P6: the record the extension writes here MUST be
    /// matchable by `ActiveLockStore.removeLimitShields(appTokens:bundleID:)` so
    /// `clear_limit` actually un-shields the app it auto-shielded.
    func test_applyingLimit_record_isMatchableBy_removeLimitShields() {
        let rule = makeRule(bundleID: "com.burbn.instagram")
        let record = try! XCTUnwrap(
            LimitShieldLogic.applyingLimit(to: [:], rule: rule)[LimitShieldLogic.recordKey(for: rule)]
        )

        // Matches on the lowercased bundleID (token sets are empty in tests).
        XCTAssertTrue(
            removeLimitShieldsMatches(record, appTokens: [], bundleID: "com.burbn.instagram"),
            "Limit shield must be matched by P6 removeLimitShields on bundleID"
        )
        // Case-insensitive: a differently-cased bundleID still matches.
        XCTAssertTrue(
            removeLimitShieldsMatches(record, appTokens: [], bundleID: "COM.Burbn.Instagram")
        )
        // A different app's bundleID must NOT match.
        XCTAssertFalse(
            removeLimitShieldsMatches(record, appTokens: [], bundleID: "com.toyopagroup.picaboo")
        )
    }

    /// Re-firing the threshold for the same rule overwrites its own record (same
    /// recordKey) rather than accreting duplicates.
    func test_applyingLimit_isIdempotentForSameRule() {
        let rule = makeRule()
        let once = LimitShieldLogic.applyingLimit(to: [:], rule: rule)
        let twice = LimitShieldLogic.applyingLimit(to: once, rule: rule)
        XCTAssertEqual(twice.count, 1)
        XCTAssertEqual(Set(twice.keys), Set(once.keys))
    }

    /// Applying a limit must not disturb a coexisting manual shield on a different
    /// app — both records survive.
    func test_applyingLimit_keepsExistingManualShield() {
        let manual = manualRecord()
        let rule = makeRule(bundleID: "com.burbn.instagram")
        let updated = LimitShieldLogic.applyingLimit(
            to: [manual.recordKey: manual], rule: rule
        )
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated[manual.recordKey]?.source, .manual)
        XCTAssertEqual(updated[LimitShieldLogic.recordKey(for: rule)]?.source, .limit)
    }

    // MARK: - strippingLimitShields (daily reset)

    func test_strippingLimitShields_removesOnlyLimit_keepsManual() {
        let manual = manualRecord(
            recordKey: "exactApp:com.toyopagroup.picaboo",
            targetKey: "com.toyopagroup.picaboo"
        )
        let rule = makeRule(bundleID: "com.burbn.instagram")
        // Build a dict containing one manual + one limit record.
        var dict: [String: ShieldRecord] = [manual.recordKey: manual]
        dict = LimitShieldLogic.applyingLimit(to: dict, rule: rule)
        XCTAssertEqual(dict.count, 2)

        let stripped = LimitShieldLogic.strippingLimitShields(from: dict)

        XCTAssertEqual(stripped.count, 1, "Only the limit record should be removed")
        XCTAssertNotNil(stripped[manual.recordKey], "Manual (parent) shield must survive")
        XCTAssertEqual(stripped[manual.recordKey]?.source, .manual)
        XCTAssertNil(stripped[LimitShieldLogic.recordKey(for: rule)], "Limit shield must be gone")
        XCTAssertFalse(stripped.values.contains { $0.source == .limit })
    }

    func test_strippingLimitShields_removesEveryLimitRecord() {
        let r1 = makeRule(bundleID: "com.burbn.instagram")
        let r2 = makeRule(bundleID: "com.toyopagroup.picaboo")
        var dict: [String: ShieldRecord] = [:]
        dict = LimitShieldLogic.applyingLimit(to: dict, rule: r1)
        dict = LimitShieldLogic.applyingLimit(to: dict, rule: r2)
        XCTAssertEqual(dict.count, 2)

        let stripped = LimitShieldLogic.strippingLimitShields(from: dict)
        XCTAssertTrue(stripped.isEmpty, "Every source==.limit record must be stripped")
    }

    func test_strippingLimitShields_onManualOnlyDict_isNoOp() {
        let manual = manualRecord()
        let dict = [manual.recordKey: manual]
        let stripped = LimitShieldLogic.strippingLimitShields(from: dict)
        XCTAssertEqual(stripped, dict)
    }

    // MARK: - Cross-process round-trip (App Group JSON)

    /// The record is persisted as JSON in the App Group with the `.iso8601` date
    /// strategy and read back cross-process. After a round-trip it must still be
    /// matchable by P6's predicate (this is the live failure mode if a field
    /// dropped through the manual Codable or the date strategy drifted).
    func test_applyingLimit_record_survivesJSONRoundTripAndStillMatches() throws {
        let rule = makeRule(bundleID: "com.burbn.instagram")
        let dict = LimitShieldLogic.applyingLimit(to: [:], rule: rule)

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(dict)
        let decoded = try dec.decode([String: ShieldRecord].self, from: data)

        let record = try XCTUnwrap(decoded[LimitShieldLogic.recordKey(for: rule)])
        XCTAssertEqual(record.source, .limit)
        XCTAssertTrue(
            removeLimitShieldsMatches(record, appTokens: [], bundleID: "com.burbn.instagram"),
            "Round-tripped limit shield must still be matchable by removeLimitShields"
        )
    }

    // MARK: - Window prefix contract

    /// The extension hardcodes `"evlin.limit.window."` (the planner type isn't in
    /// the extension target) — assert it equals the planner's source-of-truth so
    /// the daily-reset branch fires on exactly the activities the planner arms.
    func test_windowPrefix_matchesPlannerConstant() {
        XCTAssertEqual(AppLimitPlanner.windowActivityPrefix, "evlin.limit.window.")
    }

    /// The event-name suffix the extension parses is the rule's UUID string, and
    /// the recordKey it derives matches the `.exactApp` scheme `removeLimitShields`
    /// expects — guards the name<->id<->key chain end to end.
    func test_eventName_roundTripsToRule_andRecordKeyScheme() {
        let id = UUID()
        let eventName = AppLimitPlanner.eventName(for: id)
        XCTAssertEqual(eventName, "evlin.limit.\(id.uuidString)")

        let parsed = UUID(uuidString: String(eventName.dropFirst("evlin.limit.".count)))
        XCTAssertEqual(parsed, id)

        let rule = makeRule(id: id, bundleID: "com.Example.App")
        // targetKey/recordKey are lowercased — matches removeLimitShields' lowercasing.
        XCTAssertEqual(LimitShieldLogic.targetKey(for: rule), "com.example.app")
        XCTAssertEqual(LimitShieldLogic.recordKey(for: rule), "exactApp:com.example.app")
    }
}
