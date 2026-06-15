@testable import Evlin_iOS
import XCTest

final class LockSetupRecoverySyncTests: XCTestCase {
    func test_localRecoveryUploadSkipsRowsAlreadyInBackendCatalog() {
        let backend = LockSetupCatalogPresentationModel(
            apps: [
                .init(
                    aliasKey: UUID(),
                    type: .app,
                    displayName: "Instagram",
                    aliases: ["ig"],
                    bundleID: "com.burbn.instagram"
                )
            ],
            categories: [],
            lists: []
        )
        let localRows = [
            LockListAppEntry(label: "Instagram", keys: ["instagram"], bundleID: "com.burbn.instagram"),
            LockListAppEntry(label: "YouTube", keys: ["youtube"], bundleID: "com.google.ios.youtube"),
        ]

        let missing = LockSetupRecoveryPlanner.missingLocalApps(localRows, backend: backend)

        XCTAssertEqual(missing.map(\.label), ["YouTube"])
    }

    func test_localRecoveryIncludesAdvancedTokenRows() {
        let snapshot = LockListManagerSnapshot(
            apps: [
                LockListAppEntry(label: "Instagram", keys: ["instagram"], bundleID: "com.burbn.instagram")
            ],
            advancedTokens: [
                LockListAppEntry(label: "com.example.bundle-only", keys: ["com.example.bundle-only"], bundleID: "com.example.bundle-only")
            ],
            categories: [],
            lists: []
        )

        let recoverable = LockSetupRecoveryPlanner.recoverableLocalApps(snapshot)

        XCTAssertEqual(
            recoverable.map(\.label),
            ["Instagram", "com.example.bundle-only"]
        )
    }

    func test_localRecoveryDoesNotUploadOldAliasKeyAfterChildChange() {
        let upload = LockSetupRecoveryPlanner.uploadApp(
            app: LockListAppEntry(
                label: "Instagram",
                keys: ["instagram"],
                bundleID: "com.burbn.instagram"
            ),
            tokenDataBase64: "SUc=",
            childDeviceIDChanged: true
        )

        XCTAssertNil(upload.aliasKey)
        XCTAssertEqual(upload.displayName, "Instagram")
        XCTAssertEqual(upload.bundleID, "com.burbn.instagram")
    }

    func test_localRecoveryTreatsSemanticCategoryAliasAsExistingCanonicalCategory() {
        let backend = LockSetupCatalogPresentationModel(
            apps: [],
            categories: [
                .init(
                    aliasKey: UUID(),
                    type: .category,
                    displayName: "Productivity & Finance",
                    aliases: ["productivity"]
                )
            ],
            lists: []
        )
        let localCategories = [
            LockListCategoryEntry(name: "productivity")
        ]

        let missing = LockSetupRecoveryPlanner.missingLocalCategories(localCategories, backend: backend)

        XCTAssertTrue(missing.isEmpty)
    }

    func test_localRecoveryCategoryUploadUsesCanonicalAppleCategoryName() {
        let upload = LockSetupRecoveryPlanner.uploadCategory(
            category: LockListCategoryEntry(name: "reading"),
            tokenDataBase64: "UkVBRElORw==",
            sourceDeviceID: UUID()
        )

        XCTAssertEqual(upload.displayName, "Information & Reading")
        XCTAssertEqual(upload.aliases, ["Information & Reading", "reading"])
    }
}
