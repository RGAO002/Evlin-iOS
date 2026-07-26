import Foundation

nonisolated enum EarnedV2CallbackJournalError: Error {
    case defaultsUnavailable
    case lockUnavailable
    case capacityExceeded
    case durableReadbackMismatch
}

nonisolated struct EarnedV2CallbackJournalEntry: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let input: MeteringAuthorizedCallbackInput
    let work: EpochSampleWork

    var key: String {
        work.request.clientSampleID
    }
}

/// A bounded callback inbox for the DeviceActivity extension.
///
/// The extension may decode the epoch root to authorize a callback, but it must
/// not re-encode that root inside Apple's callback budget. The app process
/// replays these compact facts through the same store authorization before
/// network delivery. Entries are keyed by the backend idempotency key, so a
/// crash after root import but before inbox removal is safe to replay.
nonisolated final class EarnedV2CallbackJournal: @unchecked Sendable {
    static let storageKey = "evlin.earned.v2.callbackJournal.v1"
    static let capacity = 64

    private let defaults: UserDefaults?
    private let lock: any DeviceEpochStoreLocking

    init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: MeteringProductionComposition.appGroupSuiteName
        ),
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared
    ) {
        self.defaults = defaults
        self.lock = lock
    }

    @discardableResult
    func enqueue(
        input: MeteringAuthorizedCallbackInput,
        work: EpochSampleWork
    ) throws -> EpochSampleWork {
        try withLock {
            var entries = try load()
            let candidate = EarnedV2CallbackJournalEntry(
                ownerChildDeviceID: work.ownerChildDeviceID,
                input: input,
                work: work
            )
            if let existing = entries.first(where: { $0.key == candidate.key }) {
                return existing.work
            }
            guard entries.count < Self.capacity else {
                throw EarnedV2CallbackJournalError.capacityExceeded
            }
            entries.append(candidate)
            try persist(entries)
            return work
        }
    }

    func pending(owner: UUID) throws -> [EarnedV2CallbackJournalEntry] {
        try withLock {
            try load()
                .filter { $0.ownerChildDeviceID == owner }
                .sorted {
                    if $0.input.observedAt != $1.input.observedAt {
                        return $0.input.observedAt < $1.input.observedAt
                    }
                    return $0.key < $1.key
                }
        }
    }

    /// Re-authorize every durable fact against the current root. A stale owner
    /// or route can never cross this boundary merely because it was once valid.
    @discardableResult
    func replay(into store: DeviceEpochStore, owner: UUID) throws -> Int {
        let snapshot = try withLock { try load() }
        var consumedKeys = Set<String>()
        var imported = 0

        for entry in snapshot {
            guard entry.ownerChildDeviceID == owner else {
                consumedKeys.insert(entry.key)
                continue
            }
            let result = try store.enqueueAuthorizedV2Callback(
                entry.input,
                owner: owner
            )
            switch result {
            case .queued:
                imported += 1
                consumedKeys.insert(entry.key)
            case .discarded:
                // The exact callback is terminally stale under the current
                // identity/provenance. Keeping it would retry forever.
                consumedKeys.insert(entry.key)
            }
        }

        guard !consumedKeys.isEmpty else { return imported }
        try withLock {
            let current = try load()
            try persist(current.filter { !consumedKeys.contains($0.key) })
        }
        return imported
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        var result: Result<Value, Error>?
        guard lock.withLock({ result = Result { try body() } }) != nil else {
            throw EarnedV2CallbackJournalError.lockUnavailable
        }
        return try result!.get()
    }

    private func load() throws -> [EarnedV2CallbackJournalEntry] {
        guard let defaults else {
            throw EarnedV2CallbackJournalError.defaultsUnavailable
        }
        _ = defaults.synchronize()
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        guard let entries = try? Self.decoder.decode(
            [EarnedV2CallbackJournalEntry].self,
            from: data
        ) else {
            throw EarnedV2CallbackJournalError.durableReadbackMismatch
        }
        guard Set(entries.map(\.key)).count == entries.count else {
            throw EarnedV2CallbackJournalError.durableReadbackMismatch
        }
        return entries
    }

    private func persist(_ entries: [EarnedV2CallbackJournalEntry]) throws {
        guard let defaults else {
            throw EarnedV2CallbackJournalError.defaultsUnavailable
        }
        guard entries.count <= Self.capacity,
              Set(entries.map(\.key)).count == entries.count
        else {
            throw EarnedV2CallbackJournalError.durableReadbackMismatch
        }
        let data = try Self.encoder.encode(entries)
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.synchronize(),
              defaults.data(forKey: Self.storageKey) == data
        else {
            throw EarnedV2CallbackJournalError.durableReadbackMismatch
        }
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

/// The Phase 3 physical-time upper bound shared by earned and per-app callbacks.
/// It deliberately has no lower-bound age check, so delayed valid callbacks stay
/// eligible while impossible immediate thresholds are rejected.
nonisolated enum MeteringCallbackPhysicalTime {
    static let defaultJitterSeconds = MeteringEpochContract.defaultJitterSeconds
    static let maximumJitterSeconds = MeteringEpochContract.maximumJitterSeconds

    static func allows(
        adjustedEstimateMinutes: Int,
        baseAcceptedMinutes: Int,
        startedAt: Date,
        observedAt: Date,
        jitterSeconds: Int = defaultJitterSeconds
    ) -> Bool {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let epoch = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        return MeteringEpochContract.callbackVerdict(
            MeteringCallbackInput(
                activeEpochID: epoch,
                callbackEpochID: epoch,
                activeOwnerDeviceID: owner,
                callbackOwnerDeviceID: owner,
                activeUsageDate: "physical-time",
                callbackUsageDate: "physical-time",
                activePolicyRevision: "physical-time",
                callbackPolicyRevision: "physical-time",
                expectedEventNamespace: "physical-time",
                callbackEventNamespace: "physical-time",
                adjustedEstimateMinutes: adjustedEstimateMinutes,
                baseAcceptedMinutes: baseAcceptedMinutes,
                startedAt: startedAt,
                callbackAt: observedAt,
                jitterSeconds: jitterSeconds
            )
        ) == .accept
    }
}

nonisolated enum EarnedMeteringCallbackOutcome: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case discarded(reason: String)
}

/// Names-only DeviceActivity callbacks cross this boundary before they can
/// affect durable metering state. Network delivery and shield effects are
/// intentionally outside this type.
nonisolated final class EarnedMeteringCallback: @unchecked Sendable {
    static let defaultJitterSeconds = MeteringCallbackPhysicalTime.defaultJitterSeconds
    static let maximumJitterSeconds = MeteringCallbackPhysicalTime.maximumJitterSeconds

    private let store: DeviceEpochStore
    private let clock: any MeteringClock
    private let jitterSeconds: Int?
    private let journal: EarnedV2CallbackJournal

    init(
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        jitterSeconds: Int = defaultJitterSeconds,
        journal: EarnedV2CallbackJournal = EarnedV2CallbackJournal()
    ) {
        self.store = store
        self.clock = clock
        self.jitterSeconds = (0...Self.maximumJitterSeconds).contains(jitterSeconds) ? jitterSeconds : nil
        self.journal = journal
    }

    /// Non-terminal DeviceActivity callbacks use a compact durable inbox. This
    /// preserves the exact authorization contract without rewriting the whole
    /// control-plane root inside Apple's extension callback budget.
    func handleDurably(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID
    ) throws -> EarnedMeteringCallbackOutcome {
        guard let input = callbackInput(callback) else {
            return .discarded(reason: jitterSeconds == nil ? "invalid_jitter" : "malformed_route")
        }

        let prepared = try store.prepareAuthorizedV2Callback(
            input,
            owner: expectedOwnerChildDeviceID
        )
        guard case .queued = prepared.result, let work = prepared.work else {
            return try handle(
                callback,
                expectedOwnerChildDeviceID: expectedOwnerChildDeviceID
            )
        }
        do {
            let persisted = try journal.enqueue(input: input, work: work)
            return .queued(sampleWorkID: persisted.workID)
        } catch {
            // Durability is mandatory. If the bounded inbox itself is
            // unavailable, retain the old verified root transaction as a
            // conservative fallback rather than silently losing the callback.
            return try handle(
                callback,
                expectedOwnerChildDeviceID: expectedOwnerChildDeviceID
            )
        }
    }

    func handle(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID,
        preparedShieldReference: EarnedShieldReference? = nil
    ) throws -> EarnedMeteringCallbackOutcome {
        guard let input = callbackInput(callback) else {
            return .discarded(reason: jitterSeconds == nil ? "invalid_jitter" : "malformed_route")
        }

        let result = try store.enqueueAuthorizedV2Callback(
            input,
            owner: expectedOwnerChildDeviceID,
            preparedShieldReference: preparedShieldReference
        )
        switch result {
        case .queued(let sampleWorkID): return .queued(sampleWorkID: sampleWorkID)
        case .discarded(let reason): return .discarded(reason: reason)
        }
    }

    func terminalCandidate(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID
    ) throws -> MeteringTerminalShieldCandidate? {
        guard let input = callbackInput(callback) else { return nil }
        return try store.terminalShieldCandidate(
            input,
            owner: expectedOwnerChildDeviceID
        )
    }

    private func callbackInput(
        _ callback: MeteringAppleCallback
    ) -> MeteringAuthorizedCallbackInput? {
        guard let jitterSeconds,
              let parsed = MeteringRouteNamespace.parse(
                  activityName: callback.activityName,
                  eventName: callback.eventName
              )
        else { return nil }
        return MeteringAuthorizedCallbackInput(
            routeID: parsed.routeID,
            activityName: callback.activityName,
            eventName: callback.eventName,
            namespace: MeteringRouteNamespace.prefix,
            thresholdMinutes: parsed.thresholdMinutes,
            observedAt: callback.observedAt,
            now: clock.now,
            jitterSeconds: jitterSeconds
        )
    }
}
