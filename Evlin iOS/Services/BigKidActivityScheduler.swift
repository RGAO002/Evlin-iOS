import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

/// `nonisolated` deliberately: every method here is a synchronous DeviceActivity
/// XPC round trip, and pinned to the main actor they were reachable from
/// BigKidStatePoller's ten-second foreground loop — a watchdog kill on any tick
/// where the Screen Time daemon does not answer. Nothing here holds main-only
/// state; it is a `DeviceActivityCenter` and three name constants, so the
/// isolation was never buying anything. `@unchecked Sendable` covers the center,
/// which Apple does not mark Sendable (same as SystemMeteringDeviceActivityCenter).
///
/// It talks to `DeviceActivityCenter` directly rather than through either
/// adapter, so the audit calls are inline here — otherwise this is a blocking
/// surface no sweep can see.
nonisolated final class BigKidActivityScheduler: @unchecked Sendable {
    static let shared = BigKidActivityScheduler()
    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("evlin.bigkid.freeplay")
    private let eventName = DeviceActivityEvent.Name("evlin.bigkid.chunk")
    private let commandHeartbeatName = DeviceActivityName("evlin.command.heartbeat")

    @discardableResult
    func start(threshold minutes: Int = BigKidTimeReporter.chunkMinutes,
               appsToMeasure: FamilyActivitySelection) -> Bool {
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
        do {
            DeviceActivityMainThreadAudit.noteIfOnMainThread("bigKid.startMonitoring")
            try center.startMonitoring(
                activityName,
                during: schedule,
                events: [eventName: event]
            )
            return true
        } catch {
            NSLog("[Evlin] device_total_arm_FAILED error=%@", error.localizedDescription)
            return false
        }
    }

    func stop() {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("bigKid.stop")
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
        DeviceActivityMainThreadAudit.noteIfOnMainThread("bigKid.heartbeatStart")
        try center.startMonitoring(commandHeartbeatName, during: schedule)
    }

    func stopCommandHeartbeatSpike() {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("bigKid.heartbeatStop")
        center.stopMonitoring([commandHeartbeatName])
    }
}
