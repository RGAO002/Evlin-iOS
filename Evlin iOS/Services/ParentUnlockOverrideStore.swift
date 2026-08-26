import Foundation

nonisolated enum ParentUnlockOverrideStoreError: Error, Equatable {
    case appGroupContainerUnavailable
    case lockUnavailable
    case ownerMismatch
    case invalidState
    case readbackMismatch
    case restorationFailed
}

nonisolated final class ParentUnlockOverrideStore: @unchecked Sendable {
    static let shared = ParentUnlockOverrideStore()
    static let fileName = "parent-unlock-override-v1.json"

    private let fileURL: URL?
    private let lock: any DeviceEpochStoreLocking
    private let fileIO: any DeviceEpochFileIO

    init(
        fileURL: URL? = nil,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        fileIO: any DeviceEpochFileIO = DurableAppLimitEpochFileIO()
    ) {
        self.fileURL = fileURL
        self.lock = lock
        self.fileIO = fileIO
    }

    func read(expectedOwner: UUID) throws -> ParentUnlockOverrideSnapshot? {
        try withLock {
            let loaded = try load(at: resolvedFileURL())
            guard loaded?.childDeviceID == expectedOwner || loaded == nil else {
                throw ParentUnlockOverrideStoreError.ownerMismatch
            }
            return loaded
        }
    }

    @discardableResult
    func ingest(
        _ envelope: ParentUnlockOverrideEnvelope,
        expectedOwner: UUID,
        now: Date
    ) throws -> ParentUnlockOverrideDisposition {
        guard envelope.childDeviceID == expectedOwner else { return .rejectedIdentity }
        try validate(envelope)

        return try withLock {
            let url = try resolvedFileURL()
            let priorData = try fileIO.read(from: url)
            let current = try decode(priorData)
            guard current?.childDeviceID == expectedOwner || current == nil else {
                return .rejectedIdentity
            }
            if let current {
                if envelope.revision < current.revision {
                    return .superseded(currentRevision: current.revision)
                }
                if envelope.revision == current.revision {
                    return .replayed
                }
            }

            let status: ParentUnlockOverrideSnapshot.Status
            if envelope.cancelled {
                status = .cancelled
            } else if now >= envelope.expiresAt {
                status = .expired
            } else {
                status = .active
            }
            try persist(
                ParentUnlockOverrideSnapshot(envelope: envelope, status: status),
                replacing: priorData,
                at: url
            )
            return .applied
        }
    }

    @discardableResult
    func expireIfNeeded(expectedOwner: UUID, now: Date) throws -> Bool {
        try withLock {
            let url = try resolvedFileURL()
            let priorData = try fileIO.read(from: url)
            guard let current = try decode(priorData) else { return false }
            guard current.childDeviceID == expectedOwner else {
                throw ParentUnlockOverrideStoreError.ownerMismatch
            }
            guard current.status == .active, now >= current.expiresAt else { return false }
            try persist(
                ParentUnlockOverrideSnapshot(envelope: current.envelope, status: .expired),
                replacing: priorData,
                at: url
            )
            return true
        }
    }

    func clearForIdentityTeardown() throws {
        try withLock {
            let url = try resolvedFileURL()
            guard try fileIO.read(from: url) != nil else { return }
            try fileIO.remove(at: url)
        }
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURL { return fileURL }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MeteringOwnerMirror.suiteName
        ) else {
            throw ParentUnlockOverrideStoreError.appGroupContainerUnavailable
        }
        return container.appendingPathComponent(Self.fileName)
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        guard let result = lock.withLock({ Result { try body() } }) else {
            throw ParentUnlockOverrideStoreError.lockUnavailable
        }
        return try result.get()
    }

    private func load(at url: URL) throws -> ParentUnlockOverrideSnapshot? {
        try decode(fileIO.read(from: url))
    }

    private func decode(_ data: Data?) throws -> ParentUnlockOverrideSnapshot? {
        guard let data else { return nil }
        let snapshot: ParentUnlockOverrideSnapshot
        do {
            snapshot = try Self.decoder.decode(ParentUnlockOverrideSnapshot.self, from: data)
        } catch {
            throw ParentUnlockOverrideStoreError.invalidState
        }
        try validate(snapshot)
        return snapshot
    }

    private func persist(
        _ snapshot: ParentUnlockOverrideSnapshot,
        replacing priorData: Data?,
        at url: URL
    ) throws {
        try validate(snapshot)
        let encoded = try Self.encoder.encode(snapshot)
        var writeAttempted = false
        do {
            writeAttempted = true
            try fileIO.writeAtomically(encoded, to: url)
            guard let readbackData = try fileIO.read(from: url), readbackData == encoded else {
                throw ParentUnlockOverrideStoreError.readbackMismatch
            }
            guard let readback = try decode(readbackData), readback == snapshot else {
                throw ParentUnlockOverrideStoreError.readbackMismatch
            }
        } catch {
            if writeAttempted {
                do {
                    if let priorData {
                        try fileIO.writeAtomically(priorData, to: url)
                    } else {
                        try fileIO.remove(at: url)
                    }
                } catch {
                    throw ParentUnlockOverrideStoreError.restorationFailed
                }
            }
            throw error
        }
    }

    private func validate(_ envelope: ParentUnlockOverrideEnvelope) throws {
        guard envelope.revision > 0,
              !envelope.usageDate.isEmpty,
              envelope.expiresAt >= envelope.startedAt,
              !envelope.scopes.isEmpty
        else { throw ParentUnlockOverrideStoreError.invalidState }
    }

    private func validate(_ snapshot: ParentUnlockOverrideSnapshot) throws {
        try validate(snapshot.envelope)
        switch snapshot.status {
        case .active, .expired:
            guard !snapshot.envelope.cancelled else {
                throw ParentUnlockOverrideStoreError.invalidState
            }
        case .cancelled:
            guard snapshot.envelope.cancelled else {
                throw ParentUnlockOverrideStoreError.invalidState
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
