import DeviceActivity
@testable import Evlin_iOS

/// Internal (NOT private) so multiple test files can share it. Mirrors the
/// private spy in ActionExecutorTests; do not modify that one.
final class LockSchedulerSpy: DeviceActivityScheduling {
    private(set) var started: [(name: DeviceActivityName, schedule: DeviceActivitySchedule)] = []
    private(set) var startedWithEvents: [(name: DeviceActivityName, schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])] = []
    private(set) var stopped: [[DeviceActivityName]?] = []
    /// Live set of activities currently considered armed — added on a successful
    /// startMonitoring, removed on stop. Backs `monitoredActivities()` so a spy
    /// shared across two planner instances reports the live set (self-healing).
    private(set) var activeActivities: Set<DeviceActivityName> = []
    var errorToThrow: Error?            // set non-nil to simulate a DAM scheduling failure
    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        if let e = errorToThrow { throw e }
        started.append((name, schedule))
        activeActivities.insert(name)
    }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        if let e = errorToThrow { throw e }
        startedWithEvents.append((activity, schedule, events))
        activeActivities.insert(activity)
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopped.append(activities)
        for a in activities { activeActivities.remove(a) }
    }
    func stopMonitoring() {
        stopped.append(nil)
        activeActivities.removeAll()
    }
    func monitoredActivities() -> [DeviceActivityName] { Array(activeActivities) }
}
