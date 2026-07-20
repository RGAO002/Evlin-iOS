import Foundation

nonisolated enum AppLimitEffectJournalError: Error, Equatable {
    case defaultsUnavailable
    case lockUnavailable
    case durableReadbackMismatch
    case invalidLease
}

nonisolated protocol AppLimitShieldPersistenceStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func synchronize() -> Bool
}

extension UserDefaults: AppLimitShieldPersistenceStore {}

nonisolated struct AppLimitShieldPersistence {
    private let store: (any AppLimitShieldPersistenceStore)?
    private let storageKey: String

    init(
        store: (any AppLimitShieldPersistenceStore)?,
        storageKey: String = "evlin.shieldRecords"
    ) {
        self.store = store
        self.storageKey = storageKey
    }

    func load() throws -> [String: ShieldRecord] {
        guard let store else { throw AppLimitEffectJournalError.defaultsUnavailable }
        guard store.synchronize() else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        guard let data = store.data(forKey: storageKey) else { return [:] }
        let decoded: [String: ShieldRecord]
        if let json = try? Self.decoder.decode([String: ShieldRecord].self, from: data) {
            decoded = json
        } else if let legacy = try? PropertyListDecoder().decode(
            [String: ShieldRecord].self,
            from: data
        ) {
            decoded = legacy
        } else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        let normalized = decoded.mapValues { $0.normalizedForCurrentSchema().record }
        guard normalized.allSatisfy({ $0.key == $0.value.recordKey }) else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        return normalized
    }

    func persist(_ shields: [String: ShieldRecord]) throws {
        guard let store else { throw AppLimitEffectJournalError.defaultsUnavailable }
        let data = try Self.encoder.encode(shields)
        store.set(data, forKey: storageKey)
        guard store.synchronize(), store.data(forKey: storageKey) == data else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        let readback = try load()
        guard readback.count == shields.count,
              readback.allSatisfy({ $0.key == $0.value.recordKey })
        else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Durable callback effects keyed to the exact rule version and arm that the
/// Task 13 validator accepted. Every commit rechecks the epoch store while the
/// shared ActiveLock lock is held.
nonisolated final class AppLimitEffectJournal: @unchecked Sendable {
    static let storageKey = "evlin.appLimitEffectJournal.v1"

    private let defaults: UserDefaults?
    private let epochStore: AppLimitEpochStore
    private let lock: ActiveLockPersistenceLock
    private let afterLocalMutation: () throws -> Void

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        epochStore: AppLimitEpochStore = .shared,
        lock: ActiveLockPersistenceLock = .shared,
        afterLocalMutation: @escaping () throws -> Void = {}
    ) {
        self.defaults = defaults
        self.epochStore = epochStore
        self.lock = lock
        self.afterLocalMutation = afterLocalMutation
    }

    @discardableResult
    func enqueue(
        _ callback: AppLimitValidatedCallback,
        now: Date = Date()
    ) throws -> AppLimitEffectEnvelope {
        try withLock {
            var effects = try load()
            let key = AppLimitEffectKey(
                ruleID: callback.rule.id,
                orderingToken: callback.provenance.ruleRevision,
                armID: callback.provenance.armID,
                effectKind: Self.journalKind(callback.effectKind),
                rawThresholdMinutes: callback.rawThresholdMinutes
            )
            if let existing = effects[key.storageKey] { return existing }
            guard try isCurrent(callback) else {
                throw AppLimitEffectJournalError.durableReadbackMismatch
            }
            let effect = AppLimitEffectEnvelope(
                key: key,
                rule: callback.rule,
                provenance: callback.provenance,
                adjustedEstimateMinutes: callback.adjustedEstimateMinutes,
                createdAt: now,
                lease: nil,
                localReceipt: nil,
                usageReceipt: nil,
                backendRejection: nil
            )
            effects[key.storageKey] = effect
            try persist(effects)
            return effect
        }
    }

    func pendingEffects() throws -> [AppLimitEffectEnvelope] {
        try withLock { try sorted(load().values) }
    }

    func effect(for key: AppLimitEffectKey) throws -> AppLimitEffectEnvelope? {
        try withLock { try load()[key.storageKey] }
    }

    func claimNext(
        workerID: UUID,
        now: Date = Date(),
        leaseDuration: TimeInterval = 60
    ) throws -> AppLimitEffectClaim? {
        try withLock {
            var effects = try load()
            var changed = false
            for candidate in sorted(effects.values) {
                guard try isCurrent(candidate.callback) else {
                    effects.removeValue(forKey: candidate.key.storageKey)
                    changed = true
                    continue
                }
                guard candidate.usageReceipt == nil,
                      candidate.backendRejection == nil
                else { continue }
                if let retryNotBefore = candidate.retryNotBefore,
                   retryNotBefore > now {
                    continue
                }
                if let lease = candidate.lease, lease.expiresAt > now { continue }
                var claimed = candidate
                let lease = AppLimitEffectLease(
                    leaseID: UUID(),
                    workerID: workerID,
                    claimedAt: now,
                    expiresAt: now.addingTimeInterval(leaseDuration)
                )
                claimed.lease = lease
                claimed.retryNotBefore = nil
                effects[candidate.key.storageKey] = claimed
                try persist(effects)
                return AppLimitEffectClaim(effect: claimed, lease: lease)
            }
            if changed { try persist(effects) }
            return nil
        }
    }

    /// The caller's synchronous mutation runs inside the shared persistence
    /// lock, after the final epoch/arm/lease check and before durable receipt
    /// write/readback.
    @discardableResult
    func applyLocal(
        _ claim: AppLimitEffectClaim,
        source: String,
        appliedAt: Date = Date(),
        mutation: (AppLimitValidatedCallback) throws -> Void
    ) throws -> AppLimitLocalEffectReceipt? {
        try withLock {
            var effects = try load()
            guard var current = effects[claim.effect.key.storageKey] else { return nil }
            guard try isCurrent(current.callback) else {
                effects.removeValue(forKey: current.key.storageKey)
                try persist(effects)
                return nil
            }
            guard Self.matchesLease(current.lease, claim.lease) else {
                throw AppLimitEffectJournalError.invalidLease
            }
            if let receipt = current.localReceipt { return receipt }
            try mutation(current.callback)
            try afterLocalMutation()
            let receipt = AppLimitLocalEffectReceipt(
                key: current.key,
                source: source,
                appliedAt: appliedAt
            )
            current.localReceipt = receipt
            effects[current.key.storageKey] = current
            try persist(effects)
            guard let readback = try load()[current.key.storageKey]?.localReceipt,
                  readback.key == receipt.key,
                  readback.source == receipt.source
            else {
                throw AppLimitEffectJournalError.durableReadbackMismatch
            }
            return receipt
        }
    }

    /// Transport runs without the persistence lock. The response is committed
    /// only after re-entering the lock and repeating the exact epoch/arm/lease
    /// comparison.
    func submitUsage(
        _ claim: AppLimitEffectClaim,
        baseURL: URL,
        deviceID: UUID,
        transport: any MeteringHTTPTransport = URLSession.shared,
        appliedAt: Date = Date()
    ) async throws -> AppLimitUsageEffectReceipt? {
        let callback: AppLimitValidatedCallback? = try withLock {
            let effects = try load()
            guard let current = effects[claim.effect.key.storageKey],
                  Self.matchesLease(current.lease, claim.lease),
                  current.usageReceipt == nil,
                  current.backendRejection == nil,
                  try isCurrent(current.callback)
            else { return nil }
            return current.callback
        }
        guard let callback else { return nil }

        let response = try await AppLimitUsageReporter.submit(
            baseURL: baseURL,
            deviceID: deviceID,
            callback: callback,
            transport: transport,
            observedAt: appliedAt
        )

        return try withLock {
            var effects = try load()
            guard var current = effects[claim.effect.key.storageKey] else { return nil }
            guard try isCurrent(current.callback) else {
                effects.removeValue(forKey: current.key.storageKey)
                try persist(effects)
                return nil
            }
            guard Self.matchesLease(current.lease, claim.lease) else { return nil }
            if let receipt = current.usageReceipt { return receipt }

            if !response.accepted, response.reason == "future_ordering_token" {
                let attempt = min((current.retryAttemptCount ?? 0) + 1, 10)
                current.retryAttemptCount = attempt
                current.retryNotBefore = appliedAt.addingTimeInterval(
                    Self.retryDelay(attempt: attempt)
                )
                current.lease = nil
                effects[current.key.storageKey] = current
                try persist(effects)
                return nil
            }

            guard response.accepted,
                  response.currentOrderingToken == current.key.orderingToken
            else {
                current.backendRejection = AppLimitBackendRejection(
                    currentOrderingToken: response.currentOrderingToken,
                    reason: response.reason ?? "authoritative_token_mismatch",
                    rejectedAt: appliedAt
                )
                current.lease = nil
                effects[current.key.storageKey] = current
                try persist(effects)
                return nil
            }

            let receipt = AppLimitUsageEffectReceipt(
                key: current.key,
                usedMinutes: response.usedMinutes,
                currentOrderingToken: response.currentOrderingToken,
                appliedAt: appliedAt
            )
            current.usageReceipt = receipt
            current.lease = nil
            current.retryNotBefore = nil
            current.retryAttemptCount = nil
            effects[current.key.storageKey] = current
            try persist(effects)
            guard let readback = try load()[current.key.storageKey]?.usageReceipt,
                  readback.key == receipt.key,
                  readback.usedMinutes == receipt.usedMinutes,
                  readback.currentOrderingToken == receipt.currentOrderingToken
            else {
                throw AppLimitEffectJournalError.durableReadbackMismatch
            }
            return receipt
        }
    }

    private func isCurrent(_ callback: AppLimitValidatedCallback) throws -> Bool {
        let state = try epochStore.read()
        guard state.ownerChildDeviceID == callback.provenance.childDeviceID,
              let slot = state.slots[callback.rule.id],
              slot.latestKind == .set,
              slot.latestOrderingToken == callback.provenance.ruleRevision,
              slot.activeRule == callback.rule,
              let provenance = slot.armProvenance
        else { return false }
        return provenance.ruleID == callback.provenance.ruleID
            && provenance.ruleRevision == callback.provenance.ruleRevision
            && provenance.armID == callback.provenance.armID
            && provenance.activityName == callback.provenance.activityName
            && provenance.replacementKey == callback.provenance.replacementKey
            && provenance.startedAt == callback.provenance.startedAt
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        var result: Result<Value, Error>?
        guard lock.withLock({ result = Result { try body() } }) != nil else {
            throw AppLimitEffectJournalError.lockUnavailable
        }
        return try result!.get()
    }

    private func load() throws -> [String: AppLimitEffectEnvelope] {
        guard let defaults else { throw AppLimitEffectJournalError.defaultsUnavailable }
        defaults.synchronize()
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        guard let values = try? Self.decoder.decode([AppLimitEffectEnvelope].self, from: data)
        else { throw AppLimitEffectJournalError.durableReadbackMismatch }
        let keyed = Dictionary(uniqueKeysWithValues: values.map { ($0.key.storageKey, $0) })
        guard keyed.count == values.count else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        return keyed
    }

    private func persist(_ effects: [String: AppLimitEffectEnvelope]) throws {
        guard let defaults else { throw AppLimitEffectJournalError.defaultsUnavailable }
        guard effects.allSatisfy({ $0.key == $0.value.key.storageKey }) else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        let values = sorted(effects.values)
        let data = try Self.encoder.encode(values)
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.synchronize(), defaults.data(forKey: Self.storageKey) == data else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
        let readback = try load()
        guard readback.count == effects.count,
              readback.allSatisfy({ $0.key == $0.value.key.storageKey })
        else {
            throw AppLimitEffectJournalError.durableReadbackMismatch
        }
    }

    private func sorted<S: Sequence>(
        _ effects: S
    ) -> [AppLimitEffectEnvelope] where S.Element == AppLimitEffectEnvelope {
        effects.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.key.storageKey < $1.key.storageKey
        }
    }

    private static func journalKind(
        _ kind: AppLimitCallbackEffectKind
    ) -> AppLimitJournalEffectKind {
        switch kind {
        case .measurement: .measurement
        case .enforcement: .enforcement
        }
    }

    private static func retryDelay(attempt: Int) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 6)
        return min(300, 5 * pow(2, Double(exponent)))
    }

    private static func matchesLease(
        _ persisted: AppLimitEffectLease?,
        _ claimed: AppLimitEffectLease
    ) -> Bool {
        persisted?.leaseID == claimed.leaseID
            && persisted?.workerID == claimed.workerID
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

private extension AppLimitEffectEnvelope {
    var callback: AppLimitValidatedCallback {
        let kind: AppLimitCallbackEffectKind = key.effectKind == .measurement
            ? .measurement
            : .enforcement
        return AppLimitValidatedCallback(
            rule: rule,
            provenance: provenance,
            effectKind: kind,
            rawThresholdMinutes: key.rawThresholdMinutes,
            adjustedEstimateMinutes: adjustedEstimateMinutes
        )
    }
}

extension LimitShieldLogic {
    static func applyingLimit(
        to shields: [String: ShieldRecord],
        callback: AppLimitValidatedCallback,
        now: Date
    ) -> [String: ShieldRecord] {
        let rule = callback.rule
        let key = recordKey(for: rule)
        let provenance = callback.provenance
        var record = ShieldRecord(
            recordKey: key,
            tier: .exactApp,
            targetKey: targetKey(for: rule),
            displayName: rule.displayName,
            lastCommandID: rule.id,
            appTokens: rule.appTokens,
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: now,
            expiresAt: nil,
            originalRequest: [
                "app limit reached",
                "rule_id=\(rule.id.uuidString.lowercased())",
                "ordering_token=\(provenance.ruleRevision)",
                "arm_id=\(provenance.armID.uuidString.lowercased())",
            ].joined(separator: " "),
            targetChildID: provenance.childDeviceID,
            sources: [.limit]
        )
        if let existing = shields[key] {
            record.sources.formUnion(existing.sources)
        }
        var updated = shields
        updated[key] = record
        return updated
    }
}
