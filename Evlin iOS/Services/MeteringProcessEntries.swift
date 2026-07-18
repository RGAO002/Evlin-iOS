import Foundation
import FamilyControls

@MainActor
final class AppMeteringEntry {
    static let shared = AppMeteringEntry()

    private let defaults: UserDefaults?
    private let store: DeviceEpochStore
    private let center: any MeteringDeviceActivityCenter
    private let transport: any MeteringHTTPTransport
    private let clock: any MeteringClock
    private let instanceID: UUID

    init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: MeteringProductionComposition.appGroupSuiteName
        ),
        store: DeviceEpochStore = .shared,
        center: (any MeteringDeviceActivityCenter)? = nil,
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        instanceID: UUID = MeteringProductionComposition.instanceID(for: .app)
    ) {
        self.defaults = defaults
        self.store = store
        self.center = center ?? SystemMeteringDeviceActivityCenter()
        self.transport = transport
        self.clock = clock
        self.instanceID = instanceID
    }

    func recoverIfConfigured() async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        let driver = MeteringProductionComposition.makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: .app,
            instanceID: instanceID,
            store: store,
            center: center,
            transport: transport,
            clock: clock
        )
        do {
            try await driver.recover(ownerChildDeviceID: configuration.owner)
        } catch {
            print("[AppMeteringEntry] recovery failed: \(error)")
        }
    }
}

/// This injected process entry is intentionally nonisolated. Under the
/// project's MainActor default, its synthesized deinit uses the actor
/// back-deployment shim and double-frees when short-lived test instances are
/// released. Production uses the singleton, while tests construct serial,
/// independent instances, so the unchecked sendability promise is bounded.
nonisolated final class DAMMeteringEntry: @unchecked Sendable {
    static let shared = DAMMeteringEntry()

    private let defaults: UserDefaults?
    private let store: DeviceEpochStore
    private let center: (any MeteringDeviceActivityCenter)?
    private let transport: any MeteringHTTPTransport
    private let clock: any MeteringClock
    private let instanceID: UUID
    private let earnedStore: EarnedTimeStore
    private let effectStore: EarnedShieldEffectStore
    private let selectionProvider: () -> FamilyActivitySelection

    init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: MeteringProductionComposition.appGroupSuiteName
        ),
        store: DeviceEpochStore = .shared,
        center: (any MeteringDeviceActivityCenter)? = nil,
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        instanceID: UUID = MeteringProductionComposition.instanceID(
            for: .deviceActivityMonitor
        ),
        earnedStore: EarnedTimeStore = .shared,
        effectStore: EarnedShieldEffectStore? = nil,
        selectionProvider: @escaping () -> FamilyActivitySelection = {
            DefaultLockGroupStore.load()
        }
    ) {
        self.defaults = defaults
        self.store = store
        self.center = center
        self.transport = transport
        self.clock = clock
        self.instanceID = instanceID
        self.earnedStore = earnedStore
        self.effectStore = effectStore ?? EarnedShieldEffectStore(
            defaults: defaults,
            epochStore: store
        )
        self.selectionProvider = selectionProvider
    }

    @MainActor
    func recoverIfConfigured(
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        let driver = MeteringProductionComposition.makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: .deviceActivityMonitor,
            instanceID: instanceID,
            store: store,
            center: center ?? SystemMeteringDeviceActivityCenter(),
            transport: transport,
            clock: clock
        )
        do {
            try await driver.recover(ownerChildDeviceID: configuration.owner)
        } catch {
            NSLog("[DAMMeteringEntry] network recovery failed: %@", String(describing: error))
        }
        do {
            try recoverShieldEffects(
                expectedOwner: configuration.owner,
                projectShields: projectShields
            )
        } catch {
            NSLog("[DAMMeteringEntry] shield recovery failed: %@", String(describing: error))
        }
    }

    func handle(
        activityName: String,
        eventName: String,
        observedAt: Date,
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) throws -> EarnedMeteringCallbackOutcome {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return .discarded(reason: "missing_shared_configuration")
        }
        let callback = MeteringProductionComposition.makeCallback(
            store: store,
            clock: clock
        )
        let appleCallback = MeteringAppleCallback(
            activityName: activityName,
            eventName: eventName,
            observedAt: observedAt
        )
        guard let candidate = try callback.terminalCandidate(
            appleCallback,
            expectedOwnerChildDeviceID: configuration.owner
        ) else {
            return try callback.handle(
                appleCallback,
                expectedOwnerChildDeviceID: configuration.owner
            )
        }

        let suppressed = {
            !self.earnedStore.usageCountingAllowed
                || self.earnedStore.isOverridden(forUsageDate: candidate.usageDate)
        }
        guard !suppressed() else {
            return try callback.handle(
                appleCallback,
                expectedOwnerChildDeviceID: configuration.owner
            )
        }

        let envelope: EarnedShieldEffectEnvelope
        do {
            guard let prepared = try effectStore.prepareTerminal(
                candidate,
                selection: selectionProvider(),
                appliesToAll: earnedStore.lockedSetAllSelected,
                isSuppressed: suppressed
            ) else {
                return try callback.handle(
                    appleCallback,
                    expectedOwnerChildDeviceID: configuration.owner
                )
            }
            envelope = prepared
        } catch {
            NSLog("[DAMMeteringEntry] terminal shield prepare failed: %@", String(describing: error))
            return try callback.handle(
                appleCallback,
                expectedOwnerChildDeviceID: configuration.owner
            )
        }

        let outcome = try callback.handle(
            appleCallback,
            expectedOwnerChildDeviceID: configuration.owner,
            preparedShieldReference: try effectStore.reference(for: envelope)
        )
        switch outcome {
        case .discarded:
            try effectStore.discardPrepared(
                operationID: envelope.operationID,
                expectedOwner: configuration.owner
            )
        case .queued:
            if try effectStore.applyPrepared(
                operationID: envelope.operationID,
                expectedOwner: configuration.owner,
                isSuppressed: { _ in suppressed() }
            ) {
                projectShields(try effectStore.loadShieldRecords())
            }
        }
        return outcome
    }

    func recoverShieldEffects(
        expectedOwner: UUID,
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) throws {
        let changed = try effectStore.recover(
            expectedOwner: expectedOwner,
            isSuppressed: { envelope in
                guard let route = try? self.store.read().routes[envelope.routeID] else {
                    return true
                }
                return !self.earnedStore.usageCountingAllowed
                    || self.earnedStore.isOverridden(forUsageDate: route.usageDate)
            }
        )
        if changed {
            projectShields(try effectStore.loadShieldRecords())
        }
    }
}

private struct MeteringProcessConfiguration {
    let baseURL: URL
    let owner: UUID

    static func load(defaults: UserDefaults?) -> MeteringProcessConfiguration? {
        guard let defaults,
              let baseRaw = defaults.string(forKey: MeteringProductionComposition.baseURLKey),
              let baseURL = URL(string: baseRaw),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil,
              let ownerRaw = defaults.string(forKey: MeteringProductionComposition.ownerKey),
              let owner = UUID(uuidString: ownerRaw)
        else { return nil }
        return MeteringProcessConfiguration(baseURL: baseURL, owner: owner)
    }
}
