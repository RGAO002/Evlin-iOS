@testable import Evlin_iOS
import XCTest

final class LockListManagerModelTests: XCTestCase {
    func test_reloadReadsSavedListsFromLocalAliasStore() {
        let store = FakeLockListStore(
            apps: [],
            categories: [],
            lists: ["Games"]
        )

        let snapshot = LockListManagerSnapshot.make(from: store)

        XCTAssertEqual(snapshot.lists, ["Games"])
    }

    func test_reloadReadsAppAliasesFromStore() {
        let store = FakeLockListStore(
            apps: [
                (label: "Instagram", keys: ["instagram", "com.burbn.instagram"], bundleID: "com.burbn.instagram")
            ],
            categories: [],
            lists: []
        )

        let snapshot = LockListManagerSnapshot.make(from: store)

        XCTAssertEqual(snapshot.apps, [
            LockListAppEntry(
                label: "Instagram",
                keys: ["instagram", "com.burbn.instagram"],
                bundleID: "com.burbn.instagram"
            )
        ])
    }

    func test_reloadShowsEmptyStateWhenNoLocalEntriesExist() {
        let snapshot = LockListManagerSnapshot.make(from: FakeLockListStore(apps: [], categories: [], lists: []))

        XCTAssertTrue(snapshot.apps.isEmpty)
        XCTAssertTrue(snapshot.categories.isEmpty)
        XCTAssertTrue(snapshot.lists.isEmpty)
    }

    func test_reloadReadsCategoryTargetsFromLocalAliasStore() {
        let store = FakeLockListStore(
            apps: [],
            categories: ["games", "social"],
            lists: []
        )

        let snapshot = LockListManagerSnapshot.make(from: store)

        XCTAssertEqual(snapshot.categories, [
            LockListCategoryEntry(name: "games"),
            LockListCategoryEntry(name: "social")
        ])
    }

    func test_kidPresentationUsesBackendCatalogAndStripsBadgesAndCopy() {
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let listID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let catalog = LockSetupCatalogPresentationModel(
            apps: [
                .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"], bundleID: "com.burbn.instagram", artworkURL: nil, isManual: true, memberCount: nil)
            ],
            categories: [
                .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["games"], bundleID: nil, artworkURL: nil, isManual: false, memberCount: nil)
            ],
            lists: [
                .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["fun"], bundleID: nil, artworkURL: nil, isManual: false, memberCount: 2)
            ]
        )

        XCTAssertEqual(catalog.appRows.map(\.title), ["Instagram"])
        XCTAssertEqual(catalog.appRows.map(\.subtitle), ["com.burbn.instagram"])
        XCTAssertEqual(catalog.appRows.map(\.badgeText), [nil])
        XCTAssertEqual(catalog.categoryRows.map(\.title), ["Games"])
        XCTAssertEqual(catalog.categoryRows.map(\.subtitle), [nil])
        XCTAssertEqual(catalog.categoryRows.map(\.badgeText), [nil])
        XCTAssertEqual(catalog.listRows.map(\.subtitle), ["2 members"])
    }
}

private struct FakeLockListStore: LockListStoreReading {
    let apps: [(label: String, keys: [String], bundleID: String?)]
    let categories: [String]
    let lists: [String]

    func groupedApplicationAliases() -> [(label: String, keys: [String], bundleID: String?)] {
        apps
    }

    func allListNames() -> [String] {
        lists
    }

    func allCategoryNames() -> [String] {
        categories
    }
}
