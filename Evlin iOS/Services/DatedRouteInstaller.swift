import DeviceActivity
import FamilyControls
import Foundation

nonisolated enum DatedRouteInstallResult: Equatable, Sendable {
    case noWork
    case claimed(workID: UUID, token: UUID)
    case adopted(workID: UUID)
    case verified(workID: UUID)
    case deferred(workID: UUID, code: String)
}

/// Process-local coordinator whose operations remain MainActor-isolated, while
/// destruction avoids the MainActor back-deployment deinit shim. Short-lived
/// test and recovery instances otherwise double-free in that shim.
nonisolated final class DatedRouteInstaller: @unchecked Sendable {
    static let claimLeaseSeconds: TimeInterval = 60

    private struct ClaimedReconcileOutcome {
        let result: DatedRouteInstallResult
        let stopFilling: Bool
    }

    private let store: DeviceEpochStore
    private let center: any MeteringDeviceActivityCenter
    private let processIdentity: MeteringProcessIdentity
    private let clock: any MeteringClock

    init(store: DeviceEpochStore = .shared, center: any MeteringDeviceActivityCenter, processIdentity: MeteringProcessIdentity, clock: any MeteringClock = MeteringRuntimeClock.live()) {
        self.store = store
        self.center = center
        self.processIdentity = processIdentity
        self.clock = clock
    }

    func reconcile(ownerChildDeviceID: UUID) throws -> [DatedRouteInstallResult] {
        try stopOrphanedV2Activities(ownerChildDeviceID: ownerChildDeviceID)
        var results: [DatedRouteInstallResult] = []
        for due in try store.dueInstallWork(owner: ownerChildDeviceID, now: clock.now) {
            if try leavesCurrentDayStartForApp(
                due,
                ownerChildDeviceID: ownerChildDeviceID
            ) {
                continue
            }
            if due.authorization == .registrationRequired {
                let superseded = try store.supersedeUnprovenRegistrationRequiredInstall(
                    workID: due.workID,
                    owner: ownerChildDeviceID
                )
                let result = DatedRouteInstallResult.deferred(
                    workID: due.workID,
                    code: superseded ? "routeSuperseded" : "registrationRequired"
                )
                recordInstallOutcome(result, routeID: due.routeID, attempts: due.retry.attemptCount)
                results.append(result)
                continue
            }
            guard let claimed = try store.claimInstallWork(workID: due.workID, owner: ownerChildDeviceID, processIdentity: processIdentity, now: clock.now) else {
                continue
            }
            let outcome = try reconcileClaimed(claimed, owner: ownerChildDeviceID)
            recordInstallOutcome(
                outcome.result,
                routeID: claimed.work.routeID,
                attempts: claimed.work.retry.attemptCount
            )
            results.append(outcome.result)
            if outcome.stopFilling {
                break
            }
        }
        return results
    }

    /// Starting a fresh current-day activity from inside a DeviceActivity
    /// callback can synchronously back-deliver all of its one-shot events into
    /// the same extension process. Those events are then consumed even though
    /// the physical-time guard correctly refuses to credit them. The app owns
    /// fresh current-day starts; the monitor may still adopt interrupted work
    /// and preinstall future dates.
    private func leavesCurrentDayStartForApp(
        _ work: ActivityInstallWork,
        ownerChildDeviceID owner: UUID
    ) throws -> Bool {
        guard processIdentity.role == .deviceActivityMonitor,
              work.phase == .pendingStart
        else { return false }
        let state = try store.read()
        guard state.ownerChildDeviceID == owner,
              let route = state.routes[work.routeID],
              let today = MeteringEpochContract.canonicalUsageDate(
                  at: clock.now,
                  timezoneIdentifier: route.plannedSchedule.timezoneIdentifier
              )
        else { return false }
        return route.usageDate == today
    }

    /// A3: a deferred install is the arming leg failing. It used to leave only
    /// a retry code inside the store, which nothing surfaced — the visible
    /// symptom was simply that the bar never moved.
    private func recordInstallOutcome(
        _ result: DatedRouteInstallResult,
        routeID: UUID,
        attempts: Int
    ) {
        guard case let .deferred(workID, code) = result else { return }
        MeteringFlightRecorder.emit(
            kind: .meteringWork,
            site: "installer.install",
            verdict: "deferred:\(code)",
            detail: MeteringFlightRecorder.detail([
                ("work", MeteringFlightRecorder.shortID(workID)),
                ("attempts", String(attempts)),
            ]),
            nums: ScreenTimeEvent.Nums(count: attempts),
            corrID: routeID
        )
    }

    /// How long a route's measurement window may stay open while the route is
    /// still only `.planned` before we call it stuck.
    ///
    /// Generous on purpose: activation normally completes in seconds, and a
    /// route planned for a FUTURE day is legitimately `.planned` for days — the
    /// staleness test below keys off the window being OPEN, never off age.
    static let plannedWindowStuckGraceSeconds: TimeInterval = 30 * 60

    /// Is this route armed with Apple, counting, and yet unable to credit
    /// anything — permanently?
    ///
    /// `.planned` is a black hole. Two independent rules meet in it:
    ///   - crediting requires `.active` (`callbackRouteAuthorization`), so a
    ///     `.planned` route's callbacks are parked and expire, forever;
    ///   - orphan reconciliation treats `.planned` as DESIRED, so nothing ever
    ///     tears it down.
    /// Both are individually correct. Together they mean a route that arms
    /// (`startMonitoring` runs BEFORE verification) and then fails to verify
    /// stays armed with Apple, invisible to accounting, and immune to cleanup.
    ///
    /// Observed on Liam's iPhone: route FE1FB0AC was planned 2026-07-26 09:52
    /// and spent the next 14 hours receiving a threshold callback every ~15
    /// minutes, discarding every one of them, while the bar only advanced when
    /// the parent happened to foreground the app. Nothing in the system had a
    /// timeout on `.planned`.
    ///
    /// Tearing a stuck route down cannot lose counted time: a `.planned` route
    /// credits nothing by construction. It converts "armed and useless" into
    /// "absent", which the planner can then fix.
    /// BOTH conditions, and neither alone is sufficient:
    ///
    /// - **the window is open.** Dated routes are planned up to eight days
    ///   ahead and sit `.planned` that whole time; tearing those down would
    ///   silently strip every future day of its ladder.
    /// - **it has been `.planned` too long.** Keying off the window alone is
    ///   wrong in the other direction: a route armed at 09:00 for a window that
    ///   opened at midnight is nine hours "open" while being seconds old, and a
    ///   perfectly healthy fresh install would be executed on arrival.
    ///
    /// Routes are born `.planned`, so `createdAt` measures exactly how long this
    /// one has failed to advance.
    private func isStuckPlanned(_ route: MeteringCallbackRoute, now: Date) -> Bool {
        guard route.lifecycle == .planned else { return false }
        guard let openedAt = route.plannedSchedule.intervalStartAt,
              now >= openedAt
        else { return false }
        return now.timeIntervalSince(route.createdAt) > Self.plannedWindowStuckGraceSeconds
    }

    private func stopOrphanedV2Activities(ownerChildDeviceID owner: UUID) throws {
        let state = try store.read()
        guard state.ownerChildDeviceID == owner else { return }
        // An install owner may be between daemon mutation and durable adoption.
        // Let that lease finish before performing global orphan reconciliation.
        guard !state.installWork.values.contains(where: {
            $0.ownerChildDeviceID == owner
                && $0.phase == .starting
                && $0.claim != nil
        }) else { return }
        let now = clock.now
        let stuck = state.routes.values.filter {
            $0.ownerChildDeviceID == owner && isStuckPlanned($0, now: now)
        }
        for route in stuck {
            // A stuck route was silent for 14 hours once. It never will be again.
            MeteringFlightRecorder.emit(
                kind: .meteringWork,
                site: "installer.orphan",
                verdict: "stuck_planned_window_open",
                detail: MeteringFlightRecorder.detail([
                    ("act", route.activityName),
                    ("openedAt", route.plannedSchedule.intervalStartAt.map(
                        ISO8601DateFormatter().string(from:)
                    ) ?? "-"),
                ]),
                corrID: route.routeID
            )
        }
        let stuckNames = Set(stuck.map(\.activityName))
        let desiredNames = Set(state.routes.values.compactMap { route -> String? in
            guard route.ownerChildDeviceID == owner,
                  route.lifecycle == .planned || route.lifecycle == .active,
                  !stuckNames.contains(route.activityName),
                  state.generations[route.generationID]?.retiredAt == nil
            else { return nil }
            return route.activityName
        })
        let stale = center.activities.filter {
            $0.rawValue.hasPrefix(MeteringRouteNamespace.prefix)
                && !desiredNames.contains($0.rawValue)
        }
        if !stale.isEmpty {
            center.stopMonitoring(stale)
            try store.transaction(expectedOwner: owner) { state in
                for key in state.installWork.keys {
                    guard var work = state.installWork[key],
                          work.ownerChildDeviceID == owner,
                          work.phase == .pendingStart,
                          work.retry.terminal == .pending,
                          work.retry.lastErrorCode == "excessiveActivities"
                    else { continue }
                    work.claim = nil
                    work.retry.nextAttemptAt = clock.now
                    state.installWork[key] = work
                }
            }
        }
        let physicallyInstalledNames = Set(center.activities.map(\.rawValue))
        try store.compactPhysicallyAbsentRetiredHistory(
            owner: owner,
            physicallyInstalledActivityNames: physicallyInstalledNames
        )
    }

    /// Projects the bounded product horizon from Apple's currently installed
    /// activities. Persisted install phases are not sufficient proof: another
    /// Screen Time client or the daemon may have removed a route after Evlin
    /// last wrote its state.
    @discardableResult
    func refreshCoverage(ownerChildDeviceID owner: UUID) throws -> MonitorCoverageState? {
        let state = try store.read()
        guard state.ownerChildDeviceID == owner else { return nil }
        let generation = state.activeGenerationID
            .flatMap { state.generations[$0] }
            ?? state.generations.values
                .filter { $0.childDeviceID == owner && $0.retiredAt == nil }
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.generationID.uuidString.lowercased()
                        < $1.generationID.uuidString.lowercased()
                }
                .first
        guard let generation,
              generation.childDeviceID == owner,
              generation.retiredAt == nil,
              let timeZone = TimeZone(identifier: generation.canonicalTimezone)
        else { return nil }

        guard let today = MeteringEpochContract.canonicalUsageDate(
            at: clock.now,
            timezoneIdentifier: generation.canonicalTimezone
        ) else { return nil }
        let requiredDates = try MeteringHorizonPlanner.requiredUsageDates(
            today: today,
            timeZone: timeZone
        )
        guard let requiredFrom = requiredDates.first,
              let requiredThrough = requiredDates.last
        else { return nil }

        let functioningRouteIDs = Set(state.installWork.values.compactMap { work -> UUID? in
            switch work.phase {
            case .verified, .dualActive, .active:
                return work.routeID
            case .pendingStart, .starting, .installed, .pendingStop, .stopped:
                return nil
            }
        })
        let routesByDate = Dictionary(grouping: state.routes.values.filter {
            $0.ownerChildDeviceID == owner
                && $0.generationID == generation.generationID
                && requiredDates.contains($0.usageDate)
                && state.hasEligibleRouteEpochGeneration(
                    owner: owner,
                    route: $0,
                    epoch: state.epochs[$0.epochID],
                    generation: generation
                )
        }, by: \.usageDate)

        var readyThrough: String?
        // The FIRST date that failed and WHY — `daemonMatches` used to answer
        // with a bare Bool, so a coverage flip to `coverageExhausted` named no
        // culprit and every debugging session started from zero.
        var firstFailure: (usageDate: String, reason: String, summary: String)?
        for usageDate in requiredDates {
            var dateFailure: (reason: String, summary: String)?
            let covered = routesByDate[usageDate, default: []].contains { route in
                guard functioningRouteIDs.contains(route.routeID) else {
                    if dateFailure == nil {
                        dateFailure = ("install_phase", "route=\(MeteringFlightRecorder.shortID(route.routeID))")
                    }
                    return false
                }
                guard let expected = try? expectedConfiguration(for: route, state: state) else {
                    if dateFailure == nil {
                        dateFailure = ("expected_config", "route=\(MeteringFlightRecorder.shortID(route.routeID))")
                    }
                    return false
                }
                let result = probe(
                    activity: DeviceActivityName(route.activityName),
                    expected: expected
                )
                if !result.isHealthy, dateFailure == nil {
                    dateFailure = (result.failure ?? "unknown", result.summary)
                }
                return result.isHealthy
            }
            guard covered else {
                let failure = dateFailure ?? ("no_route", "routes=0")
                firstFailure = (usageDate, failure.reason, failure.summary)
                break
            }
            readyThrough = usageDate
        }

        let errorCode = state.installWork.values
            .filter { work in
                guard let route = state.routes[work.routeID] else { return false }
                return route.generationID == generation.generationID
                    && requiredDates.contains(route.usageDate)
                    && work.retry.lastErrorCode == "excessiveActivities"
                    && work.retry.terminal == .pending
            }
            .map(\.retry.lastErrorCode)
            .compactMap { $0 }
            .first
        let status: MonitorCoverageStatus
        if readyThrough == requiredThrough {
            status = .ready
        } else if readyThrough == nil || (readyThrough ?? "") < today {
            status = .coverageExhausted
        } else {
            status = .installLimited
        }
        let coverage = MonitorCoverageState(
            ownerChildDeviceID: owner,
            requiredFromUsageDate: requiredFrom,
            requiredThroughUsageDate: requiredThrough,
            readyThroughUsageDate: readyThrough,
            status: status,
            refreshedAt: clock.now,
            errorCode: status == .ready ? nil : errorCode
        )
        let priorCoverage = state.coverage
        try store.transaction(expectedOwner: owner) { state in
            state.coverage = coverage
        }
        // Only a CHANGE is worth a line — this runs on every recovery pass and
        // a per-pass green heartbeat would flood the ring buffer.
        if priorCoverage?.status != coverage.status
            || priorCoverage?.readyThroughUsageDate != coverage.readyThroughUsageDate {
            MeteringFlightRecorder.emit(
                kind: .meteringCover,
                site: "installer.coverage",
                verdict: coverage.status.rawValue,
                detail: MeteringFlightRecorder.detail([
                    ("failedOn", firstFailure?.usageDate ?? ""),
                    ("failing", firstFailure?.reason ?? ""),
                    ("probe", firstFailure?.summary ?? ""),
                    ("errCode", coverage.errorCode ?? ""),
                ]),
                transition: ScreenTimeEvent.Transition(
                    before: "\(priorCoverage?.status.rawValue ?? "none")@\(priorCoverage?.readyThroughUsageDate ?? "nil")",
                    after: "\(coverage.status.rawValue)@\(coverage.readyThroughUsageDate ?? "nil")"
                )
            )
        }
        return coverage
    }

    private func reconcileClaimed(_ claimed: (work: ActivityInstallWork, priorPhase: ActivityInstallPhase, claim: ActivityInstallClaim), owner: UUID) throws -> ClaimedReconcileOutcome {
        let state: DeviceEpochStoreState
        do {
            state = try store.read()
        } catch {
            return ClaimedReconcileOutcome(
                result: try deferClaimedWork(claimed, owner: owner, code: "configurationFailed", installLimited: false),
                stopFilling: false
            )
        }
        guard let route = state.routes[claimed.work.routeID] else {
            return ClaimedReconcileOutcome(
                result: try deferClaimedWork(claimed, owner: owner, code: "missingRoute", installLimited: false),
                stopFilling: false
            )
        }
        guard state.hasCurrentInstallProvenance(
            owner: owner,
            route: route,
            authorization: claimed.work.authorization
        ) else {
            let superseded = try store.supersedeInstallWork(
                workID: claimed.work.workID,
                token: claimed.claim.token,
                owner: owner,
                now: clock.now
            )
            return ClaimedReconcileOutcome(
                result: .deferred(workID: claimed.work.workID, code: superseded ? "routeSuperseded" : "claimLost"),
                stopFilling: false
            )
        }
        let expected: (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])
        do {
            expected = try expectedConfiguration(for: route, state: state)
        } catch {
            return ClaimedReconcileOutcome(
                result: try deferClaimedWork(claimed, owner: owner, code: "configurationFailed", installLimited: false),
                stopFilling: false
            )
        }
        let activity = DeviceActivityName(route.activityName)

        if claimed.priorPhase != .pendingStart, daemonMatches(activity: activity, expected: expected) {
            guard try store.recordVerifiedRoute(workID: claimed.work.workID, token: claimed.claim.token, owner: owner, now: clock.now) else {
                return ClaimedReconcileOutcome(result: .deferred(workID: claimed.work.workID, code: "claimLost"), stopFilling: false)
            }
            return ClaimedReconcileOutcome(
                result: claimed.priorPhase == .starting ? .adopted(workID: claimed.work.workID) : .verified(workID: claimed.work.workID),
                stopFilling: false
            )
        }

        // Never RE-arm a day that is already over. `startMonitoring` for a
        // finished interval throws `invalidDateComponents` — observed on iPhone
        // 2026-07-25, where a device wedged on the previous day kept re-arming
        // yesterday's route and threw every single time. Re-arming is the
        // damaging direction: `absorbCreditedProgressForRearm` has already moved
        // the ledger by the time Apple refuses, and the route the daemon was
        // holding does not come back. Deferring is cheaper (no XPC round trip)
        // and names the real cause.
        //
        // Deliberately scoped to routes that were already started at least once
        // (`priorPhase != .pendingStart`). A never-armed route for a past day is
        // self-limiting: `hasCurrentInstallProvenance` drops it as soon as it
        // falls out of the generation's current horizon, so it is superseded
        // rather than retried, and no ledger has moved.
        if claimed.priorPhase != .pendingStart,
           let routeTimeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier),
           MeteringDatedSchedule.hasElapsed(
               usageDate: route.usageDate,
               timeZone: routeTimeZone,
               now: clock.now
           ) {
            MeteringFlightRecorder.emitFailure(
                site: "installer.install",
                verdict: "usage_date_elapsed",
                detail: MeteringFlightRecorder.detail([
                    ("date", route.usageDate),
                    ("phase", claimed.priorPhase.rawValue),
                ]),
                corrID: route.routeID
            )
            return ClaimedReconcileOutcome(
                result: try deferClaimedWork(
                    claimed,
                    owner: owner,
                    code: "usageDateElapsed",
                    installLimited: false
                ),
                stopFilling: false
            )
        }

        do {
            // Re-arming restarts Apple's counter at zero; carry what this route
            // already earned into the base so the ladder's next rung still means
            // "5 more minutes" instead of dead time (see the method's comment).
            try store.absorbCreditedProgressForRearm(
                routeID: route.routeID,
                owner: owner,
                trigger: "install:\(claimed.priorPhase.rawValue)"
            )
            // Arm what the store holds NOW. The absorb re-cuts the ladder in its
            // own transaction, so `expected` — read before it — describes rungs
            // priced against the OLD base. Arming those would recreate BUG 1 on
            // the successful path: the daemon holding a ladder the store has
            // already re-priced.
            let armed = try expectedConfigurationAfterAbsorb(
                routeID: route.routeID,
                fallback: expected
            )
            try center.startMonitoring(activity, during: armed.schedule, events: armed.events)
            guard try store.recordInstalledRoute(workID: claimed.work.workID, token: claimed.claim.token, owner: owner, now: clock.now) else {
                return ClaimedReconcileOutcome(result: .deferred(workID: claimed.work.workID, code: "claimLost"), stopFilling: false)
            }
            guard daemonMatches(activity: activity, expected: armed) else {
                guard try store.deferInstallWork(workID: claimed.work.workID, token: claimed.claim.token, owner: owner, now: clock.now, code: "verificationFailed", installLimited: false) else {
                    return ClaimedReconcileOutcome(result: .deferred(workID: claimed.work.workID, code: "claimLost"), stopFilling: false)
                }
                return ClaimedReconcileOutcome(result: .deferred(workID: claimed.work.workID, code: "verificationFailed"), stopFilling: false)
            }
            guard try store.recordVerifiedRoute(workID: claimed.work.workID, token: claimed.claim.token, owner: owner, now: clock.now) else {
                return ClaimedReconcileOutcome(result: .deferred(workID: claimed.work.workID, code: "claimLost"), stopFilling: false)
            }
            return ClaimedReconcileOutcome(result: .verified(workID: claimed.work.workID), stopFilling: false)
        } catch {
            let isExcessive = (error as? DeviceActivityCenter.MonitoringError) == .excessiveActivities
            let code = isExcessive ? "excessiveActivities" : "startFailed"
#if DEBUG
            if isExcessive {
                let activityNames = center.activities
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ",")
                print(
                    "[MeteringDaemonCapacity] count=\(center.activities.count) "
                        + "attempted=\(activity.rawValue) active=\(activityNames)"
                )
            }
#endif
            // Arming the daemon failed. Before A3 this only ever reached a
            // DEBUG `print` plus a retry code buried in the store, so a device
            // that could not arm looked identical to one that simply had no
            // usage yet.
            MeteringFlightRecorder.emitError(
                site: "installer.start",
                error: error,
                detail: MeteringFlightRecorder.detail([
                    ("code", code),
                    ("activities", String(center.activities.count)),
                    ("phase", claimed.priorPhase.rawValue),
                ]),
                corrID: route.routeID
            )
            guard try store.deferInstallWork(workID: claimed.work.workID, token: claimed.claim.token, owner: owner, now: clock.now, code: code, installLimited: isExcessive) else {
                return ClaimedReconcileOutcome(
                    result: .deferred(workID: claimed.work.workID, code: "claimLost"),
                    stopFilling: isExcessive
                )
            }
            return ClaimedReconcileOutcome(
                result: .deferred(workID: claimed.work.workID, code: code),
                stopFilling: isExcessive
            )
        }
    }

    private func deferClaimedWork(
        _ claimed: (work: ActivityInstallWork, priorPhase: ActivityInstallPhase, claim: ActivityInstallClaim),
        owner: UUID,
        code: String,
        installLimited: Bool
    ) throws -> DatedRouteInstallResult {
        guard try store.deferInstallWork(
            workID: claimed.work.workID,
            token: claimed.claim.token,
            owner: owner,
            now: clock.now,
            code: code,
            installLimited: installLimited
        ) else {
            return .deferred(workID: claimed.work.workID, code: "claimLost")
        }
        return .deferred(workID: claimed.work.workID, code: code)
    }

    /// Re-reads the route after `absorbCreditedProgressForRearm` and rebuilds the
    /// configuration from the ladder it left behind. Falls back to the
    /// pre-absorb configuration when the route or its expected configuration
    /// cannot be rebuilt — arming the previous shape is strictly better than
    /// arming nothing, and the coverage probe catches the mismatch.
    private func expectedConfigurationAfterAbsorb(
        routeID: UUID,
        fallback: (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])
    ) throws -> (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) {
        guard let state = try? store.read(),
              let refreshed = state.routes[routeID],
              let rebuilt = try? expectedConfiguration(for: refreshed, state: state)
        else { return fallback }
        return rebuilt
    }

    private func expectedConfiguration(for route: MeteringCallbackRoute, state: DeviceEpochStoreState) throws -> (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) {
        guard let timeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier), let generation = state.generations[route.generationID] else {
            throw MeteringDatedScheduleError.invalidUsageDate(route.usageDate)
        }
        let selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: generation.measurementSelectionBytes)
        var eventNames = Set<String>()
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        // The 2026-07-24 A/B that capped this at the two lowest thresholds was
        // measuring the interval-anchor bug (see `MeteringDatedSchedule`), not
        // the event count. Keeping the cap after that fix meant the daemon only
        // ever held t5 and t10: both fired exactly on schedule and then the bar
        // froze for good, because no further rung existed on Apple's side even
        // though the route had planned 30 of them.
        let plannedEventPlans = route.plannedEvents

        for plan in plannedEventPlans {
            guard plan.thresholdMinutes > 0,
                  plan.eventName == MeteringRouteNamespace.eventName(
                      routeID: route.routeID,
                      thresholdMinutes: plan.thresholdMinutes
                  ),
                  eventNames.insert(plan.eventName).inserted
            else {
                throw MeteringDatedScheduleError.invalidUsageDate(route.usageDate)
            }
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

    /// Delegates to the shared `MeteringDaemonProbe` so the installer, the
    /// debug re-kick report and the A3 watchdog can never drift apart on what
    /// "the daemon matches" means.
    private func daemonMatches(activity: DeviceActivityName, expected: (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])) -> Bool {
        probe(activity: activity, expected: expected).isHealthy
    }

    private func probe(
        activity: DeviceActivityName,
        expected: (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])
    ) -> MeteringDaemonProbeResult {
        MeteringDaemonProbe.probe(
            center: center,
            activity: activity,
            expectedSchedule: expected.schedule,
            expectedEvents: expected.events
        )
    }
}
