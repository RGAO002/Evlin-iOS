import XCTest
@testable import Evlin_iOS

final class StoredChatMessageTests: XCTestCase {

    func test_sanitizing_drops_command_and_receipt_state() {
        // ChatMessage init (ChatModels.swift:162-176) takes only
        // (role,content,timestamp,reasoning,action,debugTurnID); commandID +
        // receiptState are mutable vars (ChatModels.swift:142-143) — set post-init.
        var live = ChatMessage(role: .agent, content: "Locked", timestamp: Date())
        live.commandID = UUID(); live.receiptState = .pending
        let stored = StoredChatMessage(sanitizing: live)
        let inert = stored.asInertChatMessage()
        XCTAssertNil(inert.commandID)
        XCTAssertNotEqual(inert.receiptState, .pending)  // terminal/nil, never resumes polling
        XCTAssertEqual(inert.content, "Locked")
    }

    func test_round_trip_codable_preserves_core_fields() throws {
        var live = ChatMessage(role: .parent, content: "Hello", timestamp: Date(timeIntervalSince1970: 1_000_000))
        live.commandID = UUID()
        live.receiptState = .pending
        let stored = StoredChatMessage(sanitizing: live)

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredChatMessage.self, from: data)

        XCTAssertEqual(decoded.role, .parent)
        XCTAssertEqual(decoded.content, "Hello")
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, 1_000_000, accuracy: 0.001)
    }

    func test_sanitizing_freezes_confirmed_receipt_into_summary() {
        var live = ChatMessage(role: .agent, content: "Done", timestamp: Date())
        live.commandID = UUID()
        live.receiptState = .kidNotResponding
        let stored = StoredChatMessage(sanitizing: live)
        XCTAssertNotNil(stored.receiptSummary)
    }

    func test_inert_message_never_resumes_ack_poll() {
        // The guard in ChatViewModel.resumePendingAckPolls (line 149-151) is:
        //   msg.role == .agent && msg.receiptState == .pending && msg.commandID != nil
        // A restored message must NEVER satisfy all three conditions simultaneously.
        var live = ChatMessage(role: .agent, content: "X", timestamp: Date())
        live.commandID = UUID()
        live.receiptState = .pending
        let inert = StoredChatMessage(sanitizing: live).asInertChatMessage()

        let wouldResumePoll = inert.role == .agent
            && inert.receiptState == .pending
            && inert.commandID != nil
        XCTAssertFalse(wouldResumePoll)
    }
}
