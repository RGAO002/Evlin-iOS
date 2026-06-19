import XCTest
@testable import Evlin_iOS

final class GroupEditReconcilerTests: XCTestCase {
    func test_active_reappliesWithForce() {
        XCTAssertEqual(GroupEditReconciler.action(active: true), .reapplyWithForce)
    }
    func test_inactive_blobOnly() {
        XCTAssertEqual(GroupEditReconciler.action(active: false), .blobOnly)
    }
}
