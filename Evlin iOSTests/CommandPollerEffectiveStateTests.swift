import XCTest
@testable import Evlin_iOS

final class CommandPollerEffectiveStateTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test.effstate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeShield() -> ShieldRecord {
        ShieldRecord(
            recordKey: "savedList:L1",
            tier: .savedList,
            targetKey: "L1",
            displayName: "Locked Set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_780_000_000),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID(),
            sources: [.earnedTime]
        )
    }

    private func makeBlock() -> BlockRecord {
        BlockRecord(
            bundleID: "com.game.x",
            displayName: "Game X",
            blockedAt: Date(timeIntervalSince1970: 1_780_000_000),
            lastCommandID: UUID(),
            originalRequest: "test",
            targetChildID: UUID()
        )
    }

    private func seed(shields: [ShieldRecord], blocks: [BlockRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let shieldDict = Dictionary(uniqueKeysWithValues: shields.map { ($0.recordKey, $0) })
        let blockDict = Dictionary(uniqueKeysWithValues: blocks.map { ($0.bundleID, $0) })
        defaults.set(try! enc.encode(shieldDict), forKey: CurrentRestrictionsReader.shieldsKey)
        defaults.set(try! enc.encode(blockDict), forKey: CurrentRestrictionsReader.blocksKey)
    }

    // 1) snapshot reflects the PERSISTED records (enforcement truth)
    func test_snapshot_readsPersistedTruth() throws {
        seed(shields: [makeShield()], blocks: [makeBlock()])
        let dict = try XCTUnwrap(
            CommandPoller.globalEffectiveStateDictionary(defaults: defaults))
        XCTAssertEqual(dict["isBlocked"] as? Bool, true)
        let covers = try XCTUnwrap(dict["shieldsCovering"] as? [[String: Any]])
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers[0]["recordKey"] as? String, "savedList:L1")
        XCTAssertEqual((covers[0]["sources"] as? [String]), ["earnedTime"])
        let blocks = try XCTUnwrap(dict["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["bundleID"] as? String, "com.game.x")
        XCTAssertEqual(blocks[0]["displayName"] as? String, "Game X")
    }

    // 2) empty truth → empty snapshot (not nil)
    func test_snapshot_emptyTruth() throws {
        let dict = try XCTUnwrap(
            CommandPoller.globalEffectiveStateDictionary(defaults: defaults))
        XCTAssertEqual(dict["isBlocked"] as? Bool, false)
        XCTAssertEqual((dict["shieldsCovering"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((dict["blocks"] as? [[String: Any]])?.count, 0)
    }
}
