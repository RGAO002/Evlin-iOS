@testable import Evlin_iOS
import XCTest

final class AddTargetFlowRulesTests: XCTestCase {
    func test_addAppWithAppsCategoriesAndWebsitesSavesAppsAndWarnsIgnoredTokens() {
        let decision = AddTargetFlowRules.decision(
            mode: .app,
            appCount: 2,
            categoryCount: 1,
            webDomainCount: 1
        )

        XCTAssertEqual(decision.action, .saveApps)
        XCTAssertEqual(decision.warning, "Category and website selections were ignored.")
    }

    func test_addAppWithCategoryOnlyRejectsInPicker() {
        let decision = AddTargetFlowRules.decision(
            mode: .app,
            appCount: 0,
            categoryCount: 1,
            webDomainCount: 0
        )

        XCTAssertEqual(decision.action, .reject)
        XCTAssertEqual(decision.warning, "Expand categories or search to select individual apps.")
    }

    func test_addCategoryWithCategoriesAppsAndWebsitesSavesCategoriesAndWarnsIgnoredTokens() {
        let decision = AddTargetFlowRules.decision(
            mode: .category,
            appCount: 1,
            categoryCount: 2,
            webDomainCount: 1
        )

        XCTAssertEqual(decision.action, .saveCategories)
        XCTAssertEqual(decision.warning, "App and website selections were ignored.")
    }

    func test_addCategoryWithAppOnlyRejectsInPicker() {
        let decision = AddTargetFlowRules.decision(
            mode: .category,
            appCount: 1,
            categoryCount: 0,
            webDomainCount: 0
        )

        XCTAssertEqual(decision.action, .reject)
        XCTAssertEqual(decision.warning, "Select a category, not an individual app.")
    }

    func test_webDomainOnlyRejectsBothModes() {
        XCTAssertEqual(
            AddTargetFlowRules.decision(
                mode: .app,
                appCount: 0,
                categoryCount: 0,
                webDomainCount: 1
            ).action,
            .reject
        )
        XCTAssertEqual(
            AddTargetFlowRules.decision(
                mode: .category,
                appCount: 0,
                categoryCount: 0,
                webDomainCount: 1
            ).action,
            .reject
        )
    }

    func test_pickerShellRejectKeepsPickerOpen() {
        var model = AddTargetPickerShellModel()

        let saved = model.attemptSave(
            decision: .init(
                action: .reject,
                warning: "Select a category, not an individual app."
            )
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.errorBanner, "Select a category, not an individual app.")
    }

    func test_pickerShellValidSaveDismissesPicker() {
        var model = AddTargetPickerShellModel()

        let saved = model.attemptSave(decision: .init(action: .saveApps, warning: nil))

        XCTAssertTrue(saved)
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.errorBanner)
    }
}
