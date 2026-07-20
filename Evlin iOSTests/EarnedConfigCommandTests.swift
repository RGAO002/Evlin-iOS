import XCTest
@testable import Evlin_iOS

@MainActor
final class EarnedConfigCommandTests: XCTestCase {
    private let owner = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

    private func makeConfigJSON(
        commandID: String = "11111111-0000-0000-0000-000000000001",
        orderingToken: Int64 = 1,
        poolMinutes: Int = 90,
        capMinutes: Int = 60,
        remainingMinutes: Int? = nil
    ) -> Data {
        let remainingField = remainingMinutes.map { ",\n            \"remaining_minutes\": \($0)" } ?? ""
        return Data("""
        {
          "command_id":"\(commandID)",
          "action":"earned_time_config",
          "tier":"earnedTime",
          "target":{"target_type":"earnedTime","original_request":""},
          "issued_at":"2026-07-20T10:00:00Z",
          "earned_time_config":{
            "child_profile_id":"BBBBBBBB-0000-0000-0000-000000000001",
            "child_device_id":"\(owner.uuidString)",
            "effective_date":"2026-07-20",
            "usage_date":"2026-07-20",
            "timezone":"America/New_York",
            "policy_revision":"policy-\(orderingToken)",
            "ordering_token":\(orderingToken),
            "daily_pool_minutes":\(poolMinutes),
            "device_cap_minutes":\(capMinutes),
            "earned_bucket_minutes":10\(remainingField),
            "selected_set":{"list_id":"AAAAAAAA-0000-0000-0000-000000000001"}
          }
        }
        """.utf8)
    }

    func testPollDTOAndSharedCommandDecodeVersionedPolicy() throws {
        let dto = try JSONDecoder().decode(
            PollCommandDTO.self,
            from: makeConfigJSON(orderingToken: 9, remainingMinutes: 37)
        )
        XCTAssertEqual(dto.action, CommandAction.earnedTimeConfig.rawValue)
        XCTAssertEqual(dto.earned_time_config?.orderingToken, 9)
        XCTAssertEqual(dto.earned_time_config?.daily_pool_minutes, 90)
        XCTAssertEqual(dto.earned_time_config?.device_cap_minutes, 60)
        XCTAssertEqual(dto.earned_time_config?.remaining_minutes, 37)
        XCTAssertEqual(CommandAction(rawValue: "earned_time_config"), .earnedTimeConfig)
    }

    func testPollPersistsPendingThenInvokesSoleEpochOwnerWithoutDirectShield() async throws {
        let poller = CommandPoller.shared
        let saved = PollerSeams(poller)
        defer { saved.restore(poller) }

        var ingressCount = 0
        var recoveryCount = 0
        var ack: (String, [String: Any]?)?
        poller.childDeviceIDProvider = { self.owner }
        poller.oneShotPollOverride = nil
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self, from: self.makeConfigJSON())]
        }
        poller.earnedPolicyIngressOverride = { command, fetchedOwner in
            ingressCount += 1
            XCTAssertEqual(command.action, .earnedTimeConfig)
            XCTAssertEqual(fetchedOwner, self.owner)
            return .acceptedNeedsOwner
        }
        poller.ackCommandOverride = { _, status, detail in ack = (status, detail) }
        poller.earnedPolicyRecoveryOverride = { recoveryCount += 1 }
        let shieldsBefore = await ActiveLockStore.shared.allCurrent().shields.count

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(ingressCount, 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(ack?.0, "persisted_waiting_for_owner")
        XCTAssertEqual(ack?.1?["application_state"] as? String, "pending")
        let shieldsAfter = await ActiveLockStore.shared.allCurrent().shields.count
        XCTAssertEqual(shieldsAfter, shieldsBefore)
    }

    func testSupersededPolicyGetsTerminalAckWithoutOwnerRecovery() async throws {
        let poller = CommandPoller.shared
        let saved = PollerSeams(poller)
        defer { saved.restore(poller) }

        var recoveryCount = 0
        var ack: (String, [String: Any]?)?
        poller.childDeviceIDProvider = { self.owner }
        poller.oneShotPollOverride = nil
        poller.pollCommandsOverride = { _, _ in
            [try JSONDecoder().decode(PollCommandDTO.self, from: self.makeConfigJSON(orderingToken: 2))]
        }
        poller.earnedPolicyIngressOverride = { _, _ in .superseded(latestOrderingToken: 4) }
        poller.ackCommandOverride = { _, status, detail in ack = (status, detail) }
        poller.earnedPolicyRecoveryOverride = { recoveryCount += 1 }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(ack?.0, "confirmed")
        XCTAssertEqual(ack?.1?["application_state"] as? String, "superseded")
        XCTAssertEqual(ack?.1?["latest_ordering_token"] as? Int64, 4)
    }
}

@MainActor
private struct PollerSeams {
    let pollCommands: ((UUID, APIClient) async throws -> [PollCommandDTO])?
    let childDeviceIDProvider: () -> UUID?
    let oneShot: ((UUID, APIClient) async -> Void)?
    let ingress: ((LockCommand, UUID) throws -> MeteringPolicyIngressDisposition)?
    let recovery: (() async throws -> Void)?
    let ack: ((UUID, String, [String: Any]?) async throws -> Void)?

    init(_ poller: CommandPoller) {
        pollCommands = poller.pollCommandsOverride
        childDeviceIDProvider = poller.childDeviceIDProvider
        oneShot = poller.oneShotPollOverride
        ingress = poller.earnedPolicyIngressOverride
        recovery = poller.earnedPolicyRecoveryOverride
        ack = poller.ackCommandOverride
    }

    func restore(_ poller: CommandPoller) {
        poller.pollCommandsOverride = pollCommands
        poller.childDeviceIDProvider = childDeviceIDProvider
        poller.oneShotPollOverride = oneShot
        poller.earnedPolicyIngressOverride = ingress
        poller.earnedPolicyRecoveryOverride = recovery
        poller.ackCommandOverride = ack
    }
}
