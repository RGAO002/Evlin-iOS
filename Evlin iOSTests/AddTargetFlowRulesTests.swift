@testable import Evlin_iOS
import XCTest

final class AddTargetFlowRulesTests: XCTestCase {
    func test_addAppPickerExpandsSelectedCategoriesIntoApplicationTokens() {
        XCTAssertTrue(AddTargetPickerConfiguration.includeEntireCategory(for: .app))
    }

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
        XCTAssertEqual(decision.warning, "That is a category selection. Search for the app and select the app row itself.")
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

    func test_blankCategoryLabelBlocksSave() {
        let row = PendingCategoryRow(
            semanticKey: "games",
            displayName: "   ",
            tokenBase64: "Q0FURUdPUlk="
        )

        XCTAssertFalse(row.isNamedCategory)
    }

    func test_typedCategoryNameIsUsedInUploadPayload() {
        let deviceID = UUID()
        let row = PendingCategoryRow(
            semanticKey: "games",
            displayName: "Arcade Games",
            tokenBase64: "Q0FURUdPUlk="
        )

        let upload = row.makeUploadCategory(sourceDeviceID: deviceID)

        XCTAssertTrue(row.isNamedCategory)
        XCTAssertEqual(upload.displayName, "Arcade Games")
        XCTAssertEqual(upload.aliases, ["Arcade Games", "games"])
        XCTAssertEqual(upload.sourceDeviceID, deviceID)
    }

    func test_missingCategoryPickerLabelStartsBlankForPlaceholder() {
        XCTAssertEqual(PendingCategoryRow.initialDisplayName(pickerLabel: nil), "")
        XCTAssertEqual(PendingCategoryRow.initialDisplayName(pickerLabel: "   "), "")
    }

    func test_categoryPickerLabelUsesTrimmedVisibleName() {
        XCTAssertEqual(PendingCategoryRow.initialDisplayName(pickerLabel: "  Games  "), "Games")
    }

    func test_categorySuggestionsFilterKnownAppleCategories() {
        XCTAssertEqual(
            AppleScreenTimeCategorySuggestions.matches(for: "ent").map(\.displayName),
            ["Entertainment"]
        )
        XCTAssertEqual(
            AppleScreenTimeCategorySuggestions.matches(for: "social").map(\.displayName),
            ["Social"]
        )
        XCTAssertEqual(
            AppleScreenTimeCategorySuggestions.matches(for: "category").map(\.displayName),
            [
                "Social",
                "Games",
                "Entertainment",
                "Creativity",
                "Productivity & Finance",
                "Education",
                "Information & Reading",
                "Health & Fitness",
                "Shopping & Food",
                "Travel",
                "Utilities",
                "Other",
            ]
        )
        XCTAssertEqual(
            AppleScreenTimeCategorySuggestions.matches(for: "reading").map(\.displayName),
            ["Information & Reading"]
        )
        XCTAssertEqual(
            AppleScreenTimeCategorySuggestions.matches(for: "info").map(\.displayName),
            ["Information & Reading"]
        )
    }

    func test_categorySuggestionAppliesDisplayNameAndSemanticAlias() {
        var row = PendingCategoryRow(
            semanticKey: "category",
            displayName: "",
            tokenBase64: "Q0FURUdPUlk="
        )

        row.applySuggestion(.games)
        let upload = row.makeUploadCategory(sourceDeviceID: nil)

        XCTAssertEqual(row.displayName, "Games")
        XCTAssertEqual(row.semanticKey, "games")
        XCTAssertEqual(upload.aliases, ["Games", "games"])
    }

    func test_blankCategoryShowsAllAppleSuggestionCapsules() {
        XCTAssertEqual(
            AppleScreenTimeCategorySuggestions.visibleCapsules(for: "").map(\.displayName),
            AppleScreenTimeCategorySuggestions.all.map(\.displayName)
        )
    }

    func test_categorySuggestionSelectionMatchesSemanticKey() {
        var row = PendingCategoryRow(
            semanticKey: "category",
            displayName: "",
            tokenBase64: "Q0FURUdPUlk="
        )

        XCTAssertFalse(row.matchesSuggestion(.games))

        row.applySuggestion(.games)

        XCTAssertTrue(row.matchesSuggestion(.games))
        XCTAssertFalse(row.matchesSuggestion(.social))
    }

    func test_informationReadingSuggestionUsesReadingAlias() {
        var row = PendingCategoryRow(
            semanticKey: "category",
            displayName: "",
            tokenBase64: "Q0FURUdPUlk="
        )

        row.applySuggestion(.informationAndReading)
        let upload = row.makeUploadCategory(sourceDeviceID: nil)

        XCTAssertEqual(row.displayName, "Information & Reading")
        XCTAssertEqual(row.semanticKey, "reading")
        XCTAssertEqual(upload.aliases, ["Information & Reading", "reading"])
    }
}
