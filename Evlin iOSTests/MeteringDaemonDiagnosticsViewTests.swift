#if DEBUG
import FamilyControls
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

    func testManualInspectionRequestsIncludeActiveEarnedRouteWithoutStartJournal() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let start = Date(timeIntervalSince1970: 1_768_665_600)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-daemon-view-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
        let key = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "diagnostic-fixture",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: UUID()
        )
        let plan = try store.reconcileMeteringHorizon(.init(
            ownerChildDeviceID: owner,
            today: "2026-01-17",
            generationKey: key,
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: start
        ))
        let routeID = try XCTUnwrap(plan.routeIDsByUsageDate["2026-01-17"])
        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = plan.generationID
            state.activeEpochID = state.routes[routeID]?.epochID
            state.activeRouteID = routeID
            state.routes[routeID]?.lifecycle = .active
        }
        let state = try store.read()
        let activityName = try XCTUnwrap(state.routes[routeID]?.activityName)

        let requests = MeteringDaemonDiagnosticsSnapshot.manualInspectionRequests(
            entries: [],
            ownerChildDeviceID: owner,
            state: state
        )

        let request = try XCTUnwrap(requests.first { $0.activityName == activityName })
        XCTAssertEqual(request.namespace, MeteringRouteNamespace.prefix)
        XCTAssertEqual(request.reason, .manual)
        XCTAssertEqual(request.expected.events.count, 12)
        XCTAssertTrue(request.expected.events.contains { $0.threshold == "minute=5" })
        XCTAssertTrue(request.expected.events.contains { $0.threshold == "minute=60" })
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

    func testCommandDeliveryResetStopsOnlyStaleEarnedActivities() {
        let desired = "evlin.earned.budget.current"
        let staleLegacy = "evlin.earned.budget"
        let staleGenerated = "evlin.earned.budget.stale"
        let perApp = "evlin.limit.v2.rule"
        let commandHeartbeat = "evlin.command.heartbeat"

        let stopped = CommandDeliveryMeteringRepair.staleEarnedActivityNames(
            liveActivityNames: Set([
                desired,
                staleLegacy,
                staleGenerated,
                perApp,
                commandHeartbeat,
            ]),
            desiredEarnedActivityNames: Set([desired])
        )

        XCTAssertEqual(stopped, [staleLegacy, staleGenerated])
    }

    func testCommandDeliveryResetStopsStaleV2EarnedActivityButPreservesDesiredRoute() {
        let desired = "evlin.earned.v2.11111111-1111-1111-1111-111111111111"
        let stale = "evlin.earned.v2.22222222-2222-2222-2222-222222222222"
        let perApp = "evlin.limit.v2.33333333-3333-3333-3333-333333333333"

        let stopped = CommandDeliveryMeteringRepair.staleEarnedActivityNames(
            liveActivityNames: Set([desired, stale, perApp]),
            desiredEarnedActivityNames: Set([desired])
        )

        XCTAssertEqual(stopped, [stale])
    }

    func testCommandDeliveryContainsDebugOnlyMeteringRepairAction() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Evlin iOS/Components/Debug/CommandDeliveryDiagnosticsView.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Repair metering activities"))
        XCTAssertTrue(source.contains("CommandDeliveryMeteringRepair.run()"))
        XCTAssertTrue(source.contains("#if DEBUG"))
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
