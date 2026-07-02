import XCTest
@testable import Evlin_iOS

final class DefaultLockGroupTests: XCTestCase {
    func test_id_isStableAcrossCalls() {
        XCTAssertEqual(DefaultLockGroup.shared.id, DefaultLockGroup.shared.id)
    }
    func test_recordKey_matchesSavedListConvention() {
        // Wave-1 Task 5: `makeRecordKey` lowercases the `.savedList` segment
        // (immortal-lock fix), so `recordKey` no longer matches `id` verbatim
        // when `id` is the uppercase pre-sync local UUID — it matches its
        // lowercased form.
        XCTAssertEqual(DefaultLockGroup.shared.recordKey, "savedList:\(DefaultLockGroup.shared.id.lowercased())")
    }
}
