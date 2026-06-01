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
