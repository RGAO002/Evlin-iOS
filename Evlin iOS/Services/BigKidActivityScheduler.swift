import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

@MainActor
final class BigKidActivityScheduler {
    static let shared = BigKidActivityScheduler()
    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("evlin.bigkid.freeplay")
    private let eventName = DeviceActivityEvent.Name("evlin.bigkid.chunk")
    private let commandHeartbeatName = DeviceActivityName("evlin.command.heartbeat")

    func start(threshold minutes: Int = BigKidTimeReporter.chunkMinutes,
               appsToMeasure: FamilyActivitySelection) {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(
            applications: appsToMeasure.applicationTokens,
            categories: appsToMeasure.categoryTokens,
            webDomains: appsToMeasure.webDomainTokens,
            threshold: DateComponents(minute: minutes)
        )
        try? center.startMonitoring(activityName,
                                    during: schedule,
                                    events: [eventName: event])
    }

    func stop() {
        center.stopMonitoring([activityName])
    }

    func startCommandHeartbeatSpike(delaySeconds: TimeInterval = 120) throws {
        let calendar = Calendar.current
        let start = Date().addingTimeInterval(delaySeconds)
        let end = start.addingTimeInterval(15 * 60)
        let components: Set<Calendar.Component> = [
            .calendar, .timeZone, .year, .month, .day, .hour, .minute, .second
        ]
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: start),
            intervalEnd: calendar.dateComponents(components, from: end),
            repeats: false
        )
        try center.startMonitoring(commandHeartbeatName, during: schedule)
    }

    func stopCommandHeartbeatSpike() {
        center.stopMonitoring([commandHeartbeatName])
    }
}
