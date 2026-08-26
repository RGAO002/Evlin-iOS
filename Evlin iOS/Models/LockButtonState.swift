import Foundation

/// B8 — pure value that drives the ProfileView green/red lock button.
///
/// Derived from `DeviceLockStateResponse.covering_sources`, or from
/// `EarnedSummaryDTO.state` for multi-device child-level display.
///
/// Three states:
/// - `.pending`           — no acked state yet (sources = nil); show spinner/neutral
/// - `.clear`             — selected set is unlocked (sources = [])
/// - `.shielded(who:)`    — locked; `who` lists which sources are active
enum LockButtonState: Equatable {
    case pending
    case clear
    case shielded(who: [String])

    // MARK: - Factory from lock-state acked fields

    /// Derive button state from the acked `covering_sources` array.
    ///
    /// Rules (in priority order):
    /// 1. If `sources` is nil    → `.pending` (no acked state yet)
    /// 2. If `sources` is empty  → `.clear`
    /// 3. Otherwise              → `.shielded(who: sources)`
    ///
    /// `exhausted` is intentionally not enough to show a red Unlock button.
    /// The button is an App Controls lock toggle, so red means the selected set
    /// is actually covered by a shield source.
    static func from(coveringSources: [String]?, exhausted: Bool?) -> LockButtonState {
        guard let sources = coveringSources else { return .pending }
        return sources.isEmpty ? .clear : .shielded(who: sources)
    }

    // MARK: - Factory from earned-summary state string

    /// Derive button state from `EarnedSummaryDTO.state`.
    /// Values: "ok" → clear; "exhausted" → shielded; nil → pending.
    static func from(summaryState: String?) -> LockButtonState {
        switch summaryState {
        case "exhausted": return .shielded(who: [])
        case "ok":        return .clear
        default:          return .pending
        }
    }

    // MARK: - Convenience

    /// True when the selected set is actively shielded (button should be red).
    var isShielded: Bool {
        if case .shielded = self { return true }
        return false
    }

    /// True when we have no acked state (button should be neutral / show spinner).
    var isPending: Bool { self == .pending }

    /// True when the selected set is clear (button should be green).
    var isClear: Bool { self == .clear }
}

/// Manual selected-set state across every device linked to one child profile.
nonisolated enum ManualLockAggregateState: Equatable {
    case unlocked
    case locked
    case mixed
    case pending

    static func reduce(
        expectedDeviceCount: Int,
        coveringSources: [[String]?]
    ) -> ManualLockAggregateState {
        guard expectedDeviceCount > 0,
              coveringSources.count == expectedDeviceCount,
              coveringSources.allSatisfy({ $0 != nil })
        else { return .pending }

        let manualByDevice = coveringSources.map { isManualLocked(coveringSources: $0) == true }
        if manualByDevice.allSatisfy({ $0 }) { return .locked }
        if manualByDevice.allSatisfy({ !$0 }) { return .unlocked }
        return .mixed
    }

    static func isManualLocked(coveringSources: [String]?) -> Bool? {
        guard let coveringSources else { return nil }
        return coveringSources.contains(where: isManualSource)
    }

    private static func isManualSource(_ source: String) -> Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "manual"
    }
}

/// Automatic lock display across a complete child-device snapshot.
/// A nil reduction means the caller must preserve its previous display state.
nonisolated enum AutomaticLockAggregateState: Equatable {
    case unlocked
    case locked

    static func reduce(
        expectedDeviceIDs: [UUID],
        lockedByDevice: [UUID: Bool]
    ) -> AutomaticLockAggregateState? {
        let expected = ManualLockOperationStatus.expectedDeviceIDs(
            displayed: expectedDeviceIDs,
            receipts: []
        )
        guard !expected.isEmpty,
              expected.allSatisfy({ lockedByDevice[$0] != nil })
        else { return nil }

        return expected.contains(where: { lockedByDevice[$0] == true }) ? .locked : .unlocked
    }
}

/// The only side effects the Profile lock button is allowed to request.
nonisolated enum ManualLockButtonIntent: String, Codable, Equatable, Sendable {
    case lockSelectedForChild
    case unlockSelectedForChild

    var wantsLocked: Bool { self == .lockSelectedForChild }

    static func from(
        state: ManualLockAggregateState,
        retryIntent: ManualLockButtonIntent?
    ) -> ManualLockButtonIntent? {
        if let retryIntent { return retryIntent }
        switch state {
        case .unlocked: return .lockSelectedForChild
        case .locked: return .unlockSelectedForChild
        case .mixed, .pending: return nil
        }
    }
}

nonisolated enum ManualLockAckOutcome: Equatable, Sendable {
    case confirmed
    case failed
    case pending

    static func from(status: String) -> ManualLockAckOutcome {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "confirmed", "confirmed_exact", "confirmed_fallback":
            return .confirmed
        case "failed", "timeout":
            return .failed
        default:
            return .pending
        }
    }
}

/// Coherent status for one child-wide operation. Error and neutral progress
/// are separate so a failed device cannot hide devices that are still queued.
nonisolated struct ManualLockOperationStatus: Equatable, Sendable {
    let failedDeviceCount: Int
    let remainingDeviceCount: Int

    var errorMessage: String? {
        guard failedDeviceCount > 0 else { return nil }
        let noun = failedDeviceCount == 1 ? "device" : "devices"
        return "\(failedDeviceCount) \(noun) couldn't apply the update."
    }

    var noteMessage: String? {
        guard needsUpdateDeviceCount > 0 else { return nil }
        let noun = needsUpdateDeviceCount == 1 ? "device" : "devices"
        let verb = needsUpdateDeviceCount == 1 ? "needs" : "need"
        return "\(needsUpdateDeviceCount) \(noun) still \(verb) update."
    }

    var needsUpdateDeviceCount: Int { failedDeviceCount + remainingDeviceCount }
    var isComplete: Bool { failedDeviceCount == 0 && remainingDeviceCount == 0 }

    static func from(
        expectedDeviceIDs: [UUID],
        ackByDevice: [UUID: ManualLockAckOutcome]
    ) -> ManualLockOperationStatus {
        let expected = Self.expectedDeviceIDs(displayed: expectedDeviceIDs, receipts: [])
        return ManualLockOperationStatus(
            failedDeviceCount: expected.filter { ackByDevice[$0] == .failed }.count,
            remainingDeviceCount: expected.filter {
                let outcome = ackByDevice[$0] ?? .pending
                return outcome == .pending
            }.count
        )
    }

    static func reconciled(
        expectedDeviceIDs: [UUID],
        ackByDevice: [UUID: ManualLockAckOutcome],
        manualLockedByDevice: [UUID: Bool],
        wantsLocked: Bool
    ) -> ManualLockOperationStatus {
        let expected = Self.expectedDeviceIDs(displayed: expectedDeviceIDs, receipts: [])
        let failedCount = expected.filter { ackByDevice[$0] == .failed }.count
        let remainingCount = expected.filter { deviceID in
            guard ackByDevice[deviceID] != .failed else { return false }
            return ackByDevice[deviceID] != .confirmed
                || manualLockedByDevice[deviceID] != wantsLocked
        }.count
        return ManualLockOperationStatus(
            failedDeviceCount: failedCount,
            remainingDeviceCount: remainingCount
        )
    }

    static func expectedDeviceIDs(
        displayed: [UUID],
        receipts: [UUID]
    ) -> [UUID] {
        var seen = Set<UUID>()
        return (displayed + receipts).filter { seen.insert($0).inserted }
    }
}

nonisolated struct ManualLockOperationReceipt: Codable, Equatable, Sendable {
    let deviceID: UUID
    let commandID: UUID?
}

/// Durable intent and command identity for one child-wide manual lock operation.
nonisolated struct ManualLockOperation: Codable, Equatable, Sendable {
    let childProfileID: UUID
    let operationID: UUID
    let intent: ManualLockButtonIntent
    let expectedDeviceIDs: [UUID]
    let receipts: [ManualLockOperationReceipt]

    init(
        childProfileID: UUID,
        operationID: UUID,
        intent: ManualLockButtonIntent,
        expectedDeviceIDs: [UUID],
        receipts: [ManualLockOperationReceipt]
    ) {
        var seenReceipts = Set<UUID>()
        let uniqueReceipts = receipts.filter { seenReceipts.insert($0.deviceID).inserted }
        self.childProfileID = childProfileID
        self.operationID = operationID
        self.intent = intent
        self.expectedDeviceIDs = ManualLockOperationStatus.expectedDeviceIDs(
            displayed: expectedDeviceIDs,
            receipts: uniqueReceipts.map(\.deviceID)
        )
        self.receipts = uniqueReceipts
    }

    static func provisional(
        childProfileID: UUID,
        operationID: UUID,
        intent: ManualLockButtonIntent,
        expectedDeviceIDs: [UUID]
    ) -> ManualLockOperation {
        let expected = ManualLockOperationStatus.expectedDeviceIDs(
            displayed: expectedDeviceIDs,
            receipts: []
        )
        return ManualLockOperation(
            childProfileID: childProfileID,
            operationID: operationID,
            intent: intent,
            expectedDeviceIDs: expected,
            receipts: expected.map {
                ManualLockOperationReceipt(deviceID: $0, commandID: nil)
            }
        )
    }

    var hasMissingReceipts: Bool {
        let receiptByDevice = Dictionary(
            uniqueKeysWithValues: receipts.map { ($0.deviceID, $0) }
        )
        return expectedDeviceIDs.contains { receiptByDevice[$0]?.commandID == nil }
    }

    func merging(receipts newReceipts: [ManualLockOperationReceipt]) -> ManualLockOperation {
        var orderedDeviceIDs = ManualLockOperationStatus.expectedDeviceIDs(
            displayed: expectedDeviceIDs,
            receipts: receipts.map(\.deviceID)
        )
        var receiptByDevice = Dictionary(
            uniqueKeysWithValues: receipts.map { ($0.deviceID, $0) }
        )
        for receipt in newReceipts {
            if !orderedDeviceIDs.contains(receipt.deviceID) {
                orderedDeviceIDs.append(receipt.deviceID)
            }
            if receipt.commandID != nil || receiptByDevice[receipt.deviceID] == nil {
                receiptByDevice[receipt.deviceID] = receipt
            }
        }
        return ManualLockOperation(
            childProfileID: childProfileID,
            operationID: operationID,
            intent: intent,
            expectedDeviceIDs: orderedDeviceIDs,
            receipts: orderedDeviceIDs.map {
                receiptByDevice[$0] ?? ManualLockOperationReceipt(deviceID: $0, commandID: nil)
            }
        )
    }
}

nonisolated enum ManualLockRequestFailureDisposition: Equatable, Sendable {
    case ambiguous
    case definitive
}

nonisolated enum ManualLockOperationAction: Equatable, Sendable {
    case persist(ManualLockOperation)
    case post(ManualLockOperation)
}

/// Pure request ordering and retry gate consumed by ProfileView.
nonisolated enum ManualLockOperationOrchestrator {
    static func begin(
        childProfileID: UUID,
        operationID: UUID,
        intent: ManualLockButtonIntent,
        expectedDeviceIDs: [UUID]
    ) -> [ManualLockOperationAction] {
        let operation = ManualLockOperation.provisional(
            childProfileID: childProfileID,
            operationID: operationID,
            intent: intent,
            expectedDeviceIDs: expectedDeviceIDs
        )
        return [.persist(operation), .post(operation)]
    }

    static func resumeAction(
        for operation: ManualLockOperation,
        requestInFlight: Bool,
        attemptedOperationIDs: Set<UUID>
    ) -> ManualLockOperationAction? {
        guard operation.hasMissingReceipts,
              !requestInFlight,
              !attemptedOperationIDs.contains(operation.operationID)
        else { return nil }
        return .post(operation)
    }

    static func operationAfterFailure(
        _ operation: ManualLockOperation,
        disposition: ManualLockRequestFailureDisposition
    ) -> ManualLockOperation? {
        disposition == .ambiguous ? operation : nil
    }
}

nonisolated enum ManualLockOperationStore {
    private static let keyPrefix = "evlin.pendingManualLockOperation."

    static func load(
        childProfileID: UUID,
        defaults: UserDefaults = .standard
    ) -> ManualLockOperation? {
        guard let data = defaults.data(forKey: key(childProfileID)) else { return nil }
        return try? JSONDecoder().decode(ManualLockOperation.self, from: data)
    }

    static func save(
        _ operation: ManualLockOperation,
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

/// Pure projection used after the initial request and on every later refresh.
nonisolated struct ManualLockOperationReconciliation: Equatable, Sendable {
    let status: ManualLockOperationStatus
    let displayState: ManualLockAggregateState
    let retryIntent: ManualLockButtonIntent?
    let shouldClearPersistence: Bool

    static func evaluate(
        operation: ManualLockOperation,
        ackByDevice: [UUID: ManualLockAckOutcome],
        manualLockedByDevice: [UUID: Bool],
        aggregateState: ManualLockAggregateState
    ) -> ManualLockOperationReconciliation {
        let status = ManualLockOperationStatus.reconciled(
            expectedDeviceIDs: operation.expectedDeviceIDs,
            ackByDevice: ackByDevice,
            manualLockedByDevice: manualLockedByDevice,
            wantsLocked: operation.intent.wantsLocked
        )
        let complete = status.isComplete
        let displayState: ManualLockAggregateState
        if complete {
            displayState = aggregateState
        } else {
            displayState = aggregateState == .mixed ? .mixed : .pending
        }
        return ManualLockOperationReconciliation(
            status: status,
            displayState: displayState,
            retryIntent: complete ? nil : operation.intent,
            shouldClearPersistence: complete
        )
    }
}

nonisolated struct ManualLockButtonPresentation: Equatable {
    enum Tone: Equatable {
        case lock
        case unlock
        case updating
    }

    let title: String
    let systemImage: String
    let tone: Tone
    let allowsTap: Bool

    static func from(
        state: ManualLockAggregateState,
        childName: String,
        requestActive: Bool = false,
        retryIntent: ManualLockButtonIntent? = nil
    ) -> ManualLockButtonPresentation {
        if requestActive {
            return updating(childName: childName)
        }

        if let retryIntent {
            let action = retryIntent.wantsLocked ? "locking" : "unlocking"
            return ManualLockButtonPresentation(
                title: "Retry \(action) \(childName)'s devices",
                systemImage: "arrow.triangle.2.circlepath",
                tone: retryIntent.wantsLocked ? .lock : .unlock,
                allowsTap: true
            )
        }

        switch state {
        case .unlocked:
            return ManualLockButtonPresentation(
                title: "Lock \(childName)'s devices",
                systemImage: "lock",
                tone: .lock,
                allowsTap: true
            )
        case .locked:
            return ManualLockButtonPresentation(
                title: "Unlock \(childName)'s devices",
                systemImage: "lock.open",
                tone: .unlock,
                allowsTap: true
            )
        case .mixed, .pending:
            return updating(childName: childName)
        }
    }

    private static func updating(childName: String) -> ManualLockButtonPresentation {
        ManualLockButtonPresentation(
            title: "Updating \(childName)'s devices",
            systemImage: "arrow.triangle.2.circlepath",
            tone: .updating,
            allowsTap: false
        )
    }
}

nonisolated enum MasterLockPresentation: Equatable, Sendable {
    case hiddenForReflection
    case updating
    case lockApps
    case unlockDirect
    case unlockWithDuration(MasterUnlockSheetModel)
    case mixed(MasterLockMixedModel)
    case overrideActive(expiresAt: Date)
    case delivery(MasterLockDeliveryModel)

    static func reduce(
        projection: MasterLockProjection,
        operation: MasterLockOperation? = nil
    ) -> MasterLockPresentation {
        if projection.devices.contains(where: \.reflectionActive) {
            return .hiddenForReflection
        }
        guard !projection.devices.isEmpty,
              projection.devices.allSatisfy(\.identityVerified)
        else {
            return .updating
        }

        if let operation,
           operation.childProfileID == projection.childProfileID {
            let delivery = MasterLockDeliveryModel(
                projection: projection,
                operation: operation
            )
            if delivery.canRetry {
                return .delivery(delivery)
            }
        } else if projection.devices.contains(where: {
            $0.deliveryState != .confirmed
        }) {
            return .updating
        }

        if let expiresAt = projection.overrideExpiresAt {
            return .overrideActive(expiresAt: expiresAt)
        }

        let restrictedCount = projection.devices.filter(\.hasManagedRestrictions).count
        if restrictedCount == 0 {
            return .lockApps
        }
        if restrictedCount != projection.devices.count {
            return .mixed(MasterLockMixedModel(projection: projection))
        }
        let sheet = MasterUnlockSheetModel(projection: projection)
        if sheet.hasAutomaticRestrictions {
            return .unlockWithDuration(sheet)
        }
        return .unlockDirect
    }
}
