import XCTest
@testable import Evlin_iOS

/// Simulator tests cannot mint real FamilyControls tokens or exercise Apple's
/// ManagedSettings mutation. These tests pin the backend DTO contract and the
/// executor's token-byte selection; real shield application remains device QA.
@MainActor
final class CommandCatalogPayloadTests: XCTestCase {
    func test_commandPollerMapsCanonicalExactAppCatalogTokenIntoCommandTarget() throws {
        let tokenBlob = Data("APP_TOKEN".utf8).base64EncodedString()
        let poll = try decodePollCommand("""
        {
          "command_id": "11111111-1111-1111-1111-111111111111",
          "action": "shield",
          "tier": "exactApp",
          "target": {
            "bundle_id": "com.burbn.instagram",
            "category_hint": "   ",
            "target_all": false,
            "target_child_id": "22222222-2222-2222-2222-222222222222",
            "target_display": "Instagram",
            "original_request": "lock ig",
            "has_pending_blob": false,
            "catalog_token_data_base64": "\(tokenBlob)"
          },
          "duration_minutes": 15,
          "issued_at": "2026-05-31T12:00:00Z"
        }
        """)

        let command = CommandPoller.lockCommand(from: poll)

        XCTAssertEqual(command.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(command.action, .shield)
        XCTAssertEqual(command.tier, .exactApp)
        XCTAssertEqual(command.durationMinutes, 15)
        XCTAssertEqual(command.target.bundleID, "com.burbn.instagram")
        XCTAssertNil(command.target.categoryHint)
        XCTAssertEqual(command.target.targetDisplay, "Instagram")
        XCTAssertEqual(command.target.targetChildID, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(command.target.catalogTokenDataBase64, tokenBlob)
        XCTAssertNil(command.target.catalogCategoryTokenDataBase64)
        XCTAssertEqual(CatalogCommandTokenData.decodedApplicationData(from: command.target), Data("APP_TOKEN".utf8))
    }

    func test_commandPollerMapsCanonicalCategoryCatalogTokenIntoCommandTarget() throws {
        let tokenBlob = Data("CATEGORY_TOKEN".utf8).base64EncodedString()
        let poll = try decodePollCommand("""
        {
          "command_id": "33333333-3333-3333-3333-333333333333",
          "action": "shield",
          "tier": "category",
          "target": {
            "category_hint": "  Social  ",
            "target_all": false,
            "target_child_id": "44444444-4444-4444-4444-444444444444",
            "target_display": "Social",
            "original_request": "lock social",
            "has_pending_blob": false,
            "catalog_category_token_data_base64": "\(tokenBlob)"
          },
          "duration_minutes": 30,
          "issued_at": "2026-05-31T12:05:00Z"
        }
        """)

        let command = CommandPoller.lockCommand(from: poll)

        XCTAssertEqual(command.tier, .category)
        XCTAssertEqual(command.target.categoryHint, "Social")
        XCTAssertEqual(command.target.targetDisplay, "Social")
        XCTAssertEqual(command.target.catalogCategoryTokenDataBase64, tokenBlob)
        XCTAssertNil(command.target.catalogTokenDataBase64)
        XCTAssertEqual(CatalogCommandTokenData.decodedCategoryData(from: command.target), Data("CATEGORY_TOKEN".utf8))
    }

    func test_commandPollerMappingPreservesLegacySavedListPendingBlobFields() throws {
        let tokenBlob = Data("LEGACY_APP_TOKEN".utf8).base64EncodedString()
        let poll = try decodePollCommand("""
        {
          "command_id": "55555555-5555-5555-5555-555555555555",
          "action": "shield",
          "tier": "savedList",
          "target": {
            "bundle_id": "com.example.legacy",
            "list_name": "Homework Apps",
            "list_id": "66666666-6666-6666-6666-666666666666",
            "target_all": false,
            "target_display": "Homework Apps",
            "original_request": "lock homework",
            "has_pending_blob": true,
            "force_downgrade": true,
            "token_data_base64": "\(tokenBlob)"
          },
          "duration_minutes": null,
          "issued_at": "2026-05-31T12:10:00Z"
        }
        """)

        let command = CommandPoller.lockCommand(from: poll)

        XCTAssertEqual(command.tier, .savedList)
        XCTAssertEqual(command.target.listName, "Homework Apps")
        XCTAssertEqual(command.target.listID, UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        XCTAssertTrue(command.target.hasPendingBlob)
        XCTAssertTrue(command.target.forceDowngrade)
        XCTAssertEqual(command.target.catalogTokenDataBase64, tokenBlob)
        XCTAssertEqual(CatalogCommandTokenData.decodedApplicationData(from: command.target), Data("LEGACY_APP_TOKEN".utf8))
    }

    func test_pollCommandDTO_decodesCanonicalExactAppCatalogTokenPayload() throws {
        let tokenBlob = Data("APP_TOKEN".utf8).base64EncodedString()
        let data = """
        {
          "command_id": "11111111-1111-1111-1111-111111111111",
          "action": "shield",
          "tier": "exactApp",
          "target": {
            "bundle_id": "com.burbn.instagram",
            "list_name": null,
            "list_id": null,
            "category_hint": null,
            "target_all": false,
            "target_child_id": "22222222-2222-2222-2222-222222222222",
            "target_display": "Instagram",
            "original_request": "lock ig",
            "has_pending_blob": false,
            "catalog_token_data_base64": "\(tokenBlob)"
          },
          "duration_minutes": 15,
          "issued_at": "2026-05-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(PollCommandDTO.self, from: data)

        XCTAssertEqual(command.tier, "exactApp")
        XCTAssertEqual(command.target.target_display, "Instagram")
        XCTAssertEqual(command.target.catalog_token_data_base64, tokenBlob)
        XCTAssertNil(command.target.catalog_category_token_data_base64)
    }

    func test_pollCommandDTO_decodesCanonicalCategoryCatalogTokenPayload() throws {
        let tokenBlob = Data("CATEGORY_TOKEN".utf8).base64EncodedString()
        let data = """
        {
          "command_id": "33333333-3333-3333-3333-333333333333",
          "action": "shield",
          "tier": "category",
          "target": {
            "bundle_id": null,
            "list_name": null,
            "list_id": null,
            "category_hint": "Social",
            "target_all": false,
            "target_child_id": "44444444-4444-4444-4444-444444444444",
            "target_display": "Social",
            "original_request": "lock social",
            "has_pending_blob": false,
            "catalog_category_token_data_base64": "\(tokenBlob)"
          },
          "duration_minutes": 30,
          "issued_at": "2026-05-31T12:05:00Z"
        }
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(PollCommandDTO.self, from: data)

        XCTAssertEqual(command.tier, "category")
        XCTAssertEqual(command.target.category_hint, "Social")
        XCTAssertEqual(command.target.catalog_category_token_data_base64, tokenBlob)
        XCTAssertNil(command.target.catalog_token_data_base64)
    }

    func test_pollCommandDTO_preservesLegacyExactAppTokenAliasAndPendingBlobPath() throws {
        let tokenBlob = Data("LEGACY_APP_TOKEN".utf8).base64EncodedString()
        let data = """
        {
          "command_id": "55555555-5555-5555-5555-555555555555",
          "action": "shield",
          "tier": "exactApp",
          "target": {
            "bundle_id": "com.example.legacy",
            "list_name": null,
            "list_id": null,
            "category_hint": null,
            "target_all": false,
            "target_display": "Legacy",
            "original_request": "lock legacy",
            "has_pending_blob": true,
            "token_data_base64": "\(tokenBlob)"
          },
          "duration_minutes": null,
          "issued_at": "2026-05-31T12:10:00Z"
        }
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(PollCommandDTO.self, from: data)

        XCTAssertEqual(command.target.catalog_token_data_base64, tokenBlob)
        XCTAssertTrue(command.target.has_pending_blob ?? false)
    }

    func test_catalogCommandTokenData_decodesExecutorApplicationAndCategoryBytes() {
        let appBlob = Data("APP_TOKEN".utf8).base64EncodedString()
        let categoryBlob = Data("CATEGORY_TOKEN".utf8).base64EncodedString()
        let target = CommandTarget(
            bundleID: "com.burbn.instagram",
            listName: nil,
            listID: nil,
            categoryHint: "Social",
            targetAll: false,
            originalRequest: "lock ig",
            targetDisplay: "Instagram",
            targetChildID: nil,
            hasPendingBlob: false,
            forceDowngrade: false,
            catalogTokenDataBase64: appBlob,
            catalogCategoryTokenDataBase64: categoryBlob
        )

        XCTAssertEqual(CatalogCommandTokenData.decodedApplicationData(from: target), Data("APP_TOKEN".utf8))
        XCTAssertEqual(CatalogCommandTokenData.decodedCategoryData(from: target), Data("CATEGORY_TOKEN".utf8))
    }

    func test_catalogCommandTokenData_rejectsMalformedBase64WithoutFallingBackToOtherTier() {
        let categoryBlob = Data("CATEGORY_TOKEN".utf8).base64EncodedString()
        let target = CommandTarget(
            bundleID: "com.burbn.instagram",
            listName: nil,
            listID: nil,
            categoryHint: "Social",
            targetAll: false,
            originalRequest: "lock ig",
            targetDisplay: "Instagram",
            targetChildID: nil,
            hasPendingBlob: false,
            forceDowngrade: false,
            catalogTokenDataBase64: "not base64",
            catalogCategoryTokenDataBase64: categoryBlob
        )

        XCTAssertNil(CatalogCommandTokenData.decodedApplicationData(from: target))
        XCTAssertEqual(CatalogCommandTokenData.decodedCategoryData(from: target), Data("CATEGORY_TOKEN".utf8))
    }

    private func decodePollCommand(_ json: String) throws -> PollCommandDTO {
        try JSONDecoder().decode(PollCommandDTO.self, from: Data(json.utf8))
    }
}
