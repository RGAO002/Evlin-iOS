//
//  ChatViewModelPlanArchLifecycleTests.swift
//  Evlin iOSTests
//
//  Task 27: Lifecycle tests for plan-arch card dispatch in ChatViewModel.
//  Tests that makePlanArchHandlers produces valid CardHandlers and that
//  source routing stubs behave correctly.
//

import XCTest
@testable import Evlin_iOS

@MainActor
final class ChatViewModelPlanArchLifecycleTests: XCTestCase {

    // Helper: build a minimal PlanArchCardPayload from JSON
    private func makePayload(kind: String, source: String = "plan", planToken: String = "tok123") -> PlanArchCardPayload {
        let body: [String: Any] = [
            "type": "duration_picker",
            "title": "Test card",
            "plan_token": planToken,
            "step_index": 0,
            "kind": kind,
            "source": source,
            "detail": ["target_name": "IG"],
            "options": [],
            "danger": "low",
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(PlanArchCardPayload.self, from: data)
    }

    func testMakePlanArchHandlersReturnsCancelClosure() {
        let vm = ChatViewModel()
        let card = makePayload(kind: "phone.missing_duration")
        vm.pendingPlanArchCard = card

        let handlers = vm.makePlanArchHandlers(for: card)
        XCTAssertNotNil(handlers.onCancel, "onCancel must be non-nil")
        XCTAssertNotNil(handlers.onPrimary, "onPrimary must be non-nil")
        XCTAssertNotNil(handlers.onDurationPicked, "onDurationPicked must be non-nil")
        XCTAssertNotNil(handlers.onU1UnlockSelected, "onU1UnlockSelected must be non-nil")
        XCTAssertNotNil(handlers.onU1UnlockEverything, "onU1UnlockEverything must be non-nil")
    }

    func testEventSourceSetsErrorMessageAndClearsCard() async {
        let vm = ChatViewModel()
        let card = makePayload(kind: "event.reflection_review_pending", source: "event")
        vm.pendingPlanArchCard = card

        // Synthesise a cancel-style option (source routing ignores option content)
        let opt = PlanArchCardOption(label: "OK", patch: [:], cancelsPlan: false)
        vm.handlePlanArchOption(opt)

        // Yield to let the async Task complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPlanArchCard, "card should be cleared after event stub")
        XCTAssertEqual(vm.errorMessage, "Event-card actions arrive in Phase 2B.")
    }

    func testQuerySourceSetsErrorMessageAndClearsCard() async {
        let vm = ChatViewModel()
        let card = makePayload(kind: "query.result_pending_submissions", source: "query")
        vm.pendingPlanArchCard = card

        let opt = PlanArchCardOption(label: "OK", patch: [:], cancelsPlan: false)
        vm.handlePlanArchOption(opt)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPlanArchCard, "card should be cleared after query stub")
        XCTAssertEqual(vm.errorMessage, "Query-result actions arrive in Phase 2D.")
    }

    func testPlanSourceCancelClearsCardImmediately() {
        let vm = ChatViewModel()
        let card = makePayload(kind: "phone.danger_confirm", source: "plan")
        vm.pendingPlanArchCard = card

        let cancelOpt = PlanArchCardOption.cancel(fromCard: card)
        vm.handlePlanArchOption(cancelOpt)

        // Cancel is synchronous (no Task), card clears immediately
        XCTAssertNil(vm.pendingPlanArchCard)
        XCTAssertTrue(vm.messages.contains(where: { $0.content == "Cancelled." }))
    }
}
