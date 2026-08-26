import Foundation
import XCTest
@testable import Evlin_iOS

final class ParentUnlockOverrideStoreTests: XCTestCase {
    private let ownerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let otherOwnerID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let operationID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000004")!
    private let startedAt = Date(timeIntervalSince1970: 1_777_255_200)
    private let expiresAt = Date(timeIntervalSince1970: 1_777_258_800)

    func testNewerRevisionPersistsBeforeApplyReturns() throws {
        let harness = try makeHarness()
        var enforcementCallbacks = 0

        let disposition = try harness.store.ingest(
            envelope(revision: 4),
            expectedOwner: ownerID,
            now: startedAt
        )
        let restarted = ParentUnlockOverrideStore(fileURL: harness.fileURL)
        let committed = try XCTUnwrap(restarted.read(expectedOwner: ownerID))

        XCTAssertEqual(disposition, .applied)
        XCTAssertEqual(committed.revision, 4)
        XCTAssertEqual(enforcementCallbacks, 0)
        enforcementCallbacks += 1
    }

    func testEqualRevisionIsIdempotentReplay() throws {
        let harness = try makeHarness()
        let value = envelope(revision: 4)
        _ = try harness.store.ingest(value, expectedOwner: ownerID, now: startedAt)
        let committedBytes = try Data(contentsOf: harness.fileURL)

        let disposition = try harness.store.ingest(
            value,
            expectedOwner: ownerID,
            now: startedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(disposition, .replayed)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), committedBytes)
    }

    func testOlderRevisionIsSuperseded() throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 4),
            expectedOwner: ownerID,
            now: startedAt
        )
        let committedBytes = try Data(contentsOf: harness.fileURL)

        let disposition = try harness.store.ingest(
            envelope(revision: 3),
            expectedOwner: ownerID,
            now: startedAt
        )

        XCTAssertEqual(disposition, .superseded(currentRevision: 4))
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), committedBytes)
    }

    func testWrongOwnerIsRejectedWithoutMutation() throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 4),
            expectedOwner: ownerID,
            now: startedAt
        )
        let committedBytes = try Data(contentsOf: harness.fileURL)

        let disposition = try harness.store.ingest(
            envelope(revision: 5, childDeviceID: otherOwnerID),
            expectedOwner: ownerID,
            now: startedAt
        )

        XCTAssertEqual(disposition, .rejectedIdentity)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), committedBytes)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.revision, 4)
    }

    func testExpiredSnapshotIsNotActive() throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 4),
            expectedOwner: ownerID,
            now: expiresAt.addingTimeInterval(1)
        )

        let snapshot = try XCTUnwrap(harness.store.read(expectedOwner: ownerID))

        XCTAssertEqual(snapshot.status, .expired)
        XCTAssertFalse(snapshot.isActive(at: expiresAt.addingTimeInterval(1)))
    }

    func testTornOrInvalidFileDoesNotReplaceLastGoodState() throws {
        let fileIO = OneShotCorruptingOverrideFileIO()
        let harness = try makeHarness(fileIO: fileIO)
        _ = try harness.store.ingest(
            envelope(revision: 4),
            expectedOwner: ownerID,
            now: startedAt
        )
        fileIO.corruptNextWrite()

        XCTAssertThrowsError(
            try harness.store.ingest(
                envelope(revision: 5),
                expectedOwner: ownerID,
                now: startedAt
            )
        ) { error in
            XCTAssertEqual(error as? ParentUnlockOverrideStoreError, .readbackMismatch)
        }

        let restarted = ParentUnlockOverrideStore(
            fileURL: harness.fileURL,
            fileIO: fileIO
        )
        XCTAssertEqual(try restarted.read(expectedOwner: ownerID)?.revision, 4)
    }

    func testExpireIfNeededPersistsOfflineExpiration() throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 4),
            expectedOwner: ownerID,
            now: startedAt
        )

        XCTAssertTrue(
            try harness.store.expireIfNeeded(
                expectedOwner: ownerID,
                now: expiresAt
            )
        )

        let restarted = ParentUnlockOverrideStore(fileURL: harness.fileURL)
        let snapshot = try XCTUnwrap(restarted.read(expectedOwner: ownerID))
        XCTAssertEqual(snapshot.status, .expired)
        XCTAssertFalse(snapshot.isActive(at: expiresAt))
    }

    private func envelope(
        revision: Int64,
        childDeviceID: UUID? = nil
    ) -> ParentUnlockOverrideEnvelope {
        ParentUnlockOverrideEnvelope(
            revision: revision,
            childDeviceID: childDeviceID ?? ownerID,
            usageDate: "2026-04-26",
            startedAt: startedAt,
            expiresAt: expiresAt,
            operationID: operationID,
            scopes: [.manual, .earnedTime, .taskPause, .deviceLimit, .perAppLimit],
            cancelled: false
        )
    }

    private func makeHarness(
        fileIO: any DeviceEpochFileIO = DurableAppLimitEpochFileIO()
    ) throws -> (store: ParentUnlockOverrideStore, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parent-unlock-override-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("override.json")
        return (
            ParentUnlockOverrideStore(fileURL: fileURL, fileIO: fileIO),
            fileURL
        )
    }
}

private final class OneShotCorruptingOverrideFileIO: DeviceEpochFileIO, @unchecked Sendable {
    private let underlying = DurableAppLimitEpochFileIO()
    private let lock = NSLock()
    private var shouldCorruptNextWrite = false

    func corruptNextWrite() {
        lock.lock()
        shouldCorruptNextWrite = true
        lock.unlock()
    }

    func read(from url: URL) throws -> Data? {
        try underlying.read(from: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        let corrupt = shouldCorruptNextWrite
        shouldCorruptNextWrite = false
        lock.unlock()
        try underlying.writeAtomically(corrupt ? Data("{torn".utf8) : data, to: url)
    }

    func remove(at url: URL) throws {
        try underlying.remove(at: url)
    }
}
