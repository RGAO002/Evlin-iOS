import CryptoKit
import Darwin
import Foundation

nonisolated struct DurableAppLimitEpochFileIO: DeviceEpochFileIO {
    private let syncDirectory: @Sendable (URL) throws -> Void

    init(
        syncDirectory: @escaping @Sendable (URL) throws -> Void = Self.fsyncDirectory
    ) {
        self.syncDirectory = syncDirectory
    }

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

        try syncDirectory(directory)
    }

    func remove(at url: URL) throws {
        guard Darwin.unlink(url.path) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.posixError() }
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
            return try loadPersistedState(
                at: url,
                expectedOwnerForMigration: ownerProvider()
            ).state
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
            let loaded = try loadPersistedState(
                at: url,
                expectedOwnerForMigration: expectedOwner
            )
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

    func resetForIdentityTeardown(expectedOwner: UUID) throws {
        try withLock {
            let url = try resolvedFileURL()
            let loaded: AppLimitEpochStoreState
            if try fileIO.read(from: url) == nil {
                loaded = AppLimitEpochStoreState()
            } else {
                loaded = try loadPersistedState(
                    at: url,
                    expectedOwnerForMigration: expectedOwner
                ).state
            }
            try checkOwner(expectedOwner, state: loaded)
            try fileIO.remove(at: url)
            guard try fileIO.read(from: url) == nil else {
                throw AppLimitEpochStoreError.readbackMismatch
            }
            legacyDefaults?.removeObject(forKey: Self.legacyRulesKey)
        }
    }

    func requiresOwnerForIdentityTeardown() throws -> Bool {
        try withLock {
            let url = try resolvedFileURL()
            guard let data = try fileIO.read(from: url) else {
                return legacyDefaults?.data(forKey: Self.legacyRulesKey) != nil
            }
            let state = try Self.decoder.decode(AppLimitEpochStoreState.self, from: data)
            guard state.schemaVersion <= AppLimitEpochStoreState.currentSchemaVersion else {
                throw AppLimitEpochStoreError.unsupportedSchema(state.schemaVersion)
            }
            try validate(state)
            return state.ownerChildDeviceID != nil
                || !state.slots.isEmpty
                || state.storeRevision != 0
                || state.legacyMigration != nil
                || state.lastMutationSource != nil
                || legacyDefaults?.data(forKey: Self.legacyRulesKey) != nil
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
        at url: URL,
        expectedOwnerForMigration: UUID?
    ) throws -> (state: AppLimitEpochStoreState, persistedData: Data?) {
        guard let data = try fileIO.read(from: url) else {
            return try migrateLegacyIfPresent(
                base: AppLimitEpochStoreState(),
                priorData: nil,
                expectedOwner: expectedOwnerForMigration,
                at: url
            )
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
        try checkOwner(expectedOwnerForMigration, state: state)
        do {
            try validate(state)
        } catch AppLimitEpochStoreError.invalidState {
            try quarantine(data, at: url)
            return (AppLimitEpochStoreState(), nil)
        }
        if state.legacyMigration != nil {
            if legacyDefaults?.data(forKey: Self.legacyRulesKey) != nil {
                try checkOwner(expectedOwnerForMigration, state: state)
                legacyDefaults?.removeObject(forKey: Self.legacyRulesKey)
            }
            return (state, data)
        }
        return try migrateLegacyIfPresent(
            base: state,
            priorData: data,
            expectedOwner: expectedOwnerForMigration,
            at: url
        )
    }

    private func migrateLegacyIfPresent(
        base: AppLimitEpochStoreState,
        priorData: Data?,
        expectedOwner: UUID?,
        at url: URL
    ) throws -> (state: AppLimitEpochStoreState, persistedData: Data?) {
        guard let legacyData = legacyDefaults?.data(forKey: Self.legacyRulesKey) else {
            return (base, priorData)
        }
        try checkOwner(expectedOwner, state: base)
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
        migrated.ownerChildDeviceID = base.ownerChildDeviceID ?? expectedOwner
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
        try persist(
            migrated,
            replacing: priorData,
            expectedOwner: expectedOwner,
            at: url
        )
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
        if let boundOwner = state.ownerChildDeviceID {
            guard expectedOwner == boundOwner, ownerProvider() == boundOwner else {
                throw AppLimitEpochStoreError.ownerMismatch
            }
            return
        }
        guard let expectedOwner else { return }
        guard ownerProvider() == expectedOwner else {
            throw AppLimitEpochStoreError.ownerMismatch
        }
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
