import XCTest
@testable import Evlin_iOS

final class LockReviewFilterTests: XCTestCase {
    func test_lockedBundleIDs_dedupesAndDropsNil() {
        let windows = [
            LockWindowRecord(
                recordKey: "a",
                displayName: "Instagram",
                bundleID: "com.burbn.instagram",
                issuedAt: Date(),
                expiresAt: nil
            ),
            LockWindowRecord(
                recordKey: "b",
                displayName: "Instagram",
                bundleID: "com.burbn.instagram",
                issuedAt: Date(),
                expiresAt: nil
            ),
            LockWindowRecord(
                recordKey: "c",
                displayName: "Games",
                bundleID: nil,
                issuedAt: Date(),
                expiresAt: nil
            ),
        ]

        XCTAssertEqual(
            LockReviewFilterHelper.lockedBundleIDs(from: windows),
            ["com.burbn.instagram"]
        )
    }

    func test_lockedBundleIDs_scopesBestEffortUsageToLockedAppsOnly() {
        // The review surfaces best-effort current usage for the locked bundleIDs
        // only. It cannot decide whether usage fell inside a historical lock window.
        let base = Date(timeIntervalSince1970: 3_000_000)
        let windows = [
            LockWindowRecord(
                recordKey: "a",
                displayName: "Instagram",
                bundleID: "com.burbn.instagram",
                issuedAt: base,
                expiresAt: base.addingTimeInterval(900)
            ),
            LockWindowRecord(
                recordKey: "b",
                displayName: "Snapchat",
                bundleID: "com.toyopagroup.picaboo",
                issuedAt: base,
                expiresAt: nil
            ),
        ]

        let locked = LockReviewFilterHelper.lockedBundleIDs(from: windows)
        XCTAssertEqual(locked, ["com.burbn.instagram", "com.toyopagroup.picaboo"])
        XCTAssertFalse(locked.contains("com.other.app"))
    }

    func test_missingData_isNotProofOfNoUsage_copyIsPresent() {
        XCTAssertEqual(
            EvlinReceiptCopy.reviewIsBestEffort,
            "Best-effort review. Missing usage data is not proof the app went unused."
        )
        XCTAssertEqual(
            EvlinReceiptCopy.reviewUsageDuringWindow,
            "This app may not have been blocked — try refreshing Screen Time control / re-binding the app."
        )
    }
}
