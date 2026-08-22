import Foundation

/// Chat-level action verbs. See spec §7.
/// Legacy lock/unlock/lockAll/unlockAll are aliased during migration (Phase 11).
enum CommandAction: String, Codable, Sendable {
    case shield
    case block
    case unshield
    case unblock
    case unshieldAll = "unshield_all"
    case unblockAll = "unblock_all"
    case expandLibrary = "expand_library"
    case setLimit = "set_limit"
    case clearLimit = "clear_limit"
    /// A4: same-day pool/cap change sync from the backend. Handled inline in
    /// CommandPoller; never reaches ActionExecutor.
    case earnedTimeConfig = "earned_time_config"
    case meteringRearm = "metering_rearm"
}

enum OrderingTokenDecoding {
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Int64 {
        let token = try container.decode(Int64.self, forKey: key)
        guard token > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "ordering_token must be a positive Int64"
            )
        }
        return token
    }
}

enum CommandTimestampDecoding {
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlainFormatter = ISO8601DateFormatter()

    static func parse(_ value: String) -> Date? {
        isoFractionalFormatter.date(from: value) ?? isoPlainFormatter.date(from: value)
    }

    static func issuedAt(from value: String) -> Date {
        parse(value) ?? Date(timeIntervalSince1970: 0)
    }
}

struct EarnedTimeConfigSelectedSet: Codable, Sendable, Equatable {
    let list_id: String?
    let recordKey: String?
    let targetKey: String?
    let has_tokens: Bool?
}

/// Shared wire model for `earned_time_config`. Both foreground polling and the
/// push extension decode this exact type so policy authority cannot drift.
struct EarnedTimeConfigCommand: Codable, Sendable, Equatable {
    let child_profile_id: String?
    let child_device_id: String?
    let effective_date: String?
    let usage_date: String?
    let timezone: String?
    let policy_revision: String?
    let orderingToken: Int64?
    let daily_pool_minutes: Int
    let device_cap_minutes: Int
    let earned_bucket_minutes: Int?
    let remaining_minutes: Int?
    /// Server-authoritative: does a same-day exhaustion override still stand?
    /// The device must not infer this from pool deltas — it compares a
    /// different baseline than the server does and can read a lowering as a
    /// raise. Nil only for payloads predating the field.
    let override_active: Bool?
    let selected_set: EarnedTimeConfigSelectedSet?

    private enum CodingKeys: String, CodingKey {
        case child_profile_id
        case child_device_id
        case effective_date
        case usage_date
        case timezone
        case policy_revision
        case orderingToken = "ordering_token"
        case daily_pool_minutes
        case device_cap_minutes
        case earned_bucket_minutes
        case remaining_minutes
        case override_active
        case selected_set
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        child_profile_id = try container.decodeIfPresent(String.self, forKey: .child_profile_id)
        child_device_id = try container.decodeIfPresent(String.self, forKey: .child_device_id)
        effective_date = try container.decodeIfPresent(String.self, forKey: .effective_date)
        usage_date = try container.decodeIfPresent(String.self, forKey: .usage_date)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
        policy_revision = try container.decodeIfPresent(String.self, forKey: .policy_revision)
        if container.contains(.orderingToken),
           try !container.decodeNil(forKey: .orderingToken) {
            orderingToken = try OrderingTokenDecoding.decode(
                from: container,
                forKey: .orderingToken
            )
        } else {
            orderingToken = nil
        }
        daily_pool_minutes = try container.decode(Int.self, forKey: .daily_pool_minutes)
        device_cap_minutes = try container.decode(Int.self, forKey: .device_cap_minutes)
        earned_bucket_minutes = try container.decodeIfPresent(Int.self, forKey: .earned_bucket_minutes)
        remaining_minutes = try container.decodeIfPresent(Int.self, forKey: .remaining_minutes)
        override_active = try container.decodeIfPresent(Bool.self, forKey: .override_active)
        selected_set = try container.decodeIfPresent(
            EarnedTimeConfigSelectedSet.self,
            forKey: .selected_set
        )
    }
}

/// Per-app daily time limit rule decoded from a `set_limit` command (P3 wire
/// decode only — enforcement/planning/execution land in later tasks).
/// `startMinute`/`endMinute` are the schedule window parsed from "HH:mm" strings
/// into minutes-since-midnight (0...1439).
struct LimitRule: Codable, Sendable, Equatable {
    let ruleId: UUID
    let orderingToken: Int64
    let dailyBudgetMinutes: Int
    let resetPolicy: String
    let startMinute: Int
    let endMinute: Int
    let timezone: String?
    let effectiveFrom: Date
    let expiresAt: Date?
    let updatedAt: Date
    let usedTodayMinutes: Int?

    init(
        ruleId: UUID,
        orderingToken: Int64 = 1,
        dailyBudgetMinutes: Int,
        resetPolicy: String,
        startMinute: Int,
        endMinute: Int,
        timezone: String?,
        effectiveFrom: Date,
        expiresAt: Date?,
        updatedAt: Date,
        usedTodayMinutes: Int? = nil
    ) {
        self.ruleId = ruleId
        self.orderingToken = orderingToken
        self.dailyBudgetMinutes = dailyBudgetMinutes
        self.resetPolicy = resetPolicy
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timezone = timezone
        self.effectiveFrom = effectiveFrom
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
        self.usedTodayMinutes = usedTodayMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case ruleId
        case orderingToken = "ordering_token"
        case dailyBudgetMinutes
        case resetPolicy
        case startMinute
        case endMinute
        case timezone
        case effectiveFrom
        case expiresAt
        case updatedAt
        case usedTodayMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleId = try container.decode(UUID.self, forKey: .ruleId)
        orderingToken = try OrderingTokenDecoding.decode(from: container, forKey: .orderingToken)
        dailyBudgetMinutes = try container.decode(Int.self, forKey: .dailyBudgetMinutes)
        resetPolicy = try container.decode(String.self, forKey: .resetPolicy)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
        effectiveFrom = try container.decode(Date.self, forKey: .effectiveFrom)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        usedTodayMinutes = try container.decodeIfPresent(Int.self, forKey: .usedTodayMinutes)
    }
}

/// Payload decoded from a `clear_limit` command (P3 wire decode only).
struct ClearLimit: Codable, Sendable, Equatable {
    let ruleId: UUID
    let orderingToken: Int64
    let reason: String?
    let updatedAt: Date

    init(
        ruleId: UUID,
        orderingToken: Int64 = 1,
        reason: String?,
        updatedAt: Date
    ) {
        self.ruleId = ruleId
        self.orderingToken = orderingToken
        self.reason = reason
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case ruleId
        case orderingToken = "ordering_token"
        case reason
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleId = try container.decode(UUID.self, forKey: .ruleId)
        orderingToken = try OrderingTokenDecoding.decode(from: container, forKey: .orderingToken)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct CommandTarget: Codable, Sendable {
    var bundleID: String?
    var listName: String?
    var listID: UUID?                 // stable identifier for a Saved List
    var categoryHint: String?
    var targetAll: Bool = false       // true when kind=all
    // Task 3 (paper-lock fix): true when the backend's `all_selected` flag
    // (Task 1/2 plumbing) says the kid's saved-list selection was "all apps
    // and categories" at upload time. Distinct from `targetAll`, which marks
    // the unrelated kind=all tier. Optional because most commands (and all
    // pre-Task-1 backends) never send this key.
    var allSelected: Bool? = nil
    // Default-lock-group identity: true when the backend says this savedList
    // command targets the device's one default "Locked set" (as opposed to an
    // arbitrary parent-named custom list). Lets the device adopt lockedSetID
    // from the lock command itself — a fresh family locks before any
    // earned_time_config ever carried the list id. Optional: older backends
    // never send this key.
    var defaultLockGroup: Bool? = nil
    var originalRequest: String
    var targetDisplay: String?
    var targetChildID: UUID?          // for multi-child
    var hasPendingBlob: Bool = false

    // Parent's confirmed-downgrade re-submission: when the parent taps "Change to X min"
    // on a B1 card, the /parent/chat follow-up sets `force_downgrade=true`. Child's
    // ActiveLockStore.addShield then skips the merge rule for this (tier, targetKey).
    // See spec §5.2 B1 flow and plan Phase 6/9 changes.
    var forceDowngrade: Bool = false

    // Canonical backend catalog-lock payloads. These preserve the existing
    // local-alias and pending-blob fallbacks while allowing direct token execute.
    var catalogTokenDataBase64: String? = nil
    var catalogCategoryTokenDataBase64: String? = nil
    var catalogApplicationTokenDataBase64s: [String] = []
    var catalogCategoryTokenDataBase64s: [String] = []

    // B2: lock-source provenance. Wire snake value ("earned_time"|"manual").
    var lockSource: String? = nil
    // B2: for unshield commands — which sources to remove. Wire snake values.
    var unlockSources: [String]? = nil
    // Backend-canonical day for an explicit earned-time override.
    var earnedOverrideUsageDate: String? = nil
}

struct LockCommand: Codable, Sendable, Identifiable {
    let id: UUID                   // command_id
    let action: CommandAction
    let tier: ShieldTier?          // nil for unshield_all, unblock_all, expand_library
    let target: CommandTarget
    let durationMinutes: Int?      // nil = permanent
    let issuedAt: Date
    // Per-app time-limit payloads (P3). Nil for all non-limit commands. Budget
    // intentionally does NOT flow through durationMinutes/expiresAt.
    var limit: LimitRule? = nil
    var clear: ClearLimit? = nil
    var earnedTimeConfig: EarnedTimeConfigCommand? = nil
    // B2: provenance carried from CommandTarget for convenience access.
    var lockSource: String? { target.lockSource }
    var unlockSources: [String]? { target.unlockSources }
    var expiresAt: Date? {
        guard let m = durationMinutes else { return nil }
        return issuedAt.addingTimeInterval(TimeInterval(m * 60))
    }
}

/// Which verb was executed — drives receipt copy so success of
/// `block Instagram` doesn't render as "Shielded Instagram".
enum AckVerb: String, Codable, Sendable, Equatable {
    case shield
    case block
    case unshield
    case unblock
    case unshieldAll = "unshield_all"
    case unblockAll = "unblock_all"
    case setLimit = "set_limit"
    case clearLimit = "clear_limit"
}

/// Child-computed snapshot of effective coverage after the mutation, so the
/// parent's ReceiptCard can render the "Still shielded by / May still be in
/// a Saved List" honest-disclosure line. Serialized inside AckResult.
///
/// Shape mirrors `EffectiveState` from ActiveLockStore (Phase 2) but uses
/// JSON-friendly primitives.
struct AckEffectiveState: Codable, Sendable, Equatable {
    struct ShieldCover: Codable, Sendable, Equatable {
        let displayName: String
        let expiresAtISO: String?      // nil = permanent
        let tier: String               // ShieldTier rawValue
        // B7: identity + provenance fields (optional for back-compat with old binaries)
        let recordKey: String?         // e.g. "savedList:<listID>"
        let targetKey: String?         // e.g. "<listID>"
        let sources: [String]?         // ShieldSource rawValues: "manual"/"limit"/"earnedTime"

        // Memberwise init with defaults for back-compat callers that don't pass the new fields.
        init(
            displayName: String,
            expiresAtISO: String?,
            tier: String,
            recordKey: String? = nil,
            targetKey: String? = nil,
            sources: [String]? = nil
        ) {
            self.displayName = displayName
            self.expiresAtISO = expiresAtISO
            self.tier = tier
            self.recordKey = recordKey
            self.targetKey = targetKey
            self.sources = sources
        }
    }
    struct BlockEntry: Codable, Sendable, Equatable {
        let bundleID: String
        let displayName: String
    }

    let isBlocked: Bool
    let shieldsCovering: [ShieldCover]
    let possibleSavedListCoverage: Bool  // indeterminate — honest "May still be…" line
    /// Full per-app block list (B.1-A1). Optional for back-compat with old
    /// binaries whose payloads only carried `isBlocked`.
    let blocks: [BlockEntry]?

    // Explicit init with a defaulted `blocks:` so the 7 pre-B.1 construction
    // sites (ActionExecutor + tests) compile unchanged — same pattern as
    // ShieldCover's back-compat init above.
    init(
        isBlocked: Bool,
        shieldsCovering: [ShieldCover],
        possibleSavedListCoverage: Bool,
        blocks: [BlockEntry]? = nil
    ) {
        self.isBlocked = isBlocked
        self.shieldsCovering = shieldsCovering
        self.possibleSavedListCoverage = possibleSavedListCoverage
        self.blocks = blocks
    }
}

/// Extended AckResult.
/// * `confirmedExact` / `confirmedFallback` carry `verb` so ReceiptCard can render
///   verb-appropriate copy (Shielded / Hidden / Unshielded / Restored / Unblocked).
/// * Both success cases carry an optional `effectiveState` computed on the child
///   after the mutation, so the parent receipt can show coverage disclosure.
/// * `pendingConfirmation` case added for B1-style flows where the child device
///   needs parent confirmation (B1 downgrade).
enum AckResult: Codable, Sendable, Equatable {
    case confirmedExact(verb: AckVerb, displayName: String, effectiveState: AckEffectiveState?)
    case confirmedFallback(verb: AckVerb, displayName: String, category: String, origRequest: String, effectiveState: AckEffectiveState?)
    case pendingConfirmation(cardID: String, context: [String: String])
    case failed(AckFailure)
}

enum AckFailure: Codable, Sendable, Equatable {
    case notAuthorized
    case listNotFound(String)
    case categoryNotConfigured(String)
    case applicationNotConfigured(String)
    case nothingToUnlock
    case malformed
    case execution(String)
    /// Per-app limit could not be scheduled because the requested schedule needs
    /// more DeviceActivity windows than the OS cap allows (P3 ack wire only).
    case limitQuotaExceeded(windows: Int, slotsNeeded: Int, cap: Int)
}
