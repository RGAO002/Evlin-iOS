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

// NOTE: kept in this file rather than its own. This file is compiled into the
// app extensions as well as the app, and a separate file would have to be added
// to each target by hand — a missing membership shows up as a build error at
// best and a silently un-audited extension at worst.
/// Records DeviceActivity calls that ran on the main thread.
///
/// Every one of these is a watchdog kill waiting to happen. `startMonitoring`,
/// `stopMonitoring` and the `activities` read are synchronous XPC to the Screen
/// Time daemon with no timeout, so a daemon that does not answer parks the
/// calling thread indefinitely — and on the main thread that is
/// `0x8BADF00D scene-update watchdog transgression` in ten seconds flat
/// (2026-08-08, iPhone XS Max: 0.02s of CPU burned, killed while blocked in
/// `mach_msg` under `startMonitoring`).
///
/// **Record-only, deliberately.** A `fatalError` or `assertionFailure` stops at
/// the first offender, and the whole point of this audit is to enumerate ALL of
/// them from a single run over the real app. It is also why this is not
/// `#if DEBUG`: the paths most likely to be wrong are the ones that only run on
/// a real device off a real push, and those need a TestFlight build to reach.
/// Once the enumeration is closed out, a hard trap can replace this as a
/// permanent regression guard — alongside a static scan, since a dynamic sweep
/// cannot reach code that did not happen to run.
///
/// Writes at most one entry per distinct call site, so a hot loop costs a set
/// lookup rather than a defaults write.
nonisolated enum DeviceActivityMainThreadAudit {
    /// App Group key holding the accumulated sites, oldest first.
    static let defaultsKey = "evlin.deviceActivity.mainThreadSites"

    private static let siteCap = 40
    private static let lock = NSLock()
    private static var seenSites: Set<String> = []

    /// Call at the top of every DeviceActivity XPC wrapper.
    static func noteIfOnMainThread(_ api: String) {
        guard Thread.isMainThread else { return }
        let site = "\(api)|\(callerSignature())"
        lock.lock()
        let isNew = seenSites.insert(site).inserted
        let overCap = seenSites.count > siteCap
        lock.unlock()
        guard isNew, !overCap else { return }
        persist(site)
    }

    /// Everything recorded so far, for a debug screen or a `devicectl` pull.
    static func recordedSites() -> [String] {
        defaults?.stringArray(forKey: defaultsKey) ?? []
    }

    static func reset() {
        lock.lock()
        seenSites.removeAll()
        lock.unlock()
        defaults?.removeObject(forKey: defaultsKey)
    }

    // MARK: - Internals

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.evlin.ios")
    }

    /// The first frames above this file. Unsymbolicated addresses are fine — the
    /// binary and its dSYM are archived together, and `atos` turns them back
    /// into a call site. Only runs on the offending path, so its cost is paid
    /// exactly where we already have a ten-second budget problem.
    private static func callerSignature() -> String {
        Thread.callStackSymbols
            .drop(while: { $0.contains("DeviceActivityMainThreadAudit") })
            .prefix(6)
            .map { frame in
                // "  3  Evlin iOS  0x000000010a1b2c3d Foo.bar() + 42" → "Foo.bar() + 42"
                frame
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .dropFirst(3)
                    .joined(separator: " ")
            }
            .joined(separator: " < ")
    }

    private static func persist(_ site: String) {
        guard let defaults else { return }
        var sites = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !sites.contains(site) else { return }
        sites.append("\(ISO8601DateFormatter().string(from: Date())) \(site)")
        if sites.count > siteCap { sites.removeFirst(sites.count - siteCap) }
        defaults.set(sites, forKey: defaultsKey)
    }
}
