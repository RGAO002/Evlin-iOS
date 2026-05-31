// Evlin iOSTests/LazyTagTests.swift
import XCTest
@testable import Evlin_iOS

final class LazyTagCatalogModelTests: XCTestCase {
    private let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let categoryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let listID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func test_sectionsAlwaysAppearInAppCategoryListOrder() {
        let targets: [LazyTagCatalogTarget] = [
            .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["fun"], memberCount: 3),
            .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"], bundleID: "com.burbn.instagram", artworkURL: URL(string: "https://example.com/ig.png"), isManual: false),
            .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["gaming"])
        ]

        let sections = LazyTagCatalogModel.sections(from: targets, searchText: "")

        XCTAssertEqual(sections.map(\.type), [.app, .category, .list])
        XCTAssertEqual(sections.map(\.title), ["App", "Category", "List"])
        XCTAssertEqual(sections[0].targets.map(\.displayName), ["Instagram"])
        XCTAssertEqual(sections[1].targets.map(\.displayName), ["Games"])
        XCTAssertEqual(sections[2].targets.map(\.displayName), ["Entertainment"])
    }

    func test_sectionSearchMatchesDisplayNameAndAliasesWithoutDroppingSections() {
        let targets: [LazyTagCatalogTarget] = [
            .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"]),
            .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["gaming"]),
            .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["weekend"])
        ]

        let sections = LazyTagCatalogModel.sections(from: targets, searchText: "ig")

        XCTAssertEqual(sections.map(\.type), [.app, .category, .list])
        XCTAssertEqual(sections[0].targets.map(\.displayName), ["Instagram"])
        XCTAssertEqual(sections[1].targets, [])
        XCTAssertEqual(sections[2].targets, [])
    }

    func test_categorySubtitleUsesBroadCoverageCopy() {
        let target = LazyTagCatalogTarget(
            aliasKey: categoryID,
            type: .category,
            displayName: "Games",
            aliases: []
        )

        XCTAssertEqual(target.supportingText, "Current + future apps Apple classifies as Games")
    }
}

final class LazyTagPersistenceTests: XCTestCase {
    func test_normalizedAlias_trimsAliasBeforeBackendSave() {
        let result = LazyTagPersistence.normalizedAlias("  抖音  ")
        switch result {
        case .success(let alias): XCTAssertEqual(alias, "抖音")
        case .failure: XCTFail("expected trimmed alias")
        }
    }

    func test_persistCatalogAlias_rejectsMissingFamilyBeforeNetwork() async {
        let target = LazyTagCatalogTarget(
            aliasKey: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            type: .app,
            displayName: "TikTok"
        )

        let result = await LazyTagPersistence.persistCatalogAlias(
            target: target,
            requestedAlias: "抖音",
            familyID: nil,
            childDeviceID: UUID()
        )

        switch result {
        case .failure(let err): XCTAssertEqual(err, .missingFamily)
        case .success: XCTFail("expected missingFamily failure")
        }
    }

    func test_persistCatalogAlias_rejectsMissingChildDeviceBeforeNetwork() async {
        let target = LazyTagCatalogTarget(
            aliasKey: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            type: .app,
            displayName: "TikTok"
        )

        let result = await LazyTagPersistence.persistCatalogAlias(
            target: target,
            requestedAlias: "抖音",
            familyID: UUID(),
            childDeviceID: nil
        )

        switch result {
        case .failure(let err): XCTAssertEqual(err, .missingChildDevice)
        case .success: XCTFail("expected missingChildDevice failure")
        }
    }

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

final class LazyTagUniversalFallbackTests: XCTestCase {
    /// Contract: a lazy-tag for an app can only bind a real ApplicationToken.
    /// Unit tests cannot mint FamilyControls tokens, so this pins the guard
    /// that prevents bad picker output from creating a false app binding.
    func test_appKind_requiresApplicationToken() {
        let result = LazyTagPersistence.persistAlias(
            token: 7 as Any,
            kind: .app,
            target: "Bilibili"
        )
        switch result {
        case .failure(let error): XCTAssertEqual(error, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType")
        }
    }

    /// Blank names must never be persisted as aliases; otherwise future
    /// natural-language locks could resolve to an invisible bad binding.
    func test_emptyTarget_isRejected_soCatalogNeverBindsBlankName() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: " "
        )
        switch result {
        case .failure(let error): XCTAssertEqual(error, .emptyTarget)
        case .success: XCTFail("expected emptyTarget")
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
