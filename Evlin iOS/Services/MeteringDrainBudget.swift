import Foundation

/// Work cap for ONE opportunistic drain pass.
///
/// The DeviceActivity extension no longer waits for uploads inside its
/// synchronous callback (2026-08-19). It kicks a background drain and returns.
/// That drain must not turn into "walk the whole backlog with 4-second
/// timeouts": the backlog is largest exactly when previous callbacks died,
/// and a large upload payload is the memory spike that pushed the extension
/// to its 6MB per-process limit (iPad 2026-08-18, pid 5728: footprint 4.17MB
/// at `beforeDrain`, jetsam `per-process-limit` during the drain).
///
/// So each pass reserves at most `maxRequests` network requests and stops at
/// `deadline`; whatever is left waits for the next callback, the host app's
/// foreground drain, or a background wake. The main app keeps using
/// `.unlimited()` — its behaviour is unchanged.
nonisolated final class MeteringDrainBudget: @unchecked Sendable {
    /// No cap. Preserves the historical main-app behaviour byte for byte.
    static func unlimited() -> MeteringDrainBudget {
        MeteringDrainBudget(maxRequests: Int.max, deadline: .distantFuture)
    }

    /// The extension's default: one small batch, a few seconds, then stop.
    static func extensionDefault(now: Date = Date()) -> MeteringDrainBudget {
        MeteringDrainBudget(
            maxRequests: extensionMaxRequests,
            deadline: now.addingTimeInterval(extensionWallClockSeconds)
        )
    }

    static let extensionMaxRequests = 8
    static let extensionWallClockSeconds: TimeInterval = 3

    let maxRequests: Int
    let deadline: Date

    private let lock = NSLock()
    private var used = 0

    init(maxRequests: Int, deadline: Date) {
        precondition(maxRequests >= 0)
        self.maxRequests = maxRequests
        self.deadline = deadline
    }

    /// Reserve one network request. `false` once the pass has spent its
    /// request count or crossed its deadline — callers stop and return.
    func reserveRequest(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard used < maxRequests, now < deadline else { return false }
        used += 1
        return true
    }

    /// Per-request timeout for a request started under this budget, or `nil`
    /// when the budget is unlimited (callers keep their own default).
    ///
    /// The deadline is not a real deadline if a request that started at
    /// T-0.1s may run for 4s (callback journal) or 60s (URLSession default,
    /// which the epoch requests used to inherit): the single-flight worker
    /// would sit on it, later kicks would only pile up, and a claimed work
    /// item would hold its lease. So every request under a bounded budget is
    /// clamped to what is left of the pass — at least `minimumRequestSeconds`
    /// so a request is never born dead, at most `maximumRequestSeconds`.
    func requestTimeout(now: Date = Date()) -> TimeInterval? {
        guard deadline != .distantFuture else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        return min(
            Self.maximumRequestSeconds,
            max(Self.minimumRequestSeconds, remaining)
        )
    }

    static let minimumRequestSeconds: TimeInterval = 1
    static let maximumRequestSeconds: TimeInterval = 4

    /// Requests reserved so far (diagnostics/tests).
    var requestsUsed: Int {
        lock.lock()
        defer { lock.unlock() }
        return used
    }
}
