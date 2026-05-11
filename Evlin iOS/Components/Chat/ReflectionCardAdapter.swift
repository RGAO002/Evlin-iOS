//
//  ReflectionCardAdapter.swift
//  Evlin iOS
//
//  Phase 2B: Dispatches all reflection.* kinds.
//
//  Mapping (spec §6.3):
//   reflection.confirm_propose        → .A1 (DangerConfirmCard) — parent confirms Gemini will spend tokens
//   reflection.confirm_cancel         → .A1 (DangerConfirmCard) — confirm cancelling an active reflection
//   reflection.confirm_bypass_response → .A1 (DangerConfirmCard) — respond to bypass request from child
//   reflection.confirm_approve        → nil (fallback to PlanArchCardView until polished review card lands)
//   reflection.confirm_redo           → nil (fallback to PlanArchCardView until polished review card lands)
//   reflection.content_generation_failed → .contentGenFailed (ReflectionContentFailedCard)
//   unknown reflection.* kind         → nil (fallback)
//

import Foundation

enum ReflectionCardAdapter {
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? {
        switch payload.kind {

        case "reflection.confirm_propose":
            // Strategy_agent emits reflection.confirm_propose with title like
            // "Start a reflection?" + body=rationale + options=[Start reflection,
            // Cancel]. A1 has hardcoded BLOCK copy ("Blocking hides the app...")
            // that doesn't fit reflection semantics. Return nil so ChatView
            // falls back to PlanArchCardView which renders title/body/options
            // from the payload as-is. Same pattern as phone.proposal_confirm.
            return nil

        case "reflection.confirm_cancel":
            // "Cancel active reflection?"
            let summary = stringFromDetail(payload, "reason")
                ?? payload.title
            return CardRenderModel(
                cardID: .A1,
                context: makeContext(target: summary, childName: childName)
            )

        case "reflection.confirm_bypass_response":
            // "Respond to bypass request from <child>"
            let who = childName.isEmpty ? "child" : childName
            let bypassSummary = stringFromDetail(payload, "bypass_reason")
                ?? "bypass request from \(who)"
            let summary = "Respond to \(bypassSummary)"
            return CardRenderModel(
                cardID: .A1,
                context: makeContext(target: summary, childName: childName)
            )

        case "reflection.confirm_approve", "reflection.confirm_redo":
            // Deferred: requires polished ReflectionReviewCard showing essay excerpt
            // + quiz score + Approve/Redo buttons. PlanArchCardView already handles
            // essay text rendering and is an acceptable fallback for Phase 2B.
            // TODO(Phase 2C): implement ReflectionReviewCard and route here.
            return nil

        case "reflection.content_generation_failed":
            // New in Phase 2B: ReflectionContentFailedCard with Retry / SimplerTemplate / Cancel.
            let summary = stringFromDetail(payload, "failure_reason")
                ?? payload.title
            return CardRenderModel(
                cardID: .contentGenFailed,
                context: makeContext(target: summary, childName: childName)
            )

        default:
            // Unknown reflection.* kind — fall back to PlanArchCardView.
            return nil
        }
    }

    // MARK: - One-shot CardContext factory
    // CardContext fields are all `let`, so construct in one shot.

    private static func makeContext(
        target: String,
        childName: String
    ) -> CardContext {
        CardContext(
            targetDisplay: target,
            childName: childName,
            durationMinutes: nil,
            categoryGuess: nil,
            listSuggestions: [],
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

    private static func stringFromDetail(_ p: PlanArchCardPayload, _ key: String) -> String? {
        (p.detail[key]?.value) as? String
    }
}
