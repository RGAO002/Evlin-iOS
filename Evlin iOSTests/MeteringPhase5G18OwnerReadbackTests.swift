import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringPhase5G18OwnerReadbackTests: XCTestCase {
    func testSetReadbackTruthfullyNamesAppliedMonitorOwnerState() throws {
        let armID = UUID(uuidString: "50000000-0000-0000-0000-000000000006")!
        let receipt = AppLimitApplyReceipt(
            ruleID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            orderingToken: 9_007_199_254_740_993,
            commandKind: .set,
            armID: armID,
            source: "app_limit_owner",
            appliedAt: Date(timeIntervalSince1970: 1_753_027_200),
            storeRevision: 12
        )

        let detail = HTTPAppLimitOwnerReadbackClient.detail(for: receipt)

        XCTAssertEqual(detail["verb"] as? String, "set_limit")
        XCTAssertEqual(detail["application_state"] as? String, "applied")
        XCTAssertEqual(detail["owner"] as? String, "main_app")
        XCTAssertEqual(detail["source"] as? String, "monitor_owner_readback")
        XCTAssertEqual(detail["ordering_token"] as? Int64, 9_007_199_254_740_993)
        XCTAssertEqual(detail["arm_id"] as? String, armID.uuidString)
    }

    func testClearReadbackTruthfullyNamesClearedStateWithoutArm() throws {
        let receipt = AppLimitApplyReceipt(
            ruleID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            orderingToken: 4,
            commandKind: .clear,
            armID: nil,
            source: "app_limit_owner",
            appliedAt: Date(timeIntervalSince1970: 1_753_027_200),
            storeRevision: 13
        )

        let detail = HTTPAppLimitOwnerReadbackClient.detail(for: receipt)

        XCTAssertEqual(detail["verb"] as? String, "clear_limit")
        XCTAssertEqual(detail["application_state"] as? String, "cleared")
        XCTAssertEqual(detail["owner"] as? String, "main_app")
        XCTAssertNil(detail["arm_id"])
    }

    func testLegacyPrivateReadbackAdapterIsAbsent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let poller = try String(contentsOf: root.appendingPathComponent(
            "Evlin iOS/Services/CommandPoller.swift"
        ))
        XCTAssertFalse(poller.contains("AppLimitOwnerAPIReadbackPort"))
        XCTAssertTrue(poller.contains("HTTPAppLimitOwnerReadbackClient"))
    }
}
