import XCTest
@testable import Evlin_iOS

final class LockWindowLogTests: XCTestCase {
    private let suite = "group.com.evlin.ios"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suite)?.removeObject(forKey: LockWindowStore.key)
    }

    func test_append_thenLoad_roundTrips() {
        let record = LockWindowRecord(
            recordKey: "exactApp:com.burbn.instagram",
            displayName: "Instagram",
            bundleID: "com.burbn.instagram",
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_000_900)
        )

        LockWindowStore.append(record)

        let all = LockWindowStore.load()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.displayName, "Instagram")
        XCTAssertEqual(all.first?.bundleID, "com.burbn.instagram")
    }

    func test_append_capsHistoryAt200_keepingNewest() {
        for i in 0..<205 {
            LockWindowStore.append(LockWindowRecord(
                recordKey: "exactApp:app\(i)",
                displayName: "App\(i)",
                bundleID: "com.x.app\(i)",
                issuedAt: Date(timeIntervalSince1970: Double(i)),
                expiresAt: Date(timeIntervalSince1970: Double(i) + 60)
            ))
        }

        let all = LockWindowStore.load()
        XCTAssertEqual(all.count, 200)
        XCTAssertTrue(all.contains { $0.displayName == "App204" })
        XCTAssertFalse(all.contains { $0.displayName == "App0" })
    }

    func test_windowsCovering_filtersByBundleAndOverlap() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        LockWindowStore.append(LockWindowRecord(
            recordKey: "exactApp:com.burbn.instagram",
            displayName: "Instagram",
            bundleID: "com.burbn.instagram",
            issuedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(300)
        ))
        LockWindowStore.append(LockWindowRecord(
            recordKey: "exactApp:com.zhiliaoapp.musically",
            displayName: "TikTok",
            bundleID: "com.zhiliaoapp.musically",
            issuedAt: now.addingTimeInterval(-10_000),
            expiresAt: now.addingTimeInterval(-9_000)
        ))

        let igNow = LockWindowStore.windows(
            forBundleID: "com.burbn.instagram",
            overlapping: DateInterval(start: now, duration: 1)
        )
        XCTAssertEqual(igNow.count, 1)

        let ttNow = LockWindowStore.windows(
            forBundleID: "com.zhiliaoapp.musically",
            overlapping: DateInterval(start: now, duration: 1)
        )
        XCTAssertEqual(ttNow.count, 0)
    }
}
