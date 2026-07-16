#if DEBUG
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringMonitorCapabilityProbeTests: XCTestCase {
    func test_activityNamesRecordOriginSequenceAndRoleInsideProbeNamespace() {
        let stopped = MeteringMonitorCapabilityProbe.activityName(
            origin: "nse",
            sequence: 7,
            role: "stopped"
        )
        let active = MeteringMonitorCapabilityProbe.activityName(
            origin: "dam",
            sequence: 9,
            role: "active"
        )

        XCTAssertEqual(stopped, "evlin.metering.probe.nse.7.stopped")
        XCTAssertEqual(active, "evlin.metering.probe.dam.9.active")
        XCTAssertTrue(MeteringMonitorCapabilityProbe.isProbeActivity(stopped))
        XCTAssertTrue(MeteringMonitorCapabilityProbe.isProbeActivity(active))

        XCTAssertFalse(MeteringMonitorCapabilityProbe.isProbeActivity("evlin.earned.t15"))
        XCTAssertFalse(MeteringMonitorCapabilityProbe.isProbeActivity("evlin.limit.window.rule"))
        XCTAssertFalse(MeteringMonitorCapabilityProbe.isProbeActivity("evlin.command.heartbeat"))
    }

    func test_appendKeepsOnlyLatestThirtyProbeLines() throws {
        let suiteName = "MeteringMonitorCapabilityProbeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 0..<35 {
            MeteringMonitorCapabilityProbe.append("line-\(index)", defaults: defaults)
        }

        let log = try XCTUnwrap(
            defaults.stringArray(forKey: MeteringMonitorCapabilityProbe.logKey)
        )
        XCTAssertEqual(log.count, 30)
        XCTAssertEqual(log.first, "line-5")
        XCTAssertEqual(log.last, "line-34")
    }

    func test_schedulePlanUsesInjectedNowAndCanonicalTimezoneForEveryComponentSet() throws {
        let originalDefault = NSTimeZone.default
        defer { NSTimeZone.default = originalDefault }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = try XCTUnwrap(
            MeteringMonitorCapabilityProbe.schedulePlan(
                origin: "nse",
                sequence: 7,
                now: now,
                canonicalTimezone: "Asia/Tokyo"
            )
        )

        XCTAssertEqual(plan.stoppedActivityName, "evlin.metering.probe.nse.7.stopped")
        XCTAssertEqual(plan.activeActivityName, "evlin.metering.probe.nse.7.active")
        XCTAssertEqual(plan.stoppedStart, now.addingTimeInterval(45))
        XCTAssertEqual(plan.supersededActiveStart, now.addingTimeInterval(30))
        XCTAssertEqual(plan.replacementActiveStart, now.addingTimeInterval(60))
        XCTAssertEqual(plan.end, now.addingTimeInterval(16 * 60))
        XCTAssertEqual(plan.canonicalTimezone, "Asia/Tokyo")
        XCTAssertNotEqual(TimeZone.current.identifier, plan.canonicalTimezone)

        for date in [
            plan.stoppedStart,
            plan.supersededActiveStart,
            plan.replacementActiveStart,
            plan.end,
        ] {
            let components = try XCTUnwrap(plan.dateComponents(for: date))
            XCTAssertEqual(components.timeZone?.identifier, "Asia/Tokyo")
            XCTAssertEqual(components.calendar?.timeZone.identifier, "Asia/Tokyo")
        }
    }

    func test_schedulePlanRejectsUnknownCanonicalTimezone() {
        XCTAssertNil(
            MeteringMonitorCapabilityProbe.schedulePlan(
                origin: "dam",
                sequence: 1,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                canonicalTimezone: "Not/A_Timezone"
            )
        )
    }
}
#endif
