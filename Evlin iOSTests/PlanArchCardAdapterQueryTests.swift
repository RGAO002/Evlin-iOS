//
//  PlanArchCardAdapterQueryTests.swift
//  Evlin iOSTests
//
//  Phase 2D: Tests for QueryCardAdapter — 5 query.result_* kinds + unknown fallback.
//
//  Mapping under test (spec §6.3):
//   query.result_pending_submissions → .F1 (ListSuggestionCard) with titles
//   query.result_pending_bypass      → .F1 (ListSuggestionCard) with child_text snippets
//   query.result_task_summary        → nil (text-bubble path)
//   query.result_active_reflection   → nil (text-bubble path)
//   query.result_shields_summary     → nil (text-bubble path)
//   query.result_unknown_X           → nil (graceful fallback)
//
//  Invariant: query result rows MUST NOT mutate state (spec §1 invariant 4).
//  Adapter-level tests verify card shape only; lifecycle tests (in
//  ChatViewModelPlanArchLifecycleTests) verify inputText prefill and the
//  absence of plan-patch POSTs.
//

import XCTest
@testable import Evlin_iOS

final class PlanArchCardAdapterQueryTests: XCTestCase {

    // MARK: - Helpers

    private func payload(kind: String, detail: [String: Any] = [:]) -> PlanArchCardPayload {
        let body: [String: Any] = [
            "type": "duration_picker",
            "title": "Query result",
            "plan_token": "qtok",
            "step_index": 0,
            "kind": kind,
            "source": "query",
            "detail": detail,
            "options": [],
            "danger": "low",
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(PlanArchCardPayload.self, from: data)
    }

    // MARK: - query.result_pending_submissions → .F1

    func testPendingSubmissionsMapsToF1WithTitles() {
        let card = payload(
            kind: "query.result_pending_submissions",
            detail: [
                "items": [
                    ["title": "Clean room", "submitted_at": "2026-05-08T09:00:00Z"],
                    ["title": "Read chapter 5", "submitted_at": "2026-05-08T10:00:00Z"],
                ]
            ]
        )
        let model = QueryCardAdapter.adapt(card, childName: "Liam")

        XCTAssertNotNil(model,
            "query.result_pending_submissions must produce a CardRenderModel (.F1)")
        XCTAssertEqual(model?.cardID, .F1,
            "query.result_pending_submissions → .F1 (ListSuggestionCard)")
        XCTAssertEqual(model?.context.listSuggestions, ["Clean room", "Read chapter 5"],
            "listSuggestions must be populated from items[*].title")
    }

    // MARK: - query.result_pending_bypass → .F1

    func testPendingBypassMapsToF1WithChildText() {
        let card = payload(
            kind: "query.result_pending_bypass",
            detail: [
                "items": [
                    ["child_text": "Please let me use YouTube for homework", "requested_at": "2026-05-08T11:00:00Z"],
                    ["child_text": "I finished my chores", "requested_at": "2026-05-08T11:30:00Z"],
                ]
            ]
        )
        let model = QueryCardAdapter.adapt(card, childName: "Liam")

        XCTAssertNotNil(model,
            "query.result_pending_bypass must produce a CardRenderModel (.F1)")
        XCTAssertEqual(model?.cardID, .F1,
            "query.result_pending_bypass → .F1 (ListSuggestionCard)")
        XCTAssertEqual(
            model?.context.listSuggestions,
            ["Please let me use YouTube for homework", "I finished my chores"],
            "listSuggestions must be populated from items[*].child_text"
        )
    }

    // MARK: - Text-bubble kinds → nil

    func testTaskSummaryReturnsNil() {
        let card = payload(
            kind: "query.result_task_summary",
            detail: ["message": "Liam has 3 active tasks."]
        )
        let model = QueryCardAdapter.adapt(card, childName: "Liam")

        XCTAssertNil(model,
            "query.result_task_summary must return nil (text-bubble path via ChatViewModel message field)")
    }

    func testActiveReflectionReturnsNil() {
        let card = payload(
            kind: "query.result_active_reflection",
            detail: ["message": "Reflection expires in 2 hours."]
        )
        let model = QueryCardAdapter.adapt(card, childName: "Liam")

        XCTAssertNil(model,
            "query.result_active_reflection must return nil (text-bubble path)")
    }

    func testShieldsSummaryReturnsNil() {
        let card = payload(
            kind: "query.result_shields_summary",
            detail: ["message": "Instagram is shielded until 5 PM."]
        )
        let model = QueryCardAdapter.adapt(card, childName: "Liam")

        XCTAssertNil(model,
            "query.result_shields_summary must return nil (text-bubble path)")
    }

    // MARK: - Unknown query.* kind → nil

    func testUnknownQueryKindReturnsNil() {
        let card = payload(kind: "query.result_unknown_X")
        let model = QueryCardAdapter.adapt(card, childName: "Liam")

        XCTAssertNil(model,
            "unknown query.* kind must return nil so PlanArchCardView fallback renders")
    }
}
