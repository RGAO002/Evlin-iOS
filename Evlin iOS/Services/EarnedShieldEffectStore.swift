import Foundation
import FamilyControls

nonisolated enum EarnedShieldEffectPhase: String, Codable, Sendable {
    case prepared, applied, releasePending, released, conflicted
}

nonisolated enum EarnedShieldEffectError: Error, Equatable {
    case defaultsUnavailable
    case lockUnavailable
    case authorizationChanged
    case envelopeMissing(UUID)
    case durableReadbackMismatch
    case casConflict(UUID)
}

nonisolated struct EarnedShieldEffectEnvelope: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
    let recordKey: String
    let beforeRecord: ShieldRecord?
    let intendedAfterRecord: ShieldRecord?
    var phase: EarnedShieldEffectPhase
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated enum EarnedShieldCAS {
    static func releasingEarnedSource(
        current: ShieldRecord?,
        expectedApplied: ShieldRecord
    ) -> ShieldRecord? {
        guard current == expectedApplied else { return current }
        var released = expectedApplied
        released.sources.remove(.earnedTime)
        return released.sources.isEmpty ? nil : released
    }
}

/// Durable compare-and-swap for the earned source only. It deliberately has no
/// ManagedSettings dependency: projection remains owned by ActiveLockStore and
/// DeviceActivityMonitor wiring remains Task 18 work.
nonisolated final class EarnedShieldEffectStore: @unchecked Sendable {
    static let envelopeKey = "evlin.earnedShieldEffectEnvelopes.v1"
    static let shieldsKey = "evlin.shieldRecords"
    static let blocksKey = "evlin.blockRecords"

    private let defaults: UserDefaults?
    private let lock: ActiveLockPersistenceLock
    private let epochStore: DeviceEpochStore

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        lock: ActiveLockPersistenceLock = .shared,
        epochStore: DeviceEpochStore = .shared
    ) {
        self.defaults = defaults
        self.lock = lock
        self.epochStore = epochStore
    }

    /// Persists only the local lock intent. The callback transaction later
    /// commits the exact D#6 reference together with its sample; recovery is
    /// forbidden from applying this envelope until that reference exists.
    func prepareTerminal(
        _ candidate: MeteringTerminalShieldCandidate,
        selection: FamilyActivitySelection,
        appliesToAll: Bool,
        isSuppressed: () -> Bool
    ) throws -> EarnedShieldEffectEnvelope? {
        try withPersistenceLock {
            guard !isSuppressed() else { return nil }
            var envelopes = try loadEnvelopes()
            let recordKey = ShieldRecord.makeRecordKey(
                tier: .savedList,
                targetKey: candidate.enforcementSetID.uuidString
            )
            if let existing = envelopes[candidate.operationID] {
                guard existing.ownerChildDeviceID == candidate.ownerChildDeviceID,
                      existing.generationID == candidate.generationID,
                      existing.epochID == candidate.epochID,
                      existing.routeID == candidate.routeID,
                      existing.recordKey == recordKey
                else { throw EarnedShieldEffectError.authorizationChanged }
                switch existing.phase {
                case .prepared, .applied:
                    return existing
                case .released, .releasePending:
                    return nil
                case .conflicted:
                    throw EarnedShieldEffectError.casConflict(existing.operationID)
                }
            }

            let shields = try loadShields()
            let before = shields[recordKey]
            let after: ShieldRecord
            if let before {
                after = ShieldSourceLogic.unioning(before, intoSources: [.earnedTime])
            } else {
                after = ShieldRecord(
                    recordKey: recordKey,
                    tier: .savedList,
                    targetKey: candidate.enforcementSetID.uuidString,
                    displayName: "Locked Set",
                    lastCommandID: candidate.operationID,
                    appTokens: selection.applicationTokens,
                    categoryTokens: selection.categoryTokens,
                    webDomainTokens: selection.webDomainTokens,
                    appliesToAll: appliesToAll,
                    issuedAt: candidate.observedAt,
                    expiresAt: nil,
                    originalRequest: "earned time terminal: t\(candidate.thresholdMinutes)",
                    targetChildID: candidate.ownerChildDeviceID,
                    sources: [.earnedTime]
                )
            }
            let envelope = EarnedShieldEffectEnvelope(
                operationID: candidate.operationID,
                ownerChildDeviceID: candidate.ownerChildDeviceID,
                generationID: candidate.generationID,
                epochID: candidate.epochID,
                routeID: candidate.routeID,
                recordKey: recordKey,
                beforeRecord: before,
                intendedAfterRecord: after,
                phase: .prepared,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: candidate.observedAt,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: candidate.observedAt
            )
            try validateEnvelope(envelope)
            guard try epochStore.canPrepareEarnedShieldReference(try reference(for: envelope)) else {
                throw EarnedShieldEffectError.authorizationChanged
            }
            envelopes[envelope.operationID] = envelope
            try persistEnvelopes(envelopes)
            return envelope
        }
    }

    /// Applies a previously prepared intent only when the callback transaction
    /// has committed its byte-exact reference. The suppression closure executes
    /// while the ActiveLock lock is held, closing the override race.
    @discardableResult
    func applyPrepared(
        operationID: UUID,
        expectedOwner: UUID,
        isSuppressed: (EarnedShieldEffectEnvelope) -> Bool
    ) throws -> Bool {
        try withPersistenceLock {
            var envelopes = try loadEnvelopes()
            guard var envelope = envelopes[operationID] else {
                throw EarnedShieldEffectError.envelopeMissing(operationID)
            }
            guard envelope.ownerChildDeviceID == expectedOwner else {
                throw EarnedShieldEffectError.authorizationChanged
            }
            let expectedReference = try reference(for: envelope)
            guard try epochStore.hasExactEarnedShieldReference(expectedReference) else {
                throw EarnedShieldEffectError.authorizationChanged
            }
            switch envelope.phase {
            case .released, .releasePending:
                return false
            case .conflicted:
                throw EarnedShieldEffectError.casConflict(operationID)
            case .applied:
                guard try loadShields()[envelope.recordKey] == envelope.intendedAfterRecord else {
                    envelope.phase = .conflicted
                    envelopes[operationID] = envelope
                    try persistEnvelopes(envelopes)
                    throw EarnedShieldEffectError.casConflict(operationID)
                }
                return false
            case .prepared:
                break
            }

            if isSuppressed(envelope) {
                envelope.phase = .released
                envelopes[operationID] = envelope
                try persistEnvelopes(envelopes)
                return false
            }

            var shields = try loadShields()
            let current = shields[envelope.recordKey]
            if current != envelope.intendedAfterRecord {
                guard current == envelope.beforeRecord else {
                    envelope.phase = .conflicted
                    envelopes[operationID] = envelope
                    try persistEnvelopes(envelopes)
                    throw EarnedShieldEffectError.casConflict(operationID)
                }
                set(envelope.intendedAfterRecord, at: envelope.recordKey, in: &shields)
                try persistShields(shields)
            }
            envelope.phase = .applied
            envelopes[operationID] = envelope
            try persistEnvelopes(envelopes)
            return true
        }
    }

    func discardPrepared(operationID: UUID, expectedOwner: UUID) throws {
        try withPersistenceLock {
            var envelopes = try loadEnvelopes()
            guard let envelope = envelopes[operationID],
                  envelope.ownerChildDeviceID == expectedOwner,
                  envelope.phase == .prepared
            else { return }
            if try epochStore.hasExactEarnedShieldReference(try reference(for: envelope)) {
                return
            }
            envelopes.removeValue(forKey: operationID)
            try persistEnvelopes(envelopes)
        }
    }

    func apply(_ envelope: EarnedShieldEffectEnvelope) throws {
        try withPersistenceLock {
            try validateEnvelope(envelope)
            var envelopes = try loadEnvelopes()
            let priorEnvelopes = envelopes
            let persisted: EarnedShieldEffectEnvelope

            if let existing = envelopes[envelope.operationID] {
                guard hasSameImmutableTuple(existing, envelope) else {
                    throw EarnedShieldEffectError.authorizationChanged
                }
                switch existing.phase {
                case .applied:
                    persisted = existing
                case .released, .releasePending:
                    throw EarnedShieldEffectError.authorizationChanged
                case .conflicted:
                    throw EarnedShieldEffectError.casConflict(existing.operationID)
                case .prepared:
                    persisted = existing
                }
            } else {
                guard try epochStore.canPrepareEarnedShieldReference(try reference(for: envelope)) else {
                    throw EarnedShieldEffectError.authorizationChanged
                }
                envelopes[envelope.operationID] = envelope
                try persistEnvelopes(envelopes)
                persisted = envelope
            }

            guard try epochStore.createOrVerifyEarnedShieldReference(try reference(for: persisted)) else {
                if envelopes != priorEnvelopes {
                    try persistEnvelopes(priorEnvelopes)
                }
                throw EarnedShieldEffectError.authorizationChanged
            }

            var shields = try loadShields()
            let current = shields[persisted.recordKey]
            if persisted.phase == .applied {
                guard current == persisted.intendedAfterRecord else {
                    var conflicted = persisted
                    conflicted.phase = .conflicted
                    envelopes[conflicted.operationID] = conflicted
                    try persistEnvelopes(envelopes)
                    throw EarnedShieldEffectError.casConflict(persisted.operationID)
                }
                return
            }
            if current == persisted.intendedAfterRecord {
                var applied = persisted
                applied.phase = .applied
                envelopes[applied.operationID] = applied
                try persistEnvelopes(envelopes)
                return
            }
            guard current == persisted.beforeRecord else {
                var conflicted = persisted
                conflicted.phase = .conflicted
                envelopes[conflicted.operationID] = conflicted
                try persistEnvelopes(envelopes)
                throw EarnedShieldEffectError.casConflict(persisted.operationID)
            }

            set(persisted.intendedAfterRecord, at: persisted.recordKey, in: &shields)
            try persistShields(shields)
            var applied = persisted
            applied.phase = .applied
            envelopes[applied.operationID] = applied
            try persistEnvelopes(envelopes)
        }
    }

    func release(operationID: UUID, expectedOwner: UUID) throws {
        try withPersistenceLock {
            var envelopes = try loadEnvelopes()
            guard var envelope = envelopes[operationID] else {
                throw EarnedShieldEffectError.envelopeMissing(operationID)
            }
            guard envelope.ownerChildDeviceID == expectedOwner else {
                throw EarnedShieldEffectError.authorizationChanged
            }
            switch envelope.phase {
            case .released:
                return
            case .conflicted:
                throw EarnedShieldEffectError.casConflict(operationID)
            case .prepared:
                throw EarnedShieldEffectError.authorizationChanged
            case .applied, .releasePending:
                break
            }

            let reference = try reference(for: envelope)
            guard try epochStore.canReleaseEarnedShieldReference(reference) else {
                throw EarnedShieldEffectError.authorizationChanged
            }
            let priorEnvelope = envelope
            envelope.phase = .releasePending
            envelopes[operationID] = envelope
            try persistEnvelopes(envelopes)
            guard try epochStore.canReleaseEarnedShieldReference(reference) else {
                envelopes[operationID] = priorEnvelope
                try persistEnvelopes(envelopes)
                throw EarnedShieldEffectError.authorizationChanged
            }

            var shields = try loadShields()
            let released = EarnedShieldCAS.releasingEarnedSource(
                current: envelope.intendedAfterRecord,
                expectedApplied: try requiredAppliedRecord(envelope)
            )
            let current = shields[envelope.recordKey]
            if current == released {
                envelope.phase = .released
                envelopes[operationID] = envelope
                try persistEnvelopes(envelopes)
                return
            }
            guard current == envelope.intendedAfterRecord else {
                envelope.phase = .conflicted
                envelopes[operationID] = envelope
                try persistEnvelopes(envelopes)
                throw EarnedShieldEffectError.casConflict(operationID)
            }

            set(released, at: envelope.recordKey, in: &shields)
            try persistShields(shields)
            envelope.phase = .released
            envelopes[operationID] = envelope
            try persistEnvelopes(envelopes)
        }
    }

    @discardableResult
    func recover(
        expectedOwner: UUID,
        isSuppressed: (EarnedShieldEffectEnvelope) -> Bool = { _ in false }
    ) throws -> Bool {
        let pending = try withPersistenceLock { () -> [EarnedShieldEffectEnvelope] in
            try loadEnvelopes().values
                .filter { $0.ownerChildDeviceID == expectedOwner }
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.operationID.uuidString.lowercased()
                        < $1.operationID.uuidString.lowercased()
                }
        }
        var requiresProjection = false
        for envelope in pending {
            switch envelope.phase {
            case .prepared:
                let reference = try reference(for: envelope)
                if try epochStore.hasExactEarnedShieldReference(reference) {
                    requiresProjection = try applyPrepared(
                        operationID: envelope.operationID,
                        expectedOwner: expectedOwner,
                        isSuppressed: isSuppressed
                    ) || requiresProjection
                } else {
                    try discardPrepared(
                        operationID: envelope.operationID,
                        expectedOwner: expectedOwner
                    )
                }
            case .releasePending:
                try release(operationID: envelope.operationID, expectedOwner: expectedOwner)
                requiresProjection = true
            case .applied, .released:
                continue
            case .conflicted:
                throw EarnedShieldEffectError.casConflict(envelope.operationID)
            }
        }
        return requiresProjection
    }

    func reference(for envelope: EarnedShieldEffectEnvelope) throws -> EarnedShieldReference {
        EarnedShieldReference(
            operationID: envelope.operationID,
            ownerChildDeviceID: envelope.ownerChildDeviceID,
            generationID: envelope.generationID,
            epochID: envelope.epochID,
            routeID: envelope.routeID,
            recordKey: envelope.recordKey,
            expectedRecordBytes: try encodedRecordBytes(try requiredAppliedRecord(envelope)),
            retry: envelope.retry,
            createdAt: envelope.createdAt
        )
    }

    func loadShieldRecords() throws -> [String: ShieldRecord] {
        try withPersistenceLock { try loadShields() }
    }

    private func validateEnvelope(_ envelope: EarnedShieldEffectEnvelope) throws {
        guard envelope.phase == .prepared,
              let intended = envelope.intendedAfterRecord,
              intended.recordKey == envelope.recordKey,
              envelope.beforeRecord?.recordKey == nil || envelope.beforeRecord?.recordKey == envelope.recordKey,
              intended.sources.contains(.earnedTime)
        else { throw EarnedShieldEffectError.authorizationChanged }
    }

    private func requiredAppliedRecord(_ envelope: EarnedShieldEffectEnvelope) throws -> ShieldRecord {
        guard let intended = envelope.intendedAfterRecord else {
            throw EarnedShieldEffectError.authorizationChanged
        }
        return intended
    }

    private func hasSameImmutableTuple(
        _ lhs: EarnedShieldEffectEnvelope,
        _ rhs: EarnedShieldEffectEnvelope
    ) -> Bool {
        lhs.operationID == rhs.operationID
            && lhs.ownerChildDeviceID == rhs.ownerChildDeviceID
            && lhs.generationID == rhs.generationID
            && lhs.epochID == rhs.epochID
            && lhs.routeID == rhs.routeID
            && lhs.recordKey == rhs.recordKey
            && lhs.beforeRecord == rhs.beforeRecord
            && lhs.intendedAfterRecord == rhs.intendedAfterRecord
            && lhs.createdAt == rhs.createdAt
    }

    private func withPersistenceLock<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        guard lock.withLock({ result = Result { try body() } }) != nil else {
            throw EarnedShieldEffectError.lockUnavailable
        }
        return try result!.get()
    }

    private func loadEnvelopes() throws -> [UUID: EarnedShieldEffectEnvelope] {
        try load([UUID: EarnedShieldEffectEnvelope].self, key: Self.envelopeKey)
    }

    private func loadShields() throws -> [String: ShieldRecord] {
        try load([String: ShieldRecord].self, key: Self.shieldsKey)
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let defaults else { throw EarnedShieldEffectError.defaultsUnavailable }
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else {
            if type == [UUID: EarnedShieldEffectEnvelope].self {
                return [:] as! T
            }
            if type == [String: ShieldRecord].self {
                return [:] as! T
            }
            throw EarnedShieldEffectError.durableReadbackMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(type, from: data) else {
            throw EarnedShieldEffectError.durableReadbackMismatch
        }
        return value
    }

    private func persistEnvelopes(_ envelopes: [UUID: EarnedShieldEffectEnvelope]) throws {
        try persist(envelopes, key: Self.envelopeKey)
    }

    private func persistShields(_ shields: [String: ShieldRecord]) throws {
        try persist(shields, key: Self.shieldsKey)
    }

    private func persist<T: Encodable>(_ value: T, key: String) throws {
        guard let defaults else { throw EarnedShieldEffectError.defaultsUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            throw EarnedShieldEffectError.durableReadbackMismatch
        }
        defaults.set(data, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == data else {
            throw EarnedShieldEffectError.durableReadbackMismatch
        }
    }

    private func encodedRecordBytes(_ record: ShieldRecord) throws -> Data {
        struct CanonicalRecord: Encodable {
            let recordKey: String
            let tier: String
            let targetKey: String
            let displayName: String
            let lastCommandID: String
            let appTokens: [String]
            let categoryTokens: [String]
            let webDomainTokens: [String]
            let appliesToAll: Bool
            let issuedAt: Date
            let expiresAt: Date?
            let originalRequest: String
            let targetChildID: String
            let sources: [String]
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let canonical = CanonicalRecord(
            recordKey: record.recordKey,
            tier: record.tier.rawValue,
            targetKey: record.targetKey,
            displayName: record.displayName,
            lastCommandID: record.lastCommandID.uuidString.lowercased(),
            appTokens: try canonicalTokenStrings(record.appTokens),
            categoryTokens: try canonicalTokenStrings(record.categoryTokens),
            webDomainTokens: try canonicalTokenStrings(record.webDomainTokens),
            appliesToAll: record.appliesToAll,
            issuedAt: record.issuedAt,
            expiresAt: record.expiresAt,
            originalRequest: record.originalRequest,
            targetChildID: record.targetChildID.uuidString.lowercased(),
            sources: record.sources.map(\.rawValue).sorted()
        )
        return try encoder.encode(canonical)
    }

    private func canonicalTokenStrings<Token: Encodable & Hashable>(_ tokens: Set<Token>) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try tokens.map { token in
            try encoder.encode(token).base64EncodedString()
        }.sorted()
    }

    private func set(_ value: ShieldRecord?, at key: String, in shields: inout [String: ShieldRecord]) {
        if let value {
            shields[key] = value
        } else {
            shields.removeValue(forKey: key)
        }
    }
}
