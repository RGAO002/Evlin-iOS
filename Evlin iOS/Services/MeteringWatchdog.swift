import DeviceActivity
import FamilyControls
import Foundation

/// One self-check of today's metering route against Apple's daemon + the store.
nonisolated struct MeteringWatchdogVerdict: Equatable, Sendable {
    /// Named reds, in the order they were checked. Empty ⇒ all green.
    var reds: [String]
    /// Compact `k=v` description of what was observed.
    var detail: String
    /// The route the check ran against (nil when there was nothing to check).
    var routeID: UUID?
    /// True when the check could not run at all (no active route, no owner) —
    /// this is NOT a red: a device with no armed day has nothing to heal.
    var inconclusive: Bool

    var isGreen: Bool { reds.isEmpty && !inconclusive }
}

/// A3 — periodic self-check + self-heal for the metering engine.
///
/// The engine has three independent ways to go quiet, and none of them used to
/// announce itself:
///   1. Apple's daemon no longer holds today's activity (capacity churn, a
///      Screen Time reset, another client) — no callback can ever arrive.
///   2. The daemon holds it but with a drifted event set / payload — the rungs
///      that fire are not the rungs the store planned.
///   3. The store's own `coverage` is stale or exhausted, so `hasCallbackCoverage`
///      discards every arriving callback as `epoch_not_active`.
/// All three are repaired by exactly one action: re-kick today's route
/// (`MeteringTodayRouteRekick`, which absorbs credited progress first, so
/// re-arming costs no dead time and has no dead zone).
///
/// Runs in the MAIN APP ONLY. The extension gets seconds of CPU per callback and
/// must never spend them on XPC round trips it did not need; the app both
/// forgrounds regularly and already runs a 10 s recovery poll.
///
/// Throttling is deliberate and doubled up:
///   - `selfCheckInterval` (5 min) bounds how often the check itself runs, so
///     the poll loop calling in every 10 s is free.
///   - `rekickCooldown` (10 min) bounds the HEALING action independently. A
///     re-kick that does not fix the red must never turn into a re-kick loop —
///     each one stops and restarts Apple's monitoring, and a tight loop there
///     would be worse than the fault.
///
/// nonisolated (NOT @MainActor, despite only running in the app): the check
/// makes synchronous DeviceActivity XPC calls, which must never block the main
/// thread's scene-update watchdog — the same reason `EarnedMeteringRecoveryDriver`
/// and `DatedRouteInstaller` are nonisolated. It also avoids the MainActor
/// back-deployment deinit shim, which double-frees short-lived instances (a
/// documented hazard in this codebase, reproduced here by a temporary watchdog
/// in a unit test).
nonisolated final class MeteringWatchdog: @unchecked Sendable {
    static let shared = MeteringWatchdog()

    static let selfCheckInterval: TimeInterval = 5 * 60
    static let rekickCooldown: TimeInterval = 10 * 60
    /// A green run is a heartbeat, not news — at most one per hour, so a
    /// healthy device does not spend its ring buffer on "still fine".
    static let greenHeartbeatInterval: TimeInterval = 60 * 60

    private let store: DeviceEpochStore
    private let center: any MeteringDeviceActivityCenter
    private let now: @Sendable () -> Date
    private let heal: @Sendable () async -> String

    /// Guards the three throttle timestamps. The watchdog is reachable from the
    /// poll loop and from scene activation, which are not the same task.
    private let throttleLock = NSLock()
    private var lastCheckAt: Date?
    private var lastGreenEmitAt: Date?
    private var lastRekickAt: Date?

    init(
        store: DeviceEpochStore = .shared,
        center: any MeteringDeviceActivityCenter = SystemMeteringDeviceActivityCenter(),
        now: @escaping @Sendable () -> Date = { Date() },
        heal: @escaping @Sendable () async -> String = {
            await MeteringTodayRouteRekick.run(trigger: "watchdog")
        }
    ) {
        self.store = store
        self.center = center
        self.now = now
        self.heal = heal
    }

    /// Throttled entry point. Safe to call from every foreground transition and
    /// every recovery poll tick.
    func runIfDue(trigger: String) async {
        let current = now()
        let due: Bool = throttleLock.withLock {
            if let lastCheckAt, current.timeIntervalSince(lastCheckAt) < Self.selfCheckInterval {
                return false
            }
            lastCheckAt = current
            return true
        }
        guard due else { return }
        await run(trigger: trigger)
    }

    /// Unthrottled check + heal. `runIfDue` is the production entry point;
    /// this one exists for the debug button and for tests.
    func run(trigger: String) async {
        let verdict = check()
        guard !verdict.inconclusive else { return }

        if verdict.isGreen {
            // Rate-limit the green heartbeat; reds are never rate-limited.
            let shouldEmitGreen: Bool = throttleLock.withLock {
                if let lastGreenEmitAt,
                   now().timeIntervalSince(lastGreenEmitAt) < Self.greenHeartbeatInterval {
                    return false
                }
                lastGreenEmitAt = now()
                return true
            }
            guard shouldEmitGreen else { return }
            MeteringFlightRecorder.emit(
                kind: .meteringWatch,
                site: "watchdog.selfcheck",
                verdict: "green",
                detail: MeteringFlightRecorder.detail([("trigger", trigger)])
                    + " " + verdict.detail,
                corrID: verdict.routeID
            )
            return
        }

        let cooling: Bool = throttleLock.withLock {
            lastRekickAt.map { now().timeIntervalSince($0) < Self.rekickCooldown } ?? false
        }
        MeteringFlightRecorder.emit(
            kind: .meteringWatch,
            site: "watchdog.selfcheck",
            verdict: "red:" + verdict.reds.joined(separator: ","),
            detail: MeteringFlightRecorder.detail([
                ("trigger", trigger),
                ("heal", cooling ? "cooling_down" : "rekick"),
            ]) + " " + verdict.detail,
            corrID: verdict.routeID
        )
        guard !cooling else { return }
        throttleLock.withLock { lastRekickAt = now() }
        let report = await heal()
        MeteringFlightRecorder.emit(
            kind: .meteringWatch,
            site: "watchdog.heal",
            verdict: "rekicked",
            detail: MeteringFlightRecorder.detail([
                ("reds", verdict.reds.joined(separator: ",")),
                ("report", report),
            ]),
            corrID: verdict.routeID
        )
    }

    // MARK: - Read-only self-check

    /// Pure inspection: reads the store and asks the daemon what it holds.
    /// Mutates nothing, so it is safe to run on any tick.
    func check() -> MeteringWatchdogVerdict {
        let state: DeviceEpochStoreState
        do {
            state = try store.read()
        } catch {
            MeteringFlightRecorder.emitError(site: "watchdog.read", error: error)
            return MeteringWatchdogVerdict(
                reds: [], detail: "store_unreadable", routeID: nil, inconclusive: true
            )
        }
        guard let owner = state.ownerChildDeviceID,
              let routeID = state.activeRouteID,
              let route = state.routes[routeID],
              route.ownerChildDeviceID == owner,
              route.lifecycle == .active,
              let generation = state.generations[route.generationID],
              let timeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)
        else {
            return MeteringWatchdogVerdict(
                reds: [], detail: "no_active_route", routeID: state.activeRouteID, inconclusive: true
            )
        }

        let expected: (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])
        do {
            expected = try Self.expectedConfiguration(
                route: route,
                generation: generation,
                timeZone: timeZone
            )
        } catch {
            // We cannot rebuild what the daemon SHOULD hold, so we cannot judge
            // it — but this is itself a fault worth a line.
            MeteringFlightRecorder.emitError(
                site: "watchdog.expected",
                error: error,
                corrID: routeID
            )
            return MeteringWatchdogVerdict(
                reds: [], detail: "expected_config_failed", routeID: routeID, inconclusive: true
            )
        }

        // 1 + 2. What Apple actually holds, via the SAME probe the installer's
        // coverage refresh uses.
        let probe = MeteringDaemonProbe.probe(
            center: center,
            activity: DeviceActivityName(route.activityName),
            expectedSchedule: expected.schedule,
            expectedEvents: expected.events
        )
        var reds: [String] = []
        if let failure = probe.failure {
            reds.append("daemon_\(failure)")
        }

        // 3. The store's own coverage gate. `hasCallbackCoverage` consults
        // exactly this, so a stale/exhausted coverage silently discards every
        // callback even when the daemon is perfect.
        let coverageRed = Self.coverageRed(
            coverage: state.coverage,
            owner: owner,
            usageDate: route.usageDate
        )
        if let coverageRed {
            reds.append(coverageRed)
        }

        return MeteringWatchdogVerdict(
            reds: reds,
            detail: MeteringFlightRecorder.detail([
                ("probe", probe.summary),
                ("cover", state.coverage?.status.rawValue ?? "none"),
                ("ready", state.coverage?.readyThroughUsageDate ?? "nil"),
                ("date", route.usageDate),
            ]),
            routeID: routeID,
            inconclusive: false
        )
    }

    /// Pure decision seam (unit-tested): is the store's coverage healthy enough
    /// for today's callbacks to be credited?
    static func coverageRed(
        coverage: MonitorCoverageState?,
        owner: UUID,
        usageDate: String
    ) -> String? {
        guard let coverage else { return "coverage_missing" }
        guard coverage.ownerChildDeviceID == owner else { return "coverage_foreign" }
        switch coverage.status {
        case .coverageExhausted:
            return "coverage_exhausted"
        case .installLimited, .ready:
            guard let readyThrough = coverage.readyThroughUsageDate else {
                return "coverage_not_ready"
            }
            return readyThrough >= usageDate ? nil : "coverage_behind"
        }
    }

    /// Rebuilds what the daemon is expected to hold for a route. Mirrors
    /// `DatedRouteInstaller.expectedConfiguration` (which is private to the
    /// installer) using only public store data.
    static func expectedConfiguration(
        route: MeteringCallbackRoute,
        generation: MeteringPolicyGeneration,
        timeZone: TimeZone
    ) throws -> (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) {
        let selection = try JSONDecoder().decode(
            FamilyActivitySelection.self,
            from: generation.measurementSelectionBytes
        )
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for plan in route.plannedEvents {
            events[DeviceActivityEvent.Name(plan.eventName)] = MeteringDatedSchedule.makeEvent(
                selection: selection,
                thresholdMinutes: plan.thresholdMinutes
            )
        }
        return (
            try MeteringDatedSchedule.datedSchedule(
                usageDate: route.usageDate,
                timeZone: timeZone,
                intervalStartAt: route.plannedSchedule.intervalStartAt
            ),
            events
        )
    }
}
