import DeviceActivity
import Foundation

nonisolated enum MeteringRolloverLocalEffect: String, CaseIterable, Hashable, Sendable {
    case earnedSource
    case perApp
    case taskState
    case bypassExpiry
}

private enum EarnedMeteringRecoveryError: Error {
    case invalidRollover(String)
}

@MainActor
final class EarnedMeteringRecoveryDriver {
    private let store: DeviceEpochStore
    private let delivery: MeteringEpochDelivery
    private let installer: DatedRouteInstaller
    private let center: any MeteringDeviceActivityCenter
    private let processIdentity: MeteringProcessIdentity
    private let clock: any MeteringClock
    private let purgeIdentityRetryState: (UUID, [String]) -> Set<String>
    private let releaseIdentityShield: (UUID, UUID) throws -> Void
    private let resetRolloverEffect: (MeteringRolloverLocalEffect, RolloverEffectsWork) throws -> Void

    init(
        store: DeviceEpochStore = .shared,
        delivery: MeteringEpochDelivery,
        installer: DatedRouteInstaller,
        center: any MeteringDeviceActivityCenter,
        processIdentity: MeteringProcessIdentity,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        purgeIdentityRetryState: ((UUID, [String]) -> Set<String>)? = nil,
        releaseIdentityShield: ((UUID, UUID) throws -> Void)? = nil,
        resetRolloverEffect: ((MeteringRolloverLocalEffect, RolloverEffectsWork) throws -> Void)? = nil
    ) {
        self.store = store
        self.delivery = delivery
        self.installer = installer
        self.center = center
        self.processIdentity = processIdentity
        self.clock = clock
        self.purgeIdentityRetryState = purgeIdentityRetryState ?? { owner, keys in
            EarnedSampleReporter.purgeRetryState(deviceID: owner, capturedKeys: keys)
        }
        let effectStore = EarnedShieldEffectStore(epochStore: store)
        self.releaseIdentityShield = releaseIdentityShield ?? { operationID, owner in
            try effectStore.release(operationID: operationID, expectedOwner: owner)
        }
        self.resetRolloverEffect = resetRolloverEffect ?? { _, _ in
            throw EarnedMeteringRecoveryError.invalidRollover("reset adapter unavailable")
        }
    }

    func recover(ownerChildDeviceID owner: UUID) async throws {
        if try recoverIdentityCleanupIfPresent() { return }
        guard store.isCurrentOwner(owner) else { return }
        if try await recoverCanonicalRolloverIfPresent(owner: owner) { return }

        try prepareReplacementIfNeeded(owner: owner)
        await delivery.drain(owner: owner)
        _ = try installer.reconcile(ownerChildDeviceID: owner)
        try promoteVerifiedCandidate(owner: owner)
        await delivery.drain(owner: owner)
        try recoverTerminalInitialActivation(owner: owner)
        try advanceReplacementBarrier(owner: owner)
        await delivery.drain(owner: owner)
        try advanceReplacementBarrier(owner: owner)
        await delivery.drain(owner: owner)
        try promoteAcknowledgedActivation(owner: owner)
        try prepareReplacementIfNeeded(owner: owner)
        try stopRetiredLane(owner: owner)
        try stopAuthoritativeBaseRejectedCandidates(owner: owner)
    }

    private func recoverCanonicalRolloverIfPresent(owner: UUID) async throws -> Bool {
        guard var work = try store.read().rolloverEffectsWork,
              work.ownerChildDeviceID == owner
        else { return false }
        if work.retry.terminal == .succeeded { return false }

        for effect in MeteringRolloverLocalEffect.allCases where !rolloverEffectAcknowledged(effect, work: work) {
            try resetRolloverEffect(effect, work)
            try acknowledgeRolloverEffect(effect, workID: work.workID, owner: owner)
            guard let refreshed = try store.read().rolloverEffectsWork else {
                throw EarnedMeteringRecoveryError.invalidRollover("work disappeared during reset")
            }
            work = refreshed
        }

        // Settle older-due horizon install work before the rollover envelope
        // asks delivery to dispatch its registration and activation children.
        // The exact new-day route must already verify before dualV2 begins.
        _ = try installer.reconcile(ownerChildDeviceID: owner)
        try prepareRolloverHandoff(workID: work.workID, owner: owner)
        try advanceRolloverBarrier(workID: work.workID, owner: owner)
        await delivery.drain(owner: owner)
        try acknowledgeRolloverRegistrationAndEnqueueActivation(workID: work.workID, owner: owner)
        await delivery.drain(owner: owner)
        try commitRolloverActivation(workID: work.workID, owner: owner)
        try stopRolloverPriorRoute(workID: work.workID, owner: owner)
        if try store.read().rolloverEffectsWork?.retry.terminal == .succeeded {
            await delivery.drain(owner: owner)
        }
        return true
    }

    private func rolloverEffectAcknowledged(
        _ effect: MeteringRolloverLocalEffect,
        work: RolloverEffectsWork
    ) -> Bool {
        switch effect {
        case .earnedSource: return work.earnedSourceResetAcknowledged
        case .perApp: return work.perAppResetAcknowledged
        case .taskState: return work.taskStateResetAcknowledged
        case .bypassExpiry: return work.bypassExpiryAcknowledged
        }
    }

    private func acknowledgeRolloverEffect(
        _ effect: MeteringRolloverLocalEffect,
        workID: UUID,
        owner: UUID
    ) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var current = state.rolloverEffectsWork, current.workID == workID else {
                throw EarnedMeteringRecoveryError.invalidRollover("work changed")
            }
            switch effect {
            case .earnedSource: current.earnedSourceResetAcknowledged = true
            case .perApp: current.perAppResetAcknowledged = true
            case .taskState: current.taskStateResetAcknowledged = true
            case .bypassExpiry: current.bypassExpiryAcknowledged = true
            }
            state.rolloverEffectsWork = current
        }
    }

    private func prepareRolloverHandoff(workID: UUID, owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var work = state.rolloverEffectsWork, work.workID == workID,
                  let oldRoute = state.routes[work.oldRouteID],
                  let newRoute = state.routes[work.newRouteID],
                  oldRoute.epochID == work.oldEpochID,
                  newRoute.epochID == work.newEpochID,
                  oldRoute.usageDate == work.fromUsageDate,
                  newRoute.usageDate == work.toUsageDate,
                  state.activeRouteID == oldRoute.routeID,
                  state.activeEpochID == oldRoute.epochID,
                  oldRoute.lifecycle == .active,
                  let newInstallID = uniqueInstallKey(for: newRoute.routeID, in: state),
                  state.installWork[newInstallID]?.phase == .verified
            else { return }

            if state.v2RouteHandoff == nil {
                state.v2RouteHandoff = V2RouteHandoff(
                    handoffID: work.workID,
                    ownerChildDeviceID: owner,
                    fromGenerationID: oldRoute.generationID,
                    fromEpochID: oldRoute.epochID,
                    fromRouteID: oldRoute.routeID,
                    toGenerationID: newRoute.generationID,
                    toEpochID: newRoute.epochID,
                    toRouteID: newRoute.routeID,
                    phase: .dualV2,
                    priorRouteInputClosedAt: nil,
                    registrationAcknowledgedAt: nil,
                    activationAcknowledgedAt: nil,
                    priorStopAcknowledgedAt: nil,
                    createdAt: work.createdAt
                )
            }
            guard state.v2RouteHandoff?.handoffID == work.workID else { return }
            state.routes[newRoute.routeID]?.lifecycle = .active
            state.installWork[newInstallID]?.authorization = .offlinePending
            state.installWork[newInstallID]?.phase = .dualActive
            work.installAcknowledged = true
            state.rolloverEffectsWork = work
        }
    }

    private func advanceRolloverBarrier(workID: UUID, owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let work = state.rolloverEffectsWork, work.workID == workID,
                  var handoff = state.v2RouteHandoff,
                  handoff.handoffID == workID,
                  handoff.phase == .dualV2,
                  !hasNonterminalPriorRouteWork(work.oldRouteID, in: state),
                  let epoch = state.epochs[work.newEpochID]
            else { return }
            handoff.phase = .cutoverReady
            handoff.priorRouteInputClosedAt = clock.now
            state.v2RouteHandoff = handoff
            guard !state.registrationWork.values.contains(where: {
                $0.epochID == work.newEpochID && $0.routeID == work.newRouteID
                    && ($0.retry.terminal == .pending || $0.retry.terminal == .succeeded)
            }) else { return }
            let registrationID = UUID()
            state.registrationWork[registrationID] = EpochRegistrationWork(
                workID: registrationID,
                ownerChildDeviceID: owner,
                epochID: work.newEpochID,
                routeID: work.newRouteID,
                request: registrationRequest(epoch: epoch, reason: .dayRollover),
                claim: nil,
                retry: pendingRetry(),
                createdAt: clock.now
            )
        }
    }

    private func acknowledgeRolloverRegistrationAndEnqueueActivation(workID: UUID, owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var work = state.rolloverEffectsWork, work.workID == workID,
                  var handoff = state.v2RouteHandoff,
                  handoff.handoffID == workID,
                  handoff.phase == .cutoverReady,
                  let route = state.routes[work.newRouteID],
                  hasUniqueSuccessfulRegistration(route, owner: owner, in: state)
            else { return }
            work.registrationAcknowledged = true
            handoff.registrationAcknowledgedAt = clock.now
            state.rolloverEffectsWork = work
            state.v2RouteHandoff = handoff
            enqueueActivationIfNeeded(route: route, owner: owner, state: &state)
        }
    }

    private func commitRolloverActivation(workID: UUID, owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var work = state.rolloverEffectsWork, work.workID == workID,
                  var handoff = state.v2RouteHandoff,
                  handoff.handoffID == workID,
                  handoff.phase == .cutoverReady,
                  hasSuccessfulActivation(work.newRouteID, in: state),
                  var oldRoute = state.routes[work.oldRouteID],
                  var oldEpoch = state.epochs[work.oldEpochID],
                  let newInstallID = uniqueInstallKey(for: work.newRouteID, in: state),
                  state.installWork[newInstallID]?.phase == .dualActive,
                  let oldInstallID = uniqueInstallKey(for: work.oldRouteID, in: state),
                  state.installWork[oldInstallID]?.phase == .active,
                  let dayEnd = state.canonicalDayEnd(
                    usageDate: work.fromUsageDate,
                    timeZoneIdentifier: oldEpoch.canonicalTimezone
                  )
            else { return }
            state.activeGenerationID = oldRoute.generationID
            state.activeEpochID = work.newEpochID
            state.activeRouteID = work.newRouteID
            state.routes[work.newRouteID]?.lifecycle = .active
            state.installWork[newInstallID]?.phase = .active
            oldRoute.lifecycle = .tombstoned
            state.routes[oldRoute.routeID] = oldRoute
            oldEpoch.status = .retired
            oldEpoch.retiredAt = clock.now
            oldEpoch.retireReason = .dayRollover
            state.epochs[oldEpoch.epochID] = oldEpoch
            state.tombstones[oldRoute.routeID] = MeteringRouteTombstone(
                routeID: oldRoute.routeID,
                activityName: oldRoute.activityName,
                eventNames: oldRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: oldRoute.usageDate,
                epochID: oldRoute.epochID,
                generationID: oldRoute.generationID,
                canonicalDayEnd: dayEnd,
                stopAcknowledgedAt: nil,
                referencedWorkIDs: Set(state.sampleWork.values.filter { $0.routeID == oldRoute.routeID }.map(\.workID)),
                retainedUntil: nil
            )
            state.installWork[oldInstallID]?.phase = .pendingStop
            handoff.phase = .committed
            handoff.activationAcknowledgedAt = clock.now
            state.v2RouteHandoff = handoff
            work.activationAcknowledged = true
            state.rolloverEffectsWork = work
        }
    }

    private func stopRolloverPriorRoute(workID: UUID, owner: UUID) throws {
        let state = try store.read()
        guard let work = state.rolloverEffectsWork, work.workID == workID,
              !work.oldStopAcknowledged,
              let route = state.routes[work.oldRouteID],
              state.v2RouteHandoff?.phase == .committed
        else { return }
        let activity = DeviceActivityName(route.activityName)
        center.stopMonitoring([activity])
        guard !center.activities.contains(activity) else { return }
        let acknowledgedAt = clock.now
        try store.transaction(expectedOwner: owner) { state in
            guard var current = state.rolloverEffectsWork, current.workID == workID,
                  let installID = uniqueInstallKey(for: current.oldRouteID, in: state),
                  state.installWork[installID]?.phase == .pendingStop,
                  var tombstone = state.tombstones[current.oldRouteID]
            else { return }
            state.installWork[installID]?.phase = .stopped
            tombstone.stopAcknowledgedAt = acknowledgedAt
            tombstone.retainedUntil = max(
                tombstone.canonicalDayEnd.addingTimeInterval(48 * 3_600),
                acknowledgedAt.addingTimeInterval(24 * 3_600)
            )
            state.tombstones[current.oldRouteID] = tombstone
            current.oldStopAcknowledged = true
            current.retry.terminal = .succeeded
            state.rolloverEffectsWork = current
            if var handoff = state.v2RouteHandoff, handoff.handoffID == workID {
                handoff.priorStopAcknowledgedAt = acknowledgedAt
                state.v2RouteHandoff = handoff
            }
        }
    }

    /// Identity cleanup must run before the mutable-owner guard. Its exact
    /// durable work ID is the authority that lets recovery continue after the
    /// mirror has already moved to a new child or has been removed on sign-out.
    private func recoverIdentityCleanupIfPresent() throws -> Bool {
        let initial = try store.read()
        guard let cleanup = initial.identityCleanupWork else { return false }
        if cleanup.retry.terminal == .succeeded {
            _ = try store.finalizeIdentityCleanup(workID: cleanup.workID)
            return true
        }

        try store.identityCleanupTransaction(workID: cleanup.workID) { state, current in
            func terminalize(_ ids: [UUID], in work: inout [UUID: EpochRegistrationWork]) {
                for id in ids where work[id] != nil {
                    work[id]?.claim = nil
                    work[id]?.retry.terminal = .superseded
                    work[id]?.retry.lastErrorCode = "identity_cleanup"
                    current.terminalizedWorkIDs.insert(id)
                }
            }
            func terminalize(_ ids: [UUID], in work: inout [UUID: EpochActivationWork]) {
                for id in ids where work[id] != nil {
                    work[id]?.claim = nil
                    work[id]?.retry.terminal = .superseded
                    work[id]?.retry.lastErrorCode = "identity_cleanup"
                    current.terminalizedWorkIDs.insert(id)
                }
            }
            func terminalize(_ ids: [UUID], in work: inout [UUID: EpochSampleWork]) {
                for id in ids where work[id] != nil {
                    work[id]?.claim = nil
                    work[id]?.retry.terminal = .superseded
                    work[id]?.retry.lastErrorCode = "identity_cleanup"
                    current.terminalizedWorkIDs.insert(id)
                }
            }
            func terminalize(_ ids: [UUID], in work: inout [UUID: ActivityInstallWork]) {
                for id in ids where work[id] != nil {
                    work[id]?.claim = nil
                    work[id]?.retry.terminal = .superseded
                    work[id]?.retry.lastErrorCode = "identity_cleanup"
                    current.terminalizedWorkIDs.insert(id)
                }
            }
            terminalize(current.oldRegistrationWorkIDs, in: &state.registrationWork)
            terminalize(current.oldActivationWorkIDs, in: &state.activationWork)
            terminalize(current.oldSampleWorkIDs, in: &state.sampleWork)
            terminalize(current.oldInstallWorkIDs, in: &state.installWork)
        }

        var current = try requiredIdentityCleanup(workID: cleanup.workID)
        let fallbackKeys = current.oldFallbackKeys.filter {
            !current.purgedFallbackKeys.contains($0)
        }
        if !fallbackKeys.isEmpty {
            let purged = purgeIdentityRetryState(current.oldOwnerChildDeviceID, fallbackKeys)
            if !purged.isEmpty {
                try store.identityCleanupTransaction(workID: current.workID) { _, work in
                    work.purgedFallbackKeys.formUnion(purged.intersection(work.oldFallbackKeys))
                }
            }
        }

        current = try requiredIdentityCleanup(workID: cleanup.workID)
        for operationID in current.oldShieldOperationIDs
            where !current.releasedShieldOperationIDs.contains(operationID) {
            try releaseIdentityShield(operationID, current.oldOwnerChildDeviceID)
            try store.identityCleanupTransaction(workID: current.workID) { _, work in
                guard work.oldShieldOperationIDs.contains(operationID) else { return }
                work.releasedShieldOperationIDs.insert(operationID)
            }
        }

        current = try requiredIdentityCleanup(workID: cleanup.workID)
        let namesToStop = current.oldActivityNames.filter {
            !current.stopAcknowledgedActivityNames.contains($0)
        }
        if !namesToStop.isEmpty {
            let activities = namesToStop.map { DeviceActivityName($0) }
            center.stopMonitoring(activities)
            let stillActive = Set(center.activities.map(\.rawValue))
            let absent = Set(namesToStop).subtracting(stillActive)
            if !absent.isEmpty {
                try store.identityCleanupTransaction(workID: current.workID) { state, work in
                    work.stopAcknowledgedActivityNames.formUnion(absent)
                    for routeID in work.oldRouteIDs {
                        guard let route = state.routes[routeID], absent.contains(route.activityName) else { continue }
                        state.tombstones[routeID]?.stopAcknowledgedAt = clock.now
                        for (installID, install) in state.installWork where install.routeID == routeID {
                            state.installWork[installID]?.phase = .stopped
                        }
                    }
                }
            }
        }

        _ = try store.markIdentityCleanupSucceeded(workID: cleanup.workID)
        return true
    }

    private func requiredIdentityCleanup(workID: UUID) throws -> IdentityCleanupWork {
        guard let cleanup = try store.read().identityCleanupWork,
              cleanup.workID == workID
        else { throw DeviceEpochStoreError.ownerMismatch }
        return cleanup
    }

    private func prepareReplacementIfNeeded(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let ratchet = state.ratchets[owner], ratchet.localSelection == .v2,
                  state.v2RouteHandoff == nil,
                  let fromRouteID = state.activeRouteID,
                  let fromRoute = state.routes[fromRouteID],
                  let fromEpoch = state.epochs[fromRoute.epochID],
                  let fromGeneration = state.generations[fromRoute.generationID],
                  let candidate = candidateRoute(in: state, owner: owner, excluding: fromRouteID),
                  let candidateEpoch = state.epochs[candidate.epochID],
                  let candidateGeneration = state.generations[candidate.generationID],
                  let priorInstallKey = uniqueInstallKey(for: fromRouteID, in: state),
                  state.installWork[priorInstallKey]?.phase == .active,
                  let candidateInstallKey = uniqueInstallKey(for: candidate.routeID, in: state)
            else { return }
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: owner,
                fromGenerationID: fromGeneration.generationID,
                fromEpochID: fromEpoch.epochID,
                fromRouteID: fromRoute.routeID,
                toGenerationID: candidateGeneration.generationID,
                toEpochID: candidateEpoch.epochID,
                toRouteID: candidate.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: clock.now
            )
            if state.installWork[candidateInstallKey]?.phase == .pendingStart {
                state.installWork[candidateInstallKey]?.authorization = .offlinePending
            }
            for (key, var work) in state.registrationWork where
                work.routeID == candidate.routeID && work.retry.terminal == .pending {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "replacement_registration_deferred"
                state.registrationWork[key] = work
            }
        }
    }

    private func promoteVerifiedCandidate(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let ratchet = state.ratchets[owner] else { return }
            if ratchet.localSelection == .v1 {
                guard let candidate = initialCandidate(in: state, owner: owner),
                      let installKey = uniqueInstallKey(for: candidate.routeID, in: state),
                      state.installWork[installKey]?.phase == .verified,
                      hasUniqueSuccessfulRegistration(candidate, owner: owner, in: state)
                else { return }
                state.routes[candidate.routeID]?.lifecycle = .active
                state.installWork[installKey]?.phase = .dualActive
                var updated = ratchet
                updated.localSelection = .dualActive
                updated.dualActiveAt = clock.now
                state.ratchets[owner] = updated
                enqueueActivationIfNeeded(route: candidate, owner: owner, state: &state)
                return
            }

            guard ratchet.localSelection == .v2,
                  var handoff = state.v2RouteHandoff,
                  handoff.phase == .preparing,
                  let candidate = state.routes[handoff.toRouteID],
                  let installKey = uniqueInstallKey(for: candidate.routeID, in: state),
                  state.installWork[installKey]?.phase == .verified
            else { return }
            state.routes[candidate.routeID]?.lifecycle = .active
            state.installWork[installKey]?.phase = .dualActive
            handoff.phase = .dualV2
            state.v2RouteHandoff = handoff
        }
    }

    private func advanceReplacementBarrier(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff,
                  handoff.phase == .dualV2,
                  !hasNonterminalPriorRouteWork(handoff.fromRouteID, in: state),
                  let candidate = state.routes[handoff.toRouteID],
                  let epoch = state.epochs[handoff.toEpochID]
            else { return }
            handoff.phase = .cutoverReady
            handoff.priorRouteInputClosedAt = clock.now
            state.v2RouteHandoff = handoff
            // A preparing handoff terminalizes any premature candidate
            // registration. That terminal audit row must not suppress the
            // one registration which becomes legal only after this barrier.
            let hasUsableRegistration = state.registrationWork.values.contains {
                $0.ownerChildDeviceID == owner
                    && $0.epochID == epoch.epochID
                    && $0.routeID == candidate.routeID
                    && ($0.retry.terminal == .pending || $0.retry.terminal == .succeeded)
            }
            if !hasUsableRegistration {
                let workID = UUID()
                state.registrationWork[workID] = EpochRegistrationWork(
                    workID: workID,
                    ownerChildDeviceID: owner,
                    epochID: epoch.epochID,
                    routeID: candidate.routeID,
                    request: registrationRequest(epoch: epoch),
                    claim: nil,
                    retry: pendingRetry(),
                    createdAt: clock.now
                )
            }
        }

        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.phase == .cutoverReady,
                  let candidate = state.routes[handoff.toRouteID],
                  hasUniqueSuccessfulRegistration(candidate, owner: owner, in: state)
            else { return }
            enqueueActivationIfNeeded(route: candidate, owner: owner, state: &state)
        }
    }

    private func recoverTerminalInitialActivation(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var ratchet = state.ratchets[owner], ratchet.localSelection == .dualActive,
                  let candidate = initialDualActiveCandidate(in: state, owner: owner),
                  let activation = state.activationWork.values.first(where: {
                      $0.routeID == candidate.routeID && $0.epochID == candidate.epochID
                  }),
                  activation.retry.terminal != .pending,
                  activation.retry.terminal != .succeeded,
                  let installKey = uniqueInstallKey(for: candidate.routeID, in: state),
                  state.installWork[installKey]?.phase == .dualActive
            else { return }
            state.routes[candidate.routeID]?.lifecycle = .planned
            state.installWork[installKey]?.phase = .verified
            if activation.retry.lastErrorCode == "epoch_not_active" || activation.retry.lastErrorCode == "epoch_paused" {
                // The first activation never commits v2 while the gate is
                // closed. Keep v1 countable and leave this epoch durably
                // paused; Task 17 may create a distinct conservative epoch
                // only after it receives a later authoritative open state.
                state.epochs[candidate.epochID]?.status = .paused
            }
            ratchet.localSelection = .v1
            ratchet.dualActiveAt = nil
            state.ratchets[owner] = ratchet
        }
    }

    private func promoteAcknowledgedActivation(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var ratchet = state.ratchets[owner] else { return }
            if ratchet.localSelection == .dualActive {
                guard let candidate = initialDualActiveCandidate(in: state, owner: owner),
                      hasSuccessfulActivation(candidate.routeID, in: state),
                      var epoch = state.epochs[candidate.epochID],
                      let installKey = uniqueInstallKey(for: candidate.routeID, in: state),
                      state.installWork[installKey]?.phase == .dualActive
                else { return }
                epoch.registeredAt = epoch.registeredAt ?? clock.now
                state.epochs[candidate.epochID] = epoch
                state.activeGenerationID = candidate.generationID
                state.activeEpochID = candidate.epochID
                state.activeRouteID = candidate.routeID
                state.routes[candidate.routeID]?.lifecycle = .active
                state.installWork[installKey]?.phase = .active
                ratchet.localSelection = .v2
                ratchet.advertisedVersion = 2
                ratchet.activatedV2At = clock.now
                state.ratchets[owner] = ratchet
                if var legacy = state.legacy, legacy.phase != .stoppedV1 {
                    legacy.phase = .retiringV1
                    state.legacy = legacy
                }
                return
            }

            guard ratchet.localSelection == .v2,
                  var handoff = state.v2RouteHandoff,
                  handoff.phase == .cutoverReady,
                  let candidate = state.routes[handoff.toRouteID],
                  var prior = state.routes[handoff.fromRouteID],
                  var priorEpoch = state.epochs[handoff.fromEpochID],
                  hasSuccessfulActivation(candidate.routeID, in: state),
                  let candidateInstallKey = uniqueInstallKey(for: candidate.routeID, in: state),
                  state.installWork[candidateInstallKey]?.phase == .dualActive,
                  let priorInstallKey = uniqueInstallKey(for: prior.routeID, in: state),
                  state.installWork[priorInstallKey]?.phase == .active,
                  let priorCanonicalDayEnd = state.canonicalDayEnd(
                      usageDate: prior.usageDate,
                      timeZoneIdentifier: priorEpoch.canonicalTimezone
                  )
            else { return }

            state.activeGenerationID = candidate.generationID
            state.activeEpochID = candidate.epochID
            state.activeRouteID = candidate.routeID
            state.routes[candidate.routeID]?.lifecycle = .active
            state.installWork[candidateInstallKey]?.phase = .active
            prior.lifecycle = .tombstoned
            state.routes[prior.routeID] = prior
            priorEpoch.status = .retired
            priorEpoch.retiredAt = clock.now
            priorEpoch.retireReason = .policyChange
            state.epochs[priorEpoch.epochID] = priorEpoch
            state.generations[handoff.fromGenerationID]?.retiredAt = clock.now
            state.tombstones[prior.routeID] = MeteringRouteTombstone(
                routeID: prior.routeID,
                activityName: prior.activityName,
                eventNames: prior.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: prior.usageDate,
                epochID: prior.epochID,
                generationID: prior.generationID,
                canonicalDayEnd: priorCanonicalDayEnd,
                stopAcknowledgedAt: nil,
                referencedWorkIDs: Set(state.sampleWork.values.filter { $0.routeID == prior.routeID }.map(\.workID)),
                retainedUntil: nil
            )
            state.installWork[priorInstallKey]?.phase = .pendingStop
            handoff.phase = .committed
            handoff.registrationAcknowledgedAt = clock.now
            handoff.activationAcknowledgedAt = clock.now
            state.v2RouteHandoff = handoff
        }
    }

    private func stopRetiredLane(owner: UUID) throws {
        let state = try store.read()
        if let handoff = state.v2RouteHandoff,
           handoff.phase == .committed,
           handoff.priorStopAcknowledgedAt == nil,
           let route = state.routes[handoff.fromRouteID],
           let priorInstallKey = uniqueInstallKey(for: handoff.fromRouteID, in: state),
           state.installWork[priorInstallKey]?.phase == .pendingStop {
            let name = DeviceActivityName(route.activityName)
            center.stopMonitoring([name])
            guard !center.activities.contains(name) else { return }
            let acknowledgedAt = clock.now
            try store.transaction(expectedOwner: owner) { state in
                guard var current = state.v2RouteHandoff,
                      current.handoffID == handoff.handoffID,
                      current.phase == .committed,
                      state.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt == nil,
                      let currentInstallKey = uniqueInstallKey(for: handoff.fromRouteID, in: state),
                      currentInstallKey == priorInstallKey,
                      state.installWork[currentInstallKey]?.phase == .pendingStop
                else { return }
                state.installWork[currentInstallKey]?.phase = .stopped
                state.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt = acknowledgedAt
                current.priorStopAcknowledgedAt = acknowledgedAt
                state.v2RouteHandoff = current
            }
            return
        }

        guard var legacy = state.legacy,
              legacy.phase == .retiringV1,
              !legacy.isStopped
        else { return }
        let names = legacyActivityNames(legacy).map { DeviceActivityName($0) }
        center.stopMonitoring(names)
        guard names.allSatisfy({ !center.activities.contains($0) }) else { return }
        try store.transaction(expectedOwner: owner) { state in
            guard var current = state.legacy, current.phase == .retiringV1 else { return }
            current.isStopped = true
            current.phase = .stoppedV1
            current.stopAcknowledgedAt = clock.now
            state.legacy = current
        }
    }

    private func stopAuthoritativeBaseRejectedCandidates(owner: UUID) throws {
        let state = try store.read()
        let candidates = state.routes.values.compactMap { route -> (MeteringCallbackRoute, UUID)? in
            guard route.ownerChildDeviceID == owner,
                  route.lifecycle == .tombstoned,
                  state.epochs[route.epochID]?.retireReason == .authoritativeBaseMismatch,
                  state.tombstones[route.routeID]?.stopAcknowledgedAt == nil,
                  let installKey = uniqueInstallKey(for: route.routeID, in: state),
                  state.installWork[installKey]?.phase == .pendingStop
            else { return nil }
            return (route, installKey)
        }

        for (route, installKey) in candidates {
            let activity = DeviceActivityName(route.activityName)
            center.stopMonitoring([activity])
            guard !center.activities.contains(activity) else { continue }
            let acknowledgedAt = clock.now
            try store.transaction(expectedOwner: owner) { state in
                guard state.routes[route.routeID]?.lifecycle == .tombstoned,
                      state.epochs[route.epochID]?.retireReason == .authoritativeBaseMismatch,
                      state.tombstones[route.routeID]?.stopAcknowledgedAt == nil,
                      uniqueInstallKey(for: route.routeID, in: state) == installKey,
                      state.installWork[installKey]?.phase == .pendingStop
                else { return }
                state.installWork[installKey]?.phase = .stopped
                state.tombstones[route.routeID]?.stopAcknowledgedAt = acknowledgedAt
            }
        }
    }

    private func initialCandidate(in state: DeviceEpochStoreState, owner: UUID) -> MeteringCallbackRoute? {
        guard state.activeRouteID == nil,
              let generationID = state.activeGenerationID,
              let epochID = state.activeEpochID
        else { return nil }
        let matches = state.routes.values.filter {
            $0.ownerChildDeviceID == owner
                && $0.generationID == generationID
                && $0.epochID == epochID
                && $0.lifecycle == .planned
                && state.epochs[$0.epochID]?.status == .active
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func initialDualActiveCandidate(in state: DeviceEpochStoreState, owner: UUID) -> MeteringCallbackRoute? {
        guard state.activeRouteID == nil,
              let generationID = state.activeGenerationID,
              let epochID = state.activeEpochID
        else { return nil }
        let matches = state.routes.values.filter {
            $0.ownerChildDeviceID == owner
                && $0.generationID == generationID
                && $0.epochID == epochID
                && $0.lifecycle == .active
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func candidateRoute(in state: DeviceEpochStoreState, owner: UUID, excluding routeID: UUID) -> MeteringCallbackRoute? {
        guard let activeRoute = state.routes[routeID] else { return nil }
        return candidateRoutes(in: state, owner: owner).first {
            $0.routeID != routeID
                && $0.generationID != state.activeGenerationID
                && $0.usageDate == activeRoute.usageDate
        }
    }

    private func candidateRoutes(in state: DeviceEpochStoreState, owner: UUID) -> [MeteringCallbackRoute] {
        state.routes.values.filter {
            $0.ownerChildDeviceID == owner && $0.lifecycle == .planned && state.epochs[$0.epochID]?.status == .active
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.routeID.uuidString.lowercased() < $1.routeID.uuidString.lowercased()
        }
    }

    private func hasUniqueSuccessfulRegistration(
        _ route: MeteringCallbackRoute,
        owner: UUID,
        in state: DeviceEpochStoreState
    ) -> Bool {
        let usable = state.registrationWork.values.filter {
            $0.ownerChildDeviceID == owner
                && $0.epochID == route.epochID
                && $0.routeID == route.routeID
                && ($0.retry.terminal == .pending || $0.retry.terminal == .succeeded)
        }
        return usable.count == 1 && usable[0].retry.terminal == .succeeded
    }

    private func hasSuccessfulActivation(_ routeID: UUID, in state: DeviceEpochStoreState) -> Bool {
        state.activationWork.values.contains { $0.routeID == routeID && $0.retry.terminal == .succeeded }
    }

    private func hasNonterminalPriorRouteWork(_ routeID: UUID, in state: DeviceEpochStoreState) -> Bool {
        state.sampleWork.values.contains { $0.routeID == routeID && $0.retry.terminal == .pending }
    }

    private func uniqueInstallKey(for routeID: UUID, in state: DeviceEpochStoreState) -> UUID? {
        let matches = state.installWork.filter { $0.value.routeID == routeID }
        guard matches.count == 1 else { return nil }
        return matches.first?.key
    }

    private func enqueueActivationIfNeeded(route: MeteringCallbackRoute, owner: UUID, state: inout DeviceEpochStoreState) {
        guard !state.activationWork.values.contains(where: { $0.ownerChildDeviceID == owner && $0.epochID == route.epochID && $0.routeID == route.routeID }) else { return }
        let workID = UUID()
        state.activationWork[workID] = EpochActivationWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: route.epochID,
            routeID: route.routeID,
            request: EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: route.routeID, verifiedAt: clock.now),
            claim: nil,
            retry: pendingRetry(),
            createdAt: clock.now
        )
    }

    private func registrationRequest(
        epoch: DeviceDailyEpoch,
        reason: EpochRegistrationReasonDTO = .initial
    ) -> EpochRegistrationRequestDTO {
        EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: epoch.epochID,
            deviceID: epoch.childDeviceID,
            usageDate: epoch.usageDate,
            timezone: epoch.canonicalTimezone,
            policyRevision: epoch.policyRevision,
            measurementSelectionDigest: epoch.measurementSelectionDigest,
            enforcementSetID: epoch.enforcementSetID,
            startedAt: epoch.startedAt,
            baseAcceptedMinutes: epoch.baseAcceptedMinutes,
            reason: reason
        )
    }

    private func pendingRetry() -> MeteringRetryState {
        MeteringRetryState(attemptCount: 0, nextAttemptAt: clock.now, lastErrorCode: nil, terminal: .pending)
    }

    private func legacyActivityNames(_ legacy: LegacyCompatibilityMonitorState) -> [String] {
        Array(Set(
            [legacy.active?.activityName, legacy.pending?.activityName, legacy.scalarActiveActivityName]
                .compactMap { $0 }
                + legacy.retiringActivityNames
                + legacy.breadcrumbActivityNames
        )).sorted()
    }
}
