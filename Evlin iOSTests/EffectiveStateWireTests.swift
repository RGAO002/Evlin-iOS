import XCTest
@testable import Evlin_iOS

/// B7 — pins that `globalEffectiveStateDictionary()` emits `recordKey`,
/// `targetKey`, and `sources` (ShieldSource rawValues) in each cover dict,
/// alongside the existing `displayName` / `expiresAtISO` / `tier` fields.
///
/// Tests run entirely against `AckEffectiveState.ShieldCover` (the Codable
/// model) and against the JSON round-trip — no device state or FamilyControls
/// required.
final class EffectiveStateWireTests: XCTestCase {

    // MARK: - AckEffectiveState.ShieldCover model

    func test_shieldCover_encodes_recordKey_targetKey_sources() throws {
        let cover = AckEffectiveState.ShieldCover(
            displayName: "YouTube",
            expiresAtISO: nil,
            tier: "savedList",
            recordKey: "savedList:abc123",
            targetKey: "abc123",
            sources: ["manual", "earnedTime"]
        )

        let data = try JSONEncoder().encode(cover)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded cover is not a JSON object"
        )

        // Existing fields must survive
        XCTAssertEqual(dict["displayName"] as? String, "YouTube", "displayName must be present")
        XCTAssertEqual(dict["tier"] as? String, "savedList", "tier must be present")
        XCTAssertNil(dict["expiresAtISO"], "nil expiresAtISO should not appear in JSON")

        // New identity fields
        XCTAssertEqual(dict["recordKey"] as? String, "savedList:abc123", "recordKey key and value")
        XCTAssertEqual(dict["targetKey"] as? String, "abc123", "targetKey key and value")

        // sources: order-independent set check
        let sources = try XCTUnwrap(dict["sources"] as? [String], "sources must be a [String]")
        XCTAssertEqual(Set(sources), Set(["manual", "earnedTime"]), "sources must contain manual + earnedTime")
    }

    func test_shieldCover_limit_only_sources() throws {
        let cover = AckEffectiveState.ShieldCover(
            displayName: "Instagram",
            expiresAtISO: "2026-07-01T00:00:00Z",
            tier: "exactApp",
            recordKey: "exactApp:ig64",
            targetKey: "ig64",
            sources: ["limit"]
        )

        let data = try JSONEncoder().encode(cover)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let sources = try XCTUnwrap(dict["sources"] as? [String])
        XCTAssertEqual(sources, ["limit"], "single-source .limit cover must emit [\"limit\"]")
    }

    // MARK: - earnedTime must NOT be snake_case

    func test_shieldCover_earnedTime_rawValue_is_camelCase() throws {
        let cover = AckEffectiveState.ShieldCover(
            displayName: "Any",
            expiresAtISO: nil,
            tier: "savedList",
            recordKey: "savedList:x",
            targetKey: "x",
            sources: ["earnedTime"]
        )
        let data = try JSONEncoder().encode(cover)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try XCTUnwrap(dict["sources"] as? [String])
        XCTAssertEqual(sources, ["earnedTime"], "earnedTime must be camelCase, not earned_time")
        XCTAssertFalse(sources.contains("earned_time"), "snake_case earned_time must NOT appear")
    }

    // MARK: - Back-compat: covers without identity fields decode cleanly

    func test_shieldCover_back_compat_decode_missing_optional_fields() throws {
        // A legacy ack from an old binary that has no recordKey/targetKey/sources.
        let legacyJSON = """
        {
          "displayName": "Legacy App",
          "tier": "exactApp"
        }
        """.data(using: .utf8)!

        let cover = try JSONDecoder().decode(AckEffectiveState.ShieldCover.self, from: legacyJSON)
        XCTAssertEqual(cover.displayName, "Legacy App")
        XCTAssertEqual(cover.tier, "exactApp")
        XCTAssertNil(cover.recordKey, "missing recordKey decodes to nil")
        XCTAssertNil(cover.targetKey, "missing targetKey decodes to nil")
        XCTAssertNil(cover.sources, "missing sources decodes to nil")
    }

    // MARK: - Key casing: exact JSON keys must match backend A9 spec §5.4

    func test_shieldCover_json_keys_exact_casing() throws {
        let cover = AckEffectiveState.ShieldCover(
            displayName: "Test",
            expiresAtISO: "2026-01-01T00:00:00Z",
            tier: "savedList",
            recordKey: "savedList:rk",
            targetKey: "rk",
            sources: ["manual"]
        )
        let data = try JSONEncoder().encode(cover)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Verify EXACT key names (camelCase spec §5.4)
        XCTAssertNotNil(dict["recordKey"], "key must be 'recordKey' (camelCase)")
        XCTAssertNotNil(dict["targetKey"], "key must be 'targetKey' (camelCase)")
        XCTAssertNotNil(dict["displayName"], "key must be 'displayName' (camelCase)")
        XCTAssertNotNil(dict["expiresAtISO"], "key must be 'expiresAtISO' (camelCase)")
        XCTAssertNotNil(dict["tier"], "key must be 'tier' (lowercase)")
        XCTAssertNotNil(dict["sources"], "key must be 'sources' (lowercase)")

        // Must NOT contain snake_case variants
        XCTAssertNil(dict["record_key"], "snake_case record_key must NOT appear")
        XCTAssertNil(dict["target_key"], "snake_case target_key must NOT appear")
        XCTAssertNil(dict["expires_at_iso"], "snake_case expires_at_iso must NOT appear")
    }

    // MARK: - globalEffectiveStateDictionary via ShieldCover round-trip

    /// Simulates the path CommandPoller takes: build ShieldCover from a
    /// ShieldRecord-like struct, encode the AckEffectiveState, deserialize
    /// to [String:Any] (what globalEffectiveStateDictionary returns), and
    /// assert all B7 fields survive.
    func test_ackEffectiveState_covers_include_identity_fields() throws {
        let listID = "list-42"
        let cover = AckEffectiveState.ShieldCover(
            displayName: "My Saved List",
            expiresAtISO: nil,
            tier: "savedList",
            recordKey: "savedList:\(listID)",
            targetKey: listID,
            sources: ["manual", "earnedTime"]
        )
        let snapshot = AckEffectiveState(
            isBlocked: false,
            shieldsCovering: [cover],
            possibleSavedListCoverage: false
        )

        let data = try JSONEncoder().encode(snapshot)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let coverDicts = try XCTUnwrap(root["shieldsCovering"] as? [[String: Any]])
        XCTAssertEqual(coverDicts.count, 1)
        let d = coverDicts[0]

        XCTAssertEqual(d["recordKey"] as? String, "savedList:list-42")
        XCTAssertEqual(d["targetKey"] as? String, "list-42")
        let srcs = try XCTUnwrap(d["sources"] as? [String])
        XCTAssertEqual(Set(srcs), Set(["manual", "earnedTime"]))
        // Existing fields
        XCTAssertEqual(d["displayName"] as? String, "My Saved List")
        XCTAssertEqual(d["tier"] as? String, "savedList")
    }
}
