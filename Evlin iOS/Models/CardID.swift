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

    // Phase 2B placeholders (will be populated by reflection family work):
    case reflectionReview                // reflection.confirm_approve / event.* review
    case contentGenFailed                // reflection.content_generation_failed

    // Task 11 — deterministic app-control cards (NOT Brain/verb-table cards).
    // These long-string ids arrive from the parent-chat seam as
    // `action.card_id == AppControlCardPayload.type.value`, alongside a typed
    // `card_payload` dict. They are parsed by AppControlCardModel and rendered
    // by AppControlCard via ChatViewModel.currentAppControlCard — NOT through
    // CardDispatcher/CardPayloadBuilder. The cases below exist so
    // CardID(rawValue:) recognises them (routing them off the Brain path) and
    // so the exhaustive CardID switches still compile.
    case singleAppShieldAdvice = "single_app_shield_advice"
    case shieldTokenMissing = "shield_token_missing"
    case appStoreDisambiguation = "app_store_disambiguation"
    case appNotFoundTerminal = "app_not_found_terminal"
    case childDisambiguation = "child_disambiguation"
    case categoryRenameRequired = "category_rename_required"
    // Four additional app-control cards (backend commit 93a0b6a). Same render
    // path as the six above — parsed by AppControlCardModel, rendered by
    // AppControlCard, never through CardDispatcher/CardPayloadBuilder.
    case cannotBlockCategory = "cannot_block_category"
    case categoryShieldOffer = "category_shield_offer"
    case catalogAppInactive = "catalog_app_inactive"
    case bundleIDRequired = "bundle_id_required"
    // Task 6 — lock-selected-apps confirmation cards.
    case lockSelectedAppsConfirm = "lock_selected_apps_confirm"
    case lockSelectedAppsEmpty = "lock_selected_apps_empty"
}

extension CardID {
    /// True for the deterministic app-control card ids (Task 11). These take
    /// the AppControlCard render path, not the Brain/verb-table CardDispatcher
    /// path.
    var isAppControlCard: Bool {
        switch self {
        case .singleAppShieldAdvice, .shieldTokenMissing, .appStoreDisambiguation,
             .appNotFoundTerminal, .childDisambiguation, .categoryRenameRequired,
             .cannotBlockCategory, .categoryShieldOffer, .catalogAppInactive,
             .bundleIDRequired, .lockSelectedAppsConfirm, .lockSelectedAppsEmpty:
            return true
        default:
            return false
        }
    }
}
