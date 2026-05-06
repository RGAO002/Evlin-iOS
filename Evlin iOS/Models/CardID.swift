import Foundation

/// All confirmation card IDs. See spec §5.
enum CardID: String, Codable, Sendable {
    // Group A — destructive confirmations
    // A2 removed (single unblock is direct action, no card) — see spec §5.2.
    case A1, A3
    // Group B — downgrade confirmations
    case B1, B2
    // Group C — upgrade confirmations
    case C1, C2
    // Group D — missing info / ambiguity
    case D1, D2, D3, D4
    // Group E — rejection + alternative
    case E1, E2, E3, E4
    // Group F — suggestion
    case F1
    // Group G — onboarding fallback
    case G1
    // Group R — reflection confirmation (big-kid mode)
    case R1
    // Group U — unlock disambiguation
    case U1
}
