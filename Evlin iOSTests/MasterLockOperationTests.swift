import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MasterLockOperationTests: XCTestCase {
    private let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let phoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let tabletID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
    private let expiresAt = Date(timeIntervalSince1970: 1_788_019_200)

    override func setUp() {
        super.setUp()
        MasterLockURLProtocol.reset()
        URLProtocol.registerClass(MasterLockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MasterLockURLProtocol.self)
        MasterLockURLProtocol.reset()
        super.tearDown()
    }

    func testOperationStorePersistsIdentityRevisionActionReceiptsAndExpiration() throws {
        let defaults = try makeDefaults()
        let operation = makeOperation(
            requestedAction: .unlockOverride(.minutes(30)),
            receipts: [
                MasterLockOperationReceipt(deviceID: phoneID, deliveryState: .confirmed),
                MasterLockOperationReceipt(deviceID: tabletID, deliveryState: .waiting),
            ],
            expiration: expiresAt,
            submitted: true
        )

        MasterLockOperationStore.save(operation, defaults: defaults)

        XCTAssertEqual(
            MasterLockOperationStore.load(childProfileID: childID, defaults: defaults),
            operation
        )
        XCTAssertEqual(operation.operationID, operationID)
        XCTAssertEqual(operation.expectedDeviceIDs, [phoneID, tabletID])
        XCTAssertEqual(operation.revision, 5)
        XCTAssertEqual(operation.requestedAction, .unlockOverride(.minutes(30)))
        XCTAssertEqual(operation.expiration, expiresAt)
    }

    func testRelaunchResumesWithSameOperationIDInsteadOfCreatingAnotherOperation() throws {
        let defaults = try makeDefaults()
        let prepared = makeOperation(submitted: false)
        MasterLockOperationStore.save(prepared, defaults: defaults)

        let restored = try XCTUnwrap(
            MasterLockOperationStore.load(childProfileID: childID, defaults: defaults)
        )

        XCTAssertEqual(restored.operationID, operationID)
        XCTAssertEqual(MasterLockOperationCoordinator.resumeAction(for: restored), .submit(restored))
    }

    func testConfirmationRefreshReturnsUpdatedSheetWithoutSubmitting() async throws {
        let defaults = try makeDefaults()
        let original = makeProjection(
            digest: "digest-5",
            revision: 5,
            devices: [makeDevice(id: phoneID, name: "Phone", earnedExhausted: true)]
        )
        let changed = makeProjection(
            digest: "digest-6",
            revision: 6,
            devices: [
                makeDevice(id: phoneID, name: "Phone", earnedExhausted: true),
                makeDevice(id: tabletID, name: "Tablet", taskIncomplete: true),
            ]
        )
        let operation = MasterLockOperation.prepared(
            projection: original,
            operationID: operationID,
            requestedAction: .unlockOverride(.minutes(30))
        )
        var didSubmit = false

        let result = try await MasterLockOperationCoordinator.confirm(
            operation: operation,
            defaults: defaults,
            refresh: { changed },
            submit: { _ in
                didSubmit = true
                throw URLError(.badServerResponse)
            }
        )

        XCTAssertFalse(didSubmit)
        XCTAssertNil(MasterLockOperationStore.load(childProfileID: childID, defaults: defaults))
        guard case .projectionChanged(let projection, let presentation) = result else {
            return XCTFail("Expected a stale confirmation refresh")
        }
        XCTAssertEqual(projection, changed)
        guard case .unlockWithDuration(let sheet) = presentation else {
            return XCTFail("Expected the changed projection to rebuild the duration sheet")
        }
        XCTAssertEqual(sheet.revision, 6)
        XCTAssertEqual(sheet.expectedDeviceIDs, [phoneID, tabletID])
    }

    func testConfirmationPersistsBeforePOSTAndMergesResponse() async throws {
        let defaults = try makeDefaults()
        let projection = makeProjection(
            digest: "digest-5",
            revision: 5,
            devices: [
                makeDevice(id: phoneID, name: "Phone", earnedExhausted: true),
                makeDevice(id: tabletID, name: "Tablet", earnedExhausted: true),
            ]
        )
        let operation = MasterLockOperation.prepared(
            projection: projection,
            operationID: operationID,
            requestedAction: .unlockOverride(.minutes(30))
        )
        let responseProjection = makeProjection(
            digest: "digest-6",
            revision: 6,
            overrideExpiresAt: expiresAt,
            devices: [
                makeDevice(id: phoneID, name: "Phone", earnedExhausted: true),
                makeDevice(
                    id: tabletID,
                    name: "Tablet",
                    earnedExhausted: true,
                    deliveryState: .waiting
                ),
            ]
        )

        let result = try await MasterLockOperationCoordinator.confirm(
            operation: operation,
            defaults: defaults,
            refresh: { projection },
            submit: { submitted in
                XCTAssertEqual(
                    MasterLockOperationStore.load(
                        childProfileID: self.childID,
                        defaults: defaults
                    ),
                    submitted
                )
                return MasterLockControlResponse(
                    childProfileID: self.childID,
                    revision: 6,
                    operationID: self.operationID,
                    expiration: self.expiresAt,
                    receipts: [
                        MasterLockOperationReceipt(
                            deviceID: self.phoneID,
                            deliveryState: .confirmed
                        ),
                        MasterLockOperationReceipt(
                            deviceID: self.tabletID,
                            deliveryState: .waiting
                        ),
                    ],
                    projection: responseProjection
                )
            }
        )

        guard case .submitted(let saved, let returnedProjection) = result else {
            return XCTFail("Expected a submitted operation")
        }
        XCTAssertEqual(saved.revision, 6)
        XCTAssertTrue(saved.submitted)
        XCTAssertEqual(saved.expiration, expiresAt)
        XCTAssertEqual(saved.receipts.map(\.deliveryState), [.confirmed, .waiting])
        XCTAssertEqual(returnedProjection, responseProjection)
        XCTAssertEqual(
            MasterLockOperationStore.load(childProfileID: childID, defaults: defaults),
            saved
        )
    }

    func testSubmissionFailureReturnsRetryableOperationInsteadOfThrowing() async throws {
        let defaults = try makeDefaults()
        let projection = makeProjection(
            digest: "digest-5",
            revision: 5,
            devices: [makeDevice(id: phoneID, name: "Phone", earnedExhausted: true)]
        )
        let operation = MasterLockOperation.prepared(
            projection: projection,
            operationID: operationID,
            requestedAction: .unlockOverride(.minutes(30))
        )

        let result: MasterLockConfirmationResult?
        do {
            result = try await MasterLockOperationCoordinator.confirm(
                operation: operation,
                defaults: defaults,
                refresh: { projection },
                submit: { _ in throw URLError(.badServerResponse) }
            )
        } catch {
            result = nil
        }

        guard case .submissionFailed(let retained, let returnedProjection, let message) = result else {
            return XCTFail("A failed POST must remain an immediately retryable operation")
        }
        XCTAssertEqual(retained, operation)
        XCTAssertEqual(returnedProjection, projection)
        XCTAssertFalse(message.isEmpty)
        let reconciliation = MasterLockOperationReconciliation.evaluate(
            operation: retained,
            projection: returnedProjection
        )
        guard case .delivery(let delivery) = reconciliation.presentation else {
            return XCTFail("A failed POST must show the delivery retry control")
        }
        XCTAssertTrue(delivery.canRetry)
        XCTAssertEqual(delivery.waitingDeviceNames, ["Phone"])
        XCTAssertEqual(
            MasterLockOperationStore.load(childProfileID: childID, defaults: defaults),
            operation
        )
    }

    func testRetryClearsPersistedOperationWhenProjectionChanged() async throws {
        let defaults = try makeDefaults()
        let original = makeProjection(
            digest: "digest-5",
            revision: 5,
            devices: [makeDevice(id: phoneID, name: "Phone", earnedExhausted: true)]
        )
        let changed = makeProjection(
            digest: "digest-6",
            revision: 6,
            devices: [makeDevice(id: phoneID, name: "Phone")]
        )
        let operation = MasterLockOperation.prepared(
            projection: original,
            operationID: operationID,
            requestedAction: .unlockOverride(.minutes(30))
        )
        MasterLockOperationStore.save(operation, defaults: defaults)

        let result = try await MasterLockOperationCoordinator.confirm(
            operation: operation,
            defaults: defaults,
            refresh: { changed },
            submit: { _ in throw URLError(.badServerResponse) }
        )

        guard case .projectionChanged(let projection, _) = result else {
            return XCTFail("Expected the stale retry to rebuild from the current projection")
        }
        XCTAssertEqual(projection, changed)
        XCTAssertNil(
            MasterLockOperationStore.load(childProfileID: childID, defaults: defaults),
            "The stale persisted operation must not auto-submit on the next refresh"
        )
    }

    func testStaleRetryDoesNotClearAnewerPersistedOperation() async throws {
        let defaults = try makeDefaults()
        let original = makeProjection(
            digest: "digest-5",
            revision: 5,
            devices: [makeDevice(id: phoneID, name: "Phone", earnedExhausted: true)]
        )
        let changed = makeProjection(
            digest: "digest-6",
            revision: 6,
            devices: [makeDevice(id: phoneID, name: "Phone")]
        )
        let stale = MasterLockOperation.prepared(
            projection: original,
            operationID: operationID,
            requestedAction: .unlockOverride(.minutes(30))
        )
        let newer = MasterLockOperation.prepared(
            projection: changed,
            operationID: UUID(),
            requestedAction: .lockApps
        )
        MasterLockOperationStore.save(newer, defaults: defaults)

        _ = try await MasterLockOperationCoordinator.confirm(
            operation: stale,
            defaults: defaults,
            refresh: { changed },
            submit: { _ in throw URLError(.badServerResponse) }
        )

        XCTAssertEqual(
            MasterLockOperationStore.load(childProfileID: childID, defaults: defaults),
            newer
        )
    }

    func testReconciliationUsesRevisionAndPerDeviceReceipts() {
        let operation = makeOperation(
            revision: 6,
            receipts: [
                MasterLockOperationReceipt(deviceID: phoneID, deliveryState: .waiting),
                MasterLockOperationReceipt(deviceID: tabletID, deliveryState: .waiting),
            ],
            submitted: true
        )
        let partial = makeProjection(
            digest: "digest-6",
            revision: 6,
            devices: [
                makeDevice(id: phoneID, name: "Phone", manualAllApps: true),
                makeDevice(
                    id: tabletID,
                    name: "Tablet",
                    manualAllApps: true,
                    deliveryState: .failed
                ),
            ]
        )

        let pending = MasterLockOperationReconciliation.evaluate(
            operation: operation,
            projection: partial
        )

        XCTAssertFalse(pending.shouldClearPersistence)
        guard case .delivery(let delivery) = pending.presentation else {
            return XCTFail("Expected partial delivery")
        }
        XCTAssertEqual(delivery.confirmedDeviceNames, ["Phone"])
        XCTAssertEqual(delivery.failedDeviceNames, ["Tablet"])

        let confirmed = makeProjection(
            digest: "digest-6-complete",
            revision: 6,
            devices: [
                makeDevice(id: phoneID, name: "Phone", manualAllApps: true),
                makeDevice(id: tabletID, name: "Tablet", manualAllApps: true),
            ]
        )
        let complete = MasterLockOperationReconciliation.evaluate(
            operation: operation,
            projection: confirmed
        )
        XCTAssertTrue(complete.shouldClearPersistence)
        XCTAssertEqual(complete.presentation, .unlockDirect)
    }

    func testReconciliationDoesNotClearConfirmedLockUntilDesiredStateIsVisible() {
        let operation = makeOperation(
            revision: 6,
            requestedAction: .lockApps,
            receipts: [
                MasterLockOperationReceipt(deviceID: phoneID, deliveryState: .confirmed),
                MasterLockOperationReceipt(deviceID: tabletID, deliveryState: .confirmed),
            ],
            submitted: true
        )
        let staleProjection = makeProjection(
            digest: "digest-6-stale",
            revision: 6,
            devices: [
                makeDevice(id: phoneID, name: "Phone", manualAllApps: true),
                makeDevice(id: tabletID, name: "Tablet", manualAllApps: false),
            ]
        )

        let result = MasterLockOperationReconciliation.evaluate(
            operation: operation,
            projection: staleProjection
        )

        XCTAssertFalse(result.shouldClearPersistence)
        guard case .delivery(let delivery) = result.presentation else {
            return XCTFail("Confirmed delivery without the desired state must remain pending")
        }
        XCTAssertEqual(delivery.confirmedDeviceNames, ["Phone"])
        XCTAssertEqual(delivery.waitingDeviceNames, ["Tablet"])
    }

    func testReconciliationRequiresActiveOverrideBeforeClearingOverrideOperation() {
        let operation = makeOperation(
            revision: 6,
            requestedAction: .unlockOverride(.minutes(30)),
            receipts: [
                MasterLockOperationReceipt(deviceID: phoneID, deliveryState: .confirmed),
                MasterLockOperationReceipt(deviceID: tabletID, deliveryState: .confirmed),
            ],
            submitted: true
        )
        let noOverrideYet = makeProjection(
            digest: "digest-6-no-override",
            revision: 6,
            devices: [
                makeDevice(id: phoneID, name: "Phone"),
                makeDevice(id: tabletID, name: "Tablet"),
            ]
        )

        let pending = MasterLockOperationReconciliation.evaluate(
            operation: operation,
            projection: noOverrideYet
        )
        XCTAssertFalse(pending.shouldClearPersistence)

        let activeOverride = makeProjection(
            digest: "digest-6-active-override",
            revision: 6,
            overrideExpiresAt: expiresAt,
            devices: [
                makeDevice(id: phoneID, name: "Phone"),
                makeDevice(id: tabletID, name: "Tablet"),
            ]
        )
        let complete = MasterLockOperationReconciliation.evaluate(
            operation: operation,
            projection: activeOverride
        )
        XCTAssertTrue(complete.shouldClearPersistence)
    }

    func testNewTaskDuringOverrideOffersLockNowOrKeepUnlocked() async throws {
        let defaults = try makeDefaults()
        let activeOverride = makeProjection(
            digest: "digest-5",
            revision: 5,
            overrideExpiresAt: expiresAt,
            devices: [makeDevice(id: phoneID, name: "Phone", taskIncomplete: true)]
        )

        XCTAssertEqual(
            MasterLockTaskOverrideDecision.resolve(
                choice: .keepUnlocked,
                projection: activeOverride,
                operationID: operationID
            ),
            .keepUnlocked(activeOverride)
        )
        XCTAssertTrue(activeOverride.devices[0].taskIncomplete)
        XCTAssertEqual(activeOverride.overrideExpiresAt, expiresAt)

        guard case .submit(let lockNow) = MasterLockTaskOverrideDecision.resolve(
            choice: .lockNow,
            projection: activeOverride,
            operationID: operationID
        ) else {
            return XCTFail("Expected Lock Now to submit")
        }
        XCTAssertEqual(lockNow.requestedAction, .cancelOverrideAndLock)
        XCTAssertEqual(lockNow.revision, 5)

        let lockedProjection = makeProjection(
            digest: "digest-6",
            revision: 6,
            devices: [makeDevice(id: phoneID, name: "Phone", manualAllApps: true, taskIncomplete: true)]
        )
        let result = try await MasterLockOperationCoordinator.confirm(
            operation: lockNow,
            defaults: defaults,
            refresh: { activeOverride },
            submit: { submitted in
                XCTAssertEqual(submitted.requestedAction, .cancelOverrideAndLock)
                return MasterLockControlResponse(
                    childProfileID: self.childID,
                    revision: 6,
                    operationID: self.operationID,
                    expiration: nil,
                    receipts: [
                        MasterLockOperationReceipt(
                            deviceID: self.phoneID,
                            deliveryState: .confirmed
                        )
                    ],
                    projection: lockedProjection
                )
            }
        )

        guard case .submitted(let submitted, _) = result else {
            return XCTFail("Expected Lock Now to submit")
        }
        XCTAssertGreaterThan(submitted.revision, activeOverride.overrideRevision)
        XCTAssertEqual(submitted.requestedAction, .cancelOverrideAndLock)
        XCTAssertTrue(lockedProjection.devices[0].taskIncomplete)
    }

    func testAPIClientWiresProjectionAndOperationEndpoints() async throws {
        MasterLockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (200, Self.projectionJSON)
            }
            return (200, Self.controlResponseJSON)
        }
        let client = APIClient(baseURL: "https://task8.example/api/v1")
        let controlRequest = ParentMasterControlRequestDTO(
            expectedRevision: 5,
            expectedSnapshotDigest: "digest-5",
            operationID: operationID
        )
        let overrideRequest = ParentUnlockOverrideRequestDTO(
            duration: .minutes,
            durationMinutes: 30,
            expectedRevision: 5,
            expectedSnapshotDigest: "digest-5",
            operationID: operationID
        )

        let projection = try await client.fetchParentLockProjection(
            childProfileID: childID
        )
        _ = try await client.submitMasterLock(
            childProfileID: childID,
            request: controlRequest
        )
        _ = try await client.submitMasterUnlock(
            childProfileID: childID,
            request: controlRequest
        )
        _ = try await client.submitUnlockOverride(
            childProfileID: childID,
            request: overrideRequest
        )
        _ = try await client.submitUnlockOverrideCancellation(
            childProfileID: childID,
            request: controlRequest
        )

        XCTAssertEqual(projection.snapshotDigest, "digest-5")
        XCTAssertEqual(
            MasterLockURLProtocol.requests.map { $0.url?.path },
            [
                "/api/v1/parent/children/\(childID.uuidString)/lock-projection",
                "/api/v1/parent/children/\(childID.uuidString)/master-lock",
                "/api/v1/parent/children/\(childID.uuidString)/master-unlock",
                "/api/v1/parent/children/\(childID.uuidString)/unlock-override",
                "/api/v1/parent/children/\(childID.uuidString)/unlock-override/cancel",
            ]
        )
        XCTAssertEqual(
            MasterLockURLProtocol.requests.map(\.httpMethod),
            ["GET", "POST", "POST", "POST", "POST"]
        )
        // URLSession hands URLProtocol an immutable request after body-stream
        // conversion, so the captured request body is intentionally not used
        // as a serialization oracle here. The endpoint methods share
        // authedJSON's existing encoder coverage; this test protects the
        // distinct endpoint/method wiring contract.
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MasterLockOperationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeOperation(
        revision: Int64 = 5,
        requestedAction: MasterLockRequestedAction = .lockApps,
        receipts: [MasterLockOperationReceipt] = [],
        expiration: Date? = nil,
        submitted: Bool
    ) -> MasterLockOperation {
        MasterLockOperation(
            childProfileID: childID,
            operationID: operationID,
            expectedDeviceIDs: [phoneID, tabletID],
            revision: revision,
            snapshotDigest: "digest-5",
            requestedAction: requestedAction,
            receipts: receipts,
            expiration: expiration,
            submitted: submitted
        )
    }

    private func makeProjection(
        digest: String,
        revision: Int64,
        overrideExpiresAt: Date? = nil,
        devices: [MasterLockDeviceProjection]
    ) -> MasterLockProjection {
        MasterLockProjection(
            childProfileID: childID,
            snapshotDigest: digest,
            overrideRevision: revision,
            overrideExpiresAt: overrideExpiresAt,
            devices: devices
        )
    }

    private func makeDevice(
        id: UUID,
        name: String,
        identityVerified: Bool = true,
        manualAllApps: Bool = false,
        earnedExhausted: Bool = false,
        taskIncomplete: Bool = false,
        deviceLimitActive: Bool = false,
        limitedAppIDs: [UUID] = [],
        limitedLegacyScopeIDs: [String] = [],
        reflectionActive: Bool = false,
        deliveryState: ParentControlDeliveryState = .confirmed
    ) -> MasterLockDeviceProjection {
        MasterLockDeviceProjection(
            childDeviceID: id,
            deviceName: name,
            identityVerified: identityVerified,
            manualAllApps: manualAllApps,
            earnedExhausted: earnedExhausted,
            taskIncomplete: taskIncomplete,
            deviceLimitActive: deviceLimitActive,
            limitedAppIDs: limitedAppIDs,
            limitedLegacyScopeIDs: limitedLegacyScopeIDs,
            reflectionActive: reflectionActive,
            deliveryState: deliveryState
        )
    }

    private static let projectionJSON = Data("""
    {
      "child_profile_id": "00000000-0000-0000-0000-000000000001",
      "snapshot_digest": "digest-5",
      "override_revision": 5,
      "override_expires_at": null,
      "devices": [{
        "child_device_id": "00000000-0000-0000-0000-000000000101",
        "identity_verified": true,
        "manual_all_apps": false,
        "earned_exhausted": true,
        "task_incomplete": false,
        "device_limit_active": false,
        "limited_app_ids": [],
        "limited_legacy_scope_ids": [],
        "reflection_active": false,
        "delivery_state": "confirmed"
      }]
    }
    """.utf8)

    private static let controlResponseJSON = Data("""
    {
      "child_profile_id": "00000000-0000-0000-0000-000000000001",
      "usage_date": "2026-08-26",
      "revision": 6,
      "operation_id": "00000000-0000-0000-0000-000000000901",
      "expires_at": null,
      "receipts": [{
        "child_device_id": "00000000-0000-0000-0000-000000000101",
        "delivery_state": "confirmed"
      }],
      "snapshot": {
        "child_profile_id": "00000000-0000-0000-0000-000000000001",
        "snapshot_digest": "digest-6",
        "override_revision": 6,
        "override_expires_at": null,
        "devices": [{
          "child_device_id": "00000000-0000-0000-0000-000000000101",
          "identity_verified": true,
          "manual_all_apps": true,
          "earned_exhausted": false,
          "task_incomplete": false,
          "device_limit_active": false,
          "limited_app_ids": [],
          "limited_legacy_scope_ids": [],
          "reflection_active": false,
          "delivery_state": "confirmed"
        }]
      }
    }
    """.utf8)
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}

private final class MasterLockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "task8.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        do {
            let (statusCode, data) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
