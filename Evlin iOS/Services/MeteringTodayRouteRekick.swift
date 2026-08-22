import Foundation
import DeviceActivity
import FamilyControls

/// Debug-only: stop + start TODAY's active dated route under the SAME activity
/// name and configuration. Apple's daemon re-evaluates a re-registered activity
/// and immediately back-delivers threshold events already met by the day's
/// ledger (proven 2026-07-23 topology-8 reinstall and 2026-07-24 19:13 instant
/// t480). Recovers events whose instant back-delivery raced route activation
/// and was discarded by the provenance guard — by the time this runs, the
/// route is fully active, so the redelivered callback passes the guard.
enum MeteringTodayRouteRekick {
    /// Production recovery for an active route that disappeared from Apple's
    /// daemon. Unlike `run`, this never reuses consumed activity/event names.
    /// It prepares the existing make-before-break handoff, then lets the normal
    /// recovery driver install, register, verify and activate the fresh route.
    static func replaceMissingActiveRoute(
        trigger: String,
        role: MeteringProcessRole = .app
    ) async -> String {
        guard let preparation = await MeteringDeviceActivityGateway.perform(
            "missingRoute.prepare",
            { prepareMissingActiveRoute() }
        ) else {
            return "missing-route recovery refused: Screen Time gateway busy"
        }
        guard preparation.prepared else { return preparation.message }

        do {
            let outcome = try await MeteringProductionComposition
                .recoverFromSharedConfiguration(role: role)
            return "fresh route prepared for \(preparation.routeID?.uuidString ?? "unknown"); recovery=\(outcome) trigger=\(trigger)"
        } catch {
            return "fresh route prepared; recovery failed: \(error)"
        }
    }

    /// - Parameter trigger: who asked — `manual` for the debug button,
    ///   `watchdog` for the A3 self-heal. Recorded so an auto-heal loop is
    ///   distinguishable from a human hammering the button.
    @discardableResult
    static func run(
        trigger: String = "manual",
        role: MeteringProcessRole = .app
    ) async -> String {
        await runReport(trigger: trigger, role: role).message
    }

    static func runReport(
        trigger: String = "manual",
        role: MeteringProcessRole = .app
    ) async -> Report {
        // One hop for the whole rekick, not four. `perform` is a single coherent
        // daemon operation — stop, start, coverage refresh, probe — and splitting
        // it would let another arm interleave in the middle of it.
        //
        // This matters more here than anywhere else: the watchdog calls this
        // exactly when it has just seen a red, which usually means the Screen
        // Time daemon is already unhealthy. Self-healing on the main thread is
        // running the riskiest daemon call at the moment it is most likely to
        // hang, and a hang there killed the app on 2026-08-08.
        guard let report = await MeteringDeviceActivityGateway.perform("rekick.perform", {
            perform(trigger: trigger, role: role)
        }) else {
            return Report(
                verdict: "gateway_busy",
                message: "rekick refused: Screen Time gateway busy",
                routeID: nil
            )
        }
        MeteringFlightRecorder.emit(
            kind: .meteringRepair,
            site: "rekick.run",
            verdict: report.verdict,
            detail: MeteringFlightRecorder.detail([
                ("trigger", trigger),
                ("report", report.message),
            ]),
            corrID: report.routeID
        )
        return report
    }

    nonisolated struct Report: Sendable {
        let verdict: String
        let message: String
        let routeID: UUID?

        var isHealthy: Bool { verdict == "rearmed" }
    }

    nonisolated private struct MissingRoutePreparation: Sendable {
        let prepared: Bool
        let message: String
        let routeID: UUID?
    }

    nonisolated private static func prepareMissingActiveRoute() -> MissingRoutePreparation {
        let store = DeviceEpochStore.shared
        let state: DeviceEpochStoreState
        do {
            state = try store.read()
        } catch {
            return MissingRoutePreparation(
                prepared: false,
                message: "missing-route recovery read failed: \(error)",
                routeID: nil
            )
        }
        guard let routeID = state.activeRouteID,
              let route = state.routes[routeID],
              route.lifecycle == .active,
              let timeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)
        else {
            return MissingRoutePreparation(
                prepared: false,
                message: "no active route to replace",
                routeID: state.activeRouteID
            )
        }
        guard !MeteringDatedSchedule.hasElapsed(
            usageDate: route.usageDate,
            timeZone: timeZone,
            now: Date()
        ) else {
            return MissingRoutePreparation(
                prepared: false,
                message: "missing route belongs to elapsed day \(route.usageDate)",
                routeID: routeID
            )
        }

        let liveActivities = Set(
            SystemMeteringDeviceActivityCenter().activities.map(\.rawValue)
        )
        guard !liveActivities.contains(route.activityName) else {
            return MissingRoutePreparation(
                prepared: false,
                message: "active route returned before recovery",
                routeID: routeID
            )
        }

        do {
            let prepared = try store.replaceMissingActiveRouteIfNeeded(
                owner: route.ownerChildDeviceID,
                missingRouteID: routeID,
                now: Date()
            )
            return MissingRoutePreparation(
                prepared: prepared,
                message: prepared
                    ? "fresh physical route prepared"
                    : "route state no longer permits replacement",
                routeID: routeID
            )
        } catch {
            return MissingRoutePreparation(
                prepared: false,
                message: "missing-route recovery failed: \(error)",
                routeID: routeID
            )
        }
    }

    /// NOT `@MainActor`: every DeviceActivity call below is synchronous XPC, and
    /// `run` hops this whole function off the main thread. It touches only
    /// `DeviceEpochStore.shared`, which is `nonisolated` and internally locked.
    nonisolated private static func perform(
        trigger: String,
        role: MeteringProcessRole
    ) -> Report {
        let store = DeviceEpochStore.shared
        let state: DeviceEpochStoreState
        do {
            state = try store.read()
        } catch {
            return Report(verdict: "read_failed", message: "read failed: \(error)", routeID: nil)
        }
        guard let routeID = state.activeRouteID,
              let route = state.routes[routeID],
              route.lifecycle == .active,
              let generation = state.generations[route.generationID],
              let timeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)
        else {
            return Report(
                verdict: "no_active_route",
                message: "no active route to re-kick",
                routeID: state.activeRouteID
            )
        }

        // Re-kicking a day that is already over is actively destructive: this
        // routine STOPS before it starts, and Apple then refuses the restart
        // with `invalidDateComponents`, leaving the daemon holding nothing at
        // all. That is exactly what the watchdog did on iPhone 2026-07-25 while
        // the device was wedged on the previous day. A stale active route is a
        // rollover/replacement problem, not something a re-arm can heal.
        guard !MeteringDatedSchedule.hasElapsed(
            usageDate: route.usageDate,
            timeZone: timeZone,
            now: Date()
        ) else {
            return Report(
                verdict: "usage_date_elapsed",
                message: "active route is \(route.usageDate), which is already over — not re-arming",
                routeID: routeID
            )
        }

        let selection: FamilyActivitySelection
        do {
            selection = try JSONDecoder().decode(
                FamilyActivitySelection.self,
                from: generation.measurementSelectionBytes
            )
        } catch {
            return Report(
                verdict: "selection_decode_failed",
                message: "selection decode failed: \(error)",
                routeID: routeID
            )
        }

        let schedule: DeviceActivitySchedule
        do {
            schedule = try MeteringDatedSchedule.datedSchedule(
                usageDate: route.usageDate,
                timeZone: timeZone,
                intervalStartAt: route.plannedSchedule.intervalStartAt
            )
        } catch {
            return Report(
                verdict: "schedule_rebuild_failed",
                message: "schedule rebuild failed: \(error)",
                routeID: routeID
            )
        }

        // The audited adapter, not a raw DeviceActivityCenter: every call below
        // is synchronous XPC, and a raw center bypasses both the main-thread
        // audit and any hope of a static check noticing.
        let center = SystemMeteringDeviceActivityCenter()
        let name = DeviceActivityName(route.activityName)
        // Same reason as the installer's re-arm: carry credited progress into the
        // base so restarting Apple's counter costs no dead time.
        try? store.absorbCreditedProgressForRearm(
            routeID: route.routeID,
            owner: route.ownerChildDeviceID,
            trigger: "rekick:\(trigger)"
        )
        // Build the event set from what the store holds AFTER the absorb: the
        // absorb re-cuts the ladder for the carried base, and arming the rungs
        // read before it would leave Apple holding a ladder priced against a
        // base that no longer exists — BUG 1's exact shape.
        let armedRoute = (try? store.read().routes[route.routeID]) ?? route
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for plan in armedRoute.plannedEvents {
            events[DeviceActivityEvent.Name(plan.eventName)] = MeteringDatedSchedule.makeEvent(
                selection: selection,
                thresholdMinutes: plan.thresholdMinutes
            )
        }
        center.stopMonitoring([name])
        do {
            try center.startMonitoring(name, during: schedule, events: events)
        } catch {
            return Report(
                verdict: "start_monitoring_failed",
                message: "startMonitoring failed: \(error)",
                routeID: routeID
            )
        }

        // Refresh coverage IN THIS TURN, before Apple's back-delivery lands.
        //
        // `stopMonitoring` above makes `daemonMatches` fail for today's route,
        // which flips coverage to `coverageExhausted`; `hasCallbackCoverage`
        // then discards every callback as `epoch_not_active`. Apple re-delivers
        // the already-met thresholds ~1s after `startMonitoring`, but coverage
        // is only recomputed at the END of the next recovery pass — up to 10s
        // later. So the re-kick reliably destroyed its own delivery: measured on
        // iPad 2026-07-25, every tap produced a v2 callback that was dropped
        // while coverage was still stale, and coverage went green seconds after.
        do {
            _ = try DatedRouteInstaller(
                store: store,
                center: SystemMeteringDeviceActivityCenter(),
                processIdentity: MeteringProcessIdentity(
                    role: role,
                    instanceID: MeteringProductionComposition.instanceID(for: role)
                )
            ).refreshCoverage(ownerChildDeviceID: route.ownerChildDeviceID)
        } catch {
            return Report(
                verdict: "coverage_refresh_failed",
                message: "re-armed but coverage refresh failed: \(error)",
                routeID: routeID
            )
        }
        // Report what Apple actually holds versus what we expect, via the SAME
        // shared probe the installer's coverage refresh and the A3 watchdog
        // use — three hand-rolled copies of this comparison is how they drifted
        // apart. The probe names WHICH of the four comparisons (registration,
        // schedule, event set, event payload) is the one failing.
        let result = MeteringDaemonProbe.probe(
            center: center,
            activity: name,
            expectedSchedule: schedule,
            expectedEvents: events
        )
        let thresholds = armedRoute.plannedEvents
            .map { String($0.thresholdMinutes) }
            .sorted()
            .joined(separator: ",")
        return Report(
            verdict: result.isHealthy ? "rearmed" : "rearmed_\(result.failure ?? "unhealthy")",
            message: "Re-kicked [t\(thresholds)] — activities=\(result.daemonActivityCount) \(result.summary)",
            routeID: routeID
        )
    }
}
