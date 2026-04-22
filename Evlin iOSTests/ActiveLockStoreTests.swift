import XCTest
@testable import Evlin_iOS

final class ActiveLockStoreTests: XCTestCase {
    override func setUp() async throws {
        // Clean slate between tests — each test gets its own store instance.
        // Note: shared App Group UserDefaults persist, so we clean explicitly.
        UserDefaults(suiteName: "group.com.evlin.ios")?.removeObject(forKey: "evlin.activeLocks")
    }

    func test_add_then_remove_clearsStore() async {
        let store = ActiveLockStore()
        let lock = Self.makeBundleLock(id: UUID(), bundles: ["com.x.y"])
        await store.add(lock)
        var cur = await store.current()
        XCTAssertEqual(cur.count, 1)

        await store.remove(commandID: lock.id)
        cur = await store.current()
        XCTAssertEqual(cur.count, 0)
    }

    func test_sweepExpired_removesOnlyExpired() async {
        let store = ActiveLockStore()
        let live = Self.makeBundleLock(id: UUID(), bundles: ["a"], expiresAt: .distantFuture)
        let dead = Self.makeBundleLock(id: UUID(), bundles: ["b"], expiresAt: Date().addingTimeInterval(-1))
        await store.add(live)
        await store.add(dead)

        let removed = await store.sweepExpired()
        XCTAssertEqual(removed, [dead.id])
        let remaining = await store.current().map(\.id)
        XCTAssertEqual(remaining, [live.id])
    }

    func test_addPermanent_hasNoExpiry() async {
        let store = ActiveLockStore()
        let permanent = Self.makeBundleLock(id: UUID(), bundles: ["x"], expiresAt: nil)
        await store.add(permanent)
        let removed = await store.sweepExpired()
        XCTAssertTrue(removed.isEmpty)
    }

    func test_removeMatching_byBundleID() async {
        let store = ActiveLockStore()
        let igLock = Self.makeBundleLock(id: UUID(), bundles: ["com.burbn.instagram"])
        let ttLock = Self.makeBundleLock(id: UUID(), bundles: ["com.zhiliaoapp.musically"])
        await store.add(igLock)
        await store.add(ttLock)

        var target = CommandTarget(originalRequest: "IG")
        target.bundleID = "com.burbn.instagram"
        let removed = await store.removeMatching(target)
        XCTAssertEqual(removed, [igLock.id])
        let remaining = await store.current().map(\.id)
        XCTAssertEqual(remaining, [ttLock.id])
    }

    func test_removeAll_clearsEverything() async {
        let store = ActiveLockStore()
        await store.add(Self.makeBundleLock(id: UUID(), bundles: ["a"]))
        await store.add(Self.makeBundleLock(id: UUID(), bundles: ["b"]))
        await store.add(Self.makeBundleLock(id: UUID(), bundles: ["c"]))
        XCTAssertEqual(await store.current().count, 3)

        await store.removeAll()
        XCTAssertEqual(await store.current().count, 0)
    }

    func test_concurrentExpiryDoesNotReleaseOtherLocks() async {
        // Critical behavior: if lock1 expires, locks 2 and 3 remain.
        let store = ActiveLockStore()
        let l1 = Self.makeBundleLock(id: UUID(), bundles: ["com.a"], expiresAt: Date().addingTimeInterval(-1)) // expired
        let l2 = Self.makeBundleLock(id: UUID(), bundles: ["com.b"], expiresAt: .distantFuture)
        let l3 = Self.makeBundleLock(id: UUID(), bundles: ["com.c"], expiresAt: nil) // permanent
        await store.add(l1)
        await store.add(l2)
        await store.add(l3)

        let removed = await store.sweepExpired()
        XCTAssertEqual(removed, [l1.id])
        let remainingIDs = Set(await store.current().map(\.id))
        XCTAssertEqual(remainingIDs, Set([l2.id, l3.id]))
    }

    // MARK: helpers
    private static func makeBundleLock(id: UUID, bundles: [String], expiresAt: Date? = .distantFuture) -> ActiveLock {
        ActiveLock(
            id: id,
            tier: .exactBundle,
            blockedBundleIDs: Set(bundles),
            shieldAppTokens: [],
            shieldCategoryTokens: [],
            issuedAt: Date(),
            expiresAt: expiresAt,
            originalRequest: bundles.first ?? "",
            displayName: bundles.first ?? ""
        )
    }
}
