import XCTest
@testable import Evlin_iOS

final class DefaultLockGroupTests: XCTestCase {
    func test_id_isStableAcrossCalls() {
        XCTAssertEqual(DefaultLockGroup.shared.id, DefaultLockGroup.shared.id)
    }
    func test_recordKey_matchesSavedListConvention() {
        XCTAssertEqual(DefaultLockGroup.shared.recordKey, "savedList:\(DefaultLockGroup.shared.id)")
    }
}
