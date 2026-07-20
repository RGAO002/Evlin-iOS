import Foundation
import FamilyControls
import ManagedSettings
import CryptoKit

/// Provenance of a `ShieldRecord` — which subsystem authored it.
/// - `.manual`: a parent/reflection-driven lock (the historical, only behavior).
/// - `.limit`: written by the per-app time-limit subsystem (P4+).
/// - `.earnedTime`: granted by the earned screen-time subsystem (B1+).
/// - `.taskPause`: written by the task-pause subsystem.
///
/// String-backed so the JSON payload is human-readable and stable across the
/// app/extension process boundary. Old persisted records predate this field;
/// decode defaults a missing `source` to `.manual` (see `extension ShieldRecord`
/// below) so legacy payloads never fail to decode (a decode failure = silent
/// shield wipe).
struct ShieldSource: Codable, Sendable, Hashable {
    let rawValue: String

    static let manual = ShieldSource(rawValue: "manual")
    static let limit = ShieldSource(rawValue: "limit")
    static let earnedTime = ShieldSource(rawValue: "earnedTime")
    static let taskPause = ShieldSource(rawValue: "taskPause")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = rawValue.isEmpty ? .manual : ShieldSource(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Single shield entry in ActiveLockStore.
/// Keyed by `recordKey` (stable across mutations). Same (tier, targetKey)
/// merges; different (tier, targetKey) coexist even if they cover the same app.
/// See spec §3.1 and §3.2.
struct ShieldRecord: Codable, Sendable, Equatable {
    /// "exactApp:<b64>" | "savedList:<listID>" | "category:social" | "allApps:<target>" | "all"
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
    /// - allApps: all three empty; appliesToAll = true; web domain categories stay unset
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

    /// Which subsystems have a stake in this record. A record may be claimed by
    /// multiple subsystems simultaneously (e.g. `.earnedTime` + `.manual` when a
    /// parent also manually locks the same app). The record is deleted only when
    /// the set is empty. Defaults to `[.manual]` so every historical construction
    /// site (and every legacy persisted payload missing both `source` and `sources`
    /// keys) keeps its original parent/reflection-lock meaning.
    var sources: Set<ShieldSource> = [.manual]

    /// C-3/D-2: record-level request to leave WEB domains open while this
    /// record's app shielding applies. Set by `ReflectionLockRecordFactory`
    /// so the embedded reflection video can load inside an all-apps lock;
    /// `ActiveShieldProjection` honors it for the web fields ONLY (apps stay
    /// fully shielded). Legacy persisted payloads have no `webOpen` key and
    /// decode as `false`, preserving their original meaning.
    var webOpen: Bool = false

    // MARK: - Helpers

    /// Derive recordKey for a tier/targetKey pair. See spec §3.2.
    ///
    /// `.savedList` lowercases its `targetKey`: that segment is always a UUID
    /// string (the backend `ChildCatalogList.id`, or the pre-sync local
    /// `UUID().uuidString`), and the two sides of the app disagreed on case —
    /// the extension writes the backend's lowercase string, while
    /// `id.uuidString` on the parent unlock path renders uppercase. Without
    /// normalizing here the two recordKeys never match and `removeSource`
    /// silently misses the dict entry, leaving an "immortal" shield (Wave-1
    /// Task 5). Other tiers are left untouched: their targetKeys are already
    /// lowercased at their call sites (bundle ids, category hints) and are not
    /// UUID-shaped, so case-folding them here would be a no-op at best and a
    /// correctness risk at worst.
    static func makeRecordKey(tier: ShieldTier, targetKey: String) -> String {
        switch tier {
        case .all: return "all"
        case .allApps: return "allApps:\(targetKey)"
        case .exactApp: return "exactApp:\(targetKey)"
        case .savedList: return "savedList:\(targetKey.lowercased())"
        case .category: return "category:\(targetKey)"
        }
    }

    /// Extract tier from a recordKey.
    static func tierFromRecordKey(_ key: String) -> ShieldTier? {
        if key == "all" { return .all }
        if key.hasPrefix("allApps:") { return .allApps }
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

    var isFullWebBroadShield: Bool {
        appliesToAll && tier == .all
    }

    func normalizedForCurrentSchema() -> (record: ShieldRecord, migrated: Bool) {
        guard tier == .all, recordKey.hasPrefix("all:reflection:") else {
            return (self, false)
        }
        return (
            ShieldRecord(
                recordKey: recordKey,
                tier: .allApps,
                targetKey: targetKey,
                displayName: displayName,
                lastCommandID: lastCommandID,
                appTokens: appTokens,
                categoryTokens: categoryTokens,
                webDomainTokens: [],
                appliesToAll: true,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                originalRequest: originalRequest,
                targetChildID: targetChildID,
                sources: sources,
                webOpen: webOpen
            ),
            true
        )
    }
}

/// Shared by the main app and DeviceActivity extension so either process
/// projects the same durable record set onto the web shield fields.
enum ShieldWebProjectionDecision: Equatable, Sendable {
    case all
    case specific
    case open

    static func resolve<S: Sequence>(records: S) -> ShieldWebProjectionDecision
    where S.Element == ShieldRecord {
        let records = Array(records)
        let broad = records.filter(\.appliesToAll)
        if broad.contains(where: \.webOpen) {
            return .open
        }
        if broad.contains(where: { $0.tier == .all }) {
            return .all
        }
        return records.contains(where: { !$0.webDomainTokens.isEmpty }) ? .specific : .open
    }
}

// MARK: - Codable (backward-compatible `source` migration)

/// Custom Codable lives in an EXTENSION on purpose: declaring `init(from:)` in
/// the struct body would suppress the synthesized MEMBERWISE init that
/// `normalizedForCurrentSchema()`, `ActiveLockStore`, the extension, and the
/// builders all rely on. Keeping it here preserves both inits.
///
/// The ONLY behavioral deviation from the synthesized Codable is `source`:
/// old persisted records have no `source` key, so we `decodeIfPresent(...) ??
/// .manual`. A hard `decode` would throw on legacy payloads and fail the whole
/// `ShieldRecord` (and the surrounding `[String: ShieldRecord]` dict) — a silent
/// wipe of a parent's active shields. Every other field decodes exactly as the
/// synthesized version would, so the on-wire format is otherwise unchanged.
extension ShieldRecord {
    private enum CodingKeys: String, CodingKey {
        case recordKey, tier, targetKey, displayName, lastCommandID
        case appTokens, categoryTokens, webDomainTokens, appliesToAll
        case issuedAt, expiresAt, originalRequest, targetChildID
        // New key written by B1+.
        case sources
        // Legacy scalar key (P4 era, pre-B1). Decoded read-only; we encode `sources`.
        case source
        // New key written by C-3; missing key decodes as `false`.
        case webOpen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Legacy-compatible sources decode:
        //   1. `sources` array present (and non-empty) → use it.
        //   2. Legacy scalar `source` present → wrap as a singleton set (preserves
        //      `.limit` / `.earnedTime` — NOT forced to `.manual`).
        //   3. Neither key present (oldest payloads) → default to `[.manual]`.
        let resolvedSources: Set<ShieldSource>
        if let set = (try? c.decodeIfPresent(Set<ShieldSource>.self, forKey: .sources)) ?? nil,
           !set.isEmpty {
            resolvedSources = set
        } else if let scalar = (try? c.decodeIfPresent(ShieldSource.self, forKey: .source)) ?? nil {
            resolvedSources = [scalar]
        } else {
            resolvedSources = [.manual]
        }

        self.init(
            recordKey: try c.decode(String.self, forKey: .recordKey),
            tier: try c.decode(ShieldTier.self, forKey: .tier),
            targetKey: try c.decode(String.self, forKey: .targetKey),
            displayName: try c.decode(String.self, forKey: .displayName),
            lastCommandID: try c.decode(UUID.self, forKey: .lastCommandID),
            appTokens: try c.decode(Set<ApplicationToken>.self, forKey: .appTokens),
            categoryTokens: try c.decode(Set<ActivityCategoryToken>.self, forKey: .categoryTokens),
            webDomainTokens: try c.decode(Set<WebDomainToken>.self, forKey: .webDomainTokens),
            appliesToAll: try c.decode(Bool.self, forKey: .appliesToAll),
            issuedAt: try c.decode(Date.self, forKey: .issuedAt),
            expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt),
            originalRequest: try c.decode(String.self, forKey: .originalRequest),
            targetChildID: try c.decode(UUID.self, forKey: .targetChildID),
            sources: resolvedSources,
            webOpen: try c.decodeIfPresent(Bool.self, forKey: .webOpen) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recordKey, forKey: .recordKey)
        try c.encode(tier, forKey: .tier)
        try c.encode(targetKey, forKey: .targetKey)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(lastCommandID, forKey: .lastCommandID)
        try c.encode(appTokens, forKey: .appTokens)
        try c.encode(categoryTokens, forKey: .categoryTokens)
        try c.encode(webDomainTokens, forKey: .webDomainTokens)
        try c.encode(appliesToAll, forKey: .appliesToAll)
        try c.encode(issuedAt, forKey: .issuedAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(originalRequest, forKey: .originalRequest)
        try c.encode(targetChildID, forKey: .targetChildID)
        // Write the new `sources` array; legacy `source` key is intentionally omitted.
        try c.encode(sources, forKey: .sources)
        try c.encode(webOpen, forKey: .webOpen)
    }
}

// MARK: - SHA-256 helper

private func sha256(_ data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
}
