import DeviceActivity
import Foundation
import XCTest
@testable import Evlin_iOS

private struct FixedMeteringClock: MeteringClock {
    let date: Date

    var now: Date { date }
}

private nonisolated struct FakeCenter: MeteringDeviceActivityCenter {
    var activities: [DeviceActivityName] = []

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { nil }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { [:] }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {}

    func stopMonitoring(_ activities: [DeviceActivityName]) {}
}

@MainActor
final class MeteringRuntimeInfrastructureTests: XCTestCase {
    private let expectedDate = Date(timeIntervalSince1970: 1_784_179_200)

    func testFixedClockReturnsItsInjectedDate() {
        let clock: any MeteringClock = FixedMeteringClock(date: expectedDate)

        XCTAssertEqual(clock.now, expectedDate)
    }

    func testDebugAppGroupClockReadsPinnedDate() {
        let suiteName = "MeteringRuntimeInfrastructureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defer { defaults?.removePersistentDomain(forName: suiteName) }
        defaults?.set("2026-07-16T12:00:00Z", forKey: DebugAppGroupMeteringClock.preferenceKey)
        let expected = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!

        let clock = DebugAppGroupMeteringClock(
            defaults: defaults,
            fallback: FixedMeteringClock(date: expectedDate)
        )

        XCTAssertEqual(clock.now, expected)
    }

    func testDebugAppGroupClockFallsBackToInjectedClock() {
        let clock = DebugAppGroupMeteringClock(
            defaults: nil,
            fallback: FixedMeteringClock(date: expectedDate)
        )

        XCTAssertEqual(clock.now, expectedDate)
    }

    func testSystemClockConformsToMeteringClock() {
        let clock: any MeteringClock = SystemMeteringClock()

        XCTAssertLessThanOrEqual(clock.now.timeIntervalSinceNow, 0)
    }

    func testRuntimeClockProducesAMeteringClock() {
        let clock = MeteringRuntimeClock.live(defaults: nil)

        XCTAssertLessThanOrEqual(clock.now.timeIntervalSinceNow, 0)
    }

    func testValueFakeConformsToMeteringDeviceActivityCenter() {
        let expected = DeviceActivityName("evlin.metering.fake")
        let center: any MeteringDeviceActivityCenter = FakeCenter(activities: [expected])

        XCTAssertEqual(center.activities, [expected])
        XCTAssertNil(center.schedule(for: expected))
        XCTAssertTrue(center.events(for: expected).isEmpty)
    }

    func testDebugPreferenceKeyIsInsideDebugConditional() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Evlin iOS/Services/MeteringRuntimeInfrastructure.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let debugStart = try XCTUnwrap(source.range(of: "#if DEBUG"))
        let debugEnd = try XCTUnwrap(source.range(of: "#endif", range: debugStart.upperBound..<source.endIndex))
        let preferenceKey = "evlin.metering.debugClockNow"

        XCTAssertFalse(source[..<debugStart.lowerBound].contains(preferenceKey))
        XCTAssertTrue(source[debugStart.lowerBound..<debugEnd.upperBound].contains(preferenceKey))
        XCTAssertFalse(source[debugEnd.upperBound...].contains(preferenceKey))
    }
}
