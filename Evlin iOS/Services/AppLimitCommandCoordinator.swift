import Foundation

/// Arbitrates tokened app-limit commands before an owner applies their effects.
nonisolated final class AppLimitCommandCoordinator: @unchecked Sendable {
    private let store: AppLimitEpochStore
    private let expectedOwnerProvider: @Sendable () -> UUID?

    init(
        store: AppLimitEpochStore = .shared,
        expectedOwnerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current
    ) {
        self.store = store
        self.expectedOwnerProvider = expectedOwnerProvider
    }

    func ingest(_ command: AppLimitCommandEnvelope) throws -> AppLimitCommandDisposition {
        try store.transaction(
            source: command.source,
            expectedOwner: expectedOwnerProvider()
        ) { state in
            guard let current = state.slots[command.ruleID] else {
                state.slots[command.ruleID] = AppLimitVersionSlot(accepting: command)
                return .acceptedNeedsOwner
            }

            if command.orderingToken < current.latestOrderingToken {
                return .superseded(latestOrderingToken: current.latestOrderingToken)
            }

            if command.orderingToken > current.latestOrderingToken {
                state.slots[command.ruleID] = AppLimitVersionSlot(accepting: command)
                return .acceptedNeedsOwner
            }

            guard command.kind == current.latestKind,
                  command.payloadDigest == current.latestPayloadDigest
            else { return .equalTokenConflict }

            if let receipt = current.appliedReceipt {
                return .duplicateApplied(receipt)
            }
            return .duplicatePending
        }
    }
}
