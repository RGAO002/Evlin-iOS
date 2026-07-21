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

nonisolated struct MeteringDaemonNamespaceCount: Equatable, Sendable {
    let namespace: String
    let count: Int
}

nonisolated struct MeteringDaemonDiagnosticsSnapshot: Equatable, Sendable {
    let ownerChildDeviceID: UUID?
    let persistedOwnerChildDeviceID: UUID?
    let appMode: String
    let identityReady: Bool
    let protocolSelection: String
    let startCount: Int
    let stopNamesCount: Int
    let stopAllCount: Int
    let namespaceCounts: [MeteringDaemonNamespaceCount]
    let latestReadback: MeteringDaemonDiagnosticEntry?
    let entries: [MeteringDaemonDiagnosticEntry]

    static func make(
        ownerChildDeviceID: UUID?,
        persistedOwnerChildDeviceID: UUID?,
        appMode: String,
        localSelection: MeteringLocalProtocolSelection?,
        entries: [MeteringDaemonDiagnosticEntry]
    ) -> Self {
        let counts = Dictionary(grouping: entries) { $0.namespace ?? "unknown" }
            .map { MeteringDaemonNamespaceCount(namespace: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.namespace < $1.namespace
            }
        let newestFirst = entries.sorted { $0.sequence > $1.sequence }
        return Self(
            ownerChildDeviceID: ownerChildDeviceID,
            persistedOwnerChildDeviceID: persistedOwnerChildDeviceID,
            appMode: appMode,
            identityReady: appMode == "child"
                && ownerChildDeviceID != nil
                && ownerChildDeviceID == persistedOwnerChildDeviceID,
            protocolSelection: localSelection?.rawValue ?? "none",
            startCount: entries.count { $0.operation == .start },
            stopNamesCount: entries.count { $0.operation == .stopNames },
            stopAllCount: entries.count { $0.operation == .stopAll },
            namespaceCounts: counts,
            latestReadback: newestFirst.first { $0.operation == .readback },
            entries: newestFirst
        )
    }

    static func manualInspectionRequests(
        entries: [MeteringDaemonDiagnosticEntry]
    ) -> [MeteringDaemonInspectionRequest] {
        var latestByActivity: [String: MeteringDaemonDiagnosticEntry] = [:]
        for entry in entries where entry.operation == .start && entry.result == .success {
            guard let activityName = entry.activityName, entry.expected != nil else { continue }
            if entry.sequence > (latestByActivity[activityName]?.sequence ?? 0) {
                latestByActivity[activityName] = entry
            }
        }
        return latestByActivity.values.sorted { ($0.activityName ?? "") < ($1.activityName ?? "") }
            .compactMap { entry in
                guard let activityName = entry.activityName, let expected = entry.expected else {
                    return nil
                }
                return MeteringDaemonInspectionRequest(
                    reason: .manual,
                    process: "app",
                    activityName: activityName,
                    namespace: entry.namespace ?? "unknown",
                    armID: entry.armID,
                    expected: expected
                )
            }
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

nonisolated enum MeteringDaemonInspectionReason: String, Codable, Sendable {
    case afterArm = "after_arm"
    case configurationChanged = "configuration_changed"
    case manual
    case audit
}

nonisolated struct MeteringDaemonInspectionRequest: Sendable {
    let reason: MeteringDaemonInspectionReason
    let process: String
    let activityName: String
    let namespace: String
    let armID: UUID?
    let expected: MeteringDaemonConfigurationSummary
}

nonisolated protocol MeteringDaemonReadbackPort: Sendable {
    func configuration(activityName: String) throws -> MeteringDaemonConfigurationSummary?
}

nonisolated struct SystemMeteringDaemonReadback: MeteringDaemonReadbackPort, @unchecked Sendable {
    private let center: DeviceActivityCenter

    init(center: DeviceActivityCenter = DeviceActivityCenter()) {
        self.center = center
    }

    func configuration(activityName: String) throws -> MeteringDaemonConfigurationSummary? {
        let name = DeviceActivityName(activityName)
        guard center.activities.contains(name), let schedule = center.schedule(for: name) else {
            return nil
        }
        return MeteringDaemonConfigurationSummary.make(
            schedule: schedule,
            events: center.events(for: name)
        )
    }
}

private nonisolated enum MeteringDaemonReadbackOutcome: Sendable {
    case value(MeteringDaemonConfigurationSummary?)
    case failure(String)
}

nonisolated actor MeteringDaemonInspector {
    private let readback: any MeteringDaemonReadbackPort
    private let journal: MeteringDaemonDiagnosticJournal
    private let now: @Sendable () -> Date
    private let auditInterval: TimeInterval
    private var inspectionInFlight = false
    private var lastSuccessfulAuditAt: Date?

    init(
        readback: any MeteringDaemonReadbackPort = SystemMeteringDaemonReadback(),
        journal: MeteringDaemonDiagnosticJournal = MeteringDaemonDiagnosticJournal(),
        now: @escaping @Sendable () -> Date = { Date() },
        auditInterval: TimeInterval = 300
    ) {
        self.readback = readback
        self.journal = journal
        self.now = now
        self.auditInterval = auditInterval
    }

    func request(_ request: MeteringDaemonInspectionRequest) async {
        guard !inspectionInFlight else { return }
        let requestedAt = now()
        if request.reason == .audit,
           let lastSuccessfulAuditAt,
           requestedAt.timeIntervalSince(lastSuccessfulAuditAt) < auditInterval {
            return
        }

        inspectionInFlight = true
        defer { inspectionInFlight = false }
        let readback = self.readback
        let outcome = await Task.detached(priority: .utility) {
            do {
                return MeteringDaemonReadbackOutcome.value(
                    try readback.configuration(activityName: request.activityName)
                )
            } catch {
                return MeteringDaemonReadbackOutcome.failure(String(describing: error))
            }
        }.value

        switch outcome {
        case .value(let actual):
            if request.reason == .audit {
                lastSuccessfulAuditAt = requestedAt
            }
            let differences = actual?.differences(from: request.expected) ?? []
            let result: MeteringDiagnosticResult
            if actual == nil {
                result = .missing
            } else if differences.isEmpty {
                result = .match
            } else {
                result = .mismatch
            }
            journal.append(.init(
                timestamp: requestedAt,
                process: request.process,
                operation: .readback,
                activityName: request.activityName,
                namespace: request.namespace,
                armID: request.armID,
                expected: request.expected,
                actual: actual,
                result: result,
                mismatchReasons: differences,
                message: "reason=\(request.reason.rawValue)"
            ))
        case .failure(let message):
            journal.append(.init(
                timestamp: requestedAt,
                process: request.process,
                operation: .readback,
                activityName: request.activityName,
                namespace: request.namespace,
                armID: request.armID,
                expected: request.expected,
                actual: nil,
                result: .failure,
                mismatchReasons: [],
                message: "reason=\(request.reason.rawValue) error=\(message)"
            ))
        }
    }
}

nonisolated final class DiagnosticDeviceActivityScheduler: DeviceActivityScheduling, @unchecked Sendable {
    private let base: any DeviceActivityScheduling
    private let journal: MeteringDaemonDiagnosticJournal
    private let inspector: MeteringDaemonInspector
    private let process: String
    private let now: @Sendable () -> Date

    init(
        base: any DeviceActivityScheduling,
        journal: MeteringDaemonDiagnosticJournal = MeteringDaemonDiagnosticJournal(),
        inspector: MeteringDaemonInspector = MeteringDaemonInspector(),
        process: String = "app",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.journal = journal
        self.inspector = inspector
        self.process = process
        self.now = now
    }

    func startMonitoring(
        _ name: DeviceActivityName,
        during schedule: DeviceActivitySchedule
    ) throws {
        let expected = MeteringDaemonConfigurationSummary.make(
            schedule: schedule,
            events: [:]
        )
        do {
            try base.startMonitoring(name, during: schedule)
            appendStart(name: name, expected: expected, result: .success, message: nil)
        } catch {
            appendStart(
                name: name,
                expected: expected,
                result: .failure,
                message: String(describing: error)
            )
            throw error
        }
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        let expected = MeteringDaemonConfigurationSummary.make(
            schedule: schedule,
            events: events
        )
        do {
            try base.startMonitoring(activity, during: schedule, events: events)
            appendStart(
                name: activity,
                expected: expected,
                result: .success,
                message: nil
            )
            let request = inspectionRequest(activity: activity, expected: expected)
            Task { await inspector.request(request) }
        } catch {
            appendStart(
                name: activity,
                expected: expected,
                result: .failure,
                message: String(describing: error)
            )
            throw error
        }
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        base.stopMonitoring(activities)
        for activity in activities {
            journal.append(.init(
                timestamp: now(),
                process: process,
                operation: .stopNames,
                activityName: activity.rawValue,
                namespace: Self.namespace(for: activity.rawValue),
                armID: Self.armID(from: activity.rawValue),
                expected: nil,
                actual: nil,
                result: .success,
                mismatchReasons: [],
                message: nil
            ))
        }
    }

    func stopMonitoring() {
        base.stopMonitoring()
        journal.append(.init(
            timestamp: now(),
            process: process,
            operation: .stopAll,
            activityName: nil,
            namespace: "all",
            armID: nil,
            expected: nil,
            actual: nil,
            result: .success,
            mismatchReasons: [],
            message: "high_severity global DeviceActivity stop"
        ))
    }

    func monitoredActivities() -> [DeviceActivityName] {
        base.monitoredActivities()
    }

    private func appendStart(
        name: DeviceActivityName,
        expected: MeteringDaemonConfigurationSummary,
        result: MeteringDiagnosticResult,
        message: String?
    ) {
        journal.append(.init(
            timestamp: now(),
            process: process,
            operation: .start,
            activityName: name.rawValue,
            namespace: Self.namespace(for: name.rawValue),
            armID: Self.armID(from: name.rawValue),
            expected: expected,
            actual: nil,
            result: result,
            mismatchReasons: [],
            message: message
        ))
    }

    private func inspectionRequest(
        activity: DeviceActivityName,
        expected: MeteringDaemonConfigurationSummary
    ) -> MeteringDaemonInspectionRequest {
        .init(
            reason: .afterArm,
            process: process,
            activityName: activity.rawValue,
            namespace: Self.namespace(for: activity.rawValue),
            armID: Self.armID(from: activity.rawValue),
            expected: expected
        )
    }

    private static func namespace(for activityName: String) -> String {
        if activityName.hasPrefix("evlin.limit.v2.") { return "per_app_v2" }
        if activityName.hasPrefix("evlin.limit.window.") { return "per_app_legacy" }
        if activityName.hasPrefix("evlin.earned.") { return "earned" }
        if activityName == "evlin.bigkid.freeplay" { return "legacy_device_total" }
        if activityName.hasPrefix("evlin.command.") { return "command" }
        if activityName.hasPrefix("evlin.shield.") { return "shield" }
        if activityName.hasPrefix("evlin.block.") { return "block" }
        return "other"
    }

    private static func armID(from activityName: String) -> UUID? {
        guard activityName.hasPrefix("evlin.limit.v2.") else { return nil }
        return UUID(uuidString: String(activityName.dropFirst("evlin.limit.v2.".count)))
    }
}
#endif
