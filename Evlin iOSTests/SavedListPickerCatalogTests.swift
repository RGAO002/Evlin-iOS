@testable import Evlin_iOS
import XCTest

final class SavedListPickerCatalogTests: XCTestCase {
    func test_lockSetupCatalogDecodesListMembers() throws {
        let json = """
        {
          "child_device_id": "11111111-1111-1111-1111-111111111111",
          "sections": [
            {
              "type": "list",
              "targets": [
                {
                  "alias_key": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                  "target_type": "list",
                  "list_name": "Evening",
                  "aliases": ["Evening"],
                  "app_count": 2,
                  "status": "active",
                  "members": [
                    {"target_type": "app", "alias_key": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"},
                    {"target_type": "category", "alias_key": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"}
                  ]
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(LockSetupCatalog.self, from: json)

        let row = catalog.listTargets[0]
        XCTAssertEqual(row.members.map(\.aliasKey), [
            UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
        ])
        XCTAssertEqual(row.members.map(\.targetType), [.app, .category])
    }

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

    func test_memberUploadsUseStableAppThenCategoryOrder() {
        let laterAppID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let earlierAppID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let categoryID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        let members = SavedListMemberPlanner.members(
            selectedAppIDs: [laterAppID, earlierAppID],
            selectedCategoryIDs: [categoryID]
        )

        XCTAssertEqual(members.map(\.aliasKey), [earlierAppID, laterAppID, categoryID])
        XCTAssertEqual(members.map(\.targetType), [.app, .app, .category])
    }
}
