import XCTest
@testable import Evlin_iOS

final class ParentPINRowTests: XCTestCase {
    func testAvailablePINCanBeShown() {
        let row = ParentPINRow.display(status: "available", pin: "4826", kidName: "Maya")
        XCTAssertEqual(row.value, "4826")
        XCTAssertTrue(row.canClear)
    }

    func testMissingValueDoesNotPretendAvailable() {
        let row = ParentPINRow.display(status: "available", pin: nil, kidName: "Maya")
        XCTAssertNil(row.value)
        XCTAssertEqual(row.subtitle, "Will appear when Maya's phone syncs.")
        XCTAssertTrue(row.canClear)
    }

    func testUnrecoverableOffersClearExit() {
        let row = ParentPINRow.display(status: "unrecoverable", pin: nil, kidName: "Maya")
        XCTAssertNil(row.value)
        XCTAssertTrue(row.canClear)
        XCTAssertEqual(row.subtitle, "Clear it here, then create a new PIN on Maya's phone.")
    }

    func testNotSetDoesNotOfferClear() {
        let row = ParentPINRow.display(status: "not_set", pin: nil, kidName: "Maya")
        XCTAssertFalse(row.canClear)
    }
}
