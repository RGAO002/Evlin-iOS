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
          "ordering_token": 7,
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
        XCTAssertEqual(dto.ordering_token, 7)
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
          "ordering_token": 8,
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
        XCTAssertEqual(dto.ordering_token, 8)
        XCTAssertEqual(dto.timezone, "America/New_York")
        XCTAssertNil(dto.display_name)
    }

    func test_limitRuleAndClearLimitRejectNonPositiveOrderingTokens() throws {
        let limitData = """
        {
          "ruleId": "11111111-1111-1111-1111-111111111111",
          "ordering_token": 0,
          "dailyBudgetMinutes": 60,
          "resetPolicy": "daily",
          "startMinute": 0,
          "endMinute": 1439,
          "timezone": null,
          "effectiveFrom": 0,
          "expiresAt": null,
          "updatedAt": 0,
          "usedTodayMinutes": null
        }
        """.data(using: .utf8)!
        let clearData = """
        {
          "ruleId": "11111111-1111-1111-1111-111111111111",
          "ordering_token": -1,
          "reason": "parent_clear",
          "updatedAt": 0
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(LimitRule.self, from: limitData))
        XCTAssertThrowsError(try JSONDecoder().decode(ClearLimit.self, from: clearData))
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

@MainActor
final class AppLimitEditQueueTests: XCTestCase {
    func test_sameAppMutationsRunInIntentOrderAndThreadServerToken() async {
        let queue = AppLimitEditQueue()
        let ruleID = UUID()
        queue.seed(
            key: "facebook",
            state: .init(ruleID: ruleID, orderingToken: 2))
        var observedTokens: [Int?] = []

        queue.enqueue(key: "facebook") { state in
            observedTokens.append(state.orderingToken)
            return .init(ruleID: ruleID, orderingToken: 3)
        }
        queue.enqueue(key: "facebook") { state in
            observedTokens.append(state.orderingToken)
            return .init(ruleID: ruleID, orderingToken: 4)
        }

        await queue.waitForIdle(key: "facebook")

        XCTAssertEqual(observedTokens, [2, 3])
        XCTAssertEqual(queue.state(for: "facebook").orderingToken, 4)

        queue.seed(
            key: "facebook",
            state: .init(ruleID: ruleID, orderingToken: 9))
        XCTAssertEqual(
            queue.state(for: "facebook").orderingToken,
            9,
            "an idle queue must accept a refreshed server baseline")
    }
}

/// P9 review: the optimistic-update supersession guard. `pickLimit`/`toggleLimit`
/// bump a per-app monotonic token before their `await`; when each resumes it
/// asks `AppLimitEditDecision.decide` whether it may still mutate state. Only
/// the latest interaction (current == captured) is authoritative — a slower
/// earlier response is a NO-OP (neither its success write-back nor its failure
/// revert runs), which prevents stale overwrites, stale reverts, and the
/// enabled/ruleID desync from toggling off before an earlier POST returns.
final class AppLimitEditDecisionTests: XCTestCase {

    func test_nonSupersededResponseApplies() {
        // Single interaction: capture == current → apply.
        XCTAssertEqual(
            AppLimitEditDecision.decide(currentSeq: 1, capturedSeq: 1),
            .apply)
    }

    func test_laterInteractionSupersedesEarlierResponse() {
        // Two rapid taps for the same app: first captures 1, second bumps to 2.
        // The slow FIRST response resumes while current == 2 → superseded.
        // This holds for BOTH the success write-back and the failure revert
        // (the helper is the single gate both paths consult), so an earlier
        // response mutates nothing.
        XCTAssertEqual(
            AppLimitEditDecision.decide(currentSeq: 2, capturedSeq: 1),
            .superseded)
    }

    func test_latestInteractionStillApplies() {
        // The newer (second) interaction resumes last: capture == current == 2.
        XCTAssertEqual(
            AppLimitEditDecision.decide(currentSeq: 2, capturedSeq: 2),
            .apply)
    }

    func test_missingTokenIsSuperseded() {
        // Defensive: an absent entry (nil) never equals a captured token, so a
        // response whose app has no recorded in-flight token is a NO-OP.
        XCTAssertEqual(
            AppLimitEditDecision.decide(currentSeq: nil, capturedSeq: 1),
            .superseded)
    }

    /// End-to-end ordering proof: simulate two interactions on one app racing,
    /// driving a tiny state array through the same decision the view uses.
    /// The earlier response (success or failure) must be a no-op; only the
    /// later one mutates state.
    func test_earlierResponseIsNoOpAcrossSuccessAndRevert() {
        var state = 0                 // stand-in for the app's mutable row
        var current = 0               // stand-in for inflightSeq[app.id]

        // Interaction A starts.
        current += 1
        let seqA = current            // == 1
        // Interaction B starts before A's await resumes.
        current += 1
        let seqB = current            // == 2

        // A's SUCCESS resumes first → superseded → must NOT write back.
        if AppLimitEditDecision.decide(currentSeq: current, capturedSeq: seqA) == .apply {
            state = 100
        }
        XCTAssertEqual(state, 0, "earlier success write-back must be a no-op")

        // A's FAILURE path would also be gated the same way → must NOT revert.
        if AppLimitEditDecision.decide(currentSeq: current, capturedSeq: seqA) == .apply {
            state = -1
        }
        XCTAssertEqual(state, 0, "earlier failure revert must be a no-op")

        // B resumes last → authoritative → applies.
        if AppLimitEditDecision.decide(currentSeq: current, capturedSeq: seqB) == .apply {
            state = 200
        }
        XCTAssertEqual(state, 200, "latest interaction applies normally")
    }
}
