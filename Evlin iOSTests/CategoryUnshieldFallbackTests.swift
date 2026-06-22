import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

/// Regression test for the "unlock Social no-op" bug.
///
/// The kid can receive an `unshield` command with `tier: .category` that carries
/// ONLY a lowercase `category_hint` ("social"), no resolved category token, and
/// no `target_display`. The token-keyed removal (`removeShield(recordKey:
/// "category:social")`) misses the active `.category` shield when that shield was
/// stored under a different `targetKey` (e.g. its catalog alias was wiped). Before
/// the fix the shield stayed (parent's "unlock" silently did nothing) and the ack
/// fell back to `display_name: "App"`.
///
/// The fix: when the token-keyed removal removes nothing, fall back to removing the
/// active `.category`-tier shield whose `displayName` matches the command hint
/// case-insensitively, and ack with that shield's real `displayName` ("Social").
final class CategoryUnshieldFallbackTests: XCTestCase {
    override func setUp() async throws {
        await clearActiveLockState()
    }

    override func tearDown() async throws {
        await clearActiveLockState()
    }

    /// Active `.category` shield "Social" stored under an alias-derived targetKey
    /// that does NOT equal the command's lowercase hint, so the recordKey-keyed
    /// removal misses. A bad unshield-category command (hint "social", no token,
    /// no display) must still remove that shield and ack displayName "Social".
    func testUnshieldCategoryWithoutTokenFallsBackToDisplayNameMatch() async throws {
        // Seed an active `.category` shield whose displayName is "Social" but whose
        // recordKey/targetKey is NOT "category:social" — emulates the catalog alias
        // being wiped so the command-built recordKey can't match it.
        let active = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .category, targetKey: "social-wiped-alias"),
            tier: .category,
            targetKey: "social-wiped-alias",
            displayName: "Social",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3_600),
            originalRequest: "lock Social",
            targetChildID: UUID()
        )
        _ = await ActiveLockStore.shared.addShield(active)

        // Sanity: the token-keyed recordKey the command will build ("category:social")
        // does NOT match the stored shield — so without the fallback this is a no-op.
        let missingByRecordKey = await ActiveLockStore.shared.allCurrent().shields
            .contains { $0.recordKey == ShieldRecord.makeRecordKey(tier: .category, targetKey: "social") }
        XCTAssertFalse(missingByRecordKey, "Precondition: stored shield must not match the command recordKey")

        let executor = ActionExecutor(
            activityScheduler: NoopScheduler(),
            authorizationStatusProvider: { .approved }
        )

        // BAD command shape: only a lowercase `category_hint`, no token, no display.
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .category,
            target: CommandTarget(
                categoryHint: "social",
                originalRequest: "unlock Social",
                targetChildID: UUID()
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let result = await executor.execute(command)

        // The shield must be gone.
        let remaining = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertTrue(
            remaining.isEmpty,
            "Fallback should have removed the active category shield; remaining: \(remaining.map(\.recordKey))"
        )

        // The ack must report the matched shield's displayName ("Social"), NOT "App".
        guard case let .confirmedExact(verb, displayName, _) = result else {
            return XCTFail("Expected .confirmedExact, got \(result)")
        }
        XCTAssertEqual(verb, .unshield)
        XCTAssertEqual(displayName, "Social")
    }

    private func clearActiveLockState() async {
        _ = await ActiveLockStore.shared.unblockAll()
        _ = await ActiveLockStore.shared.unshieldAll()
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.removeObject(forKey: "evlin.blockRecords")
        defaults?.removeObject(forKey: "evlin.shieldRecords")
    }
}

/// Minimal scheduler stub — the fallback path only touches `stopMonitoring`,
/// which is a no-op here.
private final class NoopScheduler: DeviceActivityScheduling {
    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {}
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {}
    func stopMonitoring(_ activities: [DeviceActivityName]) {}
    func stopMonitoring() {}
    func monitoredActivities() -> [DeviceActivityName] { [] }
}
