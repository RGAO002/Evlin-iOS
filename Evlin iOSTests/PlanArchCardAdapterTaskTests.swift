//
//  PlanArchCardAdapterTaskTests.swift
//  Evlin iOSTests
//
//  Phase 2C: Tests for TaskCardAdapter — 4 task.* kinds + unknown fallback.
//
//  Mapping under test:
//   task.confirm_destructive    → .A1
//   task.confirm_approve        → .A1 (basic body; polished evidence card is post-2C)
//   task.confirm_redo           → .A1 (same rationale as confirm_approve)
//   task.confirm_unusual_assign → .A3
//   task.unknown_future_kind    → nil (graceful fallback to PlanArchCardView)
//

import XCTest
@testable import Evlin_iOS

final class PlanArchCardAdapterTaskTests: XCTestCase {

    // MARK: - Helpers

    private func payload(kind: String, detail: [String: Any] = [:]) -> PlanArchCardPayload {
        // Use a valid legacy `type` to satisfy the strict CardPayload schema;
        // `kind` drives the new family-prefixed dispatch.
        let body: [String: Any] = [
            "type": "danger_confirm",
            "title": "test",
            "plan_token": "tok",
            "step_index": 0,
            "kind": kind,
            "source": "plan",
            "detail": detail,
            "options": [],
            "danger": "high",
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(PlanArchCardPayload.self, from: data)
    }

    // MARK: - task.confirm_destructive → .A1

    func testConfirmDestructiveMapsToA1() {
        let card = payload(kind: "task.confirm_destructive",
                           detail: ["title": "Clean room", "intent": "delete"])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model, "task.confirm_destructive must produce a CardRenderModel")
        XCTAssertEqual(model?.cardID, .A1,
                       "task.confirm_destructive → .A1 (DangerConfirmCard)")
    }

    // MARK: - task.confirm_approve → .A1 (basic; polished evidence card is post-2C)

    func testConfirmApproveMapsToA1() {
        let card = payload(kind: "task.confirm_approve",
                           detail: [
                               "title": "Math homework",
                               "evidence_note": "I did it!",
                               "submitted_at": "2026-05-08T10:00:00Z",
                           ])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model,
                        "task.confirm_approve returns .A1 for Phase 2C (polished evidence card is post-2C)")
        XCTAssertEqual(model?.cardID, .A1,
                       "task.confirm_approve → .A1 (basic body summarises submission)")
    }

    // MARK: - task.confirm_redo → .A1 (same rationale as confirm_approve)

    func testConfirmRedoMapsToA1() {
        let card = payload(kind: "task.confirm_redo",
                           detail: [
                               "title": "Read chapter 5",
                               "redo_reason": "Summary was too short",
                           ])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model,
                        "task.confirm_redo returns .A1 for Phase 2C (polished evidence card is post-2C)")
        XCTAssertEqual(model?.cardID, .A1,
                       "task.confirm_redo → .A1 (basic body summarises submission)")
    }

    // MARK: - task.confirm_unusual_assign → .A3

    func testConfirmUnusualAssignMapsToA3() {
        let card = payload(kind: "task.confirm_unusual_assign",
                           detail: [
                               "unusual_reasons": ["extreme_time", "lock_until_complete"],
                               "assign_fields": ["title": "Wake up and study"],
                           ])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNotNil(model, "task.confirm_unusual_assign must produce a CardRenderModel")
        XCTAssertEqual(model?.cardID, .A3,
                       "task.confirm_unusual_assign → .A3 (BulkActionCard)")
    }

    // MARK: - unknown task.* kind → nil (graceful fallback)

    func testUnknownTaskKindReturnsNil() {
        let card = payload(kind: "task.unknown_future_kind")
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model,
                     "unknown task.* kind must return nil so PlanArchCardView fallback renders")
    }
}
