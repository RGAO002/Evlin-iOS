import XCTest
@testable import Evlin_iOS

final class BrainTurnIDTests: XCTestCase {
    func testChatMessagePersistsDebugTurnID() throws {
        let message = ChatMessage(
            role: .agent,
            content: "Hello",
            timestamp: Date(timeIntervalSince1970: 1),
            debugTurnID: "turn:abc123"
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.debugTurnID, "turn:abc123")
    }
}
