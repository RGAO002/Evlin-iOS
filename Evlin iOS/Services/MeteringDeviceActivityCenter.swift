import DeviceActivity

@MainActor
protocol MeteringDeviceActivityCenter {
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

@MainActor
struct SystemMeteringDeviceActivityCenter: MeteringDeviceActivityCenter {
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
