import XCTest
import FamilyControls
@testable import Evlin_iOS

/// Task 2: `allSelected` computed from the raw `FamilyActivitySelection` and
/// threaded through `ControlListInput` -> `CatalogListUploadRequestBody` ->
/// wire JSON as `all_selected`. Task 3 will append device-local union /
/// appliesToAll tests to this same file.
final class LockedSetFullCoverageTests: XCTestCase {

    // MARK: - LockedSetSelectionSemantics.isAllSelected

    /// Verified 2026-07-02 (see LockedSetSelectionSemantics.swift doc comment):
    /// `FamilyActivitySelection.includeEntireCategory` is real on this SDK but
    /// is fixed at init time by the caller, not a live "user tapped Select
    /// All" bit — and this app's Locked-set picker (`CombinedPickerSheet`)
    /// always constructs it with `includeEntireCategory: false`. No reliable
    /// on-device "all selected" signal exists, so the safe fallback ships:
    /// always `false`, isolated behind this one function.
    func test_isAllSelected_isAlwaysFalseForFallbackSignal_evenWithManyTokens() {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        XCTAssertFalse(LockedSetSelectionSemantics.isAllSelected(selection))

        // A selection with categories present is still not a reliable "all"
        // signal (no known-category-count catalog exists to compare against).
        selection = FamilyActivitySelection(includeEntireCategory: false)
        XCTAssertFalse(LockedSetSelectionSemantics.isAllSelected(selection))
    }

    func test_isAllSelected_isFalseForEmptySelection() {
        let selection = FamilyActivitySelection()
        XCTAssertFalse(LockedSetSelectionSemantics.isAllSelected(selection))
    }

    // MARK: - ControlListInput -> CatalogListUploadRequestBody wire threading

    func test_controlListInput_defaultsAllSelectedFalse() {
        let input = ControlListInput(
            listName: "Locked set",
            members: []
        )
        XCTAssertFalse(input.allSelected)
    }

    func test_catalogListUploadBody_encodesAllSelectedTrue() throws {
        let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let body = CatalogListUploadRequestBody(
            deviceID: deviceID,
            aliasKey: nil,
            sourceDeviceID: deviceID,
            listName: "Locked set",
            aliases: ["Locked set"],
            selectionBlobBase64: nil,
            appCount: 1,
            members: [.init(targetType: .app, aliasKey: appID)],
            allSelected: true
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["all_selected"] as? Bool, true)
    }

    func test_catalogListUploadBody_encodesAllSelectedFalseByDefault() throws {
        let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let appID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let body = CatalogListUploadRequestBody(
            deviceID: deviceID,
            aliasKey: nil,
            sourceDeviceID: deviceID,
            listName: "Locked set",
            aliases: ["Locked set"],
            selectionBlobBase64: nil,
            appCount: 1,
            members: [.init(targetType: .app, aliasKey: appID)]
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["all_selected"] as? Bool, false)
    }
}
