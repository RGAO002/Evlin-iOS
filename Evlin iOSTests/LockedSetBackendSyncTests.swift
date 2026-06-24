import XCTest
import FamilyControls
@testable import Evlin_iOS

/// Unit tests for `LockedSetSyncInputBuilder` — the pure extraction of the
/// "build ControlListInput from local state" step that does NOT require a
/// network mock.
///
/// `syncLockedSetToBackend` itself calls `createControlList`/`updateControlList`
/// over the network, so the full integration is not exercised here; the pure
/// builder is tested instead.
final class LockedSetBackendSyncTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LocalAliasStore.shared.removeAllAliases()
        EarnedTimeStore.shared.removeAll()
    }

    override func tearDown() {
        LocalAliasStore.shared.removeAllAliases()
        EarnedTimeStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Empty-selection guard

    func test_buildInput_emptyMembers_returnsNil() {
        let input = LockedSetSyncInputBuilder.build(
            members: [],
            existingAliasKey: nil
        )
        XCTAssertNil(input, "Empty member array must produce nil (nothing to sync)")
    }

    // MARK: - Create path (no existing alias key)

    func test_buildInput_withKnownMember_noExistingKey_returnsCreateInput() {
        let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        LocalAliasStore.shared.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token-1")
        let members = LocalAliasStore.shared.catalogListMembers(
            applicationTokenKeys: ["app-token-1"],
            categoryTokenKeys: []
        )
        XCTAssertEqual(members.count, 1, "Precondition: member must be found")

        let input = LockedSetSyncInputBuilder.build(
            members: members,
            existingAliasKey: nil
        )

        XCTAssertNotNil(input)
        XCTAssertNil(input?.aliasKey, "Create path: aliasKey must be nil so backend assigns a new one")
        XCTAssertEqual(input?.listName, DefaultLockGroup.shared.name)
        XCTAssertEqual(input?.aliases, [DefaultLockGroup.shared.name])
        XCTAssertNil(input?.selectionBlobBase64)
        XCTAssertEqual(input?.members.count, 1)
        XCTAssertEqual(input?.members.first?.aliasKey, appID)
        XCTAssertEqual(input?.members.first?.targetType, .app)
    }

    // MARK: - Update path (existing alias key present)

    func test_buildInput_withExistingAliasKey_returnsUpdateInput() {
        let appID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let existingKey = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        LocalAliasStore.shared.saveCatalogAliasKey(appID, targetType: .app, encodedTokenKey: "app-token-2")
        let members = LocalAliasStore.shared.catalogListMembers(
            applicationTokenKeys: ["app-token-2"],
            categoryTokenKeys: []
        )

        let input = LockedSetSyncInputBuilder.build(
            members: members,
            existingAliasKey: existingKey
        )

        XCTAssertEqual(input?.aliasKey, existingKey, "Update path: aliasKey must match the persisted one")
        XCTAssertEqual(input?.listName, "Locked set")
    }

    // MARK: - List name exactness

    func test_listName_isExactlyLockedSet() {
        // This is the critical invariant: the name must match DEFAULT_LOCK_GROUP_NAME
        // on the backend (matched case-insensitively via func.lower()).
        XCTAssertEqual(
            DefaultLockGroup.shared.name,
            "Locked set",
            "Name must match DEFAULT_LOCK_GROUP_NAME on the backend exactly"
        )
    }

    // MARK: - Category member path

    func test_buildInput_categoryMember_roundTrips() {
        let catID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        LocalAliasStore.shared.saveCatalogAliasKey(catID, targetType: .category, encodedTokenKey: "cat-token-1")
        let members = LocalAliasStore.shared.catalogListMembers(
            applicationTokenKeys: [],
            categoryTokenKeys: ["cat-token-1"]
        )

        let input = LockedSetSyncInputBuilder.build(members: members, existingAliasKey: nil)

        XCTAssertNotNil(input)
        XCTAssertEqual(input?.members.first?.targetType, .category)
        XCTAssertEqual(input?.members.first?.aliasKey, catID)
    }
}
