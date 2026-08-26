#if DEBUG
import DeviceActivity
import Foundation
import XCTest
@testable import Evlin_iOS

final class DiagnosticDeviceActivitySchedulerTests: XCTestCase {
    func testDebugDefaultSchedulerUsesDiagnosticDecorator() {
        XCTAssertTrue(makeDefaultDeviceActivityScheduler() is DiagnosticDeviceActivityScheduler)
    }

    func testEventStartDelegatesOnceRecordsSuccessAndQueuesExactReadback() async throws {
        let fixture = makeFixture()
        fixture.readback.value = fixture.expected

        try fixture.scheduler.startMonitoring(
            fixture.activity,
            during: fixture.schedule,
            events: fixture.events
        )
        try await waitUntil { fixture.journal.read().count == 2 }

        XCTAssertEqual(fixture.base.calls, [.startEvents(fixture.activity.rawValue)])
        let entries = fixture.journal.read()
        XCTAssertEqual(entries.map(\.operation), [.start, .readback])
        XCTAssertEqual(entries.map(\.result), [.success, .match])
        XCTAssertEqual(entries[0].expected, fixture.expected)
        XCTAssertEqual(entries[1].actual, fixture.expected)
    }

    func testThrownStartErrorPropagatesAndDoesNotQueueReadback() async {
        let fixture = makeFixture()
        fixture.base.error = ProbeError.failed

        XCTAssertThrowsError(try fixture.scheduler.startMonitoring(
            fixture.activity,
            during: fixture.schedule,
            events: fixture.events
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fixture.base.calls, [.startEvents(fixture.activity.rawValue)])
        XCTAssertEqual(fixture.readback.callCount, 0)
        XCTAssertEqual(fixture.journal.read().map(\.result), [.failure])
    }

    func testNoEventStartAndNamedStopDelegateExactlyOnce() throws {
        let fixture = makeFixture()

        try fixture.scheduler.startMonitoring(fixture.activity, during: fixture.schedule)
        fixture.scheduler.stopMonitoring([fixture.activity])

        XCTAssertEqual(fixture.base.calls, [
            .start(fixture.activity.rawValue),
            .stop([fixture.activity.rawValue]),
        ])
        XCTAssertEqual(fixture.journal.read().map(\.operation), [.start, .stopNames])
    }

    func testParentUnlockExpiryUsesDedicatedDiagnosticNamespace() throws {
        let fixture = makeFixture()
        let expiry = DeviceActivityName(
            "evlin.parent-unlock-expiry.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.7"
        )

        try fixture.scheduler.startMonitoring(expiry, during: fixture.schedule)

        XCTAssertEqual(fixture.journal.read().last?.namespace, "parent_unlock_expiry")
    }

    func testGlobalStopIsRecordedAsHighSeverityAndDelegated() {
        let fixture = makeFixture()

        fixture.scheduler.stopMonitoring()

        XCTAssertEqual(fixture.base.calls, [.stopAll])
        let entry = fixture.journal.read().first
        XCTAssertEqual(entry?.operation, .stopAll)
        XCTAssertTrue(entry?.message?.contains("high_severity") == true)
    }

    private func makeFixture() -> SchedulerFixture {
        let suiteName = "DiagnosticDeviceActivitySchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let journal = MeteringDaemonDiagnosticJournal(defaults: defaults)
        let base = SchedulingSpy()
        let readback = SchedulerReadbackSpy()
        let inspector = MeteringDaemonInspector(readback: readback, journal: journal)
        let scheduler = DiagnosticDeviceActivityScheduler(
            base: base,
            journal: journal,
            inspector: inspector,
            process: "app"
        )
        let activity = DeviceActivityName(
            "evlin.limit.v2.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let events = [
            DeviceActivityEvent.Name("evlin.limit.v2.fixture.budget"): DeviceActivityEvent(
                applications: [],
                categories: [],
                webDomains: [],
                threshold: DateComponents(minute: 1),
                includesPastActivity: false
            ),
        ]
        return SchedulerFixture(
            scheduler: scheduler,
            base: base,
            readback: readback,
            journal: journal,
            activity: activity,
            schedule: schedule,
            events: events,
            expected: .make(schedule: schedule, events: events)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw ProbeError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct SchedulerFixture {
    let scheduler: DiagnosticDeviceActivityScheduler
    let base: SchedulingSpy
    let readback: SchedulerReadbackSpy
    let journal: MeteringDaemonDiagnosticJournal
    let activity: DeviceActivityName
    let schedule: DeviceActivitySchedule
    let events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    let expected: MeteringDaemonConfigurationSummary
}

private enum ProbeError: Error {
    case failed
    case timeout
}

private final class SchedulingSpy: DeviceActivityScheduling {
    enum Call: Equatable {
        case start(String)
        case startEvents(String)
        case stop([String])
        case stopAll
    }

    var error: Error?
    private(set) var calls: [Call] = []

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        calls.append(.start(name.rawValue))
        if let error { throw error }
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        calls.append(.startEvents(activity.rawValue))
        if let error { throw error }
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        calls.append(.stop(activities.map(\.rawValue)))
    }

    func stopMonitoring() { calls.append(.stopAll) }
    func monitoredActivities() -> [DeviceActivityName] { [] }
}

private final class SchedulerReadbackSpy: MeteringDaemonReadbackPort, @unchecked Sendable {
    var value: MeteringDaemonConfigurationSummary?
    private(set) var callCount = 0

    func configuration(activityName: String) throws -> MeteringDaemonConfigurationSummary? {
        callCount += 1
        return value
    }
}
#endif
