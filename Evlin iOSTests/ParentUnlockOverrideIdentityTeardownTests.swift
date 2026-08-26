import DeviceActivity
import Foundation
import XCTest
@testable import Evlin_iOS

final class ParentUnlockOverrideIdentityTeardownTests: XCTestCase {
    private let ownerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let startedAt = Date(timeIntervalSince1970: 1_777_255_200)
    private let expiresAt = Date(timeIntervalSince1970: 1_777_258_800)

    func testUnpairClearsOverrideMirrorAndActivity() async throws {
        try await assertIdentityTeardownClearsOverride()
    }

    func testAccountDeletionClearsOverrideMirrorAndActivity() async throws {
        try await assertIdentityTeardownClearsOverride()
    }

    func testChildSignOutClearsOverrideMirrorAndActivity() async throws {
        try await assertIdentityTeardownClearsOverride()
    }

    func testCrossFamilyRepairDoesNotAdoptOldOverride() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(envelope(), expectedOwner: ownerID, now: startedAt)
        let scheduler = ParentUnlockIdentitySchedulerSpy()
        let activityName = ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7)
        scheduler.seed(activityName)

        try await ParentUnlockOverrideExpiry.clearForIdentityTeardown(
            store: harness.store,
            scheduler: scheduler
        )

        XCTAssertNil(try harness.store.read(expectedOwner: ownerID))
        XCTAssertEqual(scheduler.stoppedNames, [[activityName]])
    }

    private func assertIdentityTeardownClearsOverride() async throws {
        let harness = try makeHarness()
        _ = try harness.store.ingest(envelope(), expectedOwner: ownerID, now: startedAt)
        let scheduler = ParentUnlockIdentitySchedulerSpy()
        let activityName = ParentUnlockOverrideExpiry.activityName(ownerID: ownerID, revision: 7)
        scheduler.seed(activityName)

        try await ParentUnlockOverrideExpiry.clearForIdentityTeardown(
            store: harness.store,
            scheduler: scheduler
        )

        XCTAssertNil(try harness.store.read(expectedOwner: ownerID))
        XCTAssertEqual(scheduler.stoppedNames, [[activityName]])
    }

    private func envelope() -> ParentUnlockOverrideEnvelope {
        ParentUnlockOverrideEnvelope(
            revision: 7,
            childDeviceID: ownerID,
            usageDate: "2026-04-26",
            startedAt: startedAt,
            expiresAt: expiresAt,
            operationID: UUID(),
            scopes: [.manual, .earnedTime, .taskPause, .deviceLimit, .perAppLimit],
            cancelled: false
        )
    }

    private func makeHarness() throws -> (store: ParentUnlockOverrideStore, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parent-unlock-identity-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("override.json")
        return (ParentUnlockOverrideStore(fileURL: fileURL), fileURL)
    }
}

private final class ParentUnlockIdentitySchedulerSpy: DeviceActivityScheduling {
    private var active: Set<DeviceActivityName> = []
    private(set) var stoppedNames: [[String]] = []

    func seed(_ activityName: String) {
        active.insert(DeviceActivityName(activityName))
    }

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        active.insert(name)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
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
