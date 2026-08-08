import Foundation
import XCTest
@testable import Evlin_iOS

/// Raising a per-app budget mid-day mints a fresh arm identity (new ordering
/// token). The minutes the child already spent today must survive that mint,
/// otherwise the new ladder is cut over the full budget and the child silently
/// receives a whole second allowance.
///
/// Production evidence (2026-08-08, device 8c62dd0c): parent raised WhatsApp
/// 15m -> 20m. The backend delivered `budget=20, used_today_minutes=15` and the
/// device acked in 2s, but the device then emitted a `t10` measurement sample —
/// a rung that can only exist on a ladder cut over 20 minutes, not over the
/// correct remaining 5. Net effect: 35 minutes of screen time.
final class AppLimitBudgetRaiseTests: XCTestCase {
    func testRaisingBudgetMidDayCarriesAuthoritativeUsedTodayIntoNewArm() throws {
        let fixture = try BudgetRaiseFixture()

        // Child spends the original 15-minute budget down; the backend reports
        // 15 minutes used today alongside the raised 20-minute rule.
        try fixture.applyRuleChange(
            budgetMinutes: 20,
            orderingToken: 4,
            authoritativeUsedTodayMinutes: 15,
            armedOnUsageDate: fixture.dayOneStart
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 20),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneStart.addingTimeInterval(15 * 60)
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

    func testStaleAuthoritativeUsedTodayDoesNotLeakAcrossMidnight() throws {
        let fixture = try BudgetRaiseFixture()

        // Yesterday's arm, and yesterday's used-today value still on the slot
        // because no rollover has refreshed it yet.
        try fixture.applyRuleChange(
            budgetMinutes: 20,
            orderingToken: 4,
            authoritativeUsedTodayMinutes: 15,
            armedOnUsageDate: fixture.dayOneStart
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

    func testReducedSchedulingViewStillDerivesItsOwnBase() throws {
        let fixture = try BudgetRaiseFixture()
        try fixture.applyRuleChange(
            budgetMinutes: 60,
            orderingToken: 4,
            authoritativeUsedTodayMinutes: 0,
            armedOnUsageDate: nil
        )

        let provenance = try fixture.provenanceStore.resolve(
            rule: fixture.rule(budgetMinutes: 45),
            ownerChildDeviceID: fixture.owner,
            now: fixture.dayOneStart
        ).provenance

        XCTAssertEqual(provenance.baseAcceptedMinutes, 15)
    }
}

private final class BudgetRaiseFixture {
    let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let armID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    let dayOneStart = ISO8601DateFormatter().date(from: "2026-07-25T04:00:00Z")!
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

    /// Installs the post-change slot: the raised rule at a new ordering token,
    /// the backend's used-today, and — when `armedOnUsageDate` is non-nil — the
    /// prior arm left behind by the superseded rule revision.
    func applyRuleChange(
        budgetMinutes: Int,
        orderingToken: Int64,
        authoritativeUsedTodayMinutes: Int,
        armedOnUsageDate: Date?
    ) throws {
        let canonical = rule(budgetMinutes: budgetMinutes)
        let priorArm = armedOnUsageDate.map { armedAt in
            AppLimitArmProvenance(
                ruleID: ruleID,
                ruleRevision: orderingToken - 1,
                childDeviceID: owner,
                usageDate: "2026-07-25",
                timezone: "America/New_York",
                scheduleWindow: canonical.window,
                tokenDigest: "superseded",
                budgetMinutes: 15,
                startedAt: armedAt,
                baseAcceptedMinutes: 0,
                lastRawThresholdMinutes: 0,
                ignoredWhilePausedMinutes: 0,
                activityName: "evlin.limit.v2.\(UUID().uuidString.lowercased())",
                armID: UUID()
            )
        }
        try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.slots[ruleID] = AppLimitVersionSlot(
                ruleID: ruleID,
                latestOrderingToken: orderingToken,
                latestKind: .set,
                latestPayloadDigest: "whatsapp-\(budgetMinutes)",
                activeRule: canonical,
                clearTombstone: nil,
                pendingOwnerWork: nil,
                appliedReceipt: nil,
                armProvenance: priorArm,
                authoritativeUsedTodayMinutes: authoritativeUsedTodayMinutes
            )
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
