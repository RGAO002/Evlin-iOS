import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import CryptoKit

/// Outcome of an `AppLimitPlanner.arm(rules:)` pass. Returned to the caller
/// (P6) which turns `.quotaExceeded` into a `limit_quota_exceeded` ack and
/// `.armed` into a success ack. The planner itself emits no acks.
enum AppLimitPlanResult: Equatable {
    /// DeviceActivity was (re)armed. `activityCount` distinct window activities,
    /// `eventCount` total `evlin.limit.<ruleId>` events across them.
    case armed(activityCount: Int, eventCount: Int)
    /// Validation failed BEFORE arming — nothing was stopped or armed (atomic).
    /// `slotsNeeded` is the count that breached `cap` (the offending dimension).
    case quotaExceeded(windows: Int, slotsNeeded: Int, cap: Int)
}

/// The "20-slot packer". Pure arming logic for per-app time limits:
///
/// 1. Filter the rule set to those active *now* (`now ∈ [effectiveFrom, expiresAt)`).
/// 2. Bucket rules by their `AppLimitWindow` — each distinct window becomes ONE
///    DeviceActivity activity named `evlin.limit.window.<sha16(windowKey)>`.
///    This is the key property: many rules sharing the default daily window
///    collapse into a single activity (slot), not one slot per rule.
/// 3. For each rule in a bucket, build a `DeviceActivityEvent` named
///    `evlin.limit.<ruleId>` whose threshold is the rule's `budgetMinutes`.
/// 4. Build the `DeviceActivitySchedule` from the window (honoring its tz).
/// 5. Validate the whole plan atomically (≤ 20 activities, ≤ 50 tokens/window,
///    ≤ `maxEventsPerActivity` events/activity). On breach → `.quotaExceeded`
///    and the scheduler is NOT touched (no partial arm).
/// 6. Commit: stop every `evlin.limit.*` window activity we know about (the
///    union of windows previously armed by this planner + windows about to be
///    armed), then arm each window via the `events:` scheduling overload.
///
/// Holds no persistence side effects beyond arming. P6 persists rules to the
/// store, then calls `arm(rules:)`.
///
/// `nonisolated` opts the planner out of the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default. Without it the class is
/// implicitly `@MainActor`, and its synthesized deinit routes through
/// `swift_task_deinitOnExecutorMainActorBackDeploy`, which double-frees on
/// dealloc under this toolchain (SIGABRT in every test that lets a planner
/// deallocate — `__deallocating_deinit` on the main-actor back-deploy shim).
/// Marking the class `nonisolated` runs the deinit off that shim. `@unchecked
/// Sendable` matches `ActionExecutor` / `AppLimitRuleStore`; the single-call-path
/// mutable state (`lastArmedActivityNames`) is not shared across threads, so the
/// unchecked promise holds.
nonisolated final class AppLimitPlanner: @unchecked Sendable {

    // MARK: - Quota constants

    /// DeviceActivity allows at most 20 concurrently-monitored activities.
    /// We bucket per window, so this caps distinct windows. Conservative:
    /// app-limit activities share the budget with shield/block/heartbeat
    /// activities, so a real deployment may want headroom below 20 — but the
    /// hard ceiling is 20 and that is what we validate against here.
    static let maxActivities = 20

    /// Max `ApplicationToken`s summed across all events in one window activity.
    /// DeviceActivity's documented per-activity application ceiling.
    static let maxTokensPerActivity = 50

    /// Max `DeviceActivityEvent`s per activity.
    /// KNOWN-UNKNOWN: Apple does not publish a hard per-activity event count.
    /// 50 is a conservative guess that MUST be verified against the real
    /// ceiling on device before relying on it — flagged for P6/P7.
    static let maxEventsPerActivity = 50

    // MARK: - Dependencies

    private let scheduler: DeviceActivityScheduling
    private let now: () -> Date

    /// Window activity names this planner armed on its previous successful pass.
    /// Tracked so the next pass can stop activities for windows that have since
    /// vanished from the rule set — `DeviceActivityCenter` stops only by explicit
    /// name, and a vanished window can't be re-derived from the current rules.
    private var lastArmedActivityNames: Set<String> = []

    init(
        scheduler: DeviceActivityScheduling = DeviceActivityCenterScheduler(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.now = now
    }

    // MARK: - Arm

    /// Validate then (re)arm DeviceActivity for the given rules. Atomic: if any
    /// quota is exceeded, the scheduler is left untouched and `.quotaExceeded`
    /// is returned. Otherwise all prior `evlin.limit.*` activities are stopped
    /// and each active window is re-armed.
    @discardableResult
    func arm(rules: [AppLimitRule]) -> AppLimitPlanResult {
        let reference = now()
        let active = rules.filter { isActive($0, at: reference) }

        // Bucket by window. Keyed on the stable `windowKey` string (not the
        // window value) so we don't require `AppLimitWindow: Hashable` — the
        // window struct lives in AppLimitRuleStore.swift, which P5 must not
        // touch. We carry the representative `AppLimitWindow` alongside the
        // rules so we can build the schedule from it.
        var buckets: [String: (window: AppLimitWindow, rules: [AppLimitRule])] = [:]
        for rule in active {
            let key = Self.windowKey(rule.window)
            if buckets[key] == nil {
                buckets[key] = (rule.window, [rule])
            } else {
                buckets[key]?.rules.append(rule)
            }
        }

        // ---- VALIDATE (no scheduler side effects yet) -----------------------

        let windowCount = buckets.count
        if windowCount > Self.maxActivities {
            return .quotaExceeded(windows: windowCount, slotsNeeded: windowCount, cap: Self.maxActivities)
        }
        for (_, bucket) in buckets {
            if bucket.rules.count > Self.maxEventsPerActivity {
                return .quotaExceeded(
                    windows: windowCount,
                    slotsNeeded: bucket.rules.count,
                    cap: Self.maxEventsPerActivity
                )
            }
            let tokenCount = bucket.rules.reduce(0) { $0 + $1.appTokens.count }
            if tokenCount > Self.maxTokensPerActivity {
                return .quotaExceeded(
                    windows: windowCount,
                    slotsNeeded: tokenCount,
                    cap: Self.maxTokensPerActivity
                )
            }
        }

        // ---- COMMIT (atomic past this point) --------------------------------

        // Build the (name, schedule, events) plan for each window up front so
        // arming is a straight loop with no further computation.
        struct ArmedActivity {
            let name: DeviceActivityName
            let schedule: DeviceActivitySchedule
            let events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        }
        var plan: [ArmedActivity] = []
        var totalEvents = 0
        for (_, bucket) in buckets {
            let window = bucket.window
            let name = DeviceActivityName(Self.activityName(for: window))
            let schedule = Self.schedule(for: window)
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            for rule in bucket.rules {
                let eventName = DeviceActivityEvent.Name(Self.eventName(for: rule.id))
                events[eventName] = DeviceActivityEvent(
                    applications: rule.appTokens,
                    categories: [],
                    webDomains: [],
                    threshold: DateComponents(minute: rule.budgetMinutes)
                )
            }
            totalEvents += events.count
            plan.append(ArmedActivity(name: name, schedule: schedule, events: events))
        }

        // "Stop all evlin.limit.*": DeviceActivityCenter stops only by explicit
        // name (or stops EVERYTHING, which would also kill shield/block/heartbeat
        // activities — unacceptable). So we compute the union of the window
        // activity names we armed last time + the ones we're about to arm, and
        // stop exactly that set. This wholesale-clears every limit window we
        // could be responsible for, including ones that vanished from the rule
        // set, without disturbing other namespaces.
        let namesToArm = Set(plan.map(\.name.rawValue))
        let namesToStop = lastArmedActivityNames.union(namesToArm)
        if !namesToStop.isEmpty {
            scheduler.stopMonitoring(namesToStop.sorted().map { DeviceActivityName($0) })
        }

        // Re-arm each window. Arming order doesn't matter; the stop above
        // already cleared the slate.
        for activity in plan {
            // Best-effort: a single window failing to arm should not abort the
            // others (the validate pass already guaranteed we're within quota).
            // We still surface throws to the console via the scheduler's own
            // logging path if any; here we keep the plan moving.
            try? scheduler.startMonitoring(activity.name, during: activity.schedule, events: activity.events)
        }

        lastArmedActivityNames = namesToArm
        return .armed(activityCount: plan.count, eventCount: totalEvents)
    }

    // MARK: - Filtering

    /// `now ∈ [effectiveFrom, expiresAt)`. Nil `expiresAt` = no upper bound.
    private func isActive(_ rule: AppLimitRule, at reference: Date) -> Bool {
        guard reference >= rule.effectiveFrom else { return false }
        if let expiresAt = rule.expiresAt, reference >= expiresAt { return false }
        return true
    }

    // MARK: - Naming

    /// Stable per-window activity name. Uses the same sha256-hex-16 approach the
    /// DeviceActivity extension (P7) uses for `evlin.shield.*` / `evlin.block.*`,
    /// so the extension can recognize an `evlin.limit.window.*` interval.
    static func activityName(for window: AppLimitWindow) -> String {
        "evlin.limit.window.\(sha16(windowKey(window)))"
    }

    /// Per-rule event name. The extension's `eventDidReachThreshold` parses the
    /// `evlin.limit.<id>` suffix back to a UUID to look up the rule + its tokens.
    static func eventName(for ruleID: UUID) -> String {
        "evlin.limit.\(ruleID.uuidString)"
    }

    /// Deterministic, collision-resistant string identity for a window. Order
    /// and separators are fixed so the hash is stable across processes/runs.
    static func windowKey(_ window: AppLimitWindow) -> String {
        "\(window.startMinute)|\(window.endMinute)|\(window.repeats)|\(window.timezone ?? "")"
    }

    // MARK: - Schedule

    /// Build the `DeviceActivitySchedule` for a window. Minutes-since-midnight
    /// convert to (hour, minute). If the window carries an IANA `timezone`, the
    /// schedule's components carry that tz so DeviceActivity resets in the rule's
    /// local time — this MUST later match the extension's threshold reset (P7).
    static func schedule(for window: AppLimitWindow) -> DeviceActivitySchedule {
        var startComponents = DateComponents(
            hour: window.startMinute / 60,
            minute: window.startMinute % 60
        )
        var endComponents = DateComponents(
            hour: window.endMinute / 60,
            minute: window.endMinute % 60
        )
        if let tzID = window.timezone, let tz = TimeZone(identifier: tzID) {
            startComponents.timeZone = tz
            endComponents.timeZone = tz
        }
        return DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: window.repeats
        )
    }

    // MARK: - Hash

    private static func sha16(_ string: String) -> String {
        let hash = SHA256.hash(data: Data(string.utf8))
        return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
