import XCTest
@testable import Evlin_iOS

final class LocalAliasStoreCatalogMemberTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LocalAliasStore.shared.removeAllAliases()
    }

    override func tearDown() {
        LocalAliasStore.shared.removeAllAliases()
        super.tearDown()
    }

    func testCatalogListMembersUsesSavedAppAndCategoryAliasKeys() {
        let store = LocalAliasStore.shared
        let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let categoryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        store.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token")
        store.saveCatalogAliasKey(categoryID, targetType: .category, encodedTokenKey: "category-token")

        let members = store.catalogListMembers(
            applicationTokenKeys: ["unknown-app-token", "app-token"],
            categoryTokenKeys: ["category-token", "unknown-category-token"]
        )

        XCTAssertEqual(members, [
            CatalogListMemberUpload(targetType: .app, aliasKey: appID),
            CatalogListMemberUpload(targetType: .category, aliasKey: categoryID),
        ])
    }

    func testCatalogAliasKeyForSameTokenIsReplacedByLatestCapture() {
        let store = LocalAliasStore.shared
        let oldID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let newID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        store.saveCatalogAliasKey(oldID, targetType: .app, encodedTokenKey: "same-token")
        store.saveCatalogAliasKey(newID, targetType: .app, encodedTokenKey: "same-token")

        let members = store.catalogListMembers(
            applicationTokenKeys: ["same-token"],
            categoryTokenKeys: []
        )

        XCTAssertEqual(members, [
            CatalogListMemberUpload(targetType: .app, aliasKey: newID),
        ])
    }

    func testCatalogConfirmationIsScopedToCurrentChildDevice() {
        let store = LocalAliasStore.shared
        let aliasID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let oldDeviceID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let newDeviceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        store.saveCatalogAliasKey(
            aliasID,
            targetType: .app,
            encodedTokenKey: "app-token",
            childDeviceID: oldDeviceID
        )

        XCTAssertTrue(store.hasCatalogConfirmation(
            targetType: .app,
            encodedTokenKey: "app-token",
            childDeviceID: oldDeviceID
        ))
        XCTAssertFalse(store.hasCatalogConfirmation(
            targetType: .app,
            encodedTokenKey: "app-token",
            childDeviceID: newDeviceID
        ))
    }

    func testCatalogListMembersDedupesSameAliasKeyAcrossTokenKeys() {
        let store = LocalAliasStore.shared
        let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        store.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token-a")
        store.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token-b")

        let members = store.catalogListMembers(
            applicationTokenKeys: ["app-token-a", "app-token-b"],
            categoryTokenKeys: []
        )

        XCTAssertEqual(members, [
            CatalogListMemberUpload(targetType: .app, aliasKey: appID),
        ])
    }

    func testRemoveAllAliasesClearsCatalogAliasKeyIndex() {
        let store = LocalAliasStore.shared
        let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        store.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token")
        store.removeAllAliases()

        let members = store.catalogListMembers(
            applicationTokenKeys: ["app-token"],
            categoryTokenKeys: []
        )

        XCTAssertTrue(members.isEmpty)
    }
}
