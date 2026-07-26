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
            for: .confirmedExact(
                verb: .unshield,
                displayName: "Instagram",
                unlocksAt: nil,
                artworkURL: nil
            ),
            effectiveState: state
        )

        XCTAssertEqual(actions?.unlockTarget.displayName, "Games")
        XCTAssertEqual(actions?.unlockTarget.tier, .category)
        XCTAssertEqual(actions?.unlockButtonTitle, "Unlock Games")
        XCTAssertEqual(actions?.keepButtonTitle, "Keep locked")
        // Task 11 — receipts also offer "Block instead" to escalate the
        // still-covered target to a permanent block.
        XCTAssertEqual(actions?.blockButtonTitle, "Block instead")
    }

    func test_receiptActionsDoNotOfferUnlockWhenNothingStillCoversTarget() {
        let state = AckEffectiveState(
            isBlocked: false,
            shieldsCovering: [],
            possibleSavedListCoverage: false
        )

        let actions = ReceiptCardActionModel.actions(
            for: .confirmedExact(
                verb: .unshield,
                displayName: "Instagram",
                unlocksAt: nil,
                artworkURL: nil
            ),
            effectiveState: state
        )

        XCTAssertNil(actions)
    }

    func test_timedBlockReceiptShowsRestoreTimeInsteadOfPermanentCopy() {
        let date = Date(timeIntervalSince1970: 1_800)

        XCTAssertEqual(
            ReceiptCardCopyModel.timeLimitLine(
                verb: .block,
                unlocksAt: date,
                timeString: { _ in "3:45 PM" }
            ),
            "Restores at 3:45 PM"
        )
    }

    func test_permanentBlockReceiptUsesUnblockCopy() {
        XCTAssertEqual(
            ReceiptCardCopyModel.timeLimitLine(
                verb: .block,
                unlocksAt: nil,
                timeString: { _ in "unused" }
            ),
            "Until you unblock"
        )
    }

    func test_kidNotRespondingCopyDoesNotRequireOpeningEvlin() {
        XCTAssertEqual(
            ReceiptCardCopyModel.kidNotRespondingDetail,
            "Still queued — it will apply when the kid device receives or polls for commands."
        )
    }

    func test_pickedUpCopySaysKidDeviceReceivedCommand() {
        XCTAssertEqual(
            ReceiptCardCopyModel.pickedUpDetail,
            "Kid device received the command — applying now."
        )
    }

    func test_lockStoreUnavailableUsesParentFacingCopy() {
        let copy = ChatViewModel.parentFacingExecutionFailure("lock_store_unavailable")

        XCTAssertEqual(
            copy,
            "Screen Time controls weren't available on the selected kid device. Open Evlin there, then try again."
        )
        XCTAssertFalse(copy.contains("lock_store_unavailable"))
    }

    func test_unknownExecutionFailureDoesNotExposeInternalValue() {
        let copy = ChatViewModel.parentFacingExecutionFailure("some_internal_code")

        XCTAssertEqual(copy, "The kid device couldn't apply this command. Try again.")
        XCTAssertFalse(copy.contains("some_internal_code"))
    }

    func test_ackStatusDecodesDeliveryStateAndTimestamps() throws {
        let json = Data("""
        {
          "command_id": "11111111-1111-1111-1111-111111111111",
          "status": "pending",
          "delivery_state": "picked_up",
          "created_at": "2026-06-10T22:50:00Z",
          "picked_up_at": "2026-06-10T22:50:02Z",
          "acked_at": null,
          "bundle_id": "com.burbn.instagram",
          "artwork_url": "https://example.com/instagram.png"
        }
        """.utf8)

        let response = try JSONDecoder().decode(AckStatusResponse.self, from: json)

        XCTAssertEqual(response.deliveryState, "picked_up")
        XCTAssertEqual(response.createdAt, "2026-06-10T22:50:00Z")
        XCTAssertEqual(response.pickedUpAt, "2026-06-10T22:50:02Z")
        XCTAssertNil(response.ackedAt)
        XCTAssertEqual(response.bundleID, "com.burbn.instagram")
        XCTAssertEqual(response.artworkURL, URL(string: "https://example.com/instagram.png"))
    }
}
