//
//  AppControlCardModel.swift
//  Evlin iOS
//
//  Task 11 — deterministic app-control cards.
//
//  The backend's parent-chat seam (app/api/routes/parent_chat.py
//  `_app_control_card_response`) emits six long-string card ids alongside a
//  `card_payload` dict whose shape mirrors AppControlCardPayload
//  (app/schemas/card_payload.py). These are SEPARATE from the Brain/verb-table
//  cards (U1/A1/B1/D1/D4/…): the long ids are not valid PlanArchCardType raw
//  values, so PlanArchCardPayload.decodeAllFromChatResponseData skips them and
//  they fall through to ChatViewModel.processResponse → CardID(rawValue:).
//
//  This file holds the PURE (UI-free, unit-testable) parse + option→action
//  routing so the card view stays a thin renderer and ChatViewModel stays a
//  thin dispatcher. See LazyTagCatalogModelTests for coverage.
//

import Foundation

/// The six deterministic app-control card ids. Raw values match
/// `AppControlCardType` on the backend AND the `CardID` enum cases added for
/// the chat render path.
enum AppControlCardKind: String, Sendable, CaseIterable {
    case singleAppShieldAdvice = "single_app_shield_advice"
    case shieldTokenMissing = "shield_token_missing"
    case appStoreDisambiguation = "app_store_disambiguation"
    case appNotFoundTerminal = "app_not_found_terminal"
    case childDisambiguation = "child_disambiguation"
    case categoryRenameRequired = "category_rename_required"
}

/// One tappable option on an app-control card. Mirrors backend
/// `AppControlCardOption`.
struct AppControlCardOption: Sendable, Equatable, Identifiable {
    /// Deterministic verb iOS replays, e.g. "block_now", "shield_anyway",
    /// "open_lazy_tag", "rename_list".
    let action: String
    let label: String
    /// Confirmation tokens to resend on the next /parent/chat turn so the seam
    /// takes the chosen branch deterministically (e.g. ["shield_anyway"]).
    let forceConfirmations: [String]

    var id: String { action + "|" + label }
}

/// One disambiguation row. Mirrors the loose dict the seam projects for each
/// candidate (`_app_control_candidate_projection`).
struct AppControlCandidate: Sendable, Equatable, Identifiable {
    let display: String
    let bundleID: String?
    let targetType: String?
    let childDeviceID: String?
    let aliasKey: String?

    /// Stable enough for SwiftUI ForEach: a candidate is uniquely identified by
    /// its child device (children) or bundle id / display (apps).
    var id: String {
        childDeviceID ?? bundleID ?? display
    }
}

/// Parsed, typed view of a backend app-control `card_payload` dict.
struct AppControlCardModel: Sendable, Equatable {
    let kind: AppControlCardKind
    let title: String
    let body: String
    let targetDisplay: String
    /// "app" | "category" | "list" | "all"
    let targetKind: String
    let options: [AppControlCardOption]
    let candidates: [AppControlCandidate]
    let aliasKey: String?
    let bundleID: String?

    /// Parse from the chat-response `card_payload` dict (already deserialised to
    /// `[String: Any]`). Returns nil when `card_id` isn't one of the six
    /// app-control ids — the caller then leaves the Brain/verb-table path
    /// untouched.
    static func parse(cardID: String, payload: [String: Any]) -> AppControlCardModel? {
        guard let kind = AppControlCardKind(rawValue: cardID) else { return nil }

        let title = (payload["title"] as? String) ?? ""
        let body = (payload["body"] as? String) ?? ""
        // `target_display` is duplicated at the top level by the seam; prefer it.
        let targetDisplay = (payload["target_display"] as? String) ?? ""
        let targetKind = (payload["target_kind"] as? String) ?? "app"
        let aliasKey = payload["alias_key"] as? String
        let bundleID = payload["bundle_id"] as? String

        let optionDicts = (payload["options"] as? [[String: Any]]) ?? []
        let options: [AppControlCardOption] = optionDicts.compactMap { dict in
            guard let action = dict["action"] as? String,
                  let label = dict["label"] as? String
            else { return nil }
            let fc = (dict["force_confirmations"] as? [String]) ?? []
            return AppControlCardOption(action: action, label: label, forceConfirmations: fc)
        }

        let candidateDicts = (payload["candidates"] as? [[String: Any]]) ?? []
        let candidates: [AppControlCandidate] = candidateDicts.compactMap { dict in
            // A row is only usable if it has a display string to show/replay.
            guard let display = (dict["display"] as? String), !display.isEmpty else { return nil }
            return AppControlCandidate(
                display: display,
                bundleID: dict["bundle_id"] as? String,
                targetType: dict["target_type"] as? String,
                childDeviceID: dict["child_device_id"] as? String,
                aliasKey: dict["alias_key"] as? String
            )
        }

        return AppControlCardModel(
            kind: kind,
            title: title,
            body: body,
            targetDisplay: targetDisplay,
            targetKind: targetKind,
            options: options,
            candidates: candidates,
            aliasKey: aliasKey,
            bundleID: bundleID
        )
    }
}

/// What ChatViewModel should do when an app-control option / candidate is tapped.
/// Pure value type so routing is unit-testable without touching the network or
/// SwiftUI.
enum AppControlAction: Sendable, Equatable {
    /// Re-dispatch the original parent message with these force-confirmation
    /// tokens (mirrors the U1/A1/B1 resend mechanism). Used by block_now /
    /// shield_anyway.
    case resendForceConfirmations([String])
    /// Re-dispatch the chat with an unambiguous phrase derived from the chosen
    /// disambiguation candidate (mirrors the D4 child-name rewrite). Used by
    /// app_store / child disambiguation rows.
    case resendPhrase(String)
    /// Open the catalog-backed lazy-tag picker for this target. Used by
    /// open_lazy_tag (shield_token_missing / app_not_found_terminal).
    case openLazyTag(target: String, kind: AliasKind)
    /// Surface guidance toward renaming the colliding list. Used by
    /// category_rename_required's rename_list (no chat endpoint exists).
    case renameList(target: String)
    /// Option/action not recognised — caller should no-op (and dismiss).
    case none
}

enum AppControlRouter {
    /// Route an option tap to a concrete action. `verb` parsing comes from the
    /// option's `action` string; `force_confirmations` is preferred when the
    /// backend supplied it so the seam's deterministic branch is honoured.
    static func route(option: AppControlCardOption, card: AppControlCardModel) -> AppControlAction {
        // Force-confirmation options (block_now / shield_anyway) always resend
        // with the backend-provided tokens — that's the contract the seam reads.
        if !option.forceConfirmations.isEmpty {
            return .resendForceConfirmations(option.forceConfirmations)
        }
        switch option.action {
        case "block_now":
            // Defensive: backend normally ships force_confirmations=["block_now"];
            // if a deploy omitted them, resend the token explicitly.
            return .resendForceConfirmations(["block_now"])
        case "shield_anyway":
            return .resendForceConfirmations(["shield_anyway"])
        case "open_lazy_tag":
            return .openLazyTag(target: card.targetDisplay, kind: aliasKind(for: card.targetKind))
        case "rename_list":
            return .renameList(target: card.targetDisplay)
        default:
            return .none
        }
    }

    /// Route a disambiguation candidate tap. Picking a row replays an
    /// unambiguous phrase so the seam resolves deterministically next turn.
    static func route(candidate: AppControlCandidate, card: AppControlCardModel) -> AppControlAction {
        switch card.kind {
        case .childDisambiguation:
            // Rewrite to scope the original action to the chosen child, mirroring
            // the Brain D4 child-name rewrite ("Liam's phone: …").
            return .resendPhrase("\(candidate.display)'s phone")
        case .appStoreDisambiguation:
            // The candidate display is now the unambiguous app name.
            return .resendPhrase(candidate.display)
        default:
            return .none
        }
    }

    static func aliasKind(for targetKind: String) -> AliasKind {
        targetKind == "category" ? .category : .app
    }
}
