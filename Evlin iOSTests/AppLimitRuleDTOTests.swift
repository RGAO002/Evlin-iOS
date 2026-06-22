import SwiftUI
import XCTest
@testable import Evlin_iOS

/// P9: decode of `APIClient.AppLimitRuleDTO` against the backend's
/// `AppLimitRuleResponse` wire shape, plus the pure app↔rule merge that builds
/// `DeviceAppsSheet`'s state. The DTO uses snake_case literal property names
/// (this codebase does NOT set `convertFromSnakeCase`) and the backend rule id
/// field is `rule_id` (NOT `id`).
final class AppLimitRuleDTOTests: XCTestCase {

    // MARK: - DTO decode

    /// Builds the same decoder the production methods use (custom ISO-8601 with
    /// + without fractional seconds). Mirrors `APIClient.appLimitDateDecoder`.
    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let d = withFractional.date(from: raw) ?? plain.date(from: raw) { return d }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return dec
    }

    func test_appLimitRuleDTODecodesBackendResponseShape() throws {
        // Field-for-field the backend `AppLimitRuleResponse` (child_device.py).
        let data = """
        {
          "rule_id": "11111111-1111-1111-1111-111111111111",
          "family_id": "22222222-2222-2222-2222-222222222222",
          "child_device_id": "33333333-3333-3333-3333-333333333333",
          "bundle_id": "com.google.ios.youtube",
          "display_name": "YouTube",
          "artwork_url": "https://example.com/yt.png",
          "daily_budget_minutes": 60,
          "reset_policy": "daily",
          "window_start_minute": 0,
          "window_end_minute": 1439,
          "timezone": null,
          "status": "active",
          "effective_from": "2026-06-19T00:00:00+00:00",
          "expires_at": null,
          "updated_at": "2026-06-19T00:00:00+00:00"
        }
        """.data(using: .utf8)!

        let dto = try makeDecoder().decode(APIClient.AppLimitRuleDTO.self, from: data)

        XCTAssertEqual(dto.rule_id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(dto.family_id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(dto.child_device_id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(dto.bundle_id, "com.google.ios.youtube")
        XCTAssertEqual(dto.display_name, "YouTube")
        XCTAssertEqual(dto.artwork_url, "https://example.com/yt.png")
        XCTAssertEqual(dto.daily_budget_minutes, 60)
        XCTAssertEqual(dto.reset_policy, "daily")
        XCTAssertEqual(dto.window_start_minute, 0)
        XCTAssertEqual(dto.window_end_minute, 1439)
        XCTAssertNil(dto.timezone)
        XCTAssertEqual(dto.status, "active")
        XCTAssertNil(dto.expires_at)
    }

    func test_appLimitRuleDTODecodesFractionalSecondsTimestamp() throws {
        // Some backends serialize with fractional seconds; the custom decoder
        // must accept both this and the plain variant above.
        let data = """
        {
          "rule_id": "11111111-1111-1111-1111-111111111111",
          "family_id": "22222222-2222-2222-2222-222222222222",
          "child_device_id": "33333333-3333-3333-3333-333333333333",
          "bundle_id": "com.burbn.instagram",
          "display_name": null,
          "artwork_url": null,
          "daily_budget_minutes": 30,
          "reset_policy": "daily",
          "window_start_minute": 0,
          "window_end_minute": 1439,
          "timezone": "America/New_York",
          "status": "active",
          "effective_from": "2026-06-19T08:30:15.250000+00:00",
          "expires_at": null,
          "updated_at": "2026-06-19T08:30:15.250000+00:00"
        }
        """.data(using: .utf8)!

        let dto = try makeDecoder().decode(APIClient.AppLimitRuleDTO.self, from: data)
        XCTAssertEqual(dto.daily_budget_minutes, 30)
        XCTAssertEqual(dto.timezone, "America/New_York")
        XCTAssertNil(dto.display_name)
    }

    // MARK: - App ↔ rule merge

    private func catalogApp(id: String, bundle: String?) -> DeviceAppItem {
        DeviceAppItem(
            id: id, name: id, iconSystemName: "app.fill",
            brandColor: .clear, bgColor: .clear,
            enabled: false, usedMin: 0, limitMin: 60,
            artworkURL: nil, bundleID: bundle, ruleID: nil)
    }

    func test_mergeTurnsOnAppsThatHaveARuleAndOffThoseThatDont() {
        let ytRule = AppLimitRuleSummary(
            ruleID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            bundleID: "com.google.ios.youtube",
            dailyBudgetMinutes: 45)
        let apps = [
            catalogApp(id: "yt", bundle: "com.google.ios.youtube"),
            catalogApp(id: "ig", bundle: "com.burbn.instagram"),
        ]

        let merged = DeviceAppLimitMerge.apply(rules: [ytRule], to: apps)

        // YouTube has a rule → on, budget from rule, ruleID carried.
        XCTAssertTrue(merged[0].enabled)
        XCTAssertEqual(merged[0].limitMin, 45)
        XCTAssertEqual(merged[0].ruleID, ytRule.ruleID)
        // Instagram has no rule → off, no ruleID, default limit preserved for pill.
        XCTAssertFalse(merged[1].enabled)
        XCTAssertNil(merged[1].ruleID)
        XCTAssertEqual(merged[1].limitMin, 60)
    }

    func test_mergeLeavesBundlelessAppsOff() {
        let rule = AppLimitRuleSummary(
            ruleID: UUID(), bundleID: "com.google.ios.youtube", dailyBudgetMinutes: 20)
        let apps = [catalogApp(id: "mystery", bundle: nil)]

        let merged = DeviceAppLimitMerge.apply(rules: [rule], to: apps)

        XCTAssertFalse(merged[0].enabled)
        XCTAssertNil(merged[0].ruleID)
    }

    func test_mergeWithNoRulesTurnsEverythingOff() {
        let apps = [
            catalogApp(id: "yt", bundle: "com.google.ios.youtube"),
            catalogApp(id: "ig", bundle: "com.burbn.instagram"),
        ]

        let merged = DeviceAppLimitMerge.apply(rules: [], to: apps)

        XCTAssertTrue(merged.allSatisfy { !$0.enabled })
        XCTAssertTrue(merged.allSatisfy { $0.ruleID == nil })
    }
}
