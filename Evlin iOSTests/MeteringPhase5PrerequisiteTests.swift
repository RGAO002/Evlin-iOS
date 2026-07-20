import Foundation
import XCTest

final class MeteringPhase5PrerequisiteTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testHostVerifierOwnsFailClosedFixtureMatrix() throws {
        let verifier = try text("scripts/verify_metering_phase5_prerequisites.sh")
        for marker in [
            "--self-test",
            "phase3_completion_report_missing",
            "phase3_attestation_missing",
            "phase4_completion_report_missing",
            "phase4_attestation_missing",
            "phase4_contract_missing",
            "phase4_release_builder_missing",
            "push_monitor_owner_forbidden",
            "physical_status=PENDING",
        ] {
            XCTAssertTrue(verifier.contains(marker), "missing verifier gate: \(marker)")
        }
    }

    func testCanonicalHandoffsRemainAutomatedPendingAndNotReleasable() throws {
        for path in [
            "docs/superpowers/reports/2026-07-17-metering-epoch-phase-3-completion.md",
            "docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md",
        ] {
            let report = try text(path)
            XCTAssertTrue(report.contains("AUTOMATED PASSED; PHYSICAL PENDING; NOT RELEASABLE"))
            XCTAssertTrue(report.contains("phase_complete: false"))
            XCTAssertTrue(report.contains("releasable: false"))
        }
    }

    func testProductionContractsAndConservativeDecisionArePresent() throws {
        let capability = try text(
            "docs/superpowers/research/2026-07-15-metering-monitor-capability-results.md"
        )
        XCTAssertTrue(capability.contains("not proven / conservative branch"))

        let services = repositoryRoot.appendingPathComponent("Evlin iOS/Services")
        let production = try FileManager.default.contentsOfDirectory(
            at: services,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
        for symbol in [
            "AppLimitCommandEnvelope",
            "AppLimitCommandDisposition",
            "AppLimitVersionSlot",
            "AppLimitEpochStore",
            "clearTombstone",
        ] {
            XCTAssertTrue(production.contains(symbol), "missing Phase 4 contract: \(symbol)")
        }
    }
}
