import XCTest
import UIKit
@testable import Evlin_iOS

/// Hermetic coverage for `CommandPoller.pollOnceForCurrentDevice()` — the
/// one-shot poll entry point the APNs background remote-notification handler
/// calls (Task 9 / Phase 5 L2 silent-push delivery).
///
/// We can't fire a real APNs push or mint a device token in a unit test, so we
/// drive the poller through its injectable seams (`childDeviceIDProvider`,
/// `oneShotPollOverride`) instead of touching shared `UserDefaults` or the
/// network. The override stands in for the real `pollOnce()` network path so we
/// can assert the device-id → poll wiring without any I/O.
@MainActor
final class CommandPollerTests: XCTestCase {
    private let poller = CommandPoller.shared

    // The poller is a singleton; snapshot its seams so each test is isolated
    // and we don't bleed an injected provider into other suites.
    private var savedDeviceIDProvider: (() -> UUID?)!
    private var savedPollOverride: ((UUID, APIClient) async -> Void)?
    private var savedAppLimitRecoveryOverride: (() async -> Void)?
    private var savedPollCommandsOverride: ((UUID, APIClient) async throws -> [PollCommandDTO])?
    private var savedLockedSetIDOverride: ((String, Data?) -> Void)?
    private var savedAppLimitEnvelopeOverride: ((PollCommandDTO, LockCommand) throws -> AppLimitCommandEnvelope)?
    private var savedAppLimitIngestOverride: ((AppLimitCommandEnvelope) throws -> AppLimitCommandDisposition)?
    private var savedAppLimitOwnerExecuteOverride: ((LockCommand, AppLimitCommandEnvelope, UUID) async -> AppLimitOwnerExecutionResult)?
    private var savedAppLimitReceiptReadbackOverride: ((UUID) throws -> AppLimitApplyReceipt?)?
    private var savedAckCommandOverride: ((UUID, String, [String: Any]?) async throws -> Void)?
    private var savedCommandExecutionOverride: ((PollCommandDTO, UUID, APIClient) async -> Void)?
    private var savedTaskPauseSupersessionStore: TaskPauseSupersessionStoring!

    override func setUp() async throws {
        savedDeviceIDProvider = poller.childDeviceIDProvider
        savedPollOverride = poller.oneShotPollOverride
        savedAppLimitRecoveryOverride = poller.appLimitRecoveryOverride
        poller.appLimitRecoveryOverride = {}
        savedPollCommandsOverride = poller.pollCommandsOverride
        savedLockedSetIDOverride = poller.saveLockedSetIDOverride
        savedAppLimitEnvelopeOverride = poller.appLimitEnvelopeOverride
        savedAppLimitIngestOverride = poller.appLimitIngestOverride
        savedAppLimitOwnerExecuteOverride = poller.appLimitOwnerExecuteOverride
        savedAppLimitReceiptReadbackOverride = poller.appLimitReceiptReadbackOverride
        savedAckCommandOverride = poller.ackCommandOverride
        savedCommandExecutionOverride = poller.commandExecutionOverride
        savedTaskPauseSupersessionStore = poller.taskPauseSupersessionStore
    }

    override func tearDown() async throws {
        poller.childDeviceIDProvider = savedDeviceIDProvider
        poller.oneShotPollOverride = savedPollOverride
        poller.appLimitRecoveryOverride = savedAppLimitRecoveryOverride
        poller.pollCommandsOverride = savedPollCommandsOverride
        poller.saveLockedSetIDOverride = savedLockedSetIDOverride
        poller.appLimitEnvelopeOverride = savedAppLimitEnvelopeOverride
        poller.appLimitIngestOverride = savedAppLimitIngestOverride
        poller.appLimitOwnerExecuteOverride = savedAppLimitOwnerExecuteOverride
        poller.appLimitReceiptReadbackOverride = savedAppLimitReceiptReadbackOverride
        poller.ackCommandOverride = savedAckCommandOverride
        poller.commandExecutionOverride = savedCommandExecutionOverride
        poller.taskPauseSupersessionStore = savedTaskPauseSupersessionStore
    }

    private func earnedConfigCommand() throws -> PollCommandDTO {
        let json = """
        {
          "command_id": "11111111-0000-0000-0000-000000000001",
          "action": "earned_time_config",
          "tier": "earnedTime",
          "target": { "target_type": "earnedTime", "original_request": "" },
          "issued_at": "2026-07-12T10:00:00.000000+00:00",
          "earned_time_config": {
            "child_profile_id": "BBBBBBBB-0000-0000-0000-000000000001",
            "child_device_id": "CCCCCCCC-0000-0000-0000-000000000001",
            "effective_date": "2026-07-12",
            "usage_date": "2026-07-12",
            "timezone": "America/New_York",
            "daily_pool_minutes": 90,
            "device_cap_minutes": 60,
            "earned_bucket_minutes": 10,
            "selected_set": { "list_id": "AAAAAAAA-0000-0000-0000-000000000001" }
          }
        }
        """
        return try JSONDecoder().decode(PollCommandDTO.self, from: Data(json.utf8))
    }

    func testPollLimitCommandsRejectMissingAndInvalidOrderingTokens() throws {
        let invalidTokens: [Any?] = [nil, 0, -1, 1.5, NSDecimalNumber(string: "9223372036854775808")]

        for commandKey in ["set_limit", "clear_limit"] {
            for token in invalidTokens {
                let data = try appLimitFixtureCommand(commandKey, orderingToken: token)
                XCTAssertThrowsError(try JSONDecoder().decode(PollCommandDTO.self, from: data))
            }
        }
    }

    func testAcceptedPolledLimitExecutesAuthorizedWorkAndAcksDurableReceipt() async throws {
        let receipt = AppLimitApplyReceipt(
            ruleID: appLimitRuleID,
            orderingToken: 10,
            commandKind: .set,
            armID: nil,
            source: "app_owner",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_100),
            storeRevision: 42
        )
        var ownerExecutions = 0
        poller.appLimitReceiptReadbackOverride = { _ in receipt }
        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 10,
            disposition: .acceptedNeedsOwner
        ) { _, _, _ in
            ownerExecutions += 1
            return AppLimitOwnerExecutionResult(
                result: .confirmedExact(verb: .setLimit, displayName: "YouTube", effectiveState: nil),
                receipt: receipt
            )
        }

        XCTAssertEqual(ownerExecutions, 1)
        XCTAssertEqual(ack.status, "confirmed")
        XCTAssertEqual(ack.detail?["ordering_token"] as? Int64, 10)
        XCTAssertEqual(ack.detail?["disposition"] as? String, "accepted_needs_owner")
        XCTAssertEqual(ack.detail?["receipt_revision"] as? UInt64, 42)
    }

    func testSupersededPolledLimitAcksWithoutOwnerEffects() async throws {
        var ownerExecutions = 0
        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 9,
            disposition: .superseded(latestOrderingToken: 10)
        ) { _, _, _ in
            ownerExecutions += 1
            return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
        }

        XCTAssertEqual(ownerExecutions, 0)
        XCTAssertEqual(ack.status, "confirmed")
        XCTAssertEqual(ack.detail?["reason"] as? String, "superseded_by_token")
        XCTAssertEqual(ack.detail?["latest_ordering_token"] as? Int64, 10)
        XCTAssertEqual(ack.detail?["disposition"] as? String, "superseded")
    }

    func testDuplicatePendingPolledLimitAcksPendingWithoutOwnerEffects() async throws {
        var ownerExecutions = 0
        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 10,
            disposition: .duplicatePending
        ) { _, _, _ in
            ownerExecutions += 1
            return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
        }

        XCTAssertEqual(ownerExecutions, 0)
        XCTAssertEqual(ack.status, "pending")
        XCTAssertEqual(ack.detail?["reason"] as? String, "persisted_waiting_for_owner")
        XCTAssertEqual(ack.detail?["disposition"] as? String, "duplicate_pending")
    }

    func testDuplicateAppliedPolledLimitAcksStoredReceiptWithoutOwnerEffects() async throws {
        let receipt = AppLimitApplyReceipt(
            ruleID: appLimitRuleID,
            orderingToken: 10,
            commandKind: .set,
            armID: nil,
            source: "app_owner",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_100),
            storeRevision: 77
        )
        var ownerExecutions = 0
        poller.appLimitReceiptReadbackOverride = { _ in receipt }
        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 10,
            disposition: .duplicateApplied(receipt)
        ) { _, _, _ in
            ownerExecutions += 1
            return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
        }

        XCTAssertEqual(ownerExecutions, 0)
        XCTAssertEqual(ack.status, "confirmed")
        XCTAssertEqual(ack.detail?["receipt_revision"] as? UInt64, 77)
        XCTAssertEqual(ack.detail?["disposition"] as? String, "duplicate_applied")
    }

    func testConfirmedOwnerResultWithoutCurrentReceiptAcksPending() async throws {
        let receipt = AppLimitApplyReceipt(
            ruleID: appLimitRuleID,
            orderingToken: 10,
            commandKind: .set,
            armID: UUID(),
            source: "app_owner",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_100),
            storeRevision: 42
        )
        poller.appLimitReceiptReadbackOverride = { _ in nil }

        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 10,
            disposition: .acceptedNeedsOwner
        ) { _, _, _ in
            AppLimitOwnerExecutionResult(
                result: .confirmedExact(
                    verb: .setLimit,
                    displayName: "YouTube",
                    effectiveState: nil
                ),
                receipt: receipt
            )
        }

        XCTAssertEqual(ack.status, "pending")
        XCTAssertNil(ack.detail?["receipt_revision"])
    }

    func testDuplicateAppliedReceiptRejectedByCurrentReadbackAcksPending() async throws {
        let staleReceipt = AppLimitApplyReceipt(
            ruleID: appLimitRuleID,
            orderingToken: 10,
            commandKind: .set,
            armID: UUID(),
            source: "app_owner",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_100),
            storeRevision: 41
        )
        poller.appLimitReceiptReadbackOverride = { _ in nil }

        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 10,
            disposition: .duplicateApplied(staleReceipt)
        ) { _, _, _ in
            XCTFail("duplicate applied must not rerun owner effects")
            return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
        }

        XCTAssertEqual(ack.status, "pending")
        XCTAssertNil(ack.detail?["receipt_revision"])
    }

    func testEqualTokenConflictFailsClosedWithoutOwnerEffects() async throws {
        var ownerExecutions = 0
        let ack = try await runAppLimitPoll(
            commandKey: "set_limit",
            token: 10,
            disposition: .equalTokenConflict
        ) { _, _, _ in
            ownerExecutions += 1
            return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
        }

        XCTAssertEqual(ownerExecutions, 0)
        XCTAssertEqual(ack.status, "failed")
        XCTAssertEqual(ack.detail?["reason"] as? String, "equal_token_conflict")
        XCTAssertEqual(ack.detail?["disposition"] as? String, "equal_token_conflict")
    }

    func testClearThenDelayedOldSetCannotResurrectRuleOrRepeatOwnerEffects() async throws {
        let deviceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let clearDTO = try JSONDecoder().decode(
            PollCommandDTO.self,
            from: try appLimitFixtureCommand("clear_limit", orderingToken: 11)
        )
        let setDTO = try JSONDecoder().decode(
            PollCommandDTO.self,
            from: try appLimitFixtureCommand("set_limit", orderingToken: 10)
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "poll-limit-ordering-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: PollerEpochTestLock(),
            ownerProvider: { deviceID },
            legacyDefaults: nil
        )
        let coordinator = AppLimitCommandCoordinator(
            store: store,
            expectedOwnerProvider: { deviceID }
        )
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.pollCommandsOverride = { _, _ in [clearDTO, setDTO] }
        poller.appLimitEnvelopeOverride = { [appLimitRuleID] poll, command in
            let isClear = command.action == .clearLimit
            let token: Int64 = isClear ? 11 : 10
            return AppLimitCommandEnvelope(
                commandID: poll.command_id,
                ruleID: appLimitRuleID,
                orderingToken: token,
                kind: isClear ? .clear : .set,
                payloadDigest: isClear ? "clear-11" : "set-10",
                receivedAt: command.issuedAt,
                source: .poll,
                rule: isClear ? nil : AppLimitRule(
                    id: appLimitRuleID,
                    appTokens: [],
                    bundleID: "com.google.ios.youtube",
                    displayName: "YouTube",
                    budgetMinutes: 60,
                    window: AppLimitWindow(
                        startMinute: 0,
                        endMinute: 1439,
                        repeats: true,
                        timezone: nil
                    ),
                    effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
                    expiresAt: nil
                )
            )
        }
        poller.appLimitIngestOverride = { try coordinator.ingest($0) }
        var ownerExecutions = 0
        poller.appLimitOwnerExecuteOverride = { _, _, _ in
            ownerExecutions += 1
            return AppLimitOwnerExecutionResult(
                result: .failed(.execution("deferred_for_test")),
                receipt: nil
            )
        }
        var acks: [(String, [String: Any]?)] = []
        poller.ackCommandOverride = { _, status, detail in acks.append((status, detail)) }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(ownerExecutions, 1)
        XCTAssertEqual(acks.count, 2)
        XCTAssertEqual(acks.last?.0, "confirmed")
        XCTAssertEqual(acks.last?.1?["disposition"] as? String, "superseded")
        let slot = try XCTUnwrap(store.read().slots[appLimitRuleID])
        XCTAssertEqual(slot.latestOrderingToken, 11)
        XCTAssertEqual(slot.latestKind, .clear)
        XCTAssertNil(slot.activeRule)
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 11)
    }

    private var appLimitRuleID: UUID {
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    }

    private func runAppLimitPoll(
        commandKey: String,
        token: Int64,
        disposition: AppLimitCommandDisposition,
        ownerExecute: @escaping (LockCommand, AppLimitCommandEnvelope, UUID) async -> AppLimitOwnerExecutionResult
    ) async throws -> (status: String, detail: [String: Any]?) {
        let deviceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let dto = try JSONDecoder().decode(
            PollCommandDTO.self,
            from: try appLimitFixtureCommand(commandKey, orderingToken: token)
        )
        poller.childDeviceIDProvider = { deviceID }
        poller.oneShotPollOverride = nil
        poller.pollCommandsOverride = { _, _ in [dto] }
        poller.appLimitEnvelopeOverride = { [appLimitRuleID] poll, command in
            AppLimitCommandEnvelope(
                commandID: poll.command_id,
                ruleID: appLimitRuleID,
                orderingToken: token,
                kind: commandKey == "set_limit" ? .set : .clear,
                payloadDigest: "\(commandKey)-\(token)",
                receivedAt: command.issuedAt,
                source: .poll,
                rule: commandKey == "set_limit" ? AppLimitRule(
                    id: appLimitRuleID,
                    appTokens: [],
                    bundleID: "com.google.ios.youtube",
                    displayName: "YouTube",
                    budgetMinutes: 60,
                    window: AppLimitWindow(
                        startMinute: 0,
                        endMinute: 1439,
                        repeats: true,
                        timezone: nil
                    ),
                    effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
                    expiresAt: nil
                ) : nil
            )
        }
        poller.appLimitIngestOverride = { _ in disposition }
        poller.appLimitOwnerExecuteOverride = ownerExecute

        var captured: (String, [String: Any]?)?
        poller.ackCommandOverride = { commandID, status, detail in
            XCTAssertEqual(commandID, dto.command_id)
            captured = (status, detail)
        }

        await poller.pollOnceForCurrentDevice()
        return try XCTUnwrap(captured)
    }

    private func appLimitFixtureCommand(
        _ commandKey: String,
        orderingToken: Any?
    ) throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/app_limit_wire.json")
        let fixture = try Data(contentsOf: fixtureURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var command = try XCTUnwrap(root[commandKey] as? [String: Any])
        let payloadKey = commandKey == "set_limit" ? "limit" : "clear"
        var payload = try XCTUnwrap(command[payloadKey] as? [String: Any])
        if let orderingToken {
            payload["ordering_token"] = orderingToken
        } else {
            payload.removeValue(forKey: "ordering_token")
        }
        command[payloadKey] = payload
        return try JSONSerialization.data(withJSONObject: command)
    }

    /// With a paired child device id present, the one-shot poll routes that
    /// exact id into the poll path (the same path the foreground timer drives).
    func testPollOnceForCurrentDeviceRoutesStoredDeviceIDIntoPollPath() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!
        poller.childDeviceIDProvider = { expectedID }

        var observedID: UUID?
        var callCount = 0
        poller.oneShotPollOverride = { deviceID, _ in
            observedID = deviceID
            callCount += 1
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(callCount, 1, "Expected exactly one poll for the paired device")
        XCTAssertEqual(observedID, expectedID, "Poll must run against the stored child device id")
    }

    /// APNs can deliver lock and unlock wakes close together. The old poller
    /// dropped a wake that arrived while `isPolling == true`, which left the
    /// second command queued until the app foregrounded/restarted. A concurrent
    /// wake must coalesce into one immediate follow-up poll.
    func testConcurrentOneShotPollIsCoalescedIntoFollowUpPoll() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000004")!
        poller.childDeviceIDProvider = { expectedID }

        var pollCount = 0
        poller.pollCommandsOverride = { [weak poller] deviceID, _ in
            XCTAssertEqual(deviceID, expectedID)
            pollCount += 1
            if pollCount == 1 {
                Task { @MainActor in
                    await poller?.pollOnceForCurrentDevice()
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return []
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(pollCount, 2, "Concurrent wake should trigger one follow-up poll, not get dropped")
    }

    func testSameBatchExecutesNewestOppositeTaskPauseAndSupersedesOlder() async throws {
        let deviceID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000005")!
        let oldID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let newID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let manualID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        func dto(_ id: UUID, action: String, source: String) throws -> PollCommandDTO {
            let provenance = action == "shield"
                ? "\"lock_source\":\"\(source)\",\"unlock_sources\":null"
                : "\"lock_source\":null,\"unlock_sources\":[\"\(source)\"]"
            let data = Data("""
            {
              "command_id":"\(id.uuidString)","action":"\(action)","tier":"savedList",
              "target":{"bundle_id":null,"list_name":"Locked set","list_id":null,
                        "category_hint":null,"target_all":false,"target_child_id":null,
                        "target_display":"Locked set","original_request":"","has_pending_blob":false,
                        "force_downgrade":false,"lock_source":null,"unlock_sources":null},
              "duration_minutes":null,"issued_at":"2026-08-23T12:00:00Z",
              "limit":null,"clear":null,\(provenance),"earned_time_config":null
            }
            """.utf8)
            return try JSONDecoder().decode(PollCommandDTO.self, from: data)
        }
        let oldUnlock = try dto(oldID, action: "unshield", source: "task_pause")
        let newLock = try dto(newID, action: "shield", source: "task_pause")
        let manualUnlock = try dto(manualID, action: "unshield", source: "manual")
        poller.childDeviceIDProvider = { deviceID }
        poller.pollCommandsOverride = { _, _ in [oldUnlock, newLock, manualUnlock] }
        var executed: [UUID] = []
        poller.commandExecutionOverride = { poll, _, _ in executed.append(poll.command_id) }
        var acks: [(UUID, String, [String: Any]?)] = []
        poller.ackCommandOverride = { acks.append(($0, $1, $2)) }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(executed, [newID, manualID])
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks[0].0, oldID)
        XCTAssertEqual(acks[0].1, "superseded")
        XCTAssertEqual(acks[0].2?["superseded_by_command_id"] as? String, newID.uuidString)
    }

    func testSameBatchDoesNotSupersedeMixedSourceManualUnlock() async throws {
        let deviceID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000007")!
        let manualID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let lockID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        func dto(_ id: UUID, action: String, provenance: String) throws -> PollCommandDTO {
            try JSONDecoder().decode(PollCommandDTO.self, from: Data("""
            {
              "command_id":"\(id.uuidString)","action":"\(action)","tier":"savedList",
              "target":{"target_display":"Locked set","original_request":""},
              "duration_minutes":null,"issued_at":"2026-08-23T12:00:00Z",
              "limit":null,"clear":null,\(provenance),"earned_time_config":null
            }
            """.utf8))
        }
        let manualUnlock = try dto(
            manualID,
            action: "unshield",
            provenance: "\"lock_source\":null,\"unlock_sources\":[\"manual\",\"earned_time\",\"task_pause\"]"
        )
        let taskLock = try dto(
            lockID,
            action: "shield",
            provenance: "\"lock_source\":\"task_pause\",\"unlock_sources\":null"
        )
        poller.childDeviceIDProvider = { deviceID }
        poller.pollCommandsOverride = { _, _ in [manualUnlock, taskLock] }
        var executed: [UUID] = []
        poller.commandExecutionOverride = { poll, _, _ in executed.append(poll.command_id) }
        var supersededAcks = 0
        poller.ackCommandOverride = { _, status, _ in
            if status == "superseded" { supersededAcks += 1 }
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(executed, [manualID, lockID])
        XCTAssertEqual(supersededAcks, 0)
    }

    func testLostSupersededAckNeverExecutesTheSkippedCommandOnRetry() async throws {
        struct LostResponse: Error {}
        let deviceID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000006")!
        let oldID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let newID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        func dto(_ id: UUID, action: String) throws -> PollCommandDTO {
            let provenance = action == "shield"
                ? "\"lock_source\":\"task_pause\",\"unlock_sources\":null"
                : "\"lock_source\":null,\"unlock_sources\":[\"task_pause\"]"
            return try JSONDecoder().decode(PollCommandDTO.self, from: Data("""
            {
              "command_id":"\(id.uuidString)","action":"\(action)","tier":"savedList",
              "target":{"target_display":"Locked set","original_request":""},
              "duration_minutes":null,"issued_at":"2026-08-23T12:00:00Z",
              "limit":null,"clear":null,\(provenance),"earned_time_config":null
            }
            """.utf8))
        }
        let oldUnlock = try dto(oldID, action: "unshield")
        let newLock = try dto(newID, action: "shield")
        let store = InMemoryTaskPauseSupersessionStore()
        poller.taskPauseSupersessionStore = store
        poller.childDeviceIDProvider = { deviceID }
        var fetch = 0
        poller.pollCommandsOverride = { _, _ in
            fetch += 1
            return fetch == 1 ? [oldUnlock, newLock] : [oldUnlock]
        }
        var executed: [UUID] = []
        poller.commandExecutionOverride = { poll, _, _ in executed.append(poll.command_id) }
        var ackAttempts = 0
        poller.ackCommandOverride = { commandID, status, _ in
            guard commandID == oldID, status == "superseded" else { return }
            ackAttempts += 1
            if ackAttempts == 1 { throw LostResponse() }
        }

        await poller.pollOnceForCurrentDevice()
        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(executed, [newID])
        XCTAssertEqual(ackAttempts, 2)
        XCTAssertNil(store.replacementID(for: oldID))
    }

    func testRejectedSupersededAckKeepsDurableSkipOnRetry() async throws {
        let deviceID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000008")!
        let oldID = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
        let newID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        func dto(_ id: UUID, action: String) throws -> PollCommandDTO {
            let provenance = action == "shield"
                ? "\"lock_source\":\"task_pause\",\"unlock_sources\":null"
                : "\"lock_source\":null,\"unlock_sources\":[\"task_pause\"]"
            return try JSONDecoder().decode(PollCommandDTO.self, from: Data("""
            {
              "command_id":"\(id.uuidString)","action":"\(action)","tier":"savedList",
              "target":{"target_display":"Locked set","original_request":""},
              "duration_minutes":null,"issued_at":"2026-08-23T12:00:00Z",
              "limit":null,"clear":null,\(provenance),"earned_time_config":null
            }
            """.utf8))
        }
        let oldUnlock = try dto(oldID, action: "unshield")
        let newLock = try dto(newID, action: "shield")
        let store = InMemoryTaskPauseSupersessionStore()
        let savedFactory = poller.oneShotAPIClientFactory
        poller.stop()
        poller.oneShotAPIClientFactory = {
            APIClient(baseURL: "https://command-ack.invalid/api/v1")
        }
        CommandPollerAckURLProtocol.statusCode = 409
        CommandPollerAckURLProtocol.requestCount = 0
        URLProtocol.registerClass(CommandPollerAckURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(CommandPollerAckURLProtocol.self)
            poller.stop()
            poller.oneShotAPIClientFactory = savedFactory
        }
        poller.taskPauseSupersessionStore = store
        poller.childDeviceIDProvider = { deviceID }
        var fetch = 0
        poller.pollCommandsOverride = { _, _ in
            fetch += 1
            return fetch == 1 ? [oldUnlock, newLock] : [oldUnlock]
        }
        var executed: [UUID] = []
        poller.commandExecutionOverride = { poll, _, _ in executed.append(poll.command_id) }
        poller.ackCommandOverride = nil

        await poller.pollOnceForCurrentDevice()
        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(executed, [newID])
        XCTAssertEqual(store.replacementID(for: oldID), newID)
        XCTAssertEqual(CommandPollerAckURLProtocol.requestCount, 2)
    }

    /// A coalesced silent wake must keep the APNs completion path alive until
    /// the in-flight poll performs its follow-up pass and owner recovery.
    /// Returning early lets iOS suspend the process with a durable limit
    /// command still waiting for the main-app owner to arm it.
    func testCoalescedOneShotPollWaitsForInFlightOwnerRecovery() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000014")!
        poller.childDeviceIDProvider = { expectedID }

        var pollCount = 0
        var recoveries = 0
        var firstPollContinuation: CheckedContinuation<Void, Never>?
        let firstPollStarted = expectation(description: "first poll started")
        poller.appLimitRecoveryOverride = { recoveries += 1 }
        poller.pollCommandsOverride = { _, _ in
            pollCount += 1
            if pollCount == 1 {
                firstPollStarted.fulfill()
                await withCheckedContinuation { continuation in
                    firstPollContinuation = continuation
                }
            }
            return []
        }

        let firstPoll = Task { await self.poller.pollOnceForCurrentDevice() }
        await fulfillment(of: [firstPollStarted], timeout: 1.0)

        var coalescedWakeReturned = false
        let coalescedWake = Task {
            await self.poller.pollOnceForCurrentDevice(
                recoveryReason: .silentRemoteNotification
            )
            coalescedWakeReturned = true
        }
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(
            coalescedWakeReturned,
            "A coalesced silent wake must not complete before owner recovery can run"
        )

        firstPollContinuation?.resume()
        await firstPoll.value
        await coalescedWake.value

        XCTAssertTrue(coalescedWakeReturned)
        XCTAssertEqual(pollCount, 2)
        XCTAssertEqual(recoveries, 1, "The active poll must reach owner recovery before the coalesced wake completes")
    }

    func testDelayedFetchDiscardsCommandsWhenStoredIdentityChanges() async throws {
        let oldID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000010")!
        let newID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000011")!
        var currentID = oldID
        var resumeFetch: CheckedContinuation<[PollCommandDTO], Never>?
        var fetchCount = 0
        var saveCount = 0
        let store = EarnedTimeStore.shared
        store.removeAll()
        defer {
            poller.saveLockedSetIDOverride = nil
            store.removeAll()
        }
        poller.childDeviceIDProvider = { currentID }
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = { _, _ in saveCount += 1 }
        poller.pollCommandsOverride = { _, _ in
            fetchCount += 1
            if fetchCount == 1 {
                return await withCheckedContinuation { resumeFetch = $0 }
            }
            return []
        }

        let poll = Task { await poller.pollOnceForCurrentDevice() }
        while resumeFetch == nil { await Task.yield() }
        currentID = newID
        resumeFetch?.resume(returning: [try earnedConfigCommand()])
        await poll.value

        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(store.poolMinutes)
        XCTAssertNil(store.capMinutes)
        XCTAssertEqual(fetchCount, 2)
    }

    /// No paired child device id → safe no-op. A backgrounded push on a device
    /// that isn't a paired child must not poll (and must not crash).
    func testPollOnceForCurrentDeviceIsNoOpWhenNoDeviceID() async {
        poller.childDeviceIDProvider = { nil }

        var didPoll = false
        poller.oneShotPollOverride = { _, _ in didPoll = true }

        await poller.pollOnceForCurrentDevice()

        XCTAssertFalse(didPoll, "With no child device id the poll path must not run")
    }

    /// APNs wakes are shared by command delivery, BigKid reflection state, and
    /// parent notification feed rows. The app delegate must invalidate both
    /// UI stores so foreground parent sessions see reflection/nudge notifications
    /// without relaunching or tapping the system banner.
    func testRemoteNotificationPollsCommandsAndInvalidatesBigKidState() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000002")!
        poller.childDeviceIDProvider = { expectedID }

        let stateInvalidated = expectation(description: "BigKid state invalidated")
        let feedInvalidated = expectation(description: "notification feed invalidated")
        let completionCalled = expectation(description: "APNs completion called")
        let stateObserver = NotificationCenter.default.addObserver(
            forName: .bigKidStateInvalidated,
            object: nil,
            queue: .main
        ) { _ in
            stateInvalidated.fulfill()
        }
        let feedObserver = NotificationCenter.default.addObserver(
            forName: .evlinNotificationFeedInvalidated,
            object: nil,
            queue: .main
        ) { _ in
            feedInvalidated.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(stateObserver)
            NotificationCenter.default.removeObserver(feedObserver)
        }

        var observedID: UUID?
        poller.oneShotPollOverride = { deviceID, _ in
            observedID = deviceID
        }

        let appDelegate = AppDelegate()
        appDelegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "aps": ["content-available": 1],
                "evlin": ["kind": "reflection_wake"]
            ]
        ) { result in
            XCTAssertEqual(result, .newData)
            completionCalled.fulfill()
        }

        await fulfillment(of: [stateInvalidated, feedInvalidated, completionCalled], timeout: 1.0)
        XCTAssertEqual(observedID, expectedID)
    }

    /// Reinstall/pairing race: APNs can produce a device token before the kid
    /// device has written `evlin.childDeviceID`. When that child id appears in
    /// K mode, the app must replay token upload + registration immediately.
    /// Parent mode must not do this, or the parent phone can overwrite the kid
    /// device row with the parent's APNs token.
    func testChildDeviceIDAvailabilityReplaysAPNsOnlyInChildMode() {
        var uploadCount = 0
        var registrationCount = 0

        AppDelegate.handleChildDeviceIDAvailability(
            "ABCDEF00-0000-0000-0000-000000000003",
            appMode: "parent",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(registrationCount, 0)

        AppDelegate.handleChildDeviceIDAvailability(
            "ABCDEF00-0000-0000-0000-000000000003",
            appMode: "child",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(registrationCount, 1)

        AppDelegate.handleChildDeviceIDAvailability(
            "",
            appMode: "child",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(registrationCount, 1)

        XCTAssertTrue(AppDelegate.shouldReplayAPNsForChildDeviceID(
            "ABCDEF00-0000-0000-0000-000000000003",
            appMode: "child"
        ))
        XCTAssertFalse(AppDelegate.shouldReplayAPNsForChildDeviceID(
            "not-a-uuid",
            appMode: "child"
        ))
    }

    func testChildForegroundReplaysCachedTokenAndRemoteRegistration() {
        var uploadCount = 0
        var registrationCount = 0

        AppDelegate.handleForegroundAPNsRegistration(
            appMode: "parent",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(registrationCount, 0)

        AppDelegate.handleForegroundAPNsRegistration(
            appMode: "child",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(registrationCount, 1)
    }
}

private final class PollerEpochTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CommandPollerAckURLProtocol: URLProtocol {
    static var statusCode = 200
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "command-ack.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
