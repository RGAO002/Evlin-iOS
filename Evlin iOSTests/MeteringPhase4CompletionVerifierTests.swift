import XCTest

final class MeteringPhase4CompletionVerifierTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(at relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("required Phase 4 artifact is missing: \(relativePath)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testVerifierDefinesAutomatedReleaseAndImmutableFinalModes() throws {
        let verifier = try text(at: "scripts/verify_metering_phase4.sh")

        XCTAssertTrue(verifier.contains("--automated"))
        XCTAssertTrue(verifier.contains("--release"))
        XCTAssertTrue(verifier.contains("final"))
        XCTAssertTrue(verifier.contains("physical_gate_pending"))
        XCTAssertTrue(verifier.contains("AUTOMATED_PASSED_PHYSICAL_PENDING"))
    }

    func testCanonicalReportCannotClaimPhysicalCompletionOrRelease() throws {
        let report = try text(
            at: "docs/superpowers/reports/2026-07-17-metering-epoch-phase-4-completion.md"
        )

        XCTAssertTrue(report.contains("status_code: AUTOMATED_PASSED_PHYSICAL_PENDING"))
        XCTAssertTrue(report.contains("phase_complete: false"))
        XCTAssertTrue(report.contains("releasable: false"))
        XCTAssertFalse(report.contains("phase_complete: true"))
        XCTAssertFalse(report.contains("releasable: true"))
        XCTAssertGreaterThanOrEqual(report.components(separatedBy: "| PENDING |").count - 1, 4)
    }

    func testReleaseBuilderPinsAllProductionProductsAndWritesHashes() throws {
        let builder = try text(at: "scripts/build_verify_six_release_iphoneos.sh")

        for product in [
            "Evlin iOS.app/Evlin iOS",
            "EvlinDeviceActivityMonitor.appex/EvlinDeviceActivityMonitor",
            "EvlinDeviceActivityReport.appex/EvlinDeviceActivityReport",
            "EvlinShieldConfig.appex/EvlinShieldConfig",
            "EvlinPushApplier.appex/EvlinPushApplier",
            "Evlin iOSTests.xctest/Evlin iOSTests",
        ] {
            XCTAssertTrue(builder.contains(product), "missing Release product: \(product)")
        }
        XCTAssertTrue(builder.contains("shasum -a 256"))
    }
}
