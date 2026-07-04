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

    // MARK: - Instant counter re-arm after task_pause unshield (2026-07-03)

    private func makeCommand(unlockSources: [String]?) -> LockCommand {
        LockCommand(
            id: UUID(),
            action: .unshield,
            tier: .savedList,
            target: CommandTarget(
                listName: "Locked set",
                listID: UUID(),
                originalRequest: "tasks complete",
                targetDisplay: "Locked set",
                targetChildID: UUID(),
                unlockSources: unlockSources
            ),
            durationMinutes: nil,
            issuedAt: Date()
        )
    }

    @MainActor
    private func observeInvalidation(_ body: () -> Void) -> Bool {
        var fired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .bigKidStateInvalidated, object: nil, queue: nil
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return fired
    }

    @MainActor
    func test_taskPauseUnshieldConfirmedExact_postsStateInvalidated() {
        let cmd = makeCommand(unlockSources: ["task_pause"])
        let result = AckResult.confirmedExact(verb: .unshield, displayName: "Locked set", effectiveState: nil)

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertTrue(fired, "A confirmed task_pause unshield must trigger an immediate state refresh")
    }

    @MainActor
    func test_taskPauseUnshieldConfirmedFallback_postsStateInvalidated() {
        let cmd = makeCommand(unlockSources: ["task_pause"])
        let result = AckResult.confirmedFallback(
            verb: .unshield, displayName: "Locked set", category: "games",
            origRequest: "tasks complete", effectiveState: nil
        )

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertTrue(fired, "A confirmed-fallback task_pause unshield must also trigger a refresh")
    }

    @MainActor
    func test_nonTaskPauseUnshield_doesNotPostStateInvalidated() {
        // Manual unlock — unlock_sources doesn't include task_pause.
        let cmd = makeCommand(unlockSources: ["manual"])
        let result = AckResult.confirmedExact(verb: .unshield, displayName: "Locked set", effectiveState: nil)

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertFalse(fired, "Non task_pause unlock sources must stay on the normal poll cadence")
    }

    @MainActor
    func test_taskPauseShield_doesNotPostStateInvalidated() {
        // A shield (not unshield) command should never trigger this seam,
        // even if unlock_sources happened to be non-nil.
        let cmd = makeCommand(unlockSources: ["task_pause"])
        let result = AckResult.confirmedExact(verb: .shield, displayName: "Locked set", effectiveState: nil)

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertFalse(fired, "Only the unshield verb should trigger the instant re-arm refresh")
    }

    @MainActor
    func test_taskPauseUnshieldFailed_doesNotPostStateInvalidated() {
        let cmd = makeCommand(unlockSources: ["task_pause"])
        let result = AckResult.failed(.nothingToUnlock)

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertFalse(fired, "A failed unshield never re-arms — nothing actually unlocked")
    }

    @MainActor
    func test_taskPauseUnshieldPendingConfirmation_doesNotPostStateInvalidated() {
        let cmd = makeCommand(unlockSources: ["task_pause"])
        let result = AckResult.pendingConfirmation(cardID: "card-1", context: [:])

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertFalse(fired, "A pending-confirmation result hasn't unlocked anything yet")
    }

    @MainActor
    func test_nilUnlockSources_doesNotPostStateInvalidated() {
        let cmd = makeCommand(unlockSources: nil)
        let result = AckResult.confirmedExact(verb: .unshield, displayName: "Locked set", effectiveState: nil)

        let fired = observeInvalidation {
            CommandPoller.notifyStateInvalidatedIfTaskPauseUnshield(cmd: cmd, result: result)
        }
        XCTAssertFalse(fired, "nil unlock_sources (e.g. unshield_all) must not trigger this seam")
    }
}
