import FamilyControls
import XCTest
@testable import Evlin_iOS

@MainActor
final class LockListManagerModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LocalAliasStore.shared.removeAllAliases()
    }

    override func tearDown() {
        LocalAliasStore.shared.removeAllAliases()
        super.tearDown()
    }

    func test_reloadReadsSavedListsFromLocalAliasStore() {
        LocalAliasStore.shared.saveList(FamilyActivitySelection(), named: "Games")

        let model = LockListManagerModel()
        model.reload()

        XCTAssertTrue(model.lists.contains("games") || model.lists.contains("Games"))
    }

    func test_reloadShowsEmptyStateWhenNoLocalEntriesExist() {
        let model = LockListManagerModel()
        model.reload()

        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertTrue(model.lists.isEmpty)
    }
}
