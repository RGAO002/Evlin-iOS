//
//  QueryCardAdapter.swift
//  Evlin iOS
//
//  Phase 2D: Dispatches 5 query.result_* kinds emitted when
//  AGENT_PLAN_ARCH_QUERY=true.
//
//  Spec §6.3 invariant 4: query result rows MUST NOT mutate state.
//  Tapping a row prefills the chat input box via handleQueryCardStub —
//  NO plan-patch POST is made.
//
//  Mapping:
//   query.result_pending_submissions → .F1 (ListSuggestionCard)
//     items from payload.detail["items"][*]["title"]
//   query.result_pending_bypass      → .F1 (ListSuggestionCard)
//     items from payload.detail["items"][*]["child_text"]
//   query.result_task_summary        → nil (text-bubble path)
//   query.result_active_reflection   → nil (text-bubble path)
//   query.result_shields_summary     → nil (text-bubble path)
//   unknown query.* kind             → nil (graceful fallback)
//

import Foundation

enum QueryCardAdapter {
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? {
        switch payload.kind {

        case "query.result_pending_submissions":
            // QF-1: Parent asked "any pending submissions?" — show task titles.
            // Tapping a row prefills "Approve <title>" via handleQueryCardStub.
            let titles = itemStrings(from: payload, field: "title")
            return CardRenderModel(
                cardID: .F1,
                context: makeContext(
                    target: payload.title,
                    childName: childName,
                    listSuggestions: titles
                )
            )

        case "query.result_pending_bypass":
            // QF-2: Parent asked "any bypass requests?" — show child_text snippets.
            // Tapping a row prefills the snippet for follow-up via handleQueryCardStub.
            let snippets = itemStrings(from: payload, field: "child_text")
            return CardRenderModel(
                cardID: .F1,
                context: makeContext(
                    target: payload.title,
                    childName: childName,
                    listSuggestions: snippets
                )
            )

        case "query.result_task_summary",
             "query.result_active_reflection",
             "query.result_shields_summary":
            // Text-bubble kinds: no polished card. ChatViewModel surfaces the
            // card's title/body via the existing chat bubble path.
            return nil

        default:
            // Unknown query.* kind — fall back to PlanArchCardView.
            return nil
        }
    }

    // MARK: - Helpers

    /// Extracts strings from payload.detail["items"] array by reading
    /// the given field key from each item dict.
    private static func itemStrings(from payload: PlanArchCardPayload, field: String) -> [String] {
        guard let raw = payload.detail["items"]?.value as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { $0[field] as? String }
    }

    private static func makeContext(
        target: String,
        childName: String,
        listSuggestions: [String] = []
    ) -> CardContext {
        CardContext(
            targetDisplay: target,
            childName: childName,
            durationMinutes: nil,
            categoryGuess: nil,
            listSuggestions: listSuggestions,
            existingLists: [],
            blockItems: [],
            childDevices: [],
            mode: "std",
            existingRecordKey: nil,
            requestedExpiryISO: nil,
            existingMode: nil,
            u1Token: nil,
            u1ShieldList: []
        )
    }
}
