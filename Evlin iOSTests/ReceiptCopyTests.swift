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

    func test_receiptActionsOfferUnlockForStrongestShieldCover() {
        let state = AckEffectiveState(
            isBlocked: false,
            shieldsCovering: [
                .init(displayName: "Instagram", expiresAtISO: "2026-05-31T18:00:00Z", tier: "specific"),
                .init(displayName: "Games", expiresAtISO: nil, tier: "category"),
            ],
            possibleSavedListCoverage: false
        )

        let actions = ReceiptCardActionModel.actions(
            for: .confirmedExact(verb: .unshield, displayName: "Instagram", unlocksAt: nil),
            effectiveState: state
        )

        XCTAssertEqual(actions?.unlockTarget.displayName, "Games")
        XCTAssertEqual(actions?.unlockTarget.tier, .category)
        XCTAssertEqual(actions?.unlockButtonTitle, "Unlock Games")
        XCTAssertEqual(actions?.keepButtonTitle, "Keep locked")
    }

    func test_receiptActionsDoNotOfferUnlockWhenNothingStillCoversTarget() {
        let state = AckEffectiveState(
            isBlocked: false,
            shieldsCovering: [],
            possibleSavedListCoverage: false
        )

        let actions = ReceiptCardActionModel.actions(
            for: .confirmedExact(verb: .unshield, displayName: "Instagram", unlocksAt: nil),
            effectiveState: state
        )

        XCTAssertNil(actions)
    }
}
