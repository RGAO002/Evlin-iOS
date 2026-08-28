import XCTest
@testable import Evlin_iOS

@MainActor
final class MasterLockProjectionTests: XCTestCase {
    private let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let phoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let tabletID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let appID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private let expiresAt = Date(timeIntervalSince1970: 1_788_019_200)

    func testReflectionHidesControl() {
        let projection = makeProjection(
            overrideRevision: 8,
            overrideExpiresAt: expiresAt,
            devices: [
                makeDevice(
                    id: phoneID,
                    name: "Phone",
                    manualAllApps: true,
                    earnedExhausted: true,
                    taskIncomplete: true,
                    deviceLimitActive: true,
                    limitedAppIDs: [appID],
                    reflectionActive: true,
                    deliveryState: .failed
                )
            ]
        )

        XCTAssertEqual(
            MasterLockPresentation.reduce(projection: projection),
            .hiddenForReflection
        )
    }

    func testUnlockedShowsImmediateLockAction() {
        let projection = makeProjection(devices: [
            makeDevice(id: phoneID, name: "Phone"),
            makeDevice(id: tabletID, name: "Tablet"),
        ])

        XCTAssertEqual(
            MasterLockPresentation.reduce(projection: projection),
            .lockApps
        )
    }

    func testManualOnlyShowsDirectUnlock() {
        let projection = makeProjection(devices: [
            makeDevice(id: phoneID, name: "Phone", manualAllApps: true),
            makeDevice(id: tabletID, name: "Tablet", manualAllApps: true),
        ])

        XCTAssertEqual(
            MasterLockPresentation.reduce(projection: projection),
            .unlockDirect
        )
    }

    func testAutomaticSourceRequiresDurationSheet() throws {
        let projection = makeProjection(devices: [
            makeDevice(id: phoneID, name: "Phone", earnedExhausted: true),
            makeDevice(id: tabletID, name: "Tablet", earnedExhausted: true),
        ])

        guard case .unlockWithDuration(let sheet) = MasterLockPresentation.reduce(
            projection: projection
        ) else {
            return XCTFail("Expected a duration sheet")
        }

        XCTAssertTrue(sheet.hasAutomaticRestrictions)
        XCTAssertEqual(sheet.expectedDeviceIDs, [phoneID, tabletID])
        XCTAssertEqual(sheet.devices.map(\.deviceName), ["Phone", "Tablet"])
        XCTAssertTrue(try XCTUnwrap(sheet.devices.first).earnedExhausted)
    }

    func testMixedDevicesShowsChoiceSheet() {
        let projection = makeProjection(devices: [
            makeDevice(id: phoneID, name: "Phone", manualAllApps: true),
            makeDevice(id: tabletID, name: "Tablet"),
        ])

        guard case .mixed(let model) = MasterLockPresentation.reduce(
            projection: projection
        ) else {
            return XCTFail("Expected a mixed-device choice")
        }

        XCTAssertEqual(model.lockedDeviceNames, ["Phone"])
        XCTAssertEqual(model.unlockedDeviceNames, ["Tablet"])
        XCTAssertNil(model.unlockSheet)
    }

    func testActiveOverrideShowsCountdownAndLockNow() {
        let projection = makeProjection(
            overrideRevision: 4,
            overrideExpiresAt: expiresAt,
            devices: [makeDevice(id: phoneID, name: "Phone", taskIncomplete: true)]
        )

        XCTAssertEqual(
            MasterLockPresentation.reduce(projection: projection),
            .overrideActive(expiresAt: expiresAt)
        )
    }

    func testConfirmedOverrideDisplaysDeviceAsUnlockedDespiteUnderlyingTaskLock() {
        let projection = makeProjection(
            overrideRevision: 4,
            overrideExpiresAt: expiresAt,
            devices: [
                makeDevice(
                    id: phoneID,
                    name: "Phone",
                    taskIncomplete: true,
                    deliveryState: .confirmed
                )
            ]
        )

        XCTAssertFalse(
            projection.displaysDeviceAsLocked(phoneID, fallbackLocked: true)
        )
    }

    func testWaitingOverrideKeepsUnderlyingDeviceLockVisible() {
        let projection = makeProjection(
            overrideRevision: 4,
            overrideExpiresAt: expiresAt,
            devices: [
                makeDevice(
                    id: phoneID,
                    name: "Phone",
                    taskIncomplete: true,
                    deliveryState: .waiting
                )
            ]
        )

        XCTAssertTrue(
            projection.displaysDeviceAsLocked(phoneID, fallbackLocked: true)
        )
    }

    func testPartialDeliveryNamesWaitingAndFailedDevices() {
        let projection = makeProjection(
            overrideRevision: 6,
            devices: [
                makeDevice(id: phoneID, name: "Phone", deliveryState: .waiting),
                makeDevice(id: tabletID, name: "Tablet", deliveryState: .failed),
            ]
        )
        let operation = MasterLockOperation(
            childProfileID: childID,
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            expectedDeviceIDs: [phoneID, tabletID],
            revision: 6,
            snapshotDigest: "digest-6",
            requestedAction: .unlockDirect,
            receipts: [
                MasterLockOperationReceipt(deviceID: phoneID, deliveryState: .waiting),
                MasterLockOperationReceipt(deviceID: tabletID, deliveryState: .failed),
            ],
            expiration: nil,
            submitted: true
        )

        guard case .delivery(let delivery) = MasterLockPresentation.reduce(
            projection: projection,
            operation: operation
        ) else {
            return XCTFail("Expected partial delivery detail")
        }

        XCTAssertEqual(delivery.requestedAction, .unlockDirect)
        XCTAssertEqual(delivery.waitingDeviceNames, ["Phone"])
        XCTAssertEqual(delivery.failedDeviceNames, ["Tablet"])
        XCTAssertEqual(delivery.confirmedDeviceNames, [])
        XCTAssertTrue(delivery.canRetry)
    }

    func testPerAppScopeDoesNotPretendWholeDeviceIsLocked() throws {
        let projection = makeProjection(devices: [
            makeDevice(
                id: phoneID,
                name: "Phone",
                limitedAppIDs: [appID]
            )
        ])

        guard case .unlockWithDuration(let sheet) = MasterLockPresentation.reduce(
            projection: projection
        ) else {
            return XCTFail("Expected a duration sheet for a per-app limit")
        }

        let phone = try XCTUnwrap(sheet.devices.first)
        XCTAssertFalse(phone.wholeDeviceLocked)
        XCTAssertEqual(phone.limitedAppIDs, [appID])
        XCTAssertEqual(phone.limitedLegacyScopeIDs, [])
    }

    func testUnverifiedIdentityShowsUpdating() {
        let projection = makeProjection(devices: [
            makeDevice(id: phoneID, name: "Phone", identityVerified: false),
        ])

        XCTAssertEqual(
            MasterLockPresentation.reduce(projection: projection),
            .updating
        )
    }

    private func makeProjection(
        snapshotDigest: String = "digest-6",
        overrideRevision: Int64 = 0,
        overrideExpiresAt: Date? = nil,
        devices: [MasterLockDeviceProjection]
    ) -> MasterLockProjection {
        MasterLockProjection(
            childProfileID: childID,
            snapshotDigest: snapshotDigest,
            overrideRevision: overrideRevision,
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
}
