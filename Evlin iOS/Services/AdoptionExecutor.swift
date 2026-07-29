import Foundation

/// Which shape of adoption a commit result calls for.
nonisolated enum AdoptionPlan: Equatable, Sendable {
    /// Same owner: the identity-switch teardown would be wrong, but the local
    /// machinery still has to be converged and rebased (see the note in
    /// `AdoptionExecutor.run`).
    case restoreConverge
    /// Different owner: the old identity must be dismantled before the new one
    /// is written.
    case identitySwitch
}

nonisolated enum AdoptionPlanner {
    static func plan(oldUUID: UUID?, newUUID: UUID) -> AdoptionPlan {
        oldUUID == newUUID ? .restoreConverge : .identitySwitch
    }
}

/// Everything the executor needs from the metering engines, injected so the
/// state machine can be tested without them. Production wiring forwards each
/// closure to the existing engine — it must never reimplement any of this.
nonisolated struct AdoptionHooks: Sendable {
    /// Finish any cleanup the engine had already persisted.
    let finishExistingCleanup: @Sendable () async throws -> Void
    /// Run a recovery pass so stalled handoffs and dead routes settle.
    let convergeLocalMachinery: @Sendable () async throws -> Void
    /// Replace the local counting baseline with the server's ledger.
    let rebaseFromServerLedger: @Sendable () async throws -> Void
    /// Persist the switch intent with the cleanup engine.
    let prepareIdentityCleanup: @Sendable (UUID?, UUID) async throws -> Void
    /// Stop the old monitors and wait for the durable acknowledgement.
    let teardownAndAwaitAck: @Sendable () async throws -> Void
    /// Write the new owner locally.
    let writeIdentity: @Sendable (UUID) async throws -> Void
    /// Fetch config under the new identity and arm.
    let bootstrap: @Sendable () async throws -> Void
}

/// Crash-resumable identity adoption.
///
/// Each phase is persisted before the next one runs, so a process death at any
/// point resumes from the record instead of redoing completed work — which
/// matters most on the switch path, where repeating the teardown after the new
/// identity is already written would dismantle the wrong thing.
nonisolated final class AdoptionExecutor: @unchecked Sendable {

    private let store: PendingAdoptionStore
    private let hooks: AdoptionHooks

    init(store: PendingAdoptionStore, hooks: AdoptionHooks) {
        self.store = store
        self.hooks = hooks
    }

    func run(record: PendingAdoptionRecord) async throws {
        guard let result = record.result else {
            // Defensive only. The caller (AdoptionResumer) is responsible for
            // replaying the commit to fill this in first; arriving here with no
            // result means the adoption is not ready to proceed.
            return
        }
        var rec = record

        switch AdoptionPlanner.plan(oldUUID: rec.oldUUID,
                                    newUUID: result.childDeviceID) {
        case .restoreConverge:
            // Skipping the identity-switch teardown is NOT the same as doing
            // nothing. A device usually reaches re-pairing because its state is
            // already tangled, so inheriting it wholesale restores straight back
            // into the problem: settle the old machinery, then take the server's
            // ledger as the baseline rather than merging a local high-water mark.
            if rec.phase == .committing {
                rec.phase = .converging
                try store.save(rec)
            }
            try await hooks.finishExistingCleanup()
            try await hooks.convergeLocalMachinery()
            try await hooks.rebaseFromServerLedger()
            try await hooks.bootstrap()

        case .identitySwitch:
            if rec.phase == .committing || rec.phase == .converging {
                rec.phase = .cleanupPrepared
                try store.save(rec)
            }
            if rec.phase == .cleanupPrepared {
                try await hooks.prepareIdentityCleanup(rec.oldUUID,
                                                       result.childDeviceID)
                try await hooks.teardownAndAwaitAck()
                try await hooks.writeIdentity(result.childDeviceID)
                rec.phase = .identityWritten
                try store.save(rec)
            }
            try await hooks.bootstrap()
        }

        store.clear()
    }
}

/// Launch-time entry point: resume an interrupted adoption.
///
/// The replay must happen before any hook runs. A record whose commit response
/// was lost has no result yet, and starting the teardown without one would
/// dismantle the old identity with nothing to adopt in its place.
nonisolated struct AdoptionResumer: Sendable {

    let store: PendingAdoptionStore
    let replay: @Sendable (PendingAdoptionRecord) async throws -> PairingCommitResult
    let execute: @Sendable (PendingAdoptionRecord) async throws -> Void

    func resumeIfPending() async {
        guard var record = store.load() else { return }
        if record.result == nil {
            guard let result = try? await replay(record) else { return }
            record.result = result
            // The contract of this type is that the result is durable before
            // anything acts on it; a failed write must abort and let the next
            // launch retry, not proceed on a record that may not exist.
            do {
                try store.save(record)
            } catch {
                return
            }
        }
        try? await execute(record)
    }
}
