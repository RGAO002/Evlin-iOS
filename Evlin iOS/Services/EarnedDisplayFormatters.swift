/// B11 — Pure, stateless formatters for earned-time displays.
///
/// All functions are static (no instance state) so they are trivially unit-
/// testable without mocks. Copy is intentionally honest:
///   - Remaining pool values use the app's 5-minute cap granularity
///   - Per-app "used" is suppressed (no real per-app usage data in v1)
///
/// EarnedDisplayTests covers every public method here.
enum EarnedDisplayFormatters {

    // MARK: - Remaining-time tier (color bands)

    /// Three-tier band for a REMAINING-time bar. `fraction` = remaining / total
    /// (1.0 = full, 0 = empty): `> ⅔` green, `⅓ … ⅔` yellow, `≤ ⅓` red. Pure
    /// threshold logic — `Color.evTimeRemaining(_:)` maps the tier to a color.
    enum RemainingTier { case green, yellow, red }

    static func remainingTier(fraction: Double) -> RemainingTier {
        if fraction > 2.0 / 3.0 { return .green }
        if fraction > 1.0 / 3.0 { return .yellow }
        return .red
    }

    /// Fraction for remaining-time bars. This is intentionally remaining / pool,
    /// not used / pool, so the filled portion shrinks from right to left as time
    /// is spent.
    static func remainingFraction(remainingMinutes: Int?, dailyPoolMinutes: Int?) -> Double {
        guard let remainingMinutes else { return 1.0 }
        guard remainingMinutes > 0 else { return 0 }
        guard let dailyPoolMinutes,
              dailyPoolMinutes > 0
        else { return 1.0 }

        return min(1.0, max(0.0, Double(remainingMinutes) / Double(dailyPoolMinutes)))
    }

    // MARK: - Countdown label (parent + child surfaces)

    /// Returns a clean remaining-time label matching the backend countdown copy.
    /// Returns the exhausted copy when `remainingMinutes` ≤ 0.
    static func coarseCountdownLabel(remainingMinutes: Int) -> String {
        guard remainingMinutes > 0 else { return exhaustedLabel() }
        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60
        if hours == 0 {
            return "\(minutes)m left"
        }
        if minutes == 0 {
            return "\(hours)h left"
        }
        return "\(hours)h \(minutes)m left"
    }

    // MARK: - Exhausted copy

    /// Canonical "time is up" string used whenever remaining ≤ 0.
    static func exhaustedLabel() -> String {
        "Time's up for today"
    }

    // MARK: - Per-device estimate label (parent Enrolled Devices row)

    /// Returns the 5-minute granularity label for how much time is estimated
    /// left on one device.
    ///
    /// When the estimate is ≤ 0 (device cap reached) returns the device-
    /// specific exhausted copy so parents can see which device is out.
    static func deviceEstimateLabel(estimatedMinutesLeft: Int) -> String {
        guard estimatedMinutesLeft > 0 else { return "time's up on this device" }
        return "\(estimatedMinutesLeft) mins left"
    }

    private static func effectiveDeviceRemainingMinutes(
        remainingToCapMinutes: Int,
        overallRemainingMinutes: Int?
    ) -> Int {
        guard let overallRemainingMinutes else { return remainingToCapMinutes }
        return min(remainingToCapMinutes, overallRemainingMinutes)
    }

    /// Device row copy must never claim device time remains after the shared
    /// pool is empty. Per-device estimates can lag the aggregate summary, so
    /// overall remaining time wins when it is exhausted.
    static func deviceRemainingLabel(
        remainingToCapMinutes: Int?,
        overallRemainingMinutes: Int?,
        fallbackOverallLabel: String
    ) -> String {
        if let overallRemainingMinutes, overallRemainingMinutes <= 0 {
            return fallbackOverallLabel
        }
        if let remainingToCapMinutes {
            return deviceEstimateLabel(
                estimatedMinutesLeft: effectiveDeviceRemainingMinutes(
                    remainingToCapMinutes: remainingToCapMinutes,
                    overallRemainingMinutes: overallRemainingMinutes
                )
            )
        }
        return fallbackOverallLabel
    }

    /// Device row progress uses the same remaining-time direction as the shared
    /// pool. If both per-device and overall values exist, use the smaller
    /// remaining-minute value with the device-row denominator.
    static func deviceRemainingFraction(
        remainingToCapMinutes: Int?,
        capMinutes: Int?,
        overallRemainingMinutes: Int?,
        dailyPoolMinutes: Int?
    ) -> Double {
        if let overallRemainingMinutes, overallRemainingMinutes <= 0 {
            return 0
        }

        guard let remainingToCapMinutes else {
            return remainingFraction(
                remainingMinutes: overallRemainingMinutes,
                dailyPoolMinutes: dailyPoolMinutes
            )
        }

        let deviceDenominator = capMinutes ?? dailyPoolMinutes
        let effectiveRemainingMinutes = effectiveDeviceRemainingMinutes(
            remainingToCapMinutes: remainingToCapMinutes,
            overallRemainingMinutes: overallRemainingMinutes
        )
        return remainingFraction(
            remainingMinutes: effectiveRemainingMinutes,
            dailyPoolMinutes: deviceDenominator
        )
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

    // MARK: - Per-app row status (v1: hide usage)

    /// Status text for a per-app row in DeviceAppsSheet.
    ///
    /// v1 has NO real per-app usage data; `usedMin` is a mock value and must
    /// never be surfaced as real usage. This function intentionally ignores
    /// `usedMin` and returns only whether the limit is active or not.
    static func appRowStatusText(limitEnabled: Bool, usedMin: Int, limitMin: Int) -> String {
        guard limitEnabled else { return "Limit off" }
        // Real (coarse) per-app usage now flows in via the measurement samples.
        // Show the figure clamped to the limit ("60 / 60 min" at/over budget,
        // never "65 / 60"). The row's separate right-aligned "LIMIT REACHED" badge
        // conveys the reached state, so this text must NOT also say it.
        return "\(min(usedMin, limitMin)) / \(limitMin) min"
    }
}
