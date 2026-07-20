import XCTest
@testable import Evlin_iOS

@MainActor
final class NSEVersionedCommandWireTests: XCTestCase {
    private let commandID = "11111111-2222-3333-4444-555555555555"

    private func payload(includeVersion: Bool = true) -> Data {
        let version = includeVersion
            ? "\"policy_revision\": \"pool-9:cap-4\", \"ordering_token\": 9007199254740993,"
            : ""
        return Data("""
        {
          "command_id": "\(commandID)",
          "action": "earned_time_config",
          "tier": "earnedTime",
          "target": {
            "target_type": "earnedTime",
            "target_child_id": "CCCCCCCC-0000-0000-0000-000000000001",
            "original_request": ""
          },
          "duration_minutes": null,
          "issued_at": "2026-07-20T18:02:03.456789+00:00",
          "earned_time_config": {
            \(version)
            "child_profile_id": "BBBBBBBB-0000-0000-0000-000000000001",
            "child_device_id": "CCCCCCCC-0000-0000-0000-000000000001",
            "effective_date": "2026-07-20",
            "usage_date": "2026-07-20",
            "timezone": "America/New_York",
            "daily_pool_minutes": 120,
            "device_cap_minutes": 60,
            "earned_bucket_minutes": 5,
            "remaining_minutes": 47,
            "selected_set": {
              "list_id": "AAAAAAAA-0000-0000-0000-000000000001",
              "recordKey": "savedList:AAAAAAAA-0000-0000-0000-000000000001",
              "targetKey": "AAAAAAAA-0000-0000-0000-000000000001",
              "has_tokens": true
            }
          }
        }
        """.utf8)
    }

    func test_pollAndNSEDecodeIdenticalVersionedEarnedPolicy() throws {
        let poll = try JSONDecoder().decode(PollCommandDTO.self, from: payload())
        let appCommand = CommandPoller.lockCommand(from: poll)
        let pushCommand = try NSECommandWireDecoder.decode(payload())

        XCTAssertEqual(appCommand.earnedTimeConfig, pushCommand.earnedTimeConfig)
        let policy = try XCTUnwrap(appCommand.earnedTimeConfig)
        XCTAssertEqual(policy.orderingToken, 9_007_199_254_740_993)
        XCTAssertEqual(policy.policy_revision, "pool-9:cap-4")
        XCTAssertEqual(policy.child_device_id, "CCCCCCCC-0000-0000-0000-000000000001")
        XCTAssertEqual(policy.usage_date, "2026-07-20")
        XCTAssertEqual(policy.timezone, "America/New_York")
        XCTAssertEqual(policy.daily_pool_minutes, 120)
        XCTAssertEqual(policy.device_cap_minutes, 60)
        XCTAssertEqual(policy.remaining_minutes, 47)
        XCTAssertEqual(policy.selected_set?.has_tokens, true)
        XCTAssertEqual(appCommand.issuedAt, pushCommand.issuedAt)
    }

    func test_oldForegroundPayloadDecodesWithoutVersionAuthority() throws {
        let poll = try JSONDecoder().decode(PollCommandDTO.self, from: payload(includeVersion: false))
        let appCommand = CommandPoller.lockCommand(from: poll)
        XCTAssertNil(appCommand.earnedTimeConfig?.orderingToken)
        XCTAssertNil(appCommand.earnedTimeConfig?.policy_revision)
    }

    func test_nonPositivePresentPolicyTokenIsRejectedByBothDecoders() throws {
        let invalid = Data(
            String(decoding: payload(), as: UTF8.self)
                .replacingOccurrences(of: "9007199254740993", with: "0")
                .utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(PollCommandDTO.self, from: invalid))
        XCTAssertThrowsError(try NSECommandWireDecoder.decode(invalid))
    }
}
