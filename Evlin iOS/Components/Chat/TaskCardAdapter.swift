//
//  TaskCardAdapter.swift
//  Evlin iOS
//
//  Phase 2C: Dispatches all task.* kinds introduced by the propose_task_plan
//  backend tool (gated on AGENT_PLAN_ARCH_TASK=true).
//
//  Mapping (spec §task-cards):
//   task.confirm_destructive  → nil (PlanArchCardView renders backend copy/options)
//   task.confirm_approve      → nil (PlanArchCardView renders backend copy/options)
//   task.confirm_redo         → nil (PlanArchCardView renders backend copy/options)
//   task.confirm_unusual_assign → .A3 (BulkActionCard) — unusual params, list of reasons
//   unknown task.* kind       → nil (fallback to PlanArchCardView)
//

import Foundation

enum TaskCardAdapter {
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? {
        switch payload.kind {

        case "task.confirm_destructive":
            // Do not route through .A1: that template is phone-specific and
            // renders "Block <target>?". The backend payload already carries
            // the correct task title/body/buttons, so let PlanArchCardView
            // render it directly.
            return nil

        case "task.confirm_approve":
            // See task.confirm_destructive. Reusing .A1 would turn a task
            // approve into phone-block copy.
            return nil

        case "task.confirm_redo":
            // See task.confirm_destructive. The backend payload says
            // "Request task redo?"; .A1 would incorrectly say "Block ...?".
            return nil

        case "task.confirm_unusual_assign":
            // TF4: Unusual assign params (5am due / "until done" / bulk).
            // Backend emits unusual_reasons as a list; body already contains
            // bullet-point summary. BulkActionCard (.A3) is the natural fit.
            let reasons = stringArrayFromDetail(payload, "unusual_reasons") ?? []
            return CardRenderModel(
                cardID: .A3,
                context: makeContext(
                    target: payload.title,
                    childName: childName,
                    blockItems: reasons
                )
            )

        default:
            // Unknown task.* kind — fall back to PlanArchCardView.
            return nil
        }
    }

    // MARK: - One-shot CardContext factory
    // CardContext fields are all `let`, so construct in one shot.

    private static func makeContext(
        target: String,
        childName: String,
        blockItems: [String] = []
    ) -> CardContext {
        CardContext(
            targetDisplay: target,
            childName: childName,
            durationMinutes: nil,
            categoryGuess: nil,
            listSuggestions: [],
            existingLists: [],
            blockItems: blockItems,
            childDevices: [],
            mode: "std",
            existingRecordKey: nil,
            requestedExpiryISO: nil,
            existingMode: nil,
            u1Token: nil,
            u1ShieldList: []
        )
    }

    // MARK: - Helpers reading from PlanArchAnyCodable

    private static func stringFromDetail(_ p: PlanArchCardPayload, _ key: String) -> String? {
        (p.detail[key]?.value) as? String
    }

    private static func stringArrayFromDetail(_ p: PlanArchCardPayload, _ key: String) -> [String]? {
        p.detail[key]?.value as? [String]
    }
}
