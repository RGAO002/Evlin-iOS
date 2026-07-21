#if DEBUG
import CryptoKit
import DeviceActivity
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

        init(
            name: String,
            threshold: String,
            includesPastActivity: Bool,
            applicationTokenDigests: [String],
            categoryTokenDigests: [String],
            webDomainTokenDigests: [String]
        ) {
            self.name = name
            self.threshold = threshold
            self.includesPastActivity = includesPastActivity
            self.applicationTokenDigests = applicationTokenDigests.sorted()
            self.categoryTokenDigests = categoryTokenDigests.sorted()
            self.webDomainTokenDigests = webDomainTokenDigests.sorted()
        }
    }

    let schedule: Schedule
    let events: [Event]

    init(schedule: Schedule, events: [Event]) {
        self.schedule = schedule
        self.events = events.sorted { $0.name < $1.name }
    }

    static func make(
        schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) -> Self {
        let eventValues = events.map { name, event in
            Event(
                name: name.rawValue,
                threshold: componentSummary(event.threshold),
                includesPastActivity: event.includesPastActivity,
                applicationTokenDigests: digests(event.applications),
                categoryTokenDigests: digests(event.categories),
                webDomainTokenDigests: digests(event.webDomains)
            )
        }
        return Self(
            schedule: Schedule(
                intervalStart: componentSummary(schedule.intervalStart),
                intervalEnd: componentSummary(schedule.intervalEnd),
                repeats: schedule.repeats,
                warningTime: schedule.warningTime.map(componentSummary)
            ),
            events: eventValues
        )
    }

    func differences(from expected: Self) -> [String] {
        var reasons: [String] = []
        if schedule.intervalStart != expected.schedule.intervalStart {
            reasons.append("schedule.interval_start")
        }
        if schedule.intervalEnd != expected.schedule.intervalEnd {
            reasons.append("schedule.interval_end")
        }
        if schedule.repeats != expected.schedule.repeats {
            reasons.append("schedule.repeats")
        }
        if schedule.warningTime != expected.schedule.warningTime {
            reasons.append("schedule.warning_time")
        }

        let actualByName = Dictionary(uniqueKeysWithValues: events.map { ($0.name, $0) })
        let expectedByName = Dictionary(uniqueKeysWithValues: expected.events.map { ($0.name, $0) })
        for name in expectedByName.keys.sorted() where actualByName[name] == nil {
            reasons.append("event.\(name).missing")
        }
        for name in actualByName.keys.sorted() where expectedByName[name] == nil {
            reasons.append("event.\(name).unexpected")
        }
        for name in actualByName.keys.sorted() {
            guard let actual = actualByName[name], let expectedEvent = expectedByName[name] else {
                continue
            }
            if actual.threshold != expectedEvent.threshold {
                reasons.append("event.\(name).threshold")
            }
            if actual.includesPastActivity != expectedEvent.includesPastActivity {
                reasons.append("event.\(name).includes_past")
            }
            if actual.applicationTokenDigests != expectedEvent.applicationTokenDigests {
                reasons.append("event.\(name).applications")
            }
            if actual.categoryTokenDigests != expectedEvent.categoryTokenDigests {
                reasons.append("event.\(name).categories")
            }
            if actual.webDomainTokenDigests != expectedEvent.webDomainTokenDigests {
                reasons.append("event.\(name).web_domains")
            }
        }
        return reasons
    }

    private static func componentSummary(_ components: DateComponents) -> String {
        let values: [(String, Int?)] = [
            ("era", components.era),
            ("year", components.year),
            ("month", components.month),
            ("day", components.day),
            ("hour", components.hour),
            ("minute", components.minute),
            ("second", components.second),
            ("nanosecond", components.nanosecond),
            ("weekday", components.weekday),
            ("weekdayOrdinal", components.weekdayOrdinal),
            ("quarter", components.quarter),
            ("weekOfMonth", components.weekOfMonth),
            ("weekOfYear", components.weekOfYear),
            ("yearForWeekOfYear", components.yearForWeekOfYear),
        ]
        return values.compactMap { name, value in
            value.map { "\(name)=\($0)" }
        }.joined(separator: ",")
    }

    private static func digests<T: Encodable>(_ tokens: Set<T>) -> [String] {
        tokens.compactMap { token in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(token) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.sorted()
    }
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
