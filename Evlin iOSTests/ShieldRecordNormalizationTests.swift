import XCTest
@testable import Evlin_iOS

final class ShieldRecordNormalizationTests: XCTestCase {
    // MARK: - webOpen backward compatibility (C-3 Task 1)

    /// Legacy persisted payloads have no `webOpen` key. They MUST decode with
    /// `webOpen == false` — a decode failure here would silently wipe a
    /// parent's active shields (whole-dict decode fails closed).
    func test_missing_webOpen_decodes_false() throws {
        let decoded = try decodeLegacyRecordWithoutWebOpen()
        XCTAssertFalse(decoded.webOpen)
    }

    func test_webOpen_true_roundtrips_through_codable() throws {
        var record = ReflectionLockRecordFactory.make(
            rid: UUID(), expiresAt: Date(timeIntervalSince1970: 2_000), childID: UUID()
        )
        record.webOpen = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ShieldRecord.self, from: encoder.encode(record))

        XCTAssertTrue(decoded.webOpen)
    }

    func test_legacy_reflection_normalization_preserves_webOpen() {
        let rid = UUID()
        var legacy = ShieldRecord(
            recordKey: "all:reflection:\(rid.uuidString)",
            tier: .all,
            targetKey: "reflection:\(rid.uuidString)",
            displayName: "Reflection lock",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            originalRequest: "reflection lockdown",
            targetChildID: UUID()
        )
        legacy.webOpen = true

        let normalized = legacy.normalizedForCurrentSchema()

        XCTAssertTrue(normalized.migrated)
        XCTAssertTrue(normalized.record.webOpen, "re-key copy must not drop webOpen")
    }

    private func decodeLegacyRecordWithoutWebOpen() throws -> ShieldRecord {
        let json = """
        {
          "recordKey": "exactApp:com.example.app",
          "tier": "exactApp",
          "targetKey": "com.example.app",
          "displayName": "Example",
          "lastCommandID": "00000000-0000-0000-0000-000000000001",
          "appTokens": [],
          "categoryTokens": [],
          "webDomainTokens": [],
          "appliesToAll": false,
          "issuedAt": "2026-07-15T00:00:00Z",
          "originalRequest": "lock example",
          "targetChildID": "00000000-0000-0000-0000-000000000002"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShieldRecord.self, from: Data(json.utf8))
    }

    func test_legacy_reflection_all_record_normalizes_to_app_only() {
        let rid = UUID()
        let legacy = ShieldRecord(
            recordKey: "all:reflection:\(rid.uuidString)",
            tier: .all,
            targetKey: "reflection:\(rid.uuidString)",
            displayName: "Reflection lock",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            originalRequest: "reflection lockdown",
            targetChildID: UUID()
        )

        let normalized = legacy.normalizedForCurrentSchema()

        XCTAssertTrue(normalized.migrated)
        XCTAssertEqual(normalized.record.tier, .allApps)
        XCTAssertTrue(normalized.record.appliesToAll)
        XCTAssertFalse(normalized.record.isFullWebBroadShield)
    }

    func test_parent_all_record_remains_full_web_shield() {
        let parentAll = ShieldRecord(
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

        let normalized = parentAll.normalizedForCurrentSchema()

        XCTAssertFalse(normalized.migrated)
        XCTAssertEqual(normalized.record.tier, .all)
        XCTAssertTrue(normalized.record.isFullWebBroadShield)
    }
}
