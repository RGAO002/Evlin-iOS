import Foundation
import XCTest
@testable import Evlin_iOS

final class AppLimitCommandCoordinatorTests: XCTestCase {
    private var directoryURL: URL!
    private var fileURL: URL!
    private var epochLock: CoordinatorTestLock!
    private let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000008")!
    private let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000008")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-limit-command-coordinator-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("app-limit-epoch.json")
        epochLock = CoordinatorTestLock()
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try super.tearDownWithError()
    }

    func testP4V01_newerSetPersistsActiveRuleAndOneOwnerWork() throws {
        let disposition = try makeCoordinator().ingest(set(token: 10))

        XCTAssertEqual(disposition, .acceptedNeedsOwner)
        let slot = try XCTUnwrap(try makeStore().read().slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, 10)
        XCTAssertEqual(slot.latestKind, .set)
        XCTAssertEqual(slot.activeRule, rule())
        XCTAssertNil(slot.clearTombstone)
        XCTAssertEqual(slot.pendingOwnerWork?.commandKind, .set)
        XCTAssertEqual(slot.pendingOwnerWork?.orderingToken, 10)
        XCTAssertNil(slot.appliedReceipt)
    }

    func testP4V02_lowerTokenIsSupersededWithoutByteMutation() throws {
        _ = try makeCoordinator().ingest(set(token: 10))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try makeCoordinator().ingest(set(token: 9)), .superseded(latestOrderingToken: 10))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testP4V03_newerClearRemovesRuleAndPersistsTombstoneAndOneOwnerWork() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(set(token: 10))

        XCTAssertEqual(try coordinator.ingest(clear(token: 11)), .acceptedNeedsOwner)
        let slot = try XCTUnwrap(try makeStore().read().slots[ruleID])
        XCTAssertEqual(slot.latestOrderingToken, 11)
        XCTAssertEqual(slot.latestKind, .clear)
        XCTAssertNil(slot.activeRule)
        XCTAssertEqual(slot.clearTombstone?.orderingToken, 11)
        XCTAssertEqual(slot.clearTombstone?.payloadDigest, "clear-11")
        XCTAssertEqual(slot.pendingOwnerWork?.commandKind, .clear)
        XCTAssertEqual(slot.pendingOwnerWork?.orderingToken, 11)
        XCTAssertNil(slot.appliedReceipt)
    }

    func testP4V04_oldSetAfterClearIsSupersededWithoutResurrectionOrByteMutation() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(set(token: 10))
        _ = try coordinator.ingest(clear(token: 11))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try coordinator.ingest(set(token: 10)), .superseded(latestOrderingToken: 11))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertNil(try makeStore().read().slots[ruleID]?.activeRule)
    }

    func testP4V05_equalAppliedSetReturnsExistingReceiptWithoutByteMutation() throws {
        let receipt = try applyReceipt(for: set(token: 10))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try makeCoordinator().ingest(set(token: 10)), .duplicateApplied(receipt))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testP4V06_equalAppliedClearReturnsExistingReceiptWithoutByteMutation() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(set(token: 10))
        let receipt = try applyReceipt(for: clear(token: 11))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try makeCoordinator().ingest(clear(token: 11)), .duplicateApplied(receipt))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testP4V07_equalPendingCommandRemainsPendingWithoutAdditionalOwnerWork() throws {
        let command = set(token: 10)
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(command)
        let before = try makeStore().read()
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try coordinator.ingest(command), .duplicatePending)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertEqual(try makeStore().read(), before)
    }

    func testP4V08_equalTokenWithDifferentDigestFailsClosedWithoutByteMutation() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(set(token: 10))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try coordinator.ingest(set(token: 10, digest: "different")), .equalTokenConflict)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testEqualTokenWithDifferentKindFailsClosedWithoutByteMutation() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.ingest(set(token: 10))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try coordinator.ingest(clear(token: 10, digest: "set-10")), .equalTokenConflict)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testAllSixPermutationsConvergeAfterOldSetNewClearAndEqualClear() throws {
        let commands = [set(token: 10), clear(token: 11), clear(token: 11)]
        let permutations = [
            [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ]

        for indices in permutations {
            try resetStore()
            for index in indices {
                _ = try makeCoordinator().ingest(commands[index])
            }
            let slot = try XCTUnwrap(try makeStore().read().slots[ruleID])
            XCTAssertEqual(slot.latestOrderingToken, 11)
            XCTAssertEqual(slot.latestKind, .clear)
            XCTAssertNil(slot.activeRule)
            XCTAssertEqual(slot.clearTombstone?.orderingToken, 11)
        }
    }

    func testRestartBetweenCommandsPreservesClearTombstoneAndRejectsOldSet() throws {
        _ = try makeCoordinator().ingest(set(token: 10))
        _ = try makeCoordinator().ingest(clear(token: 11))
        let bytes = try Data(contentsOf: fileURL)

        XCTAssertEqual(try makeCoordinator().ingest(set(token: 10)), .superseded(latestOrderingToken: 11))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOwnerMismatchPropagatesFromEpochStoreWithoutByteMutation() throws {
        _ = try makeCoordinator().ingest(set(token: 10))
        let bytes = try Data(contentsOf: fileURL)
        let differentOwner = UUID(uuidString: "20000000-0000-0000-0000-000000000009")!
        let coordinator = AppLimitCommandCoordinator(
            store: makeStore(owner: differentOwner),
            expectedOwnerProvider: { differentOwner }
        )

        XCTAssertThrowsError(try coordinator.ingest(clear(token: 11))) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    private func makeStore(owner: UUID? = nil) -> AppLimitEpochStore {
        let resolvedOwner = owner ?? self.owner
        return AppLimitEpochStore(
            fileURL: fileURL,
            lock: epochLock,
            ownerProvider: { resolvedOwner },
            legacyDefaults: nil
        )
    }

    private func makeCoordinator() -> AppLimitCommandCoordinator {
        let owner = self.owner
        return AppLimitCommandCoordinator(
            store: makeStore(),
            expectedOwnerProvider: { owner }
        )
    }

    private func resetStore() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func applyReceipt(for command: AppLimitCommandEnvelope) throws -> AppLimitApplyReceipt {
        _ = try makeCoordinator().ingest(command)
        let receipt = AppLimitApplyReceipt(
            ruleID: ruleID,
            orderingToken: command.orderingToken,
            commandKind: command.kind,
            armID: nil,
            source: "test",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_200),
            storeRevision: 1
        )
        _ = try makeStore().transaction(source: .wakeRecovery, expectedOwner: owner) { state in
            var slot = try XCTUnwrap(state.slots[ruleID])
            slot.pendingOwnerWork = nil
            slot.appliedReceipt = receipt
            state.slots[ruleID] = slot
        }
        return receipt
    }

    private func set(token: Int64, digest: String? = nil) -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: UUID(uuidString: "30000000-0000-0000-0000-000000000008")!,
            ruleID: ruleID,
            orderingToken: token,
            kind: .set,
            payloadDigest: digest ?? "set-\(token)",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .poll,
            rule: rule()
        )
    }

    private func clear(token: Int64, digest: String? = nil) -> AppLimitCommandEnvelope {
        AppLimitCommandEnvelope(
            commandID: UUID(uuidString: "30000000-0000-0000-0000-000000000009")!,
            ruleID: ruleID,
            orderingToken: token,
            kind: .clear,
            payloadDigest: digest ?? "clear-\(token)",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .notificationServiceExtension,
            rule: nil
        )
    }

    private func rule() -> AppLimitRule {
        AppLimitRule(
            id: ruleID,
            appTokens: [],
            bundleID: "com.example.focus",
            displayName: "Focus",
            budgetMinutes: 30,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
    }
}

private final class CoordinatorTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
