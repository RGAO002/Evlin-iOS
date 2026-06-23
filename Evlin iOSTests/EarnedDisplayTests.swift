import XCTest
@testable import Evlin_iOS

/// B11 — Pure-logic tests for EarnedDisplayFormatters.
///
/// All functions under test are free functions / static methods — no network,
/// no SwiftUI, no DeviceActivity types, no ManagedSettingsStore.
///
/// Covered:
///   1. Coarse countdown label rounding (10-min steps, "about N min left")
///   2. Freshness phrasing ("updated ~Xm ago", thresholds for hours/just now)
///   3. Exhausted copy ("Time's up for today")
///   4. Per-device estimate label (honest coarse copy)
///   5. Per-app "used" is hidden in v1 (statusText returns only limit-off / nothing about usage)
final class EarnedDisplayTests: XCTestCase {

    // MARK: - 1. Coarse countdown label

    func test_coarseCountdown_roundsTo10MinSteps() {
        // 83 min → rounds DOWN to 80
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 83), "about 80 min left")
    }

    func test_coarseCountdown_exactMultipleOf10() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 60), "about 60 min left")
    }

    func test_coarseCountdown_smallRemainder() {
        // 7 min → below first step → "about 10 min left" (floor clamps to 10)
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 7), "about 10 min left")
    }

    func test_coarseCountdown_zero_isExhausted() {
        // 0 min → exhausted copy
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 0), "Time's up for today")
    }

    func test_coarseCountdown_negative_isExhausted() {
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: -5), "Time's up for today")
    }

    func test_coarseCountdown_largeValue_roundsCorrectly() {
        // 147 min → 140
        XCTAssertEqual(EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: 147), "about 140 min left")
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

    func test_deviceEstimate_showsCoarseMinutes() {
        // 45 min remaining on device → "about 40 min left on this device"
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: 45), "about 40 min left on this device")
    }

    func test_deviceEstimate_atCap_showsTimesUp() {
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: 0), "time's up on this device")
    }

    func test_deviceEstimate_atCap_negative_showsTimesUp() {
        XCTAssertEqual(EarnedDisplayFormatters.deviceEstimateLabel(estimatedMinutesLeft: -1), "time's up on this device")
    }

    // MARK: - 5. v1: per-app "used" is hidden

    func test_perAppStatus_limitOff_returnsLimitOffOnly() {
        // When the limit is off, status is "Limit off" — no usage number
        let result = EarnedDisplayFormatters.appRowStatusText(limitEnabled: false, usedMin: 30, limitMin: 60)
        XCTAssertEqual(result, "Limit off")
        XCTAssertFalse(result.contains("used"), "v1: must not show usage data")
        XCTAssertFalse(result.contains("30"), "v1: usedMin must not appear")
    }

    func test_perAppStatus_limitOn_doesNotShowUsageNumbers() {
        // When limit is on but v1 has no real usage, status must NOT show "X used / X min used"
        let result = EarnedDisplayFormatters.appRowStatusText(limitEnabled: true, usedMin: 0, limitMin: 60)
        XCTAssertFalse(result.contains("used"), "v1: must not show per-app usage data")
        XCTAssertFalse(result.contains("0"), "v1: usedMin=0 must not appear as a number")
    }

    func test_perAppStatus_limitOn_nonZeroUsed_doesNotShowUsage() {
        // Even if the mock usedMin is non-zero, v1 must not display it
        let result = EarnedDisplayFormatters.appRowStatusText(limitEnabled: true, usedMin: 45, limitMin: 60)
        XCTAssertFalse(result.contains("used"), "v1: per-app usage must be hidden")
        XCTAssertFalse(result.contains("45"), "v1: usedMin must not appear")
    }

    // MARK: - 6. Precision badge copy

    func test_precisionBadge() {
        XCTAssertEqual(EarnedDisplayFormatters.precisionBadge(), "~10 min steps")
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
