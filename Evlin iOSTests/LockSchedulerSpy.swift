import DeviceActivity
@testable import Evlin_iOS

/// Internal (NOT private) so multiple test files can share it. Mirrors the
/// private spy in ActionExecutorTests; do not modify that one.
final class LockSchedulerSpy: DeviceActivityScheduling {
    private(set) var started: [(name: DeviceActivityName, schedule: DeviceActivitySchedule)] = []
    private(set) var stopped: [[DeviceActivityName]?] = []
    var errorToThrow: Error?            // set non-nil to simulate a DAM scheduling failure
    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        if let e = errorToThrow { throw e }
        started.append((name, schedule))
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) { stopped.append(activities) }
    func stopMonitoring() { stopped.append(nil) }
}
