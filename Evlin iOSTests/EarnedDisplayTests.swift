import XCTest
@testable import Evlin_iOS

/// B11 — Pure-logic tests for EarnedDisplayFormatters.
///
/// All functions under test are free functions / static methods — no network,
/// no SwiftUI, no DeviceActivity types, no ManagedSettingsStore.
///
/// Covered:
///   1. Countdown label formatting (5-minute pool granularity)
///   2. Freshness phrasing ("updated ~Xm ago", thresholds for hours/just now)
///   3. Exhausted copy ("Time's up for today")
///   4. Per-device estimate label (5-minute cap granularity copy)
///   5. Per-app "used" is hidden in v1 (statusText returns only limit-off / nothing about usage)
final class EarnedDisplayTests: XCTestCase {

    // MARK: - 1. Coarse countdown label

    func test_coarseCountdown_showsActualMinutesUnderAnHour() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 45), "45m left")
    }

    func test_coarseCountdown_exactHour() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 60), "1h left")
    }

    func test_coarseCountdown_hourAndMinutes() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 65), "1h 5m left")
    }

    func test_coarseCountdown_zero_isExhausted() {
        // 0 min → exhausted copy
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 0), "Time's up for today")
    }

    func test_coarseCountdown_negative_isExhausted() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: -5), "Time's up for today")
    }

    func test_coarseCountdown_largeValue_formatsHoursAndMinutes() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 147), "2h 27m left")
    }

    // MARK: - 2. Freshness phrasing

    func test_freshness_justNow() {
        // 0 seconds ago
        XCTAssertEqual(EarnedDisplayFormatters.freshnessLabel(secondsAgo: 0), "updated just now")
    }

    func test_freshness_lessThan90Seconds_isJustNow() {
        XCTAssertEqual(EarnedDisplayFormatters.freshnessLabel(secondsAgo: 59), "updated just now")
    }

    func test_freshness_3minutesAgo() {
        // 3*60 = 180 seconds
        XCTAssertEqual(EarnedDisplayFormatters.freshnessLabel(secondsAgo: 180), "updated ~3m ago")
    }

    func test_freshness_roundsToWholeMinutes() {
        // 190 seconds = 3.16 min → "~3m ago"
        XCTAssertEqual(EarnedDisplayFormatters.freshnessLabel(secondsAgo: 190), "updated ~3m ago")
    }

    func test_freshness_60minutesAgo_usesHours() {
        // 3600 seconds = 60 min → "~1h ago"
        XCTAssertEqual(EarnedDisplayFormatters.freshnessLabel(secondsAgo: 3600), "updated ~1h ago")
    }

    func test_freshness_90minutesAgo_usesHours() {
        // 5400 seconds = 90 min → "~1h ago" (1.5 h rounds to 1)
        XCTAssertEqual(EarnedDisplayFormatters.freshnessLabel(secondsAgo: 5400), "updated ~1h ago")
    }

    // MARK: - 3. Exhausted copy

    func test_exhaustedLabel() {
        XCTAssertEqual(EarnedDisplayFormatters.exhaustedLabel(), "Time's up for today")
    }

    // MARK: - 4. Per-device estimate label

    func test_deviceEstimate_showsActualRemainingMinutes() {
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: 45), "45 mins left")
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: 65), "65 mins left")
    }

    func test_deviceEstimate_atCap_showsTimesUp() {
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: 0), "time's up on this device")
    }

    func test_deviceEstimate_atCap_negative_showsTimesUp() {
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: -1), "time's up on this device")
    }

    func test_deviceRemaining_overallPoolEmptyOverridesStaleDeviceEstimate() {
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingLabel(
                remainingToCapMinutes: 60,
                overallRemainingMinutes: 0,
                fallbackOverallLabel: "Time's up for today"
            ),
            "Time's up for today"
        )
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingFraction(
                remainingToCapMinutes: 60,
                capMinutes: 65,
                overallRemainingMinutes: 0,
                dailyPoolMinutes: 65
            ),
            0,
            accuracy: 0.001
        )
    }

    func test_deviceRemainingLabel_clampsPositiveDeviceCapToSharedPool() {
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingLabel(
                remainingToCapMinutes: 120,
                overallRemainingMinutes: 35,
                fallbackOverallLabel: "35m left"
            ),
            "35 mins left"
        )
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingFraction(
                remainingToCapMinutes: 120,
                capMinutes: 120,
                overallRemainingMinutes: 35,
                dailyPoolMinutes: 120
            ),
            35.0 / 120.0,
            accuracy: 0.001
        )
    }

    func test_deviceRemaining_usesEffectiveMinutesWithAsymmetricDenominators() {
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingLabel(
                remainingToCapMinutes: 35,
                overallRemainingMinutes: 50,
                fallbackOverallLabel: "50m left"
            ),
            "35 mins left"
        )
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingFraction(
                remainingToCapMinutes: 35,
                capMinutes: 60,
                overallRemainingMinutes: 50,
                dailyPoolMinutes: 120
            ),
            35.0 / 60.0,
            accuracy: 0.001
        )
    }

    func test_deviceRemaining_missingDeviceUsesOverallFallback() {
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingLabel(
                remainingToCapMinutes: nil,
                overallRemainingMinutes: 50,
                fallbackOverallLabel: "50m left"
            ),
            "50m left"
        )
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingFraction(
                remainingToCapMinutes: nil,
                capMinutes: 60,
                overallRemainingMinutes: 50,
                dailyPoolMinutes: 120
            ),
            50.0 / 120.0,
            accuracy: 0.001
        )
    }

    func test_deviceRemaining_negativeOverallIsExhausted() {
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingLabel(
                remainingToCapMinutes: 35,
                overallRemainingMinutes: -5,
                fallbackOverallLabel: "Time's up for today"
            ),
            "Time's up for today"
        )
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingFraction(
                remainingToCapMinutes: 35,
                capMinutes: 60,
                overallRemainingMinutes: -5,
                dailyPoolMinutes: 120
            ),
            0,
            accuracy: 0.001
        )
    }

    func test_deviceRemaining_usesRemainingToCapNotEstimatedUsedMinutes() {
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingLabel(
                remainingToCapMinutes: 10,
                overallRemainingMinutes: nil,
                fallbackOverallLabel: "50m left"
            ),
            "10 mins left"
        )
        XCTAssertEqual(
            EarnedDisplayFormatters.deviceRemainingFraction(
                remainingToCapMinutes: 10,
                capMinutes: 60,
                overallRemainingMinutes: nil,
                dailyPoolMinutes: nil
            ),
            1.0 / 6.0,
            accuracy: 0.001
        )
    }

    // MARK: - 5. Per-app "used" shows real (coarse) usage

    func test_perAppStatus_limitOff_returnsLimitOffOnly() {
        // Limit off → "Limit off", regardless of any usage value.
        let result = EarnedDisplayFormatters.appRowStatusText(limitEnabled: false, usedMin: 30, limitMin: 60)
        XCTAssertEqual(result, "Limit off")
    }

    func test_perAppStatus_limitOn_showsUsageFigure() {
        XCTAssertEqual(EarnedDisplayFormatters.appRowStatusText(limitEnabled: true, usedMin: 0, limitMin: 60), "0 / 60 min")
        XCTAssertEqual(EarnedDisplayFormatters.appRowStatusText(limitEnabled: true, usedMin: 45, limitMin: 60), "45 / 60 min")
    }

    func test_perAppStatus_atOrOverLimit_clampsToLimit() {
        // Clamped to the limit; the row's separate "LIMIT REACHED" badge conveys
        // the reached state (this text must not double-label it).
        XCTAssertEqual(EarnedDisplayFormatters.appRowStatusText(limitEnabled: true, usedMin: 60, limitMin: 60), "60 / 60 min")
        XCTAssertEqual(EarnedDisplayFormatters.appRowStatusText(limitEnabled: true, usedMin: 75, limitMin: 60), "60 / 60 min")
    }

    // MARK: - 6. Remaining-time fraction

    func test_remainingFraction_usesRemainingOverPool() {
        XCTAssertEqual(
            EarnedDisplayFormatters.remainingFraction(remainingMinutes: 30, dailyPoolMinutes: 120),
            0.25,
            accuracy: 0.001
        )
    }

    func test_remainingFraction_clampsToValidBarRange() {
        XCTAssertEqual(EarnedDisplayFormatters.remainingFraction(remainingMinutes: -5, dailyPoolMinutes: 120), 0)
        XCTAssertEqual(EarnedDisplayFormatters.remainingFraction(remainingMinutes: 140, dailyPoolMinutes: 120), 1)
        XCTAssertEqual(EarnedDisplayFormatters.remainingFraction(remainingMinutes: 30, dailyPoolMinutes: 0), 1)
        XCTAssertEqual(EarnedDisplayFormatters.remainingFraction(remainingMinutes: nil, dailyPoolMinutes: 120), 1)
    }

    func test_remainingFraction_exhaustedIsEmptyEvenWithoutPoolDenominator() {
        XCTAssertEqual(EarnedDisplayFormatters.remainingFraction(remainingMinutes: 0, dailyPoolMinutes: nil), 0)
        XCTAssertEqual(EarnedDisplayFormatters.remainingFraction(remainingMinutes: -5, dailyPoolMinutes: nil), 0)
    }

    func test_remainingTier_usesRemainingTimeThresholds() {
        XCTAssertEqual(EarnedDisplayFormatters.remainingTier(fraction: 0.9), .green)
        XCTAssertEqual(EarnedDisplayFormatters.remainingTier(fraction: 0.5), .yellow)
        XCTAssertEqual(EarnedDisplayFormatters.remainingTier(fraction: 0.2), .red)
    }

    // MARK: - 7. EarnedSummaryDTO decodes A3 "devices" key (B11 regression guard)

    /// Regression test: A3 summary response returns per-device entries under the
    /// JSON key "devices" (spec §5.2), NOT "device_estimates". The CodingKeys
    /// mapping on EarnedSummaryDTO must bridge the two so the array decodes.
    func test_earnedSummaryDTO_decodesDevicesKey() throws {
        let deviceID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        let json = """
        {
            "child_profile_id": "00000000-0000-0000-0000-000000000001",
            "state": "ok",
            "earned_minutes": 60,
            "used_minutes": 20,
            "remaining_minutes": 40,
            "devices": [
                {
                    "child_device_id": "\(deviceID)",
                    "estimated_minutes": 30,
                    "cap_minutes": 60,
                    "cap_state": "ok"
                }
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(APIClient.EarnedSummaryDTO.self, from: json)

        XCTAssertNotNil(dto.device_estimates, "device_estimates must be non-nil — A3 returns the array under 'devices' key")
        XCTAssertEqual(dto.device_estimates?.count, 1, "Expected 1 device estimate")
        let entry = try XCTUnwrap(dto.device_estimates?.first)
        XCTAssertEqual(entry.child_device_id?.uuidString.uppercased(), deviceID.uppercased())
        XCTAssertEqual(entry.estimated_minutes, 30)
    }
}
