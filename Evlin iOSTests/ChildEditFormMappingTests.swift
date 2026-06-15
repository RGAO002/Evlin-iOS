import XCTest
@testable import Evlin_iOS

final class ChildEditFormMappingTests: XCTestCase {

    func test_createBody_maps_age_to_birth_year() {
        let body = ChildCRUDMapper.createBody(name: "Sam", age: 8, referenceYear: 2026)
        XCTAssertEqual(body.display_name, "Sam")
        XCTAssertEqual(body.birth_year, 2018)            // 2026 - 8
        XCTAssertNil(body.child_device_id)
    }

    func test_updateBody_maps_name_and_age() {
        let body = ChildCRUDMapper.updateBody(name: "Sam", age: 10, referenceYear: 2026)
        XCTAssertEqual(body.display_name, "Sam")
        XCTAssertEqual(body.birth_year, 2016)            // 2026 - 10
    }

    func test_deleteError_409_is_paired_device_message() {
        let msg = ChildCRUDMapper.deleteErrorMessage(for: APIError.serverError(409))
        XCTAssertTrue(msg.lowercased().contains("paired device"),
                      "409 must explain a linked device blocks deletion, got: \(msg)")
    }

    func test_deleteError_other_is_generic() {
        let msg = ChildCRUDMapper.deleteErrorMessage(for: APIError.serverError(500))
        XCTAssertFalse(msg.lowercased().contains("paired device"))
        XCTAssertFalse(msg.isEmpty)
    }

    func test_settingsVersionDisplay_includes_build_when_present() {
        let display = ParentSettingsPresentation.versionDisplay(
            shortVersion: "1.2.3",
            build: "45"
        )

        XCTAssertEqual(display, "1.2.3 (45)")
    }

    func test_settingsVersionDisplay_falls_back_to_dash_when_missing() {
        let display = ParentSettingsPresentation.versionDisplay(
            shortVersion: nil,
            build: nil
        )

        XCTAssertEqual(display, "—")
    }

    func test_notificationAuthorizationCopy_maps_parent_statuses() {
        XCTAssertEqual(
            ParentSettingsPresentation.notificationStatusCopy(.authorized),
            "Allowed"
        )
        XCTAssertEqual(
            ParentSettingsPresentation.notificationStatusCopy(.denied),
            "Off"
        )
        XCTAssertEqual(
            ParentSettingsPresentation.notificationStatusCopy(.notDetermined),
            "Not Asked Yet"
        )
        XCTAssertEqual(
            ParentSettingsPresentation.notificationStatusCopy(.provisional),
            "Provisional"
        )
    }

    func test_notificationPermissionToggle_requestsAuthorizationBeforeOpeningSettings() {
        XCTAssertEqual(
            ParentSettingsPresentation.notificationPermissionAction(
                status: .notDetermined,
                wantsEnabled: true
            ),
            .requestAuthorization
        )
    }

    func test_notificationPermissionToggle_opensSettingsAfterDenied() {
        XCTAssertEqual(
            ParentSettingsPresentation.notificationPermissionAction(
                status: .denied,
                wantsEnabled: true
            ),
            .openSystemSettings
        )
    }

    func test_notificationPermissionToggle_opensSettingsWhenTurningOff() {
        XCTAssertEqual(
            ParentSettingsPresentation.notificationPermissionAction(
                status: .authorized,
                wantsEnabled: false
            ),
            .openSystemSettings
        )
    }

    func test_notificationPermissionToggle_doesNotOpenSettingsWhenAlreadyEnabled() {
        XCTAssertEqual(
            ParentSettingsPresentation.notificationPermissionAction(
                status: .authorized,
                wantsEnabled: true
            ),
            .setLocalPreference
        )
    }

    func test_familyDevicesSummary_matches_settings_root_copy() {
        XCTAssertEqual(
            ParentSettingsPresentation.childrenDevicesSummary(childCount: 2, deviceCount: 3),
            "2 children · 3 child devices"
        )
        XCTAssertEqual(
            ParentSettingsPresentation.childrenDevicesSummary(childCount: 1, deviceCount: 1),
            "1 child · 1 child device"
        )
    }

    func test_coParentValue_countsOnlyActualCoparents() {
        XCTAssertEqual(ParentSettingsPresentation.coParentValue(coParentCount: 0), "None")
        XCTAssertEqual(ParentSettingsPresentation.coParentValue(coParentCount: 2), "2 adults")
    }

    func test_parentRootAvatarURL_usesSignedPhotoWhenPresent() {
        XCTAssertEqual(
            ParentSettingsPresentation.parentRootAvatarURL(" https://example.com/me.jpg "),
            "https://example.com/me.jpg"
        )
        XCTAssertNil(ParentSettingsPresentation.parentRootAvatarURL("   "))
    }

    func test_childSettingsAvatarURL_usesSignedPhotoWhenPresent() {
        XCTAssertEqual(
            ParentSettingsPresentation.childSettingsAvatarURL(" https://example.com/kid.jpg "),
            "https://example.com/kid.jpg"
        )
        XCTAssertNil(ParentSettingsPresentation.childSettingsAvatarURL("   "))
    }

    func test_parentNotificationToggles_start_with_mockup_defaults() {
        XCTAssertEqual(
            ParentSettingsPresentation.defaultNotificationToggleIDs,
            ["kid_requests", "reflection_completions", "kid_nudges"]
        )
    }

    func test_parentAccentOptions_match_settings_profile_mockup() {
        XCTAssertGreaterThanOrEqual(ParentSettingsPresentation.parentAccentHexOptions.count, 8)
        XCTAssertEqual(ParentSettingsPresentation.parentAccentHexOptions.first, "#24324A")
        XCTAssertTrue(ParentSettingsPresentation.parentAccentHexOptions.contains("#2E7D32"))
        XCTAssertTrue(ParentSettingsPresentation.parentAccentHexOptions.contains("#BE185D"))
    }

    func test_parentProfileHeroAccentOptions_areFlatMockupOrder() {
        XCTAssertEqual(
            ParentSettingsPresentation.parentProfileHeroAccentHexOptions,
            [
                "#24324A",
                "#2E7D32",
                "#7C6FF7",
                "#EF6C00",
                "#0F766E",
                "#BE185D",
                "#2563EB",
                "#6B7280",
            ]
        )
    }

    func test_childProfileHeroAccentOptions_matchParentProfileOptions() {
        XCTAssertEqual(
            ParentSettingsPresentation.childProfileHeroAccentHexOptions,
            ParentSettingsPresentation.parentProfileHeroAccentHexOptions
        )
    }

    func test_parentAvatarUploadResponse_decodes_backendSignedURL() throws {
        let data = """
        {"ok":true,"object_key":"parent/avatar.jpg","signed_url":"http://localhost/avatar.jpg"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AvatarUploadResponseDTO.self, from: data)

        XCTAssertEqual(response.signed_url, "http://localhost/avatar.jpg")
    }

    func test_kidSpaceOverflowMenuOnlyShowsEditAndDeleteProfile() {
        XCTAssertEqual(
            ProfilePresentation.kidSpaceOverflowMenuLabels,
            ["Edit Profile", "Delete Profile"]
        )
    }
}
