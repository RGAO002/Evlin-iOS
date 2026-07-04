import XCTest
@testable import Evlin_iOS

final class ChatStreamIntegrationTests: XCTestCase {
    func test_reconcile_envelope_wins() {
        XCTAssertEqual(ChatViewModel.reconcileStreamedEnvelope(
            revealedSoFar: "Hel", envelopeMessage: "Hello parent"), "Hello parent")
        XCTAssertEqual(ChatViewModel.reconcileStreamedEnvelope(
            revealedSoFar: "totally different", envelopeMessage: "X"), "X")
    }

    func test_stage_dedup_ignores_same_label() {
        XCTAssertFalse(ChatViewModel.shouldUpdateStage(
            current: "Checking tasks…", incoming: "Checking tasks…"))
        XCTAssertTrue(ChatViewModel.shouldUpdateStage(
            current: "Checking tasks…", incoming: "Looking at the calendar…"))
        XCTAssertTrue(ChatViewModel.shouldUpdateStage(
            current: nil, incoming: "Thinking…"))
    }

    func test_stream_failure_before_text_falls_back_to_legacy() {
        XCTAssertTrue(ChatViewModel.shouldFallbackToLegacyAfterStreamFailure(
            hasReceivedText: false,
            hasReceivedEnvelope: false
        ))
    }

    func test_stream_failure_after_text_does_not_double_send() {
        XCTAssertFalse(ChatViewModel.shouldFallbackToLegacyAfterStreamFailure(
            hasReceivedText: true,
            hasReceivedEnvelope: false
        ))
        XCTAssertFalse(ChatViewModel.shouldFallbackToLegacyAfterStreamFailure(
            hasReceivedText: false,
            hasReceivedEnvelope: true
        ))
    }

    func test_visible_stream_error_copy_is_not_blank() {
        XCTAssertFalse(ChatViewModel.visibleStreamErrorMessage("Server error 500").isEmpty)
    }

    func test_stage_clear_waits_until_minimum_visible_duration() {
        XCTAssertGreaterThan(
            ChatViewModel.stageClearDelay(
                elapsed: 0.1,
                minimumVisibleDuration: 0.6
            ),
            0
        )
        XCTAssertEqual(
            ChatViewModel.stageClearDelay(
                elapsed: 0.7,
                minimumVisibleDuration: 0.6
            ),
            0,
            accuracy: 0.001
        )
    }

    func test_safety_status_prompt_detection() {
        XCTAssertTrue(ChatViewModel.isSafetyStatusPrompt("Is my kid safe?"))
        XCTAssertTrue(ChatViewModel.isSafetyStatusPrompt("Where is K right now?"))
        XCTAssertFalse(ChatViewModel.isSafetyStatusPrompt("Lock YouTube for 30 minutes"))
    }

    func test_initial_stage_label_for_calendar_requests() {
        XCTAssertEqual(
            ChatViewModel.initialStageLabel(for: "Add three events for K next Tuesday"),
            "Looking at the calendar…"
        )
    }

    func test_initial_stage_label_for_plain_chat() {
        XCTAssertEqual(ChatViewModel.initialStageLabel(for: "hello"), "Thinking…")
    }
}
