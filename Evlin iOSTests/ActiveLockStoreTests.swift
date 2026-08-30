import XCTest
@testable import Evlin_iOS

/// Tests for the new (tier, targetKey)-keyed ActiveLockStore.
/// Uses exactApp tier where possible since tokens can be constructed in tests
/// via an opaque Data-based encoding (see `TestHelpers`).
final class ActiveLockStoreTests: XCTestCase {
    override func setUp() async throws {
        // Clear shared App Group state so tests don't pollute each other.
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.removeObject(forKey: "evlin.shieldRecords")
        defaults?.removeObject(forKey: "evlin.blockRecords")
        defaults?.removeObject(forKey: EarnedShieldEffectStore.envelopeKey)
    }

    func test_reapplyCurrentRestrictions_reportsFailureWhenDurableStateCannotReload() async throws {
        let suiteName = "active-lock-reapply-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ActiveLockStore(defaults: defaults)
        defaults.removeObject(forKey: "evlin.lastRecompute")
        defaults.set(Data("not-json-or-plist".utf8), forKey: "evlin.blockRecords")
        let reapplied = await store.reapplyCurrentRestrictions()

        XCTAssertFalse(reapplied)
        XCTAssertNil(defaults.string(forKey: "evlin.lastRecompute"))
    }

    func test_durable_lock_serializes_extension_write_after_cas_persist() throws {
        let recordKey = "all:all"
        let compared = DispatchSemaphore(value: 0)
        let writerAttempted = DispatchSemaphore(value: 0)
        let writerEntered = DispatchSemaphore(value: 0)
        let casFinished = expectation(description: "CAS finished")
        let writerFinished = expectation(description: "extension writer finished")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "group.com.evlin.ios"))

        let oldRecord = Self.makeAllRecord(recordKey: recordKey, minutes: 30)
        let newerRecord = Self.makeAllRecord(recordKey: recordKey, minutes: nil)
        try Self.persistShields([recordKey: oldRecord], defaults: defaults)

        DispatchQueue.global().async {
            _ = ActiveLockPersistenceLock.shared.withLock {
                let comparedRecords = try! Self.loadShields(defaults: defaults)
                XCTAssertEqual(comparedRecords[recordKey]?.lastCommandID, oldRecord.lastCommandID)
                compared.signal()
                XCTAssertEqual(writerAttempted.wait(timeout: .now() + 2), .success)
                XCTAssertEqual(
                    writerEntered.wait(timeout: .now() + 0.05),
                    .timedOut,
                    "extension writer entered between rollback compare and persist"
                )
                try! Self.persistShields([:], defaults: defaults)
            }
            casFinished.fulfill()
        }

        XCTAssertEqual(compared.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            writerAttempted.signal()
            _ = ActiveLockPersistenceLock.shared.withLock {
                writerEntered.signal()
                try! Self.persistShields([recordKey: newerRecord], defaults: defaults)
            }
            writerFinished.fulfill()
        }

        wait(for: [casFinished, writerFinished], timeout: 3)
        let finalRecord = try Self.loadShields(defaults: defaults)[recordKey]
        XCTAssertEqual(finalRecord?.lastCommandID, newerRecord.lastCommandID)
        XCTAssertEqual(finalRecord?.targetChildID, newerRecord.targetChildID)
    }

    // MARK: - Merge rules (spec §3.4)

    func test_add_same_target_timed_new_longer_extends() async {
        let store = ActiveLockStore()
        let r1 = Self.makeTimedShield(displayName: "IG", minutes: 30)
        let r2 = Self.makeTimedShield(displayName: "IG", minutes: 60, recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        if case .extendedTimed(let newExpiry) = result {
            XCTAssertGreaterThan(newExpiry, r1.expiresAt!)
        } else {
            XCTFail("Expected .extendedTimed, got \(result)")
        }
        let current = await store.allCurrent().shields
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].expiresAt, r2.expiresAt)
    }

    func test_add_same_target_timed_new_shorter_noOp() async {
        let store = ActiveLockStore()
        let r1 = Self.makeTimedShield(displayName: "IG", minutes: 60)
        let r2 = Self.makeTimedShield(displayName: "IG", minutes: 30, recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        XCTAssertEqual(String(describing: result), "noOpShorterThanExisting")
    }

    func test_add_same_target_timed_upgraded_to_permanent() async {
        let store = ActiveLockStore()
        let r1 = Self.makeTimedShield(displayName: "IG", minutes: 30)
        let r2 = Self.makePermanentShield(displayName: "IG", recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        if case .upgradedToPermanent(let prev) = result {
            XCTAssertEqual(
                prev.timeIntervalSince1970,
                r1.expiresAt?.timeIntervalSince1970 ?? 0,
                accuracy: 1
            )
        } else {
            XCTFail("Expected .upgradedToPermanent, got \(result)")
        }
        let current = await store.allCurrent().shields
        XCTAssertNil(current[0].expiresAt)
    }

    func test_add_same_target_permanent_to_timed_needs_confirmation() async {
        let store = ActiveLockStore()
        let r1 = Self.makePermanentShield(displayName: "IG")
        let r2 = Self.makeTimedShield(displayName: "IG", minutes: 30, recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        if case .needsConfirmation(let reason) = result {
            if case .downgradePermanentToTimed(let key, _) = reason {
                XCTAssertEqual(key, r1.recordKey)
            } else {
                XCTFail("wrong reason \(reason)")
            }
        } else {
            XCTFail("Expected .needsConfirmation, got \(result)")
        }
    }

    func test_add_same_target_both_permanent_noOp() async {
        let store = ActiveLockStore()
        let r1 = Self.makePermanentShield(displayName: "IG")
        let r2 = Self.makePermanentShield(displayName: "IG", recordKey: r1.recordKey)

        _ = await store.addShield(r1)
        let result = await store.addShield(r2)

        XCTAssertEqual(String(describing: result), "noOpAlreadyPermanent")
    }

    // MARK: - Different (tier, target) coexist

    func test_different_tiers_covering_same_app_coexist() async {
        let store = ActiveLockStore()
        let exact = Self.makeTimedShield(displayName: "IG", minutes: 30, tier: .exactApp, targetKey: "ig_token_key")
        let category = Self.makeTimedShield(displayName: "Social", minutes: 60, tier: .category, targetKey: "social")

        _ = await store.addShield(exact)
        _ = await store.addShield(category)

        let current = await store.allCurrent().shields
        XCTAssertEqual(current.count, 2)
    }

    // MARK: - unshieldAll preserves blocks (spec §4.4)

    func test_unshieldAll_preserves_blocks() async {
        let store = ActiveLockStore()
        let shield = Self.makeTimedShield(displayName: "IG", minutes: 30)
        let block = BlockRecord(bundleID: "com.roblox.robloxmobile", displayName: "Roblox",
                                 blockedAt: Date(), lastCommandID: UUID(),
                                 originalRequest: "block Roblox",
                                 targetChildID: UUID())

        _ = await store.addShield(shield)
        _ = await store.addBlock(block)

        let cleared = await store.unshieldAll()
        XCTAssertEqual(cleared.count, 1)

        let final = await store.allCurrent()
        XCTAssertEqual(final.shields.count, 0)
        XCTAssertEqual(final.blocks.count, 1)
    }

    // MARK: - addBlock duplicate

    func test_addBlock_duplicate_alreadyBlocked() async {
        let store = ActiveLockStore()
        let b = BlockRecord(bundleID: "com.burbn.instagram", displayName: "Instagram",
                            blockedAt: Date(), lastCommandID: UUID(),
                            originalRequest: "block IG",
                            targetChildID: UUID())

        _ = await store.addBlock(b)
        let result = await store.addBlock(b)

        XCTAssertEqual(String(describing: result), "alreadyBlocked")
        let current = await store.allCurrent().blocks
        XCTAssertEqual(current.count, 1)
    }

    // MARK: - removeBlock reports remaining shields

    func test_removeBlock_reports_remaining_shields() async {
        let store = ActiveLockStore()
        let shield = Self.makeTimedShield(displayName: "Social", minutes: 60, tier: .category, targetKey: "social")
        let block = BlockRecord(bundleID: "com.burbn.instagram", displayName: "Instagram",
                                 blockedAt: Date(), lastCommandID: UUID(),
                                 originalRequest: "block IG",
                                 targetChildID: UUID())
        _ = await store.addShield(shield)
        _ = await store.addBlock(block)

        let removed = await store.removeBlock(bundleID: "com.burbn.instagram")
        XCTAssertNotNil(removed)
        let final = await store.allCurrent().blocks
        XCTAssertEqual(final.count, 0)
    }

    // MARK: - Effective-state query (spec §3.5)

    func test_effectiveState_returns_covering_shields() async {
        let store = ActiveLockStore()
        let cat = Self.makeTimedShield(displayName: "Social", minutes: 60,
                                        tier: .category, targetKey: "social")
        _ = await store.addShield(cat)

        let state = await store.effectiveState(for: AppQuery(categoryHint: "social"))
        XCTAssertEqual(state.shieldsCovering.count, 1)
        XCTAssertFalse(state.isBlocked)
    }

    func test_effectiveState_flags_blocked() async {
        let store = ActiveLockStore()
        let b = BlockRecord(bundleID: "com.x", displayName: "X",
                             blockedAt: Date(), lastCommandID: UUID(),
                             originalRequest: "block", targetChildID: UUID())
        _ = await store.addBlock(b)

        let state = await store.effectiveState(for: AppQuery(bundleID: "com.x"))
        XCTAssertTrue(state.isBlocked)
    }

    @MainActor
    func test_sweepExpired_removes_past_shields() async {
        let store = ActiveLockStore()
        let live = Self.makeTimedShield(displayName: "IG", minutes: 60, targetKey: "live_key")
        let soon = Self.makeTimedShield(displayName: "TT", minutes: 1, expiresAt: Date().addingTimeInterval(30), targetKey: "soon_key")

        _ = await store.addShield(live)
        _ = await store.addShield(soon)

        let removed = await store.sweepExpired(now: Date().addingTimeInterval(120))
        XCTAssertEqual(removed.map(\.recordKey), [soon.recordKey])
        let after = await store.allCurrent().shields.count
        XCTAssertEqual(after, 1)
    }

    func test_sweepExpired_removes_past_blocks() async {
        let store = ActiveLockStore()
        let live = BlockRecord(bundleID: "com.live.app",
                               displayName: "Live",
                               blockedAt: Date(),
                               lastCommandID: UUID(),
                               originalRequest: "test",
                               targetChildID: UUID(),
                               expiresAt: Date().addingTimeInterval(60))
        let dead = BlockRecord(bundleID: "com.dead.app",
                               displayName: "Dead",
                               blockedAt: Date(),
                               lastCommandID: UUID(),
                               originalRequest: "test",
                               targetChildID: UUID(),
                               expiresAt: Date().addingTimeInterval(-5))

        _ = await store.addBlock(live)
        _ = await store.addBlock(dead)

        _ = await store.sweepExpired()

        let after = await store.allCurrent().blocks
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].bundleID, live.bundleID)
    }

    // MARK: - webOpen full-union projection (C-3 Task 1)

    /// A broad record that requests web access (reflection) must open the WEB
    /// projection even while a parent full lock keeps the APP projection at
    /// `.all`. webOpen wins only for the web fields.
    func test_webOpen_broad_record_wins_only_for_web_projection() {
        let parentAll = Self.makeAllRecord(recordKey: "all", minutes: nil)
        let reflectionWebOpen = ReflectionLockRecordFactory.make(
            rid: UUID(), expiresAt: Date(timeIntervalSince1970: 2_000), childID: UUID()
        )

        let projection = ActiveShieldProjection.make(records: [parentAll, reflectionWebOpen])

        XCTAssertEqual(projection.applications, .all)
        XCTAssertEqual(projection.webDomains, .open)
    }

    func test_projection_without_webOpen_keeps_parent_full_web_shield() {
        let parentAll = Self.makeAllRecord(recordKey: "all", minutes: nil)

        let projection = ActiveShieldProjection.make(records: [parentAll])

        XCTAssertEqual(projection.applications, .all)
        XCTAssertEqual(projection.webDomains, .all)
    }

    func test_projection_union_of_web_tokens_with_no_broad_records_is_specific_or_open() {
        let exact = Self.makeTimedShield(displayName: "IG", minutes: 30)

        let projection = ActiveShieldProjection.make(records: [exact])

        XCTAssertEqual(projection.webDomains, .open)
        XCTAssertNotEqual(projection.applications, .all)
    }

    func test_reflection_web_open_coexisting_with_parent_all_keeps_web_available() async {
        let store = ActiveLockStore()
        let parentAll = Self.makeAllRecord(recordKey: "all", minutes: nil)
        let reflection = ReflectionLockRecordFactory.make(
            rid: UUID(), expiresAt: Date().addingTimeInterval(600), childID: UUID()
        )

        _ = await store.addShield(parentAll)
        _ = await store.addShield(reflection, force: true)

        let diag = UserDefaults(suiteName: "group.com.evlin.ios")?
            .string(forKey: "evlin.lastRecompute")
        XCTAssertTrue(
            diag?.contains("branch=all_apps_only") == true,
            "webOpen reflection must keep web available (got \(diag ?? "missing diag"))"
        )
    }

    // MARK: - Reflection lock coexistence (dedicated-key design)

    func test_app_only_all_record_does_not_apply_all_web_domain_category() async throws {
        let store = ActiveLockStore()
        guard let allApps = ShieldTier(rawValue: "allApps") else {
            XCTFail("ShieldTier must support app-only all locks")
            return
        }
        let record = ShieldRecord(
            recordKey: "allApps:reflection:\(UUID().uuidString)",
            tier: allApps,
            targetKey: "reflection",
            displayName: "Reflection lock",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            originalRequest: "reflection lockdown",
            targetChildID: UUID()
        )

        _ = await store.addShield(record)

        let diag = UserDefaults(suiteName: "group.com.evlin.ios")?
            .string(forKey: "evlin.lastRecompute")
        XCTAssertTrue(diag?.contains("branch=all_apps_only") == true, diag ?? "missing diag")
    }

    func test_legacy_reflection_all_record_is_migrated_to_app_only() async {
        let store = ActiveLockStore()
        let rid = UUID()
        let legacy = Self.makeAllRecord(recordKey: "all:reflection:\(rid.uuidString)", minutes: 20)

        _ = await store.addShield(legacy)

        let current = await store.allCurrent().shields
        XCTAssertEqual(current.first?.tier, .allApps)
        XCTAssertEqual(current.first?.recordKey, legacy.recordKey)
        let diag = UserDefaults(suiteName: "group.com.evlin.ios")?
            .string(forKey: "evlin.lastRecompute")
        XCTAssertTrue(diag?.contains("branch=all_apps_only") == true, diag ?? "missing diag")
    }

    func test_restore_migrates_legacy_reflection_all_record_to_app_only() async throws {
        let rid = UUID()
        let legacy = Self.makeAllRecord(recordKey: "all:reflection:\(rid.uuidString)", minutes: 20)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([legacy.recordKey: legacy])
        UserDefaults(suiteName: "group.com.evlin.ios")?.set(data, forKey: "evlin.shieldRecords")

        let store = ActiveLockStore()

        let current = await store.allCurrent().shields
        XCTAssertEqual(current.first?.tier, .allApps)
        XCTAssertEqual(current.first?.recordKey, legacy.recordKey)
        let diag = UserDefaults(suiteName: "group.com.evlin.ios")?
            .string(forKey: "evlin.lastRecompute")
        XCTAssertTrue(diag?.contains("branch=all_apps_only") == true, diag ?? "missing diag")
    }

    func test_reflection_all_record_coexists_and_removes_independently_of_parent_all() async {
        let store = ActiveLockStore()
        let parentAll = Self.makeAllRecord(recordKey: "all", minutes: nil)               // permanent parent all-lock
        let rid = UUID()
        let reflectionAll = Self.makeAllRecord(recordKey: "all:reflection:\(rid)", minutes: 20)
        _ = await store.addShield(parentAll)
        _ = await store.addShield(reflectionAll)
        let bothCount = await store.allCurrent().shields.count
        XCTAssertEqual(bothCount, 2)   // both coexist
        _ = await store.removeShield(recordKey: "all:reflection:\(rid)")
        let remaining = await store.allCurrent().shields
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].recordKey, "all")               // parent all-lock survives
    }

    @MainActor
    func test_liveActorMutationAfterEarnedEffectPreservesEveryDurableSourceAndBlock() async throws {
        let owner = UUID(uuidString: "82000000-0000-4000-8000-000000000001")!
        let epochFixture = try Self.makeActiveEpochFixture(owner: owner)
        defer { try? FileManager.default.removeItem(at: epochFixture.url) }
        let suiteName = "ActiveLockStoreEarnedRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeStore = ActiveLockStore(defaults: defaults)

        var manual = Self.makeAllRecord(recordKey: "all", minutes: nil)
        manual.targetChildID = owner
        manual.sources = [.manual]
        var taskPause = Self.makePermanentShield(
            displayName: "Task pause",
            tier: .category,
            targetKey: "task-pause",
            recordKey: "category:task-pause"
        )
        taskPause.targetChildID = owner
        taskPause.sources = [.taskPause]
        var deviceLimit = Self.makePermanentShield(
            displayName: "Device limit",
            tier: .allApps,
            targetKey: "device-limit",
            recordKey: "allApps:device-limit"
        )
        deviceLimit.targetChildID = owner
        deviceLimit.appliesToAll = true
        deviceLimit.sources = [.limit]
        var perAppLimit = Self.makePermanentShield(
            displayName: "Per-app limit",
            tier: .exactApp,
            targetKey: "per-app",
            recordKey: "exactApp:per-app"
        )
        perAppLimit.targetChildID = owner
        perAppLimit.sources = [.limit]
        var futureSource = Self.makePermanentShield(
            displayName: "Future source",
            tier: .savedList,
            targetKey: "future-source",
            recordKey: "savedList:future-source"
        )
        futureSource.targetChildID = owner
        futureSource.sources = [ShieldSource(rawValue: "future-source")]
        let block = BlockRecord(
            bundleID: "com.evlin.blocked",
            displayName: "Blocked",
            blockedAt: Date(),
            lastCommandID: UUID(),
            originalRequest: "test",
            targetChildID: owner
        )

        _ = await activeStore.addShield(manual)
        _ = await activeStore.addShield(taskPause)
        _ = await activeStore.addShield(deviceLimit)
        _ = await activeStore.addShield(perAppLimit)
        _ = await activeStore.addShield(futureSource)
        _ = await activeStore.addBlock(block)

        let earned = ShieldRecord(
            recordKey: "allApps:earned",
            tier: .allApps,
            targetKey: "earned",
            displayName: "Earned time",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "earned",
            targetChildID: owner,
            sources: [.earnedTime]
        )
        let operationID = UUID()
        let envelope = EarnedShieldEffectEnvelope(
            operationID: operationID,
            ownerChildDeviceID: owner,
            generationID: epochFixture.generationID,
            epochID: epochFixture.epochID,
            routeID: epochFixture.routeID,
            recordKey: earned.recordKey,
            beforeRecord: nil,
            intendedAfterRecord: earned,
            phase: .prepared,
            retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: Date(), lastErrorCode: nil, terminal: .pending),
            createdAt: Date()
        )
        try EarnedShieldEffectStore(defaults: defaults, epochStore: epochFixture.store).apply(envelope)

        var postEffectManual = Self.makePermanentShield(
            displayName: "Post-effect manual",
            tier: .category,
            targetKey: "post-effect",
            recordKey: "category:post-effect"
        )
        postEffectManual.targetChildID = owner
        postEffectManual.sources = [.manual]
        _ = await activeStore.addShield(postEffectManual)

        let current = await activeStore.allCurrent()
        XCTAssertEqual(Set(current.shields.map(\.recordKey)), Set([
            manual.recordKey,
            taskPause.recordKey,
            deviceLimit.recordKey,
            perAppLimit.recordKey,
            futureSource.recordKey,
            earned.recordKey,
            postEffectManual.recordKey,
        ]))
        XCTAssertEqual(current.shields.first(where: { $0.recordKey == manual.recordKey })?.sources, [.manual])
        XCTAssertEqual(current.shields.first(where: { $0.recordKey == taskPause.recordKey })?.sources, [.taskPause])
        XCTAssertEqual(current.shields.first(where: { $0.recordKey == deviceLimit.recordKey })?.sources, [.limit])
        XCTAssertEqual(current.shields.first(where: { $0.recordKey == perAppLimit.recordKey })?.sources, [.limit])
        XCTAssertEqual(current.shields.first(where: { $0.recordKey == earned.recordKey })?.sources, [.earnedTime])
        XCTAssertEqual(
            current.shields.first(where: { $0.recordKey == futureSource.recordKey })?.sources,
            [ShieldSource(rawValue: "future-source")]
        )
        XCTAssertEqual(current.blocks.map(\.bundleID), [block.bundleID])
        XCTAssertEqual(try Self.loadShields(defaults: defaults)[earned.recordKey]?.sources, [.earnedTime])
    }

    // MARK: - Helpers

    private static func makeAllRecord(
        recordKey: String,
        minutes: Int?
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: .all,
            targetKey: "all",
            displayName: "All",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) },
            originalRequest: "test",
            targetChildID: UUID()
        )
    }

    private static func makeTimedShield(
        displayName: String,
        minutes: Int,
        expiresAt: Date? = nil,
        tier: ShieldTier = .exactApp,
        targetKey: String? = nil,
        recordKey: String? = nil
    ) -> ShieldRecord {
        let tk = targetKey ?? "test_key_\(UUID().uuidString.prefix(6))"
        let rk = recordKey ?? ShieldRecord.makeRecordKey(tier: tier, targetKey: tk)
        return ShieldRecord(
            recordKey: rk,
            tier: tier,
            targetKey: tk,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: tier == .all,
            issuedAt: Date(),
            expiresAt: expiresAt ?? Date().addingTimeInterval(TimeInterval(minutes * 60)),
            originalRequest: "test",
            targetChildID: UUID()
        )
    }

    private static func makePermanentShield(
        displayName: String,
        tier: ShieldTier = .exactApp,
        targetKey: String? = nil,
        recordKey: String? = nil
    ) -> ShieldRecord {
        let tk = targetKey ?? "test_key_\(UUID().uuidString.prefix(6))"
        let rk = recordKey ?? ShieldRecord.makeRecordKey(tier: tier, targetKey: tk)
        return ShieldRecord(
            recordKey: rk,
            tier: tier,
            targetKey: tk,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: tier == .all,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID()
        )
    }

    private static func persistShields(
        _ records: [String: ShieldRecord],
        defaults: UserDefaults
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(records), forKey: "evlin.shieldRecords")
        defaults.synchronize()
    }

    private static func loadShields(defaults: UserDefaults) throws -> [String: ShieldRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try XCTUnwrap(defaults.data(forKey: "evlin.shieldRecords"))
        return try decoder.decode([String: ShieldRecord].self, from: data)
    }

    private static func makeActiveEpochFixture(owner: UUID) throws -> ActiveEpochFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-lock-effect-\(UUID().uuidString).json")
        let store = DeviceEpochStore(fileURL: url, ownerProvider: { owner })
        let selection = Data([0x41, 0x42, 0x43])
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "active-lock-effect",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: UUID()
        )
        let horizon = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-18",
            generationKey: generationKey,
            persistedSelectionBytes: selection,
            poolMinutes: 120,
            deviceCapMinutes: 120,
            authoritativeBaseAcceptedMinutes: 0,
            now: Date(timeIntervalSince1970: 1_784_419_200)
        ))
        let routeID = try XCTUnwrap(horizon.routeIDsByUsageDate["2026-07-18"])
        try store.transaction(expectedOwner: owner) { state in
            guard var route = state.routes[routeID] else { throw ActiveEpochFixtureError.missingRoute }
            route.lifecycle = .active
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[routeID] = route
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = routeID
            state.epochs[route.epochID]?.status = .active
        }
        let state = try store.read()
        return ActiveEpochFixture(
            url: url,
            store: store,
            generationID: try XCTUnwrap(state.activeGenerationID),
            epochID: try XCTUnwrap(state.activeEpochID),
            routeID: try XCTUnwrap(state.activeRouteID)
        )
    }
}

private struct ActiveEpochFixture {
    let url: URL
    let store: DeviceEpochStore
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
}

private enum ActiveEpochFixtureError: Error {
    case missingRoute
}
