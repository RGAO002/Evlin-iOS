import Foundation
import XCTest
@testable import Evlin_iOS

/// The client half of the per-app recovery leg (2026-08-11).
///
/// A re-login's identity teardown empties the local rule store, and set_limit
/// commands are delivered exactly once — so without this leg the device could
/// never re-learn its rules. These pin the hydration contract against the
/// exact wire shapes the backend snapshot endpoint emits.
final class AppLimitSnapshotRecoveryTests: XCTestCase {
    private var directoryURL: URL!
    private var fileURL: URL!
    private let owner = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let ruleID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private let deviceID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-limit-snapshot-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("app-limit-epoch.json")
    }

    override func tearDownWithError() throws {
        if let directoryURL { try? FileManager.default.removeItem(at: directoryURL) }
        try super.tearDownWithError()
    }

    private func makeStore() -> AppLimitEpochStore {
        let owner = self.owner
        return AppLimitEpochStore(
            fileURL: fileURL,
            lock: SnapshotTestLock(),
            ownerProvider: { owner },
            legacyDefaults: nil
        )
    }

    private func makeCoordinator(store: AppLimitEpochStore) -> AppLimitCommandCoordinator {
        let owner = self.owner
        return AppLimitCommandCoordinator(store: store, expectedOwnerProvider: { owner })
    }

    /// The exact wire shape GET /child/app-limits/snapshot returns for one
    /// active WhatsApp rule (mirrors the backend's canonical builder output).
    private func snapshotJSON(items: [[String: Any]]) throws -> (AppLimitSnapshotDTO, Data) {
        let root: [String: Any] = [
            "child_device_id": deviceID.uuidString,
            "child_profile_id": UUID().uuidString,
            "server_revision": "2026-08-11T21:09:00+00:00",
            "rules_digest": String(repeating: "a", count: 64),
            "items": items,
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return (try JSONDecoder().decode(AppLimitSnapshotDTO.self, from: data), data)
    }

    private func setItem(orderingToken: Int) -> [String: Any] {
        [
            "kind": "set",
            "rule_id": ruleID.uuidString,
            "ordering_token": orderingToken,
            "status": "active",
            "payload": [
                "action": "set_limit",
                "tier": "exactApp",
                "duration_minutes": NSNull(),
                "issued_at": "2026-08-11T21:09:00+00:00",
                "target": [
                    "target_type": "app",
                    "bundle_id": "net.whatsapp.WhatsApp",
                    "target_display": "WhatsApp",
                    "catalog_token_data_base64": Data("APP_TOKEN".utf8).base64EncodedString(),
                ],
                "limit": [
                    "rule_id": ruleID.uuidString,
                    "ordering_token": orderingToken,
                    "daily_budget_minutes": 20,
                    "used_today_minutes": 0,
                    "reset_policy": "daily",
                    "schedule": [
                        "starts_at": "00:00", "ends_at": "23:59",
                        "timezone": "America/New_York",
                    ],
                    "effective_from": "2026-08-08T09:08:09+00:00",
                    "expires_at": NSNull(),
                    "updated_at": "2026-08-11T21:09:00+00:00",
                ],
            ],
        ]
    }

    private func clearItem(orderingToken: Int) -> [String: Any] {
        [
            "kind": "clear",
            "rule_id": ruleID.uuidString,
            "ordering_token": orderingToken,
            "status": "disabled",
            "updated_at": "2026-08-11T21:09:00+00:00",
            "clear": [
                "rule_id": ruleID.uuidString,
                "ordering_token": orderingToken,
                "reason": "rule_disabled",
                "updated_at": "2026-08-11T21:09:00+00:00",
            ],
        ]
    }


    /// A real ApplicationToken cannot be fabricated in tests (opaque Codable);
    /// this mirrors AppLimitProductionComposition.envelope with empty
    /// appTokens, the same convention every other app-limit test uses. The
    /// digest keys on (kind, token) so idempotence and ordering behave.
    private func testEnvelope(from command: LockCommand) throws -> AppLimitCommandEnvelope {
        if let limit = command.limit {
            return AppLimitCommandEnvelope(
                commandID: command.id,
                ruleID: limit.ruleId,
                orderingToken: limit.orderingToken,
                kind: .set,
                payloadDigest: "set-\(limit.orderingToken)",
                receivedAt: command.issuedAt,
                source: .wakeRecovery,
                rule: AppLimitRule(
                    id: limit.ruleId,
                    appTokens: [],
                    bundleID: command.target.bundleID ?? "",
                    displayName: command.target.targetDisplay ?? "App",
                    budgetMinutes: limit.dailyBudgetMinutes,
                    window: AppLimitWindow(
                        startMinute: limit.startMinute,
                        endMinute: limit.endMinute,
                        repeats: true,
                        timezone: limit.timezone
                    ),
                    effectiveFrom: limit.effectiveFrom,
                    expiresAt: limit.expiresAt
                ),
                confirmationMode: .localSnapshot
            )
        }
        let clear = command.clear!
        return AppLimitCommandEnvelope(
            commandID: command.id,
            ruleID: clear.ruleId,
            orderingToken: clear.orderingToken,
            kind: .clear,
            payloadDigest: "clear-\(clear.orderingToken)",
            receivedAt: command.issuedAt,
            source: .wakeRecovery,
            rule: nil,
            confirmationMode: .localSnapshot
        )
    }

    private func runRecovery(
        fetch: @escaping () async throws -> (AppLimitSnapshotDTO, Data),
        deviceID: UUID? = nil,
        coordinator: AppLimitCommandCoordinator
    ) async -> AppLimitSnapshotRecovery.Outcome {
        await AppLimitSnapshotRecovery.run(
            fetch: fetch,
            deviceID: deviceID ?? self.deviceID,
            coordinator: coordinator,
            makeEnvelope: { try self.testEnvelope(from: $0) }
        )
    }

    // ── The Enerel/WhatsApp scenario: empty store re-learns its rule ──

    func test_setItemHydratesAnEmptyStoreAsLocalSnapshotWork() async throws {
        let store = makeStore()
        let snapshot = try snapshotJSON(items: [setItem(orderingToken: 5)])

        let outcome = await runRecovery(
            fetch: { snapshot }, coordinator: makeCoordinator(store: store)
        )

        XCTAssertEqual(outcome, .hydrated(ingested: 1, tombstones: 0, unknown: 0))
        let slot = try XCTUnwrap(try store.read().slots[ruleID])
        XCTAssertEqual(slot.latestKind, .set)
        XCTAssertEqual(slot.latestOrderingToken, 5)
        XCTAssertEqual(slot.activeRule?.budgetMinutes, 20)
        let work = try XCTUnwrap(slot.pendingOwnerWork)
        XCTAssertEqual(
            work.confirmationMode, .localSnapshot,
            "snapshot work carries a synthetic command id — confirming it via "
                + "/child/ack would 404 forever, so it must be marked for "
                + "local completion"
        )
    }

    func test_hydrationIsIdempotent_sameSnapshotTwiceDoesNotStack() async throws {
        let store = makeStore()
        let snapshot = try snapshotJSON(items: [setItem(orderingToken: 5)])
        let coordinator = makeCoordinator(store: store)

        _ = await runRecovery(fetch: { snapshot }, coordinator: coordinator)
        let firstWork = try XCTUnwrap(try store.read().slots[ruleID]?.pendingOwnerWork)
        _ = await runRecovery(fetch: { snapshot }, coordinator: coordinator)
        let secondWork = try XCTUnwrap(try store.read().slots[ruleID]?.pendingOwnerWork)

        XCTAssertEqual(
            firstWork, secondWork,
            "deterministic synthetic ids must dedupe a retried snapshot, not "
                + "stack a second pending work"
        )
    }

    func test_newerLocalStateWinsOverAStaleSnapshot() async throws {
        // The device already holds ordering token 7 (a live command that
        // arrived after the snapshot was cut). Token 5 from the snapshot must
        // be rejected exactly like a replayed old command.
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        let newer = try snapshotJSON(items: [setItem(orderingToken: 7)])
        _ = await runRecovery(fetch: { newer }, coordinator: coordinator)

        let stale = try snapshotJSON(items: [setItem(orderingToken: 5)])
        _ = await runRecovery(fetch: { stale }, coordinator: coordinator)

        let slot = try XCTUnwrap(try store.read().slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, 7)
    }

    func test_clearTombstoneHealsALostClearLimit() async throws {
        // Rule installed at token 5; the parent's delete (token 6 clear) was
        // lost in flight. The snapshot's tombstone must retire it.
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        _ = await runRecovery(
            fetch: { try self.snapshotJSON(items: [self.setItem(orderingToken: 5)]) },
            coordinator: coordinator
        )

        let outcome = await runRecovery(
            fetch: { try self.snapshotJSON(items: [self.clearItem(orderingToken: 6)]) },
            coordinator: coordinator
        )

        XCTAssertEqual(outcome, .hydrated(ingested: 0, tombstones: 1, unknown: 0))
        let slot = try XCTUnwrap(try store.read().slots[ruleID])
        XCTAssertEqual(slot.latestKind, .clear)
        XCTAssertNil(slot.activeRule)
    }

    func test_unknownItemTouchesNothing() async throws {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        _ = await runRecovery(
            fetch: { try self.snapshotJSON(items: [self.setItem(orderingToken: 5)]) },
            coordinator: coordinator
        )

        // Token became unavailable server-side: the entry degrades to
        // "unknown". Treating it as "no rule" would CLEAR a real limit —
        // the most dangerous misread. Nothing may change.
        let unknown: [[String: Any]] = [[
            "kind": "unknown",
            "rule_id": ruleID.uuidString,
            "ordering_token": 6,
            "status": "active",
            "unavailable_reason": "token_unavailable",
        ]]
        let outcome = await runRecovery(
            fetch: { try self.snapshotJSON(items: unknown) },
            coordinator: coordinator
        )

        XCTAssertEqual(outcome, .hydrated(ingested: 0, tombstones: 0, unknown: 1))
        let slot = try XCTUnwrap(try store.read().slots[ruleID])
        XCTAssertEqual(slot.latestKind, .set)
        XCTAssertEqual(slot.latestOrderingToken, 5)
    }

    func test_fetchFailureLeavesEverydSlotAloneAndIsNotNoRules() async throws {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        _ = await runRecovery(
            fetch: { try self.snapshotJSON(items: [self.setItem(orderingToken: 5)]) },
            coordinator: coordinator
        )

        struct Boom: Error {}
        let outcome = await runRecovery(
            fetch: { throw Boom() },
            coordinator: coordinator
        )

        XCTAssertEqual(outcome, .fetchFailed)
        XCTAssertNotNil(try store.read().slots[ruleID]?.activeRule)
    }

    func test_scopeMismatchIsRefused() async throws {
        let store = makeStore()
        var wrongDevice = try snapshotJSON(items: [setItem(orderingToken: 5)])
        let outcome = await runRecovery(
            fetch: { wrongDevice },
            deviceID: UUID(),  // caller expects a DIFFERENT device
            coordinator: makeCoordinator(store: store)
        )
        XCTAssertEqual(outcome, .malformed)
        XCTAssertNil(try store.read().slots[ruleID])
        _ = wrongDevice  // silence mutation warning
    }

    func test_syntheticCommandIDsAreDeterministicAndKindScoped() {
        let a = AppLimitSnapshotRecovery.syntheticCommandID(
            ruleID: ruleID, orderingToken: 5, kind: "set"
        )
        let b = AppLimitSnapshotRecovery.syntheticCommandID(
            ruleID: ruleID, orderingToken: 5, kind: "set"
        )
        let c = AppLimitSnapshotRecovery.syntheticCommandID(
            ruleID: ruleID, orderingToken: 5, kind: "clear"
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

private final class SnapshotTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
