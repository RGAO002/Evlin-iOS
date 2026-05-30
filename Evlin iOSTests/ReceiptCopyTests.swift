import XCTest
@testable import Evlin_iOS

final class ReceiptCopyTests: XCTestCase {
    /// The honest receipt string is the exact spec copy and never claims
    /// Apple-level confirmation.
    func test_honestReceipt_isExactSpecCopy() {
        XCTAssertEqual(
            EvlinReceiptCopy.appliedOnKidDevice,
            "Evlin applied this lock on Kid's iPhone"
        )
    }

    func test_honestReceipt_neverClaimsAppleInterception() {
        let copy = EvlinReceiptCopy.appliedOnKidDevice.lowercased()
        XCTAssertFalse(copy.contains("apple confirmed"))
        XCTAssertFalse(copy.contains("intercepted"))
        XCTAssertFalse(copy.contains("blocked by ios"))
    }
}
