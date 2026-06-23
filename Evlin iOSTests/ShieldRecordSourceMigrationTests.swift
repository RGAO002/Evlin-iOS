import XCTest
@testable import Evlin_iOS

/// P4 regression guard. `ShieldRecord` gained a `source` provenance field. The
/// records are persisted as JSON in App Group UserDefaults and decoded
/// CROSS-PROCESS by both the main app and the DeviceActivity extension. Old
/// persisted payloads have NO `source` key — decoding MUST default the missing
/// field to `.manual` WITHOUT failing the whole `ShieldRecord` (or the
/// surrounding `[String: ShieldRecord]` dict). A failed decode here means every
/// active shield silently wipes on the next launch.
final class ShieldRecordSourceMigrationTests: XCTestCase {

    /// Match the on-wire date strategy the app + extension pin: `.iso8601`.
    private func evlinDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func evlinEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// A single OLD `ShieldRecord` JSON object WITHOUT a `source` key, with the
    /// `.iso8601` date format the live store uses. This mirrors a payload
    /// already sitting in a parent's App Group from a previous app version.
    private let legacyRecordJSON = """
    {
      "recordKey": "exactApp:com.burbn.instagram",
      "tier": "exactApp",
      "targetKey": "com.burbn.instagram",
      "displayName": "Instagram",
      "lastCommandID": "11111111-1111-1111-1111-111111111111",
      "appTokens": [],
      "categoryTokens": [],
      "webDomainTokens": [],
      "appliesToAll": false,
      "issuedAt": "2026-01-02T03:04:05Z",
      "expiresAt": "2026-01-02T04:04:05Z",
      "originalRequest": "lock instagram",
      "targetChildID": "22222222-2222-2222-2222-222222222222"
    }
    """

    func test_legacyRecordWithoutSource_decodesAsManual() throws {
        let data = Data(legacyRecordJSON.utf8)
        let record = try evlinDecoder().decode(ShieldRecord.self, from: data)
        XCTAssertEqual(record.sources, [.manual], "Missing source key must default to {.manual}")
        // The rest of the record must survive intact (no field shifted).
        XCTAssertEqual(record.recordKey, "exactApp:com.burbn.instagram")
        XCTAssertEqual(record.tier, .exactApp)
        XCTAssertEqual(record.displayName, "Instagram")
        XCTAssertFalse(record.appliesToAll)
    }

    /// The store persists the WHOLE dict `[String: ShieldRecord]`. A missing
    /// `source` on one record must not fail the dict decode (= silent wipe).
    func test_legacyDictWithoutSource_decodesWholeDict() throws {
        let dictJSON = "{ \"exactApp:com.burbn.instagram\": \(legacyRecordJSON) }"
        let data = Data(dictJSON.utf8)
        let decoded = try evlinDecoder().decode([String: ShieldRecord].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        let record = try XCTUnwrap(decoded["exactApp:com.burbn.instagram"])
        XCTAssertEqual(record.sources, [.manual])
    }

    /// A JSON object whose `source` is a value NO current case matches (e.g. a
    /// future `"schedule"` written by a newer app and read by an older extension
    /// binary). `ShieldSource`'s synthesized `RawRepresentable` decode would THROW
    /// on this, failing the whole `ShieldRecord` decode. The unknown-tolerant
    /// decoder must instead fall back to `.manual` WITHOUT throwing.
    private let futureSourceRecordJSON = """
    {
      "recordKey": "exactApp:com.burbn.instagram",
      "tier": "exactApp",
      "targetKey": "com.burbn.instagram",
      "displayName": "Instagram",
      "lastCommandID": "11111111-1111-1111-1111-111111111111",
      "appTokens": [],
      "categoryTokens": [],
      "webDomainTokens": [],
      "appliesToAll": false,
      "issuedAt": "2026-01-02T03:04:05Z",
      "expiresAt": "2026-01-02T04:04:05Z",
      "originalRequest": "lock instagram",
      "targetChildID": "22222222-2222-2222-2222-222222222222",
      "source": "schedule"
    }
    """

    func test_unknownFutureSource_decodesAsManual() throws {
        let data = Data(futureSourceRecordJSON.utf8)
        // Must NOT throw — an unknown future source value falls back to .manual.
        let record = try evlinDecoder().decode(ShieldRecord.self, from: data)
        XCTAssertEqual(record.sources, [.manual], "Unknown future source value must fall back to {.manual}")
        // Rest of the record must survive intact.
        XCTAssertEqual(record.recordKey, "exactApp:com.burbn.instagram")
        XCTAssertEqual(record.tier, .exactApp)

        // And inside the WHOLE dict the store actually persists — an unknown
        // source on one record must not fail the dict decode (= silent wipe).
        let dictJSON = "{ \"exactApp:com.burbn.instagram\": \(futureSourceRecordJSON) }"
        let decoded = try evlinDecoder().decode([String: ShieldRecord].self, from: Data(dictJSON.utf8))
        XCTAssertEqual(decoded.count, 1)
        let dictRecord = try XCTUnwrap(decoded["exactApp:com.burbn.instagram"])
        XCTAssertEqual(dictRecord.sources, [.manual])
    }

    /// Full-field round-trip guard. The `Codable` is HAND-WRITTEN (not
    /// synthesized), so a future stored property added to `ShieldRecord` could be
    /// silently dropped from `init(from:)`/`encode(to:)`. Constructing a record
    /// with EVERY field set to a distinctive non-default value and asserting full
    /// `==` equality after encode → decode catches any dropped field.
    func test_fullFieldRoundTrip_preservesEveryField() throws {
        let original = ShieldRecord(
            recordKey: "savedList:F1E2D3C4-0000-0000-0000-000000000001",
            tier: .savedList,
            targetKey: "F1E2D3C4-0000-0000-0000-000000000001",
            displayName: "Focus Block",
            lastCommandID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            originalRequest: "limit my focus block",
            targetChildID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            sources: [.limit]
        )

        let data = try evlinEncoder().encode(original)
        let decoded = try evlinDecoder().decode(ShieldRecord.self, from: data)

        // Full structural equality — fails if anyone drops a field from the
        // manual Codable. Token sets are empty here (tokens are opaque,
        // platform-minted, and cannot be synthesized in a unit test), but they
        // ARE part of the `==` comparison so an emptied-vs-emptied set still
        // exercises the field.
        XCTAssertEqual(decoded, original, "Full-field round-trip must preserve every stored property")
    }

    /// A record explicitly authored by the limit subsystem round-trips with its
    /// `.limit` provenance preserved through encode → decode.
    func test_limitSourceRoundTrips() throws {
        let original = ShieldRecord(
            recordKey: "exactApp:com.toyopagroup.picaboo",
            tier: .exactApp,
            targetKey: "com.toyopagroup.picaboo",
            displayName: "Snapchat",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            originalRequest: "limit snapchat to 30m",
            targetChildID: UUID(),
            sources: [.limit]
        )

        let data = try evlinEncoder().encode(original)
        let decoded = try evlinDecoder().decode(ShieldRecord.self, from: data)

        XCTAssertEqual(decoded.sources, [.limit])
        XCTAssertEqual(decoded.recordKey, original.recordKey)
        XCTAssertEqual(decoded.tier, original.tier)
        XCTAssertEqual(decoded.lastCommandID, original.lastCommandID)
        XCTAssertEqual(decoded.targetChildID, original.targetChildID)
    }

    /// Default construction (no `source:` argument supplied) must yield `.manual`
    /// so every existing manual construction site keeps its historical meaning.
    func test_defaultConstructionIsManual() {
        let record = ShieldRecord(
            recordKey: "all",
            tier: .all,
            targetKey: "all",
            displayName: "All Apps",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock all",
            targetChildID: UUID()
        )
        XCTAssertEqual(record.sources, [.manual])
    }
}
