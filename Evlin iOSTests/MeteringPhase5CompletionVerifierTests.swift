import Foundation
import XCTest

final class MeteringPhase5CompletionVerifierTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testVerifierIsFailClosedAndArchivesEachRun() throws {
        let source = try String(contentsOf: root.appendingPathComponent(
            "scripts/verify_metering_phase5_completion.sh"
        ))
        for marker in [
            "set -euo pipefail", "--self-test", "pre-report", "final)",
            "runs/$RUN_ID", "latest-successful-run", "backend-explicit",
            "tests/services/test_lock_escalation.py", "tests/test_command_delivery_apns.py",
            "push-release-owner-scan", "phase_complete: false", "releasable: false",
        ] {
            XCTAssertTrue(source.contains(marker), marker)
        }
        XCTAssertFalse(source.contains("|| true"))
        XCTAssertFalse(source.contains("semantic_status\", \"AUTOMATED_PASSED"))
    }

    func testReportCannotClaimPhysicalCompletion() throws {
        let report = try String(contentsOf: root.appendingPathComponent(
            "docs/superpowers/reports/2026-07-17-metering-epoch-phase-5-completion.md"
        ))
        XCTAssertTrue(report.contains("AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE"))
        XCTAssertTrue(report.contains("status_code: AUTOMATED_PASSED_PHYSICAL_PENDING"))
        XCTAssertTrue(report.contains("phase_complete: false"))
        XCTAssertTrue(report.contains("releasable: false"))
        XCTAssertFalse(report.contains("phase_complete: true"))
        XCTAssertFalse(report.contains("releasable: true"))
        XCTAssertEqual(report.components(separatedBy: "| PENDING |").count - 1, 6)
        XCTAssertTrue(report.contains(
            ".superpowers/evidence/metering-phase5/runs/20260720T205012Z-95fa8ed/"
        ))
    }
}
