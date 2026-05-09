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

    // 1. reflection.confirm_propose → .A1 (DangerConfirmCard)
    func testConfirmProposeMapsToA1() {
        let card = payload(kind: "reflection.confirm_propose",
                           detail: ["reflection_reason": "distracted by social media"])
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.cardID, .A1)
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

    // 4. reflection.confirm_approve → nil (fallback to PlanArchCardView)
    func testConfirmApproveReturnsNilFallback() {
        let card = payload(kind: "reflection.confirm_approve")
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model, "confirm_approve defers to PlanArchCardView fallback until Phase 2C")
    }

    // 5. reflection.confirm_redo → nil (fallback to PlanArchCardView)
    func testConfirmRedoReturnsNilFallback() {
        let card = payload(kind: "reflection.confirm_redo")
        let model = ReflectionCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model, "confirm_redo defers to PlanArchCardView fallback until Phase 2C")
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
