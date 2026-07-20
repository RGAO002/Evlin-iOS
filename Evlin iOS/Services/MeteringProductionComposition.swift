import FamilyControls
import Foundation

nonisolated enum MeteringProductionComposition {
    static let appGroupSuiteName = "group.com.evlin.ios"
    static let baseURLKey = "evlin.baseURL"
    static let ownerKey = "evlin.childId"
    static let selectionKey = "earned.measurementSelection"
    static let lockedSetIDKey = "earned.lockedSetID"

    private static let appInstanceID = UUID()
    private static let monitorInstanceID = UUID()

    @MainActor
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
        return EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: installer,
            center: center,
            processIdentity: identity,
            clock: clock
        )
    }

    static func makeCallback(
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live()
    ) -> EarnedMeteringCallback {
        EarnedMeteringCallback(store: store, clock: clock)
    }

    @MainActor
    static func recoverFromSharedConfiguration(
        role: MeteringProcessRole,
        runtime: EarnedTimeRuntime? = nil,
        usageCountingAllowed: Bool? = nil,
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        transport: any MeteringHTTPTransport = URLSession.shared
    ) async throws {
        guard let configuration = sharedConfiguration() else { return }
        let driver = makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: role,
            instanceID: instanceID(for: role),
            store: store,
            transport: transport,
            clock: clock
        )

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
        try await driver.recover(ownerChildDeviceID: configuration.owner)
        if role == .app {
            try await finalizeDesiredPolicyIfApplied(
                owner: configuration.owner,
                baseURL: configuration.baseURL,
                store: store,
                transport: transport,
                now: clock.now
            )
        }
    }

    private static func planDesiredPolicyIfPresent(
        owner: UUID,
        store: DeviceEpochStore,
        defaults: UserDefaults,
        now: Date
    ) throws {
        let state = try store.read()
        guard let desired = state.desiredPolicy,
              desired.ownerChildDeviceID == owner,
              desired.ackedAt == nil,
              let selectionBytes = defaults.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(
                  FamilyActivitySelection.self,
                  from: selectionBytes
              ),
              !selection.applicationTokens.isEmpty
                || !selection.categoryTokens.isEmpty
                || !selection.webDomainTokens.isEmpty,
              let enforcementSetID = desired.enforcementSetID
                ?? defaults.string(forKey: lockedSetIDKey).flatMap(UUID.init(uuidString:))
        else { return }

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
              let baseURL = URL(string: baseRaw),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil,
              let ownerRaw = defaults.string(forKey: ownerKey),
              let owner = UUID(uuidString: ownerRaw)
        else { return nil }
        return (defaults, baseURL, owner)
    }

    static func instanceID(for role: MeteringProcessRole) -> UUID {
        switch role {
        case .app: appInstanceID
        case .deviceActivityMonitor: monitorInstanceID
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
