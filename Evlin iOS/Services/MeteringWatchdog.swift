import DeviceActivity
import FamilyControls
import Foundation
// AuthorizationCenter probe: FamilyControls authorization can be revoked
// out from under a running install (reinstall, Apple ID churn, iOS whim —
// observed repeatedly on real hardware). Schedules SURVIVE revocation, so
// every other probe stays green while not a single callback can ever fire.

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
    /// #95: faults the re-kick cannot repair (a stuck route handoff). Emitted
    /// in the red line for visibility, but they never trigger the heal — a
    /// re-kick against a wedged handoff is churn, not medicine.
    var reportOnlyReds: [String] = []

    var isGreen: Bool { reds.isEmpty && reportOnlyReds.isEmpty && !inconclusive }
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
    /// Seam for probe 4. A unit-test process never holds FamilyControls
    /// authorization, so reading `AuthorizationCenter` directly made every
    /// green-verdict test fail on a condition that only exists off-device.
    private let screenTimeAuthorized: @Sendable () -> Bool

    /// Guards the three throttle timestamps. The watchdog is reachable from the
    /// poll loop and from scene activation, which are not the same task.
    private let throttleLock = NSLock()
    private var lastCheckAt: Date?
    private var lastGreenEmitAt: Date?
    private var lastGreenRouteID: UUID?
    private var lastRekickAt: Date?

    init(
        store: DeviceEpochStore = .shared,
        center: any MeteringDeviceActivityCenter = SystemMeteringDeviceActivityCenter(),
        now: @escaping @Sendable () -> Date = { Date() },
        heal: @escaping @Sendable () async -> String = {
            await MeteringTodayRouteRekick.run(trigger: "watchdog")
        },
        screenTimeAuthorized: @escaping @Sendable () -> Bool = {
            AuthorizationCenter.shared.authorizationStatus == .approved
        }
    ) {
        self.store = store
        self.center = center
        self.now = now
        self.heal = heal
        self.screenTimeAuthorized = screenTimeAuthorized
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
        // `check()` ends in synchronous DeviceActivity XPC — `center.activities`
        // through `perAppReds`, and `MeteringDaemonProbe`. The `nonisolated` on
        // this class buys nothing for that: the production caller is the
        // `Task { @MainActor in ... }` in the background-push handler, and under
        // SWIFT_APPROACHABLE_CONCURRENCY a `nonisolated async` inherits its
        // caller's executor. Only an explicit hop leaves the main thread.
        //
        // A refusal means too many daemon calls are already wedged. Skipping a
        // periodic self-check is the right response to that; the next wake runs
        // it again.
        guard let verdict = await MeteringDeviceActivityGateway.perform(
            "watchdog.check",
            { self.check() }
        ) else { return }
        guard !verdict.inconclusive else { return }

        if verdict.isGreen {
            // Rate-limit the green heartbeat — EXCEPT the first green for a
            // route. The parent-side "armed" attestation requires a ledger
            // green AFTER the current epoch's activation; suppressing that
            // first green left every freshly re-armed device showing SYNCING
            // for up to an hour while its checks were passing (2026-08-05).
            // Repeat greens for the same route stay hourly.
            let shouldEmitGreen: Bool = throttleLock.withLock {
                if verdict.routeID != lastGreenRouteID {
                    lastGreenRouteID = verdict.routeID
                    lastGreenEmitAt = now()
                    return true
                }
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
        let healable = !verdict.reds.isEmpty
        MeteringFlightRecorder.emit(
            kind: .meteringWatch,
            site: "watchdog.selfcheck",
            verdict: "red:" + (verdict.reds + verdict.reportOnlyReds).joined(separator: ","),
            detail: MeteringFlightRecorder.detail([
                ("trigger", trigger),
                ("heal", healable ? (cooling ? "cooling_down" : "rekick") : "none_applicable"),
            ]) + " " + verdict.detail,
            corrID: verdict.routeID
        )
        guard healable, !cooling else { return }
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

    /// Every rule the per-app store considers armed must have its activity
    /// live in the daemon. Report-and-heal: a missing arm is exactly what the
    /// re-kick + owner recovery can repair.
    nonisolated static func perAppReds(
        owner: UUID,
        center: any MeteringDeviceActivityCenter
    ) -> [String] {
        guard let state = try? AppLimitEpochStore.shared.read(),
              state.ownerChildDeviceID == owner
        else { return [] }
        let live = Set(center.activities.map(\.rawValue))
        var reds: [String] = []
        for slot in state.slots.values {
            guard slot.latestKind == .set,
                  let provenance = slot.armProvenance,
                  provenance.monitorStartPending != true
            else { continue }
            if !live.contains(provenance.activityName) {
                reds.append("app_limit_arm_missing")
                break
            }
        }
        return reds
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
        let expectedAccountingPause =
            !EarnedTimeStore.shared.usageCountingAllowed &&
            state.epochs[route.epochID]?.status == .paused
        if let coverageRed,
           !(expectedAccountingPause && coverageRed == "coverage_exhausted") {
            reds.append(coverageRed)
        }

        // 4. Screen Time authorization itself. iOS can revoke it silently
        // mid-life (iPad 2026-08-05 23:xx: authorization OFF while probes 1-3
        // all passed — schedules persist across revocation, so the device
        // showed ACTIVE with both metering stacks stone dead). Report-only:
        // only the user can re-grant; the kid UI surfaces the re-enable.
        var reportOnly: [String] = []
        if !screenTimeAuthorized() {
            reportOnly.append("authorization_revoked")
        }

        // 5. The pool must never sit paused while counting is allowed. Every
        // resume path (foreground poll, background wake, NSE unshield_all)
        // calls the gate reconcile, but that reconcile has a wall of
        // preconditions and any one of them returning silently used to leave
        // the epoch paused with no trace — a freshly onboarded device then
        // showed a full pool that never moved (2026-08-07). Surfacing it makes
        // the parent row honest (SYNCING, not ACTIVE) and puts a line in the
        // black box the moment it happens.
        if EarnedTimeStore.shared.usageCountingAllowed,
           state.epochs[route.epochID]?.status == .paused {
            reportOnly.append("pool_paused_while_allowed")
        }

        // 6. Per-app arms. Until now this self-check covered ONLY the earned
        // ladder, so a green verdict promised nothing about the per-app bars —
        // yet the parent row reads that verdict as "everything is armed"
        // (Fred, 2026-08-07: "if it says active, all three bars must move").
        // Each slot the store believes is armed must be present in the daemon,
        // otherwise the limit is silently unenforced.
        for red in Self.perAppReds(owner: owner, center: center) {
            reds.append(red)
        }

        // 7. #95: a route handoff is a transition, not a place to live. One
        // stuck past the grace wedges the resume mint, the rollover effect
        // leg, or both (iPad 2026-08-05 sat in exactly this state all night
        // with every check reporting green). Report-only: the re-kick cannot
        // repair it.
        if let handoffRed = Self.handoffRed(
            handoff: state.v2RouteHandoff,
            owner: owner,
            now: now()
        ) {
            reportOnly.append(handoffRed)
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
            inconclusive: false,
            reportOnlyReds: reportOnly
        )
    }

    /// How long a non-committed handoff may exist before the watchdog calls
    /// it stuck. Cutover normally completes in seconds; half an hour of
    /// squatting means something in the chain is wedged (or the device is
    /// offline — in which case a red line that uploads on reconnect is
    /// exactly the trace we want).
    static let handoffStuckGraceSeconds: TimeInterval = 30 * 60

    /// Pure decision seam (unit-tested): is the persisted handoff stuck?
    /// `.committed` is history awaiting cleanup debt, never stuck.
    static func handoffRed(
        handoff: V2RouteHandoff?,
        owner: UUID,
        now: Date
    ) -> String? {
        guard let handoff,
              handoff.ownerChildDeviceID == owner,
              handoff.phase != .committed,
              now.timeIntervalSince(handoff.createdAt) > handoffStuckGraceSeconds
        else { return nil }
        return "handoff_stuck_\(handoff.phase.rawValue)"
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
