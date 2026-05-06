// Evlin iOSTests/LazyTagTests.swift
import XCTest
@testable import Evlin_iOS

final class LazyTagPersistenceTests: XCTestCase {
    /// Passing a non-token Any (e.g. String) for `.app` mode must produce
    /// `.wrongTokenType`. We can't mint real ApplicationToken in tests
    /// (FamilyControls auth is unavailable), so we test only the
    /// type-mismatch branch — the success branch is covered by manual E2E.
    func test_persistAlias_rejectsWrongTypeForApp() {
        let result = LazyTagPersistence.persistAlias(
            token: "not a token" as Any,
            kind: .app,
            target: "Instagram"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsWrongTypeForCategory() {
        let result = LazyTagPersistence.persistAlias(
            token: 42 as Any,
            kind: .category,
            target: "games"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsEmptyTarget() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: "   "
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .emptyTarget)
        case .success: XCTFail("expected emptyTarget failure")
        }
    }
}

final class ExtractAliasTargetTests: XCTestCase {
    private func proposal(tool: String, args: [String: Any]) -> ProposalDTO {
        let typed = args.mapValues { AnyCodable($0) }
        return ProposalDTO(
            tool: tool,
            args: typed,
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
    }

    func test_returnsAppTarget_forShieldAppLegacy_withAppKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "Instagram",
            "target_kind": "app"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "Instagram")
        XCTAssertEqual(result?.kind, .app)
    }

    func test_returnsCategoryTarget_forShieldAppLegacy_withCategoryKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "games",
            "target_kind": "category"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "games")
        XCTAssertEqual(result?.kind, .category)
    }

    func test_returnsNil_forNonShieldTool() {
        let p = proposal(tool: "propose_reflection", args: [
            "target": "anything"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_whenTargetMissing() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target_kind": "app"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_forUnknownKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "x",
            "target_kind": "weird"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }
}
