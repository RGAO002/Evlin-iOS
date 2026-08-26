import Foundation

nonisolated enum MasterUnlockDuration: Codable, Equatable, Sendable {
    case minutes(Int)
    case untilTomorrow
}

nonisolated enum MasterLockRequestedAction: Codable, Equatable, Sendable {
    case lockApps
    case unlockDirect
    case unlockOverride(MasterUnlockDuration)
    case cancelOverrideAndLock
}

nonisolated struct MasterLockOperationReceipt: Codable, Equatable, Sendable {
    let deviceID: UUID
    let deliveryState: ParentControlDeliveryState
}

nonisolated struct MasterLockOperation: Codable, Equatable, Sendable {
    let childProfileID: UUID
    let operationID: UUID
    let expectedDeviceIDs: [UUID]
    let revision: Int64
    let snapshotDigest: String
    let requestedAction: MasterLockRequestedAction
    let receipts: [MasterLockOperationReceipt]
    let expiration: Date?
    let submitted: Bool

    init(
        childProfileID: UUID,
        operationID: UUID,
        expectedDeviceIDs: [UUID],
        revision: Int64,
        snapshotDigest: String,
        requestedAction: MasterLockRequestedAction,
        receipts: [MasterLockOperationReceipt],
        expiration: Date?,
        submitted: Bool
    ) {
        self.childProfileID = childProfileID
        self.operationID = operationID
        self.expectedDeviceIDs = Self.unique(expectedDeviceIDs)
        self.revision = revision
        self.snapshotDigest = snapshotDigest
        self.requestedAction = requestedAction
        self.receipts = receipts
        self.expiration = expiration
        self.submitted = submitted
    }

    static func prepared(
        projection: MasterLockProjection,
        operationID: UUID,
        requestedAction: MasterLockRequestedAction
    ) -> MasterLockOperation {
        MasterLockOperation(
            childProfileID: projection.childProfileID,
            operationID: operationID,
            expectedDeviceIDs: projection.expectedDeviceIDs,
            revision: projection.overrideRevision,
            snapshotDigest: projection.snapshotDigest,
            requestedAction: requestedAction,
            receipts: [],
            expiration: nil,
            submitted: false
        )
    }

    func accepting(_ response: MasterLockControlResponse) throws -> MasterLockOperation {
        guard response.childProfileID == childProfileID,
              response.operationID == operationID,
              response.revision >= revision
        else {
            throw MasterLockOperationError.mismatchedResponse
        }
        return MasterLockOperation(
            childProfileID: childProfileID,
            operationID: operationID,
            expectedDeviceIDs: Self.unique(
                expectedDeviceIDs + response.receipts.map(\.deviceID)
            ),
            revision: response.revision,
            snapshotDigest: response.projection.snapshotDigest,
            requestedAction: requestedAction,
            receipts: response.receipts,
            expiration: response.expiration,
            submitted: true
        )
    }

    private static func unique(_ deviceIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return deviceIDs.filter { seen.insert($0).inserted }
    }

    func desiredStateIsVisible(
        on device: MasterLockDeviceProjection,
        projection: MasterLockProjection
    ) -> Bool {
        switch requestedAction {
        case .lockApps, .cancelOverrideAndLock:
            return projection.overrideExpiresAt == nil && device.manualAllApps
        case .unlockDirect:
            return projection.overrideExpiresAt == nil && !device.manualAllApps
        case .unlockOverride:
            return projection.overrideExpiresAt != nil && !device.manualAllApps
        }
    }
}

nonisolated enum MasterLockOperationError: Error, Equatable {
    case mismatchedResponse
}

nonisolated enum MasterLockOperationStore {
    private static let keyPrefix = "evlin.pendingMasterLockOperation."

    static func load(
        childProfileID: UUID,
        defaults: UserDefaults = .standard
    ) -> MasterLockOperation? {
        guard let data = defaults.data(forKey: key(childProfileID)) else { return nil }
        return try? JSONDecoder().decode(MasterLockOperation.self, from: data)
    }

    static func save(
        _ operation: MasterLockOperation,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(operation) else { return }
        defaults.set(data, forKey: key(operation.childProfileID))
    }

    static func clear(
        childProfileID: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(childProfileID))
    }

    private static func key(_ childProfileID: UUID) -> String {
        keyPrefix + childProfileID.uuidString.lowercased()
    }
}

nonisolated enum MasterLockOperationResumeAction: Equatable, Sendable {
    case submit(MasterLockOperation)
    case reconcile(MasterLockOperation)
}

nonisolated enum MasterLockConfirmationResult: Equatable, Sendable {
    case projectionChanged(MasterLockProjection, MasterLockPresentation)
    case submitted(MasterLockOperation, MasterLockProjection)
}

nonisolated enum MasterLockOperationCoordinator {
    static func resumeAction(
        for operation: MasterLockOperation
    ) -> MasterLockOperationResumeAction {
        operation.submitted ? .reconcile(operation) : .submit(operation)
    }

    static func confirm(
        operation: MasterLockOperation,
        defaults: UserDefaults = .standard,
        refresh: () async throws -> MasterLockProjection,
        submit: (MasterLockOperation) async throws -> MasterLockControlResponse
    ) async throws -> MasterLockConfirmationResult {
        let current = try await refresh()
        guard current.matchesConfirmation(of: operation) else {
            return .projectionChanged(
                current,
                MasterLockPresentation.reduce(projection: current)
            )
        }

        MasterLockOperationStore.save(operation, defaults: defaults)
        let response = try await submit(operation)
        let submitted = try operation.accepting(response)
        MasterLockOperationStore.save(submitted, defaults: defaults)
        return .submitted(submitted, response.projection)
    }
}

nonisolated struct MasterLockOperationReconciliation: Equatable, Sendable {
    let presentation: MasterLockPresentation
    let shouldClearPersistence: Bool

    static func evaluate(
        operation: MasterLockOperation,
        projection: MasterLockProjection
    ) -> MasterLockOperationReconciliation {
        if projection.overrideRevision > operation.revision {
            return MasterLockOperationReconciliation(
                presentation: MasterLockPresentation.reduce(projection: projection),
                shouldClearPersistence: true
            )
        }

        let projectionByID = Dictionary(
            uniqueKeysWithValues: projection.devices.map { ($0.childDeviceID, $0) }
        )
        let complete = operation.submitted
            && projection.overrideRevision == operation.revision
            && operation.expectedDeviceIDs.allSatisfy {
                projectionByID[$0]?.deliveryState == .confirmed
            }
            && desiredStateIsVisible(
                for: operation,
                projection: projection,
                projectionByID: projectionByID
            )
        if complete {
            return MasterLockOperationReconciliation(
                presentation: MasterLockPresentation.reduce(projection: projection),
                shouldClearPersistence: true
            )
        }
        return MasterLockOperationReconciliation(
            presentation: MasterLockPresentation.reduce(
                projection: projection,
                operation: operation
            ),
            shouldClearPersistence: false
        )
    }

    private static func desiredStateIsVisible(
        for operation: MasterLockOperation,
        projection: MasterLockProjection,
        projectionByID: [UUID: MasterLockDeviceProjection]
    ) -> Bool {
        guard operation.expectedDeviceIDs.allSatisfy({ projectionByID[$0] != nil }) else {
            return false
        }
        switch operation.requestedAction {
        case .lockApps, .cancelOverrideAndLock, .unlockDirect, .unlockOverride:
            return operation.expectedDeviceIDs.allSatisfy { deviceID in
                guard let device = projectionByID[deviceID] else { return false }
                return operation.desiredStateIsVisible(on: device, projection: projection)
            }
        }
    }
}

nonisolated enum MasterLockTaskOverrideChoice: Equatable, Sendable {
    case lockNow
    case keepUnlocked
}

nonisolated enum MasterLockTaskOverrideDecision: Equatable, Sendable {
    case submit(MasterLockOperation)
    case keepUnlocked(MasterLockProjection)

    static func resolve(
        choice: MasterLockTaskOverrideChoice,
        projection: MasterLockProjection,
        operationID: UUID
    ) -> MasterLockTaskOverrideDecision {
        switch choice {
        case .keepUnlocked:
            return .keepUnlocked(projection)
        case .lockNow:
            return .submit(
                MasterLockOperation.prepared(
                    projection: projection,
                    operationID: operationID,
                    requestedAction: .cancelOverrideAndLock
                )
            )
        }
    }
}
