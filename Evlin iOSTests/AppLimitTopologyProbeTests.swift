#if DEBUG
import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitTopologyProbeTests: XCTestCase {
    func testLegacyAndV2PlansDifferOnlyByReservedTopologyNames() throws {
        let now = Date(timeIntervalSince1970: 1_721_600_000)
        let legacy = try AppLimitTopologyProbePlan.make(
            mode: .legacyWindow,
            tokenDigest: "fixture-token",
            now: now,
            timezone: "America/New_York"
        )
        let v2 = try AppLimitTopologyProbePlan.make(
            mode: .v2PerRule,
            tokenDigest: "fixture-token",
            now: now,
            timezone: "America/New_York"
        )

        XCTAssertNotEqual(legacy.activityName, v2.activityName)
        XCTAssertNotEqual(legacy.eventName, v2.eventName)
        XCTAssertEqual(legacy.expected.schedule, v2.expected.schedule)
        XCTAssertEqual(legacy.expected.events.count, 1)
        XCTAssertEqual(v2.expected.events.count, 1)
        XCTAssertEqual(withoutName(legacy.expected.events[0]), withoutName(v2.expected.events[0]))
        XCTAssertEqual(legacy.stopActivityNames, AppLimitTopologyProbePlan.reservedActivityNames)
        XCTAssertEqual(v2.stopActivityNames, AppLimitTopologyProbePlan.reservedActivityNames)
        XCTAssertTrue(legacy.expected.events[0].includesPastActivity)
    }

    func testProbeNeverStopsProductionNamespaces() {
        for name in AppLimitTopologyProbePlan.reservedActivityNames {
            XCTAssertTrue(name.hasPrefix("evlin.debug.topology."))
            XCTAssertFalse(name.hasPrefix("evlin.limit.v2."))
            XCTAssertFalse(name.hasPrefix("evlin.limit.window."))
            XCTAssertFalse(name.hasPrefix("evlin.earned."))
        }
    }

    func testExtensionProbeBranchIsDebugOnlyAndPrecedesProductionRouting() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let eventFunction = try XCTUnwrap(source.range(of: "override func eventDidReachThreshold"))
        let tail = String(source[eventFunction.lowerBound...])
        let debug = try XCTUnwrap(tail.range(of: "#if DEBUG"))
        let probe = try XCTUnwrap(tail.range(of: "evlin.debug.topology."))
        let production = try XCTUnwrap(tail.range(of: "evlin.limit.v2."))

        XCTAssertLessThan(debug.lowerBound, probe.lowerBound)
        XCTAssertLessThan(probe.lowerBound, production.lowerBound)
    }

    private func withoutName(
        _ event: MeteringDaemonConfigurationSummary.Event
    ) -> [String] {
        [
            event.threshold,
            String(event.includesPastActivity),
            event.applicationTokenDigests.joined(separator: ","),
            event.categoryTokenDigests.joined(separator: ","),
            event.webDomainTokenDigests.joined(separator: ","),
        ]
    }
}
#endif
