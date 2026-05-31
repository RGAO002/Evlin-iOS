import XCTest
@testable import Evlin_iOS

final class APIClientCatalogDTOTests: XCTestCase {
    func test_catalogSearchResponseDecodesWrappedResults() throws {
        let data = """
        {
          "results": [
            {
              "canonical_name": "Instagram",
              "bundle_id": "com.burbn.instagram",
              "aliases": ["Instagram", "IG", "insta"]
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CatalogSearchResponseDTO.self, from: data)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].canonicalName, "Instagram")
        XCTAssertEqual(response.results[0].bundleID, "com.burbn.instagram")
        XCTAssertEqual(response.results[0].result.aliases, ["Instagram", "IG", "insta"])
    }

    func test_childAppCatalogUploadAppEncodesSnakeCaseWithSourceDevice() throws {
        let aliasKey = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sourceDeviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let app = ChildAppCatalogUploadApp(
            aliasKey: aliasKey,
            displayName: "Instagram",
            bundleID: "com.burbn.instagram",
            aliases: ["Instagram", "IG"],
            tokenAvailable: true,
            tokenDataBase64: "VE9LRU4=",
            sourceDeviceID: sourceDeviceID
        )

        let data = try JSONEncoder().encode(app)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["alias_key"] as? String, aliasKey.uuidString)
        XCTAssertEqual(json["display_name"] as? String, "Instagram")
        XCTAssertEqual(json["token_kind"] as? String, "app")
        XCTAssertEqual(json["bundle_id"] as? String, "com.burbn.instagram")
        XCTAssertEqual(json["token_available"] as? Bool, true)
        XCTAssertEqual(json["token_data_base64"] as? String, "VE9LRU4=")
        XCTAssertEqual(json["source_device_id"] as? String, sourceDeviceID.uuidString)
    }

    func test_catalogListUploadResponseDecodesAliasKeyAndAppCount() throws {
        let aliasKey = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let childDeviceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let data = """
        {
          "alias_key": "\(aliasKey.uuidString)",
          "child_device_id": "\(childDeviceID.uuidString)",
          "list_name": "Games",
          "aliases": ["Games", "gaming"],
          "app_count": 3
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CatalogListUploadResponse.self, from: data)
        XCTAssertEqual(response.aliasKey, aliasKey)
        XCTAssertEqual(response.childDeviceID, childDeviceID)
        XCTAssertEqual(response.listName, "Games")
        XCTAssertEqual(response.aliases, ["Games", "gaming"])
        XCTAssertEqual(response.appCount, 3)
    }

    func test_lazyTagParentCatalogProjectionDecodesThreeTargetTypesWithoutDuplicatingCategories() throws {
        let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let categoryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let listID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let childDeviceID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let data = """
        {
          "child_device_id": "\(childDeviceID.uuidString)",
          "apps": [
            {
              "alias_key": "\(appID.uuidString)",
              "target_type": "app",
              "display_name": "Instagram",
              "binding_kind": "verified",
              "aliases": ["ig"],
              "bundle_id": "com.burbn.instagram",
              "token_available": true,
              "status": "active"
            },
            {
              "alias_key": "\(categoryID.uuidString)",
              "target_type": "category",
              "display_name": "Games",
              "binding_kind": "manual",
              "bundle_id": null,
              "aliases": ["gaming"],
              "token_available": true,
              "status": "active"
            }
          ],
          "categories": [
            {
              "alias_key": "\(categoryID.uuidString)",
              "target_type": "category",
              "display_name": "Games",
              "binding_kind": "manual",
              "bundle_id": null,
              "aliases": ["gaming"],
              "token_available": true,
              "status": "active"
            }
          ],
          "lists": [
            {
              "alias_key": "\(listID.uuidString)",
              "target_type": "list",
              "list_name": "Entertainment",
              "aliases": ["fun"],
              "app_count": 3,
              "status": "active"
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ParentLazyTagCatalogResponse.self, from: data)
        let targets = response.lazyTagTargets

        XCTAssertEqual(response.childDeviceID, childDeviceID)
        XCTAssertEqual(targets.map(\.type), [.app, .category, .list])
        XCTAssertEqual(targets[0].displayName, "Instagram")
        XCTAssertEqual(targets[0].bundleID, "com.burbn.instagram")
        XCTAssertFalse(targets[0].isManual)
        XCTAssertEqual(targets[1].displayName, "Games")
        XCTAssertEqual(targets[1].supportingText, "Current + future apps Apple classifies as Games")
        XCTAssertEqual(targets[2].displayName, "Entertainment")
        XCTAssertEqual(targets[2].memberCount, 3)
    }

    func test_lazyTagAliasResponseDecodesDirectBackendResponse() throws {
        let aliasKey = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let data = """
        {
          "alias_key": "\(aliasKey.uuidString)",
          "target_type": "app",
          "display_name": "TikTok",
          "aliases": ["TikTok", "抖音"],
          "status": "active",
          "bundle_id": "com.zhiliaoapp.musically",
          "token_available": true
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(LazyTagAliasTargetResponse.self, from: data)
        let target = response.lazyTagTarget

        XCTAssertEqual(target.aliasKey, aliasKey)
        XCTAssertEqual(target.aliases, ["TikTok", "抖音"])
        XCTAssertEqual(target.bundleID, "com.zhiliaoapp.musically")
        XCTAssertFalse(target.isManual)
    }

    func test_lazyTagAliasMutationRequestEncodesBackendContract() throws {
        let familyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let childDeviceID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let body = LazyTagAliasMutationRequest(
            familyID: familyID,
            childDeviceID: childDeviceID,
            targetType: .category,
            alias: "gaming"
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["family_id"] as? String, familyID.uuidString)
        XCTAssertEqual(json["child_device_id"] as? String, childDeviceID.uuidString)
        XCTAssertEqual(json["target_type"] as? String, "category")
        XCTAssertEqual(json["alias"] as? String, "gaming")
    }
}
