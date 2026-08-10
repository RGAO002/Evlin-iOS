import DeviceActivity
import Foundation

// Extracted from ActionExecutor so extensions can arm DeviceActivity without
// pulling in the whole executor. The NSE needs it to arm per-app limits: a
// force-quit device only ever wakes its extensions, and the extension could
// previously persist a limit but never hand it to Apple, so the limit silently
// did not exist until someone opened the app (2026-08-07).

protocol DeviceActivityScheduling {
    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws
    /// Arm an activity that also measures usage events (the per-app-limit path,
    /// P5). The `events:` dict maps `DeviceActivityEvent.Name` → threshold so
    /// the extension's `eventDidReachThreshold` fires when a budget is reached.
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
    func stopMonitoring()
    /// The activities DeviceActivity currently considers monitored. Lets a
    /// caller (the per-app-limit planner, P5) self-heal from the live set
    /// instead of relying on in-memory state that doesn't survive a fresh
    /// instance or an app restart.
    func monitoredActivities() -> [DeviceActivityName]
}

/// The app's only adapter onto DeviceActivity. Every method here is a
/// SYNCHRONOUS XPC round trip to the Screen Time daemon with no timeout, so any
/// of them parks its thread indefinitely when the daemon does not answer — and
/// on the main thread that is a ten-second watchdog kill. Each one therefore
/// reports itself to `DeviceActivityMainThreadAudit` when it finds itself there,
/// which is how the remaining un-routed call sites get enumerated.
struct DeviceActivityCenterScheduler: DeviceActivityScheduling {
    private let center = DeviceActivityCenter()

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("startMonitoring")
        try center.startMonitoring(name, during: schedule)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("startMonitoring(events:)")
        try center.startMonitoring(activity, during: schedule, events: events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("stopMonitoring(_:)")
        center.stopMonitoring(activities)
    }

    func stopMonitoring() {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("stopMonitoring()")
        center.stopMonitoring()
    }

    func monitoredActivities() -> [DeviceActivityName] {
        // `center.activities` is an XPC read, not a local property — grepping
        // only for start/stopMonitoring undercounts the blocking surface.
        DeviceActivityMainThreadAudit.noteIfOnMainThread("activities")
        return Array(center.activities)
    }
}
