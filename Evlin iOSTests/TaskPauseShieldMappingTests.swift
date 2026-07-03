import XCTest
import FamilyControls
@testable import Evlin_iOS

final class TaskPauseShieldMappingTests: XCTestCase {
    override func setUp() async throws {
        await clearActiveLockState()
    }

    override func tearDown() async throws {
        await clearActiveLockState()
    }

    func test_wireLockSource_taskPause_mapsToTaskPauseSource() {
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "task_pause"), [.taskPause])
    }

    func test_wireLockSource_earnedTime_stillMaps() {
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "earned_time"), [.earnedTime])
    }

    func test_wireLockSource_unknown_defaultsToManual() {
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: nil), [.manual])
        XCTAssertEqual(ActionExecutor.shieldSources(fromWireLockSource: "schedule"), [.manual])
    }

    func test_shieldSource_rawValue_taskPause() {
        XCTAssertEqual(ShieldSource.taskPause.rawValue, "taskPause")
        XCTAssertEqual(ShieldSource(rawValue: "nope") ?? .manual, .manual)
    }

    func test_unshieldUnlockSources_taskPause_removesOnlyTaskPauseSource() async throws {
        let listID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: listID.uuidString)
        let record = makeSavedListRecord(
            recordKey: recordKey,
            targetKey: listID.uuidString,
            sources: [.manual, .earnedTime, .taskPause]
        )
        _ = await ActiveLockStore.shared.addShield(record)

        let command = LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Games",
                listID: listID,
                originalRequest: "unlock task pause for games",
                targetDisplay: "Games",
                targetChildID: UUID(),
                unlockSources: ["task_pause"]
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )
        let executor = ActionExecutor(authorizationStatusProvider: { .approved })

        _ = await executor.execute(command)

        let remaining = await ActiveLockStore.shared.allCurrent().shields
            .first(where: { $0.recordKey == recordKey })
        XCTAssertNotNil(remaining, "Record must survive when manual and earned-time sources remain")
        XCTAssertEqual(remaining?.sources, [.manual, .earnedTime])
    }

    private func makeSavedListRecord(
        recordKey: String,
        targetKey: String,
        sources: Set<ShieldSource>
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: targetKey,
            displayName: "Games",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_750_000_000),
            expiresAt: nil,
            originalRequest: "lock games",
            targetChildID: UUID(),
            sources: sources
        )
    }

    private func clearActiveLockState() async {
        _ = await ActiveLockStore.shared.unblockAll()
        _ = await ActiveLockStore.shared.unshieldAll()

        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        defaults?.removeObject(forKey: "evlin.blockRecords")
        defaults?.removeObject(forKey: "evlin.shieldRecords")
    }
}
