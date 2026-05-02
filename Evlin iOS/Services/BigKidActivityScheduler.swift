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
}
