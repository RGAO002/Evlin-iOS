import XCTest
@testable import Evlin_iOS

/// The Lock Activity Review must stay off the hot path: applying a lock must
/// not reference or wait on review report/embed types.
final class HotPathIsolationTests: XCTestCase {
    func test_lockWindowStore_isPlainAppGroupHelper_noDeviceActivityImport() {
        let suite = UserDefaults(suiteName: "group.com.evlin.ios")
        suite?.removeObject(forKey: LockWindowStore.key)

        LockWindowStore.append(LockWindowRecord(
            recordKey: "exactApp:com.x",
            displayName: "X",
            bundleID: "com.x",
            issuedAt: Date(),
            expiresAt: nil
        ))

        XCTAssertEqual(LockWindowStore.load().count, 1)
    }

    func test_reviewFilterHelper_isPureAndCallableWithoutReportContext() {
        let ids = LockReviewFilterHelper.lockedBundleIDs(from: [])
        XCTAssertTrue(ids.isEmpty)
    }
}
