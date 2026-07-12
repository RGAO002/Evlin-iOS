import XCTest
@testable import Evlin_iOS

/// Tests for the new (tier, targetKey)-keyed ActiveLockStore.
/// Uses exactApp tier where possible since tokens can be constructed in tests
/// via an opaque Data-based encoding (see `TestHelpers`).
final class ActiveLockStoreTests: XCTestCase {
    override func setUp() async throws {
        // Clear shared App Group state so tests don't pollute each other.
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.shieldRecords")
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.blockRecords")
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
            XCTAssertEqual(prev, r1.expiresAt)
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
}
