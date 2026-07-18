import Foundation

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

final class DAMMeteringEntry {
    static let shared = DAMMeteringEntry()

    private let defaults: UserDefaults?
    private let store: DeviceEpochStore
    private let center: (any MeteringDeviceActivityCenter)?
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
        instanceID: UUID = MeteringProductionComposition.instanceID(
            for: .deviceActivityMonitor
        )
    ) {
        self.defaults = defaults
        self.store = store
        self.center = center
        self.transport = transport
        self.clock = clock
        self.instanceID = instanceID
    }

    @MainActor
    func recoverIfConfigured() async {
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
            NSLog("[DAMMeteringEntry] recovery failed: %@", String(describing: error))
        }
    }

    func handle(
        activityName: String,
        eventName: String,
        observedAt: Date
    ) throws -> EarnedMeteringCallbackOutcome {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return .discarded(reason: "missing_shared_configuration")
        }
        return try MeteringProductionComposition.makeCallback(
            store: store,
            clock: clock
        ).handle(
            MeteringAppleCallback(
                activityName: activityName,
                eventName: eventName,
                observedAt: observedAt
            ),
            expectedOwnerChildDeviceID: configuration.owner
        )
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
