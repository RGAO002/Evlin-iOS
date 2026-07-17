import Foundation
import XCTest
@testable import Evlin_iOS

final class DeviceEpochStoreMigrationTests: XCTestCase {
    private let owner = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testLegacyLifecycleMigratesExactlyWithoutDeletingLegacyKeys() throws {
        let defaults = UserDefaults(suiteName: MeteringOwnerMirror.suiteName)!
        let legacyKeys = [
            EarnedActivityGeneration.lifecycleKey,
            EarnedActivityGeneration.lifecycleBreadcrumbsKey,
            EarnedActivityGeneration.activeActivityNameKey,
        ]
        legacyKeys.forEach(defaults.removeObject(forKey:))
        defer { legacyKeys.forEach(defaults.removeObject(forKey:)) }

        let active = EarnedActivityGeneration.Generation(
            activityName: "evlin.earned.budget.active",
            deviceID: owner.uuidString,
            offsetMinutes: 10,
            armSignature: "active-signature",
            usageDate: "2026-07-17",
            timezoneIdentifier: "America/New_York",
            armedAt: Date(timeIntervalSince1970: 10)
        )
        let pending = EarnedActivityGeneration.Generation(
            activityName: "evlin.earned.budget.pending",
            deviceID: owner.uuidString,
            offsetMinutes: 15,
            armSignature: "pending-signature",
            usageDate: "2026-07-17",
            timezoneIdentifier: "America/New_York",
            armedAt: Date(timeIntervalSince1970: 20)
        )
        let lifecycle = EarnedActivityGeneration.Lifecycle(
            version: 2,
            active: active,
            pending: pending,
            retiringActivityNames: ["evlin.earned.budget.retiring"],
            isStopped: false
        )
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(lifecycle, defaults: defaults))
        defaults.set(["evlin.earned.budget.breadcrumb"], forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey)
        defaults.set(active.activityName, forKey: EarnedActivityGeneration.activeActivityNameKey)
        let lifecycleBytes = defaults.data(forKey: EarnedActivityGeneration.lifecycleKey)
        let breadcrumbs = defaults.stringArray(forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey)

        let io = MigrationFileIO()
        let store = DeviceEpochStore(
            fileURL: URL(fileURLWithPath: "/tmp/evlin-device-epoch-store-migration.json"),
            lock: MigrationLock(),
            fileIO: io,
            ownerProvider: { self.owner }
        )

        try store.transaction(expectedOwner: owner) { state in
            XCTAssertEqual(state.ownerChildDeviceID, owner)
            XCTAssertEqual(state.legacy, LegacyCompatibilityMonitorState(
                ownerChildDeviceID: owner,
                lifecycleVersion: 2,
                active: LegacyGenerationProvenance(activityName: active.activityName, deviceID: active.deviceID, offsetMinutes: active.offsetMinutes, armSignature: active.armSignature, usageDate: active.usageDate, timezoneIdentifier: active.timezoneIdentifier, armedAt: active.armedAt),
                pending: LegacyGenerationProvenance(activityName: pending.activityName, deviceID: pending.deviceID, offsetMinutes: pending.offsetMinutes, armSignature: pending.armSignature, usageDate: pending.usageDate, timezoneIdentifier: pending.timezoneIdentifier, armedAt: pending.armedAt),
                retiringActivityNames: lifecycle.retiringActivityNames,
                breadcrumbActivityNames: breadcrumbs ?? [],
                scalarActiveActivityName: active.activityName,
                isStopped: false,
                phase: .dualLanePreparingV2,
                stopAcknowledgedAt: nil
            ))
        }

        XCTAssertEqual(defaults.data(forKey: EarnedActivityGeneration.lifecycleKey), lifecycleBytes)
        XCTAssertEqual(defaults.stringArray(forKey: EarnedActivityGeneration.lifecycleBreadcrumbsKey), breadcrumbs)
        XCTAssertEqual(defaults.string(forKey: EarnedActivityGeneration.activeActivityNameKey), active.activityName)
    }

    func testStoppedLegacyLifecycleMapsToStoppedPhaseAndPreservesBooleanProvenance() throws {
        let defaults = UserDefaults(suiteName: MeteringOwnerMirror.suiteName)!
        let keys = [EarnedActivityGeneration.lifecycleKey, EarnedActivityGeneration.lifecycleBreadcrumbsKey, EarnedActivityGeneration.activeActivityNameKey]
        keys.forEach(defaults.removeObject(forKey:))
        defer { keys.forEach(defaults.removeObject(forKey:)) }
        let lifecycle = EarnedActivityGeneration.Lifecycle(active: nil, pending: nil, retiringActivityNames: [EarnedActivityGeneration.legacyActivityName], isStopped: true)
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(lifecycle, defaults: defaults))

        let store = DeviceEpochStore(fileURL: URL(fileURLWithPath: "/tmp/evlin-device-epoch-store-stopped-migration.json"), lock: MigrationLock(), fileIO: MigrationFileIO(), ownerProvider: { self.owner })
        try store.transaction(expectedOwner: owner) { state in
            XCTAssertEqual(state.legacy?.ownerChildDeviceID, owner)
            XCTAssertEqual(state.legacy?.isStopped, true)
            XCTAssertEqual(state.legacy?.phase, .stoppedV1)
        }
    }
}

private final class MigrationLock: DeviceEpochStoreLocking, @unchecked Sendable {
    func withLock<T>(_ body: () -> T) -> T? { body() }
}

private final class MigrationFileIO: DeviceEpochFileIO, @unchecked Sendable {
    var data: Data?
    func read(from url: URL) throws -> Data? { data }
    func writeAtomically(_ data: Data, to url: URL) throws { self.data = data }
}
