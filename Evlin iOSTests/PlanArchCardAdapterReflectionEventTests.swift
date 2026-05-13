//
//  PlanArchCardAdapterReflectionEventTests.swift
//  Evlin iOSTests
//
//  Phase 2B: Tests for ReflectionCardAdapter + EventCardAdapter.
//  8 test cases covering the full dispatch matrix.
//

import XCTest
@testable import Evlin_iOS

final class PlanArchCardAdapterReflectionEventTests: XCTestCase {

    // MARK: - Helpers

    private func payload(kind: String, source: String = "plan", detail: [String: Any] = [:]) -> PlanArchCardPayload {
        let body: [String: Any] = [
            "type": "duration_picker",
            "title": "test",
            "plan_token": "tok",
            "step_index": 0,
            "kind": kind,
            "source": source,
            "detail": detail,
            "options": [],
            "danger": "low",
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(PlanArchCardPayload.self, from: data)
    }

    // MARK: - ReflectionCardAdapter tests

    // 1. reflection.confirm_propose → nil (fallback to backend-authored copy)
    func testConfirmProposeReturnsNilFallback() {
        let card = payload(kind: "reflection.confirm_propose",
                           detail: ["reflection_reason": "distracted by social media"])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model)
    }

    // 2. reflection.confirm_cancel → .A1 (DangerConfirmCard)
    func testConfirmCancelMapsToA1() {
        let card = payload(kind: "reflection.confirm_cancel",
                           detail: ["reason": "cancel the active reflection"])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cardID, .A1)
    }

    // 3. reflection.confirm_bypass_response → .A1 (DangerConfirmCard)
    func testConfirmBypassResponseMapsToA1() {
        let card = payload(kind: "reflection.confirm_bypass_response",
                           detail: ["bypass_reason": "said he finished homework"])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cardID, .A1)
    }

    // 4. reflection.confirm_approve → .reflectionReview (approve mode)
    func testConfirmApproveMapsToReflectionReviewApproveMode() {
        let card = payload(kind: "reflection.confirm_approve",
                           detail: [
                            "writing_prompt": "What happened, and what could you do next time?",
                            "essay_text": "I got frustrated and yelled. Next time I can take a break.",
                           ])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cardID, .reflectionReview)
        XCTAssertEqual(model?.context.reflectionReviewMode, .approve)
        XCTAssertEqual(model?.context.reflectionPrompt, "What happened, and what could you do next time?")
        XCTAssertEqual(model?.context.reflectionEssay, "I got frustrated and yelled. Next time I can take a break.")
    }

    // 5. reflection.confirm_redo → .reflectionReview (redo mode)
    func testConfirmRedoMapsToReflectionReviewRedoMode() {
        let card = payload(kind: "reflection.confirm_redo",
                           detail: [
                            "prompt": "What happened, and what could you do next time?",
                            "essay": "I was mad.",
                            "redo_reason": "Ask for more detail about what happened.",
                           ])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cardID, .reflectionReview)
        XCTAssertEqual(model?.context.reflectionReviewMode, .redo)
        XCTAssertEqual(model?.context.reflectionPrompt, "What happened, and what could you do next time?")
        XCTAssertEqual(model?.context.reflectionEssay, "I was mad.")
        XCTAssertEqual(model?.context.reflectionRedoReason, "Ask for more detail about what happened.")
    }

    func testMalformedReflectionReviewReturnsNilFallback() {
        let card = payload(kind: "reflection.confirm_approve",
                           detail: ["writing_prompt": "What happened?"])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model, "missing essay must fall back to generic PlanArch rendering")
    }

    // 6. reflection.content_generation_failed → .contentGenFailed
    func testContentGenerationFailedMapsToContentGenFailed() {
        let card = payload(kind: "reflection.content_generation_failed",
                           detail: ["failure_reason": "Gemini API timeout"])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cardID, .contentGenFailed)
    }

    // 7. unknown reflection.* kind → nil
    func testUnknownReflectionKindReturnsNil() {
        let card = payload(kind: "reflection.some_future_kind")
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model, "unknown reflection.* kind must return nil so PlanArchCardView fallback runs")
    }

    // MARK: - EventCardAdapter tests

    // 8. event.reflection_review_pending → nil (fallback to PlanArchCardView for now)
    func testEventReflectionReviewPendingReturnsNilFallback() {
        let card = payload(kind: "event.reflection_review_pending", source: "event")
        let model = EventCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model, "event.reflection_review_pending returns nil until Phase 2C polished card lands")
    }
}
