import Foundation
import DeviceActivity

/// Schedules / cancels a record's DeviceActivityMonitor auto-removal by its
/// `deviceActivityName`. Standalone + injectable so the reflection reconciler
/// (and tests) can drive it without going through ActionExecutor.
/// `nonisolated` deliberately: both members end in synchronous DeviceActivity
/// XPC through the injected adapter, and this type is reached from
/// BigKidStatePoller's reflection reconciler on the main actor. It holds nothing
/// but that adapter, so the project-wide MainActor default was pure cost.
nonisolated struct LockScheduler: Sendable {
    private let activityScheduler: DeviceActivityScheduling
    private static let minScheduleMinutes = 15   // DeviceActivity practical floor

    init(activityScheduler: DeviceActivityScheduling) {
        self.activityScheduler = activityScheduler
    }

    func schedule(record: ShieldRecord) throws {
        guard let expiresAt = record.expiresAt else { return }   // permanent → no schedule
        let now = Date()
        let minInterval = TimeInterval(Self.minScheduleMinutes * 60)
        let clampedEnd = expiresAt.timeIntervalSince(now) < minInterval
            ? now.addingTimeInterval(minInterval) : expiresAt
        let cal = Calendar.current
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents([.hour, .minute, .second], from: now),
            intervalEnd: cal.dateComponents([.hour, .minute, .second], from: clampedEnd),
            repeats: false)
        try activityScheduler.startMonitoring(
            DeviceActivityName(record.deviceActivityName), during: schedule)
    }

    func cancel(deviceActivityName: String) {
        activityScheduler.stopMonitoring([DeviceActivityName(deviceActivityName)])
    }
}
