import XCTest
@testable import Evlin_iOS

final class FirstActionsLogicTests: XCTestCase {
    func testAddAppSaveResultRequiresBundleBackedExactAppForFirstBlockReadiness() {
        XCTAssertFalse(
            AddAppFlowSaveResult(savedApps: 0, savedCategories: 1, blockableAppCount: 0).isReadyForFirstBlock,
            "Category-only capture must not let kid onboarding mark first block ready."
        )
        XCTAssertFalse(
            AddAppFlowSaveResult(savedApps: 1, savedCategories: 0, blockableAppCount: 0).isReadyForFirstBlock,
            "Manual app captures without bundle id cannot drive the first app block."
        )
        XCTAssertTrue(
            AddAppFlowSaveResult(savedApps: 1, savedCategories: 1, blockableAppCount: 1).isReadyForFirstBlock
        )
    }

    func testBlockTargetRequiresRealKidCatalogApp() {
        XCTAssertNil(
            FirstActionsLogic.blockTarget(firstCatalogAppAliasKey: nil),
            "First block must wait for the kid device to register a real app; do not fall back to a synthetic category/app."
        )
    }

    func testBlockTargetUsesKidCatalogAliasKeyWhenReady() {
        let aliasKey = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(
            FirstActionsLogic.blockTarget(firstCatalogAppAliasKey: aliasKey),
            .appID(aliasKey)
        )
    }

    func testGeneralLockSetupCanContinueWithCategoryOnly() {
        let model = LockSetupCatalogPresentationModel(
            apps: [],
            categories: [
                .init(aliasKey: UUID(), type: .category, displayName: "Games")
            ],
            lists: []
        )

        XCTAssertTrue(model.hasUsableTarget)
        XCTAssertFalse(model.hasBlockableApp)
    }

    func testFirstBlockRequiresBundleBackedApp() {
        let model = LockSetupCatalogPresentationModel(
            apps: [
                .init(aliasKey: UUID(), type: .app, displayName: "Manual Token", bundleID: nil)
            ],
            categories: [],
            lists: []
        )

        XCTAssertTrue(model.hasUsableTarget)
        XCTAssertFalse(model.hasBlockableApp)
    }

    func testPayoffCopyNeverClaimsSuccessBeforeLanded() {
        XCTAssertFalse(
            FirstActionsLogic.payoffSubtitle(phase: .waitingForKid, kidName: "Ava").localizedCaseInsensitiveContains("applied the lock")
        )
        XCTAssertFalse(
            FirstActionsLogic.payoffSubtitle(phase: .timedOut, kidName: "Ava").localizedCaseInsensitiveContains("applied the lock")
        )
        XCTAssertTrue(
            FirstActionsLogic.payoffSubtitle(phase: .landed, kidName: "Ava").localizedCaseInsensitiveContains("applied the lock")
        )
    }
}
