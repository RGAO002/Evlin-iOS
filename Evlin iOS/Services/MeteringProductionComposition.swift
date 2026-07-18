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
        clock: any MeteringClock = MeteringRuntimeClock.live()
    ) async throws {
        guard let configuration = sharedConfiguration() else { return }
        let driver = makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: role,
            instanceID: instanceID(for: role),
            store: store,
            clock: clock
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
