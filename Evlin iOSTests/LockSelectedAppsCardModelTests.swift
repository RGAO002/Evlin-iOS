// Evlin iOS/Evlin iOSTests/LockSelectedAppsCardModelTests.swift
import XCTest
@testable import Evlin_iOS

final class LockSelectedAppsCardModelTests: XCTestCase {
    func testCardIDRegistersNewKinds() {
        XCTAssertEqual(CardID(rawValue: "lock_selected_apps_confirm")?.isAppControlCard, true)
        XCTAssertEqual(CardID(rawValue: "lock_selected_apps_empty")?.isAppControlCard, true)
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
}
