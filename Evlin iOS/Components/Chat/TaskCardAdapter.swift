//
//  TaskCardAdapter.swift
//  Evlin iOS
//
//  Phase 2C: Dispatches all task.* kinds introduced by the propose_task_plan
//  backend tool (gated on AGENT_PLAN_ARCH_TASK=true).
//
//  Mapping (spec §task-cards):
//   task.confirm_destructive  → .A1 (DangerConfirmCard) — delete / cancel a task
//   task.confirm_approve      → .A1 (DangerConfirmCard) — body summarises submission;
//                               polished evidence-review card (photo URLs + note) is post-2C
//   task.confirm_redo         → .A1 (DangerConfirmCard) — body summarises submission;
//                               polished evidence-review card is post-2C
//   task.confirm_unusual_assign → .A3 (BulkActionCard) — unusual params, list of reasons
//   unknown task.* kind       → nil (fallback to PlanArchCardView)
//

import Foundation

enum TaskCardAdapter {
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? {
        switch payload.kind {

        case "task.confirm_destructive":
            // TF7: Delete or cancel an existing task. High-danger destructive confirm.
            let summary = stringFromDetail(payload, "title") ?? payload.title
            return CardRenderModel(
                cardID: .A1,
                context: makeContext(target: summary, childName: childName)
            )

        case "task.confirm_approve":
            // TF9: Parent reviews submitted task and approves.
            // Polished evidence card (photo URLs + note) is post-2C work.
            // For now .A1 lets the parent tap Approve/Cancel; body already
            // summarises submission courtesy of the backend builder.
            let summary = stringFromDetail(payload, "title") ?? payload.title
            return CardRenderModel(
                cardID: .A1,
                context: makeContext(target: summary, childName: childName)
            )

        case "task.confirm_redo":
            // TF11: Send submitted task back for redo.
            // Same rationale as confirm_approve — .A1 with basic body until
            // polished evidence-review card lands post-2C.
            let summary = stringFromDetail(payload, "title") ?? payload.title
            return CardRenderModel(
                cardID: .A1,
                context: makeContext(target: summary, childName: childName)
            )

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
