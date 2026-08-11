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

    /// `async` because the call it ends in is synchronous DeviceActivity XPC.
    ///
    /// Marking this type `nonisolated` was NOT enough and the earlier commit that
    /// did only that achieved nothing: a synchronous `nonisolated` function runs
    /// on whatever thread called it, and every caller here is `@MainActor`. The
    /// hop lives inside the scheduler so no call site can forget it.
    func schedule(record: ShieldRecord) async throws {
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
        let scheduler = activityScheduler
        let name = DeviceActivityName(record.deviceActivityName)
        let outcome = await MeteringDeviceActivityGateway.perform("reflection.schedule") {
            () -> DeviceActivityScheduleOutcome in
            do {
                try scheduler.startMonitoring(name, during: schedule)
                return .scheduled
            } catch {
                return .schedulerFailed(error.localizedDescription)
            }
        }
        switch outcome {
        case .scheduled:
            return
        case .schedulerFailed(let detail):
            throw DeviceActivitySchedulingFailure.scheduler(detail)
        case nil:
            throw DeviceActivitySchedulingFailure.daemonBusy
        }
    }

    /// `false` means the stop never reached the daemon — the gateway refused
    /// because too many calls are already wedged.
    ///
    /// Callers must not read that as "cancelled". Discarding it let a release or
    /// a swap carry on believing the old activity was gone while it was still
    /// live and, worse, with nothing recorded to retry from: activities that
    /// nobody claims are invisible to the planner's own 20-slot quota check, so
    /// they accumulate until a legitimate arm gets `excessiveActivities`.
    @discardableResult
    func cancel(deviceActivityName: String) async -> Bool {
        let scheduler = activityScheduler
        let name = DeviceActivityName(deviceActivityName)
        return await MeteringDeviceActivityGateway.perform("reflection.cancel") {
            scheduler.stopMonitoring([name])
            return true
        } ?? false
    }
}
