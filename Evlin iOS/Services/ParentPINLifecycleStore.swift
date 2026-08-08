import Foundation

struct PendingParentPINUpload: Codable, Equatable, Sendable {
    let deviceID: UUID
    let baseURL: String
    let pin: String?
    let status: String
    let lifecycleSecret: String
    let resetGeneration: Int

    init(
        deviceID: UUID,
        baseURL: String,
        pin: String?,
        status: String,
        lifecycleSecret: String,
        resetGeneration: Int
    ) {
        self.deviceID = deviceID
        self.baseURL = baseURL
        self.pin = pin
        self.status = status
        self.lifecycleSecret = lifecycleSecret
        self.resetGeneration = resetGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, baseURL, pin, status, lifecycleSecret, resetGeneration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(UUID.self, forKey: .deviceID)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        pin = try container.decodeIfPresent(String.self, forKey: .pin)
        status = try container.decode(String.self, forKey: .status)
        lifecycleSecret = try container.decode(String.self, forKey: .lifecycleSecret)
        resetGeneration = try container.decodeIfPresent(Int.self, forKey: .resetGeneration) ?? 0
    }
}

struct ParentPINRemoteStatus: Equatable, Sendable {
    let status: String
    let resetGeneration: Int
}

struct PendingParentPINClear: Codable, Equatable, Sendable {
    let operationID: UUID
    let deviceID: UUID
    let baseURL: String
    let lifecycleSecret: String
}

/// PIN-only durable state. It deliberately has no dependency on metering or
/// pairing state machines: the device UUID selects the beta endpoint, while a
/// PIN-scoped secret authorizes destructive clearing after the first write.
@MainActor
final class ParentPINLifecycleStore {
    static let shared = ParentPINLifecycleStore(
        defaults: UserDefaults(suiteName: "group.com.evlin.ios")
    )

    private let defaults: UserDefaults?
    private let makeSecret: () -> String
    private let uploadKey = "evlin.parentPIN.pendingUpload.v2"
    private let clearsKey = "evlin.parentPIN.pendingClears.v2"
    private let secretsKey = "evlin.parentPIN.lifecycleSecrets.v2"
    private let generationsKey = "evlin.parentPIN.resetGenerations.v1"

    init(
        defaults: UserDefaults?,
        makeSecret: @escaping () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.defaults = defaults
        self.makeSecret = makeSecret
    }

    func captureUpload(
        pin: String?,
        status: String,
        deviceID: UUID,
        baseURL: String
    ) {
        var secrets = lifecycleSecrets()
        let secret = secrets[deviceID.uuidString] ?? makeSecret()
        secrets[deviceID.uuidString] = secret
        write(secrets, key: secretsKey)
        write(
            PendingParentPINUpload(
                deviceID: deviceID,
                baseURL: baseURL,
                pin: pin,
                status: status,
                lifecycleSecret: secret,
                resetGeneration: resetGeneration(for: deviceID)
            ),
            key: uploadKey
        )
    }

    func pendingUpload() -> PendingParentPINUpload? {
        read(PendingParentPINUpload.self, key: uploadKey)
    }

    func acknowledgeUpload(_ upload: PendingParentPINUpload) {
        guard pendingUpload() == upload else { return }
        defaults?.removeObject(forKey: uploadKey)
    }

    func lifecycleSecret(for deviceID: UUID) -> String? {
        lifecycleSecrets()[deviceID.uuidString]
    }

    func hasLifecycleProof(for deviceID: UUID) -> Bool {
        pendingUpload()?.deviceID == deviceID
            || lifecycleSecret(for: deviceID) != nil
    }

    func discardPendingUpload(unlessDeviceID deviceID: UUID) {
        guard let upload = pendingUpload(), upload.deviceID != deviceID else {
            return
        }
        defaults?.removeObject(forKey: uploadKey)
    }

    func resetGeneration(for deviceID: UUID) -> Int {
        resetGenerations()[deviceID.uuidString] ?? 0
    }

    /// Accept only a monotonic server reset. The caller owns deleting the PIN
    /// hash itself; this method atomically retires every upload credential that
    /// could otherwise restore the pre-reset PIN.
    @discardableResult
    func acceptRemoteResetGeneration(_ generation: Int, deviceID: UUID) -> Bool {
        guard generation > resetGeneration(for: deviceID) else { return false }

        var generations = resetGenerations()
        generations[deviceID.uuidString] = generation
        write(generations, key: generationsKey)

        if pendingUpload()?.deviceID == deviceID {
            defaults?.removeObject(forKey: uploadKey)
        }
        var secrets = lifecycleSecrets()
        secrets.removeValue(forKey: deviceID.uuidString)
        write(secrets, key: secretsKey)
        return true
    }

    @discardableResult
    func prepareSignOutClear(deviceID: UUID, baseURL: String) -> PendingParentPINClear? {
        guard let secret = lifecycleSecret(for: deviceID) else { return nil }
        let clear = PendingParentPINClear(
            operationID: UUID(),
            deviceID: deviceID,
            baseURL: baseURL,
            lifecycleSecret: secret
        )
        var clears = pendingClears()
        clears.append(clear)
        write(clears, key: clearsKey)

        var secrets = lifecycleSecrets()
        secrets.removeValue(forKey: deviceID.uuidString)
        write(secrets, key: secretsKey)
        if pendingUpload()?.deviceID == deviceID {
            defaults?.removeObject(forKey: uploadKey)
        }
        return clear
    }

    func pendingClears() -> [PendingParentPINClear] {
        read([PendingParentPINClear].self, key: clearsKey) ?? []
    }

    func acknowledgeClear(_ clear: PendingParentPINClear) {
        let remaining = pendingClears().filter { $0.operationID != clear.operationID }
        write(remaining, key: clearsKey)
    }

    private func lifecycleSecrets() -> [String: String] {
        read([String: String].self, key: secretsKey) ?? [:]
    }

    private func resetGenerations() -> [String: Int] {
        read([String: Int].self, key: generationsKey) ?? [:]
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults?.set(data, forKey: key)
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
