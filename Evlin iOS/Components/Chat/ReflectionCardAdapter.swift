//
//  ReflectionCardAdapter.swift
//  Evlin iOS
//
//  Phase 2B: Dispatches all reflection.* kinds.
//
//  Mapping (spec §6.3):
//   reflection.confirm_propose        → nil (fallback; backend copy is reflection-specific)
//   reflection.confirm_cancel         → .A1 (DangerConfirmCard) — confirm cancelling an active reflection
//   reflection.confirm_bypass_response → .A1 (DangerConfirmCard) — respond to bypass request from child
//   reflection.confirm_approve        → .reflectionReview (ReflectionSubmissionReviewCard approve mode)
//   reflection.confirm_redo           → .reflectionReview (ReflectionSubmissionReviewCard redo mode)
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

        case "reflection.confirm_approve":
            return makeReviewModel(payload, childName: childName, mode: .approve)

        case "reflection.confirm_redo":
            return makeReviewModel(payload, childName: childName, mode: .redo)

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

    private static func makeReviewModel(
        _ payload: PlanArchCardPayload,
        childName: String,
        mode: ReflectionReviewMode
    ) -> CardRenderModel? {
        guard let prompt = firstNonEmptyString(
            payload,
            keys: ["prompt", "writing_prompt", "writingPrompt"]
        ), let essay = firstNonEmptyString(
            payload,
            keys: ["essay", "essay_text", "essayText", "essay_excerpt", "essayExcerpt"]
        ) else {
            return nil
        }

        let redoReason = firstNonEmptyString(
            payload,
            keys: ["redo_reason", "redoReason", "reason"]
        )

        var context = CardContext.defaultContext(
            targetDisplay: payload.title,
            childName: childName
        )
        context.reflectionPrompt = prompt
        context.reflectionEssay = essay
        context.reflectionReviewMode = mode
        context.reflectionRedoReason = redoReason

        return CardRenderModel(cardID: .reflectionReview, context: context)
    }

    private static func stringFromDetail(_ p: PlanArchCardPayload, _ key: String) -> String? {
        (p.detail[key]?.value) as? String
    }

    private static func firstNonEmptyString(
        _ payload: PlanArchCardPayload,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = stringFromDetail(payload, key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }
}
