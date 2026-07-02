import XCTest
@testable import Evlin_iOS

final class ReceiptAttachTests: XCTestCase {
    private func receipt(summary: String = "Done.") -> ReceiptDTO {
        ReceiptDTO(tool: "assign_task", args: [:], summary: summary,
                   undoToken: nil, undoExpiresAt: nil)
    }

    func test_attachesToLastAgentMessage_andRemovesProposal() {
        let p = ProposalDTO(tool: "assign_task", args: [:], label: "L",
                            danger: "low", token: "tok1")
        var msg = ChatMessage(role: .agent, content: "Shall I?",
                              timestamp: Date(), reasoning: nil, action: nil)
        msg.proposals = [p]
        let out = ChatViewModel.attachingExecReceipt(
            receipt(), proposalToken: "tok1", to: [msg])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].receipts?.count, 1)
        XCTAssertEqual(out[0].proposals?.isEmpty, true)
    }

    func test_fallback_appendsNewBubble_whenNoAgentMessage() {
        let userOnly = ChatMessage(role: .parent, content: "add task",
                                   timestamp: Date(), reasoning: nil, action: nil)
        let out = ChatViewModel.attachingExecReceipt(
            receipt(summary: "Task added."), proposalToken: "tok1", to: [userOnly])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].role, .agent)
        XCTAssertEqual(out[1].content, "Task added.")
        XCTAssertEqual(out[1].receipts?.count, 1)
    }
}
