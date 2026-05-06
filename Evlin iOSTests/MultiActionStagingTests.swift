import XCTest
@testable import Evlin_iOS

final class ExtractAliasTargetsTests: XCTestCase {
    private func proposal(tool: String, rows: [[String: Any]]) -> ProposalDTO {
        let typedRows = rows.map { row in
            row.mapValues { AnyCodable($0) }
        }
        let typedRowsCodable = AnyCodable(typedRows)
        return ProposalDTO(
            tool: tool,
            args: ["rows": typedRowsCodable],
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
    }

    func test_extractsAllRows() {
        let p = proposal(tool: "shield_app_legacy", rows: [
            ["target": "IG", "target_kind": "app"],
            ["target": "TT", "target_kind": "app"],
            ["target": "Entertainment", "target_kind": "category"],
        ])
        let result = ChatViewModel.extractAliasTargets(from: p)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]?.target, "IG")
        XCTAssertEqual(result[0]?.kind, .app)
        XCTAssertEqual(result[2]?.target, "Entertainment")
        XCTAssertEqual(result[2]?.kind, .category)
    }

    func test_legacy_singleArgsShape_returnsSingleRow() {
        // Old proposals (pre-bundling) had {target, target_kind} at top level.
        let p = ProposalDTO(
            tool: "shield_app_legacy",
            args: [
                "target": AnyCodable("IG"),
                "target_kind": AnyCodable("app"),
            ],
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
        let result = ChatViewModel.extractAliasTargets(from: p)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]?.target, "IG")
    }

    func test_returnsEmpty_forNonShieldTool() {
        let p = ProposalDTO(
            tool: "propose_reflection", args: [:],
            label: "test", danger: "low", token: UUID().uuidString
        )
        XCTAssertTrue(ChatViewModel.extractAliasTargets(from: p).isEmpty)
    }
}

final class AnyCodableNestedTests: XCTestCase {
    func test_decodesNestedArrayOfDicts() throws {
        let json = """
        {"rows": [{"target": "IG", "target_kind": "app", "minutes": 15}]}
        """.data(using: .utf8)!
        struct Wrap: Decodable { let rows: AnyCodable }
        let decoded = try JSONDecoder().decode(Wrap.self, from: json)
        let rows = decoded.rows.value as? [Any]
        XCTAssertNotNil(rows)
        XCTAssertEqual(rows?.count, 1)
        let first = rows?.first as? [String: Any]
        XCTAssertEqual(first?["target"] as? String, "IG")
        XCTAssertEqual(first?["minutes"] as? Int, 15)
    }
}
