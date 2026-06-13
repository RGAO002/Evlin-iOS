@testable import Evlin_iOS
import XCTest

final class SavedListPickerCatalogTests: XCTestCase {
    func test_memberUploadsIncludeAppsAndCategories() {
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let members = SavedListMemberPlanner.members(
            selectedAppIDs: [appID],
            selectedCategoryIDs: [categoryID]
        )

        XCTAssertEqual(members, [
            CatalogListMemberUpload(targetType: .app, aliasKey: appID),
            CatalogListMemberUpload(targetType: .category, aliasKey: categoryID),
        ])
    }
}
