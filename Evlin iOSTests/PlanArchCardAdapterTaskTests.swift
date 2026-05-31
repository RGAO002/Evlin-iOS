//
//  PlanArchCardAdapterTaskTests.swift
//  Evlin iOSTests
//
//  Phase 2C: Tests for TaskCardAdapter — 4 task.* kinds + unknown fallback.
//
//  Mapping under test:
//   task.confirm_destructive    → nil (backend payload renderer)
//   task.confirm_approve        → nil (backend payload renderer)
//   task.confirm_redo           → nil (backend payload renderer)
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

    // MARK: - task.confirm_destructive → backend payload renderer

    func testConfirmDestructiveUsesBackendPayloadFallback() {
        let card = payload(kind: "task.confirm_destructive",
                           detail: ["title": "Clean room", "intent": "delete"])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model,
                     "task.confirm_destructive must not reuse phone A1 block template")
    }

    // MARK: - task.confirm_approve → backend payload renderer

    func testConfirmApproveUsesBackendPayloadFallback() {
        let card = payload(kind: "task.confirm_approve",
                           detail: [
                               "title": "Math homework",
                               "evidence_note": "I did it!",
                               "submitted_at": "2026-05-08T10:00:00Z",
                           ])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model,
                     "task.confirm_approve must not reuse phone A1 block template")
    }

    // MARK: - task.confirm_redo → backend payload renderer

    func testConfirmRedoUsesBackendPayloadFallback() {
        let card = payload(kind: "task.confirm_redo",
                           detail: [
                               "title": "Read chapter 5",
                               "redo_reason": "Summary was too short",
                           ])
        let model = TaskCardAdapter.adapt(card, childName: "Liam")
        XCTAssertNil(model,
                     "task.confirm_redo must not reuse phone A1 block template")
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
