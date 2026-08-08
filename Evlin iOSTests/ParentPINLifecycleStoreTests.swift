import XCTest
@testable import Evlin_iOS

@MainActor
final class ParentPINLifecycleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ParentPINLifecycleStore!

    override func setUp() {
        super.setUp()
        let suite = "ParentPINLifecycleStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ParentPINLifecycleStore(
            defaults: defaults,
            makeSecret: { "test-secret-abcdefghijklmnopqrstuvwxyz-123456" }
        )
    }

    func testCapturePersistsExactUploadAndStableSecretForReplay() {
        let deviceID = UUID()
        store.captureUpload(
            pin: "4826",
            status: "available",
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )

        let first = store.pendingUpload()
        XCTAssertEqual(first?.pin, "4826")
        XCTAssertEqual(first?.lifecycleSecret, "test-secret-abcdefghijklmnopqrstuvwxyz-123456")
        XCTAssertEqual(first?.resetGeneration, 0)

        store.captureUpload(
            pin: "4826",
            status: "available",
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        XCTAssertEqual(store.pendingUpload(), first)
    }

    func testPreGenerationPendingUploadDecodesAsGenerationZero() throws {
        let deviceID = UUID()
        let json = """
        {
          "deviceID": "\(deviceID.uuidString)",
          "baseURL": "https://example.test/api/v1",
          "pin": "4826",
          "status": "available",
          "lifecycleSecret": "test-secret-abcdefghijklmnopqrstuvwxyz-123456"
        }
        """

        let upload = try JSONDecoder().decode(
            PendingParentPINUpload.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(upload.deviceID, deviceID)
        XCTAssertEqual(upload.resetGeneration, 0)
    }

    func testRemoteResetClearsStalePayloadAndSecretAndAdvancesGeneration() {
        let deviceID = UUID()
        store.captureUpload(
            pin: "4826", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )

        XCTAssertTrue(store.acceptRemoteResetGeneration(1, deviceID: deviceID))
        XCTAssertNil(store.pendingUpload())
        XCTAssertNil(store.lifecycleSecret(for: deviceID))
        XCTAssertEqual(store.resetGeneration(for: deviceID), 1)

        store.captureUpload(
            pin: "7391", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        XCTAssertEqual(store.pendingUpload()?.resetGeneration, 1)
    }

    func testEqualOrOlderRemoteGenerationDoesNotClearCurrentPINState() {
        let deviceID = UUID()
        XCTAssertTrue(store.acceptRemoteResetGeneration(2, deviceID: deviceID))
        store.captureUpload(
            pin: "4826", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        let upload = store.pendingUpload()

        XCTAssertFalse(store.acceptRemoteResetGeneration(2, deviceID: deviceID))
        XCTAssertFalse(store.acceptRemoteResetGeneration(1, deviceID: deviceID))
        XCTAssertEqual(store.pendingUpload(), upload)
        XCTAssertNotNil(store.lifecycleSecret(for: deviceID))
    }

    func testAcknowledgedUploadKeepsSecretButClearsPayload() {
        let deviceID = UUID()
        store.captureUpload(
            pin: "4826", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        let upload = try! XCTUnwrap(store.pendingUpload())

        store.acknowledgeUpload(upload)

        XCTAssertNil(store.pendingUpload())
        XCTAssertEqual(store.lifecycleSecret(for: deviceID), upload.lifecycleSecret)
    }

    func testSignOutQueuesClearBeforeRemovingLocalSecret() {
        let deviceID = UUID()
        store.captureUpload(
            pin: "4826", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        let upload = try! XCTUnwrap(store.pendingUpload())
        store.acknowledgeUpload(upload)

        let clear = store.prepareSignOutClear(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )

        XCTAssertEqual(clear?.lifecycleSecret, upload.lifecycleSecret)
        XCTAssertEqual(store.pendingClears(), [clear!])
        XCTAssertNil(store.lifecycleSecret(for: deviceID))
    }

    func testFailedClearSurvivesAndAcknowledgedClearIsRemoved() {
        let deviceID = UUID()
        store.captureUpload(
            pin: "4826", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        let upload = try! XCTUnwrap(store.pendingUpload())
        store.acknowledgeUpload(upload)
        let clear = try! XCTUnwrap(store.prepareSignOutClear(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        ))

        XCTAssertEqual(store.pendingClears(), [clear])
        store.acknowledgeClear(clear)
        XCTAssertTrue(store.pendingClears().isEmpty)
    }

    func testFlushKeepsFailuresAndAcknowledgesSuccessfulMutations() async {
        let deviceID = UUID()
        store.captureUpload(
            pin: "4826", status: "available", deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )
        await ParentPINSyncCoordinator.flushPending(
            store: store,
            sendUpload: { _ in false },
            sendClear: { _ in true }
        )
        XCTAssertNotNil(store.pendingUpload())

        await ParentPINSyncCoordinator.flushPending(
            store: store,
            sendUpload: { _ in true },
            sendClear: { _ in true }
        )
        XCTAssertNil(store.pendingUpload())

        let clear = try! XCTUnwrap(store.prepareSignOutClear(
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        ))
        await ParentPINSyncCoordinator.flushPending(
            store: store,
            sendUpload: { _ in true },
            sendClear: { _ in false }
        )
        XCTAssertEqual(store.pendingClears(), [clear])

        await ParentPINSyncCoordinator.flushPending(
            store: store,
            sendUpload: { _ in true },
            sendClear: { _ in true }
        )
        XCTAssertTrue(store.pendingClears().isEmpty)
    }

    func testAdoptingAnUnprovenDeviceClearsThePreviousIdentityPIN() throws {
        let oldDeviceID = UUID()
        let newDeviceID = UUID()
        let pinStore = EvlinPINStore(
            account: "evlin.pin.adoption.\(UUID().uuidString)"
        )
        try pinStore.setPIN("4826")
        store.captureUpload(
            pin: "4826",
            status: "available",
            deviceID: oldDeviceID,
            baseURL: "https://example.test/api/v1"
        )

        ParentPINSyncCoordinator.prepareForAdoption(
            deviceID: newDeviceID,
            pinStore: pinStore,
            store: store
        )

        XCTAssertFalse(pinStore.isSet())
        XCTAssertNil(store.pendingUpload())
    }

    func testAdoptingADeviceWithItsLifecycleProofKeepsThePIN() throws {
        let deviceID = UUID()
        let pinStore = EvlinPINStore(
            account: "evlin.pin.adoption.\(UUID().uuidString)"
        )
        try pinStore.setPIN("4826")
        store.captureUpload(
            pin: "4826",
            status: "available",
            deviceID: deviceID,
            baseURL: "https://example.test/api/v1"
        )

        ParentPINSyncCoordinator.prepareForAdoption(
            deviceID: deviceID,
            pinStore: pinStore,
            store: store
        )

        XCTAssertTrue(pinStore.isSet())
        XCTAssertEqual(store.pendingUpload()?.deviceID, deviceID)
    }
}
