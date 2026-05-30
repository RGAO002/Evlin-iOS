@testable import Evlin_iOS
import XCTest

final class LockListManagerModelTests: XCTestCase {
    func test_reloadReadsSavedListsFromLocalAliasStore() {
        let store = FakeLockListStore(
            apps: [],
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
        let snapshot = LockListManagerSnapshot.make(from: FakeLockListStore(apps: [], lists: []))

        XCTAssertTrue(snapshot.apps.isEmpty)
        XCTAssertTrue(snapshot.lists.isEmpty)
    }
}

private struct FakeLockListStore: LockListStoreReading {
    let apps: [(label: String, keys: [String], bundleID: String?)]
    let lists: [String]

    func groupedApplicationAliases() -> [(label: String, keys: [String], bundleID: String?)] {
        apps
    }

    func allListNames() -> [String] {
        lists
    }
}
