@testable import Evlin_iOS
import XCTest

final class AddTargetFlowRulesTests: XCTestCase {
    func test_addAppWithAppsAndCategoriesSavesAppsAndWarnsCategoriesIgnored() {
        let decision = AddTargetFlowRules.decision(
            mode: .app,
            appCount: 2,
            categoryCount: 1,
            webDomainCount: 0
        )

        XCTAssertEqual(decision.action, .saveApps)
        XCTAssertEqual(decision.warning, "Category selections were ignored. Add categories from Add category.")
    }

    func test_addAppWithCategoryOnlyRejects() {
        let decision = AddTargetFlowRules.decision(
            mode: .app,
            appCount: 0,
            categoryCount: 1,
            webDomainCount: 0
        )

        XCTAssertEqual(decision.action, .reject)
        XCTAssertEqual(decision.warning, "Expand the category or search to select individual apps.")
    }

    func test_addCategoryWithCategoriesAndAppsSavesCategoriesAndWarnsAppsIgnored() {
        let decision = AddTargetFlowRules.decision(
            mode: .category,
            appCount: 1,
            categoryCount: 2,
            webDomainCount: 0
        )

        XCTAssertEqual(decision.action, .saveCategories)
        XCTAssertEqual(decision.warning, "App selections were ignored. Add apps from Add app.")
    }

    func test_addCategoryWithAppOnlyRejects() {
        let decision = AddTargetFlowRules.decision(
            mode: .category,
            appCount: 1,
            categoryCount: 0,
            webDomainCount: 0
        )

        XCTAssertEqual(decision.action, .reject)
        XCTAssertEqual(decision.warning, "Select a category, not an individual app.")
    }
}
