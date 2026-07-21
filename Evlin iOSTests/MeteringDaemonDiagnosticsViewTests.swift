#if DEBUG
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringDaemonDiagnosticsViewTests: XCTestCase {
    func testSnapshotExposesIdentityProtocolCountsAndLatestMismatch() {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let otherOwner = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let entries = [
            entry(sequence: 3, operation: .readback, namespace: "per_app_v2", result: .mismatch,
                  reasons: ["event.limit.threshold"]),
            entry(sequence: 1, operation: .start, namespace: "per_app_v2", result: .success),
            entry(sequence: 2, operation: .stopAll, namespace: "all", result: .success),
        ]

        let snapshot = MeteringDaemonDiagnosticsSnapshot.make(
            ownerChildDeviceID: owner,
            persistedOwnerChildDeviceID: otherOwner,
            appMode: "child",
            localSelection: .v1,
            entries: entries
        )

        XCTAssertFalse(snapshot.identityReady)
        XCTAssertEqual(snapshot.protocolSelection, "v1")
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.stopAllCount, 1)
        XCTAssertEqual(snapshot.namespaceCounts, [.init(namespace: "per_app_v2", count: 2), .init(namespace: "all", count: 1)])
        XCTAssertEqual(snapshot.latestReadback?.sequence, 3)
        XCTAssertEqual(snapshot.latestReadback?.mismatchReasons, ["event.limit.threshold"])
        XCTAssertEqual(snapshot.entries.map(\.sequence), [3, 2, 1])
    }

    func testManualInspectionRequestsUseLatestExpectedStartPerActivity() {
        let older = entry(
            sequence: 1,
            operation: .start,
            namespace: "per_app_v2",
            result: .success,
            activityName: "evlin.limit.v2.fixture",
            expected: summary(threshold: "minute=1")
        )
        let latest = entry(
            sequence: 4,
            operation: .start,
            namespace: "per_app_v2",
            result: .success,
            activityName: "evlin.limit.v2.fixture",
            expected: summary(threshold: "minute=2")
        )
        let failed = entry(
            sequence: 5,
            operation: .start,
            namespace: "earned",
            result: .failure,
            activityName: "evlin.earned.failed",
            expected: summary(threshold: "minute=5")
        )

        let requests = MeteringDaemonDiagnosticsSnapshot.manualInspectionRequests(
            entries: [latest, failed, older]
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].activityName, "evlin.limit.v2.fixture")
        XCTAssertEqual(requests[0].expected.events.first?.threshold, "minute=2")
        XCTAssertEqual(requests[0].reason, .manual)
    }

    func testDiagnosticViewSourceHasNoMeteringOrLockMutationCalls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS/Views/Debug/MeteringDaemonDiagnosticsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbidden in [
            ".startMonitoring(",
            ".stopMonitoring(",
            "unshieldAll(",
            "applyShield(",
            "resetToday",
        ] {
            XCTAssertFalse(source.contains(forbidden), "read-only diagnostic view contains \(forbidden)")
        }
    }

    func testKidDiagnosticEntryLivesInCommandDeliveryNotParentControls() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let commandDelivery = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift"
            ),
            encoding: .utf8
        )
        let parentControls = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Evlin iOS/Views/Child/BigKid/ParentControlsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(commandDelivery.contains("MeteringDaemonDiagnosticsView()"))
        XCTAssertFalse(parentControls.contains("MeteringDaemonDiagnosticsView()"))
    }

    private func entry(
        sequence: UInt64,
        operation: MeteringDiagnosticOperation,
        namespace: String,
        result: MeteringDiagnosticResult,
        reasons: [String] = [],
        activityName: String? = "evlin.limit.v2.fixture",
        expected: MeteringDaemonConfigurationSummary? = nil
    ) -> MeteringDaemonDiagnosticEntry {
        .init(sequence: sequence, draft: .init(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            process: "app",
            operation: operation,
            activityName: activityName,
            namespace: namespace,
            armID: nil,
            expected: expected,
            actual: nil,
            result: result,
            mismatchReasons: reasons,
            message: nil
        ))
    }

    private func summary(threshold: String) -> MeteringDaemonConfigurationSummary {
        .init(
            schedule: .init(
                intervalStart: "hour=0",
                intervalEnd: "hour=23,minute=59",
                repeats: true,
                warningTime: nil
            ),
            events: [.init(
                name: "limit",
                threshold: threshold,
                includesPastActivity: true,
                applicationTokenDigests: ["token"],
                categoryTokenDigests: [],
                webDomainTokenDigests: []
            )]
        )
    }
}
#endif
