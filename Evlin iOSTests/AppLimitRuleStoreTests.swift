import XCTest
import FamilyControls
import ManagedSettings
@testable import Evlin_iOS

/// P4: round-trip + CRUD coverage for the per-app limit rule persistence store.
/// The DeviceActivity extension's `eventDidReachThreshold` callback only gets the
/// event NAME (`evlin.limit.<ruleId>`), so it must look the rule's tokens/metadata
/// up here. Persisted in App Group `group.com.evlin.ios` with the same `.iso8601`
/// JSON encoder the extension uses, so a later task can read it cross-process.
///
/// NOTE: `ApplicationToken`s are opaque, picker-minted values that cannot be
/// constructed in a unit test. These tests therefore exercise the non-token
/// fields plus an empty token set; the token (de)serialization path reuses the
/// proven `LocalAliasStore` JSON token encoding, covered by its own tests.
final class AppLimitRuleStoreTests: XCTestCase {

    private func freshStore() -> AppLimitRuleStore {
        let store = AppLimitRuleStore.shared
        store.removeAll()
        return store
    }

    override func tearDown() {
        AppLimitRuleStore.shared.removeAll()
        super.tearDown()
    }

    private func makeRule(
        id: UUID = UUID(),
        bundleID: String = "com.burbn.instagram",
        budgetMinutes: Int = 45
    ) -> AppLimitRule {
        AppLimitRule(
            id: id,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Instagram",
            budgetMinutes: budgetMinutes,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/Los_Angeles"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400)
        )
    }

    func test_upsertThenReadBack_preservesAllFields() throws {
        let store = freshStore()
        let id = UUID()
        let rule = makeRule(id: id, bundleID: "com.toyopagroup.picaboo", budgetMinutes: 30)

        store.upsert(rule)

        let read = try XCTUnwrap(store.rule(forID: id))
        XCTAssertEqual(read.id, id)
        XCTAssertEqual(read.bundleID, "com.toyopagroup.picaboo")
        XCTAssertEqual(read.displayName, "Instagram")
        XCTAssertEqual(read.budgetMinutes, 30)
        XCTAssertEqual(read.appTokens, [])
        XCTAssertEqual(read.window.startMinute, 0)
        XCTAssertEqual(read.window.endMinute, 1439)
        XCTAssertTrue(read.window.repeats)
        XCTAssertEqual(read.window.timezone, "America/Los_Angeles")
        XCTAssertEqual(read.effectiveFrom, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(read.expiresAt, Date(timeIntervalSince1970: 1_700_086_400))
    }

    func test_upsert_replacesExistingRuleWithSameID() {
        let store = freshStore()
        let id = UUID()
        store.upsert(makeRule(id: id, budgetMinutes: 45))
        store.upsert(makeRule(id: id, budgetMinutes: 15))

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.rule(forID: id)?.budgetMinutes, 15)
    }

    func test_all_returnsEveryUpsertedRule() {
        let store = freshStore()
        let a = makeRule(bundleID: "com.a")
        let b = makeRule(bundleID: "com.b")
        store.upsert(a)
        store.upsert(b)

        let all = store.all()
        XCTAssertEqual(Set(all.map(\.id)), [a.id, b.id])
    }

    func test_remove_dropsOnlyTheNamedRule() {
        let store = freshStore()
        let a = makeRule(bundleID: "com.a")
        let b = makeRule(bundleID: "com.b")
        store.upsert(a)
        store.upsert(b)

        store.remove(ruleId: a.id)

        XCTAssertNil(store.rule(forID: a.id))
        XCTAssertNotNil(store.rule(forID: b.id))
        XCTAssertEqual(store.all().count, 1)
    }

    /// Persistence is real App Group UserDefaults — a freshly-read store instance
    /// must see what a prior instance wrote (proves the on-disk JSON survives,
    /// which is the whole reason the extension can read it later).
    func test_persistsAcrossStoreInstances() throws {
        let store = freshStore()
        let id = UUID()
        store.upsert(makeRule(id: id, budgetMinutes: 20))

        let reloaded = AppLimitRuleStore()
        XCTAssertEqual(reloaded.rule(forID: id)?.budgetMinutes, 20)
    }

    func test_nilExpiresAt_roundTrips() throws {
        let store = freshStore()
        let id = UUID()
        var rule = makeRule(id: id)
        rule = AppLimitRule(
            id: rule.id,
            appTokens: rule.appTokens,
            bundleID: rule.bundleID,
            displayName: rule.displayName,
            budgetMinutes: rule.budgetMinutes,
            window: rule.window,
            effectiveFrom: rule.effectiveFrom,
            expiresAt: nil
        )
        store.upsert(rule)

        let read = try XCTUnwrap(store.rule(forID: id))
        XCTAssertNil(read.expiresAt)
    }
}
