/// B11 — Pure, stateless formatters for coarse earned-time displays.
///
/// All functions are static (no instance state) so they are trivially unit-
/// testable without mocks. Copy is intentionally honest:
///   - "about" / "approx" prefixes signal coarseness
///   - Values are rounded to 10-min steps so the UI never implies precision
///   - Per-app "used" is suppressed (no real per-app usage data in v1)
///
/// EarnedDisplayTests covers every public method here.
enum EarnedDisplayFormatters {

    // MARK: - Countdown label (parent + child surfaces)

    /// Returns a coarse "about N min left" label for the remaining earned-time.
    ///
    /// Rounds DOWN to the nearest 10-min step with a floor of 10 min so the
    /// copy is always at or below the true value (never over-promises).
    /// Returns the exhausted copy when `remainingMinutes` ≤ 0.
    static func coarseCountdownLabel(remainingMinutes: Int) -> String {
        guard remainingMinutes > 0 else { return exhaustedLabel() }
        let coarse = max(10, (remainingMinutes / 10) * 10)
        return "about \(coarse) min left"
    }

    // MARK: - Exhausted copy

    /// Canonical "time is up" string used whenever remaining ≤ 0.
    static func exhaustedLabel() -> String {
        "Time's up for today"
    }

    // MARK: - Per-device estimate label (parent Enrolled Devices row)

    /// Returns a coarse label for how much time is estimated left on one device.
    ///
    /// Uses the same 10-min coarse rounding as `coarseCountdownLabel`.
    /// When the estimate is ≤ 0 (device cap reached) returns the device-
    /// specific exhausted copy so parents can see which device is out.
    static func deviceEstimateLabel(estimatedMinutesLeft: Int) -> String {
        guard estimatedMinutesLeft > 0 else { return "time's up on this device" }
        let coarse = max(10, (estimatedMinutesLeft / 10) * 10)
        return "about \(coarse) min left on this device"
    }

    // MARK: - Freshness label

    /// Returns a human-friendly "updated ~Xm ago" string for the summary timestamp.
    ///
    /// Thresholds (honest, coarse):
    ///   <  90 s → "updated just now"
    ///   < 3600 s → "updated ~Nm ago"  (whole minutes)
    ///   ≥ 3600 s → "updated ~Nh ago"  (whole hours)
    static func freshnessLabel(secondsAgo: Int) -> String {
        guard secondsAgo >= 90 else { return "updated just now" }
        if secondsAgo < 3_600 {
            let mins = secondsAgo / 60
            return "updated ~\(mins)m ago"
        }
        let hours = secondsAgo / 3_600
        return "updated ~\(hours)h ago"
    }

    // MARK: - Precision badge

    /// Short badge shown next to the countdown label to communicate coarseness.
    static func precisionBadge() -> String {
        "~10 min steps"
    }

    // MARK: - Per-app row status (v1: hide usage)

    /// Status text for a per-app row in DeviceAppsSheet.
    ///
    /// v1 has NO real per-app usage data; `usedMin` is a mock value and must
    /// never be surfaced as real usage. This function intentionally ignores
    /// `usedMin` and returns only whether the limit is active or not.
    static func appRowStatusText(limitEnabled: Bool, usedMin: Int, limitMin: Int) -> String {
        guard limitEnabled else { return "Limit off" }
        // v1: do not show usage numbers — there is no real per-app usage yet.
        return "Limit on"
    }
}
