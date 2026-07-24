import DeviceActivity

// nonisolated (NOT @MainActor): every call here is a synchronous XPC round
// trip to the DeviceActivity daemon. Pinning them to the main actor made the
// coverage-refresh loop block the main thread long enough to trip the
// FrontBoard scene-update watchdog (0x8badf00d). Apple's DeviceActivityCenter
// is safe to call off the main thread, so the recovery driver runs this work
// on a detached background task.
nonisolated protocol MeteringDeviceActivityCenter: Sendable {
    var activities: [DeviceActivityName] { get }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule?
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent]
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
}

struct SystemMeteringDeviceActivityCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private let center: DeviceActivityCenter

    init(center: DeviceActivityCenter = DeviceActivityCenter()) {
        self.center = center
    }

    var activities: [DeviceActivityName] {
        center.activities
    }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        center.schedule(for: activity)
    }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        center.events(for: activity)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        try center.startMonitoring(activity, during: schedule, events: events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        center.stopMonitoring(activities)
    }
}
