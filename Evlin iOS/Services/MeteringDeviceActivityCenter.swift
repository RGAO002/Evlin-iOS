import Foundation
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

/// Every member is a synchronous XPC round trip — including the three that look
/// like plain property/lookup reads (`activities`, `schedule(for:)`,
/// `events(for:)`). Each reports itself to `DeviceActivityMainThreadAudit` when
/// it runs on the main thread; without the read side covered, an audit built
/// around start/stopMonitoring misses most of the blocking surface in this
/// layer, which is exactly where the recovery and watchdog paths live.
struct SystemMeteringDeviceActivityCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private let center: DeviceActivityCenter

    init(center: DeviceActivityCenter = DeviceActivityCenter()) {
        self.center = center
    }

    var activities: [DeviceActivityName] {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("metering.activities")
        return center.activities
    }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("metering.schedule(for:)")
        return center.schedule(for: activity)
    }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("metering.events(for:)")
        return center.events(for: activity)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("metering.startMonitoring")
        try center.startMonitoring(activity, during: schedule, events: events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        DeviceActivityMainThreadAudit.noteIfOnMainThread("metering.stopMonitoring")
        center.stopMonitoring(activities)
    }
}

// The audit lives HERE, not beside either adapter, because this file has the
// widest target membership of the three (app + EvlinPushApplier +
// EvlinDeviceActivityMonitor) and DeviceActivitySchedulingPort's targets are a
// subset of it. Put it anywhere narrower and one target stops compiling — or
// worse, silently goes un-audited.
//
// It stays affordable inside the DeviceActivityMonitor extension's tiny memory
// budget because it does nothing at all unless a call is on the main thread AND
// the site is one it has not seen, which caps the whole process at `siteCap`
// stack captures for its entire lifetime.

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
