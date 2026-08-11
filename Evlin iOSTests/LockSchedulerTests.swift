import XCTest
import DeviceActivity
@testable import Evlin_iOS

final class LockSchedulerTests: XCTestCase {
    func testScheduleUsesRecordDeviceActivityNameAndNoRepeat() async throws {
        let spy = LockSchedulerSpy()
        let sched = LockScheduler(activityScheduler: spy)
        let rid = UUID()
        let rec = ShieldRecord(                       // inline — do NOT depend on Task 7's factory
            recordKey: "all:reflection:\(rid.uuidString)", tier: .all,
            targetKey: "reflection:\(rid.uuidString)", displayName: "Reflection lock",
            lastCommandID: UUID(), appTokens: [], categoryTokens: [], webDomainTokens: [],
            appliesToAll: true, issuedAt: Date(), expiresAt: Date().addingTimeInterval(20*60),
            originalRequest: "reflection lockdown", targetChildID: UUID())
        try await sched.schedule(record: rec)
        XCTAssertEqual(spy.started.count, 1)
        XCTAssertEqual(spy.started.first?.name.rawValue, rec.deviceActivityName)
        XCTAssertFalse(spy.started.first!.schedule.repeats)
    }
    func testCancelStopsByName() async {
        let spy = LockSchedulerSpy()
        let sched = LockScheduler(activityScheduler: spy)
        await sched.cancel(deviceActivityName: "evlin.shield.abc")
        XCTAssertEqual(spy.stopped.count, 1)
    }
}
