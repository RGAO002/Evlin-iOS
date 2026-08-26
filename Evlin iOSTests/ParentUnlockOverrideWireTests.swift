import XCTest
@testable import Evlin_iOS

@MainActor
final class ParentUnlockOverrideWireTests: XCTestCase {
    func testPollAndNSEWireDecodeSameEnvelope() throws {
        let data = commandPayload(action: "parent_unlock_override")

        let poll = try JSONDecoder().decode(PollCommandDTO.self, from: data)
        let pollCommand = CommandPoller.lockCommand(from: poll)
        let nseCommand = try NSECommandWireDecoder.decode(data)
        let envelope = try XCTUnwrap(pollCommand.parentUnlockOverride)

        XCTAssertEqual(pollCommand.action, .parentUnlockOverride)
        XCTAssertEqual(nseCommand.action, .parentUnlockOverride)
        XCTAssertEqual(envelope, nseCommand.parentUnlockOverride)
        XCTAssertEqual(envelope.revision, 4)
        XCTAssertEqual(
            envelope.childDeviceID,
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")
        )
        XCTAssertEqual(envelope.usageDate, "2026-04-26")
        XCTAssertEqual(
            envelope.operationID,
            UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000004")
        )
        XCTAssertEqual(
            envelope.scopes,
            [.manual, .earnedTime, .taskPause, .deviceLimit, .perAppLimit]
        )
        XCTAssertFalse(envelope.cancelled)
    }

    func testExplicitParentCommandActionsDoNotFallBackToShield() throws {
        let actions: [(String, CommandAction)] = [
            ("parent_master_lock", .parentMasterLock),
            ("parent_master_unlock", .parentMasterUnlock),
            ("parent_unlock_override", .parentUnlockOverride),
            ("parent_unlock_override_cancel", .parentUnlockOverrideCancel),
        ]

        for (wireAction, expected) in actions {
            let data = commandPayload(action: wireAction)
            let poll = try JSONDecoder().decode(PollCommandDTO.self, from: data)
            XCTAssertEqual(CommandPoller.lockCommand(from: poll).action, expected)
            XCTAssertEqual(try NSECommandWireDecoder.decode(data).action, expected)
        }
    }

    func testUnknownCommandActionDoesNotSilentlyDecodeAsShield() throws {
        let data = commandPayload(action: "future_parent_control")

        let poll = try JSONDecoder().decode(PollCommandDTO.self, from: data)
        let pollCommand = CommandPoller.lockCommand(from: poll)
        let nseCommand = try NSECommandWireDecoder.decode(data)

        XCTAssertEqual(pollCommand.action, .unknown)
        XCTAssertEqual(nseCommand.action, .unknown)
        XCTAssertNotEqual(pollCommand.action, .shield)
        XCTAssertNotEqual(nseCommand.action, .shield)
    }

    func testParentControlDTOsMatchFrozenBackendContract() throws {
        let operationID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000004")!
        let request = ParentUnlockOverrideRequestDTO(
            duration: .minutes,
            durationMinutes: 30,
            expectedRevision: 17,
            expectedSnapshotDigest: "snapshot-17",
            operationID: operationID
        )
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )

        XCTAssertEqual(requestObject["duration"] as? String, "minutes")
        XCTAssertEqual(requestObject["duration_minutes"] as? Int, 30)
        XCTAssertEqual(requestObject["expected_revision"] as? Int, 17)
        XCTAssertEqual(requestObject["expected_snapshot_digest"] as? String, "snapshot-17")
        XCTAssertEqual(requestObject["operation_id"] as? String, operationID.uuidString)

        let response = try JSONDecoder().decode(
            ParentChildControlResponseDTO.self,
            from: parentControlResponsePayload()
        )
        XCTAssertEqual(response.revision, 18)
        XCTAssertEqual(response.expiresAt, "2026-04-26T15:00:00Z")
        XCTAssertEqual(response.receipts.map(\.deliveryState), [.waiting])
        XCTAssertEqual(response.snapshot.snapshotDigest, "digest-18")
        XCTAssertEqual(response.snapshot.overrideRevision, 18)
        XCTAssertEqual(response.snapshot.devices.first?.limitedAppIDs.count, 1)
    }

    private func commandPayload(action: String) -> Data {
        Data(
            """
            {
              "command_id": "DDDDDDDD-0000-0000-0000-000000000004",
              "action": "\(action)",
              "origin": "user",
              "tier": null,
              "target": { "original_request": "" },
              "duration_minutes": null,
              "issued_at": "2026-04-26T14:00:00+00:00",
              "override": {
                "revision": 4,
                "family_id": "EEEEEEEE-0000-0000-0000-000000000004",
                "child_profile_id": "FFFFFFFF-0000-0000-0000-000000000004",
                "child_device_id": "AAAAAAAA-0000-0000-0000-000000000001",
                "usage_date": "2026-04-26",
                "started_at": "2026-04-26T14:00:00+00:00",
                "expires_at": "2026-04-26T15:00:00+00:00",
                "operation_id": "CCCCCCCC-0000-0000-0000-000000000004",
                "scopes": [
                  "manual",
                  "earned_time",
                  "task_pause",
                  "device_limit",
                  "per_app_limit"
                ],
                "cancelled": false
              }
            }
            """.utf8
        )
    }

    private func parentControlResponsePayload() -> Data {
        Data(
            """
            {
              "child_profile_id": "FFFFFFFF-0000-0000-0000-000000000004",
              "usage_date": "2026-04-26",
              "revision": 18,
              "operation_id": "CCCCCCCC-0000-0000-0000-000000000004",
              "expires_at": "2026-04-26T15:00:00Z",
              "receipts": [
                {
                  "child_device_id": "AAAAAAAA-0000-0000-0000-000000000001",
                  "delivery_state": "waiting"
                }
              ],
              "snapshot": {
                "child_profile_id": "FFFFFFFF-0000-0000-0000-000000000004",
                "snapshot_digest": "digest-18",
                "override_revision": 18,
                "override_expires_at": "2026-04-26T15:00:00Z",
                "devices": [
                  {
                    "child_device_id": "AAAAAAAA-0000-0000-0000-000000000001",
                    "identity_verified": true,
                    "manual_all_apps": false,
                    "earned_exhausted": true,
                    "task_incomplete": false,
                    "device_limit_active": false,
                    "limited_app_ids": ["99999999-0000-0000-0000-000000000001"],
                    "limited_legacy_scope_ids": [],
                    "reflection_active": false,
                    "delivery_state": "waiting"
                  }
                ]
              }
            }
            """.utf8
        )
    }
}
