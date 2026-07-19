import CryptoKit
import Darwin
import Foundation

nonisolated struct DurableAppLimitEpochFileIO: DeviceEpochFileIO {
    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
        )
        var renamed = false
        defer {
            if !renamed {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let descriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw Self.posixError() }
        var closeDescriptor = true
        defer {
            if closeDescriptor { Darwin.close(descriptor) }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { throw Self.posixError() }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.posixError() }
        guard Darwin.close(descriptor) == 0 else { throw Self.posixError() }
        closeDescriptor = false

        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw Self.posixError()
        }
        renamed = true

        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw Self.posixError() }
    }

    func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

nonisolated enum AppLimitEpochStoreError: Error, Equatable {
    case appGroupContainerUnavailable
    case lockUnavailable
    case ownerMismatch
    case unsupportedSchema(Int)
    case readbackMismatch
    case restorationFailed
    case revisionOverflow
    case invalidState(String)
    case legacyDecodeFailed
}

nonisolated final class AppLimitEpochStore: @unchecked Sendable {
    static let shared = AppLimitEpochStore()
    static let fileName = "app-limit-epoch-store-v1.json"
    static let legacyRulesKey = "evlin.appLimitRules"

    private let fileURL: URL?
    private let lock: any DeviceEpochStoreLocking
    private let fileIO: any DeviceEpochFileIO
    private let ownerProvider: @Sendable () -> UUID?
    private let legacyDefaults: UserDefaults?

    init(
        fileURL: URL? = nil,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        fileIO: any DeviceEpochFileIO = DurableAppLimitEpochFileIO(),
        ownerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: MeteringOwnerMirror.suiteName)
    ) {
        self.fileURL = fileURL
        self.lock = lock
        self.fileIO = fileIO
        self.ownerProvider = ownerProvider
        self.legacyDefaults = legacyDefaults
    }

    func read() throws -> AppLimitEpochStoreState {
        try withLock {
            let url = try resolvedFileURL()
            return try loadPersistedState(at: url).state
        }
    }

    @discardableResult
    func transaction<Value>(
        source: AppLimitCommandSource,
        expectedOwner: UUID?,
        _ mutate: (inout AppLimitEpochStoreState) throws -> Value
    ) throws -> Value {
        try withLock {
            let url = try resolvedFileURL()
            let loaded = try loadPersistedState(at: url)
            let priorData = loaded.persistedData
            let priorState = loaded.state
            try checkOwner(expectedOwner, state: priorState)

            var candidate = priorState
            if candidate.ownerChildDeviceID == nil {
                candidate.ownerChildDeviceID = expectedOwner
            }
            let value = try mutate(&candidate)
            candidate.schemaVersion = AppLimitEpochStoreState.currentSchemaVersion
            candidate.storeRevision = priorState.storeRevision
            candidate.ownerChildDeviceID = priorState.ownerChildDeviceID ?? expectedOwner
            candidate.lastMutationSource = priorState.lastMutationSource
            try checkOwner(expectedOwner, state: candidate)
            try validate(candidate)

            guard candidate != priorState else { return value }
            guard priorState.storeRevision < UInt64.max else {
                throw AppLimitEpochStoreError.revisionOverflow
            }
            candidate.storeRevision = priorState.storeRevision + 1
            candidate.lastMutationSource = source
            try validate(candidate)
            try persist(
                candidate,
                replacing: priorData,
                expectedOwner: expectedOwner,
                at: url
            )
            return value
        }
    }

    func reset() throws {
        try withLock {
            let url = try resolvedFileURL()
            try fileIO.remove(at: url)
            legacyDefaults?.removeObject(forKey: Self.legacyRulesKey)
        }
    }

    static func digest(of rule: AppLimitRule) -> String {
        guard let bytes = try? legacyEncoder.encode(rule) else { return "legacy-unencodable" }
        return sha256(bytes)
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURL { return fileURL }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MeteringOwnerMirror.suiteName
        ) else {
            throw AppLimitEpochStoreError.appGroupContainerUnavailable
        }
        return container.appendingPathComponent(Self.fileName)
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        guard let result = lock.withLock({ Result { try body() } }) else {
            throw AppLimitEpochStoreError.lockUnavailable
        }
        return try result.get()
    }

    private func loadPersistedState(
        at url: URL
    ) throws -> (state: AppLimitEpochStoreState, persistedData: Data?) {
        guard let data = try fileIO.read(from: url) else {
            return try migrateLegacyIfPresent(base: AppLimitEpochStoreState(), priorData: nil, at: url)
        }

        let state: AppLimitEpochStoreState
        do {
            state = try Self.decoder.decode(AppLimitEpochStoreState.self, from: data)
        } catch {
            try quarantine(data, at: url)
            return (AppLimitEpochStoreState(), nil)
        }
        guard state.schemaVersion <= AppLimitEpochStoreState.currentSchemaVersion else {
            throw AppLimitEpochStoreError.unsupportedSchema(state.schemaVersion)
        }
        try validate(state)
        if state.legacyMigration != nil {
            legacyDefaults?.removeObject(forKey: Self.legacyRulesKey)
            return (state, data)
        }
        return try migrateLegacyIfPresent(base: state, priorData: data, at: url)
    }

    private func migrateLegacyIfPresent(
        base: AppLimitEpochStoreState,
        priorData: Data?,
        at url: URL
    ) throws -> (state: AppLimitEpochStoreState, persistedData: Data?) {
        guard let legacyData = legacyDefaults?.data(forKey: Self.legacyRulesKey) else {
            return (base, priorData)
        }
        let decoded: [String: AppLimitRule]
        let format: String
        if let json = try? Self.legacyDecoder.decode([String: AppLimitRule].self, from: legacyData) {
            decoded = json
            format = "json"
        } else if let plist = try? PropertyListDecoder().decode(
            [String: AppLimitRule].self,
            from: legacyData
        ) {
            decoded = plist
            format = "propertyList"
        } else {
            throw AppLimitEpochStoreError.legacyDecodeFailed
        }

        guard base.storeRevision < UInt64.max else {
            throw AppLimitEpochStoreError.revisionOverflow
        }
        var migrated = base
        var migratedRuleCount = 0
        for rule in decoded.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard migrated.slots[rule.id] == nil else { continue }
            migrated.slots[rule.id] = AppLimitVersionSlot(
                ruleID: rule.id,
                latestOrderingToken: 0,
                latestKind: .set,
                latestPayloadDigest: Self.sha256(legacyData),
                activeRule: rule,
                clearTombstone: nil,
                pendingOwnerWork: nil,
                appliedReceipt: nil
            )
            migratedRuleCount += 1
        }
        migrated.storeRevision = base.storeRevision + 1
        migrated.schemaVersion = AppLimitEpochStoreState.currentSchemaVersion
        migrated.legacyMigration = AppLimitLegacyMigrationAudit(
            sourceKey: Self.legacyRulesKey,
            sourceFormat: format,
            payloadSHA256: Self.sha256(legacyData),
            payloadByteCount: legacyData.count,
            migratedRuleCount: migratedRuleCount,
            migratedAtStoreRevision: migrated.storeRevision
        )
        try validate(migrated)
        try persist(migrated, replacing: priorData, expectedOwner: nil, at: url)
        legacyDefaults?.removeObject(forKey: Self.legacyRulesKey)
        return (migrated, try fileIO.read(from: url))
    }

    private func quarantine(_ data: Data, at url: URL) throws {
        let quarantineURL = url.deletingPathExtension().appendingPathExtension(
            "corrupt-\(Self.sha256(data)).json"
        )
        if let existing = try fileIO.read(from: quarantineURL) {
            guard existing == data else { throw AppLimitEpochStoreError.readbackMismatch }
        } else {
            try fileIO.writeAtomically(data, to: quarantineURL)
            guard try fileIO.read(from: quarantineURL) == data else {
                throw AppLimitEpochStoreError.readbackMismatch
            }
        }
        try fileIO.remove(at: url)
    }

    private func persist(
        _ state: AppLimitEpochStoreState,
        replacing priorData: Data?,
        expectedOwner: UUID?,
        at url: URL
    ) throws {
        let encoded = try Self.encoder.encode(state)
        var writeAttempted = false
        do {
            writeAttempted = true
            try fileIO.writeAtomically(encoded, to: url)
            guard let readbackData = try fileIO.read(from: url),
                  readbackData == encoded
            else {
                throw AppLimitEpochStoreError.readbackMismatch
            }
            let readback = try Self.decoder.decode(
                AppLimitEpochStoreState.self,
                from: readbackData
            )
            try validate(readback)
            try checkOwner(expectedOwner, state: readback)
            guard readback == state else { throw AppLimitEpochStoreError.readbackMismatch }
        } catch {
            if writeAttempted {
                do {
                    if let priorData {
                        try fileIO.writeAtomically(priorData, to: url)
                    } else {
                        try fileIO.remove(at: url)
                    }
                } catch {
                    throw AppLimitEpochStoreError.restorationFailed
                }
            }
            throw error
        }
    }

    private func checkOwner(
        _ expectedOwner: UUID?,
        state: AppLimitEpochStoreState
    ) throws {
        guard let expectedOwner else { return }
        guard ownerProvider() == expectedOwner,
              state.ownerChildDeviceID == nil || state.ownerChildDeviceID == expectedOwner
        else { throw AppLimitEpochStoreError.ownerMismatch }
    }

    private func validate(_ state: AppLimitEpochStoreState) throws {
        guard state.schemaVersion == AppLimitEpochStoreState.currentSchemaVersion else {
            throw AppLimitEpochStoreError.unsupportedSchema(state.schemaVersion)
        }
        for (ruleID, slot) in state.slots {
            guard ruleID == slot.ruleID, slot.latestOrderingToken >= 0 else {
                throw AppLimitEpochStoreError.invalidState("slot identity or token")
            }
            switch slot.latestKind {
            case .set:
                guard slot.activeRule?.id == ruleID, slot.clearTombstone == nil else {
                    throw AppLimitEpochStoreError.invalidState("set slot payload")
                }
            case .clear:
                guard slot.activeRule == nil,
                      slot.clearTombstone?.ruleID == ruleID,
                      slot.clearTombstone?.orderingToken == slot.latestOrderingToken,
                      slot.clearTombstone?.payloadDigest == slot.latestPayloadDigest
                else { throw AppLimitEpochStoreError.invalidState("clear tombstone") }
            }
            if let work = slot.pendingOwnerWork {
                guard work.ruleID == ruleID,
                      work.orderingToken == slot.latestOrderingToken,
                      work.commandKind == slot.latestKind,
                      work.payloadDigest == slot.latestPayloadDigest
                else { throw AppLimitEpochStoreError.invalidState("owner work") }
            }
            if let receipt = slot.appliedReceipt {
                guard receipt.ruleID == ruleID,
                      receipt.orderingToken == slot.latestOrderingToken,
                      receipt.commandKind == slot.latestKind
                else { throw AppLimitEpochStoreError.invalidState("apply receipt") }
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static let legacyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let legacyDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
