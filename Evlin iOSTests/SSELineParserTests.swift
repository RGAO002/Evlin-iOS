import XCTest
@testable import Evlin_iOS

final class SSELineParserTests: XCTestCase {
    func test_accumulates_until_blank_line() {
        var p = SSELineParser()
        XCTAssertNil(p.feed(line: "event: stage"))
        XCTAssertNil(p.feed(line: "data: {\"key\":\"tool:x\",\"label\":\"Thinking…\"}"))
        let ev = p.feed(line: "")
        XCTAssertEqual(ev?.event, "stage")
        XCTAssertEqual(ev?.data.contains("tool:x"), true)
    }

    func test_comment_lines_ignored() {
        var p = SSELineParser()
        XCTAssertNil(p.feed(line: ": heartbeat"))
        XCTAssertNil(p.feed(line: ""))
    }

    func test_multi_data_lines_joined_with_newline() {
        var p = SSELineParser()
        _ = p.feed(line: "event: envelope")
        _ = p.feed(line: "data: {\"a\":")
        _ = p.feed(line: "data: 1}")
        let ev = p.feed(line: "")
        XCTAssertEqual(ev?.data, "{\"a\":\n1}")
    }

    func test_parse_chat_events() {
        let stage = ChatStreamEvent.parse(SSEEvent(
            event: "stage", data: "{\"key\":\"tool:x\",\"label\":\"Thinking…\"}"))
        XCTAssertEqual(stage, .stage(key: "tool:x", label: "Thinking…"))
        let delta = ChatStreamEvent.parse(SSEEvent(
            event: "text_delta", data: "{\"t\":\"Hel\"}"))
        XCTAssertEqual(delta, .textDelta("Hel"))
        XCTAssertNil(ChatStreamEvent.parse(SSEEvent(event: "unknown", data: "{}")))
    }
}
