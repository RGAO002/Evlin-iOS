import Foundation

/// Single row in a U1 unlock-disambiguation card. Mirrors backend's
/// `_load_effective_state` output dict augmented with the Phase 1b
/// coverage flags (`covered_by_all`, `category_warnings`) emitted by
/// `card_factory._annotate_picker_coverage`.
///
/// The two coverage fields carry the *honest* answer to overlap UX:
/// - `coveredByAll` is a hard truth — when an All Apps shield is active,
///   unlocking a narrower row alone can't actually unblock it, so iOS
///   strikethroughs + greys + disables the tap.
/// - `categoryWarnings` is a soft hint — ManagedSettings has no API for
///   querying "which apps does this category token cover" (confirmed
///   with Codex review). We surface every active category name on every
///   app row so the parent isn't surprised when iOS reports
///   nothing-to-unshield. The row stays tappable.
///
/// Both fields default to "no coverage" so an older backend build (or a
/// payload that predates this contract) decodes cleanly without crashing.
struct U1ShieldEntry: Identifiable, Codable, Sendable, Equatable {
    var id: Int { index }
    let index: Int        // position in original list — used for U1 marker
    let kind: String      // "app" | "category" | "list" | "all"
    let displayName: String
    let expiresAtISO: String?
    let stale: Bool
    let coveredByAll: Bool
    let categoryWarnings: [String]

    enum CodingKeys: String, CodingKey {
        case index
        case kind
        case stale
        case displayName = "display_name"
        case expiresAtISO = "expires_at_iso"
        case coveredByAll = "covered_by_all"
        case categoryWarnings = "category_warnings"
    }

    init(
        index: Int,
        kind: String,
        displayName: String,
        expiresAtISO: String?,
        stale: Bool,
        coveredByAll: Bool = false,
        categoryWarnings: [String] = []
    ) {
        self.index = index
        self.kind = kind
        self.displayName = displayName
        self.expiresAtISO = expiresAtISO
        self.stale = stale
        self.coveredByAll = coveredByAll
        self.categoryWarnings = categoryWarnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try c.decode(Int.self, forKey: .index)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.expiresAtISO = try c.decodeIfPresent(String.self, forKey: .expiresAtISO)
        self.stale = try c.decode(Bool.self, forKey: .stale)
        // Coverage fields are optional for forward/backward compat — a
        // backend build without Phase 1b emits no covered_by_all key, and
        // the safe default is "not covered" so the row stays tappable.
        self.coveredByAll = try c.decodeIfPresent(Bool.self, forKey: .coveredByAll) ?? false
        self.categoryWarnings = try c.decodeIfPresent([String].self, forKey: .categoryWarnings) ?? []
    }
}
