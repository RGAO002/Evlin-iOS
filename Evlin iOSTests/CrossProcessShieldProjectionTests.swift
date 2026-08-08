import XCTest
@testable import Evlin_iOS

final class CrossProcessShieldProjectionTests: XCTestCase {
    func test_parentAllAndReflectionWebOpen_resolvesOpenForEveryProcess() {
        let parent = makeBroadRecord(key: "all", tier: .all, webOpen: false)
        let reflection = makeBroadRecord(
            key: "allApps:reflection",
            tier: .allApps,
            webOpen: true
        )

        XCTAssertEqual(
            ShieldWebProjectionDecision.resolve(records: [parent, reflection]),
            .open
        )
    }

    func test_mainAppAndMonitorExtension_useSharedWebProjectionDecision() throws {
        let mainSource = try sourceText("Evlin iOS/Services/ActiveLockStore.swift")
        let extensionSource = try sourceText(
            "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
        )
        let invocation = "ShieldWebProjectionDecision.resolve"

        XCTAssertTrue(mainSource.contains(invocation))
        XCTAssertTrue(
            extensionSource.contains(invocation),
            "DeviceActivity recompute must not revive a parent .all web shield over reflection webOpen"
        )
    }

    func testPersistedShieldDecodeRejectsCorruptBlobInsteadOfTreatingItAsEmpty() throws {
        XCTAssertNil(ShieldSourceLogic.decodePersistedShields(Data("not-a-shield-dictionary".utf8)))

        let record = makeBroadRecord(key: "all", tier: .all, webOpen: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record.recordKey: record])

        XCTAssertEqual(
            ShieldSourceLogic.decodePersistedShields(data)?[record.recordKey],
            record
        )
    }

    func testMonitorExtensionFailsClosedWhenPersistedShieldBlobCannotDecode() throws {
        let extensionSource = try sourceText(
            "EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift"
        )

        XCTAssertTrue(
            extensionSource.contains("private func loadShields() -> [String: ShieldRecord]?")
        )
        XCTAssertFalse(
            extensionSource.contains("let decoded = decodeShields(from: data) else { return [:] }")
        )
        XCTAssertTrue(extensionSource.contains("shield_decode_failed_fail_closed"))
    }

    private func makeBroadRecord(
        key: String,
        tier: ShieldTier,
        webOpen: Bool
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: key,
            tier: tier,
            targetKey: key,
            displayName: key,
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: nil,
            originalRequest: key,
            targetChildID: UUID(),
            sources: [.manual],
            webOpen: webOpen
        )
    }

    private func sourceText(_ repoRelativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(repoRelativePath),
            encoding: .utf8
        )
    }
}
