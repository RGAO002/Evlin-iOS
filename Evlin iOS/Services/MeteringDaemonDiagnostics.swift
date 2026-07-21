#if DEBUG
import Foundation

nonisolated enum MeteringDiagnosticOperation: String, Codable, Sendable {
    case start
    case stopNames = "stop_names"
    case stopAll = "stop_all"
    case readback
    case callback
}

nonisolated enum MeteringDiagnosticResult: String, Codable, Sendable {
    case success
    case failure
    case match
    case mismatch
    case missing
}

nonisolated struct MeteringDaemonConfigurationSummary: Codable, Equatable, Sendable {
    nonisolated struct Schedule: Codable, Equatable, Sendable {
        let intervalStart: String
        let intervalEnd: String
        let repeats: Bool
        let warningTime: String?
    }

    nonisolated struct Event: Codable, Equatable, Sendable {
        let name: String
        let threshold: String
        let includesPastActivity: Bool
        let applicationTokenDigests: [String]
        let categoryTokenDigests: [String]
        let webDomainTokenDigests: [String]
    }

    let schedule: Schedule
    let events: [Event]
}

nonisolated struct MeteringDaemonDiagnosticEntry: Codable, Equatable, Sendable {
    nonisolated struct Draft: Sendable {
        let timestamp: Date
        let process: String
        let operation: MeteringDiagnosticOperation
        let activityName: String?
        let namespace: String?
        let armID: UUID?
        let expected: MeteringDaemonConfigurationSummary?
        let actual: MeteringDaemonConfigurationSummary?
        let result: MeteringDiagnosticResult
        let mismatchReasons: [String]
        let message: String?
    }

    let sequence: UInt64
    let timestamp: Date
    let process: String
    let operation: MeteringDiagnosticOperation
    let activityName: String?
    let namespace: String?
    let armID: UUID?
    let expected: MeteringDaemonConfigurationSummary?
    let actual: MeteringDaemonConfigurationSummary?
    let result: MeteringDiagnosticResult
    let mismatchReasons: [String]
    let message: String?

    init(sequence: UInt64, draft: Draft) {
        self.sequence = sequence
        timestamp = draft.timestamp
        process = draft.process
        operation = draft.operation
        activityName = draft.activityName
        namespace = draft.namespace
        armID = draft.armID
        expected = draft.expected
        actual = draft.actual
        result = draft.result
        mismatchReasons = draft.mismatchReasons
        message = draft.message
    }
}

nonisolated final class MeteringDaemonDiagnosticJournal: @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        var entries: [MeteringDaemonDiagnosticEntry]
    }

    private static let storageKey = "evlin.debug.meteringDaemonJournal.v1"
    private let defaults: UserDefaults
    private let maximumEntries: Int
    private let persistenceLock: ActiveLockPersistenceLock

    init(
        defaults: UserDefaults = UserDefaults(suiteName: "group.com.evlin.ios") ?? .standard,
        maximumEntries: Int = 400,
        persistenceLock: ActiveLockPersistenceLock = .shared
    ) {
        self.defaults = defaults
        self.maximumEntries = max(1, maximumEntries)
        self.persistenceLock = persistenceLock
    }

    @discardableResult
    func append(_ draft: MeteringDaemonDiagnosticEntry.Draft) -> MeteringDaemonDiagnosticEntry? {
        persistenceLock.withLock {
            var envelope = loadLocked()
            let sequence = (envelope.entries.last?.sequence ?? 0) + 1
            let entry = MeteringDaemonDiagnosticEntry(sequence: sequence, draft: draft)
            envelope.entries.append(entry)
            if envelope.entries.count > maximumEntries {
                envelope.entries.removeFirst(envelope.entries.count - maximumEntries)
            }
            saveLocked(envelope)
            return entry
        } ?? nil
    }

    func read() -> [MeteringDaemonDiagnosticEntry] {
        persistenceLock.withLock { loadLocked().entries } ?? []
    }

    func clear() {
        _ = persistenceLock.withLock {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func exportData() -> Data {
        persistenceLock.withLock {
            encode(loadLocked()) ?? Data()
        } ?? Data()
    }

    private func loadLocked() -> Envelope {
        guard let data = defaults.data(forKey: Self.storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1
        else {
            return Envelope(version: 1, entries: [])
        }
        return envelope
    }

    private func saveLocked(_ envelope: Envelope) {
        guard let data = encode(envelope) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func encode(_ envelope: Envelope) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(envelope)
    }
}
#endif
