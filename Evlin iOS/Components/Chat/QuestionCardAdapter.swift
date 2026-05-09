//
//  QuestionCardAdapter.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.9 — adapt a backend-emitted PlanArchCardPayload
//  (kind = "question.<style>") into a typed QuestionCard model that
//  QuestionCardView can render.
//
//  NOTE on the parameter type: the strategy-agent plan calls this
//  `parse(_ payload: CardPayload)`, but `CardPayload` (Models/CardPayload.swift)
//  is the legacy in-memory UI shell, not a Codable network type. The actual
//  on-the-wire question card arrives through the plan-arch dual path as
//  `PlanArchCardPayload` (Models/PlanArchCardPayload.swift), which already
//  exposes `kind`, `body`, `options`, and `detail` — exactly the fields the
//  plan's adapter needs. We adapted the signature accordingly while keeping
//  the parse contract the plan describes.
//

import Foundation

/// Maps a PlanArchCardPayload with kind="question.<style>" into a
/// QuestionCard model. Returns nil if the payload is not a question card.
struct QuestionCardAdapter {
    static func parse(_ payload: PlanArchCardPayload) -> QuestionCard? {
        guard payload.kind.hasPrefix("question.") else { return nil }

        // Detail carries: question_id, style, free_text_allowed, cancellable.
        guard let qid = payload.detail["question_id"]?.value as? String,
              let styleRaw = payload.detail["style"]?.value as? String,
              let style = QuestionStyle(rawValue: styleRaw) else { return nil }

        let freeTextAllowed = (payload.detail["free_text_allowed"]?.value as? Bool) ?? false
        let cancellable = (payload.detail["cancellable"]?.value as? Bool) ?? true

        // Options come as PlanArchCardOption[]; map to QuestionOption.
        let opts: [QuestionOption] = payload.options.compactMap { o in
            guard let v = o.patch["selected_value"]?.value as? String else { return nil }
            return QuestionOption(value: v, label: o.label)
        }

        return QuestionCard(
            questionId: qid,
            prompt: payload.body ?? "",
            style: style,
            options: opts,
            freeTextAllowed: freeTextAllowed,
            cancellable: cancellable
        )
    }
}
