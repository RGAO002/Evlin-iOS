import XCTest
@testable import Evlin_iOS

final class EvlinPINGateSyncTests: XCTestCase {
    func testExistingVerifiedPINIsForwardedForBackendConvergence() {
        XCTAssertEqual(
            EvlinPINGateView.syncablePIN(
                enteredPIN: "2468",
                authenticated: true
            ),
            "2468"
        )
    }

    func testRejectedPINIsNeverForwarded() {
        XCTAssertNil(
            EvlinPINGateView.syncablePIN(
                enteredPIN: "0000",
                authenticated: false
            )
        )
    }
}
