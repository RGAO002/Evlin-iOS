import DeviceActivity
import FamilyControls
import ManagedSettings
import XCTest
@testable import Evlin_iOS

/// P8 — pins the set_limit / clear_limit WIRE CONTRACT to the shared canonical
/// fixture on the iOS (decode + execute) side.
///
/// This loads `Evlin iOSTests/Fixtures/app_limit_wire.json` — a BYTE-IDENTICAL
/// copy of which lives in the backend repo at
/// `Evlin-Backend/tests/fixtures/app_limit_wire.json` — and decodes the SAME
/// `set_limit` / `clear_limit` objects the backend emission test asserts
/// against. The decode runs the REAL poll path:
/// `PollCommandDTO` → `CommandPoller.lockCommand(from:)`. If iOS renames a
/// decoded wire key (e.g. `daily_budget_minutes`, `catalog_token_data_base64`,
/// `schedule.starts_at`), decoding the canonical fixture fails here — so the
/// two sides can't silently drift.
///
/// Loading strategy: prefer the bundled resource (synchronized-group auto-
/// inclusion), and fall back to the committed source file resolved from this
/// test's own `#filePath`. EITHER way we read the exact committed fixture; the
/// fallback also makes the test independent of resource-bundling quirks. The
/// two are asserted byte-identical when both are reachable.
@MainActor
final class AppLimitWireContractTests: XCTestCase {

    // MARK: - Canonical fixture loading

    /// The committed source file, resolved from this test file's location
    /// (`…/Evlin iOSTests/AppLimitWireContractTests.swift` →
    ///  `…/Evlin iOSTests/Fixtures/app_limit_wire.json`). This is the SAME file
    /// committed into the repo, independent of whether Xcode bundled it.
    private static func sourceFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("app_limit_wire.json")
    }

    /// The bundled resource, if the test target included it (synchronized
    /// groups should). Nil if not bundled.
    private static func bundledFixtureURL() -> URL? {
        Bundle(for: AppLimitWireContractTests.self)
            .url(forResource: "app_limit_wire", withExtension: "json")
    }

    /// Load the canonical fixture bytes. Prefers the source file (always
    /// present); when the bundled copy is ALSO present, asserts the two are
    /// byte-identical so a stale bundled resource can't mask drift.
    private func loadFixtureData() throws -> Data {
        let sourceURL = Self.sourceFixtureURL()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceURL.path),
            "canonical fixture missing at \(sourceURL.path)"
        )
        let sourceData = try Data(contentsOf: sourceURL)

        if let bundledURL = Self.bundledFixtureURL() {
            let bundledData = try Data(contentsOf: bundledURL)
            XCTAssertEqual(
                bundledData, sourceData,
                "bundled fixture and committed source fixture have drifted — re-sync"
            )
        }
        return sourceData
    }

    /// Decode the fixture's top-level { "set_limit": {...}, "clear_limit": {...} }
    /// into the two example poll commands.
    private func decodeExamples() throws -> (setLimit: PollCommandDTO, clearLimit: PollCommandDTO) {
        let data = try loadFixtureData()
        // The fixture is { "_README": "...", "set_limit": {…}, "clear_limit": {…} }.
        // Pull the two command objects out and decode each as a PollCommandDTO
        // (exactly what the poll endpoint returns per-command).
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let setObj = try XCTUnwrap(root?["set_limit"], "fixture missing 'set_limit'")
        let clearObj = try XCTUnwrap(root?["clear_limit"], "fixture missing 'clear_limit'")
        let setData = try JSONSerialization.data(withJSONObject: setObj)
        let clearData = try JSONSerialization.data(withJSONObject: clearObj)
        let decoder = JSONDecoder()
        let setDTO = try decoder.decode(PollCommandDTO.self, from: setData)
        let clearDTO = try decoder.decode(PollCommandDTO.self, from: clearData)
        return (setDTO, clearDTO)
    }

    // MARK: - set_limit: decode → LockCommand.limit populated from the fixture

    func testSetLimitFixtureDecodesThroughRealPollPath() throws {
        let (setDTO, _) = try decodeExamples()

        // The real poll → LockCommand mapping (same code CommandPoller runs).
        let cmd = CommandPoller.lockCommand(from: setDTO)

        XCTAssertEqual(cmd.action, .setLimit, "fixture action must decode to .setLimit")
        XCTAssertEqual(cmd.tier, .exactApp, "fixture tier 'exactApp' must decode")
        XCTAssertNil(cmd.durationMinutes, "duration_minutes is always null for limits")
        XCTAssertEqual(cmd.target.bundleID, "com.google.ios.youtube")
        XCTAssertEqual(cmd.target.targetDisplay, "YouTube")
        XCTAssertEqual(
            cmd.target.catalogTokenDataBase64, "QVBQX1RPS0VO",
            "the executable token must decode out of target.catalog_token_data_base64"
        )

        // The whole point: LockCommand.limit is populated with the fixture values.
        let limit = try XCTUnwrap(cmd.limit, "set_limit must decode a non-nil LimitRule")
        XCTAssertEqual(limit.dailyBudgetMinutes, 60, "daily_budget_minutes")
        XCTAssertEqual(limit.resetPolicy, "daily", "reset_policy")
        XCTAssertEqual(limit.startMinute, 0, "schedule.starts_at '00:00' → minute 0")
        XCTAssertEqual(limit.endMinute, 1439, "schedule.ends_at '23:59' → minute 1439")
        XCTAssertNil(limit.timezone, "schedule.timezone null → nil")
        XCTAssertEqual(
            limit.ruleId,
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        XCTAssertEqual(limit.orderingToken, 9_007_199_254_740_993)
        // Timestamps parse (effective_from / updated_at are required; nil ⇒ the
        // whole limit would have decoded to nil, which XCTUnwrap above caught).
        XCTAssertEqual(limit.effectiveFrom.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-06-19T00:00:00Z")!.timeIntervalSince1970,
                       accuracy: 1.0)
        XCTAssertNil(limit.expiresAt, "expires_at null → nil")
    }

    // MARK: - clear_limit: decode → LockCommand.clear populated from the fixture

    func testClearLimitFixtureDecodesThroughRealPollPath() throws {
        let (_, clearDTO) = try decodeExamples()
        let cmd = CommandPoller.lockCommand(from: clearDTO)

        XCTAssertEqual(cmd.action, .clearLimit, "fixture action must decode to .clearLimit")
        XCTAssertEqual(cmd.tier, .exactApp)
        XCTAssertNil(cmd.durationMinutes)
        XCTAssertNil(cmd.limit, "clear_limit carries no `limit`")
        XCTAssertEqual(cmd.target.bundleID, "com.google.ios.youtube")

        let clear = try XCTUnwrap(cmd.clear, "clear_limit must decode a non-nil ClearLimit")
        XCTAssertEqual(clear.ruleId, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(clear.orderingToken, 9_007_199_254_740_993)
        XCTAssertEqual(clear.reason, "parent_clear", "clear.reason")
    }

}
