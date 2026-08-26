import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import CryptoKit

/// Outcome of an `AppLimitPlanner.arm(rules:)` pass. Returned to the caller
/// (P6) which turns `.quotaExceeded` into a `limit_quota_exceeded` ack and
/// `.armed` into a success ack. The planner itself emits no acks.
// `nonisolated` + `Sendable`: a plain value enum, and it has to cross a
// `Task.detached` boundary now that arming runs off the main thread. Left on the
// project-wide MainActor default it was neither, which is also where that pile
// of "main actor-isolated conformance to Equatable" warnings came from.
nonisolated enum AppLimitPlanResult: Equatable, Sendable {
    /// DeviceActivity was (re)armed. `activityCount` distinct window activities,
    /// `eventCount` total `evlin.limit.<ruleId>` events across them.
    case armed(activityCount: Int, eventCount: Int)
    /// Some window activities armed, but at least one threw at runtime AFTER
    /// validation passed (e.g. DAM `excessiveActivities`). `armed`/`failed` are
    /// window-activity counts. Validation atomicity is unaffected — this only
    /// describes runtime arm failures, so P6 can ack accurately rather than
    /// claiming full success. Already-armed windows are NOT rolled back.
    case partiallyArmed(armed: Int, failed: Int)
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
/// 6. Commit: stop every `evlin.limit.window.*` activity we could be
///    responsible for, then arm each window via the `events:` scheduling
///    overload. The stop set is the UNION of (a) windows this planner armed on
///    its previous pass, (b) windows about to be armed, and (c) the scheduler's
///    LIVE monitored activities filtered to the `evlin.limit.window.` prefix.
///
/// The planner is NOT a singleton and self-heals from the live activity set: a
/// fresh instance (or one after an app restart) no longer relies solely on
/// in-memory `lastArmedActivityNames`, so it discovers and stops orphaned
/// `evlin.limit.window.*` activities a previous instance left behind. Other
/// namespaces (`evlin.shield.*` / `evlin.block.*` / heartbeat) are never
/// touched.
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
    private let epochStore: AppLimitEpochStore
    private let ownerProvider: @Sendable () -> UUID?
    private let armIDProvider: @Sendable () -> UUID

    /// Window activity names this planner armed on its previous successful pass.
    /// Tracked so the next pass can stop activities for windows that have since
    /// vanished from the rule set — `DeviceActivityCenter` stops only by explicit
    /// name, and a vanished window can't be re-derived from the current rules.
    private var lastArmedActivityNames: Set<String> = []

    init(
        scheduler: DeviceActivityScheduling = DeviceActivityCenterScheduler(),
        now: @escaping () -> Date = { Date() },
        epochStore: AppLimitEpochStore = .shared,
        ownerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current,
        armIDProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.scheduler = scheduler
        self.now = now
        self.epochStore = epochStore
        self.ownerProvider = ownerProvider
        self.armIDProvider = armIDProvider
    }

    // MARK: - Gate pause and conservative resume

    /// Marks live v2 arms as paused without touching DeviceActivity. While the
    /// gate is closed, the extension retains only raw callback high-water; it
    /// does not emit enforcement or usage effects.
    @discardableResult
    func pauseActiveArms() -> Int {
        guard let owner = ownerProvider() else { return 0 }
        let pausedAt = now()
        do {
            return try epochStore.transaction(
                source: .poll,
                expectedOwner: owner
            ) { state in
                var count = 0
                for ruleID in state.slots.keys {
                    guard var slot = state.slots[ruleID],
                          slot.latestKind == .set,
                          var provenance = slot.armProvenance,
                          provenance.pausedAt == nil
                    else { continue }
                    provenance.pausedAt = pausedAt
                    slot.armProvenance = provenance
                    state.slots[ruleID] = slot
                    count += 1
                }
                return count
            }
        } catch {
            return 0
        }
    }

    func hasPausedArms() -> Bool {
        guard let owner = ownerProvider() else { return false }
        do {
            let state = try epochStore.read()
            guard state.ownerChildDeviceID == owner else { return false }
            return state.slots.values.contains {
                $0.latestKind == .set
                    && ($0.armProvenance?.pausedAt != nil
                        || $0.armProvenance?.monitorStartPending == true)
            }
        } catch {
            return false
        }
    }

    /// Atomically replaces each paused arm with a successor before touching
    /// DeviceActivity. The successor starts its raw counter at zero. Only
    /// callbacks accepted before pause become its base; paused raw high-water
    /// is retained as audit provenance and is never charged.
    @discardableResult
    func resumePausedArms(rules: [AppLimitRule]) -> AppLimitPlanResult {
        guard let owner = ownerProvider() else { return arm(rules: rules) }
        let resumedAt = now()
        do {
            try epochStore.transaction(
                source: .poll,
                expectedOwner: owner
            ) { state in
                for ruleID in state.slots.keys {
                    guard var slot = state.slots[ruleID],
                          slot.latestKind == .set,
                          var provenance = slot.armProvenance,
                          provenance.pausedAt != nil
                    else { continue }

                    if provenance.usageDate != Self.usageDate(
                        for: resumedAt,
                        timezoneID: provenance.timezone
                    ) {
                        provenance.predecessorIgnoredWhilePausedMinutes = provenance.ignoredWhilePausedMinutes
                        provenance.pausedAt = nil
                        provenance.ignoredWhilePausedMinutes = 0
                        slot.armProvenance = provenance
                        state.slots[ruleID] = slot
                        continue
                    }

                    let accepted = provenance.baseAcceptedMinutes
                        + provenance.lastRawThresholdMinutes
                    guard accepted >= 0, accepted < provenance.budgetMinutes else {
                        provenance.predecessorIgnoredWhilePausedMinutes = provenance.ignoredWhilePausedMinutes
                        provenance.pausedAt = nil
                        provenance.ignoredWhilePausedMinutes = 0
                        slot.armProvenance = provenance
                        state.slots[ruleID] = slot
                        continue
                    }
                    let ignored = provenance.ignoredWhilePausedMinutes
                    let armID = armIDProvider()
                    provenance.baseAcceptedMinutes = accepted
                    provenance.lastRawThresholdMinutes = 0
                    provenance.ignoredWhilePausedMinutes = 0
                    provenance.predecessorIgnoredWhilePausedMinutes = ignored
                    provenance.pausedAt = nil
                    provenance.monitorStartPending = true
                    provenance.physicalEventsConsumedAt = nil
                    provenance.startedAt = resumedAt
                    provenance.armID = armID
                    provenance.activityName = Self.v2ActivityName(armID: armID)
                    slot.armProvenance = provenance
                    state.slots[ruleID] = slot
                }
            }
        } catch {
            return .partiallyArmed(armed: 0, failed: rules.count)
        }
        return armV2(rules: rules, ownerChildDeviceID: owner)
    }

    // MARK: - Arm

    /// Validate then (re)arm DeviceActivity for the given rules. Atomic: if any
    /// quota is exceeded, the scheduler is left untouched and `.quotaExceeded`
    /// is returned. Otherwise all prior `evlin.limit.*` activities are stopped
    /// and each active window is re-armed.
    @discardableResult
    func arm(rules: [AppLimitRule]) -> AppLimitPlanResult {
        if let owner = ownerProvider() {
            return armV2(rules: rules, ownerChildDeviceID: owner)
        }

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
        let externallyOccupiedSlots = scheduler.monitoredActivities()
            .map(\.rawValue)
            // This legacy pass replaces only legacy window activities. A live
            // v2 activity is a real additional tenant during fallback and must
            // still count against Apple's global 20-activity ceiling.
            .filter { !$0.hasPrefix(Self.windowActivityPrefix) }
            .count
        let slotsNeeded = windowCount + externallyOccupiedSlots
        if slotsNeeded > Self.maxActivities {
            return .quotaExceeded(windows: windowCount, slotsNeeded: slotsNeeded, cap: Self.maxActivities)
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
            var enforcementTokens = 0
            for rule in bucket.rules {
                let eventName = DeviceActivityEvent.Name(Self.eventName(for: rule.id))
                events[eventName] = DeviceActivityEvent(
                    applications: rule.appTokens,
                    categories: [],
                    webDomains: [],
                    threshold: DateComponents(minute: rule.budgetMinutes)
                )
                enforcementTokens += rule.appTokens.count
            }
            // `eventCount` in the result is ENFORCEMENT events only (the `.armed`
            // doc + P6 ack semantics) — the measurement events below are an
            // implementation detail of the usage bar, not part of the ack.
            totalEvents += bucket.rules.count

            // Add measurement (usage-bar) events ADDITIVELY, packed into this
            // activity's remaining event/token budget after enforcement reserves
            // its share. Distinct `evlin.applimit.*` prefix → the extension routes
            // these to usage reporting and NEVER to applyLimitShield. A rule that
            // doesn't fit keeps enforcement and just loses the bar (logged).
            let alloc = Self.allocateMeasurement(
                rules: bucket.rules.map {
                    (id: $0.id, tokenCount: $0.appTokens.count, budgetMinutes: $0.budgetMinutes)
                },
                reservedEvents: bucket.rules.count,
                reservedTokens: enforcementTokens
            )
            for rule in bucket.rules {
                guard let thresholds = alloc.perRule[rule.id] else { continue }
                for t in thresholds {
                    let mName = DeviceActivityEvent.Name(Self.measurementEventName(for: rule.id, threshold: t))
                    events[mName] = DeviceActivityEvent(
                        applications: rule.appTokens,
                        categories: [],
                        webDomains: [],
                        threshold: DateComponents(minute: t)
                    )
                }
            }
            if !alloc.dropped.isEmpty {
                NSLog("[Evlin] app_limit_measurement_dropped window=%@ count=%d (enforcement intact)",
                      name.rawValue, alloc.dropped.count)
            }
            plan.append(ArmedActivity(name: name, schedule: schedule, events: events))
        }

        // "Stop all evlin.limit.window.*": DeviceActivityCenter stops only by
        // explicit name (or stops EVERYTHING, which would also kill
        // shield/block/heartbeat activities — unacceptable). So we compute the
        // stop set as the UNION of:
        //   (a) window names we armed on our previous pass (in-memory),
        //   (b) the window names we're about to arm,
        //   (c) the scheduler's LIVE monitored activities, filtered to the
        //       `evlin.limit.window.` prefix.
        // (c) is the self-healing path: a fresh planner instance (or one after
        // an app restart) has an empty (a), so without it, orphaned limit
        // windows armed by a previous instance — and since vanished from the
        // rule set — would leak forever. We never touch non-window namespaces.
        let namesToArm = Set(plan.map(\.name.rawValue))
        let liveOrphanWindows = Set(
            scheduler.monitoredActivities()
                .map(\.rawValue)
                .filter { $0.hasPrefix(Self.windowActivityPrefix) }
        )
        let namesToStop = lastArmedActivityNames
            .union(namesToArm)
            .union(liveOrphanWindows)
        if !namesToStop.isEmpty {
            scheduler.stopMonitoring(namesToStop.sorted().map { DeviceActivityName($0) })
        }

        // Re-arm each window. Arming order doesn't matter; the stop above
        // already cleared the slate. A single window failing to arm should not
        // abort the others (the validate pass already guaranteed we're within
        // quota), but we do NOT swallow the throw with try? — we collect each
        // failure, log it, and report `.partiallyArmed` so P6 can ack honestly
        // instead of claiming a full success.
        var armedCount = 0
        var failures: [(DeviceActivityName, Error)] = []
        for activity in plan {
            do {
                try scheduler.startMonitoring(activity.name, during: activity.schedule, events: activity.events)
                armedCount += 1
            } catch {
                failures.append((activity.name, error))
                NSLog(
                    "[Evlin] app_limit_arm_FAILED activity=%@ error=%@",
                    activity.name.rawValue,
                    error.localizedDescription
                )
            }
        }

        lastArmedActivityNames = namesToArm
        if failures.isEmpty {
            return .armed(activityCount: plan.count, eventCount: totalEvents)
        }
        return .partiallyArmed(armed: armedCount, failed: failures.count)
    }

    private func armV2(
        rules: [AppLimitRule],
        ownerChildDeviceID: UUID
    ) -> AppLimitPlanResult {
        // Serialise concurrent arms WITHOUT holding ActiveLockPersistenceLock
        // across DeviceActivity's synchronous XPC.
        //
        // That lock has two layers, and both used to span the whole arm: a
        // process-wide NSRecursiveLock and a CROSS-PROCESS flock that the
        // DeviceActivityMonitor extension takes at five sites. A daemon call
        // that never answers therefore did not merely wedge this caller — it
        // starved the extension into jetsam, which for parental controls is
        // worse than the crash, because a crash at least restarts and re-arms.
        // (2026-08-08: FrontBoard killed the app at armV2Locked's
        // startMonitoring with 0.02s of CPU burned, holding this lock.)
        //
        // Dropping it costs only whole-sequence atomicity against the
        // extension. Every step here already re-enters the persistence lock on
        // its own — `resolve`, `recordStartAttempt` and `markMonitorStartObserved`
        // each open their own store transaction — and each is CAS-guarded on
        // owner + armID + replacementKey + monitorStartPending, so an
        // interleaved writer is rejected rather than silently merged.
        Self.armSerialization.lock()
        defer { Self.armSerialization.unlock() }
        return armV2Locked(
            rules: rules,
            ownerChildDeviceID: ownerChildDeviceID
        )
    }

    /// In-process single-flight for arming. Recursive because an arm can be
    /// re-entered on the same thread through recovery paths; deliberately NOT
    /// the cross-process persistence lock — see `armV2`.
    private static let armSerialization = NSRecursiveLock()

    /// Every v2 activity name currently claimed by a slot's arm provenance —
    /// including claims written by another process. `nil` means the store could
    /// not be read, and the caller must then stop NOTHING: an empty set would
    /// read as "nobody claims anything" and tear down live enforcement.
    private static func claimedActivityNames(
        epochStore: AppLimitEpochStore
    ) -> Set<String>? {
        guard let state = try? epochStore.read() else { return nil }
        return Set(state.slots.values.compactMap { $0.armProvenance?.activityName })
    }

    /// Rules the backend already reports as spent for today. Read once per arm
    /// so a single store snapshot decides the whole plan; an unreadable store
    /// excludes nothing, which keeps the previous behaviour rather than
    /// silently dropping every rule.
    private static func authoritativelyExhaustedRuleIDs(
        in rules: [AppLimitRule],
        epochStore: AppLimitEpochStore
    ) -> Set<UUID> {
        guard let state = try? epochStore.read() else { return [] }
        return Set(
            rules.compactMap { rule in
                state.slots[rule.id]?.isAuthoritativelyExhausted == true
                    ? rule.id
                    : nil
            }
        )
    }

    private func armV2Locked(
        rules: [AppLimitRule],
        ownerChildDeviceID: UUID
    ) -> AppLimitPlanResult {
        let reference = now()
        // A rule whose budget the backend already reports as spent is SHIELDED,
        // not measured — ActionExecutor's exhausted branch owns it. Drop it
        // before `resolve` so it never claims an arm identity.
        //
        // This must happen here rather than at the per-rule guard below: that
        // guard is a `return`, so one spent app used to abort the whole arm and
        // every other app silently stopped being measured. And by the time the
        // guard fires, `resolve` has already written provenance for the rules
        // sorted ahead of it — an orphan monitor with no concurrency involved.
        // (Reachable only since the base is seeded from the backend's
        // used-today; before that `baseAcceptedMinutes` was always 0.)
        let exhaustedRuleIDs = Self.authoritativelyExhaustedRuleIDs(
            in: rules,
            epochStore: epochStore
        )
        let active = rules.filter {
            isActive($0, at: reference) && !exhaustedRuleIDs.contains($0.id)
        }
        let externallyOccupiedSlots = scheduler.monitoredActivities()
            .map(\.rawValue)
            // This v2 pass replaces only v2 activities. Legacy windows can
            // coexist during migration and consume physical daemon slots.
            .filter { !$0.hasPrefix(Self.v2ActivityPrefix) }
            .count
        let slotsNeeded = active.count + externallyOccupiedSlots
        guard slotsNeeded <= Self.maxActivities else {
            return .quotaExceeded(
                windows: active.count,
                slotsNeeded: slotsNeeded,
                cap: Self.maxActivities
            )
        }
        for rule in active {
            guard rule.appTokens.count <= Self.maxTokensPerActivity else {
                return .quotaExceeded(
                    windows: active.count,
                    slotsNeeded: rule.appTokens.count,
                    cap: Self.maxTokensPerActivity
                )
            }
        }

        struct ArmedActivity {
            let name: DeviceActivityName
            let schedule: DeviceActivitySchedule
            let events: [DeviceActivityEvent.Name: DeviceActivityEvent]
            let provenance: AppLimitArmProvenance
        }
        let provenanceStore = AppLimitProvenanceStore(
            store: epochStore,
            armIDProvider: armIDProvider
        )
        var plan: [ArmedActivity] = []
        for rule in active.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let resolution: AppLimitProvenanceStore.Resolution
            do {
                resolution = try provenanceStore.resolve(
                    rule: rule,
                    ownerChildDeviceID: ownerChildDeviceID,
                    now: reference
                )
            } catch {
                return .partiallyArmed(armed: 0, failed: active.count)
            }
            let provenance = resolution.provenance
            guard provenance.baseAcceptedMinutes >= 0,
                  provenance.baseAcceptedMinutes < provenance.budgetMinutes else {
                return .partiallyArmed(armed: 0, failed: active.count)
            }
            let remainingBudgetMinutes = provenance.budgetMinutes
                - provenance.baseAcceptedMinutes
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [
                DeviceActivityEvent.Name(
                    Self.v2EnforcementEventName(armID: provenance.armID)
                ): Self.makeV2Event(
                    applications: rule.appTokens,
                    thresholdMinutes: remainingBudgetMinutes
                )
            ]
            let allocation = Self.allocateMeasurement(
                rules: [
                    (
                        id: rule.id,
                        tokenCount: rule.appTokens.count,
                        budgetMinutes: remainingBudgetMinutes
                    )
                ],
                reservedEvents: 1,
                reservedTokens: rule.appTokens.count
            )
            for threshold in allocation.perRule[rule.id] ?? [] {
                events[DeviceActivityEvent.Name(
                    Self.v2MeasurementEventName(
                        armID: provenance.armID,
                        threshold: threshold
                    )
                )] = Self.makeV2Event(
                    applications: rule.appTokens,
                    thresholdMinutes: threshold
                )
            }
            plan.append(ArmedActivity(
                name: DeviceActivityName(provenance.activityName),
                schedule: Self.schedule(for: rule.window),
                events: events,
                provenance: provenance
            ))
        }

        let desiredNames = Set(plan.map(\.name.rawValue))
        let liveNames = Set(
            scheduler.monitoredActivities()
                .map(\.rawValue)
                .filter { $0.hasPrefix(Self.v2ActivityPrefix) }
        )
        // Stop only what NOBODY claims — never merely "what is absent from my
        // own plan". The Push NSE arms in its own process
        // (EvlinPushApplier/NotificationService.swift), and since the arm no
        // longer holds a cross-process lock, its arm can complete between this
        // pass's provenance write and this read. Subtracting `desiredNames`
        // stopped the monitor the extension had just correctly installed, and
        // left the store believing that arm was observed and running — the one
        // inconsistency nothing tries to repair, because it looks healthy.
        //
        // Read the claims fresh, immediately before the stop. That closes the
        // window rather than narrowing it: `resolve` writes an arm's provenance
        // before `startMonitoring` installs it, so anything already visible in
        // `liveNames` was necessarily claimed before this read.
        let staleNames = Self.claimedActivityNames(epochStore: epochStore)
            .map { liveNames.subtracting($0) } ?? []
        if !staleNames.isEmpty {
            scheduler.stopMonitoring(
                staleNames.sorted().map { DeviceActivityName($0) }
            )
        }

        let missingNames = desiredNames.subtracting(liveNames)
        for activity in plan where !missingNames.contains(activity.name.rawValue) {
            try? markMonitorStartObserved(activity.provenance, ownerChildDeviceID: ownerChildDeviceID)
        }
        var armedCount = 0
        var failedCount = 0
        for activity in plan where missingNames.contains(activity.name.rawValue) {
            do {
                _ = try provenanceStore.recordStartAttempt(
                    activity.provenance,
                    ownerChildDeviceID: ownerChildDeviceID,
                    startedAt: reference
                )
                try scheduler.startMonitoring(
                    activity.name,
                    during: activity.schedule,
                    events: activity.events
                )
                // A superseded arm is NOT armed. Counting it as such is how the
                // store came to believe an arm was observed and running while
                // the daemon had nothing — the one inconsistency that looks
                // healthy and therefore never gets repaired.
                switch try markMonitorStartObserved(
                    activity.provenance,
                    ownerChildDeviceID: ownerChildDeviceID
                ) {
                case .observed, .alreadyObserved:
                    armedCount += 1
                case .stale:
                    failedCount += 1
                }
            } catch {
                failedCount += 1
            }
        }
        if failedCount > 0 {
            return .partiallyArmed(armed: armedCount, failed: failedCount)
        }
        return .armed(activityCount: plan.count, eventCount: active.count)
    }

    /// Outcome of recording that a monitor is running. `stale` has to be
    /// distinguishable: the old code returned silently on a CAS miss and the
    /// caller counted the arm as successful anyway, so an arm that had lost its
    /// identity to another process reported `.armed`.
    enum MonitorStartObservation: Equatable {
        /// This call cleared `monitorStartPending`.
        case observed
        /// Same arm, already marked — another process got there first, which is
        /// idempotent success, not failure.
        case alreadyObserved
        /// The provenance no longer matches: this arm was superseded.
        case stale
    }

    @discardableResult
    private func markMonitorStartObserved(
        _ provenance: AppLimitArmProvenance,
        ownerChildDeviceID: UUID
    ) throws -> MonitorStartObservation {
        try epochStore.transaction(source: .wakeRecovery, expectedOwner: ownerChildDeviceID) { state in
            guard var slot = state.slots[provenance.ruleID],
                  var current = slot.armProvenance,
                  current.armID == provenance.armID,
                  current.activityName == provenance.activityName
            else { return .stale }
            guard current.monitorStartPending == true else { return .alreadyObserved }
            current.monitorStartPending = false
            slot.armProvenance = current
            state.slots[provenance.ruleID] = slot
            return .observed
        }
    }

    private static func usageDate(for date: Date, timezoneID: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    // MARK: - Filtering

    /// `now ∈ [effectiveFrom, expiresAt)`. Nil `expiresAt` = no upper bound.
    private func isActive(_ rule: AppLimitRule, at reference: Date) -> Bool {
        guard reference >= rule.effectiveFrom else { return false }
        if let expiresAt = rule.expiresAt, reference >= expiresAt { return false }
        return true
    }

    // MARK: - Naming

    /// Namespace prefix for every window activity this planner owns. The commit
    /// pass filters the scheduler's live activities to this prefix so it only
    /// ever stops limit windows — never `evlin.shield.*` / `evlin.block.*` /
    /// heartbeat activities.
    static let windowActivityPrefix = "evlin.limit.window."
    static let v2ActivityPrefix = "evlin.limit.v2."

    static func isPlannerActivity(_ activityName: String) -> Bool {
        activityName.hasPrefix(windowActivityPrefix)
            || activityName.hasPrefix(v2ActivityPrefix)
    }

    static func v2ActivityName(armID: UUID) -> String {
        "\(v2ActivityPrefix)\(armID.uuidString.lowercased())"
    }

    static func v2EnforcementEventName(armID: UUID) -> String {
        "evlin.limit.v2.\(armID.uuidString.lowercased()).budget"
    }

    static func v2MeasurementEventName(armID: UUID, threshold: Int) -> String {
        "evlin.applimit.v2.\(armID.uuidString.lowercased()).t\(threshold)"
    }

    static func makeV2Event(
        applications: Set<ApplicationToken>,
        thresholdMinutes: Int
    ) -> DeviceActivityEvent {
        DeviceActivityEvent(
            applications: applications,
            categories: [],
            webDomains: [],
            threshold: DateComponents(minute: thresholdMinutes),
            includesPastActivity: false
        )
    }

    /// Stable per-window activity name. Uses the same sha256-hex-16 approach the
    /// DeviceActivity extension (P7) uses for `evlin.shield.*` / `evlin.block.*`,
    /// so the extension can recognize an `evlin.limit.window.*` interval.
    static func activityName(for window: AppLimitWindow) -> String {
        "\(windowActivityPrefix)\(sha16(windowKey(window)))"
    }

    /// Per-rule event name. The extension's `eventDidReachThreshold` parses the
    /// `evlin.limit.<id>` suffix back to a UUID to look up the rule + its tokens.
    static func eventName(for ruleID: UUID) -> String {
        "evlin.limit.\(ruleID.uuidString)"
    }

    // MARK: - Measurement (per-app usage bar)

    /// Coarse "quarters" usage thresholds for a budget — at ~25/50/75% of the
    /// budget, strictly inside `(0, budget)`, integer, unique, ascending, at most
    /// 3. They fire BEFORE the enforcement threshold so the parent's usage bar can
    /// move in quarters. A tiny budget (whose quarters all round outside the open
    /// range) yields none — enforcement still applies, the bar just can't move.
    static func measurementThresholds(budgetMinutes: Int) -> [Int] {
        guard budgetMinutes >= 2 else { return [] }
        let quarters = [0.25, 0.5, 0.75].map { Int((Double(budgetMinutes) * $0).rounded()) }
        let inside = quarters.filter { $0 > 0 && $0 < budgetMinutes }
        return Array(Set(inside)).sorted()
    }

    /// Per-rule, per-threshold MEASUREMENT event name. A DISTINCT `evlin.applimit.`
    /// prefix (never `evlin.limit.`) so the extension routes it to usage reporting
    /// and NEVER to `applyLimitShield`.
    static func measurementEventName(for ruleID: UUID, threshold: Int) -> String {
        "evlin.applimit.\(ruleID.uuidString).t\(threshold)"
    }

    /// Result of packing measurement events into an activity's remaining budget.
    struct MeasurementAllocation: Equatable {
        var perRule: [UUID: [Int]]
        var dropped: [UUID]
    }

    /// Pack measurement thresholds into the per-activity event/token budget that
    /// REMAINS after enforcement is reserved. Enforcement always wins: a rule
    /// whose measurement events don't fit keeps its enforcement event and is
    /// listed in `dropped` (it only loses the usage bar). A rule with no
    /// measurable thresholds (tiny budget) is neither allocated nor dropped.
    /// Stable order by rule id keeps the kept set deterministic across input order.
    static func allocateMeasurement(
        rules: [(id: UUID, tokenCount: Int, budgetMinutes: Int)],
        reservedEvents: Int,
        reservedTokens: Int
    ) -> MeasurementAllocation {
        var perRule: [UUID: [Int]] = [:]
        var dropped: [UUID] = []
        var usedEvents = reservedEvents
        var usedTokens = reservedTokens
        for r in rules.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let thresholds = measurementThresholds(budgetMinutes: r.budgetMinutes)
            if thresholds.isEmpty { continue }
            let eventCost = thresholds.count
            let tokenCost = thresholds.count * r.tokenCount
            if usedEvents + eventCost <= maxEventsPerActivity,
               usedTokens + tokenCost <= maxTokensPerActivity {
                perRule[r.id] = thresholds
                usedEvents += eventCost
                usedTokens += tokenCost
            } else {
                dropped.append(r.id)
            }
        }
        return MeasurementAllocation(perRule: perRule, dropped: dropped)
    }

    /// Deterministic, collision-resistant string identity for a window. Order
    /// and separators are fixed so the hash is stable across processes/runs.
    ///
    /// The timezone is normalized through `TimeZone(identifier:)` so it matches
    /// what `schedule(for:)` actually does: an invalid IANA id collapses to the
    /// same bucket as `nil` (device-local), since `schedule(for:)` falls back to
    /// device-local for both. Without this, an invalid id would hash to its own
    /// slot doing the exact same thing as the nil/local slot. Nil stays `""`.
    static func windowKey(_ window: AppLimitWindow) -> String {
        let tzID = window.timezone.flatMap { TimeZone(identifier: $0)?.identifier } ?? ""
        return "\(window.startMinute)|\(window.endMinute)|\(window.repeats)|\(tzID)"
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

    /// V2 arms anchor their interval at the ARM moment, not the window's
    /// nominal start. The events use `includesPastActivity: false`, and since
    /// the 26.5.2-era daemon a `false` event attached MID-interval never fires
    /// for the remainder of that interval day (observed 2026-08-05..07 across
    /// two devices: production arms silent all day; an identical probe with
    /// `past: true` fired in 50s; the earned ladder — arm-anchored since
    /// 07-25 — kept firing throughout). Anchoring makes the attach moment BE
    /// the interval start, which is the one shape both Apple's documentation
    /// and the earned ladder's real-world evidence agree fires immediately.
    ///
    /// Non-repeating: this interval covers the REMAINDER of today's window
    /// only. The daily budget reset re-arms through the owner-recovery paths
    /// (foreground, poll, silent wake), which mint a fresh anchored interval
    /// for the new day. Until that re-arm the limit is unmonitored, which can
    /// only UNDER-count — the safe direction.
    static func v2ArmSchedule(
        for window: AppLimitWindow,
        armedAt: Date
    ) -> DeviceActivitySchedule {
        let tz = window.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let nowParts = calendar.dateComponents([.hour, .minute], from: armedAt)
        let nowMinute = (nowParts.hour ?? 0) * 60 + (nowParts.minute ?? 0)
        // Clamp inside the window; if the window has under a minute left,
        // fall back to the nominal window (worst case: today stays silent,
        // exactly what the old shape did all day).
        let startMinute = min(max(window.startMinute, nowMinute), window.endMinute - 1)
        var startComponents = DateComponents(
            hour: startMinute / 60,
            minute: startMinute % 60
        )
        var endComponents = DateComponents(
            hour: window.endMinute / 60,
            minute: window.endMinute % 60
        )
        startComponents.timeZone = tz
        endComponents.timeZone = tz
        return DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )
    }

    // MARK: - Hash

    private static func sha16(_ string: String) -> String {
        let hash = SHA256.hash(data: Data(string.utf8))
        return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
