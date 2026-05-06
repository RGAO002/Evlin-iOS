import Foundation

/// Single row in a U1 unlock-disambiguation card. Mirrors backend's
/// _load_effective_state output dict.
struct U1ShieldEntry: Identifiable, Codable, Sendable, Equatable {
    var id: Int { index }
    let index: Int        // position in original list — used for U1 marker
    let kind: String      // "app" | "category" | "list" | "all"
    let displayName: String
    let expiresAtISO: String?
    let stale: Bool

    enum CodingKeys: String, CodingKey {
        case index
        case kind
        case displayName = "display_name"
        case expiresAtISO = "expires_at_iso"
        case stale
    }
}
