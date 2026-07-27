// Evlin iOS/Evlin iOSTests/LockSelectedAppsCardModelTests.swift
import XCTest
@testable import Evlin_iOS

final class LockSelectedAppsCardModelTests: XCTestCase {
    func testCardIDRegistersNewKinds() {
        XCTAssertEqual(CardID(rawValue: "lock_selected_apps_confirm")?.isAppControlCard, true)
        XCTAssertEqual(CardID(rawValue: "lock_selected_apps_empty")?.isAppControlCard, true)
        XCTAssertEqual(CardID(rawValue: "restriction_unlock_picker")?.isAppControlCard, true)
    }

    func testParseConfirmCardWithActionedOptions() {
        let payload: [String: Any] = [
            "type": "lock_selected_apps_confirm", "title": "Lock selected apps?",
            "body": "Shield the 15 apps & 2 categories you picked in App Controls on Liam's iPhone — for 30 min.",
            "target_display": "Locked set", "target_kind": "list",
            "apps_count": 15, "categories_count": 2, "duration_minutes": 30,
            "app_preview": [["display_name": "Instagram", "bundle_id": "com.burbn.instagram"]],
            "category_preview": ["Games", "Social"],
            "options": [["action": "lock_selected_apps_now", "label": "Lock selected apps", "list_name": "Locked set", "duration_minutes": 30],
                        ["action": "cancel", "label": "Cancel"]],
        ]
        let model = AppControlCardModel.parse(cardID: "lock_selected_apps_confirm", payload: payload)
        XCTAssertEqual(model?.kind, .lockSelectedAppsConfirm)
        XCTAssertEqual(model?.appsCount, 15)
        XCTAssertEqual(model?.categoriesCount, 2)
        XCTAssertEqual(model?.categoryPreview, ["Games", "Social"])
        XCTAssertEqual(model?.appPreview.first?.displayName, "Instagram")
        XCTAssertEqual(model?.options.count, 2)   // options NOT dropped (they carry action)
        XCTAssertEqual(model?.options.first?.action, "lock_selected_apps_now")
    }

    func testParseRestrictionUnlockPicker() {
        let payload: [String: Any] = [
            "type": "restriction_unlock_picker",
            "title": "Current restrictions",
            "body": "2 active restrictions across 1 child.",
            "target_display": "Current restrictions",
            "target_kind": "all",
            "picker_token": "tok-123",
            "restriction_groups": [[
                "child_id": "child-1",
                "child_name": "Ryan",
                "avatar": [
                    "value": "R",
                    "color": "#258B3A",
                    "signed_url": "https://example.test/avatars/ryan.jpg",
                ],
                "devices": [["id": "device-1", "label": "iPhone"]],
                "sessions": [[
                    "id": "row-1",
                    "title": "Instagram",
                    "subtitle": "App shield",
                    "badge": "TIMED",
                    "action": "unshield",
                    "kind": "app",
                    "child_device_id": "device-1",
                    "device_label": "iPhone",
                ], [
                    "id": "row-2",
                    "title": "TikTok",
                    "subtitle": "Blocked app",
                    "badge": "BLOCKED",
                    "action": "unblock",
                    "kind": "app",
                    "child_device_id": "device-1",
                    "device_label": "iPhone",
                ]]
            ]],
            "options": [["action": "restriction_unlock_selected", "label": "Unblock selected"]],
        ]

        let model = AppControlCardModel.parse(cardID: "restriction_unlock_picker", payload: payload)
        XCTAssertEqual(model?.kind, .restrictionUnlockPicker)
        XCTAssertEqual(model?.pickerToken, "tok-123")
        XCTAssertEqual(model?.restrictionGroups.count, 1)
        XCTAssertEqual(model?.restrictionGroups.first?.childName, "Ryan")
        XCTAssertEqual(model?.restrictionGroups.first?.avatarURL?.absoluteString, "https://example.test/avatars/ryan.jpg")
        XCTAssertEqual(model?.restrictionGroups.first?.sessions.map(\.action), ["unshield", "unblock"])
        XCTAssertEqual(model?.restrictionPrimaryActionLabel, "Unblock selected")
    }

    func testRestrictionAvatarCandidatesPreferFamilyStoreByChildID() {
        let backend = URL(string: "https://cdn.example/backend.jpg")!
        let result = AppControlCardModel.restrictionAvatarCandidateURLs(
            childID: "child-1",
            familyAvatarURLsByChildID: [
                "child-1": "https://cdn.example/current.jpg",
                "device-1": "https://cdn.example/wrong-device.jpg",
            ],
            payloadURL: backend
        )

        XCTAssertEqual(result.map(\.absoluteString), [
            "https://cdn.example/current.jpg",
            "https://cdn.example/backend.jpg",
        ])
    }

    func testRestrictionAvatarCandidatesFallBackWhenChildMissing() {
        let backend = URL(string: "https://cdn.example/backend.jpg")!
        let result = AppControlCardModel.restrictionAvatarCandidateURLs(
            childID: "child-1",
            familyAvatarURLsByChildID: [
                "child-2": "https://cdn.example/other.jpg",
            ],
            payloadURL: backend
        )

        XCTAssertEqual(result, [backend])
    }

    func testRestrictionAvatarCandidatesRejectInvalidFamilyURL() {
        let backend = URL(string: "https://cdn.example/backend.jpg")!
        let result = AppControlCardModel.restrictionAvatarCandidateURLs(
            childID: "child-1",
            familyAvatarURLsByChildID: ["child-1": "not a remote URL"],
            payloadURL: backend
        )

        XCTAssertEqual(result, [backend])
    }

    func testRestrictionAvatarCandidatesDeduplicateIdenticalSources() {
        let shared = URL(string: "https://cdn.example/shared.jpg")!
        let result = AppControlCardModel.restrictionAvatarCandidateURLs(
            childID: "child-1",
            familyAvatarURLsByChildID: ["child-1": shared.absoluteString],
            payloadURL: shared
        )

        XCTAssertEqual(result, [shared])
    }

    func testRestrictionAvatarCandidatesReturnEmptyWithoutUsableURL() {
        let result = AppControlCardModel.restrictionAvatarCandidateURLs(
            childID: "child-1",
            familyAvatarURLsByChildID: [:],
            payloadURL: nil
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testParseChildDisambiguationCandidateAvatar() {
        let payload: [String: Any] = [
            "type": "child_disambiguation",
            "title": "Which child?",
            "body": "You have more than one kid device. Which one should this apply to?",
            "target_display": "Locked set",
            "target_kind": "all",
            "candidates": [[
                "display": "Ryan",
                "child_device_id": "device-1",
                "child_avatar_url": "https://example.test/avatars/ryan.jpg",
                "child_avatar_value": "R",
                "child_avatar_color": "#258B3A",
            ]],
        ]

        let model = AppControlCardModel.parse(cardID: "child_disambiguation", payload: payload)
        XCTAssertEqual(model?.kind, .childDisambiguation)
        XCTAssertEqual(model?.candidates.first?.childAvatarURL?.absoluteString, "https://example.test/avatars/ryan.jpg")
        XCTAssertEqual(model?.candidates.first?.childAvatarValue, "R")
        XCTAssertEqual(model?.candidates.first?.childAvatarColorHex, "#258B3A")
    }
}
