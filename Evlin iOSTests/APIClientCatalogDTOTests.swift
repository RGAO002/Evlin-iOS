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
}
