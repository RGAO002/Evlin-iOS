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
            if due.authorization == .registrationRequired {
                results.append(.deferred(workID: due.workID, code: "registrationRequired"))
                continue
            }
            guard let claimed = try store.claimInstallWork(workID: due.workID, owner: ownerChildDeviceID, processIdentity: processIdentity, now: clock.now) else {
                continue
            }
            let outcome = try reconcileClaimed(claimed, owner: ownerChildDeviceID)
            results.append(outcome.result)
            if outcome.stopFilling {
                break
            }
        }
        return results
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
        let desiredNames = Set(state.routes.values.compactMap { route -> String? in
            guard route.ownerChildDeviceID == owner,
                  route.lifecycle == .planned || route.lifecycle == .active,
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
        for usageDate in requiredDates {
            let covered = routesByDate[usageDate, default: []].contains { route in
                guard functioningRouteIDs.contains(route.routeID),
                      let expected = try? expectedConfiguration(for: route, state: state)
                else { return false }
                return daemonMatches(
                    activity: DeviceActivityName(route.activityName),
                    expected: expected
                )
            }
            guard covered else { break }
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
        try store.transaction(expectedOwner: owner) { state in
            state.coverage = coverage
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

        do {
            try center.startMonitoring(activity, during: expected.schedule, events: expected.events)
            guard try store.recordInstalledRoute(workID: claimed.work.workID, token: claimed.claim.token, owner: owner, now: clock.now) else {
                return ClaimedReconcileOutcome(result: .deferred(workID: claimed.work.workID, code: "claimLost"), stopFilling: false)
            }
            guard daemonMatches(activity: activity, expected: expected) else {
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

    private func expectedConfiguration(for route: MeteringCallbackRoute, state: DeviceEpochStoreState) throws -> (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) {
        guard let timeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier), let generation = state.generations[route.generationID] else {
            throw MeteringDatedScheduleError.invalidUsageDate(route.usageDate)
        }
        let selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: generation.measurementSelectionBytes)
        var eventNames = Set<String>()
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
#if DEBUG
        // DIAGNOSTIC A/B (2026-07-24): per-app activities with 1-2 events fire on
        // device; earned activities with 12-24 events never fire. Install only the
        // two lowest thresholds to isolate "too many events per activity" as the
        // cause. Store keeps all planned events; only the daemon install is capped.
        // REMOVE after the experiment concludes.
        let plannedEventPlans = route.plannedEvents
            .sorted { $0.thresholdMinutes < $1.thresholdMinutes }
            .prefix(2)
#else
        let plannedEventPlans = route.plannedEvents
#endif
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

    private func daemonMatches(activity: DeviceActivityName, expected: (schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent])) -> Bool {
        guard center.activities.contains(activity), let schedule = center.schedule(for: activity), exactSchedule(schedule, expected.schedule) else { return false }
        let events = center.events(for: activity)
        guard events.keys == expected.events.keys else { return false }
        return events.allSatisfy { name, event in
            guard let expectedEvent = expected.events[name] else { return false }
            return event.applications == expectedEvent.applications
                && event.categories == expectedEvent.categories
                && event.webDomains == expectedEvent.webDomains
                && event.threshold == expectedEvent.threshold
                && event.includesPastActivity == expectedEvent.includesPastActivity
        }
    }

    private func exactSchedule(_ lhs: DeviceActivitySchedule, _ rhs: DeviceActivitySchedule) -> Bool {
        lhs.intervalStart == rhs.intervalStart
            && lhs.intervalEnd == rhs.intervalEnd
            && lhs.repeats == rhs.repeats
            && lhs.warningTime == rhs.warningTime
    }
}
