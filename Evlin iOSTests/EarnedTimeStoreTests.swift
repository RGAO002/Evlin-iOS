import XCTest
import FamilyControls
@testable import Evlin_iOS

/// B3: EarnedTimeStore — App Group persistence for the earned screen-time subsystem.
///
/// Tests are written against real App-Group UserDefaults (`group.com.evlin.ios`)
/// — the same suite the DeviceActivity extension reads. `FamilyActivitySelection`
/// is Codable via JSON. `ApplicationToken` values cannot be minted in a unit test,
/// so we exercise the selection round-trip with an empty selection (zero tokens),
/// which proves the encode/decode path without hitting the ScreenTime entitlement
/// wall. The Locked-set id round-trip uses a plain UUID string, which is the only
/// field the extension needs for its offline tripwire.
final class EarnedTimeStoreTests: XCTestCase {

    private func freshStore() -> EarnedTimeStore {
        let s = EarnedTimeStore.shared
        s.removeAll()
        return s
    }

    override func tearDown() {
        EarnedTimeStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - isEarnedTimeReady

    func test_isEarnedTimeReady_falseWhenNeitherPresent() {
        let store = freshStore()
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    func test_isEarnedTimeReady_falseWhenOnlyMeasurementSelectionPresent() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    func test_hasMeasurableSelection_falseForEmptySavedSelection() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())

        XCTAssertFalse(store.hasMeasurableSelection)
    }

    @MainActor
    func test_identityOwnerComparison_treatsUUIDCaseAsSameIdentity() {
        let id = UUID()

        XCTAssertTrue(EarnedBudgetArming.isSameDeviceIdentity(
            id.uuidString.lowercased(),
            id.uuidString.uppercased()
        ))
    }

    func test_isEarnedTimeReady_falseWhenOnlyLockedSetIdPresent() {
        let store = freshStore()
        let id = UUID()
        store.saveLockedSetID(id.uuidString, tokenData: nil)
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    func test_isEarnedTimeReady_falseWhenLockedSetIdAndEmptySelectionPresent() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.saveLockedSetID(UUID().uuidString, tokenData: nil)
        XCTAssertFalse(store.isEarnedTimeReady)
    }

    // MARK: - Measurement selection round-trip

    func test_measurementSelection_roundTrips_emptySelection() throws {
        let store = freshStore()
        let sel = FamilyActivitySelection()
        store.saveMeasurementSelection(sel)

        let loaded = try XCTUnwrap(store.measurementSelection)
        // applicationTokens + categoryTokens are empty; equality holds because
        // FamilyActivitySelection is Equatable.
        XCTAssertEqual(loaded.applicationTokens, sel.applicationTokens)
        XCTAssertEqual(loaded.categoryTokens, sel.categoryTokens)
    }

    func test_measurementSelection_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.measurementSelection)
    }

    func test_measurementSelection_persistsAcrossInstances() throws {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())

        let reloaded = EarnedTimeStore()
        XCTAssertNotNil(reloaded.measurementSelection)
    }

    // MARK: - Locked-set id round-trip

    func test_lockedSetID_roundTrips() {
        let store = freshStore()
        let id = UUID().uuidString
        store.saveLockedSetID(id, tokenData: nil)

        XCTAssertEqual(store.lockedSetID, id)
    }

    func test_lockedSetID_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.lockedSetID)
    }

    func test_lockedSetTokenData_roundTrips() throws {
        let store = freshStore()
        let payload = Data("fake-token-blob".utf8)
        store.saveLockedSetID(UUID().uuidString, tokenData: payload)

        let loaded = try XCTUnwrap(store.lockedSetTokenData)
        XCTAssertEqual(loaded, payload)
    }

    func test_lockedSetID_persistsAcrossInstances() {
        let store = freshStore()
        let id = UUID().uuidString
        store.saveLockedSetID(id, tokenData: nil)

        let reloaded = EarnedTimeStore()
        XCTAssertEqual(reloaded.lockedSetID, id)
    }

    // MARK: - Override flag

    func test_overrideFlag_falseByDefault() {
        let store = freshStore()
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-23"))
    }

    func test_overrideFlag_setForDate() {
        let store = freshStore()
        store.setOverride(true, forUsageDate: "2026-06-23")
        XCTAssertTrue(store.isOverridden(forUsageDate: "2026-06-23"))
    }

    func test_overrideFlag_clearForDate() {
        let store = freshStore()
        store.setOverride(true, forUsageDate: "2026-06-23")
        store.setOverride(false, forUsageDate: "2026-06-23")
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-23"))
    }

    func test_overrideFlag_doesNotLeakToOtherDate() {
        let store = freshStore()
        store.setOverride(true, forUsageDate: "2026-06-23")
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-24"))
    }

    // MARK: - backendRemainingAtLastSync

    func test_backendRemaining_roundTrips() {
        let store = freshStore()
        store.backendRemainingAtLastSync = 42
        XCTAssertEqual(store.backendRemainingAtLastSync, 42)
    }

    func test_backendRemaining_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.backendRemainingAtLastSync)
    }

    func test_backendRemaining_persistsAcrossInstances() {
        let store = freshStore()
        store.backendRemainingAtLastSync = 99
        let reloaded = EarnedTimeStore()
        XCTAssertEqual(reloaded.backendRemainingAtLastSync, 99)
    }

    // MARK: - latestDeviceEstimate

    func test_latestDeviceEstimate_roundTrips() {
        let store = freshStore()
        store.latestDeviceEstimate = 15
        XCTAssertEqual(store.latestDeviceEstimate, 15)
    }

    func test_latestDeviceEstimate_nilBeforeSave() {
        let store = freshStore()
        XCTAssertNil(store.latestDeviceEstimate)
    }

    func test_latestDeviceEstimate_persistsAcrossInstances() {
        let store = freshStore()
        store.latestDeviceEstimate = 7
        let reloaded = EarnedTimeStore()
        XCTAssertEqual(reloaded.latestDeviceEstimate, 7)
    }

    // MARK: - usage counting gate

    func test_usageCountingAllowed_defaultsToTrueBeforeChildStateArrives() {
        let store = freshStore()
        XCTAssertTrue(store.usageCountingAllowed)
    }

    func test_usageCountingAllowed_roundTripsAcrossInstances() {
        let store = freshStore()
        store.usageCountingAllowed = false

        XCTAssertFalse(UserDefaults(suiteName: "group.com.evlin.ios")?.bool(
            forKey: "evlin.usageCountingAllowed"
        ) ?? true)

        store.usageCountingAllowed = true
        XCTAssertTrue(store.usageCountingAllowed)
    }

    // MARK: - Locked-set list alias key (locked-set-sync)

    func test_lockedSetListAliasKey_isNilByDefault() {
        let store = freshStore()
        XCTAssertNil(store.lockedSetListAliasKey)
    }

    func test_saveLockedSetListAliasKey_roundTrips() {
        let store = freshStore()
        let key = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        store.saveLockedSetListAliasKey(key)
        XCTAssertEqual(store.lockedSetListAliasKey, key)
    }

    func test_saveLockedSetListAliasKey_overwritesPreviousValue() {
        let store = freshStore()
        let key1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let key2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        store.saveLockedSetListAliasKey(key1)
        store.saveLockedSetListAliasKey(key2)
        XCTAssertEqual(store.lockedSetListAliasKey, key2)
    }

    func test_removeAll_clearsLockedSetListAliasKey() {
        let store = freshStore()
        store.saveLockedSetListAliasKey(UUID())
        store.removeAll()
        XCTAssertNil(store.lockedSetListAliasKey)
    }

    // MARK: - removeAll (teardown helper)

    func test_removeAll_clearsEverything() {
        let store = freshStore()
        store.saveMeasurementSelection(FamilyActivitySelection())
        store.saveLockedSetID(UUID().uuidString, tokenData: Data("blob".utf8))
        store.setOverride(true, forUsageDate: "2026-06-23")
        store.backendRemainingAtLastSync = 30
        store.latestDeviceEstimate = 10
        store.usageCountingAllowed = false

        store.removeAll()

        XCTAssertNil(store.measurementSelection)
        XCTAssertNil(store.lockedSetID)
        XCTAssertNil(store.lockedSetTokenData)
        XCTAssertFalse(store.isOverridden(forUsageDate: "2026-06-23"))
        XCTAssertNil(store.backendRemainingAtLastSync)
        XCTAssertNil(store.latestDeviceEstimate)
        XCTAssertTrue(store.usageCountingAllowed)
        XCTAssertFalse(store.isEarnedTimeReady)
    }
}
