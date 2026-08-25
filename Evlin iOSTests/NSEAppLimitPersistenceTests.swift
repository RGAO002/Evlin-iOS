import XCTest
@testable import Evlin_iOS

final class NSEAppLimitPersistenceTests: XCTestCase {
    func testAcceptedSetPersistsOwnerWorkAcksPendingAndRequestsWake() async throws {
        let harness = makeHarness()
        let envelope = setEnvelope(token: 10, source: .notificationServiceExtension)
        var acks: [AppLimitNSEAck] = []
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: envelope,
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { acks.append($0) },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "pending")
        XCTAssertEqual(delivery?.ack.disposition, "accepted_needs_owner")
        XCTAssertEqual(delivery?.ack.reason, "persisted_waiting_for_owner")
        XCTAssertEqual(delivery?.alertBody, "Updating limit")
        XCTAssertEqual(acks, [delivery?.ack].compactMap { $0 })
        XCTAssertEqual(wakes, 1)
        let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
        XCTAssertEqual(slot.activeRule?.id, ruleID)
        XCTAssertEqual(slot.pendingOwnerWork?.orderingToken, 10)
        XCTAssertNil(slot.appliedReceipt)
    }

    func testAcceptedClearPersistsTombstoneWithoutEnforcement() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10, source: .poll))
        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: clearEnvelope(token: 11, source: .notificationServiceExtension),
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in },
            requestOwnerWake: {}
        )

        XCTAssertEqual(delivery?.ack.status, "pending")
        let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
        XCTAssertNil(slot.activeRule)
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 11)
        XCTAssertEqual(slot.pendingOwnerWork?.commandKind, .clear)
    }

    func testSupersededCommandConfirmsAuthorityWithoutWakeOrMutation() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(clearEnvelope(token: 12, source: .poll))
        let before = try Data(contentsOf: harness.fileURL)
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: setEnvelope(token: 11, source: .notificationServiceExtension),
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "confirmed")
        XCTAssertEqual(delivery?.ack.disposition, "superseded")
        XCTAssertEqual(delivery?.ack.latestOrderingToken, 12)
        XCTAssertEqual(wakes, 0)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), before)
    }

    func testEqualPendingAcksPendingWithoutDuplicatingWork() async throws {
        let harness = makeHarness()
        let envelope = setEnvelope(token: 10, source: .notificationServiceExtension)
        _ = try harness.coordinator.ingest(envelope)
        let before = try Data(contentsOf: harness.fileURL)
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: envelope,
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "pending")
        XCTAssertEqual(delivery?.ack.disposition, "duplicate_pending")
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), before)
        XCTAssertEqual(try harness.store.read().slots.values.compactMap(\.pendingOwnerWork).count, 1)
    }

    func testEqualAppliedReusesReceiptAndDoesNotWakeOwner() async throws {
        let harness = makeHarness()
        let envelope = setEnvelope(token: 10, source: .notificationServiceExtension)
        _ = try harness.coordinator.ingest(envelope)
        let receipt = AppLimitApplyReceipt(
            ruleID: ruleID,
            orderingToken: 10,
            commandKind: .set,
            armID: UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010"),
            source: "app_owner",
            appliedAt: referenceDate,
            storeRevision: 2
        )
        _ = try harness.store.transaction(source: .wakeRecovery, expectedOwner: ownerID) { state in
            var slot = try XCTUnwrap(state.slots[ruleID])
            slot.pendingOwnerWork = nil
            slot.appliedReceipt = receipt
            state.slots[ruleID] = slot
        }
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: envelope,
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "confirmed")
        XCTAssertEqual(delivery?.ack.disposition, "duplicate_applied")
        XCTAssertEqual(delivery?.ack.receiptRevision, receipt.storeRevision)
        XCTAssertEqual(wakes, 0)
    }

    func testEqualTokenConflictFailsClosedWithoutWakeOrMutation() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 10, digest: "first", source: .poll))
        let before = try Data(contentsOf: harness.fileURL)
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: setEnvelope(token: 10, digest: "conflict", source: .notificationServiceExtension),
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "failed")
        XCTAssertEqual(delivery?.ack.disposition, "equal_token_conflict")
        XCTAssertEqual(wakes, 0)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), before)
    }

    func testFetchFailureDoesNothing() async {
        let harness = makeHarness()
        var acks = 0
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: nil,
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in acks += 1 },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertNil(delivery)
        XCTAssertEqual(acks, 0)
        XCTAssertEqual(wakes, 0)
        XCTAssertTrue((try? harness.store.read().slots.isEmpty) == true)
    }

    func testAckFailureLeavesDurableOwnerWorkAndStillRequestsWake() async throws {
        let harness = makeHarness()
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: setEnvelope(token: 10, source: .notificationServiceExtension),
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in throw TestError.ackFailed },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ackSucceeded, false)
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(try harness.store.read().slots[ruleID]?.pendingOwnerWork?.orderingToken, 10)
    }

    func testOwnerMismatchKeepsFailedOutcomeLocalWithoutAckWakeOrMutation() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(setEnvelope(token: 9, source: .poll))
        let before = try Data(contentsOf: harness.fileURL)
        let mismatched = AppLimitCommandCoordinator(
            store: harness.store,
            expectedOwnerProvider: { otherOwnerID }
        )
        var acks: [AppLimitNSEAck] = []
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: setEnvelope(token: 10, source: .notificationServiceExtension),
            coordinator: mismatched,
            now: referenceDate,
            postAck: { acks.append($0) },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "failed")
        XCTAssertEqual(delivery?.ack.disposition, "persistence_error")
        XCTAssertEqual(delivery?.ack.reason, "app_limit_epoch_error")
        XCTAssertTrue(acks.isEmpty, "owner mismatch must leave the command retryable")
        XCTAssertEqual(wakes, 0)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), before)
    }

    func testExpiredNewerSetReplacesCurrentClearWithNewerExpiryTombstone() async throws {
        let harness = makeHarness()
        _ = try harness.coordinator.ingest(clearEnvelope(token: 12, source: .poll))
        let expired = setEnvelope(
            token: 13,
            source: .notificationServiceExtension,
            expiresAt: referenceDate.addingTimeInterval(-1)
        )
        var wakes = 0

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: expired,
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in },
            requestOwnerWake: { wakes += 1 }
        )

        XCTAssertEqual(delivery?.ack.status, "confirmed")
        XCTAssertEqual(delivery?.ack.disposition, "expired")
        XCTAssertEqual(wakes, 0)
        let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, 13)
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 13)
        XCTAssertNil(slot.activeRule)
        XCTAssertNil(slot.pendingOwnerWork)
    }

    func testExpiredNewerSetPersistsTombstoneBeforeAcknowledgingAndSupersedesDelayedOldSet() async throws {
        let harness = makeHarness()
        let expired = setEnvelope(
            token: 5,
            source: .notificationServiceExtension,
            expiresAt: referenceDate.addingTimeInterval(-1)
        )

        let delivery = await AppLimitProductionComposition.deliverNSE(
            envelope: expired,
            coordinator: harness.coordinator,
            now: referenceDate,
            postAck: { _ in
                let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
                XCTAssertEqual(slot.latestOrderingToken, 5)
                XCTAssertEqual(slot.clearTombstone?.orderingToken, 5)
                XCTAssertNil(slot.activeRule)
                XCTAssertNil(slot.pendingOwnerWork)
            },
            requestOwnerWake: {}
        )

        XCTAssertEqual(delivery?.ack.status, "confirmed")
        XCTAssertEqual(delivery?.ack.disposition, "expired")
        XCTAssertEqual(
            try harness.coordinator.ingest(setEnvelope(token: 3, source: .poll)),
            .superseded(latestOrderingToken: 5)
        )
        let slot = try XCTUnwrap(harness.store.read().slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, 5)
        XCTAssertNil(slot.activeRule)
        XCTAssertNil(slot.pendingOwnerWork)
    }

    func testPollAndNSEPersistIdenticalStateApartFromSource() throws {
        let pollHarness = makeHarness()
        let nseHarness = makeHarness()
        let pollEnvelope = setEnvelope(token: 10, source: .poll)
        let nseEnvelope = AppLimitCommandEnvelope(
            commandID: pollEnvelope.commandID,
            ruleID: pollEnvelope.ruleID,
            orderingToken: pollEnvelope.orderingToken,
            kind: pollEnvelope.kind,
            payloadDigest: pollEnvelope.payloadDigest,
            receivedAt: pollEnvelope.receivedAt,
            source: .notificationServiceExtension,
            rule: pollEnvelope.rule
        )
        _ = try pollHarness.coordinator.ingest(pollEnvelope)
        _ = try nseHarness.coordinator.ingest(nseEnvelope)

        XCTAssertEqual(
            normalizedSourceJSON(try Data(contentsOf: pollHarness.fileURL)),
            normalizedSourceJSON(try Data(contentsOf: nseHarness.fileURL))
        )
    }

    func testPushCompositionExposesNoMonitorOrShieldCapability() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for relative in [
            "Evlin iOS/Services/AppLimitProductionComposition.swift",
            "EvlinPushApplier/NotificationService.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(relative))
            for forbidden in [
                "startMonitoring", "stopMonitoring", "DeviceActivityCenter(",
                "ManagedSettingsStore(",
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(relative) exposes \(forbidden)")
            }
            if relative.contains("AppLimitProductionComposition") {
                XCTAssertFalse(source.contains("ActiveLockStore"))
                XCTAssertFalse(source.contains("Shield"))
            }
        }
    }

    func testNSEDeadlineDoesNotUseATaskGroup() throws {
        // P1 (2026-08-22 review): a task group's scope exit awaits every
        // child, and a child wedged inside synchronous daemon XPC (mach_msg)
        // has no cancellation point — a group-based "deadline" blocks right
        // alongside the wedged call until the system kills the NSE. The
        // deadline must be a continuation race that RETURNS at timeout and
        // orphans the wedged work.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "EvlinPushApplier/NotificationService.swift"
            )
        )
        XCTAssertFalse(
            source.contains("withThrowingTaskGroup"),
            "NSE deadline regressed to a task group — it will block on a wedged XPC child"
        )
        XCTAssertTrue(
            source.contains("withCheckedThrowingContinuation"),
            "NSE deadline lost its continuation race"
        )
        // Timeout must leave the command pending, never ack it as failed.
        XCTAssertTrue(
            source.contains("catch is DeadlineExceeded"),
            "deadline errors must be distinguished so the command stays pending"
        )
    }

    private func makeHarness() -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nse-limit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("epoch.json")
        let store = AppLimitEpochStore(
            fileURL: fileURL,
            lock: NSEAppLimitTestLock(),
            ownerProvider: { ownerID },
            legacyDefaults: nil
        )
        return Harness(
            fileURL: fileURL,
            store: store,
            coordinator: AppLimitCommandCoordinator(
                store: store,
                expectedOwnerProvider: { ownerID }
            )
        )
    }

    private func setEnvelope(
        token: Int64,
        digest: String? = nil,
        source: AppLimitCommandSource,
        expiresAt: Date? = nil
    ) -> AppLimitCommandEnvelope {
        let rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.focus",
            displayName: "Focus",
            budgetMinutes: 30,
            window: AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: "UTC"),
            effectiveFrom: referenceDate,
            expiresAt: expiresAt
        )
        return AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: token,
            kind: .set,
            payloadDigest: digest ?? "set-\(token)",
            receivedAt: referenceDate,
            source: source,
            rule: rule
        )
    }

    private func clearEnvelope(
        token: Int64,
        source: AppLimitCommandSource
    ) -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: token,
            kind: .clear,
            payloadDigest: "clear-\(token)",
            receivedAt: referenceDate,
            source: source,
            rule: nil
        )
    }

    private func normalizedSourceJSON(_ data: Data) -> AnyHashable {
        func normalize(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                if dictionary["source"] != nil { dictionary["source"] = "SOURCE" }
                if dictionary["lastMutationSource"] != nil {
                    dictionary["lastMutationSource"] = "SOURCE"
                }
                return dictionary.mapValues(normalize)
            }
            if let array = value as? [Any] { return array.map(normalize) }
            return value
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        let normalized = normalize(object)
        let canonical = (try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])) ?? Data()
        return canonical as NSData
    }
}

private struct Harness {
    let fileURL: URL
    let store: AppLimitEpochStore
    let coordinator: AppLimitCommandCoordinator
}

private enum TestError: Error { case ackFailed }

private final class NSEAppLimitTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let ownerID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
private let otherOwnerID = UUID(uuidString: "cccccccc-0000-0000-0000-000000000002")!
private let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
private let referenceDate = Date(timeIntervalSince1970: 1_721_174_400)
