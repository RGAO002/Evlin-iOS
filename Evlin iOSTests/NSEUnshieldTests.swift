import XCTest
@testable import Evlin_iOS

@MainActor
final class NSEUnshieldTests: XCTestCase {
    private let suiteName = "group.com.evlin.ios"
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removeObject(forKey: shieldsKey)
        defaults?.removeObject(forKey: blocksKey)
    }

    override func tearDown() async throws {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removeObject(forKey: shieldsKey)
        defaults?.removeObject(forKey: blocksKey)
    }

    func test_resolvedUnlockSources_prefersTopLevelAndFallsBackToTarget() {
        XCTAssertEqual(
            NSECommandSourceResolver.unlockSources(
                topLevel: ["manual"],
                target: ["earned_time"]
            ),
            ["manual"]
        )
        XCTAssertEqual(
            NSECommandSourceResolver.unlockSources(
                topLevel: nil,
                target: ["task_pause"]
            ),
            ["task_pause"]
        )
        XCTAssertNil(NSECommandSourceResolver.unlockSources(topLevel: nil, target: nil))
    }

    func test_manualUnshield_keepsAutomaticSourcesAndConfirmsOutcome() async throws {
        let store = ActiveLockStore()
        let listID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: listID.uuidString)
        let record = ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: listID.uuidString,
            displayName: "Locked set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock Locked set",
            targetChildID: UUID(),
            sources: [.manual, .earnedTime, .taskPause]
        )
        _ = await store.addShield(record)
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "unlock Locked set",
                targetDisplay: "Locked set",
                unlockSources: ["manual"]
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: recordKey,
            store: store
        )

        XCTAssertEqual(outcome, .confirmed)
        let current = await store.allCurrent().shields
        let remaining = try XCTUnwrap(current.first(where: { $0.recordKey == recordKey }))
        XCTAssertEqual(remaining.sources, [.earnedTime, .taskPause])
    }

    func test_legacyUnshieldWithoutSources_removesWholeRecord() async {
        let store = ActiveLockStore()
        let listID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: listID.uuidString)
        let record = ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: listID.uuidString,
            displayName: "Locked set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "lock Locked set",
            targetChildID: UUID(),
            sources: [.manual, .earnedTime]
        )
        _ = await store.addShield(record)
        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: listID,
                originalRequest: "unlock Locked set",
                targetDisplay: "Locked set"
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )

        let outcome = await NSEUnshieldCommandApplier.apply(
            command,
            recordKey: recordKey,
            store: store
        )

        XCTAssertEqual(outcome, .confirmed)
        let remaining = await store.allCurrent().shields
        XCTAssertFalse(remaining.contains(where: { $0.recordKey == recordKey }))
    }
}
