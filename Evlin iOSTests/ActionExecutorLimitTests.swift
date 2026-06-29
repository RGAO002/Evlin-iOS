import CryptoKit
import DeviceActivity
import FamilyControls
import ManagedSettings
import XCTest
@testable import Evlin_iOS

/// P6 — wires the planner + rule store into `ActionExecutor` so
/// `set_limit`/`clear_limit` commands persist a rule, arm DeviceActivity, and ack
/// accurately. Replaces the P3 placeholder cases.
///
/// `ApplicationToken`s are opaque, picker-minted values that cannot be
/// constructed in a unit test (see `AppLimitRuleStoreTests`). So the happy-path
/// assertions here verify the rule lands in the store + the planner armed via the
/// scheduler spy, and the token-decode-failure path is exercised directly with an
/// undecodable `catalogTokenDataBase64`. Where `executeSetLimit` strictly needs a
/// real token to PROCEED, we structure the seam so it does not (the rule is built
/// from the command's bundle/window metadata and an empty token set is valid for
/// a rule, mirroring `AppLimitRuleStore`/`AppLimitPlanner` tests).
@MainActor
final class ActionExecutorLimitTests: XCTestCase {

    override func setUp() async throws {
        await clearActiveLockState()
        AppLimitRuleStore.shared.removeAll()
    }

    override func tearDown() async throws {
        await clearActiveLockState()
        AppLimitRuleStore.shared.removeAll()
    }

    // MARK: - Spy (mirrors ActionExecutorTests / AppLimitPlannerTests)

    private final class LimitSchedulerSpy: DeviceActivityScheduling {
        private(set) var armed: [(name: DeviceActivityName, events: [DeviceActivityEvent.Name: DeviceActivityEvent])] = []
        private(set) var startedNoEvents: [DeviceActivityName] = []
        private(set) var stopped: [[DeviceActivityName]?] = []
        private(set) var activeActivities: Set<DeviceActivityName> = []

        func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
            startedNoEvents.append(name)
            activeActivities.insert(name)
        }

        func startMonitoring(
            _ activity: DeviceActivityName,
            during schedule: DeviceActivitySchedule,
            events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        ) throws {
            armed.append((activity, events))
            activeActivities.insert(activity)
        }

        func stopMonitoring(_ activities: [DeviceActivityName]) {
            stopped.append(activities)
            for a in activities { activeActivities.remove(a) }
        }

        func stopMonitoring() {
            stopped.append(nil)
            activeActivities.removeAll()
        }

        func monitoredActivities() -> [DeviceActivityName] { Array(activeActivities) }
    }

    // MARK: - Fixtures

    private func makeExecutor(spy: LimitSchedulerSpy) -> ActionExecutor {
        ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved }
        )
    }

    private func makeLimitCommand(
        bundleID: String = "com.burbn.instagram",
        display: String = "Instagram",
        ruleID: UUID = UUID(),
        budget: Int = 45,
        catalogTokenBase64: String? = nil
    ) -> LockCommand {
        var target = CommandTarget(
            bundleID: bundleID,
            originalRequest: "limit Instagram to 45 min",
            targetDisplay: display,
            targetChildID: UUID()
        )
        target.catalogTokenDataBase64 = catalogTokenBase64
        return LockCommand(
            id: UUID(),
            action: .setLimit,
            tier: .exactApp,
            target: target,
            durationMinutes: nil,
            issuedAt: Date(),
            limit: LimitRule(
                ruleId: ruleID,
                dailyBudgetMinutes: budget,
                resetPolicy: "daily",
                startMinute: 0,
                endMinute: 1439,
                timezone: "America/Los_Angeles",
                effectiveFrom: Date(timeIntervalSince1970: 0),
                expiresAt: nil,
                updatedAt: Date()
            )
        )
    }

    private func makeClearCommand(
        bundleID: String = "com.burbn.instagram",
        display: String = "Instagram",
        ruleID: UUID
    ) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .clearLimit,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "remove Instagram limit",
                targetDisplay: display,
                targetChildID: UUID()
            ),
            durationMinutes: nil,
            issuedAt: Date(),
            clear: ClearLimit(ruleId: ruleID, reason: nil, updatedAt: Date())
        )
    }

    private func clearActiveLockState() async {
        _ = await ActiveLockStore.shared.unblockAll()
        _ = await ActiveLockStore.shared.unshieldAll()
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.removeObject(forKey: "evlin.blockRecords")
        defaults?.removeObject(forKey: "evlin.shieldRecords")
    }

    // MARK: - set_limit with no `limit` → .failed (not success)

    func testSetLimitWithNoLimitPayloadFails() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        var cmd = makeLimitCommand()
        cmd = LockCommand(
            id: cmd.id,
            action: .setLimit,
            tier: cmd.tier,
            target: cmd.target,
            durationMinutes: nil,
            issuedAt: cmd.issuedAt,
            limit: nil  // malformed / undecoded
        )

        let result = await executor.execute(cmd)

        guard case .failed = result else {
            return XCTFail("set_limit with nil limit must FAIL, not silently succeed; got \(result)")
        }
        XCTAssertTrue(AppLimitRuleStore.shared.all().isEmpty, "no rule should persist for a malformed set_limit")
        XCTAssertTrue(spy.armed.isEmpty, "nothing should be armed for a malformed set_limit")
    }

    // MARK: - set_limit with undecodable token → .failed application_not_configured, NO rule persisted

    func testSetLimitWithUndecodableTokenFailsApplicationNotConfigured() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        // A non-empty but garbage base64 that decodes to bytes which are NOT a
        // valid ApplicationToken → decodedApplicationToken(from:) returns nil.
        let garbage = Data("not-a-token".utf8).base64EncodedString()
        let cmd = makeLimitCommand(catalogTokenBase64: garbage)

        let result = await executor.execute(cmd)

        guard case .failed(.applicationNotConfigured) = result else {
            return XCTFail("undecodable token must fail application_not_configured; got \(result)")
        }
        XCTAssertTrue(AppLimitRuleStore.shared.all().isEmpty, "no rule should persist when the token can't decode")
        XCTAssertTrue(spy.armed.isEmpty)
    }

    func testSetLimitWithNoTokenAtAllFailsApplicationNotConfigured() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        // No catalogTokenDataBase64 at all → the device has no token to shield.
        let cmd = makeLimitCommand(catalogTokenBase64: nil)

        let result = await executor.execute(cmd)

        guard case .failed(.applicationNotConfigured) = result else {
            return XCTFail("absent token must fail application_not_configured; got \(result)")
        }
        XCTAssertTrue(AppLimitRuleStore.shared.all().isEmpty)
    }

    // MARK: - set_limit quota trip → .failed(.limitQuotaExceeded) AND rollback

    /// Tokens can't be minted in a unit test, so the quota path is driven through
    /// the `applyLimitRule(_:displayName:)` seam (the same code path `execute`
    /// reaches AFTER a successful token decode). The new rule shares the seeded
    /// daily window, pushing that window's event count to cap+1 → quotaExceeded →
    /// the planner arms nothing → the executor MUST roll the new rule back out.
    func testApplyLimitRuleTrippingQuotaRollsBackTheNewRule() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)

        // Seed the store to the per-activity event cap on the default daily window.
        let dailyWindow = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil)
        for i in 0..<AppLimitPlanner.maxEventsPerActivity {
            AppLimitRuleStore.shared.upsert(AppLimitRule(
                id: UUID(),
                appTokens: [],
                bundleID: "com.seed.\(i)",
                displayName: "Seed \(i)",
                budgetMinutes: 30,
                window: dailyWindow,
                effectiveFrom: Date(timeIntervalSince1970: 0),
                expiresAt: nil
            ))
        }
        XCTAssertEqual(AppLimitRuleStore.shared.all().count, AppLimitPlanner.maxEventsPerActivity)

        // The new rule lands on the SAME window → cap + 1 events for that activity.
        let newRule = AppLimitRule(
            id: UUID(),
            appTokens: [],
            bundleID: "com.over.cap",
            displayName: "Overflow",
            budgetMinutes: 30,
            window: dailyWindow,
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )

        let result = executor.applyLimitRule(newRule, displayName: "Overflow")

        guard case let .failed(.limitQuotaExceeded(_, slotsNeeded, cap)) = result else {
            return XCTFail("expected .failed(.limitQuotaExceeded); got \(result)")
        }
        XCTAssertEqual(slotsNeeded, AppLimitPlanner.maxEventsPerActivity + 1)
        XCTAssertEqual(cap, AppLimitPlanner.maxEventsPerActivity)

        // Rollback: the new rule must NOT remain in the store, and the store must
        // be restored to exactly the seeded set.
        XCTAssertNil(AppLimitRuleStore.shared.rule(forID: newRule.id),
                     "quota-tripping rule must be rolled back out of the store")
        XCTAssertEqual(AppLimitRuleStore.shared.all().count, AppLimitPlanner.maxEventsPerActivity,
                       "rollback must restore the prior store exactly")
        // Atomicity of the FAILING pass: the over-cap window (cap + 1 events) was
        // never armed — the planner validated and armed NOTHING on quotaExceeded.
        // (Fix 1's rollback then RE-ARMS the restored valid set so the device
        // matches the store, so the spy legitimately sees the seeded window armed
        // at exactly `cap` events; what must never appear is a cap+1 arm.)
        XCTAssertFalse(spy.armed.contains { $0.events.count > AppLimitPlanner.maxEventsPerActivity },
                       "the over-cap window must never have been armed")
    }

    /// UPDATE-rollback: a `set_limit` that UPDATEs an existing rule (same id,
    /// changed budget/window) but trips `.quotaExceeded` must RESTORE the prior
    /// valid rule — not delete it. Before Fix 1 the rollback `remove`d by id,
    /// which deleted the previously-armed rule entirely (data loss).
    func testApplyLimitRuleUpdateTrippingQuotaRestoresPriorRule() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)

        let ruleID = UUID()
        // Rule X: the previously-valid, armed version of `r` on a DISTINCT window
        // (its own slot) so it does not itself contribute to the cap breach.
        let priorWindow = AppLimitWindow(startMinute: 60, endMinute: 120, repeats: true, timezone: nil)
        let priorRule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 45,
            window: priorWindow,
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        AppLimitRuleStore.shared.upsert(priorRule)

        // Saturate the DAILY window to the per-activity event cap with OTHER rules.
        let dailyWindow = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil)
        for i in 0..<AppLimitPlanner.maxEventsPerActivity {
            AppLimitRuleStore.shared.upsert(AppLimitRule(
                id: UUID(),
                appTokens: [],
                bundleID: "com.seed.\(i)",
                displayName: "Seed \(i)",
                budgetMinutes: 30,
                window: dailyWindow,
                effectiveFrom: Date(timeIntervalSince1970: 0),
                expiresAt: nil
            ))
        }

        // UPDATE of `r`: SAME id, different budget AND window (now the saturated
        // daily window) → that activity hits cap + 1 → quotaExceeded.
        let updatedRule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 90,            // changed budget
            window: dailyWindow,          // changed window → joins the saturated slot
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )

        let result = executor.applyLimitRule(updatedRule, displayName: "Instagram")

        guard case .failed(.limitQuotaExceeded) = result else {
            return XCTFail("expected .failed(.limitQuotaExceeded); got \(result)")
        }

        // The store must still hold the ORIGINAL X — not nil, not the new version.
        let restored = AppLimitRuleStore.shared.rule(forID: ruleID)
        XCTAssertNotNil(restored, "UPDATE-rollback must restore the prior rule, not delete it")
        XCTAssertEqual(restored, priorRule, "restored rule must be the ORIGINAL X (budget/window unchanged)")
        XCTAssertEqual(restored?.budgetMinutes, 45, "must NOT keep the updated budget")
        XCTAssertEqual(restored?.window, priorWindow, "must NOT keep the updated window")
    }

    // MARK: - repeats derivation: only "daily" recurs; unknown → non-repeating

    /// The `set_limit` window-build derives `repeats` POSITIVELY from
    /// `reset_policy`: only known-recurring policies recur. An unknown / future
    /// value (e.g. "none" or "once" — the app uses "none" for "Once" elsewhere)
    /// must yield a NON-repeating window, not silently recur daily. This exercises
    /// the SAME `windowRepeats(forResetPolicy:)` seam `executeSetLimit` calls when
    /// building the rule, so a real picker-minted token is not required.
    func testWindowRepeatsDerivationIsPositiveDaily() {
        // The only v1 recurring policy.
        XCTAssertTrue(ActionExecutor.windowRepeats(forResetPolicy: "daily"))
        XCTAssertTrue(ActionExecutor.windowRepeats(forResetPolicy: "Daily"),
                      "case-insensitive")

        // Unknown / future / non-recurring policies must NOT repeat.
        for policy in ["none", "once", "weekly", "future-unknown", ""] {
            XCTAssertFalse(ActionExecutor.windowRepeats(forResetPolicy: policy),
                           "unknown reset_policy '\(policy)' must be non-repeating")
        }
    }

    /// End-to-end through the rule-build derivation: a command whose `reset_policy`
    /// is the app's "Once" sentinel ("none") yields a persisted rule whose
    /// `window.repeats == false`. Tokens can't be minted in a unit test, so the
    /// rule is built via the same `windowRepeats(forResetPolicy:)` seam the
    /// post-decode `executeSetLimit` path uses, then persisted via `applyLimitRule`.
    func testSetLimitOnceResetPolicyPersistsNonRepeatingRule() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let ruleID = UUID()

        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 45,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: ActionExecutor.windowRepeats(forResetPolicy: "none"),
                timezone: "America/Los_Angeles"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )

        let result = executor.applyLimitRule(rule, displayName: "Instagram")
        guard case .confirmedExact = result else {
            return XCTFail("expected .confirmedExact; got \(result)")
        }

        let persisted = AppLimitRuleStore.shared.rule(forID: ruleID)
        XCTAssertNotNil(persisted, "rule should persist")
        XCTAssertFalse(persisted?.window.repeats ?? true,
                       "reset_policy 'none' (Once) must yield a non-repeating window")
    }

    /// The happy path through `applyLimitRule`: a single rule on its own window
    /// persists and arms, and the ack is `.confirmedExact(.setLimit)`.
    func testApplyLimitRuleHappyPathPersistsArmsAndConfirms() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)

        let rule = AppLimitRule(
            id: UUID(),
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 45,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )

        let result = executor.applyLimitRule(rule, displayName: "Instagram")

        guard case let .confirmedExact(verb, display, _) = result else {
            return XCTFail("expected .confirmedExact; got \(result)")
        }
        XCTAssertEqual(verb, .setLimit)
        XCTAssertEqual(display, "Instagram")
        XCTAssertNotNil(AppLimitRuleStore.shared.rule(forID: rule.id), "rule must persist on success")
        XCTAssertEqual(spy.armed.count, 1, "the planner armed the one window")
        // ENFORCEMENT events only — measurement (`evlin.applimit.*`) usage-bar
        // events also ride in the dict.
        let enforcementEvents = (spy.armed.first?.events ?? [:]).keys
            .filter { $0.rawValue.hasPrefix("evlin.limit.") }
        XCTAssertEqual(enforcementEvents.count, 1, "one enforcement event for the one rule")
    }

    // MARK: - clear_limit with no `clear` → .failed

    func testClearLimitWithNoClearPayloadFails() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let cmd = LockCommand(
            id: UUID(),
            action: .clearLimit,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: "com.burbn.instagram",
                originalRequest: "remove limit",
                targetDisplay: "Instagram",
                targetChildID: UUID()
            ),
            durationMinutes: nil,
            issuedAt: Date(),
            clear: nil
        )

        let result = await executor.execute(cmd)
        guard case .failed = result else {
            return XCTFail("clear_limit with nil clear must FAIL; got \(result)")
        }
    }

    // MARK: - clear_limit removes the rule, re-arms, is idempotent → .confirmedExact

    func testClearLimitRemovesRuleAndConfirms() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let ruleID = UUID()
        // Seed a persisted rule for this id (as set_limit would have).
        AppLimitRuleStore.shared.upsert(AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 45,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        ))
        XCTAssertNotNil(AppLimitRuleStore.shared.rule(forID: ruleID))

        let cmd = makeClearCommand(ruleID: ruleID)
        let result = await executor.execute(cmd)

        guard case let .confirmedExact(verb, _, _) = result else {
            return XCTFail("clear_limit should confirm; got \(result)")
        }
        XCTAssertEqual(verb, .clearLimit)
        XCTAssertNil(AppLimitRuleStore.shared.rule(forID: ruleID), "rule must be removed from the store")
    }

    /// clear_limit drops a source == .limit shield for the rule's app but PRESERVES
    /// a parent's source == .manual shield on the same app.
    func testClearLimitDropsLimitShieldButPreservesManualShield() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let ruleID = UUID()
        let bundleID = "com.burbn.instagram"

        // A limit-authored shield (the kind P7 would auto-apply at threshold) +
        // a parent's manual shield, both on the same app (matched by targetKey).
        let limitShield = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: bundleID),
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Instagram (limit)",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "limit",
            targetChildID: UUID(),
            sources: [.limit]
        )
        let manualShield = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .category, targetKey: "social"),
            tier: .category,
            targetKey: "social",
            displayName: "Social (parent)",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock social",
            targetChildID: UUID(),
            sources: [.manual]
        )
        _ = await ActiveLockStore.shared.addShield(limitShield)
        _ = await ActiveLockStore.shared.addShield(manualShield)

        AppLimitRuleStore.shared.upsert(AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Instagram",
            budgetMinutes: 45,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        ))

        _ = await executor.execute(makeClearCommand(bundleID: bundleID, ruleID: ruleID))

        let shields = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertFalse(shields.contains { $0.sources.contains(.limit) },
                       "the limit shield must be dropped on clear")
        XCTAssertTrue(shields.contains { $0.recordKey == manualShield.recordKey },
                      "the parent's manual shield must be preserved")
    }

    func testApplyLimitRuleFromCommandImmediatelyShieldsWhenUsedTodayAlreadyReachedBudget() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let rule = AppLimitRule(
            id: UUID(),
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 1,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )

        let result = await executor.applyLimitRuleFromCommand(
            rule,
            displayName: "Instagram",
            usedTodayMinutes: 1
        )

        guard case let .confirmedExact(verb, display, _) = result else {
            return XCTFail("expected set_limit confirmation; got \(result)")
        }
        XCTAssertEqual(verb, .setLimit)
        XCTAssertEqual(display, "Instagram")

        let shields = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertTrue(
            shields.contains {
                $0.recordKey == LimitShieldLogic.recordKey(for: rule)
                    && $0.sources.contains(.limit)
                    && $0.targetKey == "com.burbn.instagram"
            },
            "re-enabling an already-spent app limit must immediately restore the limit shield"
        )
    }

    /// Clearing a non-existent rule is idempotent — still confirms.
    func testClearLimitForUnknownRuleStillConfirms() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let cmd = makeClearCommand(ruleID: UUID())

        let result = await executor.execute(cmd)
        guard case let .confirmedExact(verb, _, _) = result else {
            return XCTFail("clear_limit for unknown rule should still confirm; got \(result)")
        }
        XCTAssertEqual(verb, .clearLimit)
    }
}
