//
//  PhoneCardAdapter.swift
//  Evlin iOS
//
//  Task 24: Maps all 11 phone.* kinds to real CardID / CardContext.
//
//  CardContext fields are all `let` — constructed via makeContext() in one shot.
//  U1ShieldEntry uses `kind: String` ("app"|"category"|"list"|"all") per
//  the real U1Models.swift — not `category: String?` as shown in the plan.
//

import Foundation

enum PhoneCardAdapter {
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? {
        switch payload.kind {

        case "phone.missing_duration":
            let target = stringFromDetail(payload, "target_name")
                ?? stringFromDetail(payload, "target")
                ?? payload.title
            return CardRenderModel(
                cardID: .D1,
                context: makeContext(target: target, childName: childName)
            )

        case "phone.below_min_duration":
            let target = stringFromDetail(payload, "target_name") ?? payload.title
            let requested = intFromDetail(payload, "requested_minutes")
            return CardRenderModel(
                cardID: .D1,
                context: makeContext(
                    target: target, childName: childName,
                    durationMinutes: requested
                )
            )

        case "phone.alias_miss":
            // Phase 2A intentional fallback: alias_miss needs the
            // FamilyActivityPicker which CatalogMissCard (E3) doesn't expose.
            // Returning nil causes ChatView to fall back to PlanArchCardView
            // where the existing onLazyTag / handlePlanArchLazyTag plumbing
            // still works. Phase 2B will add onLazyTag to CardHandlers and
            // wire it into CatalogMissCard so the polished E3 UI can be used.
            return nil

        case "phone.unlock_picker":
            let shields = u1ShieldEntriesFromDetail(payload)
            let verb = unlockPickerVerb(payload)
            return CardRenderModel(
                cardID: .U1,
                context: makeContext(
                    target: "", childName: childName,
                    u1Token: payload.planToken, u1ShieldList: shields,
                    u1Verb: verb
                )
            )

        case "phone.unsupported_exclusion":
            // CardID.D2's view hardcodes "What does \"everything\" mean?" +
            // "Lock ALL apps on Liam's phone" / "Just distracting categories"
            // — that's the legacy ambiguity flow, not what backend's
            // phone.unsupported_exclusion actually says. Return nil so
            // PlanArchCardView renders the backend's real title/body/options.
            return nil

        case "phone.replace_mode_required":
            let target = stringFromDetail(payload, "target_name") ?? payload.title
            return CardRenderModel(
                cardID: .B1,
                context: makeContext(
                    target: target, childName: childName,
                    existingRecordKey: stringFromDetail(payload, "existing_record_key"),
                    requestedExpiryISO: stringFromDetail(payload, "requested_expiry"),
                    existingMode: stringFromDetail(payload, "existing_mode")
                )
            )

        case "phone.bulk_action_confirm":
            let parts = stringArrayFromDetail(payload, "targets")
                ?? stringArrayFromDetail(payload, "items")
                ?? []
            return CardRenderModel(
                cardID: .A3,
                context: makeContext(
                    target: payload.title, childName: childName,
                    blockItems: parts
                )
            )

        case "phone.danger_confirm":
            // Block-style destructive confirm: 'Block X forever / unblock from
            // home screen' UX. Keep A1 for this kind only.
            let summary = stringFromDetail(payload, "action_summary") ?? payload.title
            return CardRenderModel(
                cardID: .A1,
                context: makeContext(target: summary, childName: childName)
            )

        case "phone.proposal_confirm":
            // Generic 'Shield X for N min — confirm?' from strategy_agent or
            // fast-path. A1 has hardcoded BLOCK copy that doesn't fit shield
            // semantics. Return nil so ChatView falls back to PlanArchCardView,
            // which renders title/body/options from the payload as-is.
            return nil

        case "phone.block_max_only":
            // Validator rule_11: parent tried to block in Std mode. Backend
            // builds the explanation + 'Shield X for 30 min instead' option
            // directly into payload.title/body/options. PlanArchCardView
            // renders those as-is. The legacy D2 ('What does everything mean?')
            // routing was nonsense here — the payload semantic isn't ambiguity.
            return nil

        case "phone.unsupported_in_mode":
            let target = stringFromDetail(payload, "target_name") ?? payload.title
            return CardRenderModel(
                cardID: .E1,
                context: makeContext(
                    target: target, childName: childName,
                    mode: stringFromDetail(payload, "mode") ?? "std"
                )
            )

        case "phone.list_suggestion":
            let target = stringFromDetail(payload, "target_name") ?? payload.title
            return CardRenderModel(
                cardID: .F1,
                context: makeContext(
                    target: target, childName: childName,
                    listSuggestions: stringArrayFromDetail(payload, "suggestions") ?? [],
                    existingLists: stringArrayFromDetail(payload, "existing_lists") ?? []
                )
            )

        default:
            return nil
        }
    }

    // MARK: - one-shot CardContext factory

    /// Constructs CardContext (whose fields are all `let`) in one shot.
    private static func makeContext(
        target: String, childName: String,
        durationMinutes: Int? = nil,
        categoryGuess: String? = nil,
        listSuggestions: [String] = [],
        existingLists: [String] = [],
        blockItems: [String] = [],
        childDevices: [(id: UUID, label: String)] = [],
        mode: String = "std",
        existingRecordKey: String? = nil,
        requestedExpiryISO: String? = nil,
        existingMode: String? = nil,
        u1Token: String? = nil,
        u1ShieldList: [U1ShieldEntry] = [],
        u1Verb: String? = nil
    ) -> CardContext {
        return CardContext(
            targetDisplay: target,
            childName: childName,
            durationMinutes: durationMinutes,
            categoryGuess: categoryGuess,
            listSuggestions: listSuggestions,
            existingLists: existingLists,
            blockItems: blockItems,
            childDevices: childDevices,
            mode: mode,
            existingRecordKey: existingRecordKey,
            requestedExpiryISO: requestedExpiryISO,
            existingMode: existingMode,
            u1Token: u1Token,
            u1ShieldList: u1ShieldList,
            u1Verb: u1Verb
        )
    }

    // MARK: - small helpers reading from PlanArchAnyCodable

    private static func detailDict(_ payload: PlanArchCardPayload) -> [String: Any]? {
        return payload.detail.mapValues { $0.value } as? [String: Any]
            ?? (payload.detail as [String: Any])
    }

    private static func stringFromDetail(_ p: PlanArchCardPayload, _ key: String) -> String? {
        (p.detail[key]?.value) as? String
    }

    private static func intFromDetail(_ p: PlanArchCardPayload, _ key: String) -> Int? {
        if let n = p.detail[key]?.value as? Int { return n }
        if let d = p.detail[key]?.value as? Double { return Int(d) }
        return nil
    }

    private static func stringArrayFromDetail(_ p: PlanArchCardPayload, _ key: String) -> [String]? {
        p.detail[key]?.value as? [String]
    }

    private static func u1ShieldEntriesFromDetail(_ p: PlanArchCardPayload) -> [U1ShieldEntry] {
        // Backend may emit either ["IG", "TikTok"] or richer dicts; both accepted.
        // U1ShieldEntry uses `kind: String` ("app"|"category"|"list"|"all").
        //
        // Strategy-agent's _build_unlock_picker_* emits detail["shields"]
        // (plural). The older U1 plumbing read detail["active_shields"].
        // Accept both — fall through to whichever key is populated so a
        // future drift in one direction doesn't silently empty the card.
        let rawValue: Any? =
            p.detail["shields"]?.value
            ?? p.detail["active_shields"]?.value

        if let strings = rawValue as? [String] {
            return strings.enumerated().map { (i, name) in
                U1ShieldEntry(index: i, kind: "app", displayName: name,
                              expiresAtISO: nil, stale: false)
            }
        }
        if let arr = rawValue as? [[String: Any]] {
            return arr.enumerated().map { (i, dict) in
                U1ShieldEntry(
                    index: i,
                    kind: (dict["kind"] as? String) ?? "app",
                    displayName: (dict["display_name"] as? String) ?? "?",
                    expiresAtISO: dict["expires_at_iso"] as? String,
                    stale: (dict["stale"] as? Bool) ?? false,
                    // Phase 1b coverage flags — defaulted so older backend
                    // builds (or shapes that pre-date the field) keep
                    // working as "no coverage, fully tappable".
                    coveredByAll: (dict["covered_by_all"] as? Bool) ?? false,
                    categoryWarnings: (dict["category_warnings"] as? [String]) ?? []
                )
            }
        }
        return []
    }

    private static func unlockPickerVerb(_ p: PlanArchCardPayload) -> String {
        let title = p.title.lowercased()
        let optionLabels = p.options.map { $0.label.lowercased() }
        if title.contains("unblock") || optionLabels.contains(where: { $0.contains("unblock") }) {
            return "unblock"
        }
        return "unlock"
    }
}
