import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitMidnightRolloverTests: XCTestCase {
    func testIntervalStartRouterOwnsOnlyValidPerAppV2Activities() throws {
        let fixture = try RolloverFixture()
        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule,
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneStart
        ).provenance
        let router = AppLimitIntervalStartRouter(
            provenanceStore: fixture.provenanceStore
        )

        XCTAssertEqual(
            router.route(
                activityName: provenance.activityName,
                now: fixture.dayTwoStart
            ),
            .resetLimitShields(
                rollover: .rolledOver(
                    from: "2026-07-25",
                    to: "2026-07-26"
                )
            )
        )
        XCTAssertEqual(
            router.route(
                activityName: provenance.activityName,
                now: fixture.dayTwoStart.addingTimeInterval(60)
            ),
            .resetLimitShields(
                rollover: .unchanged(usageDate: "2026-07-26")
            )
        )
        XCTAssertEqual(
            router.route(
                activityName: "evlin.earned.v2.\(UUID().uuidString.lowercased())",
                now: fixture.dayTwoStart
            ),
            .notPerAppV2
        )
        XCTAssertEqual(
            router.route(
                activityName: "evlin.limit.v2.not-a-uuid",
                now: fixture.dayTwoStart
            ),
            .failClosed(reason: "malformed_activity")
        )
        XCTAssertEqual(
            router.route(
                activityName: "evlin.limit.v2.\(UUID().uuidString.lowercased())",
                now: fixture.dayTwoStart
            ),
            .failClosed(reason: "unknown_activity")
        )
    }

    func testRecurringIntervalRollsToCanonicalNewDayWithoutReplacingMonitor() throws {
        let fixture = try RolloverFixture()
        let first = try fixture.provenanceStore.resolve(
            rule: fixture.rule,
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneStart
        ).provenance
        let pausedAt = fixture.dayOneStart.addingTimeInterval(300)
        try fixture.store.transaction(source: .wakeRecovery, expectedOwner: fixture.owner) { state in
            var slot = try XCTUnwrap(state.slots[fixture.rule.id])
            var provenance = try XCTUnwrap(slot.armProvenance)
            provenance.baseAcceptedMinutes = 10
            provenance.lastRawThresholdMinutes = 15
            provenance.ignoredWhilePausedMinutes = 5
            provenance.pausedAt = pausedAt
            slot.armProvenance = provenance
            slot.authoritativeUsedTodayMinutes = 25
            state.slots[fixture.rule.id] = slot
        }

        let result = try fixture.provenanceStore.rolloverRecurringInterval(
            activityName: first.activityName,
            now: fixture.dayTwoStart
        )

        XCTAssertEqual(
            result,
            .rolledOver(from: "2026-07-25", to: "2026-07-26")
        )
        let slot = try XCTUnwrap(fixture.store.read().slots[fixture.rule.id])
        let rolled = try XCTUnwrap(slot.armProvenance)
        XCTAssertEqual(rolled.usageDate, "2026-07-26")
        XCTAssertEqual(rolled.startedAt, fixture.dayTwoStart)
        XCTAssertEqual(rolled.baseAcceptedMinutes, 0)
        XCTAssertEqual(rolled.lastRawThresholdMinutes, 0)
        XCTAssertEqual(rolled.ignoredWhilePausedMinutes, 0)
        XCTAssertEqual(rolled.pausedAt, pausedAt)
        XCTAssertEqual(rolled.predecessorIgnoredWhilePausedMinutes, 5)
        XCTAssertEqual(rolled.armID, first.armID)
        XCTAssertEqual(rolled.activityName, first.activityName)
        XCTAssertEqual(slot.authoritativeUsedTodayMinutes, 0)
    }

    func testFirstPlausibleThresholdAfterRolloverUsesTheNewDay() throws {
        let fixture = try RolloverFixture()
        let first = try fixture.provenanceStore.resolve(
            rule: fixture.rule,
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneStart
        ).provenance
        XCTAssertEqual(
            try fixture.provenanceStore.rolloverRecurringInterval(
                activityName: first.activityName,
                now: fixture.dayTwoStart
            ),
            .rolledOver(from: "2026-07-25", to: "2026-07-26")
        )

        var accepted: AppLimitValidatedCallback?
        let decision = try AppLimitCallbackValidator(store: fixture.store).process(
            activityName: first.activityName,
            eventName: AppLimitPlanner.v2MeasurementEventName(
                armID: first.armID,
                threshold: 15
            ),
            canonicalUsageDate: "2026-07-26",
            observedAt: fixture.dayTwoStart.addingTimeInterval(15 * 60),
            usageCountingAllowed: true
        ) { callback in
            accepted = callback
        }

        XCTAssertAccepted(decision, kind: .measurement)
        XCTAssertEqual(accepted?.provenance.usageDate, "2026-07-26")
        XCTAssertEqual(accepted?.adjustedEstimateMinutes, 15)
    }

    func testSameDayRolloverIsIdempotentAndBackwardDateFailsClosed() throws {
        let fixture = try RolloverFixture()
        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule,
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneStart
        ).provenance

        XCTAssertEqual(
            try fixture.provenanceStore.rolloverRecurringInterval(
                activityName: provenance.activityName,
                now: fixture.dayOneStart.addingTimeInterval(3_600)
            ),
            .unchanged(usageDate: "2026-07-25")
        )
        XCTAssertEqual(
            try fixture.provenanceStore.rolloverRecurringInterval(
                activityName: provenance.activityName,
                now: fixture.dayOneStart.addingTimeInterval(-86_400)
            ),
            .rejected(reason: "backward_usage_date")
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.read().slots[fixture.rule.id]?.armProvenance),
            provenance
        )
    }

    func testEqualThresholdsOnDifferentDaysHaveDistinctEffectKeys() {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let armID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let dayOne = AppLimitEffectKey(
            ruleID: ruleID,
            orderingToken: 7,
            armID: armID,
            usageDate: "2026-07-25",
            effectKind: .measurement,
            rawThresholdMinutes: 5
        )
        let dayTwo = AppLimitEffectKey(
            ruleID: ruleID,
            orderingToken: 7,
            armID: armID,
            usageDate: "2026-07-26",
            effectKind: .measurement,
            rawThresholdMinutes: 5
        )
        let legacy = AppLimitEffectKey(
            ruleID: ruleID,
            orderingToken: 7,
            armID: armID,
            effectKind: .measurement,
            rawThresholdMinutes: 5
        )

        XCTAssertNotEqual(dayOne.storageKey, dayTwo.storageKey)
        XCTAssertEqual(
            legacy.storageKey,
            "10000000-0000-0000-0000-000000000001:7:"
                + "30000000-0000-0000-0000-000000000001:measurement:5"
        )
    }
}

private final class RolloverFixture {
    let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let armID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    let dayOneStart = ISO8601DateFormatter().date(from: "2026-07-25T04:00:00Z")!
    let dayTwoStart = ISO8601DateFormatter().date(from: "2026-07-26T04:00:00Z")!
    let rule: AppLimitRule
    let store: AppLimitEpochStore
    let provenanceStore: AppLimitProvenanceStore
    private let directoryURL: URL

    init() throws {
        rule = AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.facebook.Facebook",
            displayName: "Facebook",
            budgetMinutes: 60,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-limit-midnight-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        store = AppLimitEpochStore(
            fileURL: directoryURL.appendingPathComponent("store.json"),
            lock: RolloverLock(),
            ownerProvider: { [owner] in owner },
            legacyDefaults: nil
        )
        provenanceStore = AppLimitProvenanceStore(
            store: store,
            armIDProvider: { [armID] in armID }
        )
        try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.slots[rule.id] = AppLimitVersionSlot(
                ruleID: rule.id,
                latestOrderingToken: 7,
                latestKind: .set,
                latestPayloadDigest: "facebook-rule",
                activeRule: rule,
                clearTombstone: nil,
                pendingOwnerWork: nil,
                appliedReceipt: nil,
                armProvenance: nil,
                authoritativeUsedTodayMinutes: 0
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class RolloverLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
