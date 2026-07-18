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

@MainActor
final class DatedRouteInstaller {
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
        guard state.hasCurrentRegistrationProvenance(owner: owner, epochID: route.epochID, routeID: route.routeID) else {
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
        for plan in route.plannedEvents {
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
        return (try MeteringDatedSchedule.datedSchedule(usageDate: route.usageDate, timeZone: timeZone), events)
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
