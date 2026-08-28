import Foundation

nonisolated struct MasterLockDeviceProjection: Equatable, Sendable {
    let childDeviceID: UUID
    let deviceName: String
    let identityVerified: Bool
    let manualAllApps: Bool
    let earnedExhausted: Bool
    let taskIncomplete: Bool
    let deviceLimitActive: Bool
    let limitedAppIDs: [UUID]
    let limitedLegacyScopeIDs: [String]
    let reflectionActive: Bool
    let deliveryState: ParentControlDeliveryState

    var hasAutomaticRestrictions: Bool {
        earnedExhausted
            || taskIncomplete
            || deviceLimitActive
            || !limitedAppIDs.isEmpty
            || !limitedLegacyScopeIDs.isEmpty
    }

    var hasManagedRestrictions: Bool {
        manualAllApps || hasAutomaticRestrictions
    }

    var wholeDeviceLocked: Bool {
        manualAllApps || earnedExhausted || taskIncomplete || deviceLimitActive
    }
}

nonisolated struct MasterLockProjection: Equatable, Sendable {
    let childProfileID: UUID
    let snapshotDigest: String
    let overrideRevision: Int64
    let overrideExpiresAt: Date?
    let devices: [MasterLockDeviceProjection]

    var expectedDeviceIDs: [UUID] {
        devices.map(\.childDeviceID)
    }

    func displaysDeviceAsLocked(
        _ deviceID: UUID,
        fallbackLocked: Bool
    ) -> Bool {
        guard overrideExpiresAt != nil,
              let device = devices.first(where: { $0.childDeviceID == deviceID }),
              device.deliveryState == .confirmed
        else {
            return fallbackLocked
        }
        return false
    }

    func matchesConfirmation(of operation: MasterLockOperation) -> Bool {
        snapshotDigest == operation.snapshotDigest
            && overrideRevision == operation.revision
            && Set(expectedDeviceIDs) == Set(operation.expectedDeviceIDs)
    }

    init(
        childProfileID: UUID,
        snapshotDigest: String,
        overrideRevision: Int64,
        overrideExpiresAt: Date?,
        devices: [MasterLockDeviceProjection]
    ) {
        self.childProfileID = childProfileID
        self.snapshotDigest = snapshotDigest
        self.overrideRevision = overrideRevision
        self.overrideExpiresAt = overrideExpiresAt
        self.devices = devices
    }

    init(
        dto: ParentChildLockProjectionDTO,
        deviceNamesByID: [UUID: String] = [:]
    ) throws {
        childProfileID = dto.childProfileID
        snapshotDigest = dto.snapshotDigest
        overrideRevision = dto.overrideRevision
        overrideExpiresAt = try MasterLockServerDate.parseIfPresent(dto.overrideExpiresAt)
        devices = dto.devices.map { device in
            MasterLockDeviceProjection(
                childDeviceID: device.childDeviceID,
                deviceName: deviceNamesByID[device.childDeviceID] ?? "Device",
                identityVerified: device.identityVerified,
                manualAllApps: device.manualAllApps,
                earnedExhausted: device.earnedExhausted,
                taskIncomplete: device.taskIncomplete,
                deviceLimitActive: device.deviceLimitActive,
                limitedAppIDs: device.limitedAppIDs,
                limitedLegacyScopeIDs: device.limitedLegacyScopeIDs,
                reflectionActive: device.reflectionActive,
                deliveryState: device.deliveryState
            )
        }
    }
}

nonisolated struct MasterUnlockDeviceModel: Equatable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let manualAllApps: Bool
    let earnedExhausted: Bool
    let taskIncomplete: Bool
    let deviceLimitActive: Bool
    let limitedAppIDs: [UUID]
    let limitedLegacyScopeIDs: [String]
    let wholeDeviceLocked: Bool

    var hasAutomaticRestrictions: Bool {
        earnedExhausted
            || taskIncomplete
            || deviceLimitActive
            || !limitedAppIDs.isEmpty
            || !limitedLegacyScopeIDs.isEmpty
    }
}

nonisolated struct MasterUnlockSheetModel: Equatable, Sendable {
    let snapshotDigest: String
    let revision: Int64
    let expectedDeviceIDs: [UUID]
    let devices: [MasterUnlockDeviceModel]

    var hasAutomaticRestrictions: Bool {
        devices.contains(where: \.hasAutomaticRestrictions)
    }

    init(projection: MasterLockProjection) {
        snapshotDigest = projection.snapshotDigest
        revision = projection.overrideRevision
        expectedDeviceIDs = projection.expectedDeviceIDs
        devices = projection.devices
            .filter(\.hasManagedRestrictions)
            .map {
                MasterUnlockDeviceModel(
                    deviceID: $0.childDeviceID,
                    deviceName: $0.deviceName,
                    manualAllApps: $0.manualAllApps,
                    earnedExhausted: $0.earnedExhausted,
                    taskIncomplete: $0.taskIncomplete,
                    deviceLimitActive: $0.deviceLimitActive,
                    limitedAppIDs: $0.limitedAppIDs,
                    limitedLegacyScopeIDs: $0.limitedLegacyScopeIDs,
                    wholeDeviceLocked: $0.wholeDeviceLocked
                )
            }
    }
}

nonisolated struct MasterLockMixedModel: Equatable, Sendable {
    let lockedDeviceNames: [String]
    let unlockedDeviceNames: [String]
    let unlockSheet: MasterUnlockSheetModel?

    init(projection: MasterLockProjection) {
        lockedDeviceNames = projection.devices
            .filter(\.hasManagedRestrictions)
            .map(\.deviceName)
        unlockedDeviceNames = projection.devices
            .filter { !$0.hasManagedRestrictions }
            .map(\.deviceName)
        let sheet = MasterUnlockSheetModel(projection: projection)
        unlockSheet = sheet.hasAutomaticRestrictions ? sheet : nil
    }
}

nonisolated struct MasterLockDeliveryModel: Equatable, Sendable {
    let requestedAction: MasterLockRequestedAction
    let confirmedDeviceNames: [String]
    let waitingDeviceNames: [String]
    let failedDeviceNames: [String]
    let unreachableDeviceNames: [String]

    var canRetry: Bool {
        !waitingDeviceNames.isEmpty
            || !failedDeviceNames.isEmpty
            || !unreachableDeviceNames.isEmpty
    }

    init(projection: MasterLockProjection, operation: MasterLockOperation) {
        let projectionByID = Dictionary(
            uniqueKeysWithValues: projection.devices.map { ($0.childDeviceID, $0) }
        )
        let receiptByID = Dictionary(
            uniqueKeysWithValues: operation.receipts.map { ($0.deviceID, $0) }
        )
        var confirmed: [String] = []
        var waiting: [String] = []
        var failed: [String] = []
        var unreachable: [String] = []

        for deviceID in operation.expectedDeviceIDs {
            let device = projectionByID[deviceID]
            let name = device?.deviceName ?? "Device"
            let state: ParentControlDeliveryState
            if projection.overrideRevision == operation.revision, let device {
                state = device.deliveryState
            } else {
                state = receiptByID[deviceID]?.deliveryState ?? .waiting
            }
            let effectiveState: ParentControlDeliveryState
            if state == .confirmed,
               let device,
               !operation.desiredStateIsVisible(on: device, projection: projection) {
                effectiveState = .waiting
            } else {
                effectiveState = state
            }
            switch effectiveState {
            case .confirmed:
                confirmed.append(name)
            case .waiting:
                waiting.append(name)
            case .failed:
                failed.append(name)
            case .unreachable:
                unreachable.append(name)
            }
        }

        requestedAction = operation.requestedAction
        confirmedDeviceNames = confirmed
        waitingDeviceNames = waiting
        failedDeviceNames = failed
        unreachableDeviceNames = unreachable
    }
}

nonisolated struct MasterLockControlResponse: Equatable, Sendable {
    let childProfileID: UUID
    let revision: Int64
    let operationID: UUID
    let expiration: Date?
    let receipts: [MasterLockOperationReceipt]
    let projection: MasterLockProjection

    init(
        childProfileID: UUID,
        revision: Int64,
        operationID: UUID,
        expiration: Date?,
        receipts: [MasterLockOperationReceipt],
        projection: MasterLockProjection
    ) {
        self.childProfileID = childProfileID
        self.revision = revision
        self.operationID = operationID
        self.expiration = expiration
        self.receipts = receipts
        self.projection = projection
    }

    init(
        dto: ParentChildControlResponseDTO,
        deviceNamesByID: [UUID: String] = [:]
    ) throws {
        childProfileID = dto.childProfileID
        revision = dto.revision
        operationID = dto.operationID
        expiration = try MasterLockServerDate.parseIfPresent(dto.expiresAt)
        receipts = dto.receipts.map {
            MasterLockOperationReceipt(
                deviceID: $0.childDeviceID,
                deliveryState: $0.deliveryState
            )
        }
        projection = try MasterLockProjection(
            dto: dto.snapshot,
            deviceNamesByID: deviceNamesByID
        )
    }
}

nonisolated enum MasterLockProjectionError: Error, Equatable {
    case invalidServerDate(String)
}

private nonisolated enum MasterLockServerDate {
    static func parseIfPresent(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let parsed = fractional.date(from: raw) ?? plain.date(from: raw) else {
            throw MasterLockProjectionError.invalidServerDate(raw)
        }
        return parsed
    }
}
