#if DEBUG
import Foundation
import XCTest
@testable import Evlin_iOS

final class MeteringDaemonInspectorTests: XCTestCase {
    func testConcurrentRequestsCoalesceAndReadbackRunsOffMain() async throws {
        let fixture = makeFixture()
        fixture.port.delay = 0.15
        fixture.port.value = fixture.expected

        async let first: Void = fixture.inspector.request(request(reason: .afterArm, expected: fixture.expected))
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second: Void = fixture.inspector.request(request(reason: .afterArm, expected: fixture.expected))
        _ = await (first, second)

        XCTAssertEqual(fixture.port.callCount, 1)
        XCTAssertEqual(fixture.port.observedMainThread, [false])
        XCTAssertEqual(fixture.journal.read().map(\.result), [.match])
    }

    func testAuditIsLimitedButEventDrivenRequestBypassesInterval() async {
        let fixture = makeFixture()
        fixture.port.value = fixture.expected

        await fixture.inspector.request(request(reason: .audit, expected: fixture.expected))
        fixture.clock.date = fixture.clock.date.addingTimeInterval(299)
        await fixture.inspector.request(request(reason: .audit, expected: fixture.expected))
        await fixture.inspector.request(request(reason: .configurationChanged, expected: fixture.expected))
        fixture.clock.date = fixture.clock.date.addingTimeInterval(1)
        await fixture.inspector.request(request(reason: .audit, expected: fixture.expected))

        XCTAssertEqual(fixture.port.callCount, 3)
    }

    func testReadbackRecordsMissingMismatchMatchAndFailure() async {
        let fixture = makeFixture()

        fixture.port.value = nil
        await fixture.inspector.request(request(reason: .manual, expected: fixture.expected))

        fixture.port.value = summary(repeats: false)
        await fixture.inspector.request(request(reason: .manual, expected: fixture.expected))

        fixture.port.value = fixture.expected
        await fixture.inspector.request(request(reason: .manual, expected: fixture.expected))

        fixture.port.error = ProbeError.failed
        await fixture.inspector.request(request(reason: .manual, expected: fixture.expected))

        let entries = fixture.journal.read()
        XCTAssertEqual(entries.map(\.result), [.missing, .mismatch, .match, .failure])
        XCTAssertEqual(entries[1].mismatchReasons, ["schedule.repeats"])
        XCTAssertTrue(entries[3].message?.contains("failed") == true)
    }

    func testFailureDoesNotSuppressLaterAuditRetry() async {
        let fixture = makeFixture()
        fixture.port.error = ProbeError.failed
        await fixture.inspector.request(request(reason: .audit, expected: fixture.expected))

        fixture.port.error = nil
        fixture.port.value = fixture.expected
        await fixture.inspector.request(request(reason: .audit, expected: fixture.expected))

        XCTAssertEqual(fixture.port.callCount, 2)
        XCTAssertEqual(fixture.journal.read().map(\.result), [.failure, .match])
    }

    private func makeFixture() -> Fixture {
        let suiteName = "MeteringDaemonInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let journal = MeteringDaemonDiagnosticJournal(defaults: defaults)
        let port = ReadbackSpy()
        let clock = TestClock(Date(timeIntervalSince1970: 1_721_600_000))
        let inspector = MeteringDaemonInspector(
            readback: port,
            journal: journal,
            now: { clock.date },
            auditInterval: 300
        )
        return Fixture(
            inspector: inspector,
            port: port,
            journal: journal,
            clock: clock,
            expected: summary()
        )
    }

    private func request(
        reason: MeteringDaemonInspectionReason,
        expected: MeteringDaemonConfigurationSummary
    ) -> MeteringDaemonInspectionRequest {
        .init(
            reason: reason,
            process: "app",
            activityName: "evlin.limit.v2.fixture",
            namespace: "per_app_v2",
            armID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            expected: expected
        )
    }

    private func summary(repeats: Bool = true) -> MeteringDaemonConfigurationSummary {
        .init(
            schedule: .init(
                intervalStart: "hour=0",
                intervalEnd: "hour=23,minute=59",
                repeats: repeats,
                warningTime: nil
            ),
            events: []
        )
    }
}

private struct Fixture {
    let inspector: MeteringDaemonInspector
    let port: ReadbackSpy
    let journal: MeteringDaemonDiagnosticJournal
    let clock: TestClock
    let expected: MeteringDaemonConfigurationSummary
}

private enum ProbeError: Error {
    case failed
}

private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class ReadbackSpy: MeteringDaemonReadbackPort, @unchecked Sendable {
    private let lock = NSLock()
    var value: MeteringDaemonConfigurationSummary?
    var error: Error?
    var delay: TimeInterval = 0
    private(set) var callCount = 0
    private(set) var observedMainThread: [Bool] = []

    func configuration(activityName: String) throws -> MeteringDaemonConfigurationSummary? {
        lock.lock()
        callCount += 1
        observedMainThread.append(Thread.isMainThread)
        let currentDelay = delay
        let currentError = error
        let currentValue = value
        lock.unlock()
        if currentDelay > 0 { Thread.sleep(forTimeInterval: currentDelay) }
        if let currentError { throw currentError }
        return currentValue
    }
}
#endif
