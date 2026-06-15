import XCTest
@testable import Evlin_iOS

final class ShieldRecordNormalizationTests: XCTestCase {
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
