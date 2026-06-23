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
}

/// Per-app daily time limit rule decoded from a `set_limit` command (P3 wire
/// decode only — enforcement/planning/execution land in later tasks).
/// `startMinute`/`endMinute` are the schedule window parsed from "HH:mm" strings
/// into minutes-since-midnight (0...1439).
struct LimitRule: Codable, Sendable, Equatable {
    let ruleId: UUID
    let dailyBudgetMinutes: Int
    let resetPolicy: String
    let startMinute: Int
    let endMinute: Int
    let timezone: String?
    let effectiveFrom: Date
    let expiresAt: Date?
    let updatedAt: Date
}

/// Payload decoded from a `clear_limit` command (P3 wire decode only).
struct ClearLimit: Codable, Sendable, Equatable {
    let ruleId: UUID
    let reason: String?
    let updatedAt: Date
}

struct CommandTarget: Codable, Sendable {
    var bundleID: String?
    var listName: String?
    var listID: UUID?                 // stable identifier for a Saved List
    var categoryHint: String?
    var targetAll: Bool = false       // true when kind=all
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
    let isBlocked: Bool
    let shieldsCovering: [ShieldCover]
    let possibleSavedListCoverage: Bool  // indeterminate — honest "May still be…" line
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
