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

// nonisolated (NOT @MainActor): recovery reconciles the DeviceActivity daemon
// through the installer/center, each call a synchronous XPC round trip. Run on
// the main thread it blocked long enough to trip the scene-update watchdog
// (0x8badf00d). All dependencies are Sendable and DeviceEpochStore is
// internally locked, so the whole driver is safe off the main actor; recover()
// forces the work onto a detached background task.
nonisolated final class EarnedMeteringRecoveryDriver: @unchecked Sendable {
    private static let maxIdentityCleanupPasses = 4

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
        if let releaseIdentityShield {
            self.releaseIdentityShield = releaseIdentityShield
        } else {
            let effectStore = EarnedShieldEffectStore(epochStore: store)
            self.releaseIdentityShield = { operationID, owner in
                try effectStore.retireForIdentityCleanup(
                    operationID: operationID,
                    expectedOwner: owner
                )
            }
        }
        self.resetRolloverEffect = resetRolloverEffect ?? { _, _ in
            throw EarnedMeteringRecoveryError.invalidRollover("reset adapter unavailable")
        }
    }

    func recover(ownerChildDeviceID owner: UUID) async throws {
        // Force the reconciliation off the main thread. Under
        // SWIFT_APPROACHABLE_CONCURRENCY a plain `nonisolated async` inherits
        // the caller's executor (main), so `Task.detached` is required to
        // guarantee the synchronous DeviceActivity XPC never blocks the main
        // thread's scene-update watchdog. The store is internally locked, so
        // concurrent main-thread reads stay safe.
        do {
            try await Task.detached(priority: .utility) { [self] in
                try await performRecovery(ownerChildDeviceID: owner)
            }.value
        } catch {
            // Top of the recovery pipeline. Callers historically only
            // `print`ed this, so a pass that aborted halfway — leaving the
            // route un-armed for the rest of the day — left no durable trace.
            MeteringFlightRecorder.emitError(
                site: "recovery.pass",
                error: error,
                detail: MeteringFlightRecorder.detail([
                    ("role", processIdentity.role.rawValue),
                ])
            )
            throw error
        }
    }

    private func performRecovery(ownerChildDeviceID owner: UUID) async throws {
        // Identity cleanup replaces the persisted root with an empty root for
        // the new owner. Continue the same pass after that handoff instead of
        // returning and waiting for an unrelated future wake-up to arm the
        // first route. The cleanup method can require two passes itself:
        // one to mark the envelope terminal and one to finalize the root.
        var effectiveOwner = owner
        var cleanupPasses = 0
        while cleanupPasses < Self.maxIdentityCleanupPasses {
            guard try recoverIdentityCleanupIfPresent() else { break }
            cleanupPasses += 1
            guard let currentOwner = try store.read().ownerChildDeviceID else { return }
            effectiveOwner = currentOwner
        }
        if cleanupPasses == Self.maxIdentityCleanupPasses,
           (try store.read().identityCleanupWork) != nil {
            MeteringFlightRecorder.emit(
                kind: .meteringDay,
                site: "recovery.identity_cleanup",
                verdict: "pass_limit",
                detail: MeteringFlightRecorder.detail([
                    ("passes", String(Self.maxIdentityCleanupPasses)),
                ])
            )
            return
        }
        // A pending cleanup owns the old persisted root until every external
        // effect is acknowledged. Do not compare that root with the already
        // switched mirror or turn a retryable daemon delay into ownerMismatch.
        if (try store.read().identityCleanupWork) != nil {
            return
        }
        // After cleanup, the persisted owner is authoritative by design; the
        // caller's owner may be the stale identity that triggered recovery.
        guard store.isCurrentOwner(effectiveOwner) else { return }
        _ = try store.reconcileEpochStartsFromSuccessfulRegistrations(owner: effectiveOwner)
        try settlePausedRouteSamples(owner: effectiveOwner)
        try abandonElapsedCandidateHandoffIfNeeded(owner: effectiveOwner)
        try cancelBackwardPreparingHandoffIfNeeded(owner: effectiveOwner)
        try yieldSupersededCanonicalRolloverIfNeeded(owner: effectiveOwner)
        try markElapsedActivePriorAbsentIfNeeded(owner: effectiveOwner)
        try adoptCurrentDayAfterElapsedInitialRouteIfNeeded(owner: effectiveOwner)
        try prepareCanonicalRolloverIfNeeded(owner: effectiveOwner)
        // A same-key correction rejected only for carrying the wrong
        // registration reason is REPAIRABLE, and its rejected registration
        // reads as "proven dead" to the sweep below. Give the specific repair
        // its chance first, or the generic reclaim retires a candidate that
        // would have committed on the next attempt. The predicate is narrow
        // (cutoverReady, no explicit recovery, live prior, 409-sourced
        // corrected epoch, same usage date and generation key), so running it
        // this early is a no-op in every other flow.
        _ = try store.recoverLegacySameKeyCorrectionReasonMismatch(
            owner: effectiveOwner,
            now: clock.now
        )
        // A terminal same-day candidate may still own the handoff slot when
        // midnight prepares the next dated route. Clear only a proven-dead
        // candidate before the rollover tries to claim that single slot.
        try abandonTerminalSupersededCandidate(owner: effectiveOwner)
        try detachCommittedHandoffForPreparedRolloverIfNeeded(owner: effectiveOwner)
        // Detached committed predecessors are cleanup debt, not rollover
        // authority. Retry their named stops even when the rollover network
        // leg below remains pending or fails and returns early.
        try stopAbandonedCandidates(owner: effectiveOwner)
        do {
            if try await recoverCanonicalRolloverIfPresent(owner: effectiveOwner) {
                if try store.read().rolloverEffectsWork?.activationAcknowledged == true {
                    try reconcileCoverage(owner: effectiveOwner)
                }
                return
            }
        } catch {
            // The midnight leg. `prepareCanonicalRollover` already records its
            // own throw; this covers the effect/handoff/activation legs that
            // run afterwards and can strand the device on yesterday.
            MeteringFlightRecorder.emit(
                kind: .meteringDay,
                site: "recovery.rollover",
                verdict: "recover_failed",
                detail: MeteringFlightRecorder.detail([
                    ("err", MeteringFlightRecorder.describe(error)),
                ])
            )
            throw error
        }

        try collectCompletedHandoff(owner: effectiveOwner)
        try recoverPersistedInitialAuthoritativeBaseConflict(owner: effectiveOwner)
        try recoverLegacyInitialCorrectionReason(owner: effectiveOwner)
        _ = try store.recoverLegacyRetiredPriorAuthoritativeCorrection(
            owner: effectiveOwner,
            now: clock.now
        )
        _ = try store.recoverLegacySameKeyCorrectionReasonMismatch(
            owner: effectiveOwner,
            now: clock.now
        )
        _ = try store.prepareCurrentDayInstallStartMigrationIfNeeded(
            owner: effectiveOwner,
            now: clock.now
        )
        // BUG 1 self-heal, before anything arms: a device already carrying a
        // base that outgrew its ladder must be re-cut here, otherwise the
        // installer below faithfully re-arms the over-running rungs.
        //
        // #85 (P1-3): bounded. The repair can prescribe a candidate the
        // backend keeps superseding (iPhone 2026-08-05 03:12–03:22: 30 fresh
        // epochs across 18 routes in ten minutes, one every drain). Until the
        // rung-placement root cause lands, a burst of recent repair corpses
        // parks the repair with a durable red verdict instead of minting the
        // next corpse.
        if Self.isLadderRepairStorming(state: try store.read(), now: clock.now) {
            MeteringFlightRecorder.emitFailure(
                site: "recovery.ladderRepair",
                verdict: "repair_storm_parked"
            )
        } else {
            _ = try store.repairLadderBaseInvariantIfNeeded(owner: effectiveOwner, now: clock.now)
        }
        try prepareReplacementIfNeeded(owner: effectiveOwner)
        await delivery.drain(owner: effectiveOwner)
        _ = try installer.reconcile(ownerChildDeviceID: effectiveOwner)
        _ = try store.finalizeCurrentDayInstallStartMigrationIfNeeded(owner: effectiveOwner)
        try promoteVerifiedCandidate(owner: effectiveOwner)
        await delivery.drain(owner: effectiveOwner)
        try recoverTerminalInitialActivation(owner: effectiveOwner)
        try advanceReplacementBarrier(owner: effectiveOwner)
        await delivery.drain(owner: effectiveOwner)
        try recoverPhysicalIdentityRequired(owner: effectiveOwner)
        await delivery.drain(owner: effectiveOwner)
        try advanceReplacementBarrier(owner: effectiveOwner)
        await delivery.drain(owner: effectiveOwner)
        try promoteAcknowledgedActivation(owner: effectiveOwner)
        // Routes that just reached .active may hold callbacks Apple delivered
        // within a second of arming, before activation could finish. Credit them
        // now and flush the resulting samples (FIX-A birth race).
        if !(try store.replayDeferredCallbacks(owner: effectiveOwner, now: clock.now)).isEmpty {
            await delivery.drain(owner: effectiveOwner)
        }
        try abandonTerminalConservativeCandidate(owner: effectiveOwner)
        try abandonTerminalSupersededCandidate(owner: effectiveOwner)
        try prepareReplacementIfNeeded(owner: effectiveOwner)
        try stopRetiredLane(owner: effectiveOwner)
        // A candidate may have been tombstoned by the recovery steps above.
        // Keep this end-of-pass sweep in addition to the pre-rollover sweep:
        // the former handles newly-created debt, the latter prevents existing
        // cleanup debt from being starved by a failing rollover network leg.
        try stopAbandonedCandidates(owner: effectiveOwner)
        try stopAuthoritativeBaseRejectedCandidates(owner: effectiveOwner)
        try reconcileCoverage(owner: effectiveOwner)
    }

    private func cancelBackwardPreparingHandoffIfNeeded(owner: UUID) throws {
        let activeActivityNames = Set(center.activities.map(\.rawValue))
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.phase == .preparing,
                  state.activeRouteID == handoff.fromRouteID,
                  let prior = state.routes[handoff.fromRouteID],
                  let candidate = state.routes[handoff.toRouteID],
                  let candidateGeneration = state.generations[handoff.toGenerationID],
                  !activeActivityNames.contains(candidate.activityName),
                  candidate.createdAt < prior.createdAt || candidateGeneration.retiredAt != nil
            else { return }

            for (workID, var install) in state.installWork where install.routeID == candidate.routeID {
                install.claim = nil
                install.phase = .pendingStart
                install.retry.terminal = .superseded
                install.retry.lastErrorCode = "backward_handoff_cancelled"
                state.installWork[workID] = install
            }
            state.v2RouteHandoff = nil
        }
    }

    /// Lets a canonical rollover that can never finish step aside so the
    /// replacement path can carry the device into today.
    ///
    /// ## The deadlock this exists for (iPhone, 2026-07-25, 16 h unmetered)
    /// Canonical rollover deliberately stays INSIDE one generation: it adopts
    /// the next planned route of the generation that owns the active route. If
    /// the backend has meanwhile moved to a new `policyRevision`, that route's
    /// epoch still carries the OLD revision, so its registration is answered
    /// with `409 policy_revision_mismatch` forever
    /// (`Evlin-Backend/app/services/metering_epoch_registry.py` — the backend is
    /// right; the device is asking with a dead revision). The rollover parks on
    /// `cutoverReady`, `enqueueRolloverRegistrationIfNeeded` mints a fresh
    /// registration every pass (a hot loop that also drains battery and hammers
    /// the backend), and because `performRecovery` returns as soon as
    /// `recoverCanonicalRolloverIfPresent` reports an unfinished rollover, the
    /// replacement path — which COULD reach the new generation — is never
    /// reached at all. The device is stuck on yesterday until reinstall.
    ///
    /// ## Why yielding is safe
    /// The day has ALREADY turned over locally: this only fires once all four
    /// local effects (earned source, per-app, task state, bypass expiry) are
    /// acknowledged, so nothing is replayed and nothing is undone. It also only
    /// fires while the rollover has not yet registered — a rollover the backend
    /// already accepted is completable and must be left alone. Finally it
    /// refuses to yield into a void: a live generation carrying the desired
    /// revision must already hold a planned route for canonical today.
    ///
    /// Structurally this mirrors `cancelBackwardPreparingHandoffIfNeeded`: one
    /// idempotent guard that terminalizes a doomed leg so the ordinary machinery
    /// takes over. It is one-shot — the work it retires is no longer `.pending`,
    /// which is this method's own entry condition.
    private func yieldSupersededCanonicalRolloverIfNeeded(owner: UUID) throws {
        let state = try store.read()
        guard state.ownerChildDeviceID == owner,
              let desired = state.desiredPolicy,
              desired.ownerChildDeviceID == owner,
              !desired.policyRevision.isEmpty,
              let work = state.rolloverEffectsWork,
              work.ownerChildDeviceID == owner,
              work.retry.terminal == .pending,
              // A rollover the backend already registered can still finish.
              !work.registrationAcknowledged,
              !work.activationAcknowledged,
              // The local day change is done exactly once. Never yield before
              // it — the replacement path does not perform these effects.
              work.earnedSourceResetAcknowledged,
              work.perAppResetAcknowledged,
              work.taskStateResetAcknowledged,
              work.bypassExpiryAcknowledged,
              state.activeRouteID == work.oldRouteID,
              let staleRoute = state.routes[work.newRouteID],
              let staleGeneration = state.generations[staleRoute.generationID],
              staleGeneration.policyRevision != desired.policyRevision,
              let successor = supersedingTodayRoute(in: state, owner: owner, desired: desired),
              successor.generationID != staleRoute.generationID
        else { return }

        let dayEnd = state.canonicalDayEnd(
            usageDate: staleRoute.usageDate,
            timeZoneIdentifier: staleGeneration.canonicalTimezone
        )
        try store.transaction(expectedOwner: owner) { state in
            guard var current = state.rolloverEffectsWork,
                  current.workID == work.workID,
                  current.retry.terminal == .pending
            else { return }
            current.retry.terminal = .superseded
            current.retry.lastErrorCode = "policy_revision_superseded"
            current.retry.nextAttemptAt = clock.now
            state.rolloverEffectsWork = current

            if state.v2RouteHandoff?.handoffID == current.workID {
                state.v2RouteHandoff = nil
            }

            for (key, var registration) in state.registrationWork
            where registration.routeID == current.newRouteID && registration.retry.terminal == .pending {
                registration.claim = nil
                registration.retry.terminal = .superseded
                registration.retry.lastErrorCode = "rollover_registration_superseded"
                state.registrationWork[key] = registration
            }
            for (key, var activation) in state.activationWork
            where activation.routeID == current.newRouteID && activation.retry.terminal == .pending {
                activation.claim = nil
                activation.retry.terminal = .superseded
                activation.retry.lastErrorCode = "rollover_activation_superseded"
                state.activationWork[key] = activation
            }

            // Retire the dead generation's day rather than returning it to
            // `.planned`: a planned route for today is exactly what
            // `prepareCanonicalRolloverIfNeeded` picks up, so leaving it there
            // rebuilds the same doomed rollover on the very next pass.
            guard var staleEpoch = state.epochs[staleRoute.epochID],
                  var route = state.routes[current.newRouteID],
                  route.lifecycle == .planned || route.lifecycle == .active,
                  let dayEnd
            else { return }
            staleEpoch.status = .retired
            staleEpoch.retiredAt = clock.now
            staleEpoch.retireReason = .activationSuperseded
            state.epochs[staleEpoch.epochID] = staleEpoch
            route.lifecycle = .tombstoned
            state.routes[route.routeID] = route
            state.tombstones[route.routeID] = MeteringRouteTombstone(
                routeID: route.routeID,
                activityName: route.activityName,
                eventNames: route.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: route.usageDate,
                epochID: staleEpoch.epochID,
                generationID: route.generationID,
                canonicalDayEnd: dayEnd,
                stopAcknowledgedAt: nil,
                referencedWorkIDs: Set(
                    state.sampleWork.values
                        .filter { $0.routeID == route.routeID }
                        .map(\.workID)
                ),
                retainedUntil: nil
            )
            if let installKey = uniqueInstallKey(for: route.routeID, in: state) {
                state.installWork[installKey]?.claim = nil
                state.installWork[installKey]?.phase = .pendingStop
            }
        }

        MeteringFlightRecorder.emit(
            kind: .meteringDay,
            site: "recovery.rolloverYield",
            verdict: "policy_revision_superseded",
            detail: MeteringFlightRecorder.detail([
                ("from", work.fromUsageDate),
                ("to", work.toUsageDate),
                ("deadGen", MeteringFlightRecorder.shortID(staleRoute.generationID)),
                ("liveGen", MeteringFlightRecorder.shortID(successor.generationID)),
                ("rev", MeteringFlightRecorder.clamp(desired.policyRevision, to: 40)),
            ]),
            corrID: work.workID,
            transition: ScreenTimeEvent.Transition(
                before: staleGeneration.policyRevision,
                after: desired.policyRevision
            )
        )
    }

    /// The planned route for canonical today owned by a live generation that
    /// carries the revision the backend is currently on. This is the only route
    /// a superseded rollover is allowed to yield to, and the only one the
    /// stale-day replacement branch will adopt.
    private func supersedingTodayRoute(
        in state: DeviceEpochStoreState,
        owner: UUID,
        desired: MeteringDesiredPolicy
    ) -> MeteringCallbackRoute? {
        candidateRoutes(in: state, owner: owner).first { route in
            guard let generation = state.generations[route.generationID],
                  generation.policyRevision == desired.policyRevision,
                  let today = MeteringEpochContract.canonicalUsageDate(
                      at: clock.now,
                      timezoneIdentifier: generation.canonicalTimezone
                  )
            else { return false }
            return route.usageDate == today
        }
    }

    private func prepareCanonicalRolloverIfNeeded(owner: UUID) throws {
        let state = try store.read()
        guard state.ownerChildDeviceID == owner,
              state.ratchets[owner]?.localSelection == .v2,
              state.rolloverEffectsWork?.retry.terminal != .pending,
              let activeRouteID = state.activeRouteID,
              let activeRoute = state.routes[activeRouteID],
              let activeEpoch = state.epochs[activeRoute.epochID],
              activeEpoch.status == .active,
              activeEpoch.retiredAt == nil,
              let generation = state.generations[activeRoute.generationID],
              generation.childDeviceID == owner,
              generation.retiredAt == nil,
              state.installWork.values.filter({
                  $0.ownerChildDeviceID == owner && $0.routeID == activeRouteID
              }).count == 1,
              let activeInstall = state.installWork.values.first(where: {
                  $0.ownerChildDeviceID == owner && $0.routeID == activeRouteID
              }),
              activeInstall.phase == .active
                  || state.isStaleActiveRouteConfirmedAbsent(
                      owner: owner,
                      routeID: activeRouteID
                  ),
              let canonicalToday = MeteringEpochContract.canonicalUsageDate(
                  at: clock.now,
                  timezoneIdentifier: generation.canonicalTimezone
              ),
              activeRoute.usageDate < canonicalToday,
              let nextUsageDate = state.routes.values
                .filter({
                    $0.ownerChildDeviceID == owner
                        && $0.generationID == activeRoute.generationID
                        && $0.lifecycle == .planned
                        && $0.usageDate > activeRoute.usageDate
                        && $0.usageDate <= canonicalToday
                })
                .map(\.usageDate)
                .min()
        else { return }

        _ = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: nextUsageDate,
            now: clock.now
        )
    }

    /// A committed candidate is already the accounting authority. Failure to
    /// read back the retired predecessor's stop must remain cleanup debt, not a
    /// barrier that prevents that authority from rolling into a new day.
    private func detachCommittedHandoffForPreparedRolloverIfNeeded(
        owner: UUID
    ) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.ownerChildDeviceID == owner,
                  handoff.phase == .committed,
                  handoff.priorStopAcknowledgedAt == nil,
                  let rollover = state.rolloverEffectsWork,
                  rollover.ownerChildDeviceID == owner,
                  rollover.retry.terminal == .pending,
                  rollover.oldEpochID == handoff.toEpochID,
                  rollover.oldRouteID == handoff.toRouteID,
                  state.activeGenerationID == handoff.toGenerationID,
                  state.activeEpochID == handoff.toEpochID,
                  state.activeRouteID == handoff.toRouteID,
                  let priorInstallKey = uniqueInstallKey(
                      for: handoff.fromRouteID,
                      in: state
                  ),
                  state.installWork[priorInstallKey]?.phase == .pendingStop,
                  state.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt == nil
            else { return }
            state.v2RouteHandoff = nil
        }
    }

    private func markElapsedActivePriorAbsentIfNeeded(owner: UUID) throws {
        let activeActivityNames = Set(center.activities.map(\.rawValue))
        try store.transaction(expectedOwner: owner) { state in
            guard let routeID = state.activeRouteID,
                  let route = state.routes[routeID],
                  route.ownerChildDeviceID == owner,
                  route.lifecycle == .active,
                  let epoch = state.epochs[route.epochID],
                  epoch.childDeviceID == owner,
                  epoch.status == .active,
                  epoch.retiredAt == nil,
                  let generation = state.generations[route.generationID],
                  generation.childDeviceID == owner,
                  generation.retiredAt == nil,
                  route.installedSchedule != nil,
                  !(route.installedEvents?.isEmpty ?? true),
                  !activeActivityNames.contains(route.activityName),
                  let installKey = uniqueInstallKey(for: routeID, in: state),
                  var install = state.installWork[installKey],
                  install.phase == .pendingStart,
                  install.retry.terminal == .pending,
                  (
                      install.retry.lastErrorCode == "startFailed"
                          || install.retry.lastErrorCode == "usageDateElapsed"
                  ),
                  let timeZone = TimeZone(identifier: epoch.canonicalTimezone),
                  MeteringDatedSchedule.hasElapsed(
                      usageDate: route.usageDate,
                      timeZone: timeZone,
                      now: clock.now
                  )
            else { return }

            install.phase = .stopped
            install.claim = nil
            install.retry = MeteringRetryState(
                attemptCount: install.retry.attemptCount,
                nextAttemptAt: install.retry.nextAttemptAt,
                lastErrorCode: "stale_day_prior_absent",
                terminal: .succeeded
            )
            state.installWork[installKey] = install
        }
    }

    /// Recovers the one midnight shape ordinary rollover cannot represent: the
    /// initial v2 epoch registered just before midnight, but its physical route
    /// never became active because the remaining interval was too short.
    ///
    /// There is no active predecessor to roll over from, so the normal rollover
    /// machine cannot start. Adopt only the already-verified route reserved for
    /// the current canonical day, then let the unchanged registration and
    /// activation pipeline establish authority. Every guard below is part of
    /// the transition proof; this is not a general stale-day fallback.
    private func adoptCurrentDayAfterElapsedInitialRouteIfNeeded(owner: UUID) throws {
        let activeActivities = Set(center.activities.map(\.rawValue))
        let adopted: (from: String, to: String, routeID: UUID)? = try store.transaction(
            expectedOwner: owner
        ) { state in
            guard state.activeRouteID == nil,
                  state.v2RouteHandoff == nil,
                  state.rolloverEffectsWork?.retry.terminal != .pending,
                  state.ratchets[owner]?.localSelection == .v2Pending,
                  let generationID = state.activeGenerationID,
                  let generation = state.generations[generationID],
                  generation.childDeviceID == owner,
                  generation.retiredAt == nil,
                  let priorEpochID = state.activeEpochID,
                  var priorEpoch = state.epochs[priorEpochID],
                  priorEpoch.childDeviceID == owner,
                  priorEpoch.status == .active,
                  priorEpoch.retiredAt == nil,
                  priorEpoch.registeredAt != nil,
                  let canonicalToday = MeteringEpochContract.canonicalUsageDate(
                      at: clock.now,
                      timezoneIdentifier: generation.canonicalTimezone
                  ),
                  priorEpoch.usageDate < canonicalToday
            else { return nil }

            let priorRoutes = state.routes.values.filter {
                $0.ownerChildDeviceID == owner
                    && $0.generationID == generationID
                    && $0.epochID == priorEpochID
                    && $0.lifecycle == .planned
            }
            guard priorRoutes.count == 1,
                  var priorRoute = priorRoutes.first,
                  !activeActivities.contains(priorRoute.activityName),
                  priorRoute.installedSchedule == nil,
                  priorRoute.installedEvents == nil
            else { return nil }
            let priorInstalls = state.installWork.filter {
                $0.value.ownerChildDeviceID == owner
                    && $0.value.routeID == priorRoute.routeID
            }
            guard priorInstalls.count == 1,
                  let priorInstall = priorInstalls.first?.value,
                  priorInstall.authorization == .registered,
                  priorInstall.phase == .pendingStart,
                  priorInstall.claim == nil,
                  priorInstall.retry.terminal == .superseded,
                  priorInstall.retry.lastErrorCode == "route_superseded"
            else { return nil }
            let priorRegistrations = state.registrationWork.values.filter {
                $0.ownerChildDeviceID == owner
                    && $0.epochID == priorEpochID
                    && $0.routeID == priorRoute.routeID
                    && $0.request.reason == .initial
                    && $0.retry.terminal == .succeeded
            }
            guard priorRegistrations.count == 1,
                  !state.activationWork.values.contains(where: {
                      $0.routeID == priorRoute.routeID
                          && $0.retry.terminal == .succeeded
                  })
            else { return nil }

            let currentRoutes = state.routes.values.filter {
                $0.ownerChildDeviceID == owner
                    && $0.generationID == generationID
                    && $0.usageDate == canonicalToday
                    && $0.lifecycle == .planned
            }
            guard currentRoutes.count == 1,
                  let currentRoute = currentRoutes.first,
                  activeActivities.contains(currentRoute.activityName),
                  currentRoute.installedSchedule == currentRoute.plannedSchedule,
                  currentRoute.installedEvents == currentRoute.plannedEvents,
                  let currentEpoch = state.epochs[currentRoute.epochID],
                  currentEpoch.childDeviceID == owner,
                  currentEpoch.status == .active,
                  currentEpoch.retiredAt == nil,
                  currentEpoch.usageDate == canonicalToday
            else { return nil }
            let currentInstalls = state.installWork.filter {
                $0.value.ownerChildDeviceID == owner
                    && $0.value.routeID == currentRoute.routeID
            }
            guard currentInstalls.count == 1,
                  let currentInstallID = currentInstalls.first?.key,
                  var currentInstall = state.installWork[currentInstallID],
                  currentInstall.authorization == .futurePlanned,
                  currentInstall.phase == .verified,
                  currentInstall.claim == nil,
                  currentInstall.retry.terminal == .pending,
                  !state.registrationWork.values.contains(where: {
                      $0.epochID == currentEpoch.epochID
                          || $0.routeID == currentRoute.routeID
                  }),
                  !state.activationWork.values.contains(where: {
                      $0.epochID == currentEpoch.epochID
                          || $0.routeID == currentRoute.routeID
                  }),
                  let timeZone = TimeZone(identifier: currentEpoch.canonicalTimezone),
                  currentEpoch.startedAt == (try MeteringDatedSchedule.canonicalStart(
                      usageDate: canonicalToday,
                      timeZone: timeZone
                  ))
            else { return nil }

            priorRoute.lifecycle = .retired
            state.routes[priorRoute.routeID] = priorRoute
            priorEpoch.status = .retired
            priorEpoch.retiredAt = clock.now
            priorEpoch.retireReason = .dayRollover
            state.epochs[priorEpochID] = priorEpoch

            currentInstall.authorization = .registrationRequired
            state.installWork[currentInstallID] = currentInstall
            let registrationID = UUID()
            state.registrationWork[registrationID] = EpochRegistrationWork(
                workID: registrationID,
                ownerChildDeviceID: owner,
                epochID: currentEpoch.epochID,
                routeID: currentRoute.routeID,
                request: registrationRequest(
                    epoch: currentEpoch,
                    reason: .dayRollover,
                    startedAt: currentEpoch.startedAt
                ),
                claim: nil,
                retry: pendingRetry(),
                createdAt: clock.now
            )
            state.activeEpochID = currentEpoch.epochID
            return (priorEpoch.usageDate, canonicalToday, currentRoute.routeID)
        }
        guard let adopted else { return }
        MeteringFlightRecorder.emit(
            kind: .meteringDay,
            site: "recovery.initialMidnight",
            verdict: "adopted_verified_current_day",
            detail: MeteringFlightRecorder.detail([
                ("route", MeteringFlightRecorder.shortID(adopted.routeID)),
            ]),
            corrID: adopted.routeID,
            transition: ScreenTimeEvent.Transition(
                before: adopted.from,
                after: adopted.to
            )
        )
    }

    private func collectCompletedHandoff(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard state.v2RouteHandoff?.phase == .committed,
                  state.v2RouteHandoff?.priorStopAcknowledgedAt != nil
            else { return }
            state.v2RouteHandoff = nil
        }
    }

    private func recoverPersistedInitialAuthoritativeBaseConflict(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let epochID = state.activeEpochID,
                  let epoch = state.epochs[epochID],
                  let conflict = epoch.authoritativeBaseConflict,
                  let route = state.routes.values.first(where: { $0.epochID == epochID })
            else { return }
            _ = state.replaceAuthoritativeBaseMismatchCandidate(
                owner: owner,
                rejectedEpochID: epochID,
                rejectedRouteID: route.routeID,
                conflict: conflict,
                now: clock.now
            )
        }
    }

    private func recoverLegacyInitialCorrectionReason(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard state.v2RouteHandoff == nil,
                  state.ratchets[owner] == nil || state.ratchets[owner]?.localSelection == .v1,
                  state.activeRouteID == nil,
                  let epochID = state.activeEpochID,
                  let epoch = state.epochs[epochID],
                  epoch.childDeviceID == owner,
                  epoch.registeredAt == nil,
                  epoch.baseSource == .registrationConflict409,
                  epoch.status == .active,
                  let route = state.routes.values.first(where: {
                      $0.epochID == epochID
                          && $0.ownerChildDeviceID == owner
                          && $0.lifecycle == .planned
                  }),
                  let install = state.installWork.values.first(where: {
                      $0.routeID == route.routeID
                  }),
                  install.authorization == .registrationRequired,
                  install.phase == .pendingStart,
                  let registrationKey = state.registrationWork.first(where: {
                      $0.value.epochID == epochID && $0.value.routeID == route.routeID
                  })?.key,
                  let registration = state.registrationWork[registrationKey],
                  registration.request.reason == .policyChange,
                  registration.retry.terminal == .rejected,
                  registration.retry.lastErrorCode == "replacement_reason_mismatch"
            else { return }

            let request = registration.request
            let correctedRequest = EpochRegistrationRequestDTO(
                protocolVersion: request.protocolVersion,
                epochID: request.epochID,
                deviceID: request.deviceID,
                usageDate: request.usageDate,
                timezone: request.timezone,
                policyRevision: request.policyRevision,
                measurementSelectionDigest: request.measurementSelectionDigest,
                enforcementSetID: request.enforcementSetID,
                startedAt: request.startedAt,
                baseAcceptedMinutes: request.baseAcceptedMinutes,
                reason: .initial
            )
            state.registrationWork[registrationKey] = EpochRegistrationWork(
                workID: registration.workID,
                ownerChildDeviceID: registration.ownerChildDeviceID,
                epochID: registration.epochID,
                routeID: registration.routeID,
                request: correctedRequest,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: clock.now,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: registration.createdAt
            )
        }
    }

    private func recoverPhysicalIdentityRequired(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff,
                  handoff.ownerChildDeviceID == owner,
                  handoff.phase == .cutoverReady,
                  handoff.explicitRecovery == nil,
                  state.activeGenerationID == handoff.fromGenerationID,
                  state.activeEpochID == handoff.fromEpochID,
                  state.activeRouteID == handoff.fromRouteID,
                  let candidateEpoch = state.epochs[handoff.toEpochID],
                  candidateEpoch.childDeviceID == owner,
                  candidateEpoch.status == .active,
                  candidateEpoch.retiredAt == nil,
                  let candidateRoute = state.routes[handoff.toRouteID],
                  candidateRoute.ownerChildDeviceID == owner,
                  candidateRoute.epochID == candidateEpoch.epochID,
                  candidateRoute.lifecycle == .active,
                  state.installWork.values.filter({
                      $0.ownerChildDeviceID == owner
                          && $0.routeID == candidateRoute.routeID
                          && $0.phase == .dualActive
                  }).count == 1,
                  !state.activationWork.values.contains(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.epochID == candidateEpoch.epochID
                          && $0.routeID == candidateRoute.routeID
                          && $0.retry.terminal == .succeeded
                  })
            else { return }

            let rejected = state.registrationWork.values
                .filter {
                    isPhysicalIdentityRecoveryRejection(
                        $0,
                        owner: owner,
                        epoch: candidateEpoch,
                        route: candidateRoute
                    )
                }
                .sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt < $1.createdAt
                    }
                    return $0.workID.uuidString.lowercased()
                        < $1.workID.uuidString.lowercased()
                }
            guard let selected = rejected.first,
                  !state.registrationWork.values.contains(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.epochID == candidateEpoch.epochID
                          && $0.routeID == candidateRoute.routeID
                          && (
                              $0.retry.terminal == .pending
                                  || $0.retry.terminal == .succeeded
                          )
                  })
            else { return }

            state.registrationWork[selected.workID] = EpochRegistrationWork(
                workID: selected.workID,
                ownerChildDeviceID: selected.ownerChildDeviceID,
                epochID: selected.epochID,
                routeID: selected.routeID,
                request: registrationRequest(
                    epoch: candidateEpoch,
                    reason: .identityRecovery
                ),
                claim: nil,
                retry: pendingRetry(),
                createdAt: selected.createdAt
            )
            for duplicate in rejected.dropFirst() {
                var terminal = duplicate
                terminal.claim = nil
                terminal.retry.terminal = .superseded
                terminal.retry.lastErrorCode =
                    "duplicate_physical_identity_recovery_superseded"
                state.registrationWork[terminal.workID] = terminal
            }
            handoff.explicitRecovery = .identityRecovery
            state.v2RouteHandoff = handoff
        }
    }

    private func reconcileCoverage(owner: UUID) throws {
        guard let coverage = try installer.refreshCoverage(ownerChildDeviceID: owner),
              coverage.status == .coverageExhausted
        else { return }
        let references = try store.read().shieldReferences.values
            .filter { $0.ownerChildDeviceID == owner }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.operationID.uuidString.lowercased()
                    < $1.operationID.uuidString.lowercased()
            }
        for reference in references {
            try releaseIdentityShield(reference.operationID, owner)
        }
    }

    /// Reconciles the server-authoritative accounting gate without stopping
    /// Apple's dated monitor. A reopened gate always receives a fresh route:
    /// Apple exposes no exact raw counter that can safely resume the old one.
    func reconcileUsageGate(
        ownerChildDeviceID owner: UUID,
        allowed: Bool,
        runtime: EarnedTimeRuntime
    ) throws {
        guard store.isCurrentOwner(owner) else { return }
        try store.transaction(expectedOwner: owner) { state in
            guard state.ratchets[owner]?.localSelection == .v2,
                  let priorRouteID = state.activeRouteID,
                  let priorEpochID = state.activeEpochID,
                  let generationID = state.activeGenerationID,
                  var priorEpoch = state.epochs[priorEpochID],
                  let priorRoute = state.routes[priorRouteID],
                  let generation = state.generations[generationID],
                  priorRoute.ownerChildDeviceID == owner,
                  priorRoute.epochID == priorEpochID,
                  priorRoute.generationID == generationID,
                  priorRoute.lifecycle == .active,
                  generation.childDeviceID == owner,
                  generation.retiredAt == nil
            else { return }

            if !allowed {
                guard priorEpoch.status == .active || priorEpoch.status == .paused else { return }
                priorEpoch.status = .paused
                state.epochs[priorEpochID] = priorEpoch
                return
            }

            retireSupersededPausedCrossDayHandoffIfNeeded(
                state: &state,
                owner: owner,
                priorRouteID: priorRouteID,
                priorEpochID: priorEpochID,
                runtime: runtime
            )

            if var handoff = state.v2RouteHandoff,
               handoff.ownerChildDeviceID == owner,
               handoff.phase == .cutoverReady,
               handoff.fromRouteID == priorRouteID,
               handoff.fromEpochID == priorEpochID,
               let candidateRoute = state.routes[handoff.toRouteID],
               var candidateEpoch = state.epochs[handoff.toEpochID],
               candidateRoute.ownerChildDeviceID == owner,
               candidateRoute.epochID == candidateEpoch.epochID,
               candidateRoute.usageDate == runtime.usageDate,
               candidateEpoch.status == .paused,
               candidateEpoch.retiredAt == nil,
               candidateEpoch.canonicalTimezone == runtime.timezone,
               candidateEpoch.policyRevision == runtime.policyRevision,
               state.registrationWork.values.contains(where: {
                   $0.ownerChildDeviceID == owner
                       && $0.epochID == candidateEpoch.epochID
                       && $0.routeID == candidateRoute.routeID
                       && $0.retry.terminal == .succeeded
               }),
               !state.activationWork.values.contains(where: {
                   $0.ownerChildDeviceID == owner
                       && $0.epochID == candidateEpoch.epochID
                       && $0.routeID == candidateRoute.routeID
               }) {
                candidateEpoch.status = .active
                state.epochs[candidateEpoch.epochID] = candidateEpoch
                handoff.registrationAcknowledgedAt =
                    handoff.registrationAcknowledgedAt ?? clock.now
                state.v2RouteHandoff = handoff
                return
            }

            guard priorEpoch.status == .paused,
                  state.v2RouteHandoff == nil,
                  runtime.dailyPoolMinutes > 0,
                  runtime.deviceCapMinutes > 0,
                  runtime.estimatedMinutes >= 0,
                  runtime.estimatedMinutes < min(runtime.dailyPoolMinutes, runtime.deviceCapMinutes)
            else { return }

            let targetGeneration: MeteringPolicyGeneration
            if runtime.usageDate == priorEpoch.usageDate,
               runtime.timezone == generation.canonicalTimezone,
               runtime.policyRevision == generation.policyRevision {
                targetGeneration = generation
            } else if runtime.usageDate == priorEpoch.usageDate,
                      runtime.timezone == generation.canonicalTimezone {
                // Same day, drifted policy revision. The strict path below only
                // handles a DAY change, so this case used to fall through and
                // return — leaving the epoch paused forever. That is exactly
                // what a fresh pairing produces: the epoch registers during
                // onboarding, the pool config is written moments later, and the
                // revision no longer matches, so clearing the onboarding
                // reflection could never resume the pool (2026-08-07, real
                // device: paused from 19:24 until an unrelated config change
                // minted a new epoch at 19:27).
                //
                // Resume onto the generation that matches the live policy when
                // one exists; otherwise resume on the current generation. Both
                // beat staying paused, and the desired-policy machinery re-paves
                // afterwards either way.
                targetGeneration = state.generations.values
                    .filter {
                        $0.childDeviceID == owner
                            && $0.retiredAt == nil
                            && $0.canonicalTimezone == runtime.timezone
                            && $0.policyRevision == runtime.policyRevision
                    }
                    .sorted { $0.createdAt > $1.createdAt }
                    .first ?? generation
            } else {
                guard priorEpoch.usageDate < runtime.usageDate,
                      let desired = state.desiredPolicy,
                      desired.ownerChildDeviceID == owner,
                      desired.usageDate == runtime.usageDate,
                      desired.canonicalTimezone == runtime.timezone,
                      desired.policyRevision == runtime.policyRevision,
                      let current = state.generations.values
                        .filter({
                            $0.childDeviceID == owner
                                && $0.retiredAt == nil
                                && $0.canonicalTimezone == runtime.timezone
                                && $0.policyRevision == runtime.policyRevision
                                && (desired.enforcementSetID == nil
                                    || $0.enforcementSetID == desired.enforcementSetID)
                        })
                        .sorted(by: {
                            if $0.createdAt != $1.createdAt {
                                return $0.createdAt > $1.createdAt
                            }
                            return $0.generationID.uuidString.lowercased()
                                < $1.generationID.uuidString.lowercased()
                        })
                        .first
                else { return }
                targetGeneration = current
            }

            if priorEpoch.usageDate < runtime.usageDate {
                for (key, var sample) in state.sampleWork
                    where sample.ownerChildDeviceID == owner
                        && sample.epochID == priorEpochID
                        && sample.routeID == priorRouteID
                        && sample.retry.terminal == .pending {
                    sample.claim = nil
                    sample.retry.terminal = .rejected
                    sample.retry.lastErrorCode = "paused_day_closed"
                    sample.retry.nextAttemptAt = clock.now
                    state.sampleWork[key] = sample
                }
            }

            let existingCandidate = state.routes.values.contains { route in
                guard route.ownerChildDeviceID == owner,
                      route.routeID != priorRouteID,
                      route.generationID == targetGeneration.generationID,
                      route.usageDate == runtime.usageDate,
                      route.lifecycle == .planned,
                      let epoch = state.epochs[route.epochID]
                else { return false }
                return epoch.status == .active
                    && epoch.resumeBoundaryPending
                    && epoch.baseAcceptedMinutes == runtime.estimatedMinutes
                    && epoch.baseSource == .childState200
            }
            guard !existingCandidate else { return }

            let epochID = UUID()
            let routeID = UUID()
            let epoch = DeviceDailyEpoch(
                epochID: epochID,
                protocolVersion: 2,
                childDeviceID: owner,
                usageDate: runtime.usageDate,
                canonicalTimezone: targetGeneration.canonicalTimezone,
                policyRevision: targetGeneration.policyRevision,
                measurementSelectionDigest: targetGeneration.measurementSelectionDigest,
                enforcementSetID: targetGeneration.enforcementSetID,
                startedAt: clock.now,
                registeredAt: nil,
                baseAcceptedMinutes: runtime.estimatedMinutes,
                baseSource: .childState200,
                lastRawThresholdMinutes: 0,
                excludedWhilePausedMinutes: 0,
                status: .active,
                resumeBoundaryPending: true,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            let remaining = MeteringDatedSchedule.remainingPolicy(
                poolMinutes: runtime.dailyPoolMinutes,
                capMinutes: runtime.deviceCapMinutes,
                offsetMinutes: runtime.estimatedMinutes
            )
            let thresholds = remaining.map {
                MeteringDatedSchedule.thresholds(
                    poolMinutes: $0.poolMinutes,
                    capMinutes: $0.capMinutes
                )
            } ?? []
            state.epochs[epochID] = epoch
            state.routes[routeID] = MeteringCallbackRoute(
                routeID: routeID,
                activityName: MeteringRouteNamespace.activityName(routeID: routeID),
                namespace: MeteringRouteNamespace.prefix,
                generationID: targetGeneration.generationID,
                generationKey: MeteringGenerationKey(
                    protocolVersion: targetGeneration.protocolVersion,
                    childDeviceID: targetGeneration.childDeviceID,
                    canonicalTimezone: targetGeneration.canonicalTimezone,
                    policyRevision: targetGeneration.policyRevision,
                    measurementSelectionDigest: targetGeneration.measurementSelectionDigest,
                    enforcementSetID: targetGeneration.enforcementSetID
                ),
                ownerChildDeviceID: owner,
                usageDate: runtime.usageDate,
                epochID: epochID,
                plannedSchedule: DatedSchedulePlan(
                    usageDate: runtime.usageDate,
                    timezoneIdentifier: targetGeneration.canonicalTimezone,
                    calendarIdentifier: "gregorian"
                ),
                installedSchedule: nil,
                plannedEvents: thresholds.map { threshold in
                    MeteringEventPlan(
                        eventName: MeteringRouteNamespace.eventName(
                            routeID: routeID,
                            thresholdMinutes: threshold
                        ),
                        thresholdMinutes: threshold
                    )
                },
                installedEvents: nil,
                lifecycle: .planned,
                createdAt: clock.now,
                // Cut over `runtime.estimatedMinutes` just above, so that is
                // what a rung of this ladder is relative to (BUG 1).
                ladderBaseMinutes: runtime.estimatedMinutes
            )
            let installID = UUID()
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .offlinePending,
                phase: .pendingStart,
                claim: nil,
                retry: pendingRetry(),
                createdAt: clock.now
            )
        }
    }

    private func retireSupersededPausedCrossDayHandoffIfNeeded(
        state: inout DeviceEpochStoreState,
        owner: UUID,
        priorRouteID: UUID,
        priorEpochID: UUID,
        runtime: EarnedTimeRuntime
    ) {
        guard let priorEpoch = state.epochs[priorEpochID],
              priorEpoch.status == .paused,
              priorEpoch.usageDate < runtime.usageDate,
              let handoff = state.v2RouteHandoff,
              handoff.ownerChildDeviceID == owner,
              handoff.phase != .committed,
              handoff.fromRouteID == priorRouteID,
              handoff.fromEpochID == priorEpochID,
              var targetRoute = state.routes[handoff.toRouteID],
              var targetEpoch = state.epochs[handoff.toEpochID],
              targetRoute.ownerChildDeviceID == owner,
              targetRoute.epochID == targetEpoch.epochID,
              targetRoute.usageDate == runtime.usageDate,
              targetRoute.lifecycle == .planned
                  || targetRoute.lifecycle == .active,
              targetEpoch.status == .active,
              targetEpoch.retiredAt == nil,
              !targetEpoch.resumeBoundaryPending,
              let installKey = uniqueInstallKey(for: targetRoute.routeID, in: state),
              let install = state.installWork[installKey],
              !state.activationWork.values.contains(where: {
                  $0.routeID == targetRoute.routeID
                      && (
                          $0.retry.terminal == .pending
                              || $0.retry.terminal == .succeeded
                      )
              }),
              let dayEnd = state.canonicalDayEnd(
                  usageDate: targetRoute.usageDate,
                  timeZoneIdentifier: targetEpoch.canonicalTimezone
              )
        else { return }

        targetEpoch.status = .retired
        targetEpoch.retiredAt = clock.now
        targetEpoch.retireReason = .activationSuperseded
        state.epochs[targetEpoch.epochID] = targetEpoch
        targetRoute.lifecycle = .tombstoned
        state.routes[targetRoute.routeID] = targetRoute
        let wasNeverInstalled = install.phase == .pendingStart
            && install.retry.terminal == .superseded
            && install.retry.lastErrorCode == "route_superseded"
        state.tombstones[targetRoute.routeID] = MeteringRouteTombstone(
            routeID: targetRoute.routeID,
            activityName: targetRoute.activityName,
            eventNames: targetRoute.plannedEvents.map(\.eventName),
            ownerChildDeviceID: owner,
            usageDate: targetRoute.usageDate,
            epochID: targetEpoch.epochID,
            generationID: targetRoute.generationID,
            canonicalDayEnd: dayEnd,
            stopAcknowledgedAt: wasNeverInstalled ? clock.now : nil,
            referencedWorkIDs: [],
            retainedUntil: nil
        )
        state.installWork[installKey]?.claim = nil
        state.installWork[installKey]?.phase =
            wasNeverInstalled ? .stopped : .pendingStop
        for (key, var work) in state.registrationWork
        where work.routeID == targetRoute.routeID
            && work.retry.terminal == .pending {
            work.claim = nil
            work.retry.terminal = .superseded
            work.retry.lastErrorCode = "cross_day_resume_superseded"
            state.registrationWork[key] = work
        }
        for (key, var work) in state.activationWork
        where work.routeID == targetRoute.routeID
            && work.retry.terminal == .pending {
            work.claim = nil
            work.retry.terminal = .superseded
            work.retry.lastErrorCode = "cross_day_resume_superseded"
            state.activationWork[key] = work
        }
        state.v2RouteHandoff = nil
    }

    private func recoverCanonicalRolloverIfPresent(owner: UUID) async throws -> Bool {
        guard var work = try store.read().rolloverEffectsWork,
              work.ownerChildDeviceID == owner
        else { return false }
        // Only a RUNNING rollover owns the pass. `.succeeded` is history, and
        // `.superseded` is a rollover that `yieldSupersededCanonicalRolloverIfNeeded`
        // retired because its generation's policy revision is dead — driving
        // either one would re-enter the deadlock this early-return exists to
        // break.
        guard work.retry.terminal == .pending else { return false }

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
                  !hasNonterminalPriorRouteWork(work.oldRouteID, in: state)
            else { return }
            handoff.phase = .cutoverReady
            handoff.priorRouteInputClosedAt = clock.now
            state.v2RouteHandoff = handoff
        }
        try enqueueRolloverRegistrationIfNeeded(workID: workID, owner: owner)
    }

    private func enqueueRolloverRegistrationIfNeeded(
        workID: UUID,
        owner: UUID
    ) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let work = state.rolloverEffectsWork, work.workID == workID,
                  let handoff = state.v2RouteHandoff,
                  handoff.handoffID == workID,
                  handoff.phase == .cutoverReady,
                  let epoch = state.epochs[work.newEpochID],
                  let route = state.routes[work.newRouteID],
                  route.epochID == epoch.epochID,
                  route.usageDate == epoch.usageDate,
                  let timeZone = TimeZone(identifier: epoch.canonicalTimezone)
            else { return }
            let startedAt = try MeteringDatedSchedule.canonicalStart(
                usageDate: epoch.usageDate,
                timeZone: timeZone
            )
            let request = registrationRequest(
                epoch: epoch,
                reason: .dayRollover,
                startedAt: startedAt
            )
            guard !state.registrationWork.values.contains(where: {
                $0.epochID == work.newEpochID
                    && $0.routeID == work.newRouteID
                    && $0.request == request
            }) else { return }
            let registrationID = UUID()
            state.registrationWork[registrationID] = EpochRegistrationWork(
                workID: registrationID,
                ownerChildDeviceID: owner,
                epochID: work.newEpochID,
                routeID: work.newRouteID,
                request: request,
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
        _ = try store.recoverIdentityCleanupMirrorAcknowledgement(
            workID: cleanup.workID
        )
        let refreshed = try requiredIdentityCleanup(workID: cleanup.workID)
        if refreshed.retry.terminal == .succeeded {
            return try store.finalizeIdentityCleanup(workID: refreshed.workID)
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
            do {
                try releaseIdentityShield(operationID, current.oldOwnerChildDeviceID)
            } catch EarnedShieldEffectError.casConflict(let conflictedOperationID)
                where conflictedOperationID == operationID {
                // The effect store persists `.conflicted` before raising this
                // error and leaves the newer lock record byte-for-byte intact.
                // For an identity being retired, that is a safe terminal
                // outcome: retrying can never make the obsolete earned source
                // authoritative again and must not block adoption forever.
                MeteringFlightRecorder.emit(
                    kind: .meteringDay,
                    site: "recovery.identity_cleanup",
                    verdict: "shield_conflict_preserved_newer_record",
                    detail: MeteringFlightRecorder.detail([
                        ("operation", MeteringFlightRecorder.shortID(operationID)),
                    ]),
                    corrID: operationID
                )
            }
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

        return try store.markIdentityCleanupSucceeded(workID: cleanup.workID)
    }

    private func requiredIdentityCleanup(workID: UUID) throws -> IdentityCleanupWork {
        guard let cleanup = try store.read().identityCleanupWork,
              cleanup.workID == workID
        else { throw DeviceEpochStoreError.ownerMismatch }
        return cleanup
    }

    /// #53 (FIX-0c): a non-committed handoff whose CANDIDATE's day has already
    /// ended can never cut over — its dated schedule is gone — yet it owns the
    /// single handoff slot. Every path out is then guarded shut: the rollover
    /// effect leg only adopts a slot holding its own handoffID, the cross-day
    /// resume mint requires the slot empty, and the abandon sweeps demand a
    /// TERMINAL rejection the never-registered candidate does not have (iPad
    /// 2026-08-05: pinned on yesterday all night). An elapsed day IS terminal
    /// evidence — no network verdict can revive a route whose window is over.
    /// Retire the candidate exactly like the cross-day resume replacement does
    /// and free the slot; the next gate reconcile or rollover then re-plans
    /// the current day through its normal path.
    private func abandonElapsedCandidateHandoffIfNeeded(owner: UUID) throws {
        var abandoned: (route: UUID, from: String, to: String)?
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.ownerChildDeviceID == owner,
                  handoff.phase != .committed,
                  state.activeRouteID == handoff.fromRouteID,
                  var targetRoute = state.routes[handoff.toRouteID],
                  var targetEpoch = state.epochs[handoff.toEpochID],
                  targetRoute.ownerChildDeviceID == owner,
                  targetRoute.epochID == targetEpoch.epochID,
                  targetRoute.lifecycle == .planned
                      || targetRoute.lifecycle == .active,
                  targetEpoch.retiredAt == nil,
                  !state.hasExactSuccessfulActivation(
                      owner: owner,
                      epochID: targetEpoch.epochID,
                      routeID: targetRoute.routeID
                  ),
                  let timeZone = TimeZone(identifier: targetEpoch.canonicalTimezone),
                  MeteringDatedSchedule.hasElapsed(
                      usageDate: targetRoute.usageDate,
                      timeZone: timeZone,
                      now: clock.now
                  ),
                  let installKey = uniqueInstallKey(for: targetRoute.routeID, in: state),
                  let install = state.installWork[installKey],
                  let dayEnd = state.canonicalDayEnd(
                      usageDate: targetRoute.usageDate,
                      timeZoneIdentifier: targetEpoch.canonicalTimezone
                  )
            else { return }

            targetEpoch.status = .retired
            targetEpoch.retiredAt = clock.now
            targetEpoch.retireReason = .activationSuperseded
            state.epochs[targetEpoch.epochID] = targetEpoch
            targetRoute.lifecycle = .tombstoned
            state.routes[targetRoute.routeID] = targetRoute
            let wasNeverInstalled = install.phase == .pendingStart
            state.tombstones[targetRoute.routeID] = MeteringRouteTombstone(
                routeID: targetRoute.routeID,
                activityName: targetRoute.activityName,
                eventNames: targetRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: targetRoute.usageDate,
                epochID: targetEpoch.epochID,
                generationID: targetRoute.generationID,
                canonicalDayEnd: dayEnd,
                stopAcknowledgedAt: wasNeverInstalled ? clock.now : nil,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            state.installWork[installKey]?.claim = nil
            state.installWork[installKey]?.phase =
                wasNeverInstalled ? .stopped : .pendingStop
            if wasNeverInstalled {
                state.installWork[installKey]?.retry.terminal = .superseded
                state.installWork[installKey]?.retry.lastErrorCode = "candidate_day_elapsed"
            }
            for (key, var work) in state.registrationWork
            where work.routeID == targetRoute.routeID
                && work.retry.terminal == .pending {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "candidate_day_elapsed"
                state.registrationWork[key] = work
            }
            for (key, var work) in state.activationWork
            where work.routeID == targetRoute.routeID
                && work.retry.terminal == .pending {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "candidate_day_elapsed"
                state.activationWork[key] = work
            }
            state.v2RouteHandoff = nil
            abandoned = (
                targetRoute.routeID,
                targetRoute.usageDate,
                MeteringEpochContract.canonicalUsageDate(
                    at: clock.now,
                    timezoneIdentifier: targetEpoch.canonicalTimezone
                ) ?? ""
            )
        }
        guard let abandoned else { return }
        MeteringFlightRecorder.emit(
            kind: .meteringDay,
            site: "recovery.elapsedCandidateAbandon",
            verdict: "abandoned",
            detail: MeteringFlightRecorder.detail([
                ("route", MeteringFlightRecorder.shortID(abandoned.route)),
                ("code", "candidate_day_elapsed"),
            ]),
            corrID: abandoned.route,
            transition: ScreenTimeEvent.Transition(
                before: abandoned.from,
                after: abandoned.to
            )
        )
    }

    private func prepareReplacementIfNeeded(owner: UUID) throws {
        let crossedDay: (from: String, to: String, route: UUID)? = try store.transaction(expectedOwner: owner) { state in
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
                  let priorInstall = state.installWork[priorInstallKey],
                  let candidateInstallKey = uniqueInstallKey(for: candidate.routeID, in: state)
            else { return nil }

            guard priorInstall.phase == .active
                    || state.isStaleActiveRouteConfirmedAbsent(
                        owner: owner,
                        routeID: fromRouteID
                    )
            else { return nil }

            var handoff = V2RouteHandoff(
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
            if candidateEpoch.resumeBoundaryPending {
                handoff.explicitRecovery = .gateResumeConservative
            }
            state.v2RouteHandoff = handoff
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
            guard candidate.usageDate != fromRoute.usageDate else { return nil }
            return (fromRoute.usageDate, candidate.usageDate, candidate.routeID)
        }
        guard let crossedDay else { return }
        // A replacement that also changes the day only happens on the rescue
        // path above — worth a durable line, because it is the moment a device
        // stranded on a past day starts moving again.
        MeteringFlightRecorder.emit(
            kind: .meteringDay,
            site: "recovery.staleDayReplacement",
            verdict: "adopted_today",
            detail: MeteringFlightRecorder.detail([
                ("route", MeteringFlightRecorder.shortID(crossedDay.route)),
            ]),
            corrID: crossedDay.route,
            transition: ScreenTimeEvent.Transition(
                before: crossedDay.from,
                after: crossedDay.to
            )
        )
    }

    private func promoteVerifiedCandidate(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let ratchet = state.ratchets[owner] else { return }
            if ratchet.localSelection == .v1
                || ratchet.localSelection == .v2Pending
                || ratchet.localSelection == .dualActive {
                guard let candidate = initialCandidate(in: state, owner: owner),
                      let installKey = uniqueInstallKey(for: candidate.routeID, in: state),
                      state.installWork[installKey]?.phase == .verified,
                      hasUniqueSuccessfulRegistration(candidate, owner: owner, in: state)
                else { return }
                state.routes[candidate.routeID]?.lifecycle = .active
                state.installWork[installKey]?.phase = .dualActive
                var updated = ratchet
                updated.localSelection = .dualActive
                updated.dualActiveAt = updated.dualActiveAt ?? clock.now
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
                (
                    $0.ownerChildDeviceID == owner
                        && $0.epochID == epoch.epochID
                        && $0.routeID == candidate.routeID
                        && (
                            $0.retry.terminal == .pending
                                || $0.retry.terminal == .succeeded
                        )
                ) || isPhysicalIdentityRecoveryRejection(
                    $0,
                    owner: owner,
                    epoch: epoch,
                    route: candidate
                )
            }
            if !hasUsableRegistration {
                let reason: EpochRegistrationReasonDTO
                if epoch.resumeBoundaryPending {
                    reason = .gateResumeConservative
                } else {
                    guard let priorEpoch = state.epochs[handoff.fromEpochID],
                          let classified = MeteringEpochContract.replacementReason(
                              active: epochKey(priorEpoch),
                              next: epochKey(epoch),
                              explicitRecovery: handoff.explicitRecovery
                          ),
                          let declared = EpochRegistrationReasonDTO(rawValue: classified.rawValue)
                    else { return }
                    reason = declared
                }
                let workID = UUID()
                state.registrationWork[workID] = EpochRegistrationWork(
                    workID: workID,
                    ownerChildDeviceID: owner,
                    epochID: epoch.epochID,
                    routeID: candidate.routeID,
                    request: registrationRequest(
                        epoch: epoch,
                        reason: reason
                    ),
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
                  let candidateEpoch = state.epochs[handoff.toEpochID],
                  candidateEpoch.status == .active
                      || candidateEpoch.status == .exhausted,
                  hasUniqueSuccessfulRegistration(candidate, owner: owner, in: state)
            else { return }
            enqueueActivationIfNeeded(route: candidate, owner: owner, state: &state)
        }
    }

    private func recoverTerminalInitialActivation(owner: UUID) throws {
        var recoveryVerdict: (String, UUID, String)?
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

            let errorCode = activation.retry.lastErrorCode ?? "unknown_activation_error"
            let requiresFreshIdentity = errorCode == "activation_route_mismatch"
                || errorCode == "activation_policy_not_current"
                || errorCode == "activation_enforcement_set_not_current"
                || (errorCode == "activation_epoch_not_current"
                    && activation.retry.attemptCount > 0)
            if requiresFreshIdentity {
                guard retireTerminalInitialActivationCandidate(
                    state: &state,
                    owner: owner,
                    candidate: candidate,
                    activation: activation,
                    installKey: installKey,
                    errorCode: errorCode
                ) else { return }
                recoveryVerdict = ("retired_for_replan", candidate.routeID, errorCode)
                return
            }

            let canRetrySamePhysicalIdentity = errorCode == "epoch_not_active"
                || errorCode == "epoch_paused"
                || (errorCode == "activation_epoch_not_current"
                    && activation.retry.attemptCount == 0)
            guard canRetrySamePhysicalIdentity else {
                recoveryVerdict = ("terminal_requires_attention", candidate.routeID, errorCode)
                return
            }
            state.routes[candidate.routeID]?.lifecycle = .planned
            state.installWork[installKey]?.phase = .verified
            if errorCode == "epoch_not_active" || errorCode == "epoch_paused" {
                // The first activation never commits v2 while the gate is
                // closed. Keep v1 countable and leave this epoch durably
                // paused; Task 17 may create a distinct conservative epoch
                // only after it receives a later authoritative open state.
                state.epochs[candidate.epochID]?.status = .paused
            }
            // V2-only builds never silently fall back to the legacy ladder.
            // Re-open this verified candidate as pending v2 activation and let
            // the normal delivery retry policy drive the next attempt.
            state.routes[candidate.routeID]?.lifecycle = .planned
            state.installWork[installKey]?.phase = .verified
            var retriedActivation = activation
            retriedActivation.claim = nil
            retriedActivation.retry = MeteringRetryState(
                attemptCount: activation.retry.attemptCount + 1,
                nextAttemptAt: MeteringRetryPolicy.nextAttempt(
                    after: activation.retry.attemptCount + 1,
                    now: clock.now
                ),
                lastErrorCode: activation.retry.lastErrorCode,
                terminal: .pending
            )
            if let activationKey = state.activationWork.first(where: {
                $0.value.workID == activation.workID
            })?.key {
                state.activationWork[activationKey] = retriedActivation
            }
            ratchet.localSelection = .v2Pending
            ratchet.advertisedVersion = max(ratchet.advertisedVersion, 2)
            ratchet.dualActiveAt = nil
            state.ratchets[owner] = ratchet
        }

        if let recoveryVerdict {
            MeteringFlightRecorder.emit(
                kind: .meteringDay,
                site: "recovery.initial_activation",
                verdict: recoveryVerdict.0,
                detail: MeteringFlightRecorder.detail([
                    ("route", MeteringFlightRecorder.shortID(recoveryVerdict.1)),
                    ("error", recoveryVerdict.2),
                ]),
                corrID: recoveryVerdict.1
            )
        }
    }

    private func retireTerminalInitialActivationCandidate(
        state: inout DeviceEpochStoreState,
        owner: UUID,
        candidate: MeteringCallbackRoute,
        activation: EpochActivationWork,
        installKey: UUID,
        errorCode: String
    ) -> Bool {
        guard state.ownerChildDeviceID == owner,
              state.v2RouteHandoff == nil,
              state.activeRouteID == nil,
              state.activeGenerationID == candidate.generationID,
              state.activeEpochID == candidate.epochID,
              var route = state.routes[candidate.routeID],
              route.lifecycle == .active,
              var epoch = state.epochs[candidate.epochID],
              epoch.childDeviceID == owner,
              epoch.status != .retired,
              state.generations[candidate.generationID]?.childDeviceID == owner,
              uniqueInstallKey(for: candidate.routeID, in: state) == installKey,
              state.installWork[installKey]?.phase == .dualActive,
              activation.ownerChildDeviceID == owner,
              activation.epochID == candidate.epochID,
              activation.routeID == candidate.routeID,
              activation.retry.terminal != .pending,
              activation.retry.terminal != .succeeded,
              let dayEnd = state.canonicalDayEnd(
                  usageDate: route.usageDate,
                  timeZoneIdentifier: epoch.canonicalTimezone
              )
        else { return false }

        epoch.status = .retired
        epoch.retiredAt = clock.now
        epoch.retireReason = .activationSuperseded
        state.epochs[epoch.epochID] = epoch
        state.generations[route.generationID]?.retiredAt = clock.now
        route.lifecycle = .tombstoned
        state.routes[route.routeID] = route

        for (key, var sample) in state.sampleWork where sample.routeID == route.routeID {
            guard sample.retry.terminal == .pending else { continue }
            sample.claim = nil
            sample.retry.terminal = .superseded
            sample.retry.lastErrorCode = errorCode
            state.sampleWork[key] = sample
        }
        state.deferredCallbacks = state.deferredCallbacks.filter {
            $0.value.routeID != route.routeID
        }
        state.installWork[installKey]?.claim = nil
        state.installWork[installKey]?.phase = .pendingStop

        let relatedWorkIDs = Set(
            state.registrationWork.values.filter {
                $0.epochID == epoch.epochID && $0.routeID == route.routeID
            }.map(\.workID)
                + state.activationWork.values.filter {
                    $0.epochID == epoch.epochID && $0.routeID == route.routeID
                }.map(\.workID)
                + state.sampleWork.values.filter {
                    $0.epochID == epoch.epochID && $0.routeID == route.routeID
                }.map(\.workID)
                + state.installWork.values.filter {
                    $0.routeID == route.routeID
                }.map(\.workID)
        )
        state.tombstones[route.routeID] = MeteringRouteTombstone(
            routeID: route.routeID,
            activityName: route.activityName,
            eventNames: route.plannedEvents.map(\.eventName),
            ownerChildDeviceID: owner,
            usageDate: route.usageDate,
            epochID: epoch.epochID,
            generationID: route.generationID,
            canonicalDayEnd: dayEnd,
            stopAcknowledgedAt: nil,
            referencedWorkIDs: relatedWorkIDs,
            retainedUntil: nil
        )
        state.activeGenerationID = nil
        state.activeEpochID = nil
        state.activeRouteID = nil
        if var ratchet = state.ratchets[owner] {
            ratchet.localSelection = .v2Pending
            ratchet.advertisedVersion = max(ratchet.advertisedVersion, 2)
            ratchet.dualActiveAt = nil
            state.ratchets[owner] = ratchet
        }
        return true
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
                  let priorInstall = state.installWork[priorInstallKey],
                  priorInstall.phase == .active
                      || state.hasExactStaleDayPriorAbsent(owner: owner, handoff: handoff),
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
            let isConservativeResume = handoff.explicitRecovery == .gateResumeConservative
                || (
                    candidate.generationID == prior.generationID
                        && state.epochs[candidate.epochID]?.resumeBoundaryPending == true
                )
            let isIdentityRecovery = handoff.explicitRecovery == .identityRecovery
            if isConservativeResume {
                priorEpoch.retireReason = .gateResumeConservative
            } else if isIdentityRecovery {
                priorEpoch.retireReason = .identityRecovery
            } else {
                priorEpoch.retireReason = .policyChange
            }
            state.epochs[priorEpoch.epochID] = priorEpoch
            if handoff.fromGenerationID != handoff.toGenerationID {
                state.generations[handoff.fromGenerationID]?.retiredAt = clock.now
            }
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
            // Even an already-absent stale prior moves through pendingStop so
            // the existing two-transaction stop acknowledgement invariant
            // remains intact. The next pass observes daemon absence and
            // atomically persists `.stopped` plus both acknowledgements.
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

        guard let legacy = state.legacy,
              legacy.phase == .retiringV1
        else { return }
        let names = legacyActivityNames(legacy).map { DeviceActivityName($0) }
        center.stopMonitoring(names)
        guard names.allSatisfy({ !center.activities.contains($0) }) else { return }
        try store.transaction(expectedOwner: owner) { state in
            guard var current = state.legacy, current.phase == .retiringV1 else { return }
            current.phase = .stoppedV1
            current.stopAcknowledgedAt = clock.now
            state.legacy = current
        }
    }

    private func abandonTerminalConservativeCandidate(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.phase == .cutoverReady,
                  handoff.fromGenerationID == handoff.toGenerationID,
                  state.activeGenerationID == handoff.fromGenerationID,
                  state.activeEpochID == handoff.fromEpochID,
                  state.activeRouteID == handoff.fromRouteID,
                  state.epochs[handoff.fromEpochID]?.status == .paused,
                  var candidateEpoch = state.epochs[handoff.toEpochID],
                  candidateEpoch.resumeBoundaryPending,
                  candidateEpoch.baseSource == .childState200,
                  var candidateRoute = state.routes[handoff.toRouteID],
                  let candidateInstallKey = uniqueInstallKey(for: handoff.toRouteID, in: state),
                  state.installWork[candidateInstallKey]?.phase == .dualActive,
                  let dayEnd = state.canonicalDayEnd(
                      usageDate: candidateRoute.usageDate,
                      timeZoneIdentifier: candidateEpoch.canonicalTimezone
                  )
            else { return }
            let registrationTerminated = state.registrationWork.values.contains {
                $0.epochID == handoff.toEpochID
                    && $0.routeID == handoff.toRouteID
                    && $0.retry.terminal != .pending
                    && $0.retry.terminal != .succeeded
            }
            let activationTerminated = state.activationWork.values.contains {
                $0.epochID == handoff.toEpochID
                    && $0.routeID == handoff.toRouteID
                    && $0.retry.terminal != .pending
                    && $0.retry.terminal != .succeeded
            }
            guard registrationTerminated || activationTerminated else { return }

            candidateEpoch.status = .retired
            candidateEpoch.retiredAt = clock.now
            candidateEpoch.retireReason = .gateResumeConservative
            state.epochs[candidateEpoch.epochID] = candidateEpoch
            candidateRoute.lifecycle = .tombstoned
            state.routes[candidateRoute.routeID] = candidateRoute
            state.tombstones[candidateRoute.routeID] = MeteringRouteTombstone(
                routeID: candidateRoute.routeID,
                activityName: candidateRoute.activityName,
                eventNames: candidateRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: candidateRoute.usageDate,
                epochID: candidateEpoch.epochID,
                generationID: candidateRoute.generationID,
                canonicalDayEnd: dayEnd,
                stopAcknowledgedAt: nil,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            state.installWork[candidateInstallKey]?.phase = .pendingStop
            state.v2RouteHandoff = nil
        }
    }

    private func abandonTerminalSupersededCandidate(owner: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.phase == .cutoverReady,
                  state.activeGenerationID == handoff.fromGenerationID,
                  state.activeEpochID == handoff.fromEpochID,
                  state.activeRouteID == handoff.fromRouteID,
                  var candidateEpoch = state.epochs[handoff.toEpochID],
                  candidateEpoch.status == .active,
                  var candidateRoute = state.routes[handoff.toRouteID],
                  candidateRoute.lifecycle == .active,
                  let candidateInstallKey = uniqueInstallKey(for: handoff.toRouteID, in: state),
                  state.installWork[candidateInstallKey]?.phase == .dualActive,
                  let dayEnd = state.canonicalDayEnd(
                    usageDate: candidateRoute.usageDate,
                    timeZoneIdentifier: candidateEpoch.canonicalTimezone
                  )
            else { return }

            let candidateRegistrations = state.registrationWork.values.filter {
                $0.epochID == handoff.toEpochID
                    && $0.routeID == handoff.toRouteID
            }
            let registrationTerminated = candidateRegistrations.contains {
                $0.retry.terminal != .pending
                    && $0.retry.terminal != .succeeded
            }
            let registrationStillUsable = candidateRegistrations.contains {
                $0.retry.terminal == .pending || $0.retry.terminal == .succeeded
            }
            let candidateActivations = state.activationWork.values.filter {
                $0.epochID == handoff.toEpochID
                    && $0.routeID == handoff.toRouteID
            }
            let activationTerminated = candidateActivations.contains {
                $0.retry.terminal != .pending
                    && $0.retry.terminal != .succeeded
            }
            let activationStillUsable = candidateActivations.contains {
                $0.retry.terminal == .pending || $0.retry.terminal == .succeeded
            }
            let activationSucceeded = candidateActivations.contains {
                $0.epochID == handoff.toEpochID
                    && $0.routeID == handoff.toRouteID
                    && $0.retry.terminal == .succeeded
            }
            let hasNewerCandidate = state.routes.values.contains {
                $0.ownerChildDeviceID == owner
                    && $0.routeID != handoff.toRouteID
                    && $0.routeID != handoff.fromRouteID
                    && $0.usageDate == candidateRoute.usageDate
                    && $0.generationID != handoff.fromGenerationID
                    && $0.generationID != handoff.toGenerationID
                    && $0.lifecycle == .planned
                    && state.epochs[$0.epochID]?.status == .active
            }
            let hasPreparedNextDayRollover: Bool = {
                guard let rollover = state.rolloverEffectsWork,
                      rollover.ownerChildDeviceID == owner,
                      rollover.retry.terminal == .pending,
                      rollover.oldEpochID == handoff.fromEpochID,
                      rollover.oldRouteID == handoff.fromRouteID,
                      candidateRoute.usageDate < rollover.toUsageDate,
                      let nextRoute = state.routes[rollover.newRouteID],
                      nextRoute.epochID == rollover.newEpochID,
                      nextRoute.usageDate == rollover.toUsageDate,
                      nextRoute.lifecycle == .planned || nextRoute.lifecycle == .active
                else { return false }
                return true
            }()
            let registrationFailed = registrationTerminated && !registrationStillUsable
            let activationFailedAfterRegistration = candidateRegistrations.contains {
                $0.retry.terminal == .succeeded
            } && activationTerminated && !activationStillUsable
            // A terminal registration proves the backend never accepted this candidate, so the
            // prior route is safe to resume. After registration, only a successor may take over.
            guard registrationFailed || activationFailedAfterRegistration,
                  !activationSucceeded,
                  registrationFailed || hasNewerCandidate || hasPreparedNextDayRollover
            else { return }

            for (key, var sample) in state.sampleWork
            where sample.routeID == candidateRoute.routeID
                && sample.retry.terminal == .pending {
                sample.claim = nil
                sample.retry.terminal = .superseded
                sample.retry.lastErrorCode = "cross_day_candidate_superseded"
                state.sampleWork[key] = sample
            }
            state.deferredCallbacks = state.deferredCallbacks.filter {
                $0.value.routeID != candidateRoute.routeID
            }

            candidateEpoch.status = .retired
            candidateEpoch.retiredAt = clock.now
            candidateEpoch.retireReason = .activationSuperseded
            state.epochs[candidateEpoch.epochID] = candidateEpoch
            candidateRoute.lifecycle = .tombstoned
            state.routes[candidateRoute.routeID] = candidateRoute
            state.tombstones[candidateRoute.routeID] = MeteringRouteTombstone(
                routeID: candidateRoute.routeID,
                activityName: candidateRoute.activityName,
                eventNames: candidateRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: candidateRoute.usageDate,
                epochID: candidateEpoch.epochID,
                generationID: candidateRoute.generationID,
                canonicalDayEnd: dayEnd,
                stopAcknowledgedAt: nil,
                referencedWorkIDs: Set(state.sampleWork.values.filter {
                    $0.routeID == candidateRoute.routeID
                }.map(\.workID)),
                retainedUntil: nil
            )
            state.installWork[candidateInstallKey]?.phase = .pendingStop
            state.v2RouteHandoff = nil
        }
    }

    private func stopAbandonedCandidates(owner: UUID) throws {
        let state = try store.read()
        let candidates = state.routes.values.compactMap { route -> (MeteringCallbackRoute, UUID)? in
            guard route.ownerChildDeviceID == owner,
                  route.routeID != state.activeRouteID,
                  route.routeID != state.v2RouteHandoff?.fromRouteID,
                  route.lifecycle == .tombstoned,
                  state.epochs[route.epochID]?.status == .retired,
                  state.epochs[route.epochID]?.retireReason != nil,
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
                      route.routeID != state.activeRouteID,
                      route.routeID != state.v2RouteHandoff?.fromRouteID,
                      state.epochs[route.epochID]?.status == .retired,
                      state.epochs[route.epochID]?.retireReason != nil,
                      state.tombstones[route.routeID]?.stopAcknowledgedAt == nil,
                      uniqueInstallKey(for: route.routeID, in: state) == installKey,
                      state.installWork[installKey]?.phase == .pendingStop
                else { return }
                state.installWork[installKey]?.phase = .stopped
                state.tombstones[route.routeID]?.stopAcknowledgedAt = acknowledgedAt
                state.tombstones[route.routeID]?.retainedUntil = acknowledgedAt.addingTimeInterval(24 * 3_600)
            }
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
        if let sameDay = candidateRoutes(in: state, owner: owner).first(where: {
            $0.routeID != routeID
                && $0.createdAt >= activeRoute.createdAt
                && ($0.generationID != state.activeGenerationID
                    || state.epochs[$0.epochID]?.resumeBoundaryPending == true)
                && $0.usageDate == activeRoute.usageDate
        }) {
            return sameDay
        }
        return staleDayCandidateRoute(in: state, owner: owner, activeRoute: activeRoute)
    }

    /// The escape hatch for a device left stranded on a past day.
    ///
    /// Ordinary replacement only ever swaps routes WITHIN the active day, and
    /// canonical rollover only ever advances WITHIN one generation. When the
    /// active day is over and the active generation's policy revision is dead,
    /// neither can move — the device meters nothing until it is reinstalled
    /// (iPhone, 2026-07-25). This branch, reached only after the same-day search
    /// finds nothing, lets the replacement machinery cross both boundaries at
    /// once and adopt canonical today on the revision the backend actually
    /// accepts.
    ///
    /// The desired revision is the whole gate, and deliberately so: a wedged
    /// device also accumulates several never-retired generations on dead
    /// revisions, each carrying a full week of planned routes, and some were
    /// created AFTER the live one — so "newest planned route wins" adopts a
    /// generation the backend will 409. `desiredPolicy` is the only local
    /// authority on what the backend is currently on.
    private func staleDayCandidateRoute(
        in state: DeviceEpochStoreState,
        owner: UUID,
        activeRoute: MeteringCallbackRoute
    ) -> MeteringCallbackRoute? {
        guard let desired = state.desiredPolicy,
              desired.ownerChildDeviceID == owner,
              !desired.policyRevision.isEmpty,
              let activeGeneration = state.generations[activeRoute.generationID],
              activeGeneration.policyRevision != desired.policyRevision,
              let today = MeteringEpochContract.canonicalUsageDate(
                  at: clock.now,
                  timezoneIdentifier: activeGeneration.canonicalTimezone
              ),
              activeRoute.usageDate < today
        else { return nil }
        return candidateRoutes(in: state, owner: owner).first {
            $0.routeID != activeRoute.routeID
                && $0.createdAt >= activeRoute.createdAt
                && $0.generationID != activeRoute.generationID
                && $0.usageDate == today
                && state.generations[$0.generationID]?.policyRevision == desired.policyRevision
        }
    }

    private func candidateRoutes(in state: DeviceEpochStoreState, owner: UUID) -> [MeteringCallbackRoute] {
        state.routes.values.filter {
            $0.ownerChildDeviceID == owner
                && $0.lifecycle == .planned
                && state.epochs[$0.epochID]?.status == .active
                && state.generations[$0.generationID]?.retiredAt == nil
                && isAdoptableGeneration($0.generationID, in: state)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.routeID.uuidString.lowercased() < $1.routeID.uuidString.lowercased()
        }
    }

    /// Generations the device is allowed to cut over to.
    ///
    /// A wedged device accumulates generations that were never retired because
    /// the cutover that would have retired them never completed — the iPhone
    /// black box from 2026-07-25 held three, each with a full week of planned
    /// routes, and some created AFTER the live one. `candidateRoutes` ranks by
    /// `createdAt`, so without this filter the replacement path repeatedly
    /// adopts a dead-revision generation, gets `409 policy_revision_mismatch`,
    /// abandons it and adopts the next one: pure churn that also stops and
    /// restarts Apple's monitors.
    ///
    /// Only two generations are ever legitimate: the ACTIVE one (that is how a
    /// conservative gate resume replaces a route inside its own generation) and
    /// one carrying the revision `desiredPolicy` says the backend is on. With no
    /// desired policy on record there is nothing better to go on, so every
    /// generation stays adoptable exactly as before.
    private func isAdoptableGeneration(_ generationID: UUID, in state: DeviceEpochStoreState) -> Bool {
        guard let desired = state.desiredPolicy,
              !desired.policyRevision.isEmpty,
              desired.ownerChildDeviceID == state.ownerChildDeviceID
        else { return true }
        if generationID == state.activeGenerationID { return true }
        return state.generations[generationID]?.policyRevision == desired.policyRevision
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

    /// #85 (P1-3): is the ladder repair churning? A healthy device produces
    /// at most a corpse or two per day; the observed storm produced one every
    /// ~20 seconds. Five tombstoned routes born within the last twenty
    /// minutes can only mean a repair loop that is re-minting what something
    /// else keeps killing — stop feeding it.
    nonisolated static func isLadderRepairStorming(
        state: DeviceEpochStoreState,
        now: Date
    ) -> Bool {
        // Count distinct MINT MOMENTS, not tombstones. A storm is repeated
        // mint→kill→mint cycles, and each cycle mints at its own instant. A
        // horizon, by contrast, is minted as one batch and retired as one
        // batch, so an ordinary policy change (a parent lowering the device
        // limit) instantly produced eight same-second tombstones and tripped
        // this breaker — which then has no way out: it parks the repair, the
        // ladder stays wrong, and every retry re-reads the same eight corpses
        // until they age out. The pool simply stopped (2026-08-08 00:05, real
        // device: `repair_storm_parked` every 12 seconds).
        let recentMintInstants = Set(
            state.routes.values
                .filter {
                    $0.lifecycle == .tombstoned
                        && now.timeIntervalSince($0.createdAt) < 20 * 60
                }
                // Second granularity: siblings of one batch share an instant.
                .map { Int($0.createdAt.timeIntervalSince1970) }
        )
        return recentMintInstants.count >= 5
    }

    private func hasNonterminalPriorRouteWork(_ routeID: UUID, in state: DeviceEpochStoreState) -> Bool {
        state.sampleWork.values.contains { $0.routeID == routeID && $0.retry.terminal == .pending }
    }

    /// #84 (P1-1): a sample queued moments before the gate closed is stranded
    /// once its epoch pauses — the dispatcher only claims samples on active
    /// epochs, so the delivery-settle terminalizer, which needs a backend
    /// response to run, never fires. The pending work then wedges every
    /// `hasNonterminalPriorRouteWork` barrier (same-day gate-resume
    /// replacement AND the midnight rollover) until the day ends. Settle such
    /// samples with the fate an attempted delivery would have received: the
    /// backend refuses samples on a paused epoch, and the usage they carry is
    /// already excluded at credit time via `excludedWhilePausedMinutes`.
    /// The live handoff's to-side epoch is exempt — a cutover-ready candidate
    /// can be revived paused→active and its samples must stay pending.
    private func settlePausedRouteSamples(owner: UUID) throws {
        var settled: [(workID: UUID, corrID: UUID)] = []
        try store.transaction(expectedOwner: owner) { state in
            for (key, var work) in state.sampleWork {
                guard work.ownerChildDeviceID == owner,
                      work.retry.terminal == .pending,
                      let epochID = work.epochID,
                      let epoch = state.epochs[epochID],
                      epoch.childDeviceID == owner,
                      epoch.status == .paused,
                      state.v2RouteHandoff?.toEpochID != epochID
                else { continue }
                work.claim = nil
                work.retry.terminal = .rejected
                work.retry.lastErrorCode = "accounting_paused"
                work.retry.nextAttemptAt = clock.now
                state.sampleWork[key] = work
                settled.append((work.workID, work.routeID ?? epochID))
            }
        }
        for item in settled {
            MeteringFlightRecorder.emit(
                kind: .meteringSample,
                site: "recovery.pausedSampleSettle",
                verdict: "settled_rejected",
                detail: MeteringFlightRecorder.detail([
                    ("work", MeteringFlightRecorder.shortID(item.workID)),
                    ("code", "accounting_paused"),
                ]),
                corrID: item.corrID
            )
        }
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

    private func isPhysicalIdentityRecoveryRejection(
        _ work: EpochRegistrationWork,
        owner: UUID,
        epoch: DeviceDailyEpoch,
        route: MeteringCallbackRoute
    ) -> Bool {
        let request = work.request
        return work.ownerChildDeviceID == owner
            && work.epochID == epoch.epochID
            && work.routeID == route.routeID
            && work.claim == nil
            && work.retry.terminal == .rejected
            && work.retry.lastErrorCode
                == "physical_identity_recovery_required"
            && request.protocolVersion == 2
            && request.epochID == epoch.epochID
            && request.deviceID == owner
            && request.usageDate == epoch.usageDate
            && request.timezone == epoch.canonicalTimezone
            && request.policyRevision == epoch.policyRevision
            && request.measurementSelectionDigest
                == epoch.measurementSelectionDigest
            && request.enforcementSetID == epoch.enforcementSetID
            && request.startedAt == epoch.startedAt
            && request.baseAcceptedMinutes == epoch.baseAcceptedMinutes
    }

    private func registrationRequest(
        epoch: DeviceDailyEpoch,
        reason: EpochRegistrationReasonDTO = .initial,
        startedAt: Date? = nil
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
            startedAt: startedAt ?? epoch.startedAt,
            baseAcceptedMinutes: epoch.baseAcceptedMinutes,
            reason: reason
        )
    }

    private func epochKey(_ epoch: DeviceDailyEpoch) -> MeteringEpochKey {
        MeteringEpochKey(
            protocolVersion: epoch.protocolVersion,
            childDeviceID: epoch.childDeviceID,
            usageDate: epoch.usageDate,
            canonicalTimezone: epoch.canonicalTimezone,
            policyRevision: epoch.policyRevision,
            measurementSelectionDigest: epoch.measurementSelectionDigest,
            enforcementSetID: epoch.enforcementSetID
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
                + [LegacyMeteringActivity.legacyActivityName]
        )).sorted()
    }
}
