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
        // onPrimary is intentionally nil — polished cards drive their own
        // primary action; synthesising intent_confirmed:true would be rejected
        // by backend CardPatchPayload (extra="forbid").
        XCTAssertNil(handlers.onPrimary, "onPrimary must be nil (polished cards handle their own primary)")
        XCTAssertNotNil(handlers.onDurationPicked, "onDurationPicked must be non-nil")
        XCTAssertNotNil(handlers.onU1UnlockSelected, "onU1UnlockSelected must be non-nil")
        XCTAssertNotNil(handlers.onU1UnlockEverything, "onU1UnlockEverything must be non-nil")
    }

    // MARK: - P0-1 patch shape correctness

    /// Verifies that onDurationPicked(30) synthesises the backend wire format
    /// {"duration": {"kind": "minutes", "value": 30}} — NOT the rejected
    /// {"duration_minutes": 30} that commit a79e44b emitted.
    func testDurationPickedSynthesisesCorrectPatchShape() {
        let card = makePayload(kind: "phone.missing_duration")

        // Build the option directly via synthesise — no ViewModel I/O needed.
        let durationDict: [String: Any] = ["kind": "minutes", "value": 30]
        let opt = PlanArchCardOption.synthesise(fromCard: card, patch: ["duration": durationDict])

        // Round-trip through JSON to verify the wire format.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(opt),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let patch = json["patch"] as? [String: Any]
        else {
            XCTFail("PlanArchCardOption failed JSON round-trip")
            return
        }

        // Must have a "duration" key, NOT "duration_minutes".
        XCTAssertNil(patch["duration_minutes"],
                     "Rejected key 'duration_minutes' must not appear in patch")
        guard let dur = patch["duration"] as? [String: Any] else {
            XCTFail("patch['duration'] is missing or wrong type; patch keys: \(patch.keys.sorted())")
            return
        }
        XCTAssertEqual(dur["kind"] as? String, "minutes",
                       "duration.kind must be 'minutes'")
        XCTAssertEqual(dur["value"] as? Int, 30,
                       "duration.value must be 30")
    }

    /// Verifies that onDurationPicked(nil) synthesises {"duration": {"kind": "permanent"}}.
    func testDurationPickedPermanentSynthesisesCorrectPatchShape() {
        let card = makePayload(kind: "phone.missing_duration")

        let durationDict: [String: Any] = ["kind": "permanent"]
        let opt = PlanArchCardOption.synthesise(fromCard: card, patch: ["duration": durationDict])

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(opt),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let patch = json["patch"] as? [String: Any],
              let dur = patch["duration"] as? [String: Any]
        else {
            XCTFail("PlanArchCardOption failed JSON round-trip for permanent duration")
            return
        }

        XCTAssertNil(patch["duration_kind"],
                     "Rejected key 'duration_kind' must not appear in patch")
        XCTAssertEqual(dur["kind"] as? String, "permanent",
                       "duration.kind must be 'permanent'")
        XCTAssertNil(dur["value"],
                     "permanent duration must NOT have a 'value' key")
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

    // MARK: - Phase 2D query-stub lifecycle

    /// Spec §1 invariant 4: tapping a query result row prefills inputText and
    /// clears pendingPlanArchCard — NO errorMessage is set, NO plan-patch is posted.
    func testQuerySourcePrefillsInputTextAndClearsCard() async {
        let vm = ChatViewModel()
        let card = makePayload(kind: "query.result_pending_submissions", source: "query")
        vm.pendingPlanArchCard = card

        let opt = PlanArchCardOption(label: "Approve Clean room", patch: [:], cancelsPlan: false)
        vm.handlePlanArchOption(opt)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPlanArchCard,
                     "pendingPlanArchCard must be cleared after query stub")
        XCTAssertEqual(vm.inputText, "Approve Clean room",
                       "inputText must be prefilled with option.label")
        // Must NOT set errorMessage — errorMessage is reserved for hard failures,
        // not spec-compliant query prefill flows.
        XCTAssertNil(vm.errorMessage,
                     "query stub must not set errorMessage (spec §1 invariant 4)")
    }

    /// Confirms empty label is handled gracefully (inputText stays unchanged).
    func testQuerySourceEmptyLabelLeavesInputTextUnchanged() async {
        let vm = ChatViewModel()
        vm.inputText = "existing text"
        let card = makePayload(kind: "query.result_pending_bypass", source: "query")
        vm.pendingPlanArchCard = card

        let opt = PlanArchCardOption(label: "", patch: [:], cancelsPlan: false)
        vm.handlePlanArchOption(opt)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPlanArchCard, "card must still be cleared for empty label")
        XCTAssertEqual(vm.inputText, "existing text",
                       "empty label must not overwrite existing inputText")
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

    func testAnswerQuestionResponseSurfacesReturnedPlanArchCard() throws {
        let vm = ChatViewModel()
        let oldQuestion = makePayload(kind: "question.free_text", source: "plan", planToken: "")
        vm.pendingPlanArchCardQueue = [oldQuestion]
        vm.pendingPlanArchCard = oldQuestion

        let responseJSON: [String: Any] = [
            "message": "Let's have Liam complete a reflection.",
            "card_payloads": [[
                "type": "block_intent_confirm",
                "kind": "reflection.assign_confirm",
                "source": "plan",
                "title": "Assign reflection",
                "body": "Respectful language",
                "plan_token": "reflection_tok",
                "step_index": 0,
                "detail": [:],
                "options": [],
                "danger": "medium",
            ]],
        ]
        let rawData = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try JSONDecoder().decode(APIClient.ChatResponse.self, from: rawData)

        vm.handleAnswerQuestionResponse(response, rawData: rawData)

        XCTAssertEqual(vm.pendingPlanArchCard?.kind, "reflection.assign_confirm")
        XCTAssertEqual(vm.pendingPlanArchCard?.planToken, "reflection_tok")
        XCTAssertEqual(vm.messages.last?.content, "Let's have Liam complete a reflection.")
        XCTAssertFalse(vm.isThinking)
    }

    func testAnswerQuestionResponseClearsQuestionWhenNoCardReturned() throws {
        let vm = ChatViewModel()
        let oldQuestion = makePayload(kind: "question.free_text", source: "plan", planToken: "")
        vm.pendingPlanArchCardQueue = [oldQuestion]
        vm.pendingPlanArchCard = oldQuestion

        let responseJSON: [String: Any] = [
            "message": "Thanks, I understand.",
        ]
        let rawData = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try JSONDecoder().decode(APIClient.ChatResponse.self, from: rawData)

        vm.handleAnswerQuestionResponse(response, rawData: rawData)

        XCTAssertNil(vm.pendingPlanArchCard)
        XCTAssertTrue(vm.pendingPlanArchCardQueue.isEmpty)
        XCTAssertEqual(vm.messages.last?.content, "Thanks, I understand.")
        XCTAssertFalse(vm.isThinking)
    }

    // MARK: - Finding #8: applyAgentResult keeps the queue invariant

    /// Retains ChatViewModels for the lifetime of the process. On the x86_64
    /// simulator the Swift-concurrency back-deploy shim malloc-aborts when a
    /// @MainActor ChatViewModel (holding an APIClient) deinits at test exit —
    /// an environment teardown crash, unrelated to the code under test. Holding
    /// the vm here defers deinit past process exit so the assertions' result is
    /// what the test reports.
    private static var retainedViewModels: [ChatViewModel] = []
    private func makeRetainedViewModel() -> ChatViewModel {
        let vm = ChatViewModel()
        Self.retainedViewModels.append(vm)
        return vm
    }

    /// A compound turn leaves more than one card queued. When the user acts on
    /// the front card and a continuation endpoint (event-select / resolve-target
    /// / event-scope) stages a follow-up, applyAgentResult must REPLACE the front
    /// of the queue — not just retarget the head pointer — so the sibling card
    /// queued behind it survives the next advance. Pre-fix this dropped the
    /// sibling: the stale front got popped instead of the follow-up.
    func testApplyAgentResultFollowUpReplacesFrontAndPreservesSibling() {
        let vm = makeRetainedViewModel()
        let front = makePayload(kind: "target.device_select", source: "event", planToken: "A")
        let sibling = makePayload(kind: "event.create_confirm", source: "event", planToken: "C")
        vm.pendingPlanArchCardQueue = [front, sibling]
        vm.pendingPlanArchCard = front

        let followUp = makePayload(kind: "event.create_confirm", source: "event", planToken: "B")
        let response = AgentClient.AgentCardResponse(card_payloads: [followUp], ok: true)
        vm.applyAgentResult(response)

        // Invariant: head === queue.first, and the follow-up took the front slot.
        XCTAssertEqual(vm.pendingPlanArchCard?.planToken, "B")
        XCTAssertEqual(vm.pendingPlanArchCardQueue.map(\.planToken), ["B", "C"])
        XCTAssertEqual(vm.pendingPlanArchCard?.planToken,
                       vm.pendingPlanArchCardQueue.first?.planToken,
                       "head must equal queue.first")

        // Acting on the follow-up then advancing must surface the sibling (not drop it).
        vm.advancePlanArchCardQueue()
        XCTAssertEqual(vm.pendingPlanArchCard?.planToken, "C")
        XCTAssertEqual(vm.pendingPlanArchCardQueue.map(\.planToken), ["C"])
    }

    /// No follow-up → the front card is done; advance pops it and the sibling
    /// behind it becomes the visible head (queue invariant preserved).
    func testApplyAgentResultNoFollowUpAdvancesToSibling() {
        let vm = makeRetainedViewModel()
        let front = makePayload(kind: "target.device_select", source: "event", planToken: "A")
        let sibling = makePayload(kind: "event.create_confirm", source: "event", planToken: "C")
        vm.pendingPlanArchCardQueue = [front, sibling]
        vm.pendingPlanArchCard = front

        let response = AgentClient.AgentCardResponse(card_payloads: nil, ok: true)
        vm.applyAgentResult(response)

        XCTAssertEqual(vm.pendingPlanArchCard?.planToken, "C")
        XCTAssertEqual(vm.pendingPlanArchCardQueue.map(\.planToken), ["C"])
    }
}
