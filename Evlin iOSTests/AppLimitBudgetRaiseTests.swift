import Foundation
import XCTest
@testable import Evlin_iOS

/// Raising a per-app budget mid-day rebuilds the slot from the command envelope
/// (`AppLimitCommandCoordinator.ingest` replaces it wholesale on a higher
/// ordering token), so the arm identity AND the arm provenance are both gone by
/// the time the new ladder is cut. The minutes the child already spent today
/// must survive that rebuild, otherwise the ladder is cut over the full budget
/// and the child silently receives a whole second allowance.
///
/// Production evidence (2026-08-08, device 8c62dd0c): parent raised WhatsApp
/// 15m -> 20m. The backend delivered `budget=20, used_today_minutes=15` and the
/// device acked in 2s, but the device then emitted a `t10` measurement sample —
/// a rung that can only exist on a ladder cut over 20 minutes, not over the
/// correct remaining 5. Net effect: 35 minutes of screen time.
///
/// Every slot here is built through `AppLimitVersionSlot(accepting:)` — the same
/// constructor production uses — precisely because a hand-assembled slot can
/// carry an `armProvenance` that a real rule change never leaves behind.
final class AppLimitBudgetRaiseTests: XCTestCase {
    func testRaisingBudgetMidDayCarriesAuthoritativeUsedTodayIntoNewArm() throws {
        let fixture = try BudgetRaiseFixture()

        // Child spent 15 of the original 15-minute budget; the parent raises the
        // rule to 20 and the backend reports the 15 already used.
        try fixture.ingestRuleChange(
            budgetMinutes: 20,
            orderingToken: 4,
            usedTodayMinutes: 15,
            receivedAt: fixture.dayOneNoon
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 20),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneNoon
        ).provenance

        XCTAssertEqual(provenance.budgetMinutes, 20)
        XCTAssertEqual(
            provenance.baseAcceptedMinutes,
            15,
            "the 15 minutes already spent today must seed the new arm's base"
        )
        XCTAssertEqual(
            provenance.budgetMinutes - provenance.baseAcceptedMinutes,
            5,
            "the ladder must be cut over the remaining 5 minutes, not the full 20"
        )
    }

    /// Fred's case: the budget was fully consumed before the parent raised it.
    func testRaisingAnExhaustedBudgetGrantsOnlyTheDifference() throws {
        let fixture = try BudgetRaiseFixture()

        try fixture.ingestRuleChange(
            budgetMinutes: 30,
            orderingToken: 4,
            usedTodayMinutes: 20,
            receivedAt: fixture.dayOneNoon
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 30),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneNoon
        ).provenance

        XCTAssertEqual(provenance.baseAcceptedMinutes, 20)
        XCTAssertEqual(
            provenance.budgetMinutes - provenance.baseAcceptedMinutes,
            10,
            "20 used against a new 30 budget leaves 10, not a fresh 30"
        )
    }

    func testStaleAuthoritativeUsedTodayDoesNotLeakAcrossMidnight() throws {
        let fixture = try BudgetRaiseFixture()

        // Measured yesterday; no rollover has refreshed the slot yet.
        try fixture.ingestRuleChange(
            budgetMinutes: 20,
            orderingToken: 4,
            usedTodayMinutes: 15,
            receivedAt: fixture.dayOneNoon
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 20),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayTwoStart
        ).provenance

        XCTAssertEqual(provenance.usageDate, "2026-07-26")
        XCTAssertEqual(
            provenance.baseAcceptedMinutes,
            0,
            "a new day starts from zero even if used-today has not been refreshed"
        )
    }

    func testMissingAuthoritativeUsedTodaySeedsNothing() throws {
        let fixture = try BudgetRaiseFixture()

        try fixture.ingestRuleChange(
            budgetMinutes: 20,
            orderingToken: 4,
            usedTodayMinutes: nil,
            receivedAt: fixture.dayOneNoon
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 20),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneNoon
        ).provenance

        XCTAssertEqual(provenance.baseAcceptedMinutes, 0)
    }

    func testReducedSchedulingViewStillDerivesItsOwnBase() throws {
        let fixture = try BudgetRaiseFixture()
        try fixture.ingestRuleChange(
            budgetMinutes: 60,
            orderingToken: 4,
            usedTodayMinutes: nil,
            receivedAt: fixture.dayOneNoon
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 45),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneNoon
        ).provenance

        XCTAssertEqual(provenance.baseAcceptedMinutes, 15)
    }
}

private final class BudgetRaiseFixture {
    let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let armID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    // 2026-07-25 08:00 America/New_York — mid-day, well clear of both boundaries.
    let dayOneNoon = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
    let dayTwoStart = ISO8601DateFormatter().date(from: "2026-07-26T04:00:00Z")!
    let store: AppLimitEpochStore
    let provenanceStore: AppLimitProvenanceStore
    private let directoryURL: URL

    func rule(budgetMinutes: Int) -> AppLimitRule {
        AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "net.whatsapp.WhatsApp",
            displayName: "WhatsApp",
            budgetMinutes: budgetMinutes,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
    }

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-limit-budget-raise-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        store = AppLimitEpochStore(
            fileURL: directoryURL.appendingPathComponent("store.json"),
            lock: BudgetRaiseLock(),
            ownerProvider: { [owner] in owner },
            legacyDefaults: nil
        )
        provenanceStore = AppLimitProvenanceStore(
            store: store,
            armIDProvider: { [armID] in armID }
        )
    }

    /// Installs the slot exactly the way a real rule change does: through
    /// `AppLimitVersionSlot(accepting:)`, which carries no arm provenance.
    func ingestRuleChange(
        budgetMinutes: Int,
        orderingToken: Int64,
        usedTodayMinutes: Int?,
        receivedAt: Date
    ) throws {
        let command = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: ruleID,
            orderingToken: orderingToken,
            kind: .set,
            payloadDigest: "whatsapp-\(budgetMinutes)",
            receivedAt: receivedAt,
            source: .notificationServiceExtension,
            rule: rule(budgetMinutes: budgetMinutes),
            authoritativeUsedTodayMinutes: usedTodayMinutes
        )
        let slot = AppLimitVersionSlot(accepting: command)
        XCTAssertNil(
            slot.armProvenance,
            "a rule change must not leave an arm provenance behind — the seeding "
                + "gate cannot depend on one"
        )
        try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.slots[ruleID] = slot
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class BudgetRaiseLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
