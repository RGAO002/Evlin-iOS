import Foundation
import XCTest
@testable import Evlin_iOS

final class DeviceEpochStoreMigrationTests: XCTestCase {
    private let owner = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let lifecycleKey = ["evlin", "earned", "activityLifecycle"].joined(separator: ".")
    private let breadcrumbsKey = ["evlin", "earned", "activityBreadcrumbs"].joined(separator: ".")
    private let activeNameKey = ["evlin", "earned", "activeActivityName"].joined(separator: ".")

    func testFirstReadAtomicallyMigratesExactLegacyProvenanceThenDeletesOldKeys() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let active = generation(suffix: "active", offset: 10, armedAt: 10)
        let pending = generation(suffix: "pending", offset: 15, armedAt: 20)
        try seed(
            defaults,
            lifecycle: LegacyLifecycleFixture(
                version: 2,
                active: active,
                pending: pending,
                retiringActivityNames: [
                    "evlin.earned.budget.retiring",
                    "evlin.earned.budget.retiring",
                ],
                isStopped: false
            ),
            breadcrumbs: [
                "evlin.earned.budget.breadcrumb",
                "evlin.earned.budget.breadcrumb",
            ],
            activeName: active.activityName
        )
        let io = MigrationFileIO()
        let store = makeStore(io: io, defaults: defaults)

        let state = try store.read()

        XCTAssertEqual(io.writeCount, 1)
        XCTAssertNotNil(io.data)
        XCTAssertEqual(state.ownerChildDeviceID, owner)
        XCTAssertEqual(state.legacy, LegacyCompatibilityMonitorState(
            ownerChildDeviceID: owner,
            lifecycleVersion: 2,
            active: active,
            pending: pending,
            retiringActivityNames: ["evlin.earned.budget.retiring"],
            breadcrumbActivityNames: ["evlin.earned.budget.breadcrumb"],
            scalarActiveActivityName: active.activityName,
            isStopped: false,
            phase: .dualLanePreparingV2,
            stopAcknowledgedAt: nil
        ))
        assertLegacyKeysRemoved(defaults)
        XCTAssertEqual(try store.read(), state)
        XCTAssertEqual(io.writeCount, 1)
    }

    func testFailedMigrationReadbackKeepsLegacyKeysAndAbsentRootForRetry() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let active = generation(suffix: "active", offset: 10, armedAt: 10)
        try seed(
            defaults,
            lifecycle: LegacyLifecycleFixture(
                version: 2,
                active: active,
                pending: nil,
                retiringActivityNames: [],
                isStopped: false
            ),
            breadcrumbs: [],
            activeName: active.activityName
        )
        let io = MigrationFileIO()
        io.failNextReadback = true
        let store = makeStore(io: io, defaults: defaults)

        XCTAssertThrowsError(try store.read())
        XCTAssertNil(io.data)
        XCTAssertNotNil(defaults.data(forKey: lifecycleKey))
        XCTAssertEqual(defaults.string(forKey: activeNameKey), active.activityName)

        let recovered = try store.read()
        XCTAssertEqual(recovered.legacy?.active, active)
        assertLegacyKeysRemoved(defaults)
    }

    func testExistingV4RootCannotBeOverwrittenByLateLegacyPayload() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let io = MigrationFileIO()
        let store = makeStore(io: io, defaults: defaults)
        try store.transaction(expectedOwner: owner) { state in
            state.legacy = LegacyCompatibilityMonitorState(
                ownerChildDeviceID: self.owner,
                lifecycleVersion: 2,
                active: nil,
                pending: nil,
                retiringActivityNames: [],
                breadcrumbActivityNames: [],
                scalarActiveActivityName: nil,
                isStopped: true,
                phase: .stoppedV1,
                stopAcknowledgedAt: Date(timeIntervalSince1970: 50)
            )
        }
        let authoritativeBytes = try XCTUnwrap(io.data)
        let late = generation(suffix: "late", offset: 99, armedAt: 99)
        try seed(
            defaults,
            lifecycle: LegacyLifecycleFixture(
                version: 2,
                active: late,
                pending: nil,
                retiringActivityNames: [],
                isStopped: false
            ),
            breadcrumbs: [],
            activeName: late.activityName
        )

        let state = try makeStore(io: io, defaults: defaults).read()

        XCTAssertEqual(io.data, authoritativeBytes)
        XCTAssertNil(state.legacy?.active)
        XCTAssertEqual(state.legacy?.phase, .stoppedV1)
        assertLegacyKeysRemoved(defaults)
    }

    func testImportedStoppedBooleanIsProvenanceAndPhaseControlsAuthorization() throws {
        let active = generation(suffix: "active", offset: 10, armedAt: 10)
        let activeState = LegacyCompatibilityMonitorState(
            ownerChildDeviceID: owner,
            lifecycleVersion: 2,
            active: active,
            pending: nil,
            retiringActivityNames: [],
            breadcrumbActivityNames: [],
            scalarActiveActivityName: active.activityName,
            isStopped: true,
            phase: .activeV1,
            stopAcknowledgedAt: nil
        )
        XCTAssertEqual(
            LegacyMeteringActivity.authorizedCallback(
                activityName: active.activityName,
                currentDeviceID: owner.uuidString,
                state: activeState
            ),
            active
        )
        var preparing = activeState
        preparing.phase = .dualLanePreparingV2
        XCTAssertNotNil(LegacyMeteringActivity.authorizedCallback(
            activityName: active.activityName,
            currentDeviceID: owner.uuidString,
            state: preparing
        ))
        var retiring = activeState
        retiring.phase = .retiringV1
        XCTAssertNil(LegacyMeteringActivity.authorizedCallback(
            activityName: active.activityName,
            currentDeviceID: owner.uuidString,
            state: retiring
        ))
    }

    private func makeStore(io: MigrationFileIO, defaults: UserDefaults) -> DeviceEpochStore {
        DeviceEpochStore(
            fileURL: URL(fileURLWithPath: "/tmp/evlin-device-epoch-store-migration.json"),
            lock: MigrationLock(),
            fileIO: io,
            ownerProvider: { self.owner },
            legacyDefaults: defaults
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "DeviceEpochStoreMigrationTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func generation(
        suffix: String,
        offset: Int,
        armedAt: TimeInterval
    ) -> LegacyGenerationProvenance {
        LegacyGenerationProvenance(
            activityName: "evlin.earned.budget.\(suffix)",
            deviceID: owner.uuidString,
            offsetMinutes: offset,
            usageDate: "2026-07-17",
            timezoneIdentifier: "America/New_York",
            armedAt: Date(timeIntervalSince1970: armedAt)
        )
    }

    private func seed(
        _ defaults: UserDefaults,
        lifecycle: LegacyLifecycleFixture,
        breadcrumbs: [String],
        activeName: String?
    ) throws {
        defaults.set(try JSONEncoder().encode(lifecycle), forKey: lifecycleKey)
        defaults.set(breadcrumbs, forKey: breadcrumbsKey)
        defaults.set(activeName, forKey: activeNameKey)
    }

    private func assertLegacyKeysRemoved(_ defaults: UserDefaults) {
        XCTAssertNil(defaults.object(forKey: lifecycleKey))
        XCTAssertNil(defaults.object(forKey: breadcrumbsKey))
        XCTAssertNil(defaults.object(forKey: activeNameKey))
    }

    private func clear(_ defaults: UserDefaults) {
        [lifecycleKey, breadcrumbsKey, activeNameKey].forEach(defaults.removeObject(forKey:))
    }
}

private struct LegacyLifecycleFixture: Encodable {
    let version: Int
    let active: LegacyGenerationProvenance?
    let pending: LegacyGenerationProvenance?
    let retiringActivityNames: [String]
    let isStopped: Bool
}

private final class MigrationLock: DeviceEpochStoreLocking, @unchecked Sendable {
    func withLock<T>(_ body: () -> T) -> T? { body() }
}

private enum MigrationFailure: Error { case injected }

private final class MigrationFileIO: DeviceEpochFileIO, @unchecked Sendable {
    var data: Data?
    var failNextReadback = false
    var readbackPending = false
    var writeCount = 0

    func read(from url: URL) throws -> Data? {
        if readbackPending {
            readbackPending = false
            if failNextReadback {
                failNextReadback = false
                throw MigrationFailure.injected
            }
        }
        return data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        writeCount += 1
        self.data = data
        readbackPending = true
    }

    func remove(at url: URL) throws {
        data = nil
        readbackPending = false
    }
}
