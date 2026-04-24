import Foundation
import FamilyControls
import ManagedSettings
import CryptoKit

/// Single shield entry in ActiveLockStore.
/// Keyed by `recordKey` (stable across mutations). Same (tier, targetKey)
/// merges; different (tier, targetKey) coexist even if they cover the same app.
/// See spec §3.1 and §3.2.
struct ShieldRecord: Codable, Sendable {
    /// "exactApp:<b64>" | "savedList:<listID>" | "category:social" | "all"
    /// Stable. Merge target.
    let recordKey: String

    /// tier + targetKey together make the recordKey.
    let tier: ShieldTier

    /// Canonical key (not a display name). See spec §3.2 table.
    let targetKey: String

    /// Display string — may be updated by user actions (e.g. list rename).
    var displayName: String

    /// Audit: which command caused the latest mutation on this record.
    var lastCommandID: UUID

    /// Selection payload. Populated per tier:
    /// - exactApp: appTokens has 1 token; categoryTokens / webDomainTokens empty
    /// - savedList: any of the three may be non-empty
    /// - category: categoryTokens has 1 token
    /// - all: all three empty; appliesToAll = true
    var appTokens: Set<ApplicationToken>
    var categoryTokens: Set<ActivityCategoryToken>
    var webDomainTokens: Set<WebDomainToken>
    var appliesToAll: Bool

    let issuedAt: Date
    var expiresAt: Date?           // nil = permanent
    let originalRequest: String     // parent's natural-language target phrase

    /// Which child device this record is scoped to. Required for multi-child families.
    var targetChildID: UUID

    // MARK: - Helpers

    /// Derive recordKey for a tier/targetKey pair. See spec §3.2.
    static func makeRecordKey(tier: ShieldTier, targetKey: String) -> String {
        switch tier {
        case .all: return "all"
        case .exactApp: return "exactApp:\(targetKey)"
        case .savedList: return "savedList:\(targetKey)"
        case .category: return "category:\(targetKey)"
        }
    }

    /// Extract tier from a recordKey.
    static func tierFromRecordKey(_ key: String) -> ShieldTier? {
        if key == "all" { return .all }
        if key.hasPrefix("exactApp:") { return .exactApp }
        if key.hasPrefix("savedList:") { return .savedList }
        if key.hasPrefix("category:") { return .category }
        return nil
    }

    /// Short SHA-256 based derived name for use in DeviceActivityName (which has length limits).
    /// See spec §3.2.
    var deviceActivityName: String {
        let data = recordKey.data(using: .utf8) ?? Data()
        let hash = sha256(data).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "evlin.shield.\(hash)"
    }
}

// MARK: - SHA-256 helper

private func sha256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
