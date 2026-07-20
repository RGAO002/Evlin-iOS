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
            sources: [.manual]
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
        guard record.sources.contains(.limit) else { return false }
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
        XCTAssertEqual(record.sources, [.limit])
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
        XCTAssertEqual(updated[manual.recordKey]?.sources, [.manual])
        XCTAssertEqual(updated[LimitShieldLogic.recordKey(for: rule)]?.sources, [.limit])
    }

    func test_applyingValidatedLimitCarriesRuleTokenArmAndOwnerProvenance() {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let armID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let ownerID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let rule = makeRule(id: ruleID)
        let callback = AppLimitValidatedCallback(
            rule: rule,
            provenance: AppLimitArmProvenance(
                ruleID: ruleID,
                ruleRevision: 41,
                childDeviceID: ownerID,
                usageDate: "2026-07-19",
                timezone: "America/New_York",
                scheduleWindow: rule.window,
                tokenDigest: "token-digest",
                budgetMinutes: rule.budgetMinutes,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                baseAcceptedMinutes: 0,
                lastRawThresholdMinutes: 0,
                ignoredWhilePausedMinutes: 0,
                activityName: AppLimitPlanner.v2ActivityName(armID: armID),
                armID: armID
            ),
            effectKind: .enforcement,
            rawThresholdMinutes: rule.budgetMinutes,
            adjustedEstimateMinutes: rule.budgetMinutes
        )

        let record = try! XCTUnwrap(
            LimitShieldLogic.applyingLimit(
                to: [:],
                callback: callback,
                now: Date(timeIntervalSince1970: 1_721_174_400)
            )[LimitShieldLogic.recordKey(for: rule)]
        )

        XCTAssertEqual(record.sources, [.limit])
        XCTAssertEqual(record.lastCommandID, ruleID)
        XCTAssertEqual(record.targetChildID, ownerID)
        XCTAssertTrue(record.originalRequest.contains("ordering_token=41"))
        XCTAssertTrue(record.originalRequest.contains("arm_id=\(armID.uuidString.lowercased())"))
        XCTAssertTrue(record.originalRequest.contains("rule_id=\(ruleID.uuidString.lowercased())"))
    }

    func test_applyingValidatedLimitUnionsEveryExistingSameRecordSource() {
        let rule = makeRule()
        let callback = makeValidatedCallback(rule: rule)
        var existing = manualRecord(
            recordKey: LimitShieldLogic.recordKey(for: rule),
            targetKey: LimitShieldLogic.targetKey(for: rule)
        )
        existing.sources = [.manual, .earnedTime, .taskPause]

        let updated = LimitShieldLogic.applyingLimit(
            to: [existing.recordKey: existing],
            callback: callback,
            now: Date(timeIntervalSince1970: 1_721_174_400)
        )

        XCTAssertEqual(updated[existing.recordKey]?.sources, [
            .manual, .earnedTime, .taskPause, .limit,
        ])
    }

    func test_strippingValidatedLimitPreservesEveryPriorSameRecordSource() {
        let rule = makeRule()
        let callback = makeValidatedCallback(rule: rule)
        var existing = manualRecord(
            recordKey: LimitShieldLogic.recordKey(for: rule),
            targetKey: LimitShieldLogic.targetKey(for: rule)
        )
        existing.sources = [.manual, .earnedTime, .taskPause]
        let limited = LimitShieldLogic.applyingLimit(
            to: [existing.recordKey: existing],
            callback: callback,
            now: Date(timeIntervalSince1970: 1_721_174_400)
        )

        let stripped = LimitShieldLogic.strippingLimitShields(from: limited)

        XCTAssertEqual(stripped[existing.recordKey]?.sources, existing.sources)
    }

    func test_validatedLimitTransformRequiresExplicitOperationTime() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS/Services/AppLimitEffectJournal.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("""
            callback: AppLimitValidatedCallback,
            now: Date = Date()
            """))
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
        XCTAssertEqual(stripped[manual.recordKey]?.sources, [.manual])
        XCTAssertNil(stripped[LimitShieldLogic.recordKey(for: rule)], "Limit shield must be gone")
        XCTAssertFalse(stripped.values.contains { $0.sources.contains(.limit) })
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
        XCTAssertTrue(record.sources.contains(.limit))
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

    // MARK: - "Limit reached" notification copy (pure helper)

    /// Happy path: the extension posts this BEFORE shielding when a budget is
    /// hit. Title names the app; body carries the "N-min" limit and the app name.
    func test_limitReachedNotification_interpolatesNameAndMinutes() {
        let copy = LimitShieldLogic.limitReachedNotification(appName: "Instagram", minutes: 15)
        XCTAssertEqual(copy.title, "Time's up on Instagram")
        XCTAssertTrue(copy.body.contains("15-min"), "body should carry the budget minutes: \(copy.body)")
        XCTAssertTrue(copy.body.contains("Instagram"), "body should name the app: \(copy.body)")
        XCTAssertTrue(copy.body.contains("unlocks tomorrow"))
    }

    /// nil app name → "this app" fallback in both title and body; never a blank.
    func test_limitReachedNotification_nilName_fallsBackToThisApp() {
        let copy = LimitShieldLogic.limitReachedNotification(appName: nil, minutes: 30)
        XCTAssertEqual(copy.title, "Time's up on this app")
        XCTAssertTrue(copy.body.contains("this app"))
        XCTAssertTrue(copy.body.contains("30-min"))
    }

    /// Empty / whitespace-only app name → same "this app" fallback (no "Time's
    /// up on   " with a dangling blank).
    func test_limitReachedNotification_emptyName_fallsBackToThisApp() {
        let copy = LimitShieldLogic.limitReachedNotification(appName: "   ", minutes: 45)
        XCTAssertEqual(copy.title, "Time's up on this app")
        XCTAssertTrue(copy.body.contains("this app"))
    }

    /// nil/non-positive minutes → omit the "N-min" clause; read "today's limit"
    /// so we never render "0-min".
    func test_limitReachedNotification_nilMinutes_omitsMinuteClause() {
        let copy = LimitShieldLogic.limitReachedNotification(appName: "Roblox", minutes: nil)
        XCTAssertEqual(copy.title, "Time's up on Roblox")
        XCTAssertFalse(copy.body.contains("-min"), "no minute clause when minutes unavailable: \(copy.body)")
        XCTAssertTrue(copy.body.contains("today's limit"))

        let zero = LimitShieldLogic.limitReachedNotification(appName: "Roblox", minutes: 0)
        XCTAssertFalse(zero.body.contains("0-min"))
        XCTAssertTrue(zero.body.contains("today's limit"))
    }

    // MARK: - Task A: 1-minute picker option

    /// DEBUG builds lead the limit picker with `1` so a parent can set a
    /// 1-minute budget for testing; release builds start at 15m. `formatLimit(1)`
    /// always renders a clean "1m" (not "0h 1m" / "1").
    func test_limitOptions_oneMinuteIsDebugOnly_andFormatsCleanly() {
        #if DEBUG
        XCTAssertEqual(DeviceAppsMockData.limitOptions.first, 1)
        #else
        XCTAssertFalse(DeviceAppsMockData.limitOptions.contains(1))
        XCTAssertEqual(DeviceAppsMockData.limitOptions.first, 15)
        #endif
        XCTAssertEqual(DeviceAppsMockData.formatLimit(1), "1m")
    }

    private func makeValidatedCallback(rule: AppLimitRule) -> AppLimitValidatedCallback {
        let armID = UUID(uuidString: "30000000-0000-0000-0000-000000000005")!
        return AppLimitValidatedCallback(
            rule: rule,
            provenance: AppLimitArmProvenance(
                ruleID: rule.id,
                ruleRevision: 45,
                childDeviceID: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!,
                usageDate: "2026-07-19",
                timezone: "America/New_York",
                scheduleWindow: rule.window,
                tokenDigest: "token-digest",
                budgetMinutes: rule.budgetMinutes,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                baseAcceptedMinutes: 0,
                lastRawThresholdMinutes: 0,
                ignoredWhilePausedMinutes: 0,
                activityName: AppLimitPlanner.v2ActivityName(armID: armID),
                armID: armID
            ),
            effectKind: .enforcement,
            rawThresholdMinutes: rule.budgetMinutes,
            adjustedEstimateMinutes: rule.budgetMinutes
        )
    }
}
