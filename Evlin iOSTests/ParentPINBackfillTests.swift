import XCTest
@testable import Evlin_iOS

@MainActor
final class ParentPINBackfillTests: XCTestCase {
    private var defaults: UserDefaults!
    private var pinStore: EvlinPINStore!
    private var lifecycle: ParentPINLifecycleStore!
    private var backfill: ParentPINBackfill!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        let suite = "ParentPINBackfillTests.\(id)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        pinStore = EvlinPINStore(account: "evlin.pin.backfill.\(id)")
        lifecycle = ParentPINLifecycleStore(
            defaults: defaults,
            makeSecret: { "backfill-secret-abcdefghijklmnopqrstuvwxyz-12" }
        )
        backfill = ParentPINBackfill(
            defaults: defaults,
            pinStore: pinStore,
            lifecycleStore: lifecycle
        )
    }

    func testNotSetBackendRecoversAndQueuesExistingPIN() async throws {
        try pinStore.setPIN("4826")
        let deviceID = UUID()

        await backfill.runIfNeeded(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1",
            budget: 10_000,
            remoteStatus: .init(status: "not_set", resetGeneration: 0)
        )

        XCTAssertEqual(lifecycle.pendingUpload()?.pin, "4826")
        XCTAssertEqual(lifecycle.pendingUpload()?.status, "available")
    }

    func testNetworkFailureOrSettledBackendDoesNotQueueAnything() async throws {
        try pinStore.setPIN("4826")
        let deviceID = UUID()
        await backfill.runIfNeeded(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1",
            budget: 10_000,
            remoteStatus: nil
        )
        XCTAssertNil(lifecycle.pendingUpload())

        await backfill.runIfNeeded(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1",
            budget: 10_000,
            remoteStatus: .init(status: "available", resetGeneration: 0)
        )
        XCTAssertNil(lifecycle.pendingUpload())
    }

    func testBudgetCursorAdvancesAcrossForegroundPasses() async throws {
        try pinStore.setPIN("9999")
        let deviceID = UUID()
        await backfill.runIfNeeded(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1",
            budget: 10,
            remoteStatus: .init(status: "not_set", resetGeneration: 0)
        )
        XCTAssertEqual(backfill.currentCursor(), .init(length: 4, next: 10))
        XCTAssertNil(lifecycle.pendingUpload())
    }

    func testNewerRemoteResetClearsLocalPINInsteadOfRecoveringIt() async throws {
        try pinStore.setPIN("4826")
        let deviceID = UUID()

        let cleared = backfill.applyRemoteReset(
            .init(status: "not_set", resetGeneration: 1),
            deviceID: deviceID
        )

        XCTAssertTrue(cleared)
        XCTAssertFalse(pinStore.isSet())
        XCTAssertNil(lifecycle.pendingUpload())
        XCTAssertEqual(lifecycle.resetGeneration(for: deviceID), 1)
    }
}
