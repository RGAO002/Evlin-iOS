import XCTest
@testable import Evlin_iOS

final class ReceiptUnlockRoutingTests: XCTestCase {
    func testReceiptUnlockUsesBackendUnshieldPhrase() {
        let target = ReceiptUnlockTarget(displayName: "Instagram", tier: .exactApp)

        XCTAssertEqual(
            ChatViewModel.receiptUnlockPhrase(for: target),
            "unshield Instagram"
        )
    }

    func testReceiptUnlockPhraseTrimsWhitespace() {
        let target = ReceiptUnlockTarget(displayName: "  Social  ", tier: .category)

        XCTAssertEqual(
            ChatViewModel.receiptUnlockPhrase(for: target),
            "unshield Social"
        )
    }
}
