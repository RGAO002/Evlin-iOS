#if DEBUG
import DeviceActivity
import XCTest
@testable import Evlin_iOS

final class MeteringDaemonConfigurationTests: XCTestCase {
    func testIdenticalConfigurationHasNoDifferences() {
        let value = summary()
        XCTAssertEqual(value.differences(from: value), [])
    }

    func testScheduleDimensionsHaveIndependentReasonCodes() {
        let expected = summary()

        XCTAssertEqual(
            summary(start: "hour=1").differences(from: expected),
            ["schedule.interval_start"]
        )
        XCTAssertEqual(
            summary(end: "hour=22").differences(from: expected),
            ["schedule.interval_end"]
        )
        XCTAssertEqual(
            summary(repeats: false).differences(from: expected),
            ["schedule.repeats"]
        )
        XCTAssertEqual(
            summary(warning: "minute=5").differences(from: expected),
            ["schedule.warning_time"]
        )
    }

    func testEventNameAdditionAndRemovalHaveStableReasons() {
        let expected = summary(events: [event(name: "evlin.a")])
        let actual = summary(events: [event(name: "evlin.b")])

        XCTAssertEqual(actual.differences(from: expected), [
            "event.evlin.a.missing",
            "event.evlin.b.unexpected",
        ])
    }

    func testEventDimensionsHaveIndependentReasonCodes() {
        let expected = summary(events: [event()])

        XCTAssertEqual(
            summary(events: [event(threshold: "minute=2")]).differences(from: expected),
            ["event.evlin.test.threshold"]
        )
        XCTAssertEqual(
            summary(events: [event(includesPast: true)]).differences(from: expected),
            ["event.evlin.test.includes_past"]
        )
        XCTAssertEqual(
            summary(events: [event(apps: ["a", "b"])]).differences(from: expected),
            ["event.evlin.test.applications"]
        )
        XCTAssertEqual(
            summary(events: [event(categories: ["c"])]).differences(from: expected),
            ["event.evlin.test.categories"]
        )
        XCTAssertEqual(
            summary(events: [event(webDomains: ["w"])]).differences(from: expected),
            ["event.evlin.test.web_domains"]
        )
    }

    func testTokenDigestOrderDoesNotAffectEquality() {
        let lhs = summary(events: [event(
            apps: ["c", "a", "b"],
            categories: ["z", "y"],
            webDomains: ["2", "1"]
        )])
        let rhs = summary(events: [event(
            apps: ["b", "c", "a"],
            categories: ["y", "z"],
            webDomains: ["1", "2"]
        )])

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.differences(from: rhs), [])
    }

    func testFactoryCapturesCompleteEmptyTokenEvent() {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true,
            warningTime: DateComponents(minute: 2)
        )
        let event = DeviceActivityEvent(
            applications: [],
            categories: [],
            webDomains: [],
            threshold: DateComponents(minute: 1),
            includesPastActivity: false
        )

        let value = MeteringDaemonConfigurationSummary.make(
            schedule: schedule,
            events: [DeviceActivityEvent.Name("evlin.test"): event]
        )

        XCTAssertEqual(value.schedule.intervalStart, "hour=0")
        XCTAssertEqual(value.schedule.intervalEnd, "hour=23,minute=59")
        XCTAssertTrue(value.schedule.repeats)
        XCTAssertEqual(value.schedule.warningTime, "minute=2")
        XCTAssertEqual(value.events.map(\.name), ["evlin.test"])
        XCTAssertEqual(value.events.first?.threshold, "minute=1")
        XCTAssertEqual(value.events.first?.includesPastActivity, false)
        XCTAssertEqual(value.events.first?.applicationTokenDigests, [])
    }

    private func summary(
        start: String = "hour=0",
        end: String = "hour=23,minute=59",
        repeats: Bool = true,
        warning: String? = nil,
        events: [MeteringDaemonConfigurationSummary.Event] = []
    ) -> MeteringDaemonConfigurationSummary {
        MeteringDaemonConfigurationSummary(
            schedule: .init(
                intervalStart: start,
                intervalEnd: end,
                repeats: repeats,
                warningTime: warning
            ),
            events: events
        )
    }

    private func event(
        name: String = "evlin.test",
        threshold: String = "minute=1",
        includesPast: Bool = false,
        apps: [String] = ["a"],
        categories: [String] = [],
        webDomains: [String] = []
    ) -> MeteringDaemonConfigurationSummary.Event {
        .init(
            name: name,
            threshold: threshold,
            includesPastActivity: includesPast,
            applicationTokenDigests: apps,
            categoryTokenDigests: categories,
            webDomainTokenDigests: webDomains
        )
    }
}
#endif
