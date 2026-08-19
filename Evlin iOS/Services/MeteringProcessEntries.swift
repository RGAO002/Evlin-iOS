import Foundation
import FamilyControls

nonisolated struct AppLimitOwnerEffectResult: Sendable {
    let armID: UUID?
    let source: String
}

nonisolated protocol AppLimitOwnerEffectPort: Sendable {
    func apply(
        work: AppLimitOwnerWork,
        slot: AppLimitVersionSlot
    ) async throws -> AppLimitOwnerEffectResult
}

@MainActor
final class AppLimitOwnerRecoveryDriver {
    private enum RecoveryError: Error {
        case staleWork
        case receiptReadbackMismatch
    }

    private let store: AppLimitEpochStore
    private let effectPort: any AppLimitOwnerEffectPort
    private let readbackPort: any AppLimitOwnerReadbackPort
    private let afterClaim: (AppLimitOwnerWork) async throws -> Void
    private let beforeConfirm: (AppLimitOwnerWork) async throws -> Void
    private var isRecovering = false
    private var recoveryRequested = false

    init(
        store: AppLimitEpochStore = .shared,
        effectPort: any AppLimitOwnerEffectPort,
        readbackPort: any AppLimitOwnerReadbackPort,
        afterClaim: @escaping (AppLimitOwnerWork) async throws -> Void = { _ in },
        beforeConfirm: @escaping (AppLimitOwnerWork) async throws -> Void = { _ in }
    ) {
        self.store = store
        self.effectPort = effectPort
        self.readbackPort = readbackPort
        self.afterClaim = afterClaim
        self.beforeConfirm = beforeConfirm
    }

    func recover(ownerChildDeviceID: UUID) async {
        guard !isRecovering else {
            recoveryRequested = true
            return
        }
        isRecovering = true
        defer { isRecovering = false }

        repeat {
            recoveryRequested = false
            let works: [AppLimitOwnerWork]
            do {
                let state = try store.read()
                guard state.ownerChildDeviceID == ownerChildDeviceID else {
                    NSLog(
                        "[Evlin/AppLimit] owner recovery skipped: store owner=%@ configured owner=%@",
                        state.ownerChildDeviceID?.uuidString ?? "missing",
                        ownerChildDeviceID.uuidString
                    )
                    return
                }
                works = state.slots.values.compactMap { slot in
                    guard let work = slot.pendingOwnerWork,
                          Self.matches(work, slot: slot)
                    else { return nil }
                    return work
                }.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.ruleID.uuidString < $1.ruleID.uuidString
                }
            } catch {
                NSLog("[Evlin/AppLimit] owner recovery read failed: %@", String(describing: error))
                return
            }

            for work in works {
                await recover(work: work, ownerChildDeviceID: ownerChildDeviceID)
            }
        } while recoveryRequested
    }

    private func recover(
        work: AppLimitOwnerWork,
        ownerChildDeviceID: UUID
    ) async {
        do {
            try await afterClaim(work)
            let slot = try currentSlot(
                for: work,
                ownerChildDeviceID: ownerChildDeviceID
            )
            let receipt: AppLimitApplyReceipt
            if let existing = slot.appliedReceipt {
                guard try AppLimitReceiptReadback.currentAppliedReceipt(
                    ruleID: work.ruleID,
                    store: store
                ) == existing else { throw RecoveryError.receiptReadbackMismatch }
                receipt = existing
            } else {
                let effect = try await effectPort.apply(work: work, slot: slot)
                receipt = try store.transaction(
                    source: .wakeRecovery,
                    expectedOwner: ownerChildDeviceID
                ) { state -> AppLimitApplyReceipt in
                    guard var current = state.slots[work.ruleID],
                          Self.matches(work, slot: current),
                          current.appliedReceipt == nil,
                          state.storeRevision < UInt64.max
                    else { throw RecoveryError.staleWork }
                    let armID: UUID?
                    switch work.commandKind {
                    case .set:
                        if current.isAuthoritativelyExhausted {
                            guard effect.armID == nil else {
                                throw RecoveryError.staleWork
                            }
                            armID = nil
                        } else {
                            guard let provenance = current.armProvenance,
                                  provenance.ruleRevision == work.orderingToken,
                                  effect.armID == provenance.armID
                            else { throw RecoveryError.staleWork }
                            armID = provenance.armID
                        }
                    case .clear:
                        guard effect.armID == nil else { throw RecoveryError.staleWork }
                        armID = nil
                    }
                    let appliedAt = Date(
                        timeIntervalSince1970: floor(Date().timeIntervalSince1970)
                    )
                    let receipt = AppLimitApplyReceipt(
                        ruleID: work.ruleID,
                        orderingToken: work.orderingToken,
                        commandKind: work.commandKind,
                        armID: armID,
                        source: effect.source,
                        appliedAt: appliedAt,
                        storeRevision: state.storeRevision + 1
                    )
                    // Keep the exact work until owner confirmation succeeds.
                    // A restart can then retry the network readback without
                    // applying the DeviceActivity/ManagedSettings effect again.
                    current.appliedReceipt = receipt
                    state.slots[work.ruleID] = current
                    return receipt
                }
            }

            let persisted = try AppLimitReceiptReadback.currentAppliedReceipt(
                ruleID: work.ruleID,
                store: store
            )
            guard persisted == receipt else {
                throw RecoveryError.receiptReadbackMismatch
            }
            try await beforeConfirm(work)
            let current = try store.read()
            guard current.ownerChildDeviceID == ownerChildDeviceID,
                  let currentSlot = current.slots[work.ruleID],
                  currentSlot.pendingOwnerWork == work,
                  currentSlot.latestOrderingToken == work.orderingToken,
                  currentSlot.latestKind == work.commandKind,
                  currentSlot.latestPayloadDigest == work.payloadDigest,
                  currentSlot.appliedReceipt == receipt
            else { throw RecoveryError.staleWork }
            try await readbackPort.confirm(
                commandID: work.commandID,
                receipt: receipt
            )
            try store.transaction(
                source: .wakeRecovery,
                expectedOwner: ownerChildDeviceID
            ) { state in
                guard var confirmed = state.slots[work.ruleID],
                      Self.matches(work, slot: confirmed),
                      confirmed.appliedReceipt == receipt
                else { throw RecoveryError.staleWork }
                confirmed.pendingOwnerWork = nil
                state.slots[work.ruleID] = confirmed
            }
        } catch {
            NSLog(
                "[Evlin/AppLimit] owner recovery failed rule=%@ token=%llu kind=%@ error=%@",
                work.ruleID.uuidString,
                work.orderingToken,
                work.commandKind.rawValue,
                String(describing: error)
            )
            // Pending work remains durable unless an exact receipt was committed.
            // A later wake retries it; a newer token supersedes it in the store.
        }
    }

    private func currentSlot(
        for work: AppLimitOwnerWork,
        ownerChildDeviceID: UUID
    ) throws -> AppLimitVersionSlot {
        let state = try store.read()
        guard state.ownerChildDeviceID == ownerChildDeviceID,
              let slot = state.slots[work.ruleID],
              Self.matches(work, slot: slot)
        else { throw RecoveryError.staleWork }
        return slot
    }

    private static func matches(
        _ work: AppLimitOwnerWork,
        slot: AppLimitVersionSlot
    ) -> Bool {
        slot.pendingOwnerWork == work
            && slot.latestOrderingToken == work.orderingToken
            && slot.latestKind == work.commandKind
            && slot.latestPayloadDigest == work.payloadDigest
    }
}

@MainActor
final class AppLimitEffectRecoveryDriver {
    private let journal: AppLimitEffectJournal
    private let usageStore: EarnedTimeStore
    private let shieldPersistence: AppLimitShieldPersistence
    private let transport: any MeteringHTTPTransport
    private let workerID: UUID
    private let projectRestrictions: @MainActor @Sendable () async -> Void

    init(
        journal: AppLimitEffectJournal = AppLimitEffectJournal(),
        usageStore: EarnedTimeStore = .shared,
        shieldPersistence: AppLimitShieldPersistence = AppLimitShieldPersistence(
            store: UserDefaults(suiteName: MeteringProductionComposition.appGroupSuiteName)
        ),
        transport: any MeteringHTTPTransport = URLSession.shared,
        workerID: UUID = UUID(),
        projectRestrictions: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.journal = journal
        self.usageStore = usageStore
        self.shieldPersistence = shieldPersistence
        self.transport = transport
        self.workerID = workerID
        self.projectRestrictions = projectRestrictions
    }

    func recover(
        baseURL: URL,
        ownerChildDeviceID: UUID,
        now: Date
    ) async {
        do {
            while true {
                guard let claim = try journal.claimNext(workerID: workerID, now: now) else {
                    break
                }
                let receipt = try journal.applyLocal(
                    claim,
                    source: "app_lifecycle_recovery",
                    appliedAt: now
                ) { [usageStore, shieldPersistence] callback in
                    try AppLimitEffectLocalPersistence.persist(
                        callback,
                        usageStore: usageStore,
                        shieldPersistence: shieldPersistence,
                        now: now
                    )
                }
                guard receipt != nil else { continue }
                if claim.effect.key.effectKind == .enforcement {
                    await projectRestrictions()
                }
                _ = try await journal.submitUsage(
                    claim,
                    baseURL: baseURL,
                    deviceID: ownerChildDeviceID,
                    transport: transport,
                    appliedAt: now
                )
            }
        } catch {
            NSLog("[Evlin/AppLimit] effect recovery failed: %@", String(describing: error))
            // The lease and receipts remain durable for a later lifecycle entry.
        }
    }
}

@MainActor
final class AppMeteringEntry {
    static let shared = AppMeteringEntry()

    /// Injected by the app target (the DeviceActivity extension compiles this
    /// file but not MeteringWatchdog). Fired after a recovery pass whose
    /// active route differs from the one before it — e.g. the conservative
    /// resume after a reflection mints a fresh route, and without an
    /// immediate check the parent sees SYNCING until the 5-min watchdog
    /// throttle expires or the first sample lands (~10 min of usage).
    var onActiveRouteChanged: (@Sendable (UUID?) async -> Void)?

    private let defaults: UserDefaults?
    private let store: DeviceEpochStore
    private let center: any MeteringDeviceActivityCenter
    private let transport: any MeteringHTTPTransport
    private let clock: any MeteringClock
    private let instanceID: UUID
    private let callbackJournal: EarnedV2CallbackJournal

    init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: MeteringProductionComposition.appGroupSuiteName
        ),
        store: DeviceEpochStore = .shared,
        center: (any MeteringDeviceActivityCenter)? = nil,
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        instanceID: UUID = MeteringProductionComposition.instanceID(for: .app),
        callbackJournal: EarnedV2CallbackJournal = EarnedV2CallbackJournal()
    ) {
        self.defaults = defaults
        self.store = store
        self.center = center ?? SystemMeteringDeviceActivityCenter()
        self.transport = transport
        self.clock = clock
        self.instanceID = instanceID
        self.callbackJournal = callbackJournal
    }

    func recoverIfConfigured() async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        await replayCallbacks(owner: configuration.owner)
        // Maintenance runs only in the app process, where memory is not capped
        // like the DeviceActivity extension, and off the main actor so a large
        // historical root cannot stall scene updates.
        do {
            let maintenanceStore = store
            _ = try await Task.detached(priority: .utility) {
                try maintenanceStore.compactTerminalRegistrationHistory(
                    owner: configuration.owner
                )
            }.value
        } catch {
            MeteringFlightRecorder.emitError(
                site: "app.compact",
                error: error
            )
        }
        let driver = MeteringProductionComposition.makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: .app,
            instanceID: instanceID,
            store: store,
            center: center,
            transport: transport,
            clock: clock
        )
        let routeBefore = (try? store.read())?.activeRouteID
        do {
            try await driver.recover(ownerChildDeviceID: configuration.owner)
        } catch {
            print("[AppMeteringEntry] recovery failed: \(error)")
            MeteringFlightRecorder.emitError(site: "app.recover", error: error)
        }
        let routeAfter = (try? store.read())?.activeRouteID
        if routeAfter != routeBefore {
            await onActiveRouteChanged?(routeAfter)
        }
    }

    /// Drain callbacks recorded by the DeviceActivity extension without
    /// requiring a scene transition or a manual repair action.
    func replayCallbacksIfConfigured() async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        await replayCallbacks(owner: configuration.owner)
    }

    private func replayCallbacks(owner: UUID) async {
        do {
            let replayStore = store
            let replayJournal = callbackJournal
            _ = try await Task.detached(priority: .utility) {
                try replayJournal.replay(
                    into: replayStore,
                    owner: owner
                )
            }.value
        } catch {
            MeteringFlightRecorder.emitError(
                site: "app.callbackJournal",
                error: error
            )
        }
    }
}

/// This injected process entry is intentionally nonisolated. Under the
/// project's MainActor default, its synthesized deinit uses the actor
/// back-deployment shim and double-frees when short-lived test instances are
/// released. Production uses the singleton, while tests construct serial,
/// independent instances, so the unchecked sendability promise is bounded.
nonisolated final class DAMMeteringEntry: @unchecked Sendable {
    static let shared = DAMMeteringEntry()

    private let defaults: UserDefaults?
    private let store: DeviceEpochStore
    private let center: (any MeteringDeviceActivityCenter)?
    private let transport: any MeteringHTTPTransport
    private let clock: any MeteringClock
    private let instanceID: UUID
    private let earnedStore: EarnedTimeStore
    private let effectStore: EarnedShieldEffectStore
    private let selectionProvider: () -> FamilyActivitySelection
    private let callbackJournal: EarnedV2CallbackJournal

    init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: MeteringProductionComposition.appGroupSuiteName
        ),
        store: DeviceEpochStore = .shared,
        center: (any MeteringDeviceActivityCenter)? = nil,
        transport: any MeteringHTTPTransport = URLSession.shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        instanceID: UUID = MeteringProductionComposition.instanceID(
            for: .deviceActivityMonitor
        ),
        earnedStore: EarnedTimeStore = .shared,
        effectStore: EarnedShieldEffectStore? = nil,
        callbackJournal: EarnedV2CallbackJournal = EarnedV2CallbackJournal(),
        selectionProvider: @escaping () -> FamilyActivitySelection = {
            DefaultLockGroupStore.load()
        }
    ) {
        self.defaults = defaults
        self.store = store
        self.center = center
        self.transport = transport
        self.clock = clock
        self.instanceID = instanceID
        self.earnedStore = earnedStore
        self.effectStore = effectStore ?? EarnedShieldEffectStore(
            defaults: defaults,
            epochStore: store
        )
        self.callbackJournal = callbackJournal
        self.selectionProvider = selectionProvider
    }

    @MainActor
    func recoverIfConfigured(
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) async {
        await recoverMeteringIfConfigured()
        await recoverShieldEffectsIfConfigured(projectShields: projectShields)
    }

    /// The DeviceActivity extension must be able to finish this path inside its
    /// synchronous callback lifetime. Keep the callback-journal import and the
    /// existing recovery sender independent of MainActor-only shield projection.
    func recoverMeteringIfConfigured() async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        await deliverPendingCallbacks(
            owner: configuration.owner,
            baseURL: configuration.baseURL
        )
        let driver = MeteringProductionComposition.makeRecoveryDriver(
            baseURL: configuration.baseURL,
            role: .deviceActivityMonitor,
            instanceID: instanceID,
            store: store,
            center: center ?? SystemMeteringDeviceActivityCenter(),
            transport: transport,
            clock: clock
        )
        do {
            try await driver.recover(ownerChildDeviceID: configuration.owner)
        } catch {
            NSLog("[DAMMeteringEntry] network recovery failed: %@", String(describing: error))
            MeteringFlightRecorder.emitError(site: "dam.recover", error: error)
        }
    }

    /// Import and deliver already-authorized callback work without touching
    /// DeviceActivityCenter. A threshold callback has only a short synchronous
    /// lifetime; spending it on daemon reconciliation can strand a valid sample
    /// until the child opens the host app.
    ///
    /// `budget` caps the network work of ONE pass (the extension passes
    /// `MeteringDrainBudget.extensionDefault()`; the host app keeps
    /// `.unlimited()`). Whatever the pass leaves behind stays in the journal
    /// for the next callback, the app's foreground drain, or a background wake.
    func deliverPendingCallbacksIfConfigured(
        budget: MeteringDrainBudget = .unlimited()
    ) async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        await deliverPendingCallbacks(
            owner: configuration.owner,
            baseURL: configuration.baseURL,
            budget: budget
        )
    }

    private func deliverPendingCallbacks(
        owner: UUID,
        baseURL: URL,
        budget: MeteringDrainBudget = .unlimited()
    ) async {
        do {
            _ = try await callbackJournal.submitPendingTransport(
                owner: owner,
                baseURL: baseURL,
                transport: transport,
                recordedAt: clock.now,
                budget: budget
            )
        } catch {
            MeteringFlightRecorder.emitError(
                site: "dam.callbackJournal.transport",
                error: error
            )
        }
        await replayCallbacks(owner: owner)
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: clock
        )
        await delivery.drain(owner: owner, importLegacyWork: false, budget: budget)
    }

    @MainActor
    func recoverShieldEffectsIfConfigured(
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) async {
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
            return
        }
        do {
            try recoverShieldEffects(
                expectedOwner: configuration.owner,
                projectShields: projectShields
            )
        } catch {
            NSLog("[DAMMeteringEntry] shield recovery failed: %@", String(describing: error))
            MeteringFlightRecorder.emitError(site: "dam.shieldRecover", error: error)
        }
    }

    private func replayCallbacks(owner: UUID) async {
        do {
            let replayStore = store
            let replayJournal = callbackJournal
            _ = try await Task.detached(priority: .utility) {
                try replayJournal.replay(
                    into: replayStore,
                    owner: owner
                )
            }.value
        } catch {
            MeteringFlightRecorder.emitError(
                site: "dam.callbackJournal",
                error: error
            )
        }
    }

    @MainActor
    func handleIntervalDidEnd(activityName: String) async {
        guard activityName.hasPrefix(MeteringRouteNamespace.prefix) else {
            return
        }
        await recoverIfConfigured()
    }

    func handle(
        activityName: String,
        eventName: String,
        observedAt: Date,
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) throws -> EarnedMeteringCallbackOutcome {
#if DEBUG
        func checkpoint(_ stage: String) {
            defaults?.set(
                "\(ISO8601DateFormatter().string(from: Date())) \(stage)"
                    + " activity=\(activityName) event=\(eventName)",
                forKey: "evlin.metering.lastCallbackStage"
            )
            defaults?.synchronize()
        }
        checkpoint("entered")
#endif
        guard let configuration = MeteringProcessConfiguration.load(defaults: defaults) else {
#if DEBUG
            checkpoint("missing_configuration")
#endif
            return .discarded(reason: "missing_shared_configuration")
        }
#if DEBUG
        checkpoint("configuration_loaded")
#endif
        let callback = MeteringProductionComposition.makeCallback(
            store: store,
            clock: clock,
            journal: callbackJournal
        )
        let appleCallback = MeteringAppleCallback(
            activityName: activityName,
            eventName: eventName,
            observedAt: observedAt
        )
#if DEBUG
        checkpoint("before_terminal_candidate")
#endif
        let terminalCandidate = try callback.terminalCandidate(
            appleCallback,
            expectedOwnerChildDeviceID: configuration.owner
        )
#if DEBUG
        checkpoint("after_terminal_candidate")
#endif
        guard let candidate = terminalCandidate else {
#if DEBUG
            checkpoint("before_callback_handle")
#endif
            let outcome = try callback.handleDurably(
                appleCallback,
                expectedOwnerChildDeviceID: configuration.owner
            )
#if DEBUG
            checkpoint("after_callback_handle")
#endif
            return outcome
        }

        let suppressed = {
            !self.earnedStore.usageCountingAllowed
                || self.earnedStore.isOverridden(forUsageDate: candidate.usageDate)
        }
        guard !suppressed() else {
            return try callback.handle(
                appleCallback,
                expectedOwnerChildDeviceID: configuration.owner
            )
        }

        let envelope: EarnedShieldEffectEnvelope
        do {
            guard let prepared = try effectStore.prepareTerminal(
                candidate,
                selection: selectionProvider(),
                appliesToAll: earnedStore.lockedSetAllSelected,
                isSuppressed: suppressed
            ) else {
                return try callback.handle(
                    appleCallback,
                    expectedOwnerChildDeviceID: configuration.owner
                )
            }
            envelope = prepared
        } catch {
            NSLog("[DAMMeteringEntry] terminal shield prepare failed: %@", String(describing: error))
            // The terminal rung is the one that applies the lock, and Apple
            // delivers it exactly once — the `callback.handle` below ratchets
            // the epoch past it, so there is no second chance from the daemon.
            // Logging the throw and carrying on meant "the child's time ran out
            // and nothing locked", with no durable trace for any retry to act
            // on (kid_extension 2026-07-25 13:37:28, `durableReadbackMismatch`).
            // Queue the lock durably instead: `recoverShieldEffects` retries it
            // on every wake until it lands, and the minutes still count.
            MeteringFlightRecorder.emitError(
                site: "dam.terminalShield",
                error: error,
                detail: MeteringFlightRecorder.detail([("queued", "retry")]),
                corrID: candidate.routeID
            )
            do {
                try effectStore.recordPendingTerminal(
                    candidate,
                    errorCode: MeteringFlightRecorder.describe(error),
                    now: clock.now
                )
            } catch {
                // Losing the durable queue is the one failure that genuinely
                // cannot be retried later, so it gets its own record.
                MeteringFlightRecorder.emitError(
                    site: "dam.terminalQueue",
                    error: error,
                    corrID: candidate.routeID
                )
            }
            return try callback.handle(
                appleCallback,
                expectedOwnerChildDeviceID: configuration.owner
            )
        }

        let outcome = try callback.handle(
            appleCallback,
            expectedOwnerChildDeviceID: configuration.owner,
            preparedShieldReference: try effectStore.reference(for: envelope)
        )
        switch outcome {
        case .discarded:
            try effectStore.discardPrepared(
                operationID: envelope.operationID,
                expectedOwner: configuration.owner
            )
        case .queued:
            if try effectStore.applyPrepared(
                operationID: envelope.operationID,
                expectedOwner: configuration.owner,
                isSuppressed: { _ in suppressed() }
            ) {
                projectShields(try effectStore.loadShieldRecords())
            }
        }
        return outcome
    }

    func recoverShieldEffects(
        expectedOwner: UUID,
        projectShields: ([String: ShieldRecord]) -> Void = { _ in }
    ) throws {
        // FIX-E: terminal locks whose prepare failed are retried FIRST — they
        // are the ones where "not yet" means an unlocked device.
        let terminalsChanged = try effectStore.drainPendingTerminals(
            expectedOwner: expectedOwner,
            selection: self.selectionProvider(),
            appliesToAll: earnedStore.lockedSetAllSelected,
            isSuppressed: { candidate in
                !self.earnedStore.usageCountingAllowed
                    || self.earnedStore.isOverridden(forUsageDate: candidate.usageDate)
            },
            now: clock.now
        )
        let changed = try effectStore.recover(
            expectedOwner: expectedOwner,
            isSuppressed: { envelope in
                guard let route = try? self.store.read().routes[envelope.routeID] else {
                    return true
                }
                return !self.earnedStore.usageCountingAllowed
                    || self.earnedStore.isOverridden(forUsageDate: route.usageDate)
            }
        )
        if changed || terminalsChanged {
            projectShields(try effectStore.loadShieldRecords())
        }
    }
}

struct MeteringProcessConfiguration {
    let baseURL: URL
    let owner: UUID

    static func load(defaults: UserDefaults?) -> MeteringProcessConfiguration? {
        guard let defaults,
              let baseRaw = defaults.string(forKey: MeteringProductionComposition.baseURLKey),
              let baseURL = URL(string: baseRaw),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil,
              let ownerRaw = defaults.string(forKey: MeteringProductionComposition.ownerKey),
              let owner = UUID(uuidString: ownerRaw)
        else { return nil }
        return MeteringProcessConfiguration(baseURL: baseURL, owner: owner)
    }
}
