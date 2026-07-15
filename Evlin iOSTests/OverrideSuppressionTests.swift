import XCTest
import FamilyControls
@testable import Evlin_iOS

/// Override end-to-end: child command persistence + extension suppression.
///
/// Covers the three acceptance criteria:
///   1. Extension suppression: `shouldApplyEarnedShield` returns false when the
///      override flag is set for today's usage_date.
///   2. Enforcement resumes: `shouldApplyEarnedShield` returns true when the flag
///      is absent or set for a DIFFERENT date.
///   3. Child command execution validates backend metadata and persists the marker
///      before removing the earned-time source.
///
/// Key constraint verified by these tests: the writer (child command executor/NSE)
/// and the reader (extension via EarnedSampleReporter.shouldApplyEarnedShield, which
/// calls EarnedTimeStore.isOverridden(forUsageDate:)) use the IDENTICAL App Group key
/// `earned.overridden.<usageDate>` and the backend canonical date format ("yyyy-MM-dd").
/// Both read/write through EarnedTimeStore — so the key format is automatically
/// identical by construction. These tests confirm the round-trip in a single process.
final class OverrideSuppressionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EarnedTimeStore.shared.removeAll()
    }

    override func tearDown() {
        EarnedTimeStore.shared.removeAll()
        super.tearDown()
    }

    // MARK: - 1. Extension suppression when override flag is set for today

    /// With the override flag written for today's date, `shouldApplyEarnedShield`
    /// must return false — the extension must NOT re-apply the earned-time shield.
    func test_shouldApplyEarnedShield_returnsFalse_whenOverrideFlagSetForToday() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()

        // Write the flag that the ProfileView exhausted-unlock path writes (B10).
        store.setOverride(true, forUsageDate: today)

        // thresholdN >= effectiveCap normally triggers shielding — but override blocks it.
        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 30,    // usage far exceeded cap
            usageDate: today,
            store: store
        )

        XCTAssertFalse(result,
            "Extension must NOT apply .earnedTime shield when override flag is set for today.")
    }

    /// Override flag for today must suppress shielding even at the threshold boundary.
    func test_shouldApplyEarnedShield_returnsFalse_whenOverrideFlagSetAtExactCap() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()
        store.setOverride(true, forUsageDate: today)

        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 60,   // exactly at the tripwire
            usageDate: today,
            store: store
        )

        XCTAssertFalse(result, "Override flag must block shielding even at the exact cap threshold.")
    }

    // MARK: - 2. Enforcement resumes when flag is absent or for a different date

    /// When no override flag is set, `shouldApplyEarnedShield` returns true
    /// (enforcement applies) when usage has hit or exceeded the cap.
    func test_shouldApplyEarnedShield_returnsTrue_whenNoFlagSet() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()
        // Confirm no flag set (removeAll in setUp covers this).
        XCTAssertFalse(store.isOverridden(forUsageDate: today))

        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 30,
            usageDate: today,
            store: store
        )

        XCTAssertTrue(result, "Extension MUST apply .earnedTime shield when override flag is absent.")
    }

    /// Flag set for YESTERDAY does not suppress today's enforcement.
    func test_shouldApplyEarnedShield_returnsTrue_whenFlagSetForDifferentDate() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()
        let yesterday = isoDateYesterday()

        // Write flag for a different date (yesterday).
        store.setOverride(true, forUsageDate: yesterday)

        // Flag for today must be absent.
        XCTAssertFalse(store.isOverridden(forUsageDate: today),
            "Flag for yesterday must not affect today's override check.")

        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 30,
            usageDate: today,
            store: store
        )

        XCTAssertTrue(result,
            "Extension must apply .earnedTime shield when the override flag is for a different date.")
    }

    /// Flag set for a future date also does not suppress today's enforcement.
    func test_shouldApplyEarnedShield_returnsTrue_whenFlagSetForFutureDate() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()
        let tomorrow = isoDateTomorrow()

        store.setOverride(true, forUsageDate: tomorrow)

        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 30,
            usageDate: today,
            store: store
        )

        XCTAssertTrue(result, "Override flag for a future date must not suppress today's enforcement.")
    }

    /// Below-cap usage never triggers shielding regardless of override (B5 basic path).
    func test_shouldApplyEarnedShield_returnsFalse_whenBelowCapAndNoFlag() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()

        let result = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 20,
            effectiveCap: 60,   // usage well below cap
            usageDate: today,
            store: store
        )

        XCTAssertFalse(result, "No shielding when usage is below the effective cap.")
    }

    // MARK: - 3. Child command validation and mutation ordering

    func test_currentCanonicalPolicyUsageDate_requiresRuntimeTimezone() {
        let store = EarnedTimeStore(
            suiteName: "test.override.no-runtime-tz.\(UUID().uuidString)",
            useInProcessLock: true
        )

        XCTAssertNil(store.currentCanonicalPolicyUsageDate(
            now: Date(timeIntervalSince1970: 1_768_436_400)
        ))
        store.removeAll()
    }

    func test_currentCanonicalPolicyUsageDate_ignoresDeviceTimezone() {
        let store = EarnedTimeStore(
            suiteName: "test.override.canonical-tz.\(UUID().uuidString)",
            useInProcessLock: true
        )
        let instant = ISO8601DateFormatter().date(
            from: "2026-07-16T02:00:00Z"
        )!
        XCTAssertEqual(
            store.reconcileRuntimePolicy(
                usageDate: "2026-07-15",
                timezoneIdentifier: "America/New_York",
                poolMinutes: 120,
                capMinutes: 120,
                remainingMinutes: 120,
                estimatedMinutes: 0,
                syncedAt: instant
            ),
            .reconciled(0)
        )

        XCTAssertEqual(
            store.currentCanonicalPolicyUsageDate(now: instant),
            "2026-07-15"
        )
        XCTAssertEqual(
            EarnedTimeStore.appLimitUsageDate(
                now: instant,
                timeZone: TimeZone(identifier: "Asia/Tokyo")!
            ),
            "2026-07-16"
        )
        store.removeAll()
    }

    @MainActor
    func test_foregroundOverrideCommand_persistsFlagBeforeEarnedSourceRemoval() async throws {
        let suite = "test.override.foreground.\(UUID().uuidString)"
        let earnedStore = EarnedTimeStore(
            suiteName: suite,
            useInProcessLock: true
        )
        earnedStore.removeAll()
        _ = await ActiveLockStore.shared.unshieldAll()

        let listID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let record = makeEarnedRecord(listID: listID)
        _ = await ActiveLockStore.shared.addShield(record)
        var overrideWasSetAtRemoval = false
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            earnedTimeStore: earnedStore,
            overrideUsageDateProvider: { "2026-07-15" },
            afterMutationCheckpoint: { checkpoint in
                if checkpoint == .unshieldRemoved {
                    overrideWasSetAtRemoval = earnedStore.isOverridden(
                        forUsageDate: "2026-07-15"
                    )
                }
            }
        )
        let result = await executor.execute(
            makeEarnedOverrideCommand(
                listID: listID,
                usageDate: "2026-07-15"
            ),
            expectedChildID: overrideDeviceID,
            identityIsCurrent: { $0 == overrideDeviceID }
        )

        guard case .confirmedExact(let verb, _, _) = result else {
            return XCTFail("Expected an exact unshield confirmation, got \(result)")
        }
        XCTAssertEqual(verb, .unshield)
        XCTAssertTrue(overrideWasSetAtRemoval)
        XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        XCTAssertFalse(EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 120,
            effectiveCap: 60,
            usageDate: "2026-07-15",
            store: earnedStore
        ))
        _ = await ActiveLockStore.shared.unshieldAll()
        earnedStore.removeAll()
    }

    @MainActor
    func test_foregroundMarkerOnlyOverride_persistsAndConfirmsWithoutListID() async {
        let earnedStore = EarnedTimeStore(
            suiteName: "test.override.marker.\(UUID().uuidString)",
            useInProcessLock: true
        )
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            earnedTimeStore: earnedStore,
            overrideUsageDateProvider: { "2026-07-15" }
        )
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: nil,
                originalRequest: "override today's screen time",
                targetDisplay: "Screen time override",
                targetChildID: overrideDeviceID,
                unlockSources: ["earned_time"],
                earnedOverrideUsageDate: "2026-07-15"
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let result = await executor.execute(
            command,
            expectedChildID: overrideDeviceID,
            identityIsCurrent: { $0 == overrideDeviceID }
        )

        guard case .confirmedExact(let verb, _, _) = result else {
            return XCTFail("Expected marker-only override confirmation, got \(result)")
        }
        XCTAssertEqual(verb, .unshield)
        XCTAssertTrue(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        earnedStore.removeAll()
    }

    @MainActor
    func test_foregroundPriorDayOverride_failsBeforeMarkerOrUnshield() async {
        let earnedStore = EarnedTimeStore(
            suiteName: "test.override.stale-day.\(UUID().uuidString)",
            useInProcessLock: true
        )
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            earnedTimeStore: earnedStore,
            overrideUsageDateProvider: { "2026-07-15" }
        )

        let result = await executor.execute(
            makeEarnedOverrideCommand(
                listID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                usageDate: "2026-07-14"
            ),
            expectedChildID: overrideDeviceID,
            identityIsCurrent: { $0 == overrideDeviceID }
        )

        guard case .failed(.malformed) = result else {
            return XCTFail("Expected stale override metadata to fail closed")
        }
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-14"))
        earnedStore.removeAll()
    }

    @MainActor
    func test_foregroundMissingCanonicalTimezone_failsBeforeOverrideMarker() async {
        let earnedStore = EarnedTimeStore(
            suiteName: "test.override.missing-tz.\(UUID().uuidString)",
            useInProcessLock: true
        )
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            earnedTimeStore: earnedStore
        )

        let result = await executor.execute(
            makeEarnedOverrideCommand(
                listID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                usageDate: "2026-07-15"
            ),
            expectedChildID: overrideDeviceID,
            identityIsCurrent: { $0 == overrideDeviceID }
        )

        guard case .failed(.malformed) = result else {
            return XCTFail("Expected missing canonical timezone to fail closed")
        }
        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        earnedStore.removeAll()
    }

    @MainActor
    func test_foregroundIdentitySwitch_failsBeforeOverrideMarker() async {
        let earnedStore = EarnedTimeStore(
            suiteName: "test.override.stale-identity.\(UUID().uuidString)",
            useInProcessLock: true
        )
        let executor = ActionExecutor(
            authorizationStatusProvider: { .approved },
            earnedTimeStore: earnedStore,
            overrideUsageDateProvider: { "2026-07-15" }
        )

        _ = await executor.execute(
            makeEarnedOverrideCommand(
                listID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                usageDate: "2026-07-15"
            ),
            expectedChildID: overrideDeviceID,
            identityIsCurrent: { _ in false }
        )

        XCTAssertFalse(earnedStore.isOverridden(forUsageDate: "2026-07-15"))
        earnedStore.removeAll()
    }

    /// Confirms that the flag uses the same key format that shouldApplyEarnedShield reads:
    /// "earned.overridden.<yyyy-MM-dd>" in the "group.com.evlin.ios" suite.
    /// The key format is tested by reading UserDefaults directly, matching what the
    /// extension's EarnedTimeStore.isOverridden(forUsageDate:) would look up.
    func test_flagKey_matchesExtensionReaderFormat() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()

        store.setOverride(true, forUsageDate: today)

        // Read the raw UserDefaults value using the exact key the extension uses.
        // This proves the writer (app) and reader (extension) use the identical key.
        let suite = UserDefaults(suiteName: "group.com.evlin.ios")
        let rawKey = "earned.overridden.\(today)"
        let rawValue = suite?.bool(forKey: rawKey)

        XCTAssertEqual(rawValue, true,
            "The App Group key 'earned.overridden.<usageDate>' must be set to true after setOverride.")

        // Also confirm EarnedTimeStore.isOverridden reads the same key.
        XCTAssertTrue(store.isOverridden(forUsageDate: today),
            "EarnedTimeStore.isOverridden must return true for the same key that was written.")
    }

    /// Clearing the override flag removes it from the App Group — enforcement resumes.
    func test_clearOverrideFlag_removesEntry_andEnforcementResumes() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()

        store.setOverride(true, forUsageDate: today)
        XCTAssertTrue(store.isOverridden(forUsageDate: today))

        store.setOverride(false, forUsageDate: today)
        XCTAssertFalse(store.isOverridden(forUsageDate: today),
            "Clearing the override flag must make the extension re-apply enforcement.")

        let extensionWouldShield = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 60,
            effectiveCap: 30,
            usageDate: today,
            store: store
        )
        XCTAssertTrue(extensionWouldShield,
            "After clearing the override flag, the extension must apply .earnedTime shield again.")
    }

    private func makeEarnedRecord(listID: UUID) -> ShieldRecord {
        ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(
                tier: .savedList,
                targetKey: listID.uuidString
            ),
            tier: .savedList,
            targetKey: listID.uuidString,
            displayName: "Locked set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "automatic earned lock",
            targetChildID: overrideDeviceID,
            sources: [.earnedTime]
        )
    }

    private func makeEarnedOverrideCommand(
        listID: UUID,
        usageDate: String
    ) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "override today's screen time",
                targetDisplay: "Locked set",
                targetChildID: overrideDeviceID,
                unlockSources: ["earned_time"],
                earnedOverrideUsageDate: usageDate
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )
    }

    // MARK: - Helpers

    /// ISO-8601 date string for today in the device's local timezone.
    /// Matches the format used by ProfileView.todayUsageDate() and
    /// DeviceActivityMonitorExtension.todayISODate() — "yyyy-MM-dd".
    private func isoDateToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }

    private func isoDateYesterday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date().addingTimeInterval(-86400))
    }

    private func isoDateTomorrow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date().addingTimeInterval(86400))
    }
}

private let overrideDeviceID =
    UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
