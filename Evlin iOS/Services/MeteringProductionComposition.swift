import FamilyControls
import Foundation

nonisolated struct MeteringRolloverEffectResetter: Sendable {
    enum ResetError: Error {
        case invalidDateTransition
        case earnedSourceResetFailed
    }

    let earnedStore: EarnedTimeStore

    init(earnedStore: EarnedTimeStore = .shared) {
        self.earnedStore = earnedStore
    }

    func apply(
        _ effect: MeteringRolloverLocalEffect,
        work: RolloverEffectsWork
    ) throws {
        guard EarnedTimeStore.isCanonicalUsageDate(work.fromUsageDate),
              EarnedTimeStore.isCanonicalUsageDate(work.toUsageDate),
              work.fromUsageDate < work.toUsageDate
        else { throw ResetError.invalidDateTransition }

        switch effect {
        case .earnedSource:
            guard case .reconciled(0) = earnedStore.reconcileAcceptedUsageIfNotStale(
                usageDate: work.toUsageDate,
                serverEstimatedMinutes: 0,
                expectedDeviceID: work.ownerChildDeviceID
            ) else {
                throw ResetError.earnedSourceResetFailed
            }
        case .perApp, .taskState, .bypassExpiry:
            // These authorities are already usage-date scoped. Verifying the
            // exact canonical transition is their reset; mutating global
            // DeviceActivity or lock state here would destroy unrelated work.
            break
        }
    }
}

nonisolated struct MeteringRecoverablePolicyInputs: Sendable {
    let selectionBytes: Data
    let enforcementSetID: UUID
}

enum MeteringRecoveryOutcome: Equatable {
    case attempted
    case skippedMissingConfiguration
    case skippedConfigurationMismatch
}

nonisolated enum MeteringProductionComposition {
    static let appGroupSuiteName = "group.com.evlin.ios"
    static let baseURLKey = "evlin.baseURL"

    /// The App Group backend URL, rejected in a production build when it names
    /// a development host.
    ///
    /// There are TWO stored backend addresses. `APIClient` already drops a dev
    /// URL from `UserDefaults.standard` on every Release launch — but the
    /// metering stack, the DeviceActivity monitor and the push extension read
    /// this SECOND copy out of the App Group, and nothing ever sanitised it.
    /// The App Group container survives replacing the app, so a LAN address
    /// written by a debug build stayed behind after a TestFlight install: the
    /// main app healed itself while the extensions kept talking to a Mac that
    /// was not on the user's network (2026-08-08 — only an uninstall cleared
    /// it). Worse than merely being unreachable, a real user's metering
    /// samples would be posted to whatever answers on that private address.
    ///
    /// Rejecting is safe: the app rewrites this key from its own sanitised
    /// base URL on the next configuration pass, so the extensions resume as
    /// soon as a legitimate address is stored.
    nonisolated static func sanitizedBaseURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased()
        else { return nil }
        #if DEBUG
        return url
        #else
        if scheme != "https" { return nil }
        if host == "localhost" || host.hasSuffix(".local") { return nil }
        if host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return nil
        }
        // 172.16.0.0/12
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return nil
            }
        }
        return url
        #endif
    }
    static let ownerKey = "evlin.childId"
    static let selectionKey = "earned.measurementSelection"
    static let lockedSetIDKey = "earned.lockedSetID"

    private static let appInstanceID = UUID()
    private static let monitorInstanceID = UUID()
    private static let pushInstanceID = UUID()

    static func makeRecoveryDriver(
        baseURL: URL,
        role: MeteringProcessRole,
        instanceID: UUID,
        store: DeviceEpochStore = .shared,
        center injectedCenter: (any MeteringDeviceActivityCenter)? = nil,
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    ) -> EarnedMeteringRecoveryDriver {
        let center = injectedCenter ?? SystemMeteringDeviceActivityCenter()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: clock
        )
        let identity = MeteringProcessIdentity(role: role, instanceID: instanceID)
        let installer = DatedRouteInstaller(
            store: store,
            center: center,
            processIdentity: identity,
            clock: clock
        )
        let rolloverResetter = MeteringRolloverEffectResetter()
        return EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: installer,
            center: center,
            processIdentity: identity,
            clock: clock,
            resetRolloverEffect: { effect, work in
                try rolloverResetter.apply(effect, work: work)
            }
        )
    }

    static func makeCallback(
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        journal: EarnedV2CallbackJournal = EarnedV2CallbackJournal()
    ) -> EarnedMeteringCallback {
        EarnedMeteringCallback(store: store, clock: clock, journal: journal)
    }

    @MainActor
    @discardableResult
    static func recoverFromSharedConfiguration(
        role: MeteringProcessRole,
        runtime: EarnedTimeRuntime? = nil,
        usageCountingAllowed: Bool? = nil,
        expectedOwner: UUID? = nil,
        expectedBaseURL: URL? = nil,
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        transport: any MeteringHTTPTransport = URLSession.shared,
        executionBudget: MeteringRecoveryExecutionBudget? = nil
    ) async throws -> MeteringRecoveryOutcome {
        // The recovery driver already detaches its daemon/XPC work, but this
        // composition performs several full DeviceEpochStore reads before and
        // after entering the driver. Those reads synchronously load, decode and
        // validate the persisted root. A background push still enters here on
        // MainActor, so a large mature root can otherwise freeze the host app
        // before the driver's existing off-main boundary is reached.
        let effectiveExecutionBudget = executionBudget
            ?? MeteringRecoveryExecutionContext.budget
            ?? MeteringRecoveryExecutionBudget()
        return try await Task.detached(priority: .utility) {
            try await MeteringRecoveryExecutionContext.$budget.withValue(effectiveExecutionBudget) {
                try await performRecoveryFromSharedConfiguration(
                    role: role,
                    runtime: runtime,
                    usageCountingAllowed: usageCountingAllowed,
                    expectedOwner: expectedOwner,
                    expectedBaseURL: expectedBaseURL,
                    store: store,
                    clock: clock,
                    transport: transport
                )
            }
        }.value
    }

    private static func performRecoveryFromSharedConfiguration(
        role: MeteringProcessRole,
        runtime: EarnedTimeRuntime?,
        usageCountingAllowed: Bool?,
        expectedOwner: UUID?,
        expectedBaseURL: URL?,
        store: DeviceEpochStore,
        clock: any MeteringClock,
        transport: any MeteringHTTPTransport
    ) async throws -> MeteringRecoveryOutcome {
        guard let configuration = sharedConfiguration() else {
            return .skippedMissingConfiguration
        }
        if let expectedOwner, configuration.owner != expectedOwner {
            return .skippedConfigurationMismatch
        }
        if let expectedBaseURL {
            let slashes = CharacterSet(charactersIn: "/")
            let configured = configuration.baseURL.absoluteString
                .trimmingCharacters(in: slashes)
            let expected = expectedBaseURL.absoluteString
                .trimmingCharacters(in: slashes)
            guard configured == expected else {
                return .skippedConfigurationMismatch
            }
        }
        let driver = makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: role,
            instanceID: instanceID(for: role),
            store: store,
            transport: transport,
            clock: clock
        )

        // Identity cleanup replaces the entire persisted epoch root. Finish it
        // before planning the current policy, otherwise this pass writes the
        // new route into the old root and cleanup immediately erases it. This
        // is especially important when re-pairing reuses the same device UUID.
        if try store.read().identityCleanupWork != nil {
            try await driver.recover(ownerChildDeviceID: configuration.owner)
            let postCleanup = try store.read()
            guard postCleanup.identityCleanupWork == nil else {
                return .attempted
            }
            guard postCleanup.ownerChildDeviceID == configuration.owner else {
                return .skippedConfigurationMismatch
            }
        }

        try planDesiredPolicyIfPresent(
            owner: configuration.owner,
            store: store,
            defaults: configuration.defaults,
            now: clock.now
        )

        if let runtime, let usageCountingAllowed {
            try planAuthoritativeRuntime(
                runtime,
                owner: configuration.owner,
                store: store,
                defaults: configuration.defaults,
                now: clock.now
            )
            try driver.reconcileUsageGate(
                ownerChildDeviceID: configuration.owner,
                allowed: usageCountingAllowed,
                runtime: runtime
            )
        }
        // Belt and braces: whatever the caller passed, if the gate is open and
        // the active epoch is still paused, reconcile again from stored state.
        // The reconcile is idempotent, and this is the only thing standing
        // between "a precondition returned early" and a pool that never moves
        // again for the rest of the day.
        if let storedRuntime = storedRuntimeSnapshot(now: clock.now),
           EarnedTimeStore.shared.usageCountingAllowed,
           activeEpochIsPaused(owner: configuration.owner, store: store) {
            // Only the kid-side foreground poller supplies these two arguments,
            // so every OTHER entry point — background silent wake, NSE
            // self-heal, launch recovery — skipped the gate entirely and left a
            // paused epoch paused forever. An epoch is born paused whenever a
            // reflection or task is open at registration time (every fresh
            // onboarding does exactly that), so the pool stayed frozen until
            // someone happened to open Evlin on the kid's device (2026-08-07,
            // reproduced on a freshly paired iPhone).
            //
            // The gate's live value and the runtime policy are both already
            // mirrored into the shared store by that same poller, so any
            // process can read them instead of demanding they be passed in.
            try driver.reconcileUsageGate(
                ownerChildDeviceID: configuration.owner,
                allowed: EarnedTimeStore.shared.usageCountingAllowed,
                runtime: storedRuntime
            )
        }
        try await driver.recover(ownerChildDeviceID: configuration.owner)
        if role == .app || role == .pushApplier {
            try await finalizeDesiredPolicyIfApplied(
                owner: configuration.owner,
                baseURL: configuration.baseURL,
                store: store,
                transport: transport,
                now: clock.now
            )
        }
        return .attempted
    }

    /// True when the owner's currently active epoch is paused — the exact
    /// state a missed resume leaves behind.
    private static func activeEpochIsPaused(owner: UUID, store: DeviceEpochStore) -> Bool {
        guard let state = try? store.read(),
              state.ownerChildDeviceID == owner,
              let routeID = state.activeRouteID,
              let route = state.routes[routeID],
              let epoch = state.epochs[route.epochID]
        else { return false }
        return epoch.status == .paused
    }

    /// Rebuild the runtime policy from the values the poller mirrors into the
    /// shared store, so gate reconciliation no longer requires a live snapshot
    /// handed in by a foreground caller. Returns nil before the first sync,
    /// when there is genuinely nothing to reconcile against.
    private static func storedRuntimeSnapshot(
        now: Date,
        epochStore: DeviceEpochStore = .shared
    ) -> EarnedTimeRuntime? {
        // Prefer the desired policy the NSE itself persists. The
        // `EarnedTimeStore` mirror below is written ONLY by the kid app's
        // foreground poller, so on a device that was force-quit right after
        // pairing it is still empty — and the paused-epoch rescue that depends
        // on it silently did nothing, which is exactly the case this rescue
        // exists for (2026-08-07).
        if let desired = (try? epochStore.read())?.desiredPolicy {
            return EarnedTimeRuntime(
                usageDate: desired.usageDate,
                timezone: desired.canonicalTimezone,
                policyRevision: desired.policyRevision,
                dailyPoolMinutes: desired.dailyPoolMinutes,
                deviceCapMinutes: desired.deviceCapMinutes,
                remainingMinutes: desired.remainingMinutes
                    ?? min(desired.dailyPoolMinutes, desired.deviceCapMinutes),
                estimatedMinutes: EarnedTimeStore.shared.latestDeviceEstimate ?? 0
            )
        }
        let store = EarnedTimeStore.shared
        guard let usageDate = store.currentCanonicalPolicyUsageDate(now: now),
              let timezone = store.runtimeTimezoneIdentifier,
              let policyRevision = store.runtimePolicyRevision,
              let pool = store.poolMinutes,
              let cap = store.capMinutes
        else { return nil }
        let estimate = store.latestDeviceEstimate ?? 0
        return EarnedTimeRuntime(
            usageDate: usageDate,
            timezone: timezone,
            policyRevision: policyRevision,
            dailyPoolMinutes: pool,
            deviceCapMinutes: cap,
            remainingMinutes: store.backendRemainingAtLastSync ?? max(0, min(pool, cap) - estimate),
            estimatedMinutes: estimate
        )
    }

    private static func planDesiredPolicyIfPresent(
        owner: UUID,
        store: DeviceEpochStore,
        defaults: UserDefaults,
        now: Date
    ) throws {
        let state = try store.read()
#if DEBUG
        let debugSelectionBytes = defaults.data(forKey: selectionKey)
        let debugSelection = debugSelectionBytes.flatMap {
            try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0)
        }
        print(
            "[MeteringPolicyDebug] owner=\(owner.uuidString) "
                + "storeOwner=\(state.ownerChildDeviceID?.uuidString ?? "nil") "
                + "desired=\(state.desiredPolicy != nil) "
                + "desiredAcked=\(state.desiredPolicy?.ackedAt != nil) "
                + "selectionBytes=\(debugSelectionBytes?.count ?? 0) "
                + "selectionDecoded=\(debugSelection != nil) "
                + "apps=\(debugSelection?.applicationTokens.count ?? 0) "
                + "categories=\(debugSelection?.categoryTokens.count ?? 0) "
                + "web=\(debugSelection?.webDomainTokens.count ?? 0) "
                + "lockedSet=\(defaults.string(forKey: lockedSetIDKey) ?? "nil")"
        )
#endif
        guard let desired = state.desiredPolicy,
              desired.ownerChildDeviceID == owner
        else { return }
        guard let canonicalToday = canonicalUsageDate(
            at: now,
            timezoneIdentifier: desired.canonicalTimezone
        ), desired.usageDate == canonicalToday else {
            MeteringFlightRecorder.emitFailure(
                site: "composition.desiredPolicy",
                verdict: "stale_desired_policy_ignored",
                detail: MeteringFlightRecorder.detail([
                    ("desired", desired.usageDate),
                    ("today", canonicalUsageDate(
                        at: now,
                        timezoneIdentifier: desired.canonicalTimezone
                    ) ?? "invalid_timezone"),
                    ("timezone", desired.canonicalTimezone),
                ])
            )
            return
        }
        guard repairPersistedPolicyInputsIfPossible(
            owner: owner,
            state: state,
            defaults: defaults
        ) else { return }
        guard desired.ackedAt == nil,
              let inputs = recoverablePolicyInputs(
                  owner: owner,
                  desired: desired,
                  state: state,
                  defaults: defaults
              )
        else { return }
        let selectionBytes = inputs.selectionBytes
        let enforcementSetID = inputs.enforcementSetID

        let accepted: Int
        if let epochID = state.activeEpochID,
           let epoch = state.epochs[epochID],
           epoch.childDeviceID == owner,
           epoch.usageDate == desired.usageDate {
            accepted = max(
                0,
                epoch.baseAcceptedMinutes
                    + epoch.lastRawThresholdMinutes
                    - epoch.excludedWhilePausedMinutes
            )
        } else {
            accepted = 0
        }
        let boundedAccepted = min(
            accepted,
            max(0, min(desired.dailyPoolMinutes, desired.deviceCapMinutes) - 1)
        )
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: desired.canonicalTimezone,
            policyRevision: desired.policyRevision,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: enforcementSetID
        )
        do {
            _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: desired.usageDate,
                generationKey: generationKey,
                persistedSelectionBytes: selectionBytes,
                poolMinutes: desired.dailyPoolMinutes,
                deviceCapMinutes: desired.deviceCapMinutes,
                authoritativeBaseAcceptedMinutes: boundedAccepted,
                now: now
            ))
        } catch {
#if DEBUG
            print("[MeteringPolicyDebug] reconcile failed: \(error)")
#endif
            // Horizon planning is what creates tomorrow's routes. A failure
            // here is why "the device never armed the next day" — the print
            // above is DEBUG-only, so on TestFlight it left nothing at all.
            MeteringFlightRecorder.emitError(
                site: "composition.horizon",
                error: error,
                detail: MeteringFlightRecorder.detail([
                    ("date", desired.usageDate),
                    ("rev", desired.policyRevision),
                ])
            )
            throw error
        }
    }

    static func canonicalUsageDate(
        at date: Date,
        timezoneIdentifier: String
    ) -> String? {
        guard let timezone = TimeZone(identifier: timezoneIdentifier) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timezone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    @discardableResult
    static func repairPersistedPolicyInputsIfPossible(
        owner: UUID,
        state: DeviceEpochStoreState,
        defaults: UserDefaults,
        selectionIsValid: (Data) -> Bool = hasValidSelection
    ) -> Bool {
        guard let desired = state.desiredPolicy,
              desired.ownerChildDeviceID == owner
        else { return false }
        return recoverablePolicyInputs(
            owner: owner,
            desired: desired,
            state: state,
            defaults: defaults,
            selectionIsValid: selectionIsValid
        ) != nil
    }

    static func recoverablePolicyInputs(
        owner: UUID,
        desired: MeteringDesiredPolicy,
        state: DeviceEpochStoreState,
        defaults: UserDefaults,
        selectionIsValid: (Data) -> Bool = hasValidSelection
    ) -> MeteringRecoverablePolicyInputs? {
        guard desired.ownerChildDeviceID == owner else { return nil }

        let persistedSelection = defaults.data(forKey: selectionKey)
            .flatMap { selectionIsValid($0) ? $0 : nil }
        let persistedEnforcement = defaults.string(forKey: lockedSetIDKey)
            .flatMap(UUID.init(uuidString:))
        if let selectionBytes = persistedSelection,
           let enforcementSetID = desired.enforcementSetID ?? persistedEnforcement {
            if persistedEnforcement == nil {
                defaults.set(enforcementSetID.uuidString, forKey: lockedSetIDKey)
                defaults.synchronize()
            }
            return MeteringRecoverablePolicyInputs(
                selectionBytes: selectionBytes,
                enforcementSetID: enforcementSetID
            )
        }

        guard state.ownerChildDeviceID == owner,
              let generationID = state.activeGenerationID,
              let generation = state.generations[generationID],
              generation.childDeviceID == owner,
              generation.retiredAt == nil,
              selectionIsValid(generation.measurementSelectionBytes)
        else { return nil }
        let selectionBytes = generation.measurementSelectionBytes
        let enforcementSetID = desired.enforcementSetID ?? generation.enforcementSetID
        defaults.set(selectionBytes, forKey: selectionKey)
        defaults.set(enforcementSetID.uuidString, forKey: lockedSetIDKey)
        defaults.synchronize()
        return MeteringRecoverablePolicyInputs(
            selectionBytes: selectionBytes,
            enforcementSetID: enforcementSetID
        )
    }

    private static func hasValidSelection(_ bytes: Data) -> Bool {
        guard let selection = try? JSONDecoder().decode(
            FamilyActivitySelection.self,
            from: bytes
        ),
        !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
        else { return false }
        return true
    }

    static func desiredPolicyMatchesActiveReadback(
        _ desired: MeteringDesiredPolicy,
        state: DeviceEpochStoreState
    ) -> Bool {
        guard state.ownerChildDeviceID == desired.ownerChildDeviceID,
              let generationID = state.activeGenerationID,
              let generation = state.generations[generationID],
              generation.childDeviceID == desired.ownerChildDeviceID,
              generation.policyRevision == desired.policyRevision,
              generation.canonicalTimezone == desired.canonicalTimezone,
              generation.configuredPoolMinutes == desired.dailyPoolMinutes,
              generation.configuredDeviceCapMinutes == desired.deviceCapMinutes,
              desired.enforcementSetID == nil || generation.enforcementSetID == desired.enforcementSetID,
              let epochID = state.activeEpochID,
              let epoch = state.epochs[epochID],
              epoch.childDeviceID == desired.ownerChildDeviceID,
              epoch.usageDate == desired.usageDate,
              epoch.policyRevision == desired.policyRevision,
              epoch.status == .active,
              let routeID = state.activeRouteID,
              let route = state.routes[routeID],
              route.ownerChildDeviceID == desired.ownerChildDeviceID,
              route.generationID == generationID,
              route.epochID == epochID,
              route.lifecycle == .active,
              route.installedSchedule == route.plannedSchedule,
              route.installedEvents == route.plannedEvents,
              let coverage = state.coverage,
              coverage.ownerChildDeviceID == desired.ownerChildDeviceID,
              coverage.status != .coverageExhausted,
              (coverage.readyThroughUsageDate ?? "") >= desired.usageDate
        else { return false }

        let expected = MeteringDatedSchedule.remainingPolicy(
            poolMinutes: desired.dailyPoolMinutes,
            capMinutes: desired.deviceCapMinutes,
            offsetMinutes: epoch.baseAcceptedMinutes
        ).map {
            Set(MeteringDatedSchedule.thresholds(
                poolMinutes: $0.poolMinutes,
                capMinutes: $0.capMinutes
            ))
        } ?? []
        return Set(route.plannedEvents.map(\.thresholdMinutes)) == expected
    }

    static func finalizeDesiredPolicyIfApplied(
        owner: UUID,
        baseURL: URL,
        store: DeviceEpochStore,
        transport: any MeteringHTTPTransport,
        now: Date
    ) async throws {
        var state = try store.read()
        guard var desired = state.desiredPolicy,
              desired.ownerChildDeviceID == owner,
              desired.ackedAt == nil,
              desiredPolicyMatchesActiveReadback(desired, state: state)
        else { return }

        if desired.appliedAt == nil {
            try store.markDesiredPolicyApplied(
                commandID: desired.commandID,
                orderingToken: desired.orderingToken,
                policyRevision: desired.policyRevision,
                appliedAt: now
            )
            state = try store.read()
            guard let refreshed = state.desiredPolicy else { return }
            desired = refreshed
        }
        try await MeteringPolicyOwnerReadbackClient(
            baseURL: baseURL,
            transport: transport
        ).confirm(desired)
        try store.markDesiredPolicyAcknowledged(
            commandID: desired.commandID,
            orderingToken: desired.orderingToken,
            policyRevision: desired.policyRevision,
            ackedAt: now
        )
    }

    private static func planAuthoritativeRuntime(
        _ runtime: EarnedTimeRuntime,
        owner: UUID,
        store: DeviceEpochStore,
        defaults: UserDefaults,
        now: Date
    ) throws {
        guard runtime.dailyPoolMinutes > 0,
              runtime.deviceCapMinutes > 0,
              !runtime.usageDate.isEmpty,
              !runtime.timezone.isEmpty,
              !runtime.policyRevision.isEmpty,
              let selectionBytes = defaults.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(
                  FamilyActivitySelection.self,
                  from: selectionBytes
              ),
              !selection.applicationTokens.isEmpty
                || !selection.categoryTokens.isEmpty
                || !selection.webDomainTokens.isEmpty,
              let lockedSetRaw = defaults.string(forKey: lockedSetIDKey),
              let enforcementSetID = UUID(uuidString: lockedSetRaw)
        else { return }

        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: runtime.timezone,
            policyRevision: runtime.policyRevision,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: enforcementSetID
        )
        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: runtime.usageDate,
            generationKey: generationKey,
            persistedSelectionBytes: selectionBytes,
            poolMinutes: runtime.dailyPoolMinutes,
            deviceCapMinutes: runtime.deviceCapMinutes,
            authoritativeBaseAcceptedMinutes: runtime.estimatedMinutes,
            now: now
        ))
    }

    private static func sharedConfiguration() -> (
        defaults: UserDefaults,
        baseURL: URL,
        owner: UUID
    )? {
        guard let defaults = UserDefaults(suiteName: appGroupSuiteName),
              let baseRaw = defaults.string(forKey: baseURLKey),
              let baseURL = sanitizedBaseURL(baseRaw),
              let ownerRaw = defaults.string(forKey: ownerKey),
              let owner = UUID(uuidString: ownerRaw)
        else { return nil }
        return (defaults, baseURL, owner)
    }

    static func instanceID(for role: MeteringProcessRole) -> UUID {
        switch role {
        case .app: appInstanceID
        case .deviceActivityMonitor: monitorInstanceID
        case .pushApplier: pushInstanceID
        }
    }

#if DEBUG
    @MainActor
    static func makeRecoveryDriverForTesting(
        baseURL: URL,
        role: MeteringProcessRole,
        instanceID: UUID,
        store: DeviceEpochStore,
        center: any MeteringDeviceActivityCenter,
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        legacySuiteName: String = "metering-production-link-\(UUID().uuidString)",
        releaseIdentityShield: @escaping (UUID, UUID) throws -> Void
    ) -> EarnedMeteringRecoveryDriver {
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: clock,
            legacySuiteName: legacySuiteName
        )
        let identity = MeteringProcessIdentity(role: role, instanceID: instanceID)
        let installer = DatedRouteInstaller(
            store: store,
            center: center,
            processIdentity: identity,
            clock: clock
        )
        return EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: installer,
            center: center,
            processIdentity: identity,
            clock: clock,
            releaseIdentityShield: releaseIdentityShield
        )
    }
#endif
}
