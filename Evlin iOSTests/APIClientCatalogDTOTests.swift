import XCTest
@testable import Evlin_iOS

final class APIClientCatalogDTOTests: XCTestCase {
    // APIClient is an ObservableObject used as app state; keeping the test
    // instance for the process lifetime avoids a simulator host crash on
    // deinit while still keeping the test deterministic.
    private static let childCatalogURLClient = APIClient(baseURL: "https://example.test/api/v1")

    func test_parentChildDevicesResponseDecodesSnakeCaseChildren() throws {
        let familyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let childID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let data = """
        {
          "family_id": "\(familyID.uuidString)",
          "children": [
            {
              "child_device_id": "\(childID.uuidString)",
              "display_name": "Liam's iPhone",
              "last_heartbeat": "2026-06-05T12:00:00Z",
              "child_auth_granted": true,
              "build_number": 42,
              "catalog_app_count": 2,
              "catalog_category_count": 3,
              "catalog_list_count": 1,
              "catalog_preview": ["Instagram", "Cat Quest"]
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ParentChildDevicesResponseDTO.self, from: data)

        XCTAssertEqual(response.familyID, familyID)
        XCTAssertEqual(response.children.count, 1)
        XCTAssertEqual(response.children[0].childDeviceID, childID)
        XCTAssertEqual(response.children[0].displayName, "Liam's iPhone")
        XCTAssertEqual(response.children[0].lastHeartbeat, "2026-06-05T12:00:00Z")
        XCTAssertEqual(response.children[0].childAuthGranted, true)
        XCTAssertEqual(response.children[0].buildNumber, 42)
        XCTAssertEqual(response.children[0].catalogAppCount, 2)
        XCTAssertEqual(response.children[0].catalogCategoryCount, 3)
        XCTAssertEqual(response.children[0].catalogListCount, 1)
        XCTAssertEqual(response.children[0].catalogSummary, "2 apps · 3 categories · 1 list")
        XCTAssertEqual(response.children[0].catalogPreviewText, "Instagram, Cat Quest")
    }

    func test_parentChildDevicesResponseDefaultsCatalogDiagnosticsWhenServerIsOld() throws {
        let familyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let childID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let data = """
        {
          "family_id": "\(familyID.uuidString)",
          "children": [
            {
              "child_device_id": "\(childID.uuidString)",
              "display_name": "Liam's iPhone",
              "last_heartbeat": null,
              "child_auth_granted": false,
              "build_number": null
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ParentChildDevicesResponseDTO.self, from: data)

        XCTAssertEqual(response.children[0].catalogAppCount, 0)
        XCTAssertEqual(response.children[0].catalogCategoryCount, 0)
        XCTAssertEqual(response.children[0].catalogListCount, 0)
        XCTAssertEqual(response.children[0].catalogPreview, [])
        XCTAssertEqual(response.children[0].catalogPreviewText, "No catalog entries yet")
    }

    func test_lazyTagTargetsURLUsesThreeSectionFeedEndpoint() throws {
        let childID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

        let url = Self.childCatalogURLClient.lazyTagTargetsURL(childDeviceID: childID)

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "example.test")
        XCTAssertEqual(components.path, "/api/v1/parent/lazy-tag-targets")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "child_device_id", value: childID.uuidString)]
        )
    }

    func test_parentChildDeviceResponseDecodesSingleChildWithOwningFamily() throws {
        let familyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let childID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let data = """
        {
          "family_id": "\(familyID.uuidString)",
          "child": {
            "child_device_id": "\(childID.uuidString)",
            "display_name": "Current Kid iPhone",
            "last_heartbeat": null,
            "child_auth_granted": true,
            "build_number": 77,
            "catalog_app_count": 3,
            "catalog_category_count": 1,
            "catalog_list_count": 2,
            "catalog_preview": ["Cat Quest", "Instagram", "YouTube"]
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ParentChildDeviceResponseDTO.self, from: data)

        XCTAssertEqual(response.familyID, familyID)
        XCTAssertEqual(response.child.childDeviceID, childID)
        XCTAssertEqual(response.child.displayName, "Current Kid iPhone")
        XCTAssertEqual(response.child.catalogSummary, "3 apps · 1 category · 2 lists")
        XCTAssertEqual(response.child.catalogPreviewText, "Cat Quest, Instagram, YouTube")
    }

    func test_catalogSearchResponseDecodesWrappedResults() throws {
        let data = """
        {
          "results": [
            {
              "canonical_name": "Instagram",
              "bundle_id": "com.burbn.instagram",
              "aliases": ["Instagram", "IG", "insta"],
              "artwork_url": "https://is1-ssl.mzstatic.com/image/thumb/ig.png"
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CatalogSearchResponseDTO.self, from: data)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].canonicalName, "Instagram")
        XCTAssertEqual(response.results[0].bundleID, "com.burbn.instagram")
        XCTAssertEqual(response.results[0].artworkURL, URL(string: "https://is1-ssl.mzstatic.com/image/thumb/ig.png"))
        XCTAssertEqual(response.results[0].result.artworkURL, URL(string: "https://is1-ssl.mzstatic.com/image/thumb/ig.png"))
        XCTAssertEqual(response.results[0].result.aliases, ["Instagram", "IG", "insta"])
    }

    func test_catalogListUploadBodyEncodesExplicitMembers() throws {
        let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let body = CatalogListUploadRequestBody(
            deviceID: deviceID,
            aliasKey: nil,
            sourceDeviceID: deviceID,
            listName: "Entertainment",
            aliases: ["fun"],
            selectionBlobBase64: "U0VMRUNUSU9O",
            appCount: 0,
            members: [
                .init(targetType: .app, aliasKey: appID),
                .init(targetType: .category, aliasKey: categoryID),
            ]
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let members = try XCTUnwrap(json["members"] as? [[String: Any]])

        XCTAssertEqual(json["device_id"] as? String, deviceID.uuidString)
        XCTAssertEqual(json["list_name"] as? String, "Entertainment")
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0]["target_type"] as? String, "app")
        XCTAssertEqual(members[0]["alias_key"] as? String, appID.uuidString)
        XCTAssertEqual(members[1]["target_type"] as? String, "category")
        XCTAssertEqual(members[1]["alias_key"] as? String, categoryID.uuidString)
    }

    func test_catalogListUploadBodyAllowsMemberOnlyPayloadWithoutSelectionBlob() throws {
        let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let body = CatalogListUploadRequestBody(
            deviceID: deviceID,
            aliasKey: nil,
            sourceDeviceID: deviceID,
            listName: "Entertainment",
            aliases: ["fun"],
            selectionBlobBase64: nil,
            appCount: 1,
            members: [.init(targetType: .app, aliasKey: appID)]
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["selection_blob_base64"])
        XCTAssertEqual((json["members"] as? [[String: Any]])?.count, 1)
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
              "artwork_url": "https://example.com/instagram.png",
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
        XCTAssertEqual(targets[0].artworkURL, URL(string: "https://example.com/instagram.png"))
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
          "artwork_url": "https://example.com/tiktok.png",
          "token_available": true
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(LazyTagAliasTargetResponse.self, from: data)
        let target = response.lazyTagTarget

        XCTAssertEqual(target.aliasKey, aliasKey)
        XCTAssertEqual(target.aliases, ["TikTok", "抖音"])
        XCTAssertEqual(target.bundleID, "com.zhiliaoapp.musically")
        XCTAssertEqual(target.artworkURL, URL(string: "https://example.com/tiktok.png"))
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

    // MARK: - Lock-setup catalog (Task 10)

    @MainActor
    func test_childLockSetupCatalogURLUsesChildScopedEndpoint() throws {
        let deviceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

        let url = Self.childCatalogURLClient.childLockSetupCatalogURL(deviceID: deviceID)

        XCTAssertEqual(
            url.absoluteString,
            "https://example.test/api/v1/child/lock-setup-catalog?device_id=\(deviceID.uuidString)"
        )
    }

    func test_lockSetupCatalogDecodesThreeSectionsInOrder() throws {
        let childID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let catID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let listID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let data = """
        {
          "child_device_id": "\(childID.uuidString)",
          "sections": [
            {
              "type": "app",
              "copy": "Installed apps your kid has shared.",
              "targets": [
                {
                  "alias_key": "\(appID.uuidString)",
                  "target_type": "app",
                  "display_name": "Instagram",
                  "binding_kind": "verified",
                  "bundle_id": "com.burbn.instagram",
                  "aliases": ["ig"],
                  "token_available": true,
                  "status": "active"
                }
              ]
            },
            {
              "type": "category",
              "copy": "Broad categories — current + future apps.",
              "targets": [
                {
                  "alias_key": "\(catID.uuidString)",
                  "target_type": "category",
                  "display_name": "Games",
                  "binding_kind": "manual",
                  "bundle_id": null,
                  "aliases": ["games"],
                  "token_available": true,
                  "status": "active"
                }
              ]
            },
            {
              "type": "list",
              "copy": "Saved lists your kid has shared.",
              "targets": [
                {
                  "alias_key": "\(listID.uuidString)",
                  "target_type": "list",
                  "list_name": "After School",
                  "aliases": ["fun"],
                  "app_count": 3,
                  "status": "active"
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(LockSetupCatalog.self, from: data)
        XCTAssertEqual(catalog.childDeviceID, childID)
        XCTAssertEqual(catalog.appTargets.map(\.displayName), ["Instagram"])
        XCTAssertEqual(catalog.appTargets.first?.bundleID, "com.burbn.instagram")
        XCTAssertEqual(catalog.appTargets.first?.isManual, false)
        XCTAssertEqual(catalog.categoryTargets.map(\.displayName), ["Games"])
        XCTAssertEqual(catalog.categoryTargets.first?.type, .category)
        // List rows carry list_name + member count, not display_name/bundle.
        XCTAssertEqual(catalog.listTargets.map(\.displayName), ["After School"])
        XCTAssertEqual(catalog.listTargets.first?.memberCount, 3)
        // allTargets flattens in app, category, list order.
        XCTAssertEqual(catalog.allTargets.map(\.type), [.app, .category, .list])
        XCTAssertEqual(catalog.categorySectionCopy, "Broad categories — current + future apps.")
    }

    func test_lockSetupCatalogDecodesMemberCountFromAppCountForLists() throws {
        let childID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let listID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let data = """
        {
          "child_device_id": "\(childID.uuidString)",
          "sections": [
            {
              "type": "list",
              "copy": "Saved lists your kid has shared.",
              "targets": [
                {
                  "alias_key": "\(listID.uuidString)",
                  "target_type": "list",
                  "list_name": "Entertainment",
                  "aliases": ["fun"],
                  "app_count": 2,
                  "status": "active"
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(LockSetupCatalog.self, from: data)

        XCTAssertEqual(catalog.listTargets.first?.memberCount, 2)
        XCTAssertEqual(catalog.listTargets.first?.displayName, "Entertainment")
    }

    func test_familyAppDTODecodesConfirmResponse() throws {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let data = """
        {
          "id": "\(id.uuidString)",
          "canonical_name": "Instagram",
          "bundle_id": "com.burbn.instagram",
          "artwork_url": "https://example.com/ig.png",
          "aliases": ["ig", "insta"],
          "confirmation_source": "catalog",
          "confirmation_status": "confirmed"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(FamilyAppDTO.self, from: data)
        XCTAssertEqual(dto.id, id)
        XCTAssertEqual(dto.canonicalName, "Instagram")
        XCTAssertEqual(dto.bundleID, "com.burbn.instagram")
        XCTAssertEqual(dto.aliases, ["ig", "insta"])
        XCTAssertTrue(dto.isConfirmed)
    }
}
