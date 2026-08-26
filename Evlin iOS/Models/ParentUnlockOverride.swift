import Foundation

nonisolated enum ParentUnlockOverrideScope: String, Codable, CaseIterable, Sendable {
    case manual
    case earnedTime = "earned_time"
    case taskPause = "task_pause"
    case deviceLimit = "device_limit"
    case perAppLimit = "per_app_limit"
}

nonisolated struct ParentUnlockOverrideEnvelope: Codable, Equatable, Sendable {
    let revision: Int64
    let childDeviceID: UUID
    let usageDate: String
    let startedAt: Date
    let expiresAt: Date
    let operationID: UUID
    let scopes: Set<ParentUnlockOverrideScope>
    let cancelled: Bool

    init(
        revision: Int64,
        childDeviceID: UUID,
        usageDate: String,
        startedAt: Date,
        expiresAt: Date,
        operationID: UUID,
        scopes: Set<ParentUnlockOverrideScope>,
        cancelled: Bool
    ) {
        self.revision = revision
        self.childDeviceID = childDeviceID
        self.usageDate = usageDate
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.operationID = operationID
        self.scopes = scopes
        self.cancelled = cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case childDeviceID = "child_device_id"
        case usageDate = "usage_date"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case operationID = "operation_id"
        case scopes
        case cancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        childDeviceID = try container.decode(UUID.self, forKey: .childDeviceID)
        usageDate = try container.decode(String.self, forKey: .usageDate)
        startedAt = try Self.decodeDate(from: container, forKey: .startedAt)
        expiresAt = try Self.decodeDate(from: container, forKey: .expiresAt)
        operationID = try container.decode(UUID.self, forKey: .operationID)
        scopes = try container.decode(Set<ParentUnlockOverrideScope>.self, forKey: .scopes)
        cancelled = try container.decode(Bool.self, forKey: .cancelled)

        guard revision > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "override revision must be positive"
            )
        }
        guard !usageDate.isEmpty, expiresAt >= startedAt, !scopes.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "override identity, interval, and scopes must be valid"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(childDeviceID, forKey: .childDeviceID)
        try container.encode(usageDate, forKey: .usageDate)
        try container.encode(Self.dateFormatter.string(from: startedAt), forKey: .startedAt)
        try container.encode(Self.dateFormatter.string(from: expiresAt), forKey: .expiresAt)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(scopes, forKey: .scopes)
        try container.encode(cancelled, forKey: .cancelled)
    }

    private static func decodeDate<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Date {
        let value = try container.decode(String.self, forKey: key)
        guard let date = dateFormatter.date(from: value) ?? plainDateFormatter.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "invalid ISO-8601 override timestamp"
            )
        }
        return date
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDateFormatter = ISO8601DateFormatter()
}

nonisolated struct ParentUnlockOverrideSnapshot: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case active
        case cancelled
        case expired
    }

    let envelope: ParentUnlockOverrideEnvelope
    let status: Status

    var revision: Int64 { envelope.revision }
    var childDeviceID: UUID { envelope.childDeviceID }
    var usageDate: String { envelope.usageDate }
    var startedAt: Date { envelope.startedAt }
    var expiresAt: Date { envelope.expiresAt }
    var operationID: UUID { envelope.operationID }
    var scopes: Set<ParentUnlockOverrideScope> { envelope.scopes }

    func isActive(at now: Date) -> Bool {
        status == .active && !envelope.cancelled && now < envelope.expiresAt
    }
}

nonisolated enum ParentUnlockOverrideDisposition: Equatable, Sendable {
    case applied
    case replayed
    case superseded(currentRevision: Int64)
    case rejectedIdentity
}
