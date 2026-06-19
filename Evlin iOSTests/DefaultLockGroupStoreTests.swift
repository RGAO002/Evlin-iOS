import XCTest
import FamilyControls
@testable import Evlin_iOS

final class DefaultLockGroupStoreTests: XCTestCase {
    func test_saveThenLoad_emptySelection_roundTrips() {
        DefaultLockGroupStore.save(FamilyActivitySelection())
        let loaded = DefaultLockGroupStore.load()
        XCTAssertTrue(loaded.applicationTokens.isEmpty)
        XCTAssertTrue(loaded.categoryTokens.isEmpty)
        XCTAssertTrue(loaded.webDomainTokens.isEmpty)
    }
}
