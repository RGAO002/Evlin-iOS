import Foundation

/// The one way the app target should reach DeviceActivity's synchronous XPC.
///
/// Why it exists: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` plus
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES` means `nonisolated` buys nothing for
/// escaping the main thread — a `nonisolated` sync function runs inline on the
/// caller's thread, and a `nonisolated async` one inherits the caller's
/// executor. The only construct that actually leaves the main thread is an
/// explicit `Task.detached`, and forgetting it is invisible: the annotation
/// looks like it did the job. That is how the 2026-08-08 kill shipped.
///
/// **Not a serial queue or an actor, on purpose.** These calls can block
/// forever, and a single wedged call behind a serialising gate would take every
/// later one down with it — trading one dead arm for a permanently dead
/// subsystem. Each call gets its own detached task and they proceed in parallel.
///
/// **Nothing may hold a lock across `perform`.** A wedged thread keeps whatever
/// it holds, and the persistence lock is a cross-process `flock` the
/// DeviceActivityMonitor extension needs — starving it is a silent enforcement
/// outage, which for parental controls is worse than a crash.
nonisolated enum MeteringDeviceActivityGateway {
    /// Ceiling on concurrently in-flight daemon calls.
    ///
    /// A timeout cannot rescue a thread already inside `mach_msg` — Swift
    /// cancellation is cooperative and there is no cancellation point inside
    /// `xpc_connection_send_message_with_reply_sync`. So wedged threads only
    /// accumulate. This bounds how many can pile up before the thread pool is
    /// the next thing to fail; it is damage limitation, not recovery.
    static let maxInFlight = 4

    /// App Group key recording refusals, so a stuck daemon leaves evidence
    /// instead of looking like "nothing happened".
    static let refusalKey = "evlin.deviceActivity.gatewayRefusals"

    private static let lock = NSLock()
    private static var inFlight = 0

    /// Runs `body` off the main thread, holding no lock.
    ///
    /// Returns `nil` when too many calls are already wedged. Callers must treat
    /// that as a failure to arm — never as success, and never as a reason to
    /// apply a shield: refusing to measure is not the same as knowing the child
    /// is out of time, and locking on a daemon hiccup would take away allowance
    /// the parent already granted.
    static func perform<T: Sendable>(
        _ api: StaticString,
        _ body: @escaping @Sendable () -> T
    ) async -> T? {
        guard reserveSlot() else {
            recordRefusal(api)
            return nil
        }
        defer { releaseSlot() }
        return await Task.detached(priority: .utility) { body() }.value
    }

    /// In-flight count, for diagnostics screens.
    static func inFlightCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    static func recordedRefusals() -> [String] {
        defaults?.stringArray(forKey: refusalKey) ?? []
    }

    // MARK: - Internals

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.evlin.ios")
    }

    private static func reserveSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < maxInFlight else { return false }
        inFlight += 1
        return true
    }

    private static func releaseSlot() {
        lock.lock()
        defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
    }

    private static func recordRefusal(_ api: StaticString) {
        guard let defaults else { return }
        var entries = defaults.stringArray(forKey: refusalKey) ?? []
        let stamp = ISO8601DateFormatter().string(from: Date())
        entries.append("\(stamp) \(api) inFlight=\(inFlightCount())")
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
        defaults.set(entries, forKey: refusalKey)
    }
}
