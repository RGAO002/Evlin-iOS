//
//  AppControlCardModel.swift
//  Evlin iOS
//
//  Task 11 — deterministic app-control cards.
//
//  The backend's parent-chat seam (app/api/routes/parent_chat.py
//  `_app_control_card_response`) emits long-string card ids alongside a
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

/// The deterministic app-control card ids. Raw values match
/// `AppControlCardType` on the backend AND the `CardID` enum cases added for
/// the chat render path.
enum AppControlCardKind: String, Sendable, CaseIterable {
    case singleAppShieldAdvice = "single_app_shield_advice"
    case shieldTokenMissing = "shield_token_missing"
    case appStoreDisambiguation = "app_store_disambiguation"
    case appNotFoundTerminal = "app_not_found_terminal"
    case childDisambiguation = "child_disambiguation"
    case categoryRenameRequired = "category_rename_required"
    // Four additional app-control cards (backend commit 93a0b6a). Raw values
    // match the backend `card_id`s and the matching `CardID` cases.
    case cannotBlockCategory = "cannot_block_category"
    case categoryShieldOffer = "category_shield_offer"
    case catalogAppInactive = "catalog_app_inactive"
    case bundleIDRequired = "bundle_id_required"
    // Task 6 — lock-selected-apps confirmation cards.
    case lockSelectedAppsConfirm = "lock_selected_apps_confirm"
    case lockSelectedAppsEmpty = "lock_selected_apps_empty"
    // Family-level bare unlock/unblock picker.
    case restrictionUnlockPicker = "restriction_unlock_picker"
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

/// One app-preview row from `lock_selected_apps_confirm`. Mirrors the backend
/// `AppPreviewItem` projection (`display_name`, `bundle_id`, `artwork_url`).
struct AppPreviewItem: Sendable, Equatable {
    let displayName: String
    let bundleID: String?
    let artworkURL: URL?
}

struct RestrictionUnlockRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String
    let action: String
    let kind: String
    let childDeviceID: String
    let deviceLabel: String
    let expiresAtISO: String?
}

struct RestrictionUnlockGroup: Sendable, Equatable, Identifiable {
    let id: String
    let childName: String
    let avatarURL: URL?
    let avatarValue: String
    let avatarColorHex: String?
    let deviceSummary: String
    let sessions: [RestrictionUnlockRow]
}

struct RestrictionAvatarCursor: Equatable {
    let candidateURLs: [URL]
    private(set) var index = 0

    var currentURL: URL? {
        candidateURLs.indices.contains(index) ? candidateURLs[index] : nil
    }

    mutating func advanceAfterFailure(for failedURL: URL) {
        guard currentURL == failedURL else { return }
        index += 1
    }
}

/// One disambiguation row. Mirrors the loose dict the seam projects for each
/// candidate (`_app_control_candidate_projection`).
struct AppControlCandidate: Sendable, Equatable, Identifiable {
    let display: String
    let bundleID: String?
    let artworkURL: URL?
    let targetType: String?
    let childDeviceID: String?
    let childAvatarURL: URL?
    let childAvatarValue: String?
    let childAvatarColorHex: String?
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
    let childDeviceID: String?
    // Task 6 — lock_selected_apps_confirm payload fields.
    let appsCount: Int
    let categoriesCount: Int
    let appPreview: [AppPreviewItem]
    let categoryPreview: [String]
    let durationMinutes: Int?
    let pickerToken: String?
    let restrictionGroups: [RestrictionUnlockGroup]

    /// Parse a deterministic app-control card returned by endpoints such as
    /// plan-patch, where there is no top-level ChatAction/card_id wrapper.
    static func parseFromResponseData(_ data: Data) -> AppControlCardModel? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["card_payload"] as? [String: Any],
            let cardID = payload["type"] as? String
        else { return nil }
        return parse(cardID: cardID, payload: payload)
    }

    /// Parse from the chat-response `card_payload` dict (already deserialised to
    /// `[String: Any]`). Returns nil when `card_id` isn't one of the
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
        let childDeviceID = payload["child_device_id"] as? String

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
                artworkURL: (dict["artwork_url"] as? String).flatMap(URL.init(string:)),
                targetType: dict["target_type"] as? String,
                childDeviceID: dict["child_device_id"] as? String,
                childAvatarURL: (dict["child_avatar_url"] as? String).flatMap(URL.init(string:)),
                childAvatarValue: dict["child_avatar_value"] as? String,
                childAvatarColorHex: dict["child_avatar_color"] as? String,
                aliasKey: dict["alias_key"] as? String
            )
        }

        // Task 6 — lock_selected_apps_confirm payload fields (default-zero for
        // other card kinds so no existing parse logic is affected).
        let appsCount = (payload["apps_count"] as? Int) ?? 0
        let categoriesCount = (payload["categories_count"] as? Int) ?? 0
        let appPreviewDicts = (payload["app_preview"] as? [[String: Any]]) ?? []
        let appPreview: [AppPreviewItem] = appPreviewDicts.compactMap { dict in
            guard let displayName = dict["display_name"] as? String else { return nil }
            return AppPreviewItem(
                displayName: displayName,
                bundleID: dict["bundle_id"] as? String,
                artworkURL: (dict["artwork_url"] as? String).flatMap(URL.init(string:))
            )
        }
        let categoryPreview = (payload["category_preview"] as? [String]) ?? []
        let durationMinutes = payload["duration_minutes"] as? Int
        let pickerToken = payload["picker_token"] as? String
        let restrictionGroups = parseRestrictionGroups(payload["restriction_groups"] as? [[String: Any]])

        return AppControlCardModel(
            kind: kind,
            title: title,
            body: body,
            targetDisplay: targetDisplay,
            targetKind: targetKind,
            options: options,
            candidates: candidates,
            aliasKey: aliasKey,
            bundleID: bundleID,
            childDeviceID: childDeviceID,
            appsCount: appsCount,
            categoriesCount: categoriesCount,
            appPreview: appPreview,
            categoryPreview: categoryPreview,
            durationMinutes: durationMinutes,
            pickerToken: pickerToken,
            restrictionGroups: restrictionGroups
        )
    }

    private static func parseRestrictionGroups(_ dicts: [[String: Any]]?) -> [RestrictionUnlockGroup] {
        (dicts ?? []).compactMap { dict in
            let childName = (dict["child_name"] as? String) ?? "Child"
            let avatar = dict["avatar"] as? [String: Any]
            let trimmedChildName = childName.trimmingCharacters(in: .whitespacesAndNewlines)
            let avatarValue = trimmedChildName.isEmpty
                ? "?"
                : String(trimmedChildName.prefix(1)).uppercased()
            let avatarColor = avatar?["color"] as? String
            let avatarURL = (avatar?["signed_url"] as? String).flatMap(URL.init(string:))
            let devices = (dict["devices"] as? [[String: Any]]) ?? []
            let deviceLabels = devices.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
            let sessions = ((dict["sessions"] as? [[String: Any]]) ?? []).compactMap { row -> RestrictionUnlockRow? in
                guard let id = row["id"] as? String else { return nil }
                let title = (row["title"] as? String)
                    ?? (row["display_name"] as? String)
                    ?? "Restricted item"
                return RestrictionUnlockRow(
                    id: id,
                    title: title,
                    subtitle: (row["subtitle"] as? String) ?? "",
                    badge: (row["badge"] as? String) ?? "ACTIVE",
                    action: (row["action"] as? String) ?? "unshield",
                    kind: (row["kind"] as? String) ?? "app",
                    childDeviceID: (row["child_device_id"] as? String) ?? "",
                    deviceLabel: (row["device_label"] as? String) ?? "",
                    expiresAtISO: row["expires_at_iso"] as? String
                )
            }
            guard !sessions.isEmpty else { return nil }
            return RestrictionUnlockGroup(
                id: (dict["child_id"] as? String) ?? childName,
                childName: childName,
                avatarURL: avatarURL,
                avatarValue: avatarValue,
                avatarColorHex: avatarColor,
                deviceSummary: deviceLabels.isEmpty ? "" : deviceLabels.joined(separator: ", "),
                sessions: sessions
            )
        }
    }
}

extension AppControlCardModel {
    var restrictionPrimaryActionLabel: String {
        options.first {
            $0.action == "restriction_unlock_selected"
        }?.label ?? "Remove selected"
    }

    static func restrictionAvatarCandidateURLs(
        childID: String,
        familyAvatarURLsByChildID: [String: String],
        payloadURL: URL?
    ) -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = []

        func appendIfUsable(_ url: URL?) {
            guard let url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host != nil,
                  seen.insert(url.absoluteString).inserted else {
                return
            }
            result.append(url)
        }

        let familyURL = familyAvatarURLsByChildID[childID]
            .flatMap(URL.init(string:))
        appendIfUsable(familyURL)
        appendIfUsable(payloadURL)
        return result
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
    /// Open parent-side App Store search for the unresolved/disambiguated text.
    /// Used by "Not in the list" on app-store disambiguation cards.
    case openAppSearch(query: String)
    /// Confirm an App Store / public-catalog candidate in the Family App
    /// Dictionary, then resend the original command with the selected display.
    case confirmAppAndResend(candidateDisplay: String, bundleID: String?, artworkURL: URL?)
    /// Surface guidance toward renaming the colliding list. Used by
    /// category_rename_required's rename_list (no chat endpoint exists).
    case renameList(target: String)
    /// Option/action not recognised — caller should no-op (and dismiss).
    case none
}

enum AppControlRouter {
    /// The loop-safety invariant phrase for the lock_selected_apps_confirm card.
    /// Contains "Locked set" + the duration; must NOT contain "list" (the word
    /// "list" trips GUARD_OTHER_FAMILY and bypasses the app-control fastpath).
    static func selectedSetLockPhrase(durationMinutes: Int?) -> String {
        guard let durationMinutes else {
            return "lock Locked set permanently"
        }
        return "lock Locked set for \(durationMinutes) min"
    }

    /// Route an option tap to a concrete action. `verb` parsing comes from the
    /// option's `action` string; `force_confirmations` is preferred when the
    /// backend supplied it so the seam's deterministic branch is honoured.
    static func route(option: AppControlCardOption, card: AppControlCardModel) -> AppControlAction {
        // Force-confirmation options (block_now / shield_anyway) always resend
        // with the backend-provided tokens — that's the contract the seam reads.
        if !option.forceConfirmations.isEmpty {
            return .resendForceConfirmations(scopedForceConfirmations(option.forceConfirmations, card: card))
        }
        switch option.action {
        case "block_now":
            // Defensive: backend normally ships force_confirmations.
            // if a deploy omitted them, resend the token explicitly.
            return .resendForceConfirmations(["\(card.kind.rawValue):block_now"])
        case "shield_anyway":
            return .resendForceConfirmations(["\(card.kind.rawValue):shield_anyway"])
        case "open_lazy_tag":
            return .openLazyTag(target: card.targetDisplay, kind: aliasKind(for: card.targetKind))
        case "open_app_search":
            return .openAppSearch(query: card.targetDisplay)
        case "rename_list":
            return .renameList(target: card.targetDisplay)
        case "lock_selected_apps_now":
            // Confirm card: resend with the list-guard-safe phrase. No force so
            // we don't replay the original "lock his phone" and loop.
            return .resendPhrase(selectedSetLockPhrase(durationMinutes: card.durationMinutes))
        case "lock_all_apps_now":
            // Empty card: lock the whole device for the chosen duration.
            if let durationMinutes = card.durationMinutes {
                return .resendPhrase("lock all for \(durationMinutes) min")
            }
            return .resendPhrase("lock all permanently")
        case "cancel":
            // Explicit Cancel option (cannot_block_category / category_shield_offer
            // / lock_selected_apps_confirm / lock_selected_apps_empty) is an
            // intentional dismiss, not an unknown-action fall-through.
            return .none
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
            // The candidate display is now the unambiguous app name. Confirm it
            // first so the next turn resolves through the family dictionary
            // instead of re-opening the same disambiguation / legacy lazy-tag path.
            let commandDisplay = commandDisplayName(for: candidate.display)
            return .confirmAppAndResend(
                candidateDisplay: commandDisplay,
                bundleID: candidate.bundleID,
                artworkURL: candidate.artworkURL
            )
        default:
            return .none
        }
    }

    /// Replaces the ambiguous target inside the original parent command while
    /// preserving the verb and duration ("Lock cat quest for 15 min" ->
    /// "Lock Cat Quest for 15 min"). This prevents app-store disambiguation taps
    /// from replaying only the display name and falling into the legacy
    /// "managed apps" lazy-tag path.
    static func rewriteOriginalCommand(
        _ original: String,
        replacing targetDisplay: String,
        with candidateDisplay: String
    ) -> String {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCandidate = commandDisplayName(for: candidateDisplay)
        let trimmedTarget = targetDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty, !trimmedCandidate.isEmpty else {
            return trimmedCandidate
        }
        // Already names the candidate — re-confirming the same card must not
        // splice it in twice.
        if trimmedOriginal.range(
            of: trimmedCandidate,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil {
            return trimmedOriginal
        }
        guard !trimmedTarget.isEmpty,
              let range = wordBoundedRange(of: trimmedTarget, in: trimmedOriginal)
        else {
            // The target is not in this sentence, so there is nothing to patch.
            //
            // Returning the original unchanged is the one thing we must not do:
            // the caller re-sends it, and re-sending the exact text that
            // produced the picker reproduces the picker — a closed loop with no
            // exit and no diagnostic. It happens whenever the card's target
            // differs from the parent's wording, or a later bubble displaced
            // `lastUserMessageForCard`.
            //
            // Rebuild the command instead: keep the verb the parent used and
            // name the app they just picked. The verb has to survive — block
            // hides an app, lock overlays it, and they are not interchangeable
            // — and a bare display name carries no verb at all, so the re-sent
            // message could not execute even in principle.
            //
            // The duration is dropped, so the parent gets asked for one. A
            // question is a worse outcome than executing, and a much better one
            // than the same card forever.
            if let verb = leadingCommandVerb(in: trimmedOriginal) {
                return "\(verb) \(trimmedCandidate)"
            }
            return trimmedCandidate
        }
        var rewritten = trimmedOriginal
        rewritten.replaceSubrange(range, with: trimmedCandidate)
        return rewritten
    }

    /// The command verb `original` opens with, in the parent's own casing.
    ///
    /// Ordered longest-first so "unlock" is not read as "lock" — which would
    /// invert the command.
    private static func leadingCommandVerb(in original: String) -> String? {
        let verbs = ["unblock", "unshield", "unlock", "block", "shield", "lock"]
        guard let firstWord = original.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        ).first else { return nil }
        let candidate = String(firstWord).trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        guard verbs.contains(candidate.lowercased()) else { return nil }
        return candidate
    }

    /// `target`'s range in `haystack`, but only where it stands as a whole word.
    ///
    /// A plain substring replace splices the candidate inside words that were
    /// never the target: "lock fbi" with target "fb" became "lock Facebooki",
    /// and because "block" contains "loc", a target of "loc" rewrote the verb
    /// itself — turning a block into something that is not a command at all.
    /// Both produce a re-sent command naming an app nobody chose.
    ///
    /// A boundary here is anything that is not a letter or digit. CJK has no
    /// spaces, so a CJK target is accepted wherever it appears — the boundary
    /// rule only applies when the target's own edges are alphanumeric.
    private static func wordBoundedRange(
        of target: String,
        in haystack: String
    ) -> Range<String.Index>? {
        var searchStart = haystack.startIndex
        while let range = haystack.range(
            of: target,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<haystack.endIndex
        ) {
            let leadingOK = !isWordCharacter(target.first)
                || range.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: range.lowerBound)])
            let trailingOK = !isWordCharacter(target.last)
                || range.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[range.upperBound])
            if leadingOK && trailingOK { return range }
            guard range.upperBound < haystack.endIndex else { return nil }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    static func aliasKind(for targetKind: String) -> AliasKind {
        targetKind == "category" ? .category : .app
    }

    private static func scopedForceConfirmations(
        _ tokens: [String],
        card: AppControlCardModel
    ) -> [String] {
        tokens.map { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.contains(":"),
                  trimmed == "block_now" || trimmed == "shield_anyway"
            else { return trimmed }
            return "\(card.kind.rawValue):\(trimmed)"
        }
    }

    private static func commandDisplayName(for display: String) -> String {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" - ", " – ", " — "] {
            if let range = trimmed.range(of: separator) {
                let prefix = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return String(prefix)
                }
            }
        }
        return trimmed
    }
}
