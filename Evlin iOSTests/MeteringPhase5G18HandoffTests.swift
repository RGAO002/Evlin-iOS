import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringPhase5G18HandoffTests: XCTestCase {
    private let ownerID = UUID(uuidString: "20000000-0000-0000-0000-000000000501")!
    private let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000501")!
    private let referenceDate = Date(timeIntervalSince1970: 1_753_027_200)

    func testPushWireReorderingConvergesWithoutExecutingOwnerEffects() throws {
        let harness = makeHarness()
        let sequence: [(AppLimitCommandKind, Int64)] = [
            (.set, 2), (.set, 1), (.clear, 3), (.set, 2), (.clear, 3),
        ]
        var acks: [AppLimitNSEAck] = []
        var revisions: [UInt64] = []

        for (kind, token) in sequence {
            let command = try NSECommandWireDecoder.decode(wire(kind: kind, token: token))
            let envelope = try envelope(from: command, kind: kind)
            let outcome = try AppLimitProductionComposition.persistNSE(
                envelope: envelope,
                coordinator: harness.coordinator,
                now: referenceDate
            )
            acks.append(outcome.ack)
            revisions.append(try harness.store.read().storeRevision)
        }

        XCTAssertEqual(revisions, [1, 1, 2, 2, 2])
        XCTAssertEqual(acks.map(\.status), ["pending", "confirmed", "pending", "confirmed", "pending"])
        XCTAssertEqual(
            acks.map(\.disposition),
            [
                "accepted_needs_owner", "superseded", "accepted_needs_owner",
                "superseded", "duplicate_pending",
            ]
        )
        XCTAssertEqual(acks[0].reason, "persisted_waiting_for_owner")
        XCTAssertEqual(acks[4].reason, "persisted_waiting_for_owner")

        let state = try harness.store.read()
        let slot = try XCTUnwrap(state.slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, 3)
        XCTAssertEqual(slot.latestKind, .clear)
        XCTAssertNil(slot.activeRule)
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 3)
        XCTAssertEqual(slot.pendingOwnerWork?.orderingToken, 3)
        XCTAssertNil(slot.appliedReceipt)
        XCTAssertNil(slot.armProvenance)
    }

    func testEqualAppliedReplaysReceiptAndEqualConflictDoesNotMutate() throws {
        let harness = makeHarness()
        let command = try NSECommandWireDecoder.decode(wire(kind: .clear, token: 3))
        let initialEnvelope = try envelope(from: command, kind: .clear)
        _ = try harness.coordinator.ingest(initialEnvelope)
        let receipt = AppLimitApplyReceipt(
            ruleID: ruleID,
            orderingToken: 3,
            commandKind: .clear,
            armID: nil,
            source: "main_app",
            appliedAt: referenceDate,
            storeRevision: 2
        )
        _ = try harness.store.transaction(source: .wakeRecovery, expectedOwner: ownerID) { state in
            var slot = try XCTUnwrap(state.slots[ruleID])
            slot.pendingOwnerWork = nil
            slot.appliedReceipt = receipt
            state.slots[ruleID] = slot
        }

        let appliedBytes = try Data(contentsOf: harness.fileURL)
        let duplicate = try AppLimitProductionComposition.persistNSE(
            envelope: initialEnvelope,
            coordinator: harness.coordinator,
            now: referenceDate
        )
        XCTAssertEqual(duplicate.ack.status, "confirmed")
        XCTAssertEqual(duplicate.ack.disposition, "duplicate_applied")
        XCTAssertEqual(duplicate.ack.receiptRevision, 2)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), appliedBytes)

        let conflict = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: 3,
            kind: .clear,
            payloadDigest: "different-payload",
            receivedAt: referenceDate,
            source: .notificationServiceExtension,
            rule: nil
        )
        let rejected = try AppLimitProductionComposition.persistNSE(
            envelope: conflict,
            coordinator: harness.coordinator,
            now: referenceDate
        )
        XCTAssertEqual(rejected.ack.status, "failed")
        XCTAssertEqual(rejected.ack.disposition, "equal_token_conflict")
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), appliedBytes)
    }

    func testOwnerSwapAndLockFailurePreservePriorBytesAndNeverConfirm() async throws {
        let harness = makeHarness()
        let command = try NSECommandWireDecoder.decode(wire(kind: .set, token: 2))
        let initialEnvelope = try envelope(from: command, kind: .set)
        _ = try harness.coordinator.ingest(initialEnvelope)
        let prior = try Data(contentsOf: harness.fileURL)

        let wrongOwner = AppLimitCommandCoordinator(
            store: harness.store,
            expectedOwnerProvider: {
                UUID(uuidString: "20000000-0000-0000-0000-000000000599")!
            }
        )
        var ownerAcks: [AppLimitNSEAck] = []
        let ownerResult = await AppLimitProductionComposition.deliverNSE(
            envelope: try envelope(
                from: NSECommandWireDecoder.decode(wire(kind: .clear, token: 3)),
                kind: .clear
            ),
            coordinator: wrongOwner,
            now: referenceDate,
            postAck: { ownerAcks.append($0) },
            requestOwnerWake: { XCTFail("owner mismatch must not request a wake") }
        )
        XCTAssertEqual(ownerResult?.ack.status, "failed")
        XCTAssertFalse(ownerAcks.contains { $0.status == "confirmed" })
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), prior)

        let lockedOutStore = AppLimitEpochStore(
            fileURL: harness.fileURL,
            lock: Phase5UnavailableLock(),
            ownerProvider: { self.ownerID },
            legacyDefaults: nil
        )
        let lockedOut = AppLimitCommandCoordinator(
            store: lockedOutStore,
            expectedOwnerProvider: { self.ownerID }
        )
        var lockAcks: [AppLimitNSEAck] = []
        let lockResult = await AppLimitProductionComposition.deliverNSE(
            envelope: try envelope(
                from: NSECommandWireDecoder.decode(wire(kind: .clear, token: 3)),
                kind: .clear
            ),
            coordinator: lockedOut,
            now: referenceDate,
            postAck: { lockAcks.append($0) },
            requestOwnerWake: { XCTFail("lock failure must not request a wake") }
        )
        XCTAssertEqual(lockResult?.ack.status, "failed")
        XCTAssertFalse(lockAcks.contains { $0.status == "confirmed" })
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), prior)
    }

    func testPushIngressHasNoMonitorShieldOrUsageMutationCapability() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ownedPaths = [
            "Evlin iOS/Models/NSECommandWireModels.swift",
            "Evlin iOS/Services/AppLimitProductionComposition.swift",
            "Evlin iOS/Services/AppLimitCommandCoordinator.swift",
            "EvlinPushApplier/NotificationService.swift",
        ]
        for relative in ownedPaths {
            let source = try String(contentsOf: root.appendingPathComponent(relative))
            for forbidden in [
                "startMonitoring(", "stopMonitoring(", "ManagedSettingsStore(",
                "recordAppLimitUsage(", "applyLimitShield(",
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(relative) owns \(forbidden)")
            }
        }
    }

    private func makeHarness() -> Phase5HandoffHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase5-g18-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("epoch.json")
        let store = AppLimitEpochStore(
            fileURL: fileURL,
            lock: Phase5TestLock(),
            ownerProvider: { self.ownerID },
            legacyDefaults: nil
        )
        return Phase5HandoffHarness(
            fileURL: fileURL,
            store: store,
            coordinator: AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { self.ownerID }
            )
        )
    }

    private func envelope(
        from command: LockCommand,
        kind: AppLimitCommandKind
    ) throws -> AppLimitCommandEnvelope {
        switch kind {
        case .set:
            let limit = try XCTUnwrap(command.limit)
            return AppLimitCommandEnvelope(
                commandID: command.id,
                ruleID: limit.ruleId,
                orderingToken: limit.orderingToken,
                kind: .set,
                payloadDigest: "set-\(limit.orderingToken)",
                receivedAt: command.issuedAt,
                source: .notificationServiceExtension,
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
                )
            )
        case .clear:
            let clear = try XCTUnwrap(command.clear)
            return AppLimitCommandEnvelope(
                commandID: command.id,
                ruleID: clear.ruleId,
                orderingToken: clear.orderingToken,
                kind: .clear,
                payloadDigest: "clear-\(clear.orderingToken)",
                receivedAt: command.issuedAt,
                source: .notificationServiceExtension,
                rule: nil
            )
        }
    }

    private func wire(kind: AppLimitCommandKind, token: Int64) -> Data {
        let payload: String
        switch kind {
        case .set:
            payload = """
            "limit": {
              "rule_id": "\(ruleID.uuidString)",
              "ordering_token": \(token),
              "daily_budget_minutes": 30,
              "reset_policy": "daily",
              "schedule": {"starts_at": "00:00", "ends_at": "23:59", "timezone": "UTC"},
              "effective_from": "2026-07-20T00:00:00Z",
              "expires_at": null,
              "updated_at": "2026-07-20T00:00:00Z"
            }
            """
        case .clear:
            payload = """
            "clear": {
              "rule_id": "\(ruleID.uuidString)",
              "ordering_token": \(token),
              "reason": "parent_clear",
              "updated_at": "2026-07-20T00:00:00Z"
            }
            """
        }
        return Data("""
        {
          "command_id": "\(UUID().uuidString)",
          "action": "\(kind == .set ? "set_limit" : "clear_limit")",
          "tier": "exactApp",
          "target": {
            "bundle_id": "com.example.focus",
            "target_display": "Focus",
            "target_child_id": "\(ownerID.uuidString)",
            "original_request": ""
          },
          "duration_minutes": null,
          "issued_at": "2026-07-20T00:00:00Z",
          \(payload)
        }
        """.utf8)
    }
}

private struct Phase5HandoffHarness {
    let fileURL: URL
    let store: AppLimitEpochStore
    let coordinator: AppLimitCommandCoordinator
}

private final class Phase5TestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private struct Phase5UnavailableLock: DeviceEpochStoreLocking {
    func withLock<T>(_ body: () -> T) -> T? { nil }
}
