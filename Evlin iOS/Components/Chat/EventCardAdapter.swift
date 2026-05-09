//
//  EventCardAdapter.swift
//  Evlin iOS
//
//  Phase 2B: returns nil for all event.* kinds, causing ChatView to
//  fall back to PlanArchCardView.
//
//  Rationale: event.reflection_review_pending needs a polished card showing
//  the kid's essay + quiz score with Approve/Redo buttons. That card is
//  ReflectionSubmissionReviewCard (already exists for the submission poll
//  path) but wiring it through the plan-arch card path requires threaded
//  payload fields not yet emitted by backend. Defer to Phase 2C.
//
//  When Phase 2C ships:
//   event.reflection_review_pending → map to .reflectionReview card,
//   routing to ReflectionSubmissionReviewCard (or a dedicated EventReviewCard).
//

import Foundation

enum EventCardAdapter {
    // Phase 2B: fall back to PlanArchCardView for all event.* kinds.
    // See file header for rationale and Phase 2C upgrade path.
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? { nil }
}
