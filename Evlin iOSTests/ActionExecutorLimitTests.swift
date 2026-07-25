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
    private var temporaryDirectory: URL!
    private var epochStore: AppLimitEpochStore!
    private var ruleStore: AppLimitRuleStore!

    override func setUp() async throws {
        await clearActiveLockState()
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ActionExecutorLimitTests.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        epochStore = AppLimitEpochStore(
            fileURL: temporaryDirectory.appendingPathComponent("epoch.json"),
            lock: ActionLimitEpochTestLock(),
            ownerProvider: { nil },
            legacyDefaults: nil
        )
        ruleStore = AppLimitRuleStore(
            epochStore: epochStore,
            expectedOwnerProvider: { nil }
        )
    }

    override func tearDown() async throws {
        await clearActiveLockState()
        ruleStore = nil
        epochStore = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
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
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: epochStore,
            appLimitOwnerProvider: { nil }
        )
    }

    private func makePlanner(spy: LimitSchedulerSpy) -> AppLimitPlanner {
        AppLimitPlanner(
            scheduler: spy,
            epochStore: epochStore,
            ownerProvider: { nil }
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
        XCTAssertTrue(ruleStore.all().isEmpty, "no rule should persist for a malformed set_limit")
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
        XCTAssertTrue(ruleStore.all().isEmpty, "no rule should persist when the token can't decode")
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
        XCTAssertTrue(ruleStore.all().isEmpty)
    }

    func testWindowRepeatsDerivationIsPositiveDaily() {
        XCTAssertTrue(ActionExecutor.windowRepeats(forResetPolicy: "daily"))
        XCTAssertTrue(ActionExecutor.windowRepeats(forResetPolicy: "Daily"))
        for policy in ["none", "once", "weekly", "future-unknown", ""] {
            XCTAssertFalse(
                ActionExecutor.windowRepeats(forResetPolicy: policy),
                "unknown reset_policy '\(policy)' must be non-repeating"
            )
        }
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

    func testDirectClearLimitCannotRemoveRuleWithoutDurableOwnerWork() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let ruleID = UUID()
        // Seed a persisted rule for this id (as set_limit would have).
        ruleStore.upsert(AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            budgetMinutes: 45,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        ))
        XCTAssertNotNil(ruleStore.rule(forID: ruleID))

        let cmd = makeClearCommand(ruleID: ruleID)
        let result = await executor.execute(cmd)

        XCTAssertEqual(result, .failed(.execution("app_limit_owner_work_required")))
        XCTAssertNotNil(ruleStore.rule(forID: ruleID))
        XCTAssertTrue(spy.armed.isEmpty)
    }

    /// clear_limit drops a source == .limit shield for the rule's app but PRESERVES
    /// a parent's source == .manual shield on the same app.
    func testDirectClearLimitCannotDropShieldsWithoutDurableOwnerWork() async {
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

        ruleStore.upsert(AppLimitRule(
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
        XCTAssertTrue(shields.contains { $0.sources.contains(.limit) },
                      "untrusted direct clear must not drop the limit shield")
        XCTAssertTrue(shields.contains { $0.recordKey == manualShield.recordKey },
                      "the parent's manual shield must be preserved")
    }

    func testClearLimitIdentityTeardownAfterRearmDoesNotRestoreOldFamilyState() async {
        let spy = LimitSchedulerSpy()
        let ruleID = UUID()
        let childID = UUID()
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.old-limit",
            displayName: "Old Limit",
            budgetMinutes: 45,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        let shield = ShieldRecord(
            recordKey: LimitShieldLogic.recordKey(for: rule),
            tier: .exactApp,
            targetKey: rule.bundleID,
            displayName: rule.displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "limit reached",
            targetChildID: childID,
            sources: [.limit]
        )
        ruleStore.upsert(rule)
        _ = await ActiveLockStore.shared.addShield(shield)
        _ = makePlanner(spy: spy).arm(rules: [rule])
        var currentID = childID
        var reachedCheckpoint = false
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: epochStore,
            appLimitOwnerProvider: { nil },
            afterMutationCheckpoint: { checkpoint in
                guard checkpoint == .clearLimitRearmed else { return }
                reachedCheckpoint = true
                currentID = UUID()
                self.ruleStore.removeAll()
                _ = self.makePlanner(spy: spy).arm(rules: [])
            }
        )

        let result = await executor.execute(
            makeClearCommand(bundleID: rule.bundleID, ruleID: ruleID),
            expectedChildID: childID,
            identityIsCurrent: { $0 == currentID }
        )

        XCTAssertFalse(reachedCheckpoint)
        XCTAssertEqual(result, .failed(.execution("app_limit_owner_work_required")))
        XCTAssertNotNil(ruleStore.rule(forID: ruleID))
        let shields = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertTrue(shields.contains { $0.recordKey == shield.recordKey })
        XCTAssertFalse(spy.activeActivities.isEmpty)
    }


    func testDirectClearLimitForUnknownRuleStillRequiresDurableOwnerWork() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)
        let cmd = makeClearCommand(ruleID: UUID())

        let result = await executor.execute(cmd)
        XCTAssertEqual(result, .failed(.execution("app_limit_owner_work_required")))
        XCTAssertTrue(spy.armed.isEmpty)
    }

    func testDirectSetLimitWithoutTokenFailsBeforeAnyMutation() async {
        let spy = LimitSchedulerSpy()
        let executor = makeExecutor(spy: spy)

        let result = await executor.execute(makeLimitCommand())

        guard case .failed(.applicationNotConfigured) = result else {
            return XCTFail("expected application_not_configured, got \(result)")
        }
        XCTAssertTrue(spy.armed.isEmpty)
        XCTAssertTrue(ruleStore.all().isEmpty)
    }

    func testAuthorizedSetOwnerWorkArmsReleasesUnexhaustedLimitShieldAndCommitsDurableReceipt() async throws {
        let owner = UUID()
        let ruleID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authorized-limit-work-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        let ruleStore = AppLimitRuleStore(
            epochStore: store,
            expectedOwnerProvider: { owner }
        )
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.focus",
            displayName: "Focus",
            budgetMinutes: 30,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
        let command = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 10,
            kind: .set,
            payloadDigest: "set-10",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .poll,
            rule: rule,
            authoritativeUsedTodayMinutes: 1
        )
        XCTAssertEqual(
            try AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { owner }
            ).ingest(command),
            .acceptedNeedsOwner
        )
        XCTAssertNotNil(try store.read().slots[ruleID]?.pendingOwnerWork)
        let spy = LimitSchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: store,
            appLimitOwnerProvider: { owner }
        )
        let recordKey = ShieldRecord.makeRecordKey(
            tier: .exactApp,
            targetKey: rule.bundleID
        )
        let existingShield = ShieldRecord(
            recordKey: recordKey,
            tier: .exactApp,
            targetKey: rule.bundleID,
            displayName: rule.displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            originalRequest: "previous exhausted limit plus manual lock",
            targetChildID: owner,
            sources: [.limit, .manual],
            limitRuleIDs: [ruleID]
        )
        _ = await ActiveLockStore.shared.addShield(existingShield)
        let lockCommand = LockCommand(
            id: command.commandID,
            action: .setLimit,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: rule.bundleID,
                originalRequest: "limit Focus",
                targetDisplay: rule.displayName,
                targetChildID: owner
            ),
            durationMinutes: nil,
            issuedAt: command.receivedAt,
            limit: LimitRule(
                ruleId: ruleID,
                orderingToken: 10,
                dailyBudgetMinutes: 30,
                resetPolicy: "daily",
                startMinute: 0,
                endMinute: 1439,
                timezone: "America/New_York",
                effectiveFrom: rule.effectiveFrom,
                expiresAt: nil,
                updatedAt: command.receivedAt,
                usedTodayMinutes: 1
            )
        )

        let result = await executor.executeAppLimitOwnerWork(
            lockCommand,
            envelope: command,
            expectedChildID: owner,
            identityIsCurrent: { $0 == owner }
        )

        guard case .confirmedExact(.setLimit, "Focus", _) = result.result else {
            return XCTFail("expected confirmed set owner work, got \(result.result)")
        }
        XCTAssertEqual(spy.armed.count, 1)
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.orderingToken, 10)
        XCTAssertEqual(
            receipt.armID,
            try store.read().slots[ruleID]?.armProvenance?.armID
        )
        XCTAssertNotNil(receipt.armID)
        XCTAssertGreaterThan(receipt.storeRevision, 0)
        let reread = try XCTUnwrap(store.read().slots[ruleID])
        XCTAssertEqual(
            reread.armProvenance?.baseAcceptedMinutes,
            1,
            "the new arm must preserve the server-confirmed usage already consumed today"
        )
        let armID = try XCTUnwrap(reread.armProvenance?.armID)
        let enforcementEvent = try XCTUnwrap(
            spy.armed.first?.events[
                DeviceActivityEvent.Name(
                    AppLimitPlanner.v2EnforcementEventName(armID: armID)
                )
            ]
        )
        XCTAssertEqual(
            enforcementEvent.threshold.minute,
            29,
            "a 30-minute rule with 1 minute already used must arm only the 29-minute remainder"
        )
        XCTAssertNil(reread.pendingOwnerWork)
        XCTAssertEqual(reread.appliedReceipt, receipt)
        XCTAssertEqual(
            try AppLimitProductionComposition.currentAppliedReceipt(
                ruleID: ruleID,
                store: store
            ),
            receipt
        )
        let shieldAfterIncrease = await ActiveLockStore.shared.allCurrent().shields.first {
            $0.recordKey == recordKey
        }
        XCTAssertEqual(shieldAfterIncrease?.sources, [.manual])
        XCTAssertTrue(shieldAfterIncrease?.limitRuleIDs.isEmpty == true)
    }

    func testRecoverySetOwnerWorkUsesPersistedAuthoritativeRemainder() async throws {
        let owner = UUID()
        let ruleID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authorized-limit-recovery-remainder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        let ruleStore = AppLimitRuleStore(
            epochStore: store,
            expectedOwnerProvider: { owner }
        )
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.recovery-remainder",
            displayName: "Recovery remainder",
            budgetMinutes: 15,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
        let envelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 12,
            kind: .set,
            payloadDigest: "set-12-used-11",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .notificationServiceExtension,
            rule: rule,
            authoritativeUsedTodayMinutes: 11
        )
        XCTAssertEqual(
            try AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { owner }
            ).ingest(envelope),
            .acceptedNeedsOwner
        )
        let slot = try XCTUnwrap(store.read().slots[ruleID])
        let work = try XCTUnwrap(slot.pendingOwnerWork)
        let spy = LimitSchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: store,
            appLimitOwnerProvider: { owner }
        )

        let effect = try await executor.recoverAppLimitOwnerEffect(
            work: work,
            slot: slot,
            expectedChildID: owner
        )

        let reread = try XCTUnwrap(store.read().slots[ruleID])
        XCTAssertEqual(reread.armProvenance?.baseAcceptedMinutes, 11)
        XCTAssertEqual(effect.armID, reread.armProvenance?.armID)
        let armID = try XCTUnwrap(effect.armID)
        let enforcementEvent = try XCTUnwrap(
            spy.armed.first?.events[
                DeviceActivityEvent.Name(
                    AppLimitPlanner.v2EnforcementEventName(armID: armID)
                )
            ]
        )
        XCTAssertEqual(enforcementEvent.threshold.minute, 4)
    }

    func testRecoverySetOwnerWorkStopsOldMonitorAndShieldsWhenAlreadyExhausted() async throws {
        let owner = UUID()
        let ruleID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authorized-limit-recovery-exhausted-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        let ruleStore = AppLimitRuleStore(
            epochStore: store,
            expectedOwnerProvider: { owner }
        )
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.recovery-exhausted",
            displayName: "Recovery exhausted",
            budgetMinutes: 1,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
        let envelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 13,
            kind: .set,
            payloadDigest: "set-13-used-11",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .notificationServiceExtension,
            rule: rule,
            authoritativeUsedTodayMinutes: 11
        )
        XCTAssertEqual(
            try AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { owner }
            ).ingest(envelope),
            .acceptedNeedsOwner
        )
        let slot = try XCTUnwrap(store.read().slots[ruleID])
        let work = try XCTUnwrap(slot.pendingOwnerWork)
        let spy = LimitSchedulerSpy()
        let staleActivity = DeviceActivityName("evlin.limit.v2.\(UUID().uuidString.lowercased())")
        try spy.startMonitoring(
            staleActivity,
            during: DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )
        )
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: store,
            appLimitOwnerProvider: { owner }
        )

        let effect = try await executor.recoverAppLimitOwnerEffect(
            work: work,
            slot: slot,
            expectedChildID: owner
        )

        XCTAssertNil(effect.armID)
        XCTAssertTrue(spy.monitoredActivities().isEmpty)
        XCTAssertTrue(spy.armed.isEmpty)
        let shield = await ActiveLockStore.shared.allCurrent().shields.first {
            $0.recordKey == LimitShieldLogic.recordKey(for: rule)
        }
        XCTAssertEqual(shield?.sources, [.limit])
        XCTAssertEqual(shield?.limitRuleIDs, [ruleID])
    }

    func testAuthorizedClearOwnerWorkRemovesOnlyLimitShieldAndCommitsReceipt() async throws {
        let owner = UUID()
        let ruleID = UUID()
        let bundleID = "com.example.focus"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authorized-limit-clear-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        let ruleStore = AppLimitRuleStore(
            epochStore: store,
            expectedOwnerProvider: { owner }
        )
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Focus",
            budgetMinutes: 30,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: nil
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
        let coordinator = AppLimitCommandCoordinator(
            store: store,
            expectedOwnerProvider: { owner }
        )
        _ = try coordinator.ingest(AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 10,
            kind: .set,
            payloadDigest: "set-10",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .poll,
            rule: rule
        ))
        let clearEnvelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 11,
            kind: .clear,
            payloadDigest: "clear-11",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .poll,
            rule: nil
        )
        XCTAssertEqual(try coordinator.ingest(clearEnvelope), .acceptedNeedsOwner)

        let limitShield = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: bundleID),
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Focus limit",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "limit",
            targetChildID: owner,
            sources: [.limit, .manual, .earnedTime, .taskPause]
        )
        let manualShield = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .category, targetKey: "manual-focus"),
            tier: .category,
            targetKey: "manual-focus",
            displayName: "Manual",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "manual",
            targetChildID: owner,
            sources: [.manual]
        )
        _ = await ActiveLockStore.shared.addShield(limitShield)
        _ = await ActiveLockStore.shared.addShield(manualShield)

        let spy = LimitSchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: store,
            appLimitOwnerProvider: { owner }
        )
        let command = LockCommand(
            id: clearEnvelope.commandID,
            action: .clearLimit,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "clear Focus",
                targetDisplay: "Focus",
                targetChildID: owner
            ),
            durationMinutes: nil,
            issuedAt: clearEnvelope.receivedAt,
            clear: ClearLimit(
                ruleId: ruleID,
                orderingToken: 11,
                reason: "parent_clear",
                updatedAt: clearEnvelope.receivedAt
            )
        )

        let result = await executor.executeAppLimitOwnerWork(
            command,
            envelope: clearEnvelope,
            expectedChildID: owner,
            identityIsCurrent: { $0 == owner }
        )

        guard case .confirmedExact(.clearLimit, "Focus", _) = result.result else {
            return XCTFail("expected confirmed clear owner work, got \(result.result)")
        }
        XCTAssertEqual(result.receipt?.orderingToken, 11)
        XCTAssertNil(result.receipt?.armID)
        let slot = try XCTUnwrap(store.read().slots[ruleID])
        XCTAssertNil(slot.activeRule)
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 11)
        XCTAssertNil(slot.pendingOwnerWork)
        XCTAssertEqual(slot.appliedReceipt, result.receipt)
        XCTAssertEqual(
            try AppLimitProductionComposition.currentAppliedReceipt(
                ruleID: ruleID,
                store: store
            ),
            result.receipt
        )
        let shields = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertEqual(
            shields.first { $0.recordKey == limitShield.recordKey }?.sources,
            [.manual, .earnedTime, .taskPause]
        )
        XCTAssertTrue(shields.contains { $0.recordKey == manualShield.recordKey })
    }

    func testRecoveryClearRemovesDirectSetLimitFromHistoricalMixedSourceRecord() async throws {
        let owner = UUID()
        let ruleID = UUID()
        let historicalCommandID = UUID()
        let bundleID = "com.example.direct-set-recovery"
        let store = AppLimitEpochStore(
            fileURL: temporaryDirectory.appendingPathComponent("direct-set-recovery.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        let ruleStore = AppLimitRuleStore(
            epochStore: store,
            expectedOwnerProvider: { owner }
        )
        let coordinator = AppLimitCommandCoordinator(
            store: store,
            expectedOwnerProvider: { owner }
        )
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Direct set recovery",
            budgetMinutes: 30,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
        let setEnvelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 10,
            kind: .set,
            payloadDigest: "set-10",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .poll,
            rule: rule,
            authoritativeUsedTodayMinutes: rule.budgetMinutes
        )
        XCTAssertEqual(try coordinator.ingest(setEnvelope), .acceptedNeedsOwner)

        let recordKey = ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: bundleID)
        let existing = ShieldRecord(
            recordKey: recordKey,
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Historical mixed source",
            lastCommandID: historicalCommandID,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_699_999_000),
            expiresAt: nil,
            originalRequest: "historical manual lock",
            targetChildID: owner,
            sources: [.manual, .earnedTime, .taskPause]
        )
        _ = await ActiveLockStore.shared.addShield(existing)

        let scheduler = LimitSchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: scheduler,
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: store,
            appLimitOwnerProvider: { owner }
        )
        let setCommand = LockCommand(
            id: setEnvelope.commandID,
            action: .setLimit,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "limit direct set recovery",
                targetDisplay: rule.displayName,
                targetChildID: owner
            ),
            durationMinutes: nil,
            issuedAt: setEnvelope.receivedAt,
            limit: LimitRule(
                ruleId: ruleID,
                orderingToken: 10,
                dailyBudgetMinutes: rule.budgetMinutes,
                resetPolicy: "daily",
                startMinute: 0,
                endMinute: 1439,
                timezone: "America/New_York",
                effectiveFrom: rule.effectiveFrom,
                expiresAt: nil,
                updatedAt: setEnvelope.receivedAt,
                usedTodayMinutes: rule.budgetMinutes
            )
        )

        let setResult = await executor.executeAppLimitOwnerWork(
            setCommand,
            envelope: setEnvelope,
            expectedChildID: owner,
            identityIsCurrent: { $0 == owner }
        )

        guard case .confirmedExact(.setLimit, rule.displayName, _) = setResult.result else {
            return XCTFail("expected confirmed direct set, got \(setResult.result)")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "group.com.evlin.ios"))
        let persistence = AppLimitShieldPersistence(store: defaults)
        let afterSet = try XCTUnwrap(try persistence.load()[recordKey])
        XCTAssertEqual(afterSet.lastCommandID, historicalCommandID)
        XCTAssertEqual(afterSet.sources, [.manual, .earnedTime, .taskPause, .limit])

        let clearEnvelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 11,
            kind: .clear,
            payloadDigest: "clear-11",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_200),
            source: .poll,
            rule: nil
        )
        XCTAssertEqual(try coordinator.ingest(clearEnvelope), .acceptedNeedsOwner)
        let readback = OwnerClearReadbackRecorder()
        let driver = AppLimitOwnerRecoveryDriver(
            store: store,
            effectPort: OwnerClearExecutorEffectPort(executor: executor, owner: owner),
            readbackPort: readback
        )

        await driver.recover(ownerChildDeviceID: owner)

        let afterClear = try XCTUnwrap(try persistence.load()[recordKey])
        XCTAssertEqual(afterClear.sources, [.manual, .earnedTime, .taskPause])
        let slot = try XCTUnwrap(store.read().slots[ruleID])
        XCTAssertNil(slot.pendingOwnerWork)
        XCTAssertEqual(slot.appliedReceipt?.commandKind, .clear)
        XCTAssertEqual(slot.appliedReceipt?.orderingToken, 11)
        let confirmationCount = await readback.count
        XCTAssertEqual(confirmationCount, 1)
    }

    func testRecoveryClearDoesNotConfirmUnattributedLimitState() async throws {
        // A legacy record can retain the same UUID in `lastCommandID`, but it
        // has no durable per-limit provenance. Recovery must not guess that it
        // belongs to this clear work item.
        let harness = try makeClearHarness(failure: nil)
        let readback = OwnerClearReadbackRecorder()
        let driver = AppLimitOwnerRecoveryDriver(
            store: harness.epochStore,
            effectPort: OwnerClearExecutorEffectPort(
                executor: harness.executor,
                owner: harness.owner
            ),
            readbackPort: readback
        )

        await driver.recover(ownerChildDeviceID: harness.owner)

        let slot = try XCTUnwrap(harness.epochStore.read().slots[harness.work.ruleID])
        XCTAssertEqual(slot.pendingOwnerWork, harness.work)
        XCTAssertNil(slot.appliedReceipt)
        XCTAssertTrue(try harness.persistenceStore.load().values.contains {
            $0.sources.contains(.limit)
        })
        let confirmationCount = await readback.count
        XCTAssertEqual(confirmationCount, 0)
    }

    func testAuthorizedClearPersistenceFailuresNeverConfirmOrCommitReceipt() async throws {
        for failure in OwnerClearPersistenceStoreStub.Failure.allCases {
            let harness = try makeClearHarness(failure: failure)

            let result = await harness.executor.executeAppLimitOwnerWork(
                harness.command,
                envelope: harness.envelope,
                expectedChildID: harness.owner,
                identityIsCurrent: { $0 == harness.owner }
            )

            XCTAssertEqual(result.result, .failed(.execution("lock_store_unavailable")))
            XCTAssertNil(result.receipt)
            let slot = try XCTUnwrap(harness.epochStore.read().slots[harness.work.ruleID])
            XCTAssertEqual(slot.pendingOwnerWork, harness.work)
            XCTAssertNil(slot.appliedReceipt)
        }
    }

    func testRecoveryClearPersistenceFailureNeverCommitsReceiptOrConfirms() async throws {
        let harness = try makeClearHarness(failure: .staleReadback)
        let readback = OwnerClearReadbackRecorder()
        let driver = AppLimitOwnerRecoveryDriver(
            store: harness.epochStore,
            effectPort: OwnerClearExecutorEffectPort(
                executor: harness.executor,
                owner: harness.owner
            ),
            readbackPort: readback
        )

        await driver.recover(ownerChildDeviceID: harness.owner)

        let slot = try XCTUnwrap(harness.epochStore.read().slots[harness.work.ruleID])
        XCTAssertEqual(slot.pendingOwnerWork, harness.work)
        XCTAssertNil(slot.appliedReceipt)
        let confirmationCount = await readback.count
        XCTAssertEqual(confirmationCount, 0)
    }

    private func makeClearHarness(
        failure: OwnerClearPersistenceStoreStub.Failure?,
        recordLastCommandID: UUID? = nil
    ) throws -> OwnerClearHarness {
        let owner = UUID()
        let ruleID = UUID()
        let commandID = UUID()
        let bundleID = "com.example.persistence-failure"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authorized-limit-clear-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let epochStore = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        let work = AppLimitOwnerWork(
            workID: UUID(),
            commandID: commandID,
            ruleID: ruleID,
            orderingToken: 11,
            commandKind: .clear,
            payloadDigest: "clear-11",
            source: .poll,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        _ = try epochStore.transaction(source: .poll, expectedOwner: owner) { state in
            state.slots[ruleID] = AppLimitVersionSlot(
                ruleID: ruleID,
                latestOrderingToken: 11,
                latestKind: .clear,
                latestPayloadDigest: "clear-11",
                activeRule: nil,
                clearTombstone: AppLimitClearTombstone(
                    ruleID: ruleID,
                    orderingToken: 11,
                    payloadDigest: "clear-11",
                    source: .poll,
                    clearedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                pendingOwnerWork: work,
                appliedReceipt: nil
            )
        }
        let persistenceStore = OwnerClearPersistenceStoreStub()
        let persistence = AppLimitShieldPersistence(store: persistenceStore)
        let record = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: bundleID),
            tier: .exactApp,
            targetKey: bundleID,
            displayName: "Persistence failure",
            lastCommandID: recordLastCommandID ?? ruleID,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            originalRequest: "limit",
            targetChildID: owner,
            sources: [.limit, .manual]
        )
        try persistence.persist([record.recordKey: record])
        persistenceStore.failure = failure
        let lockStore = ActiveLockStore(
            defaults: nil,
            shieldPersistence: persistenceStore
        )
        let ruleStore = AppLimitRuleStore(
            epochStore: epochStore,
            expectedOwnerProvider: { owner }
        )
        let executor = ActionExecutor(
            activityScheduler: LimitSchedulerSpy(),
            authorizationStatusProvider: { .approved },
            ruleStore: ruleStore,
            appLimitEpochStore: epochStore,
            appLimitOwnerProvider: { owner },
            appLimitLockStore: lockStore
        )
        let envelope = AppLimitCommandEnvelope(
            commandID: commandID,
            ruleID: ruleID,
            orderingToken: 11,
            kind: .clear,
            payloadDigest: "clear-11",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .poll,
            rule: nil
        )
        let command = LockCommand(
            id: commandID,
            action: .clearLimit,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "clear persistence failure",
                targetDisplay: "Persistence failure",
                targetChildID: owner
            ),
            durationMinutes: nil,
            issuedAt: envelope.receivedAt,
            clear: ClearLimit(
                ruleId: ruleID,
                orderingToken: 11,
                reason: "parent_clear",
                updatedAt: envelope.receivedAt
            )
        )
        return OwnerClearHarness(
            owner: owner,
            epochStore: epochStore,
            work: work,
            executor: executor,
            envelope: envelope,
            command: command,
            persistenceStore: persistenceStore
        )
    }
}

private struct OwnerClearHarness {
    let owner: UUID
    let epochStore: AppLimitEpochStore
    let work: AppLimitOwnerWork
    let executor: ActionExecutor
    let envelope: AppLimitCommandEnvelope
    let command: LockCommand
    let persistenceStore: OwnerClearPersistenceStoreStub
}

private final class OwnerClearPersistenceStoreStub:
    AppLimitShieldPersistenceStore,
    ActiveLockShieldPersistence
{
    private enum StoreError: Error {
        case injectedFailure
    }

    enum Failure: CaseIterable {
        case reload
        case write
        case staleReadback
    }

    var failure: Failure? {
        didSet {
            staleData = persistedData
            didWrite = false
        }
    }
    private var persistedData: Data?
    private var staleData: Data?
    private var didWrite = false

    func data(forKey defaultName: String) -> Data? {
        if failure == .staleReadback, didWrite { return staleData }
        return persistedData
    }

    func set(_ value: Any?, forKey defaultName: String) {
        persistedData = value as? Data
        didWrite = true
    }

    func synchronize() -> Bool {
        return true
    }

    func load() throws -> [String: ShieldRecord] {
        if failure == .reload { throw StoreError.injectedFailure }
        return try AppLimitShieldPersistence(store: self).load()
    }

    func persist(_ shields: [String: ShieldRecord]) throws {
        if failure == .write { throw StoreError.injectedFailure }
        try AppLimitShieldPersistence(store: self).persist(shields)
    }
}

@MainActor
private final class OwnerClearExecutorEffectPort: AppLimitOwnerEffectPort, @unchecked Sendable {
    let executor: ActionExecutor
    let owner: UUID

    init(executor: ActionExecutor, owner: UUID) {
        self.executor = executor
        self.owner = owner
    }

    func apply(
        work: AppLimitOwnerWork,
        slot: AppLimitVersionSlot
    ) async throws -> AppLimitOwnerEffectResult {
        try await executor.recoverAppLimitOwnerEffect(
            work: work,
            slot: slot,
            expectedChildID: owner
        )
    }
}

private actor OwnerClearReadbackRecorder: AppLimitOwnerReadbackPort {
    private(set) var count = 0

    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws {
        count += 1
    }
}

private final class ActionLimitEpochTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
