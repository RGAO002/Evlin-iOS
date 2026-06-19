import XCTest
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
}
