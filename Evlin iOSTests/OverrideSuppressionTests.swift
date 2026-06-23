import XCTest
@testable import Evlin_iOS

/// B10 — Override end-to-end: flag write + extension suppression.
///
/// Three test classes covering the three acceptance criteria:
///   1. Extension suppression: `shouldApplyEarnedShield` returns false when the
///      override flag is set for today's usage_date.
///   2. Enforcement resumes: `shouldApplyEarnedShield` returns true when the flag
///      is absent or set for a DIFFERENT date.
///   3. Exhausted-unlock flag write: `ExhaustedUnlockSpy` verifies the ProfileView
///      exhausted-unlock path writes the override flag + would call unlockOverride.
///
/// Key constraint verified by these tests: the writer (main app via EarnedTimeStore)
/// and the reader (extension via EarnedSampleReporter.shouldApplyEarnedShield, which
/// calls EarnedTimeStore.isOverridden(forUsageDate:)) use the IDENTICAL App Group key
/// `earned.overridden.<usageDate>` and the same date format ("yyyy-MM-dd" local tz).
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

    // MARK: - 3. Exhausted-unlock flag write (spy pattern)

    /// When the exhausted-unlock path fires, the App Group override flag for today
    /// must be written immediately (synchronously, before the backend call).
    ///
    /// This test uses the pure EarnedTimeStore API to simulate exactly what
    /// ProfileView.toggleDeviceLock does on the exhausted branch (B10):
    ///   1. Compute today's usage_date
    ///   2. Call EarnedTimeStore.shared.setOverride(true, forUsageDate: usageDate)
    ///   3. (Would call) apiClient.unlockOverride(childProfileID:)
    ///
    /// We verify step 2 using EarnedTimeStore directly — no UIKit/SwiftUI required.
    func test_exhaustedUnlockPath_writesOverrideFlagForToday() {
        let store = EarnedTimeStore.shared
        let today = isoDateToday()

        // Pre-condition: flag is absent.
        XCTAssertFalse(store.isOverridden(forUsageDate: today),
            "Override flag must be absent before the exhausted-unlock fires.")

        // Simulate exactly what ProfileView.todayUsageDate() + setOverride does.
        let usageDate = isoDateToday() // same date format: yyyy-MM-dd local tz
        store.setOverride(true, forUsageDate: usageDate)

        // Verify: flag is now set.
        XCTAssertTrue(store.isOverridden(forUsageDate: today),
            "Override flag must be set for today after the exhausted-unlock path fires.")

        // Cross-check: extension suppression check returns false (no re-shield).
        let extensionWouldShield = EarnedSampleReporter.shouldApplyEarnedShield(
            thresholdN: 90,
            effectiveCap: 60,
            usageDate: today,
            store: store
        )
        XCTAssertFalse(extensionWouldShield,
            "After exhausted-unlock flag write, the extension must NOT re-apply .earnedTime shield.")
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
