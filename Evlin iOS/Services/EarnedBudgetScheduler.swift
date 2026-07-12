import Foundation
import DeviceActivity
import FamilyControls

/// B4 — Whole-device earned-time ladder scheduler.
///
/// Arms one generated `DeviceActivity` activity over the
/// all-category measurement selection captured in `EarnedTimeStore`.
/// Events are named `evlin.earned.t5`, `evlin.earned.t10`, … up to
/// `min(poolMinutes, capMinutes)`, with the exact cap threshold always
/// included (even when it is not a multiple of `earnedBucketMinutes`).
///
/// The threshold-planning logic (`thresholds(poolMinutes:capMinutes:)`) is a
/// **pure function** — no DeviceActivity calls, no entitlements — so it can
/// be unit-tested in isolation.
@MainActor
final class EarnedBudgetScheduler {

    // MARK: - Constants (single sources of truth)

    /// The granularity of earned-time buckets (minutes).
    /// All event thresholds are derived from this value.
    nonisolated static let earnedBucketMinutes: Int = 5

    /// Hard ceiling on the number of DeviceActivity events that can be armed
    /// in one activity (240 min / 5 min per bucket = 48 max meaningful slots).
    nonisolated static let guardEventCount: Int = 48

    // MARK: - Singleton

    static let shared = EarnedBudgetScheduler()
    private let center = DeviceActivityCenter()
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")

    // MARK: - Pure threshold planner

    /// Returns the sorted list of minute thresholds for the earned-budget ladder.
    ///
    /// - Every multiple of `earnedBucketMinutes` from the first bucket up to
    ///   `min(poolMinutes, capMinutes)` is included.
    /// - If `capMinutes` is not a multiple of `earnedBucketMinutes` AND
    ///   `capMinutes ≤ poolMinutes`, the exact cap value is appended as the
    ///   final threshold.
    /// - The result count never exceeds `guardEventCount`.
    /// - Returns `[]` when either argument is ≤ 0.
    ///
    /// `nonisolated` so this pure function can be called from any context
    /// (including XCTestCase synchronous test methods) without actor-hop overhead.
    nonisolated static func thresholds(poolMinutes: Int, capMinutes: Int) -> [Int] {
        let ceiling = min(poolMinutes, capMinutes)
        guard ceiling > 0 else { return [] }

        // Generate multiples of earnedBucketMinutes up to ceiling.
        var result: [Int] = stride(
            from: earnedBucketMinutes,
            through: ceiling,
            by: earnedBucketMinutes
        ).map { $0 }

        // Append exact cap if it is not already a multiple of the bucket.
        // This ensures the cap threshold is always represented.
        if ceiling % earnedBucketMinutes != 0 {
            result.append(ceiling)
        }

        // Guard: cap at guardEventCount slots (safety valve).
        if result.count > guardEventCount {
            result = Array(result.prefix(guardEventCount))
        }

        return result
    }

    nonisolated static func remainingPolicy(
        poolMinutes: Int,
        capMinutes: Int,
        offsetMinutes: Int
    ) -> (poolMinutes: Int, capMinutes: Int)? {
        let remainingCeiling = min(poolMinutes, capMinutes) - max(0, offsetMinutes)
        guard remainingCeiling > 0 else { return nil }
        return (remainingCeiling, remainingCeiling)
    }

    // MARK: - Arming

    nonisolated static func dailySchedule(
        timeZone: TimeZone = .current,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> DeviceActivitySchedule {
        var policyCalendar = calendar
        policyCalendar.timeZone = timeZone
        var startComponents = DateComponents()
        startComponents.calendar = policyCalendar
        startComponents.timeZone = timeZone
        startComponents.hour = 0
        startComponents.minute = 0
        var endComponents = DateComponents()
        endComponents.calendar = policyCalendar
        endComponents.timeZone = timeZone
        endComponents.hour = 23
        endComponents.minute = 59
        return DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: true
        )
    }

    nonisolated static func resumeSchedule(
        startingAt start: Date,
        timeZone: TimeZone? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> DeviceActivitySchedule {
        var policyCalendar = calendar
        let policyTimeZone = timeZone ?? calendar.timeZone
        policyCalendar.timeZone = policyTimeZone
        let startComponents = policyCalendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: start
        )
        var endComponents = policyCalendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day],
            from: start
        )
        endComponents.hour = 23
        endComponents.minute = 59
        endComponents.second = 59
        return DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )
    }

    /// Arm the earned-budget activity over `selection` using the pre-computed
    /// pool/cap policy.
    ///
    /// Every call starts a fresh generated activity before retiring the prior
    /// generated and legacy activities. The call is a no-op when the policy or
    /// selection cannot produce events.
    @discardableResult
    func arm(
        poolMinutes: Int,
        capMinutes: Int,
        selection: FamilyActivitySelection,
        generation: EarnedActivityGeneration.Generation,
        schedule: DeviceActivitySchedule? = nil,
        policyTimeZone: TimeZone = .current
    ) -> Bool {
        let tokenSummary = Self.selectionSummary(selection)
        guard selection.applicationTokens.count > 0
                || selection.categoryTokens.count > 0
                || selection.webDomainTokens.count > 0
        else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped empty-selection pool=\(poolMinutes) cap=\(capMinutes) \(tokenSummary)"
            )
            return false
        }

        let steps = Self.thresholds(poolMinutes: poolMinutes, capMinutes: capMinutes)
        guard !steps.isEmpty else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped no-thresholds pool=\(poolMinutes) cap=\(capMinutes) \(tokenSummary)"
            )
            return false
        }

        let schedule = schedule ?? Self.dailySchedule(timeZone: policyTimeZone)

        // Build one event per threshold step, each measuring the full
        // all-category selection (applicationTokens + categoryTokens).
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in steps {
            let name = DeviceActivityEvent.Name("evlin.earned.t\(minutes)")
            let event = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: minutes)
            )
            events[name] = event
        }

        let installed = EarnedActivityGeneration.installReplacement(
            generation,
            defaults: defaults,
            startMonitoring: { rawName in
                try center.startMonitoring(
                    DeviceActivityName(rawName),
                    during: schedule,
                    events: events
                )
            },
            stopMonitoring: { rawNames in
                center.stopMonitoring(rawNames.map { DeviceActivityName($0) })
            }
        )
        if installed {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "armed activity=\(generation.activityName) events=\(events.count) first=\(steps.first ?? 0) last=\(steps.last ?? 0) pool=\(poolMinutes) cap=\(capMinutes) \(tokenSummary)"
            )
            return true
        } else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "failed startMonitoring pool=\(poolMinutes) cap=\(capMinutes) \(tokenSummary)"
            )
            return false
        }
    }

    @discardableResult
    func armFromNow(
        poolMinutes: Int,
        capMinutes: Int,
        selection: FamilyActivitySelection,
        generation: EarnedActivityGeneration.Generation,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        arm(
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            selection: selection,
            generation: generation,
            schedule: Self.resumeSchedule(
                startingAt: now,
                timeZone: timeZone,
                calendar: calendar
            ),
            policyTimeZone: timeZone
        )
    }

    func recoverInterruptedTransition() {
        EarnedActivityGeneration.recoverPending(
            defaults: defaults,
            stopMonitoring: { rawNames in
                center.stopMonitoring(rawNames.map { DeviceActivityName($0) })
            }
        )
    }

    /// Stop monitoring the earned-budget activity (e.g. at end of day / reset).
    func stop() {
        EarnedActivityGeneration.stopPersisted(
            defaults: defaults,
            stopMonitoring: { rawNames in
                center.stopMonitoring(rawNames.map { DeviceActivityName($0) })
            }
        )
    }

    nonisolated static func selectionSummary(_ selection: FamilyActivitySelection) -> String {
        "apps=\(selection.applicationTokens.count) categories=\(selection.categoryTokens.count) web=\(selection.webDomainTokens.count)"
    }
}
