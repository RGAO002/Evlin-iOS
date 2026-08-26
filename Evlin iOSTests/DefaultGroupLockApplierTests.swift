import XCTest
import FamilyControls
@testable import Evlin_iOS

final class DefaultGroupLockApplierTests: XCTestCase {
    func test_makeRecord_shape() {
        let child = UUID()
        let r = DefaultGroupLockApplier.makeRecord(appTokens: [], categoryTokens: [], childID: child)
        XCTAssertEqual(r.recordKey, DefaultLockGroup.shared.recordKey)
        XCTAssertEqual(r.tier, .savedList)
        XCTAssertEqual(r.targetKey, DefaultLockGroup.shared.id)
        XCTAssertEqual(r.appliesToAll, false)
        XCTAssertTrue(r.webDomainTokens.isEmpty)
        XCTAssertEqual(r.targetChildID, child)
    }

    func test_manualLockMutationPreservesAutomaticSources() {
        let child = UUID()
        var automatic = DefaultGroupLockApplier.makeRecord(
            appTokens: [],
            categoryTokens: [],
            childID: child
        )
        automatic.sources = [.earnedTime, .taskPause, .limit]

        let locked = DefaultGroupLockApplier.reconcilingManualLock(
            in: [automatic.recordKey: automatic],
            selection: FamilyActivitySelection(),
            childID: child,
            commandID: UUID(),
            locked: true
        )
        XCTAssertEqual(
            locked[automatic.recordKey]?.sources,
            [.manual, .earnedTime, .taskPause, .limit]
        )

        let unlocked = DefaultGroupLockApplier.reconcilingManualLock(
            in: locked,
            selection: FamilyActivitySelection(),
            childID: child,
            commandID: UUID(),
            locked: false
        )
        XCTAssertEqual(
            unlocked[automatic.recordKey]?.sources,
            [.earnedTime, .taskPause, .limit]
        )
    }

    func test_manualUnlockDeletesRecordOnlyWhenNoOtherSourceRemains() {
        let child = UUID()
        let manual = DefaultGroupLockApplier.makeRecord(
            appTokens: [],
            categoryTokens: [],
            childID: child
        )
        let result = DefaultGroupLockApplier.reconcilingManualLock(
            in: [manual.recordKey: manual],
            selection: FamilyActivitySelection(),
            childID: child,
            commandID: UUID(),
            locked: false
        )
        XCTAssertNil(result[manual.recordKey])
    }
}
