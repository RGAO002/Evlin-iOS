import Foundation
import XCTest

final class MeteringPhase4SafetyRegistrationTests: XCTestCase {
    func testPreflightRegistersSafetyStatesVectorsCapabilityBranchAndHeads() throws {
        let reportURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/superpowers/reports/2026-07-17-metering-phase4-preflight.md")
        let report = try String(contentsOf: reportURL, encoding: .utf8)

        let requiredValues = [
            "AppLimitVersionSlot",
            "AppLimitClearTombstone",
            "AppLimitOwnerWork",
            "AppLimitEffectLease",
            "ignoredWhilePausedMinutes",
            "AppLimitApplyReceipt",
            "NSE=persist-only",
            "16b06c735eec80d849d62aaded9c3e684ce95d35",
            "37c391a8acd1b79163f80698c680417d19551579"
        ] + (1...20).map { String(format: "P4V%02d", $0) }

        for value in requiredValues {
            XCTAssertTrue(report.contains(value), "missing \(value)")
        }
    }
}
