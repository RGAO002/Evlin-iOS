import Foundation
import FamilyControls
import ManagedSettings

/// The time window during which a per-app limit's budget applies. Minutes are
/// minutes-since-midnight in the rule's `timezone` (0...1439). A 0→1439 window
/// that `repeats` is "every day, all day".
struct AppLimitWindow: Codable, Sendable, Equatable {
    /// Minutes since local midnight the window opens (0...1439).
    let startMinute: Int
    /// Minutes since local midnight the window closes (0...1439).
    let endMinute: Int
    /// Whether the window recurs each day.
    let repeats: Bool
    /// IANA tz id (e.g. "America/Los_Angeles"). Nil = device-local time.
    let timezone: String?
}

/// One per-app time-limit rule. Persisted by `AppLimitRuleStore` and looked up
/// by the DeviceActivity extension on `eventDidReachThreshold`, which only
/// receives the event NAME `evlin.limit.<id>` and must resolve the tokens to
/// shield from here.
struct AppLimitRule: Codable, Sendable, Equatable {
    /// Stable rule identity. Encodes into the DeviceActivityEvent name
    /// `evlin.limit.<id>` so the extension can map a threshold back to a rule.
    let id: UUID
    /// App(s) this rule shields once the budget is reached. May be empty until
    /// the kid device captures the app's opaque token.
    let appTokens: Set<ApplicationToken>
    /// Bundle id of the limited app (stable cross-process identity).
    let bundleID: String
    /// Human-facing app name.
    let displayName: String
    /// Daily budget in minutes before the shield engages.
    let budgetMinutes: Int
    /// When (time-of-day) the budget applies.
    let window: AppLimitWindow
    /// Rule takes effect from this instant.
    let effectiveFrom: Date
    /// Optional hard stop; nil = no expiry.
    let expiresAt: Date?
}

/// Persistence for per-app limit rules in App Group `group.com.evlin.ios`.
///
/// Uses the SAME `.iso8601` JSON encoder/decoder the DeviceActivity extension
/// uses for `ShieldRecord` so the extension can read these rules cross-process
/// in a later task (P7). `ApplicationToken`s ride through the JSON Codable path
/// — the same approach `LocalAliasStore` proved safe on iOS 26 (where
/// `PropertyListEncoder` trips `swift_dynamicCastFailure` on FamilyControls
/// tokens). Legacy/plist payloads are tolerated on read for symmetry with the
/// other stores, even though this key is new.
final class AppLimitRuleStore: @unchecked Sendable {
    static let shared = AppLimitRuleStore()

    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let rulesKey = "evlin.appLimitRules"

    init() {}

    nonisolated deinit {}

    // MARK: - CRUD

    /// Insert or replace the rule keyed by its `id`.
    func upsert(_ rule: AppLimitRule) {
        var dict = load()
        dict[rule.id] = rule
        persist(dict)
    }

    /// Remove the rule with this id, if present.
    func remove(ruleId: UUID) {
        var dict = load()
        guard dict.removeValue(forKey: ruleId) != nil else { return }
        persist(dict)
    }

    /// All persisted rules (unordered).
    func all() -> [AppLimitRule] {
        Array(load().values)
    }

    /// Look up a single rule by id.
    func rule(forID id: UUID) -> AppLimitRule? {
        load()[id]
    }

    /// Wipe every persisted rule. Used by tests and a full reset.
    func removeAll() {
        defaults?.removeObject(forKey: rulesKey)
    }

    // MARK: - Persistence

    private func load() -> [UUID: AppLimitRule] {
        guard let data = defaults?.data(forKey: rulesKey) else { return [:] }
        // JSON (current) first; PropertyList only as a legacy fallback, matching
        // the decode discipline of ActiveLockStore / LocalAliasStore.
        if let decoded = try? evlinJSONDecoder().decode([String: AppLimitRule].self, from: data) {
            return remap(decoded)
        }
        if let decoded = try? PropertyListDecoder().decode([String: AppLimitRule].self, from: data) {
            return remap(decoded)
        }
        return [:]
    }

    private func remap(_ stringKeyed: [String: AppLimitRule]) -> [UUID: AppLimitRule] {
        var out: [UUID: AppLimitRule] = [:]
        for (key, rule) in stringKeyed {
            // Prefer the embedded id; fall back to parsing the key. Both are the
            // same UUID in practice, but the embedded id is authoritative.
            out[rule.id] = rule
            if rule.id.uuidString != key, let parsed = UUID(uuidString: key) {
                out[parsed] = rule
            }
        }
        return out
    }

    private func persist(_ dict: [UUID: AppLimitRule]) {
        // Encode with String keys so the JSON is a plain object the extension's
        // JSONDecoder reads directly (UUID dictionary keys would force an array
        // encoding that's awkward to consume cross-process).
        let stringKeyed = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString, $0.value) })
        guard let data = try? evlinJSONEncoder().encode(stringKeyed) else { return }
        defaults?.set(data, forKey: rulesKey)
    }
}

// MARK: - Codec (match the extension's `.iso8601` date strategy)

/// MUST stay `.iso8601` to match `DeviceActivityMonitorExtension`'s
/// `evlinJSONDecoder()` / `ActiveLockStore.persist()`. A strategy mismatch is
/// exactly the documented prior bug that wiped all blocks (dates-as-numbers vs
/// dates-as-strings → silent decode failure across the process boundary).
private func evlinJSONEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}

private func evlinJSONDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}
