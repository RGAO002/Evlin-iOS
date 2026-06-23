import XCTest
@testable import Evlin_iOS

/// Cross-process correctness tests for `ActiveLockStore`'s reconciliation of
/// extension-owned `source == .limit` ShieldRecords.
///
/// The DeviceActivity extension (`DeviceActivityMonitorExtension`) writes/removes
/// `.limit` records DIRECTLY into the App Group dict (`group.com.evlin.ios`, key
/// `evlin.shieldRecords`) on threshold-fire / daily-reset. The main app's
/// `ActiveLockStore` loads that dict ONCE at init, so before the reconcile fix
/// its stale in-memory copy clobbered the extension's writes on every persist /
/// recompute. These tests simulate the extension by writing the App Group dict
/// directly via `UserDefaults(suiteName:)`, mirroring the existing
/// `ActiveLockStoreTests` clean-instance pattern (fresh `ActiveLockStore()` per
/// test + App Group keys cleared in `setUp`).
final class ActiveLockStoreLimitReconcileTests: XCTestCase {

    private let suiteName = "group.com.evlin.ios"
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"

    override func setUp() async throws {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: shieldsKey)
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: blocksKey)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: shieldsKey)
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: blocksKey)
    }

    // MARK: - NEGATIVE REGRESSION (the Critical)

    /// Simulate the extension writing a `source == .limit` record into the App
    /// Group dict, THEN perform a routine main-app mutation (an unrelated manual
    /// `addShield`). The `.limit` record MUST survive in `allCurrent().shields`.
    ///
    /// Before the reconcile fix, the main app's stale in-memory dict (which never
    /// saw the extension's write) would clobber disk on `persist()` and exclude
    /// the limit token from `recomputeAndApply()` — the limit record would be
    /// GONE. This test FAILS pre-fix and PASSES post-fix.
    func test_routine_mutation_preserves_extension_written_limit_shield() async throws {
        // Construct the store first (loads an empty disk dict at init), then
        // simulate the extension writing the limit record AFTER init — exactly
        // the stale-in-memory scenario.
        let store = ActiveLockStore()

        let limitRecord = Self.makeLimitShield(bundleID: "com.roblox.robloxmobile",
                                                displayName: "Roblox")
        try Self.writeDiskShields([limitRecord.recordKey: limitRecord], suiteName: suiteName)

        // Routine main-app mutation: add an unrelated manual shield.
        let manual = Self.makeManualTimedShield(displayName: "Instagram", minutes: 30,
                                                 targetKey: "com.burbn.instagram")
        _ = await store.addShield(manual)

        let shields = await store.allCurrent().shields
        XCTAssertTrue(
            shields.contains(where: { $0.recordKey == limitRecord.recordKey && $0.sources.contains(.limit) }),
            "Extension-written .limit shield was clobbered by routine main-app mutation. Present keys: \(shields.map(\.recordKey))"
        )
        // And the manual shield is there too.
        XCTAssertTrue(shields.contains(where: { $0.recordKey == manual.recordKey }))
    }

    /// Same regression via `sweepExpired` (runs every poll cycle once any timed
    /// shield/block expires) — the most frequent clobber trigger.
    func test_sweepExpired_preserves_extension_written_limit_shield() async throws {
        let store = ActiveLockStore()

        let limitRecord = Self.makeLimitShield(bundleID: "com.roblox.robloxmobile",
                                                displayName: "Roblox")
        try Self.writeDiskShields([limitRecord.recordKey: limitRecord], suiteName: suiteName)

        _ = await store.sweepExpired()

        let shields = await store.allCurrent().shields
        XCTAssertTrue(
            shields.contains(where: { $0.recordKey == limitRecord.recordKey && $0.sources.contains(.limit) }),
            "sweepExpired clobbered the extension-written .limit shield. Present keys: \(shields.map(\.recordKey))"
        )
    }

    // MARK: - Daily-reset direction (extension cleared the limit shield)

    /// Seed a `.limit` record (via the store, so it lands in memory + disk),
    /// then simulate the extension's daily reset by removing it from the on-disk
    /// dict. A routine mutation must DROP the stale in-memory `.limit` record.
    func test_mutation_drops_limit_shield_cleared_by_extension_reset() async throws {
        let store = ActiveLockStore()

        // Land a .limit record in-memory + on disk through the normal path.
        let limitRecord = Self.makeLimitShield(bundleID: "com.roblox.robloxmobile",
                                                displayName: "Roblox")
        _ = await store.addShield(limitRecord)
        var present = await store.allCurrent().shields
        XCTAssertTrue(present.contains(where: { $0.recordKey == limitRecord.recordKey }),
                      "precondition: limit record should be present")

        // Simulate the extension's daily reset: disk no longer contains it.
        try Self.writeDiskShields([:], suiteName: suiteName)

        // Routine mutation triggers reconcile.
        _ = await store.sweepExpired()

        present = await store.allCurrent().shields
        XCTAssertFalse(
            present.contains(where: { $0.recordKey == limitRecord.recordKey }),
            "Stale in-memory .limit record was not dropped after the extension cleared it on disk."
        )
    }

    // MARK: - clear_limit still removes (no resurrection)

    /// With a `.limit` record on disk AND in-memory, `removeLimitShields` must
    /// remove it and the reconcile inside the subsequent recompute must NOT
    /// resurrect it (because persist writes the removal to disk first).
    func test_removeLimitShields_removes_and_does_not_resurrect() async throws {
        let store = ActiveLockStore()

        let bundleID = "com.roblox.robloxmobile"
        let limitRecord = Self.makeLimitShield(bundleID: bundleID, displayName: "Roblox")
        _ = await store.addShield(limitRecord)

        // Confirm it is on disk (the store persisted it).
        let onDisk = try Self.readDiskShields(suiteName: suiteName)
        XCTAssertTrue(onDisk?[limitRecord.recordKey] != nil, "precondition: limit record on disk")

        let removed = await store.removeLimitShields(appTokens: [], bundleID: bundleID)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.recordKey, limitRecord.recordKey)

        let after = await store.allCurrent().shields
        XCTAssertFalse(
            after.contains(where: { $0.recordKey == limitRecord.recordKey }),
            "removeLimitShields target was resurrected by reconcile."
        )

        // Disk should also no longer contain it.
        let diskAfter = try Self.readDiskShields(suiteName: suiteName)
        XCTAssertNil(diskAfter?[limitRecord.recordKey], "removed limit record still on disk.")
    }

    // MARK: - Manual shields unaffected by reconcile

    /// A manual `addShield` then `removeShield` behaves exactly as before; the
    /// reconcile only governs `.limit` records and must leave `.manual`
    /// authoritative in memory.
    func test_manual_shield_add_and_remove_unaffected_by_reconcile() async throws {
        let store = ActiveLockStore()

        let manual = Self.makeManualTimedShield(displayName: "Instagram", minutes: 30,
                                                 targetKey: "com.burbn.instagram")
        _ = await store.addShield(manual)
        var shields = await store.allCurrent().shields
        XCTAssertEqual(shields.count, 1)
        XCTAssertEqual(shields.first?.sources, [.manual])

        let removed = await store.removeShield(recordKey: manual.recordKey)
        XCTAssertNotNil(removed)
        shields = await store.allCurrent().shields
        XCTAssertEqual(shields.count, 0)
    }

    /// A manual shield in memory must NOT be dropped just because disk doesn't
    /// list it as a `.limit` record (reconcile must never touch `.manual`).
    func test_manual_shield_survives_when_disk_has_unrelated_limit_record() async throws {
        let store = ActiveLockStore()

        let manual = Self.makeManualTimedShield(displayName: "Instagram", minutes: 30,
                                                 targetKey: "com.burbn.instagram")
        _ = await store.addShield(manual)

        // Extension writes a DIFFERENT limit record to disk (without the manual).
        let limitRecord = Self.makeLimitShield(bundleID: "com.roblox.robloxmobile",
                                                displayName: "Roblox")
        try Self.writeDiskShields([limitRecord.recordKey: limitRecord], suiteName: suiteName)

        _ = await store.sweepExpired()

        let shields = await store.allCurrent().shields
        XCTAssertTrue(shields.contains(where: { $0.recordKey == manual.recordKey }),
                      "manual shield was incorrectly dropped by reconcile")
        XCTAssertTrue(shields.contains(where: { $0.recordKey == limitRecord.recordKey }),
                      "extension limit shield missing after reconcile")
    }

    // MARK: - Fail-safe (undecodable disk = no-op, no wipe)

    /// If the on-disk dict is garbage/undecodable, `diskShieldRecords()` returns
    /// nil and reconcile is a no-op — in-memory shields (manual AND limit) must
    /// be preserved, NOT wiped.
    func test_garbage_disk_is_noop_and_preserves_in_memory_shields() async throws {
        let store = ActiveLockStore()

        // Land both a manual and a limit record in memory + on disk.
        let manual = Self.makeManualTimedShield(displayName: "Instagram", minutes: 30,
                                                 targetKey: "com.burbn.instagram")
        let limitRecord = Self.makeLimitShield(bundleID: "com.roblox.robloxmobile",
                                                displayName: "Roblox")
        _ = await store.addShield(manual)
        _ = await store.addShield(limitRecord)

        // Corrupt the on-disk dict (undecodable bytes).
        UserDefaults(suiteName: suiteName)?.set(Data([0x00, 0x01, 0x02, 0xFF]), forKey: shieldsKey)

        // Mutation triggers reconcile, which must bail (disk == nil).
        _ = await store.sweepExpired()

        let shields = await store.allCurrent().shields
        XCTAssertTrue(shields.contains(where: { $0.recordKey == manual.recordKey }),
                      "garbage disk wiped the manual shield (fail-safe violated)")
        XCTAssertTrue(shields.contains(where: { $0.recordKey == limitRecord.recordKey }),
                      "garbage disk wiped the limit shield (fail-safe violated)")
    }

    // MARK: - Helpers

    /// Build a `source == .limit` ShieldRecord shaped exactly like the extension
    /// writes (mirrors `LimitShieldLogic.applyingLimit`): `.exactApp` tier,
    /// `targetKey` = lowercased bundleID, permanent (cleared by daily reset, not
    /// timed expiry).
    private static func makeLimitShield(bundleID: String, displayName: String) -> ShieldRecord {
        let targetKey = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: targetKey),
            tier: .exactApp,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "app limit reached: \(displayName)",
            targetChildID: UUID(),
            sources: [.limit]
        )
    }

    private static func makeManualTimedShield(
        displayName: String,
        minutes: Int,
        targetKey: String
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: targetKey),
            tier: .exactApp,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            originalRequest: "test",
            targetChildID: UUID(),
            sources: [.manual]
        )
    }

    /// Write the App Group shields dict EXACTLY as the extension does:
    /// `.iso8601` JSON for `[String: ShieldRecord]` at `evlin.shieldRecords`.
    private static func writeDiskShields(_ shields: [String: ShieldRecord], suiteName: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(shields)
        UserDefaults(suiteName: suiteName)?.set(data, forKey: "evlin.shieldRecords")
    }

    private static func readDiskShields(suiteName: String) throws -> [String: ShieldRecord]? {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: "evlin.shieldRecords") else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: ShieldRecord].self, from: data)
    }
}
