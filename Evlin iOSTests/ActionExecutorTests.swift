import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

final class ActionExecutorTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.blockRecords")
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.shieldRecords")
    }

    func testTimedBlockRequestsAutoUnblockSchedule() async {
        let spy = DeviceActivitySchedulerSpy()
        let executor = ActionExecutor(
            activityScheduler: spy,
            authorizationStatusProvider: { .approved }
        )
        let command = makeBlockCommand(bundleID: "com.burbn.instagram", minutes: 15)

        _ = await executor.execute(command)

        XCTAssertEqual(spy.started.count, 1)
        XCTAssertTrue(spy.started[0].name.rawValue.hasPrefix("evlin.block."))
    }

    private func makeBlockCommand(bundleID: String, minutes: Int) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .block,
            tier: .exactApp,
            target: CommandTarget(
                bundleID: bundleID,
                originalRequest: "block Instagram",
                targetDisplay: "Instagram",
                targetChildID: UUID()
            ),
            durationMinutes: minutes,
            issuedAt: Date()
        )
    }
}

private final class DeviceActivitySchedulerSpy: DeviceActivityScheduling {
    private(set) var started: [(name: DeviceActivityName, schedule: DeviceActivitySchedule)] = []
    private(set) var stopped: [[DeviceActivityName]?] = []

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        started.append((name, schedule))
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopped.append(activities)
    }

    func stopMonitoring() {
        stopped.append(nil)
    }
}
