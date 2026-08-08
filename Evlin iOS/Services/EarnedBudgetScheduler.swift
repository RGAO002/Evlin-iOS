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
    nonisolated static let earnedBucketMinutes = MeteringDatedSchedule.earnedBucketMinutes

    /// Hard ceiling on DeviceActivity events per route. Policies through 240
    /// minutes use five-minute buckets; larger policies use adaptive spacing.
    nonisolated static let guardEventCount = MeteringDatedSchedule.guardEventCount

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
        MeteringDatedSchedule.thresholds(poolMinutes: poolMinutes, capMinutes: capMinutes)
    }

    nonisolated static func remainingPolicy(
        poolMinutes: Int,
        capMinutes: Int,
        offsetMinutes: Int
    ) -> (poolMinutes: Int, capMinutes: Int)? {
        MeteringDatedSchedule.remainingPolicy(
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            offsetMinutes: offsetMinutes
        )
    }

    /// V1 earned ladders are retired. Existing activity names remain readable
    /// only so cleanup can stop them; no foreground path may create another.
    nonisolated static func canInstallLegacyLadder(
        localSelection: MeteringLocalProtocolSelection?
    ) -> Bool {
        _ = localSelection
        return false
    }

    nonisolated static func makeEvent(
        selection: FamilyActivitySelection,
        thresholdMinutes: Int
    ) -> DeviceActivityEvent {
        MeteringDatedSchedule.makeEvent(
            selection: selection,
            thresholdMinutes: thresholdMinutes
        )
    }

    nonisolated static func datedSchedule(
        usageDate: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DeviceActivitySchedule {
        try MeteringDatedSchedule.datedSchedule(
            usageDate: usageDate,
            timeZone: timeZone,
            calendar: calendar
        )
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
        generation: LegacyGenerationProvenance,
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
            events[name] = Self.makeEvent(
                selection: selection,
                thresholdMinutes: minutes
            )
        }

        guard let owner = UUID(uuidString: generation.deviceID) else { return false }
        let installed = LegacyMeteringActivity.installReplacement(
            generation,
            store: .shared,
            owner: owner,
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
        generation: LegacyGenerationProvenance,
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
        guard let owner = defaults?.string(forKey: "evlin.childId")
            .flatMap(UUID.init(uuidString:)) else { return }
        LegacyMeteringActivity.recoverInterruptedTransition(
            store: .shared,
            owner: owner,
            stopMonitoring: { rawNames in
                center.stopMonitoring(rawNames.map { DeviceActivityName($0) })
            }
        )
    }

    /// Stop monitoring the earned-budget activity (e.g. at end of day / reset).
    func stop() {
        guard let owner = defaults?.string(forKey: "evlin.childId")
            .flatMap(UUID.init(uuidString:)) else {
            center.stopMonitoring([DeviceActivityName(LegacyMeteringActivity.legacyActivityName)])
            return
        }
        LegacyMeteringActivity.stopPersisted(
            store: .shared,
            owner: owner,
            stopMonitoring: { rawNames in
                center.stopMonitoring(rawNames.map { DeviceActivityName($0) })
            }
        )
    }

    nonisolated static func selectionSummary(_ selection: FamilyActivitySelection) -> String {
        "apps=\(selection.applicationTokens.count) categories=\(selection.categoryTokens.count) web=\(selection.webDomainTokens.count)"
    }
}
