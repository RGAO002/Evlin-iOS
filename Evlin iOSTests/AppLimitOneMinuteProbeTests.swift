import XCTest

final class AppLimitOneMinuteProbeTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(at relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("required one-minute probe artifact is missing: \(relativePath)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testProbeIsDebugOnlyAndUsesProductionCommandComposition() throws {
        let source = try text(
            at: "Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift"
        )

        XCTAssertTrue(source.hasPrefix("#if DEBUG"))
        XCTAssertTrue(source.contains("dailyBudgetMinutes: 1"))
        XCTAssertTrue(source.contains("AppLimitProductionComposition.envelope"))
        XCTAssertTrue(source.contains("AppLimitCommandCoordinator"))
        XCTAssertTrue(source.contains("AppLimitOwnerRecoveryDriver"))
        XCTAssertTrue(source.contains("ActionExecutor.shared.recoverAppLimitOwnerEffect"))
        XCTAssertTrue(source.hasSuffix("#endif\n"))
    }

    func testProbeCannotInjectCallbackTrustOrRuntimeInputs() throws {
        let source = try text(
            at: "Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift"
        )

        for forbidden in [
            "AppLimitCallbackValidator(",
            ".process(",
            ".validate(",
            "DebugAppGroupMeteringClock",
            "debugClockNow",
            "jitterSeconds:",
            "usageCountingAllowed:",
            "ownerProvider:",
            "expectedOwnerProvider:",
        ] {
            XCTAssertFalse(source.contains(forbidden), "forbidden probe seam: \(forbidden)")
        }
    }

    func testProbeExposesRequiredRawReadback() throws {
        let source = try text(
            at: "Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift"
        )

        for label in [
            "arm provenance",
            "includesPastActivity",
            "callback decision / reason",
            "current token / tombstone",
            "shield source",
            "applied receipt",
        ] {
            XCTAssertTrue(source.contains(label), "missing readback: \(label)")
        }
    }

    func testAutomaticRefreshDoesNotReplaceThePickerPresenterIdentity() throws {
        let source = try text(
            at: "Evlin iOS/Components/Debug/AppLimitOneMinuteProbeView.swift"
        )

        XCTAssertTrue(source.contains("refreshTick += 1"))
        XCTAssertFalse(
            source.contains(".id(\"app-limit-one-minute-\\(refreshTick)\")"),
            "Changing a view id every second dismisses the FamilyActivity picker"
        )
    }

    func testPhysicalReportRemainsPending() throws {
        let report = try text(
            at: "docs/superpowers/reports/2026-07-17-metering-phase4-physical.md"
        )

        XCTAssertTrue(report.contains("Status: PENDING"))
        XCTAssertGreaterThanOrEqual(
            report.components(separatedBy: "| PENDING |").count - 1,
            4
        )
        XCTAssertFalse(report.contains("Status: PASS"))
        XCTAssertFalse(report.contains("phase_complete: true"))
        XCTAssertFalse(report.contains("releasable: true"))
    }
}
