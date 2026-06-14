import XCTest
@testable import Evlin_iOS

final class AppAliasDTOTests: XCTestCase {

    // MARK: - Sample JSON matching the backend GET /parent/app-aliases shape

    private let sampleJSON = """
    {
        "family_id": "11111111-1111-1111-1111-111111111111",
        "apps": [
            {
                "family_app_id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "bundle_id": "com.burbn.instagram",
                "canonical_name": "Instagram",
                "artwork_url": "https://example.com/instagram.png",
                "aliases": ["ig", "insta"],
                "blockable": true,
                "lockable_devices": [
                    {
                        "child_device_id": "22222222-2222-2222-2222-222222222222",
                        "child_name": "Liam",
                        "device_label": "Liam's iPhone"
                    }
                ]
            }
        ]
    }
    """.data(using: .utf8)!

    private let sampleJSONNoLockable = """
    {
        "family_id": "11111111-1111-1111-1111-111111111111",
        "apps": [
            {
                "family_app_id": null,
                "bundle_id": "com.apple.mobilesafari",
                "canonical_name": "Safari",
                "artwork_url": null,
                "aliases": ["safari", "browser"],
                "blockable": false,
                "lockable_devices": []
            }
        ]
    }
    """.data(using: .utf8)!

    // MARK: - DTO decoding tests

    func test_appAliasFeedResponseDecodesFullPayload() throws {
        let response = try JSONDecoder().decode(AppAliasFeedResponse.self, from: sampleJSON)

        XCTAssertEqual(response.familyID, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(response.apps.count, 1)

        let app = response.apps[0]
        XCTAssertEqual(app.bundleID, "com.burbn.instagram")
        XCTAssertEqual(app.canonicalName, "Instagram")
        XCTAssertEqual(app.familyAppID, UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        XCTAssertEqual(app.artworkURL, URL(string: "https://example.com/instagram.png"))
        XCTAssertTrue(app.aliases.contains("ig"))
        XCTAssertTrue(app.aliases.contains("insta"))
        XCTAssertTrue(app.blockable)
        XCTAssertEqual(app.lockableDevices.count, 1)

        let device = app.lockableDevices[0]
        XCTAssertEqual(device.childName, "Liam")
        XCTAssertEqual(device.deviceLabel, "Liam's iPhone")
        XCTAssertEqual(device.childDeviceID, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }

    func test_appAliasRowLockableIsTrueWhenLockableDevicesIsNonEmpty() throws {
        let response = try JSONDecoder().decode(AppAliasFeedResponse.self, from: sampleJSON)
        XCTAssertTrue(response.apps[0].lockable)
    }

    func test_appAliasRowLockableIsFalseWhenLockableDevicesIsEmpty() throws {
        let response = try JSONDecoder().decode(AppAliasFeedResponse.self, from: sampleJSONNoLockable)
        let app = response.apps[0]
        XCTAssertEqual(app.bundleID, "com.apple.mobilesafari")
        XCTAssertFalse(app.lockable)
        XCTAssertNil(app.artworkURL)
        XCTAssertNil(app.familyAppID)
    }

    func test_appAliasRowIdentifiableIsBundleID() throws {
        let response = try JSONDecoder().decode(AppAliasFeedResponse.self, from: sampleJSON)
        XCTAssertEqual(response.apps[0].id, "com.burbn.instagram")
    }

    func test_lockableDeviceIdentifiableIsChildDeviceID() throws {
        let response = try JSONDecoder().decode(AppAliasFeedResponse.self, from: sampleJSON)
        let device = response.apps[0].lockableDevices[0]
        XCTAssertEqual(device.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }
}
