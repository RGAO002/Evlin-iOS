import XCTest

@testable import Evlin_iOS

/// Identity adoption state machine. Plan Task 3 / Task 12.
final class AdoptionExecutorTests: XCTestCase {

    /// Records which hooks fired, in order, and can fail one of them on demand.
    private final class HookTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []

        var calls: [String] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func hooks(failAt: String? = nil) -> AdoptionHooks {
            let record: @Sendable (String) throws -> Void = { name in
                self.lock.lock()
                self._calls.append(name)
                self.lock.unlock()
                if name == failAt {
                    throw NSError(domain: "hook", code: 1)
                }
            }
            return AdoptionHooks(
                finishExistingCleanup: { try record("finish") },
                convergeLocalMachinery: { try record("converge") },
                rebaseFromServerLedger: { try record("rebase") },
                prepareIdentityCleanup: { _, _ in try record("prepare") },
                teardownAndAwaitAck: { try record("teardown") },
                writeIdentity: { _ in try record("write") },
                bootstrap: { try record("bootstrap") }
            )
        }
    }

    private func makeStore() throws -> PendingAdoptionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return PendingAdoptionStore(directoryURL: dir)
    }

    private func commitResult(deviceID: UUID) -> PairingCommitResult {
        PairingCommitResult(
            familyID: UUID(),
            childDeviceID: deviceID,
            childProfileID: UUID(),
            mode: "invited",
            deviceCredential: .init(scheme: "x-child-id-v1",
                                    childDeviceID: deviceID)
        )
    }

    private func record(
        choice: AdoptionChoice,
        old: UUID?,
        new: UUID,
        phase: PendingAdoptionPhase,
        withResult: Bool = true
    ) -> PendingAdoptionRecord {
        PendingAdoptionRecord(
            inviteID: UUID(),
            resolveSession: "rs",
            choice: choice,
            result: withResult ? commitResult(deviceID: new) : nil,
            oldUUID: old,
            phase: phase
        )
    }

    // MARK: - Planning

    func test_planner_sameOwnerRestores_differentOwnerSwitches() {
        let owner = UUID()
        XCTAssertEqual(AdoptionPlanner.plan(oldUUID: owner, newUUID: owner),
                       .restoreConverge)
        XCTAssertEqual(AdoptionPlanner.plan(oldUUID: UUID(), newUUID: owner),
                       .identitySwitch)
        XCTAssertEqual(AdoptionPlanner.plan(oldUUID: nil, newUUID: owner),
                       .identitySwitch)
    }

    // MARK: - Execution

    func test_restorePath_convergesAndRebases_withoutTearingAnythingDown() async throws {
        let store = try makeStore()
        let trace = HookTrace()
        let owner = UUID()
        let rec = record(choice: .restore, old: owner, new: owner,
                         phase: .converging)
        try store.save(rec)

        try await AdoptionExecutor(store: store, hooks: trace.hooks())
            .run(record: rec)

        XCTAssertEqual(trace.calls, ["finish", "converge", "rebase", "bootstrap"])
        XCTAssertNil(store.load())
    }

    func test_switchPath_tearsDownBeforeWritingTheNewIdentity() async throws {
        let store = try makeStore()
        let trace = HookTrace()
        let rec = record(choice: .invited, old: UUID(), new: UUID(),
                         phase: .cleanupPrepared)
        try store.save(rec)

        try await AdoptionExecutor(store: store, hooks: trace.hooks())
            .run(record: rec)

        XCTAssertEqual(trace.calls,
                       ["prepare", "teardown", "write", "bootstrap"])
        XCTAssertNil(store.load())
    }

    func test_crashAfterIdentityWritten_resumesWithBootstrapOnly() async throws {
        let store = try makeStore()
        let rec = record(choice: .invited, old: UUID(), new: UUID(),
                         phase: .cleanupPrepared)
        try store.save(rec)

        // First pass dies during bootstrap, after the identity is on disk.
        let first = HookTrace()
        try? await AdoptionExecutor(store: store,
                                    hooks: first.hooks(failAt: "bootstrap"))
            .run(record: rec)
        XCTAssertEqual(store.load()?.phase, .identityWritten)

        // Relaunch: only the missing leg runs — repeating the teardown here
        // would dismantle the identity that was just adopted.
        let second = HookTrace()
        let resumed = try XCTUnwrap(store.load())
        try await AdoptionExecutor(store: store, hooks: second.hooks())
            .run(record: resumed)
        XCTAssertEqual(second.calls, ["bootstrap"])
        XCTAssertNil(store.load())
    }

    // MARK: - Launch-time resume

    func test_resume_withNoRecordTouchesNothing() async throws {
        let store = try makeStore()
        let trace = HookTrace()
        nonisolated(unsafe) var replayed = false

        await AdoptionResumer(
            store: store,
            replay: { _ in
                replayed = true
                throw NSError(domain: "unused", code: 0)
            },
            execute: { rec in
                try await AdoptionExecutor(store: store, hooks: trace.hooks())
                    .run(record: rec)
            }
        ).resumeIfPending()

        XCTAssertFalse(replayed)
        XCTAssertEqual(trace.calls, [])
    }

    func test_resume_replaysCommitBeforeAnyHookAndPersistsResult() async throws {
        let store = try makeStore()
        let newID = UUID()
        let rec = record(choice: .invited, old: UUID(), new: newID,
                         phase: .committing, withResult: false)
        try store.save(rec)

        nonisolated(unsafe) var order: [String] = []
        let result = commitResult(deviceID: newID)

        await AdoptionResumer(
            store: store,
            replay: { _ in
                order.append("replay")
                return result
            },
            execute: { got in
                order.append("execute")
                // The record handed to the state machine already carries the
                // recovered result.
                XCTAssertEqual(got.result?.childDeviceID, newID)
            }
        ).resumeIfPending()

        XCTAssertEqual(order, ["replay", "execute"])
        XCTAssertEqual(store.load()?.result?.childDeviceID, newID)
    }

    func test_resume_whenReplayFailsNothingRunsAndTheRecordSurvives() async throws {
        let store = try makeStore()
        let rec = record(choice: .invited, old: UUID(), new: UUID(),
                         phase: .committing, withResult: false)
        try store.save(rec)
        let before = store.load()

        nonisolated(unsafe) var executed = false
        await AdoptionResumer(
            store: store,
            replay: { _ in throw URLError(.notConnectedToInternet) },
            execute: { _ in executed = true }
        ).resumeIfPending()

        XCTAssertFalse(executed)
        XCTAssertEqual(store.load(), before)
    }
}
