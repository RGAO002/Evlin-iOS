import XCTest
@testable import Evlin_iOS

/// B6: recordKey unification — when the backend `ChildCatalogList.id` is first
/// learned, any persisted `savedList:<localUUID>` record is re-keyed to
/// `savedList:<backendID>` preserving all fields (sources, expiry, tokens).
///
/// Tests use a fresh (non-shared) `ActiveLockStore` and a fresh (non-shared)
/// `EarnedTimeStore` backed by the same App Group suite so the interaction
/// between `saveLockedSetID` and `reKeyShieldRecord` can be exercised without
/// mutating global singletons.
///
/// `DefaultLockGroup.shared` IS the global singleton; tests that exercise its
/// `id` property read from / write to the real App Group defaults. Those tests
/// clean up in `tearDown`.
final class RecordKeyMigrationTests: XCTestCase {

    private let suite = "group.com.evlin.ios"
    private let shieldsKey = "evlin.shieldRecords"
    private let defaultGroupIDKey = "evlin.defaultGroupID"
    private let lockedSetIDKey = "earned.lockedSetID"

    override func setUp() async throws {
        // Wipe relevant App Group keys so each test starts clean.
        let ud = UserDefaults(suiteName: suite)
        ud?.removeObject(forKey: shieldsKey)
        ud?.removeObject(forKey: "evlin.blockRecords")
        ud?.removeObject(forKey: defaultGroupIDKey)
        ud?.removeObject(forKey: lockedSetIDKey)
        ud?.synchronize()
        EarnedTimeStore.shared.removeAll()
    }

    override func tearDown() async throws {
        let ud = UserDefaults(suiteName: suite)
        ud?.removeObject(forKey: shieldsKey)
        ud?.removeObject(forKey: "evlin.blockRecords")
        ud?.removeObject(forKey: defaultGroupIDKey)
        ud?.removeObject(forKey: lockedSetIDKey)
        ud?.synchronize()
        EarnedTimeStore.shared.removeAll()
    }

    // MARK: - Helpers

    /// Write a `savedList:<localID>` ShieldRecord directly to App Group disk
    /// (bypassing ActiveLockStore init) so the next `ActiveLockStore()` restores it.
    private func persistShieldRecord(
        localID: String,
        sources: Set<ShieldSource>,
        expiresAt: Date?,
        tokenSentinel: UUID = UUID()
    ) {
        let recordKey = "savedList:\(localID)"
        let record = ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: localID,
            displayName: "Locked set",
            lastCommandID: tokenSentinel,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSinceReferenceDate: 0),
            expiresAt: expiresAt,
            originalRequest: "default lock group",
            targetChildID: UUID(),
            sources: sources
        )
        let dict: [String: ShieldRecord] = [recordKey: record]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(dict) {
            UserDefaults(suiteName: suite)?.set(data, forKey: shieldsKey)
            UserDefaults(suiteName: suite)?.synchronize()
        }
    }

    // MARK: - Test 1: re-key on backend ID learned, preserves sources + expiry + token

    /// With a persisted record keyed by the local UUID and `{.manual, .earnedTime}`
    /// sources, learning the backend ID must re-key it ONCE to
    /// `savedList:<backendID>` and preserve the source set, expiry, and
    /// `lastCommandID` (our proxy for the opaque token blob).
    func test_reKey_onBackendIDLearned_preservesSourcesAndExpiry() async throws {
        let localID = UUID().uuidString
        let backendID = UUID().uuidString
        let expiry = Date(timeIntervalSinceNow: 3600)
        let sentinel = UUID()

        // Persist the local-id record to disk.
        persistShieldRecord(
            localID: localID,
            sources: [.manual, .earnedTime],
            expiresAt: expiry,
            tokenSentinel: sentinel
        )

        // Pin the local UUID into DefaultLockGroup so its `id` property returns
        // the local UUID BEFORE the backend id is set.
        UserDefaults(suiteName: suite)?.set(localID, forKey: defaultGroupIDKey)

        // Restore an ActiveLockStore from disk (reads the persisted record).
        let lockStore = ActiveLockStore()

        // Sanity: local-id record is present before migration. Wave-1 Task 5's
        // restore()-time sweep normalizes the persisted uppercase-UUID key to
        // lowercase on load, so the in-memory key is already lowercase here
        // even though `persistShieldRecord` wrote it uppercase to disk.
        let beforeShields = await lockStore.allCurrent().shields
        XCTAssertEqual(beforeShields.count, 1, "pre-condition: one shield present")
        XCTAssertEqual(beforeShields[0].recordKey, "savedList:\(localID.lowercased())")

        // Trigger the migration by calling reKeyShieldRecord directly.
        await lockStore.reKeyShieldRecord(fromLocalID: localID, toBackendID: backendID)

        // After migration: old key gone, new key present.
        let afterShields = await lockStore.allCurrent().shields
        XCTAssertEqual(afterShields.count, 1, "count must not change")
        let migrated = try XCTUnwrap(afterShields.first)

        // Wave-1 Task 5: `makeRecordKey`/`reKeyShieldRecord` normalize the
        // `.savedList` segment to lowercase.
        XCTAssertEqual(migrated.recordKey, "savedList:\(backendID.lowercased())", "recordKey must use backend id")
        XCTAssertEqual(migrated.targetKey, backendID, "targetKey must use backend id")
        XCTAssertEqual(migrated.sources, [.manual, .earnedTime], "sources must be preserved")
        XCTAssertEqual(migrated.expiresAt?.timeIntervalSinceReferenceDate ?? -1,
                       expiry.timeIntervalSinceReferenceDate,
                       accuracy: 1.0,
                       "expiry must be preserved")
        XCTAssertEqual(migrated.lastCommandID, sentinel, "tokens (lastCommandID) must be preserved")
    }

    // MARK: - Test 2: migration is idempotent (no-op on second call)

    /// Running the migration a second time with the same `backendID` must be a
    /// no-op — the count stays at 1 and the record is unchanged.
    func test_reKey_idempotent_secondCallIsNoOp() async throws {
        let localID = UUID().uuidString
        let backendID = UUID().uuidString

        persistShieldRecord(localID: localID, sources: [.manual, .earnedTime], expiresAt: nil)
        UserDefaults(suiteName: suite)?.set(localID, forKey: defaultGroupIDKey)

        let lockStore = ActiveLockStore()

        // First migration.
        await lockStore.reKeyShieldRecord(fromLocalID: localID, toBackendID: backendID)

        let afterFirst = await lockStore.allCurrent().shields
        XCTAssertEqual(afterFirst.count, 1)
        XCTAssertEqual(afterFirst[0].recordKey, "savedList:\(backendID.lowercased())")

        // Second migration — must be a no-op.
        await lockStore.reKeyShieldRecord(fromLocalID: localID, toBackendID: backendID)

        let afterSecond = await lockStore.allCurrent().shields
        XCTAssertEqual(afterSecond.count, 1, "count must stay 1 after second migration")
        XCTAssertEqual(afterSecond[0].recordKey, "savedList:\(backendID.lowercased())", "key must stay on backendID")
    }

    @MainActor
    func test_rollbackRekeyDoesNotOverwriteNewerDurableExtensionWrite() async throws {
        let localID = UUID().uuidString
        let backendID = UUID().uuidString
        persistShieldRecord(localID: localID, sources: [.manual], expiresAt: nil)
        let lockStore = ActiveLockStore()
        let possibleMutation = await lockStore.reKeyShieldRecord(
            fromLocalID: localID,
            toBackendID: backendID
        )
        let mutation = try XCTUnwrap(possibleMutation)
        let newer = ShieldRecord(
            recordKey: mutation.migrated.recordKey,
            tier: mutation.migrated.tier,
            targetKey: mutation.migrated.targetKey,
            displayName: mutation.migrated.displayName,
            lastCommandID: UUID(),
            appTokens: mutation.migrated.appTokens,
            categoryTokens: mutation.migrated.categoryTokens,
            webDomainTokens: mutation.migrated.webDomainTokens,
            appliesToAll: mutation.migrated.appliesToAll,
            issuedAt: mutation.migrated.issuedAt,
            expiresAt: mutation.migrated.expiresAt,
            originalRequest: mutation.migrated.originalRequest,
            targetChildID: mutation.migrated.targetChildID,
            sources: mutation.migrated.sources.union([.limit])
        )
        persistShieldDictionary([newer.recordKey: newer])

        await lockStore.rollbackRekey(mutation)

        let durable = await ActiveLockStore().allCurrent().shields
        XCTAssertEqual(durable, [newer])
    }

    // MARK: - Test 3: manual + remote resolve to the same savedList:<backendID>

    /// After the migration, `DefaultLockGroup.shared.recordKey` must return
    /// `savedList:<backendID>` (not the local UUID), so a manual green-button
    /// lock and a backend-commanded lock land on the same key.
    func test_defaultLockGroup_id_usesBackendID_afterLockedSetIDSaved() {
        let localID = UUID().uuidString
        let backendID = UUID().uuidString

        // Pre-pin the local UUID.
        UserDefaults(suiteName: suite)?.set(localID, forKey: defaultGroupIDKey)

        // Pre-sync: `DefaultLockGroup.shared.id` must return the local UUID.
        XCTAssertEqual(DefaultLockGroup.shared.id, localID, "pre-sync: id must be local UUID")

        // Learn the backend id.
        EarnedTimeStore.shared.saveLockedSetID(backendID, tokenData: nil)

        // Post-sync: `DefaultLockGroup.shared.id` must return the backend id.
        XCTAssertEqual(DefaultLockGroup.shared.id, backendID, "post-sync: id must be backend id")
        XCTAssertEqual(DefaultLockGroup.shared.recordKey, "savedList:\(backendID.lowercased())")
    }

    private func persistShieldDictionary(_ records: [String: ShieldRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(records)
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(data, forKey: shieldsKey)
        defaults?.synchronize()
    }

    // MARK: - Test 4: pre-sync fallback uses local UUID

    /// When no backend id has been synced yet, `DefaultLockGroup.shared.id` must
    /// return a stable local UUID (the pre-B6 behavior — no regression).
    func test_defaultLockGroup_id_fallsBackToLocalUUID_whenNoBackendID() {
        // Ensure no backend id is set.
        UserDefaults(suiteName: suite)?.removeObject(forKey: lockedSetIDKey)

        let id1 = DefaultLockGroup.shared.id
        let id2 = DefaultLockGroup.shared.id

        XCTAssertFalse(id1.isEmpty, "pre-sync id must be non-empty")
        XCTAssertEqual(id1, id2, "pre-sync id must be stable across calls")
        XCTAssertEqual(DefaultLockGroup.shared.recordKey, "savedList:\(id1.lowercased())")
    }
}
