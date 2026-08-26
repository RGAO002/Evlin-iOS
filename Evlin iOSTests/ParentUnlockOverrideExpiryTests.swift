import DeviceActivity
import Foundation
import XCTest
@testable import Evlin_iOS

final class ParentUnlockOverrideExpiryTests: XCTestCase {
    private let ownerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let otherOwnerID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let operationID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
    private let startedAt = Date(timeIntervalSince1970: 1_777_255_200)
    private let expiresAt = Date(timeIntervalSince1970: 1_777_258_800)

    func testReducerArmsPersistedDeadlineAndReplacesStaleRevision() {
        let staleName = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 6
        )

        let reduction = ParentUnlockOverrideExpiry.reduce(
            snapshot: snapshot(revision: 7),
            now: startedAt.addingTimeInterval(60),
            expectedOwner: ownerID,
            monitoredActivityNames: [staleName]
        )

        guard case let .arm(plan, replacing) = reduction else {
            return XCTFail("expected arm decision, got \(reduction)")
        }
        XCTAssertEqual(plan.ownerID, ownerID)
        XCTAssertEqual(plan.revision, 7)
        XCTAssertEqual(plan.deadline, expiresAt)
        XCTAssertEqual(
            plan.activityName,
            ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7)
        )
        XCTAssertEqual(replacing, [staleName])
    }

    func testReducerDisarmsSnapshotOwnedByAnotherIdentity() {
        let staleName = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )

        let reduction = ParentUnlockOverrideExpiry.reduce(
            snapshot: snapshot(revision: 7),
            now: startedAt,
            expectedOwner: otherOwnerID,
            monitoredActivityNames: [staleName]
        )

        XCTAssertEqual(reduction, .disarm(activityNames: [staleName]))
    }

    func testReducerDisarmsCancelledSnapshot() {
        let name = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )

        let reduction = ParentUnlockOverrideExpiry.reduce(
            snapshot: snapshot(revision: 7, status: .cancelled, cancelled: true),
            now: startedAt,
            expectedOwner: ownerID,
            monitoredActivityNames: [name]
        )

        XCTAssertEqual(reduction, .disarm(activityNames: [name]))
    }

    func testReducerExpiresAtHalfOpenDeadline() {
        let name = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )

        let beforeDeadline = ParentUnlockOverrideExpiry.reduce(
            snapshot: snapshot(revision: 7),
            now: expiresAt.addingTimeInterval(-1),
            expectedOwner: ownerID,
            monitoredActivityNames: [name]
        )
        let atDeadline = ParentUnlockOverrideExpiry.reduce(
            snapshot: snapshot(revision: 7),
            now: expiresAt,
            expectedOwner: ownerID,
            monitoredActivityNames: [name]
        )

        XCTAssertEqual(beforeDeadline, .unchanged)
        XCTAssertEqual(
            atDeadline,
            .expire(revision: 7, activityNames: [name])
        )
    }

    func testExpiryActivityUsesResolvedServerDeadline() async throws {
        let scheduler = ParentUnlockExpirySchedulerSpy()
        let staleName = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 6
        )
        scheduler.seed(staleName)
        let calendar = utcCalendar()

        let result = try await ParentUnlockOverrideExpiry.arm(
            snapshot: snapshot(revision: 7),
            now: startedAt.addingTimeInterval(60),
            scheduler: scheduler,
            calendar: calendar
        )

        XCTAssertEqual(result, .armed(revision: 7, deadline: expiresAt))
        XCTAssertEqual(scheduler.stoppedNames, [[staleName]])
        XCTAssertEqual(scheduler.startedWithEventsCount, 0)
        let started = try XCTUnwrap(scheduler.startedWithoutEvents.first)
        XCTAssertEqual(
            started.name,
            ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7)
        )
        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute, .second], from: expiresAt),
            started.schedule.intervalEnd
        )
    }

    func testReconcileRearmsPersistedDeadlineAfterRestart() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 7),
            expectedOwner: ownerID,
            now: startedAt
        )
        let restartedStore = ParentUnlockOverrideStore(fileURL: harness.fileURL)
        let scheduler = ParentUnlockExpirySchedulerSpy()
        let calendar = utcCalendar()

        let result = try await ParentUnlockOverrideExpiry.reconcile(
            now: startedAt.addingTimeInterval(300),
            expectedOwner: ownerID,
            store: restartedStore,
            scheduler: scheduler,
            calendar: calendar
        )

        XCTAssertEqual(result, .armed(revision: 7, deadline: expiresAt))
        let started = try XCTUnwrap(scheduler.startedWithoutEvents.first)
        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute, .second], from: expiresAt),
            started.schedule.intervalEnd
        )
        XCTAssertEqual(try restartedStore.read(expectedOwner: ownerID)?.status, .active)
    }

    func testReconcileExpiresPersistedSnapshotOnce() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 7),
            expectedOwner: ownerID,
            now: startedAt
        )
        let scheduler = ParentUnlockExpirySchedulerSpy()
        let activityName = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )
        scheduler.seed(activityName)

        let first = try await ParentUnlockOverrideExpiry.reconcile(
            now: expiresAt,
            expectedOwner: ownerID,
            store: harness.store,
            scheduler: scheduler,
            calendar: utcCalendar()
        )
        let persistedAfterFirst = try Data(contentsOf: harness.fileURL)
        let second = try await ParentUnlockOverrideExpiry.reconcile(
            now: expiresAt.addingTimeInterval(60),
            expectedOwner: ownerID,
            store: harness.store,
            scheduler: scheduler,
            calendar: utcCalendar()
        )

        XCTAssertEqual(first, .expired(revision: 7))
        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.status, .expired)
        XCTAssertEqual(try Data(contentsOf: harness.fileURL), persistedAfterFirst)
        XCTAssertEqual(scheduler.stoppedNames, [[activityName]])
        XCTAssertTrue(scheduler.startedWithoutEvents.isEmpty)
    }

    func testReconcileDoesNotAdoptPersistedSnapshotFromAnotherOwner() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 7),
            expectedOwner: ownerID,
            now: startedAt
        )
        let scheduler = ParentUnlockExpirySchedulerSpy()
        let oldName = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )
        scheduler.seed(oldName)

        let result = try await ParentUnlockOverrideExpiry.reconcile(
            now: startedAt.addingTimeInterval(60),
            expectedOwner: otherOwnerID,
            store: harness.store,
            scheduler: scheduler,
            calendar: utcCalendar()
        )

        XCTAssertEqual(result, .ownerMismatch)
        XCTAssertEqual(scheduler.stoppedNames, [[oldName]])
        XCTAssertTrue(scheduler.startedWithoutEvents.isEmpty)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.status, .active)
    }

    func testExpiryReconcilerIsIdempotentAcrossDAMAndForeground() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 7),
            expectedOwner: ownerID,
            now: startedAt
        )
        let scheduler = ParentUnlockExpirySchedulerSpy()
        scheduler.seed(ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7))
        let projection = ExpiryProjectionRecorder()

        let dam = try await ParentUnlockOverrideExpiry.reconcileAndProject(
            now: expiresAt,
            expectedOwner: ownerID,
            store: harness.store,
            scheduler: scheduler,
            calendar: utcCalendar()
        ) {
            await projection.record()
        }
        let foreground = try await ParentUnlockOverrideExpiry.reconcileAndProject(
            now: expiresAt.addingTimeInterval(30),
            expectedOwner: ownerID,
            store: harness.store,
            scheduler: scheduler,
            calendar: utcCalendar()
        ) {
            await projection.record()
        }

        XCTAssertEqual(dam, .expired(revision: 7))
        XCTAssertEqual(foreground, .unchanged)
        let projectionCount = await projection.count
        XCTAssertEqual(projectionCount, 1)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.status, .expired)
    }

    func testForceQuitPathExpiresAndReappliesLatestRules() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 7),
            expectedOwner: ownerID,
            now: startedAt
        )
        let scheduler = ParentUnlockExpirySchedulerSpy()
        scheduler.seed(ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7))
        let projection = ExpiryProjectionRecorder()

        let result = try await ParentUnlockOverrideExpiry.reconcileAndProject(
            now: expiresAt,
            expectedOwner: ownerID,
            store: harness.store,
            scheduler: scheduler,
            calendar: utcCalendar()
        ) {
            let status = try? harness.store.read(expectedOwner: self.ownerID)?.status
            await projection.record(status: status)
        }

        XCTAssertEqual(result, .expired(revision: 7))
        let projectedStatuses = await projection.statuses
        XCTAssertEqual(projectedStatuses, [.expired])
        XCTAssertEqual(
            scheduler.stoppedNames,
            [[ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7)]]
        )
    }

    func testDAMExpiryCallbackCommitsLocallyWithoutConsultingScheduler() throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 7),
            expectedOwner: ownerID,
            now: startedAt
        )
        let activityName = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )

        let result = try ParentUnlockOverrideExpiry.expireFromActivityCallback(
            activityName: activityName,
            now: expiresAt,
            expectedOwner: ownerID,
            store: harness.store
        )

        XCTAssertEqual(result, .expired(revision: 7))
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.status, .expired)
    }

    func testLateDAMExpiryCallbackCannotExpireNewerOverrideRevision() throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(
            envelope(revision: 8),
            expectedOwner: ownerID,
            now: startedAt
        )
        let staleActivity = ParentUnlockOverrideExpiry.activityName(
            ownerID: ownerID,
            revision: 7
        )

        let result = try ParentUnlockOverrideExpiry.expireFromActivityCallback(
            activityName: staleActivity,
            now: expiresAt,
            expectedOwner: ownerID,
            store: harness.store
        )

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.status, .active)
        XCTAssertEqual(try harness.store.read(expectedOwner: ownerID)?.revision, 8)
    }

    private func snapshot(
        revision: Int64,
        status: ParentUnlockOverrideSnapshot.Status = .active,
        cancelled: Bool = false
    ) -> ParentUnlockOverrideSnapshot {
        ParentUnlockOverrideSnapshot(
            envelope: envelope(revision: revision, cancelled: cancelled),
            status: status
        )
    }

    private func envelope(
        revision: Int64,
        cancelled: Bool = false
    ) -> ParentUnlockOverrideEnvelope {
        ParentUnlockOverrideEnvelope(
            revision: revision,
            childDeviceID: ownerID,
            usageDate: "2026-04-26",
            startedAt: startedAt,
            expiresAt: expiresAt,
            operationID: operationID,
            scopes: [.manual, .earnedTime, .taskPause, .deviceLimit, .perAppLimit],
            cancelled: cancelled
        )
    }

    private func makeHarness() throws -> (store: ParentUnlockOverrideStore, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parent-unlock-expiry-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("override.json")
        return (ParentUnlockOverrideStore(fileURL: fileURL), fileURL)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private actor ExpiryProjectionRecorder {
    private(set) var count = 0
    private(set) var statuses: [ParentUnlockOverrideSnapshot.Status] = []

    func record(status: ParentUnlockOverrideSnapshot.Status? = nil) {
        count += 1
        if let status {
            statuses.append(status)
        }
    }
}

private final class ParentUnlockExpirySchedulerSpy: DeviceActivityScheduling {
    private(set) var startedWithoutEvents: [(
        name: String,
        schedule: DeviceActivitySchedule
    )] = []
    private(set) var startedWithEventsCount = 0
    private(set) var stoppedNames: [[String]] = []
    private var active: Set<DeviceActivityName> = []

    func seed(_ activityName: String) {
        active.insert(DeviceActivityName(activityName))
    }

    func startMonitoring(
        _ name: DeviceActivityName,
        during schedule: DeviceActivitySchedule
    ) throws {
        startedWithoutEvents.append((name.rawValue, schedule))
        active.insert(name)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startedWithEventsCount += 1
        active.insert(activity)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stoppedNames.append(activities.map(\.rawValue).sorted())
        active.subtract(activities)
    }

    func stopMonitoring() {
        stoppedNames.append(active.map(\.rawValue).sorted())
        active.removeAll()
    }

    func monitoredActivities() -> [DeviceActivityName] {
        Array(active)
    }
}
