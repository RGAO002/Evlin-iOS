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
}
