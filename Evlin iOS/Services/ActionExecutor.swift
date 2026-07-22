import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import CryptoKit

struct AppLimitOwnerExecutionResult: Sendable {
    let result: AckResult
    let receipt: AppLimitApplyReceipt?
}

private enum AppLimitOwnerWorkError: Error {
    case stale
    case readback
}

enum CatalogCommandTokenData {
    static func decodedApplicationData(from target: CommandTarget) -> Data? {
        decodedData(from: target.catalogTokenDataBase64)
    }

    static func decodedCategoryData(from target: CommandTarget) -> Data? {
        decodedData(from: target.catalogCategoryTokenDataBase64)
    }

    static func decodedApplicationDatas(from target: CommandTarget) -> [Data] {
        target.catalogApplicationTokenDataBase64s.compactMap(decodedData)
    }

    static func decodedCategoryDatas(from target: CommandTarget) -> [Data] {
        target.catalogCategoryTokenDataBase64s.compactMap(decodedData)
    }

    static func decodedApplicationToken(from target: CommandTarget) -> ApplicationToken? {
        decodedApplicationData(from: target).flatMap {
            decodeToken(ApplicationToken.self, from: $0)
        }
    }

    static func decodedCategoryToken(from target: CommandTarget) -> ActivityCategoryToken? {
        decodedCategoryData(from: target).flatMap {
            decodeToken(ActivityCategoryToken.self, from: $0)
        }
    }

    static func decodedApplicationTokenSet(from target: CommandTarget) throws -> Set<ApplicationToken>? {
        let payloads = cleanedPayloads(target.catalogApplicationTokenDataBase64s)
        guard !payloads.isEmpty else { return nil }
        var tokens = Set<ApplicationToken>()
        for payload in payloads {
            guard let data = decodedData(from: payload),
                  let token = decodeToken(ApplicationToken.self, from: data)
            else { throw ExecuteError.malformed }
            tokens.insert(token)
        }
        return tokens
    }

    static func decodedCategoryTokenSet(from target: CommandTarget) throws -> Set<ActivityCategoryToken>? {
        let payloads = cleanedPayloads(target.catalogCategoryTokenDataBase64s)
        guard !payloads.isEmpty else { return nil }
        var tokens = Set<ActivityCategoryToken>()
        for payload in payloads {
            guard let data = decodedData(from: payload),
                  let token = decodeToken(ActivityCategoryToken.self, from: data)
            else { throw ExecuteError.malformed }
            tokens.insert(token)
        }
        return tokens
    }

    private static func decodedData(from base64: String?) -> Data? {
        guard let trimmed = base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return Data(base64Encoded: trimmed)
    }

    private static func cleanedPayloads(_ base64s: [String]) -> [String] {
        base64s
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func decodeToken<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let json = JSONDecoder()
        json.dateDecodingStrategy = .iso8601
        if let token = try? json.decode(type, from: data) { return token }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}

protocol DeviceActivityScheduling {
    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws
    /// Arm an activity that also measures usage events (the per-app-limit path,
    /// P5). The `events:` dict maps `DeviceActivityEvent.Name` → threshold so
    /// the extension's `eventDidReachThreshold` fires when a budget is reached.
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
    func stopMonitoring()
    /// The activities DeviceActivity currently considers monitored. Lets a
    /// caller (the per-app-limit planner, P5) self-heal from the live set
    /// instead of relying on in-memory state that doesn't survive a fresh
    /// instance or an app restart.
    func monitoredActivities() -> [DeviceActivityName]
}

struct DeviceActivityCenterScheduler: DeviceActivityScheduling {
    private let center = DeviceActivityCenter()

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        try center.startMonitoring(name, during: schedule)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        try center.startMonitoring(activity, during: schedule, events: events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        center.stopMonitoring(activities)
    }

    func stopMonitoring() {
        center.stopMonitoring()
    }

    func monitoredActivities() -> [DeviceActivityName] {
        Array(center.activities)
    }
}

func makeDefaultDeviceActivityScheduler() -> DeviceActivityScheduling {
#if DEBUG
    DiagnosticDeviceActivityScheduler(base: DeviceActivityCenterScheduler())
#else
    DeviceActivityCenterScheduler()
#endif
}

/// Translates LockCommand into ActiveLockStore mutations.
/// See spec §6 for dispatcher logic and §3.4 for merge rules.
final class ActionExecutor: @unchecked Sendable {
    static let shared = ActionExecutor()

    enum MutationCheckpoint: Equatable, Sendable {
        case shieldPersisted
        case shieldEffectiveStateResolved
        case blockPersisted
        case blockEffectiveStateResolved
        case setLimitPersisted
        case unshieldRemoved
        case unshieldEffectiveStateResolved
        case unblockRemoved
        case clearLimitRearmed
    }

    private struct CommandIdentityContext {
        let expectedChildID: UUID?
        let identityIsCurrent: ((UUID) -> Bool)?

        var isCurrent: Bool {
            guard let expectedChildID else { return true }
            return identityIsCurrent?(expectedChildID) ?? false
        }

        static let unrestricted = CommandIdentityContext(
            expectedChildID: nil,
            identityIsCurrent: nil
        )
    }

    private static let staleIdentityResult = AckResult.failed(.execution("stale_identity"))

    private let activityScheduler: DeviceActivityScheduling
    private let authorizationStatusProvider: () -> AuthorizationStatus
    private let earnedTimeStore: EarnedTimeStore
    private let overrideUsageDateProvider: () -> String?
    private let beforeUnshieldSourceMutation: () -> Void
    private let beforeMutation: () async -> Void
    private let afterMutationCheckpoint: (MutationCheckpoint) -> Void

    /// Per-app limit dependencies (P6). The planner is built per-arm via
    /// `makeLimitPlanner` rather than stored, for two reasons: (1) the planner is
    /// `nonisolated` (its deinit must run off the MainActor back-deploy shim that
    /// double-frees under this toolchain) — storing it on this `@MainActor`
    /// executor would route the release through the executor's main-actor
    /// synthesized deinit and re-trip that crash; (2) the planner is documented as
    /// NOT a singleton: it self-heals from the scheduler's LIVE activity set, so a
    /// fresh instance per arm discovers and stops any orphaned `evlin.limit.window.*`
    /// activities. The factory shares this executor's `activityScheduler`, so a
    /// test spy injected here is the SAME scheduler the planner arms against.
    /// `execute(_:)` is a serial command path, so `arm` is never called concurrently.
    private let ruleStore: AppLimitRuleStore
    private let makeLimitPlanner: @Sendable () -> AppLimitPlanner
    private let appLimitEpochStore: AppLimitEpochStore
    private let appLimitOwnerProvider: @Sendable () -> UUID?
    private let appLimitLockStore: ActiveLockStore

    /// iOS DeviceActivitySchedule hard minimum.
    static let minScheduleMinutes: Int = 15

    init(
        activityScheduler: DeviceActivityScheduling = makeDefaultDeviceActivityScheduler(),
        authorizationStatusProvider: @escaping () -> AuthorizationStatus = {
            AuthorizationCenter.shared.authorizationStatus
        },
        earnedTimeStore: EarnedTimeStore = .shared,
        overrideUsageDateProvider: (() -> String?)? = nil,
        ruleStore: AppLimitRuleStore = .shared,
        appLimitEpochStore: AppLimitEpochStore = .shared,
        appLimitOwnerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current,
        makeLimitPlanner: (@Sendable () -> AppLimitPlanner)? = nil,
        appLimitLockStore: ActiveLockStore = .shared,
        beforeUnshieldSourceMutation: @escaping () -> Void = {},
        beforeMutation: @escaping () async -> Void = {},
        afterMutationCheckpoint: @escaping (MutationCheckpoint) -> Void = { _ in }
    ) {
        self.activityScheduler = activityScheduler
        self.authorizationStatusProvider = authorizationStatusProvider
        self.earnedTimeStore = earnedTimeStore
        self.overrideUsageDateProvider = overrideUsageDateProvider ?? {
            earnedTimeStore.currentCanonicalPolicyUsageDate()
        }
        self.ruleStore = ruleStore
        self.appLimitEpochStore = appLimitEpochStore
        self.appLimitOwnerProvider = appLimitOwnerProvider
        self.appLimitLockStore = appLimitLockStore
        self.beforeUnshieldSourceMutation = beforeUnshieldSourceMutation
        self.beforeMutation = beforeMutation
        self.afterMutationCheckpoint = afterMutationCheckpoint
        // Default factory builds a planner sharing this executor's scheduler so
        // arming + the executor's own shield/block scheduling hit the same backend.
        self.makeLimitPlanner = makeLimitPlanner ?? {
            AppLimitPlanner(
                scheduler: activityScheduler,
                epochStore: appLimitEpochStore,
                ownerProvider: appLimitOwnerProvider
            )
        }
    }

    func execute(
        _ cmd: LockCommand,
        blob: Data? = nil,
        expectedChildID: UUID? = nil,
        identityIsCurrent: ((UUID) -> Bool)? = nil
    ) async -> AckResult {
        let identity = CommandIdentityContext(
            expectedChildID: expectedChildID,
            identityIsCurrent: identityIsCurrent
        )
        guard identity.isCurrent else { return Self.staleIdentityResult }
        guard authorizationStatusProvider() == .approved else {
            return .failed(.notAuthorized)
        }

        var overrideMarkerApplied = false
        if cmd.target.earnedOverrideUsageDate != nil {
            guard cmd.action == .unshield else { return .failed(.malformed) }
            guard let expectedChildID = identity.expectedChildID,
                  cmd.target.targetChildID == expectedChildID,
                  identity.isCurrent
            else { return Self.staleIdentityResult }
            guard await prepareForMutation(identity) else {
                return Self.staleIdentityResult
            }
            guard case .applied = EarnedOverrideCommandApplier.applyIfPresent(
                cmd,
                currentUsageDate: overrideUsageDateProvider(),
                store: earnedTimeStore
            ) else { return .failed(.malformed) }
            overrideMarkerApplied = true
        }

        switch cmd.action {
        case .shield:
            return await executeShield(cmd: cmd, blob: blob, identity: identity)
        case .block:
            return await executeBlock(cmd: cmd, identity: identity)
        case .unshield:
            return await executeUnshield(
                cmd: cmd,
                identity: identity,
                overrideMarkerApplied: overrideMarkerApplied
            )
        case .unblock:
            return await executeUnblock(cmd: cmd, identity: identity)
        case .unshieldAll:
            guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
            let cleared = await ActiveLockStore.shared.unshieldAll()
            afterMutationCheckpoint(.unshieldRemoved)
            guard identity.isCurrent else {
                return Self.staleIdentityResult
            }
            for record in cleared {
                cancelScheduled(recordKey: record.recordKey)
            }
            return .confirmedExact(verb: .unshieldAll, displayName: "\(cleared.count) shield(s) cleared", effectiveState: nil)
        case .unblockAll:
            guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
            let cleared = await ActiveLockStore.shared.unblockAll()
            afterMutationCheckpoint(.unblockRemoved)
            guard identity.isCurrent else {
                return Self.staleIdentityResult
            }
            return .confirmedExact(verb: .unblockAll, displayName: "\(cleared.count) block(s) cleared", effectiveState: nil)
        case .expandLibrary:
            return .failed(.execution("expand_library handled in UI"))
        case .setLimit:
            guard cmd.limit != nil else { return .failed(.malformed) }
            guard CatalogCommandTokenData.decodedApplicationToken(from: cmd.target) != nil else {
                return .failed(.applicationNotConfigured(
                    resolveExactAppFailureReference(from: cmd.target)
                ))
            }
            return .failed(.execution("app_limit_owner_work_required"))
        case .clearLimit:
            guard cmd.clear != nil else { return .failed(.malformed) }
            return .failed(.execution("app_limit_owner_work_required"))
        case .earnedTimeConfig:
            // A4: this case is intercepted in CommandPoller.execute(poll:api:) BEFORE
            // ActionExecutor is called. If it somehow arrives here, fail gracefully
            // rather than misrouting to shield or crashing.
            return .failed(.execution("earned_time_config must not reach ActionExecutor"))
        }
    }

    private func prepareForMutation(_ identity: CommandIdentityContext) async -> Bool {
        guard identity.isCurrent else { return false }
        await beforeMutation()
        return identity.isCurrent
    }

    private func rollbackAddedShield(
        _ receipt: ActiveLockStore.ShieldMutationReceipt
    ) async {
        _ = await ActiveLockStore.shared.rollbackShieldMutation(receipt)
    }

    private func rollbackAddedBlock(
        _ receipt: ActiveLockStore.BlockMutationReceipt
    ) async {
        _ = await ActiveLockStore.shared.rollbackBlockMutation(receipt)
    }

    // MARK: - Per-app limit (P6)

    /// Applies only work already authorized by `AppLimitCommandCoordinator`.
    /// The epoch slot is the desired-state authority; this adapter never writes
    /// through `AppLimitRuleStore.upsert/remove`.
    func executeAppLimitOwnerWork(
        _ cmd: LockCommand,
        envelope: AppLimitCommandEnvelope,
        expectedChildID: UUID,
        identityIsCurrent: @escaping (UUID) -> Bool
    ) async -> AppLimitOwnerExecutionResult {
        let identity = CommandIdentityContext(
            expectedChildID: expectedChildID,
            identityIsCurrent: identityIsCurrent
        )
        guard identity.isCurrent else {
            return AppLimitOwnerExecutionResult(result: Self.staleIdentityResult, receipt: nil)
        }
        guard appLimitOwnerProvider() == expectedChildID else {
            return AppLimitOwnerExecutionResult(result: Self.staleIdentityResult, receipt: nil)
        }
        guard authorizationStatusProvider() == .approved else {
            return AppLimitOwnerExecutionResult(result: .failed(.notAuthorized), receipt: nil)
        }

        let slot: AppLimitVersionSlot
        let work: AppLimitOwnerWork
        do {
            guard let current = try appLimitEpochStore.read().slots[envelope.ruleID],
                  current.latestOrderingToken == envelope.orderingToken,
                  current.latestKind == envelope.kind,
                  current.latestPayloadDigest == envelope.payloadDigest
            else { throw AppLimitOwnerWorkError.stale }
            slot = current
            guard let pending = slot.pendingOwnerWork,
                  pending.commandID == envelope.commandID,
                  pending.orderingToken == envelope.orderingToken,
                  pending.commandKind == envelope.kind,
                  pending.payloadDigest == envelope.payloadDigest
            else {
                return AppLimitOwnerExecutionResult(
                    result: .failed(.execution("stale_app_limit_owner_work")),
                    receipt: nil
                )
            }
            work = pending
        } catch {
            return AppLimitOwnerExecutionResult(
                result: .failed(.execution("stale_app_limit_owner_work")),
                receipt: nil
            )
        }

        let result: AckResult
        switch work.commandKind {
        case .set:
            guard cmd.action == .setLimit,
                  let rule = slot.activeRule,
                  rule.id == work.ruleID
            else {
                return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
            }
            result = await applyPersistedLimitRule(
                rule,
                command: cmd,
                identity: identity
            )
        case .clear:
            guard cmd.action == .clearLimit,
                  cmd.clear?.ruleId == work.ruleID
            else {
                return AppLimitOwnerExecutionResult(result: .failed(.malformed), receipt: nil)
            }
            result = await applyPersistedLimitClear(command: cmd, identity: identity)
        }

        guard case .confirmedExact = result, identity.isCurrent else {
            return AppLimitOwnerExecutionResult(result: result, receipt: nil)
        }

        do {
            let receipt = try commitAppLimitReceipt(work: work, expectedOwner: expectedChildID)
            return AppLimitOwnerExecutionResult(result: result, receipt: receipt)
        } catch {
            return AppLimitOwnerExecutionResult(
                result: .failed(.execution(
                    "app_limit_receipt_commit_failed:\(String(describing: error))"
                )),
                receipt: nil
            )
        }
    }

    func recoverAppLimitOwnerEffect(
        work: AppLimitOwnerWork,
        slot: AppLimitVersionSlot,
        expectedChildID: UUID
    ) async throws -> AppLimitOwnerEffectResult {
        guard appLimitOwnerProvider() == expectedChildID,
              authorizationStatusProvider() == .approved,
              slot.pendingOwnerWork == work,
              slot.latestOrderingToken == work.orderingToken,
              slot.latestKind == work.commandKind,
              slot.latestPayloadDigest == work.payloadDigest
        else { throw AppLimitOwnerWorkError.stale }

        switch work.commandKind {
        case .set:
            guard let rule = slot.activeRule, rule.id == work.ruleID else {
                throw AppLimitOwnerWorkError.stale
            }
            guard case .armed = makeLimitPlanner().arm(rules: ruleStore.all()),
                  let current = try appLimitEpochStore.read().slots[work.ruleID],
                  current.pendingOwnerWork == work,
                  let provenance = current.armProvenance,
                  provenance.ruleRevision == work.orderingToken
            else { throw AppLimitOwnerWorkError.stale }
            return AppLimitOwnerEffectResult(
                armID: provenance.armID,
                source: "app_owner_recovery"
            )
        case .clear:
            _ = try await appLimitLockStore.removeLimitSourceVerified(ruleID: work.ruleID)
            guard case .armed = makeLimitPlanner().arm(rules: ruleStore.all()) else {
                throw AppLimitOwnerWorkError.stale
            }
            return AppLimitOwnerEffectResult(armID: nil, source: "app_owner_recovery")
        }
    }

    private func applyPersistedLimitRule(
        _ rule: AppLimitRule,
        command: LockCommand,
        identity: CommandIdentityContext
    ) async -> AckResult {
        guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
        let plan = makeLimitPlanner().arm(rules: ruleStore.all())
        let result: AckResult
        switch plan {
        case .armed:
            result = .confirmedExact(
                verb: .setLimit,
                displayName: rule.displayName,
                effectiveState: nil
            )
        case .quotaExceeded(let windows, let slotsNeeded, let cap):
            return .failed(.limitQuotaExceeded(
                windows: windows,
                slotsNeeded: slotsNeeded,
                cap: cap
            ))
        case .partiallyArmed(let armed, let failed):
            return .failed(.execution(
                "per-app limit partially armed (\(armed) ok, \(failed) failed); not applied"
            ))
        }

        guard identity.isCurrent else { return Self.staleIdentityResult }
        guard let usedTodayMinutes = command.limit?.usedTodayMinutes,
              usedTodayMinutes >= rule.budgetMinutes,
              var record = LimitShieldLogic.applyingLimit(
                to: [:],
                rule: rule
              )[LimitShieldLogic.recordKey(for: rule)]
        else { return result }
        record.targetChildID = identity.expectedChildID ?? record.targetChildID
        guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
        guard await ActiveLockStore.shared.addShieldWithReceipt(record) != nil else {
            return .failed(.execution("lock_store_unavailable"))
        }
        return identity.isCurrent ? result : Self.staleIdentityResult
    }

    private func applyPersistedLimitClear(
        command: LockCommand,
        identity: CommandIdentityContext
    ) async -> AckResult {
        let appToken = CatalogCommandTokenData.decodedApplicationToken(from: command.target)
        guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
        do {
            _ = try await appLimitLockStore.removeLimitSourceVerified(
                appTokens: appToken.map { Set([$0]) } ?? [],
                bundleID: command.target.bundleID
            )
        } catch {
            return .failed(.execution("lock_store_unavailable"))
        }
        guard identity.isCurrent else { return Self.staleIdentityResult }
        _ = makeLimitPlanner().arm(rules: ruleStore.all())
        afterMutationCheckpoint(.clearLimitRearmed)
        guard identity.isCurrent else { return Self.staleIdentityResult }
        let display = command.target.targetDisplay ?? command.target.bundleID ?? "App"
        return .confirmedExact(verb: .clearLimit, displayName: display, effectiveState: nil)
    }

    private func commitAppLimitReceipt(
        work: AppLimitOwnerWork,
        expectedOwner: UUID
    ) throws -> AppLimitApplyReceipt {
        let receipt = try appLimitEpochStore.transaction(
            source: .poll,
            expectedOwner: expectedOwner
        ) { state -> AppLimitApplyReceipt in
            guard var slot = state.slots[work.ruleID],
                  slot.pendingOwnerWork == work,
                  slot.latestOrderingToken == work.orderingToken,
                  slot.latestKind == work.commandKind,
                  slot.latestPayloadDigest == work.payloadDigest,
                  state.storeRevision < UInt64.max
            else { throw AppLimitOwnerWorkError.stale }
            // Persist whole seconds so JSON Date round-trips remain value-equal.
            // Receipt ordering comes from the token/revision, not subsecond time.
            let appliedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let armID: UUID?
            switch work.commandKind {
            case .set:
                guard let provenance = slot.armProvenance,
                      provenance.ruleRevision == work.orderingToken
                else { throw AppLimitOwnerWorkError.stale }
                armID = provenance.armID
            case .clear:
                armID = nil
            }
            let receipt = AppLimitApplyReceipt(
                ruleID: work.ruleID,
                orderingToken: work.orderingToken,
                commandKind: work.commandKind,
                armID: armID,
                source: "app_owner",
                appliedAt: appliedAt,
                storeRevision: state.storeRevision + 1
            )
            slot.pendingOwnerWork = nil
            slot.appliedReceipt = receipt
            state.slots[work.ruleID] = slot
            return receipt
        }
        guard try AppLimitProductionComposition.currentAppliedReceipt(
            ruleID: work.ruleID,
            store: appLimitEpochStore
        ) == receipt else {
            throw AppLimitOwnerWorkError.readback
        }
        return receipt
    }

    /// Map a backend `reset_policy` to whether the limit window recurs daily.
    ///
    /// Derived POSITIVELY: only known-recurring policies repeat, so an unknown /
    /// future value is treated as a one-shot (non-repeating) window rather than
    /// silently recurring daily. v1's only recurring policy is `"daily"` (resets
    /// each midnight). This set MUST track the backend's `reset_policy` enum —
    /// extend it when the backend adds further recurring policies.
    static func windowRepeats(forResetPolicy policy: String) -> Bool {
        policy.lowercased() == "daily"
    }

    /// Direct receipt-action unlock path. This intentionally bypasses chat/AI
    /// re-dispatch: the receipt already identified the still-covering shield.
    func executeReceiptUnlock(_ target: ReceiptUnlockTarget) async -> AckResult {
        let requestedName = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            return .failed(.malformed)
        }

        let current = await ActiveLockStore.shared.allCurrent().shields
        let matches = current.filter { record in
            record.displayName.caseInsensitiveCompare(requestedName) == .orderedSame
                && (target.tier == nil || record.tier == target.tier)
        }

        guard let record = strongestShield(in: matches) else {
            return .failed(.nothingToUnlock)
        }
        guard let removed = await ActiveLockStore.shared.removeShield(recordKey: record.recordKey) else {
            return .failed(.nothingToUnlock)
        }
        cancelScheduled(recordKey: record.recordKey)

        let effective = effectiveStateFrom(
            removed.stillCovered,
            isBlocked: removed.blockedAfter,
            possibleSavedList: false
        )
        return .confirmedExact(
            verb: .unshield,
            displayName: removed.record.displayName,
            effectiveState: effective
        )
    }

    // MARK: - Shield

    private func executeShield(
        cmd: LockCommand,
        blob: Data?,
        identity: CommandIdentityContext
    ) async -> AckResult {
        do {
            guard identity.isCurrent else { return Self.staleIdentityResult }
            let priorLockedSetID = EarnedTimeStore.shared.lockedSetID
            let deferredLockedSetID = identity.expectedChildID != nil
                && cmd.tier == .savedList
                && cmd.target.defaultLockGroup == true
                ? cmd.target.listID?.uuidString
                : nil
            let record = try buildShieldRecord(
                from: cmd,
                blob: blob,
                expectedChildID: identity.expectedChildID,
                identityIsCurrent: { identity.isCurrent },
                persistDefaultLockGroupIdentity: identity.expectedChildID == nil
            )
            let force = cmd.target.forceDowngrade
            guard identity.isCurrent else { return Self.staleIdentityResult }
            guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
            if let deferredLockedSetID,
               priorLockedSetID?.caseInsensitiveCompare(deferredLockedSetID) != .orderedSame {
                guard identity.isCurrent else { return Self.staleIdentityResult }
                EarnedTimeStore.shared.saveLockedSetID(deferredLockedSetID, tokenData: nil)
            }
            guard let shieldMutation = await ActiveLockStore.shared.addShieldWithReceipt(
                record,
                force: force
            ) else {
                return .failed(.execution("lock_store_unavailable"))
            }
            let result = shieldMutation.result
            afterMutationCheckpoint(.shieldPersisted)
            guard identity.isCurrent else {
                await rollbackShieldCommand(
                    receipt: shieldMutation.receipt,
                    deferredLockedSetID: deferredLockedSetID,
                    priorLockedSetID: priorLockedSetID
                )
                return Self.staleIdentityResult
            }
            switch result {
            case .added, .upgradedToPermanent, .extendedTimed:
                let eff = await currentEffectiveState(
                    forShieldRecord: record,
                    cmd: cmd,
                    identity: identity
                )
                afterMutationCheckpoint(.shieldEffectiveStateResolved)
                guard identity.isCurrent else {
                    await rollbackShieldCommand(
                        receipt: shieldMutation.receipt,
                        deferredLockedSetID: deferredLockedSetID,
                        priorLockedSetID: priorLockedSetID
                    )
                    return Self.staleIdentityResult
                }
                if scheduleShieldExpiryIfNeeded(record) {
                    guard identity.isCurrent else {
                        cancelScheduled(recordKey: record.recordKey)
                        await rollbackShieldCommand(
                            receipt: shieldMutation.receipt,
                            deferredLockedSetID: deferredLockedSetID,
                            priorLockedSetID: priorLockedSetID
                        )
                        return Self.staleIdentityResult
                    }
                }
                LockWindowStore.append(LockWindowRecord(
                    recordKey: record.recordKey,
                    displayName: record.displayName,
                    bundleID: record.appTokens.isEmpty ? nil
                        : (cmd.target.bundleID ?? LocalAliasStore.shared
                            .primaryBundleID(forDisplayOrHint: record.displayName)),
                    issuedAt: record.issuedAt,
                    expiresAt: record.expiresAt
                ))
                return buildConfirmReceipt(verb: .shield, cmd: cmd, record: record, effectiveState: eff)
            case .noOpShorterThanExisting, .noOpAlreadyPermanent:
                let eff = await currentEffectiveState(
                    forShieldRecord: record,
                    cmd: cmd,
                    identity: identity
                )
                afterMutationCheckpoint(.shieldEffectiveStateResolved)
                guard identity.isCurrent else {
                    await rollbackShieldCommand(
                        receipt: shieldMutation.receipt,
                        deferredLockedSetID: deferredLockedSetID,
                        priorLockedSetID: priorLockedSetID
                    )
                    return Self.staleIdentityResult
                }
                return .confirmedExact(verb: .shield, displayName: "\(record.displayName) already covered", effectiveState: eff)
            case .needsConfirmation(let reason):
                let context: [String: String]
                switch reason {
                case .downgradePermanentToTimed(let existingKey, let newExpiry):
                    context = [
                        "card_id": "B1",
                        "target_display": record.displayName,
                        "target_request": cmd.target.originalRequest,
                        "existing_record_key": existingKey,
                        "requested_expiry_iso": ISO8601DateFormatter().string(from: newExpiry),
                        "requested_duration_minutes": String(cmd.durationMinutes ?? 0),
                        "existing_mode": "permanent",
                    ]
                }
                return .pendingConfirmation(cardID: "B1", context: context)
            }
        } catch let err as ExecuteError {
            if case .staleIdentity = err { return Self.staleIdentityResult }
            return .failed(err.ackFailure)
        } catch {
            return .failed(.execution(error.localizedDescription))
        }
    }

    private func rollbackShieldCommand(
        receipt: ActiveLockStore.ShieldMutationReceipt,
        deferredLockedSetID: String?,
        priorLockedSetID: String?
    ) async {
        await rollbackAddedShield(receipt)
        if let deferredLockedSetID {
            EarnedTimeStore.shared.restoreLockedSetIDIfCurrent(
                deferredLockedSetID,
                priorID: priorLockedSetID
            )
        }
    }

    private func scheduleShieldExpiryIfNeeded(_ record: ShieldRecord) -> Bool {
        guard let expiresAt = record.expiresAt else { return false }
        do {
            try scheduleRelock(recordKey: record.recordKey, expiresAt: expiresAt)
            let message = "schedule_ok recordKey=\(record.recordKey) "
                + "expiresAt=\(ISO8601DateFormatter().string(from: expiresAt))"
            NSLog("[Evlin] %@", message)
            UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                message,
                forKey: "evlin.lastScheduleResult"
            )
            return true
        } catch {
            let message = "schedule_FAILED recordKey=\(record.recordKey) "
                + "expiresAt=\(ISO8601DateFormatter().string(from: expiresAt)) "
                + "error=\(error.localizedDescription)"
            NSLog("[Evlin] %@", message)
            UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                message,
                forKey: "evlin.lastScheduleResult"
            )
            return false
        }
    }

    // Honest-receipt contract: parent ReceiptCard appends
    // EvlinReceiptCopy.appliedOnKidDevice under the AckResult this builds.
    // This builder must never encode an "Apple confirmed" style claim.
    private func buildConfirmReceipt(
        verb: AckVerb,
        cmd: LockCommand,
        record: ShieldRecord,
        effectiveState: AckEffectiveState?
    ) -> AckResult {
        switch cmd.tier {
        case .category:
            return .confirmedFallback(
                verb: verb,
                displayName: record.displayName,
                category: categoryLookupName(from: cmd.target) ?? "unknown",
                origRequest: cmd.target.originalRequest,
                effectiveState: effectiveState
            )
        default:
            return .confirmedExact(verb: verb, displayName: record.displayName, effectiveState: effectiveState)
        }
    }

    private func currentEffectiveState(
        forShieldRecord record: ShieldRecord,
        cmd: LockCommand,
        identity: CommandIdentityContext = .unrestricted
    ) async -> AckEffectiveState? {
        guard identity.isCurrent else { return nil }
        let query: AppQuery
        if cmd.tier == .exactApp, let resolved = try? resolveExactApp(from: cmd.target) {
            let bundleForQuery = canonicalBundleID(for: cmd.target)
            query = AppQuery(bundleID: bundleForQuery, token: resolved.token, categoryHint: nil)
        } else if cmd.tier == .category {
            query = AppQuery(categoryHint: categoryLookupName(from: cmd.target)?.lowercased())
        } else if let bid = cmd.target.bundleID {
            query = AppQuery(bundleID: bid, categoryHint: cmd.target.categoryHint?.lowercased())
        } else {
            query = AppQuery(bundleID: nil, categoryHint: cmd.target.categoryHint?.lowercased())
        }
        let state = await ActiveLockStore.shared.effectiveState(for: query)
        guard identity.isCurrent else { return nil }
        return AckEffectiveState(
            isBlocked: state.blockedAfter,
            shieldsCovering: state.stillCovered.map {
                .init(displayName: $0.displayName,
                      expiresAtISO: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) },
                      tier: $0.tier.rawValue)
            },
            possibleSavedListCoverage: state.possibleSavedListCoverage
        )
    }

    private func effectiveStateFrom(_ stillCovered: [ShieldRecord], isBlocked: Bool, possibleSavedList: Bool) -> AckEffectiveState {
        AckEffectiveState(
            isBlocked: isBlocked,
            shieldsCovering: stillCovered.map {
                .init(displayName: $0.displayName,
                      expiresAtISO: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) },
                      tier: $0.tier.rawValue)
            },
            possibleSavedListCoverage: possibleSavedList
        )
    }

    private func strongestShield(in records: [ShieldRecord]) -> ShieldRecord? {
        records.sorted { a, b in
            if a.expiresAt == nil && b.expiresAt != nil { return true }
            if a.expiresAt != nil && b.expiresAt == nil { return false }
            return (a.expiresAt ?? .distantPast) > (b.expiresAt ?? .distantPast)
        }.first
    }

    // internal (not private): exercised directly by LockedSetFullCoverageTests
    // via @testable import, matching the plan's Task 3 test-access approach.
    func buildShieldRecord(
        from cmd: LockCommand,
        blob: Data?,
        expectedChildID: UUID? = nil,
        identityIsCurrent: () -> Bool = { true },
        persistDefaultLockGroupIdentity: Bool = true
    ) throws -> ShieldRecord {
        let tier = cmd.tier ?? .category
        let targetKey: String
        var appTokens: Set<ApplicationToken> = []
        var categoryTokens: Set<ActivityCategoryToken> = []
        var webDomainTokens: Set<WebDomainToken> = []
        var appliesToAll = false
        var displayName = cmd.target.targetDisplay ?? "Unknown"

        switch tier {
        case .exactApp:
            // Catalog-captured apps live in LocalAliasStore but are not necessarily in
            // the legacy active Managed Apps selection. Don't require the token to be
            // "active": if the kid holds a real captured token for this app, shield it.
            // (When the command carries a catalog token, resolveExactApp uses it
            // directly and this flag is moot.)
            let resolved = try resolveExactApp(from: cmd.target, requireActiveToken: false)
            appTokens = [resolved.token]
            targetKey = resolved.targetKey
            displayName = cmd.target.targetDisplay
                ?? cmd.target.bundleID
                ?? cmd.target.categoryHint
                ?? "App"
        case .savedList:
            if let id = cmd.target.listID {
                targetKey = id.uuidString
            } else {
                throw ExecuteError.malformed
            }
            if let catalogApps = try CatalogCommandTokenData.decodedApplicationTokenSet(from: cmd.target) {
                appTokens = catalogApps
            }
            if let catalogCategories = try CatalogCommandTokenData.decodedCategoryTokenSet(from: cmd.target) {
                categoryTokens = catalogCategories
            }
            // Device-local union (paper-lock fix): backend enumeration only ever
            // contains catalog-MATCHED tokens (app_control_execution.py resolves
            // list membership through ensure_selected_set's token_available filter).
            // The kid's own FamilyActivitySelection in DefaultLockGroupStore is the
            // ground truth for "what did the kid actually pick" — union it in
            // so unmatched apps and every category are covered too, not just when
            // the backend sent zero tokens.
            //
            // BUT: `.savedList` is a GENERIC tier shared by arbitrary parent-named
            // custom lists (SavedListPickerView, chat "lock these 3 apps") AND the
            // device's one default "Locked set". DefaultLockGroupStore always holds
            // the DEFAULT lock group's selection, so the union must only fire when
            // this command actually targets that default group — otherwise locking
            // any small custom list over-locks everything in the kid's App-Controls
            // selection. Compare lowercased, consistent with the
            // `savedList:<targetKey.lowercased()>` recordKey normalization
            // (ShieldRecord.makeRecordKey).
            // The command itself can assert default-group identity (backend
            // `default_lock_group` flag): a fresh family's very first lock
            // arrives before any earned_time_config ever carried the list id
            // (the list is empty at provision time), so lockedSetID would be
            // nil here and the union below would silently paper-lock. Adopt
            // the id from the flagged command before evaluating the gate.
            if persistDefaultLockGroupIdentity,
               cmd.target.defaultLockGroup == true,
               EarnedTimeStore.shared.lockedSetID?.lowercased() != targetKey.lowercased() {
                guard identityIsCurrent() else { throw ExecuteError.staleIdentity }
                EarnedTimeStore.shared.saveLockedSetID(targetKey, tokenData: nil)
            }
            let isDefaultLockGroup = cmd.target.defaultLockGroup == true
                || EarnedTimeStore.shared.lockedSetID
                    .map { $0.lowercased() == targetKey.lowercased() } == true
            if isDefaultLockGroup {
                let localSelection = DefaultLockGroupStore.load()
                appTokens.formUnion(localSelection.applicationTokens)
                categoryTokens.formUnion(localSelection.categoryTokens)
                webDomainTokens.formUnion(localSelection.webDomainTokens)
            }
            // Legacy blob/local-list fallback stays as a last resort for the
            // (now rare) case where DefaultLockGroupStore itself is empty but an
            // older opaque blob or named local list still carries tokens.
            if appTokens.isEmpty && categoryTokens.isEmpty {
                let sel: FamilyActivitySelection
                // iOS 26 PropertyListEncoder crashes on FamilyControls tokens; try JSON first,
                // fall back to plist for legacy server payloads. See LocalAliasStore._decodeTokenAny.
                if let blob = blob,
                   let decoded = (try? JSONDecoder().decode(FamilyActivitySelection.self, from: blob))
                              ?? (try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob)) {
                    sel = decoded
                } else if let name = cmd.target.listName,
                          let local = LocalAliasStore.shared.savedList(named: name) {
                    sel = local
                } else {
                    throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
                }
                appTokens = sel.applicationTokens
                categoryTokens = sel.categoryTokens
                webDomainTokens = sel.webDomainTokens
            }
            if cmd.target.allSelected == true {
                appliesToAll = true
            }
            displayName = cmd.target.listName ?? "saved list"
        case .category:
            guard let hint = categoryLookupName(from: cmd.target) else {
                throw ExecuteError.categoryNotConfigured("unknown")
            }
            let tok: ActivityCategoryToken
            if let decoded = CatalogCommandTokenData.decodedCategoryToken(from: cmd.target) {
                tok = decoded
            } else if let local = LocalAliasStore.shared.categoryToken(forName: hint) {
                tok = local
            } else {
                throw ExecuteError.categoryNotConfigured(hint)
            }
            categoryTokens = [tok]
            targetKey = hint.lowercased()
            displayName = cmd.target.targetDisplay ?? hint.capitalized
        case .all, .allApps:
            targetKey = "all"
            appliesToAll = true
            displayName = "All Apps"
        }

        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(Self.minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(Self.minScheduleMinutes * 60))
        }

        return ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: cmd.id,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: webDomainTokens,
            appliesToAll: appliesToAll,
            issuedAt: cmd.issuedAt,
            expiresAt: expiresAt,
            originalRequest: cmd.target.originalRequest,
            targetChildID: expectedChildID ?? cmd.target.targetChildID ?? UUID(),
            sources: Self.shieldSources(fromWireLockSource: cmd.lockSource)
        )
    }

    /// B2: map a wire snake `lock_source` value to the `ShieldSource` set for a
    /// new `ShieldRecord`. Internal so tests can verify the mapping directly.
    static func shieldSources(fromWireLockSource wireSource: String?) -> Set<ShieldSource> {
        NSECommandSourceResolver.shieldSources(from: wireSource)
    }

    // MARK: - Block

    private func executeBlock(
        cmd: LockCommand,
        identity: CommandIdentityContext
    ) async -> AckResult {
        guard let bundleID = cmd.target.bundleID else {
            return .failed(.malformed)
        }
        // Timed block: clamp to iOS DeviceActivitySchedule's hard 15-minute
        // minimum same way shield does, so 'block IG for 5 min' becomes a
        // 15-minute block rather than silently never-firing.
        var expiresAt = cmd.expiresAt
        if let exp = expiresAt, exp.timeIntervalSinceNow < TimeInterval(Self.minScheduleMinutes * 60) {
            expiresAt = Date().addingTimeInterval(TimeInterval(Self.minScheduleMinutes * 60))
        }
        let record = BlockRecord(
            bundleID: bundleID,
            displayName: cmd.target.targetDisplay ?? bundleID,
            blockedAt: cmd.issuedAt,
            lastCommandID: cmd.id,
            originalRequest: cmd.target.originalRequest,
            targetChildID: identity.expectedChildID ?? cmd.target.targetChildID ?? UUID(),
            expiresAt: expiresAt
        )
        guard await prepareForMutation(identity) else {
            return Self.staleIdentityResult
        }
        guard let blockMutation = await ActiveLockStore.shared.addBlockWithReceipt(record) else {
            return .failed(.execution("lock_store_unavailable"))
        }
        let result = blockMutation.result
        afterMutationCheckpoint(.blockPersisted)
        guard identity.isCurrent else {
            await rollbackAddedBlock(blockMutation.receipt)
            return Self.staleIdentityResult
        }
        let query = AppQuery(bundleID: bundleID, categoryHint: nil)
        let state = await ActiveLockStore.shared.effectiveState(for: query)
        afterMutationCheckpoint(.blockEffectiveStateResolved)
        guard identity.isCurrent else {
            await rollbackAddedBlock(blockMutation.receipt)
            return Self.staleIdentityResult
        }
        // Schedule only after the final suspension and identity check.
        if let exp = expiresAt {
            do {
                try scheduleAutoUnblock(bundleID: bundleID, expiresAt: exp)
                NSLog("[Evlin] block_schedule_ok bundleID=%@ expiresAt=%@",
                      bundleID, ISO8601DateFormatter().string(from: exp))
                guard identity.isCurrent else {
                    cancelScheduledBlock(bundleID: bundleID)
                    await rollbackAddedBlock(blockMutation.receipt)
                    return Self.staleIdentityResult
                }
            } catch {
                NSLog("[Evlin] block_schedule_FAILED bundleID=%@ error=%@",
                      bundleID, error.localizedDescription)
                UserDefaults(suiteName: "group.com.evlin.ios")?.set(
                    "block_schedule_FAILED bundleID=\(bundleID) error=\(error.localizedDescription)",
                    forKey: "evlin.lastScheduleResult"
                )
            }
        }
        let eff = effectiveStateFrom(state.stillCovered, isBlocked: true, possibleSavedList: state.possibleSavedListCoverage)
        switch result {
        case .added:
            return .confirmedExact(verb: .block, displayName: record.displayName, effectiveState: eff)
        case .alreadyBlocked:
            return .confirmedExact(verb: .block, displayName: "\(record.displayName) already blocked", effectiveState: eff)
        }
    }

    /// Schedule a DeviceActivityMonitor activity that fires intervalDidEnd
    /// at `expiresAt`, so the extension can remove the BlockRecord and
    /// recompute the effective state. Activity name namespace is
    /// `evlin.block.<sha-of-bundleID>` so the extension knows it's a
    /// block-expiry event vs a shield-expiry event.
    private func scheduleAutoUnblock(bundleID: String, expiresAt: Date) throws {
        let now = Date()
        let requestedInterval = expiresAt.timeIntervalSince(now)
        let minInterval = TimeInterval(Self.minScheduleMinutes * 60)
        let clampedEnd = requestedInterval < minInterval
            ? now.addingTimeInterval(minInterval)
            : expiresAt
        let calendar = Calendar.current
        let startComp = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComp = calendar.dateComponents([.hour, .minute, .second], from: clampedEnd)
        let schedule = DeviceActivitySchedule(intervalStart: startComp, intervalEnd: endComp, repeats: false)
        let name = DeviceActivityName(deviceActivityNameForBlock(bundleID: bundleID))
        try activityScheduler.startMonitoring(name, during: schedule)
    }

    private func deviceActivityNameForBlock(bundleID: String) -> String {
        let data = bundleID.data(using: .utf8) ?? Data()
        let bytes = sha256Hex16(data)
        return "evlin.block.\(bytes)"
    }

    private func cancelScheduledBlock(bundleID: String) {
        activityScheduler.stopMonitoring([
            DeviceActivityName(deviceActivityNameForBlock(bundleID: bundleID))
        ])
    }

    // MARK: - Unshield — spec §4.4

    private func executeUnshield(
        cmd: LockCommand,
        identity: CommandIdentityContext,
        overrideMarkerApplied: Bool
    ) async -> AckResult {
        guard let tier = cmd.tier else { return .failed(.malformed) }

        switch tier {
        case .savedList:
            guard let id = cmd.target.listID else {
                guard overrideMarkerApplied else { return .failed(.nothingToUnlock) }
                return .confirmedExact(
                    verb: .unshield,
                    displayName: "Screen time override",
                    effectiveState: nil
                )
            }
            // B2: if unlock_sources specified, remove only those sources; legacy
            // commands with no unlock_sources fall through to whole-record removal.
            if let wireSources = cmd.unlockSources {
                // `id.uuidString` is uppercase; `makeRecordKey` lowercases the
                // `.savedList` segment so this matches the extension's
                // lowercase-backend-string key (Wave-1 Task 5 fix).
                let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: id.uuidString)
                for wireSource in wireSources {
                    let src: ShieldSource
                    switch wireSource {
                    case "earned_time": src = .earnedTime
                    case "task_pause":  src = .taskPause
                    default:            src = .manual
                    }
                    guard identity.isCurrent else { return Self.staleIdentityResult }
                    guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
                    beforeUnshieldSourceMutation()
                    await ActiveLockStore.shared.removeSource(src, fromRecordKey: recordKey)
                    afterMutationCheckpoint(.unshieldRemoved)
                    guard identity.isCurrent else {
                        return Self.staleIdentityResult
                    }
                }
                // Build a minimal ack — record may still exist with remaining sources.
                let displayName = cmd.target.listName ?? cmd.target.targetDisplay ?? "saved list"
                return .confirmedExact(verb: .unshield, displayName: displayName, effectiveState: nil)
            }
            return await removeExplicit(
                tier: .savedList,
                targetKey: id.uuidString,
                identity: identity
            )
        case .category:
            guard let hint = cmd.target.categoryHint else { return .failed(.nothingToUnlock) }
            // Pass the best human-readable category name (categoryHint /
            // target_display / original request) so that when the token-keyed
            // removal misses, the fallback can match the active `.category`
            // shield by its displayName ("Social") case-insensitively.
            return await removeExplicit(
                tier: .category,
                targetKey: hint.lowercased(),
                categoryDisplayHint: categoryLookupName(from: cmd.target),
                identity: identity
            )
        case .all:
            return await removeExplicit(tier: .all, targetKey: "all", identity: identity)
        case .allApps:
            return await removeExplicit(tier: .allApps, targetKey: "all", identity: identity)
        case .exactApp:
            guard let resolved = try? resolveExactApp(from: cmd.target, requireActiveToken: false) else {
                return .failed(.applicationNotConfigured(resolveExactAppFailureReference(from: cmd.target)))
            }
            let bundleForQuery = canonicalBundleID(for: cmd.target)
            let display = cmd.target.targetDisplay ?? bundleForQuery ?? cmd.target.categoryHint ?? "App"
            return await unshieldAppByBundle(
                bundleID: bundleForQuery,
                token: resolved.token,
                displayName: display,
                categoryHint: cmd.target.categoryHint,
                identity: identity
            )
        }
    }

    /// Bundle id when known (command or Managed Apps lookup); may be nil for display-only aliases.
    private func canonicalBundleID(for target: CommandTarget) -> String? {
        if let raw = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        let hints = [target.targetDisplay, target.categoryHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for hint in hints {
            if let bid = LocalAliasStore.shared.primaryBundleID(forDisplayOrHint: hint) {
                return bid
            }
        }
        return nil
    }

    private func resolveExactAppFailureReference(from target: CommandTarget) -> String {
        if let bid = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            return bid
        }
        return target.targetDisplay
            ?? target.categoryHint
            ?? target.originalRequest
    }

    private struct ExactAppResolution {
        let token: ApplicationToken
        /// Matches `ShieldRecord.targetKey`: preferred lowercased bundle id, else lowercased display hint.
        let targetKey: String
    }

    private func resolveExactApp(
        from target: CommandTarget,
        requireActiveToken: Bool = false
    ) throws -> ExactAppResolution {
        if let token = CatalogCommandTokenData.decodedApplicationToken(from: target) {
            return ExactAppResolution(token: token, targetKey: exactAppTargetKey(from: target))
        }

        let store = LocalAliasStore.shared
        let activeTokens = ScreenTimeManager.shared.selectedApps.applicationTokens
        func lookup(_ key: String) -> ApplicationToken? {
            if requireActiveToken {
                return store.activeApplicationToken(forLookupKey: key, activeTokens: activeTokens)
            }
            return store.applicationToken(forLookupKey: key)
        }

        if let rawBid = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBid.isEmpty {
            let bidLower = rawBid.lowercased()
            if let t = lookup(rawBid) {
                return ExactAppResolution(token: t, targetKey: bidLower)
            }
        }
        var seen = Set<String>()
        let hintStrings = [target.targetDisplay, target.categoryHint]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for hint in hintStrings {
            let norm = hint.lowercased()
            guard seen.insert(norm).inserted else { continue }
            guard let tok = lookup(hint) else { continue }
            let key = store.primaryBundleID(forDisplayOrHint: hint)?.lowercased() ?? norm
            return ExactAppResolution(token: tok, targetKey: key)
        }
        throw ExecuteError.applicationNotConfigured(resolveExactAppFailureReference(from: target))
    }

    private func exactAppTargetKey(from target: CommandTarget) -> String {
        if let raw = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw.lowercased()
        }
        for raw in [target.targetDisplay, target.categoryHint, target.originalRequest] {
            if let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                return clean.lowercased()
            }
        }
        return "app"
    }

    private func categoryLookupName(from target: CommandTarget) -> String? {
        for raw in [target.categoryHint, target.targetDisplay, target.originalRequest] {
            if let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                return clean
            }
        }
        return nil
    }

    private func removeExplicit(
        tier: ShieldTier,
        targetKey: String,
        categoryDisplayHint: String? = nil,
        identity: CommandIdentityContext
    ) async -> AckResult {
        // For `.savedList` callers (e.g. the `id.uuidString` fallback at :743)
        // `makeRecordKey` lowercases the targetKey so this lines up with the
        // extension's lowercase-backend-string key regardless of case here.
        let recordKey = ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey)
        guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
        guard let removed = await ActiveLockStore.shared.removeShield(recordKey: recordKey) else {
            guard identity.isCurrent else { return Self.staleIdentityResult }
            // Token-keyed removal found nothing. For a category unshield this is
            // the BAD command shape: it carried only a lowercase `category_hint`
            // (no resolvable category token), so the recordKey (`category:<hint>`)
            // doesn't match the active `.category` shield's recordKey. Fall back
            // to matching that active shield by its displayName ("Social")
            // case-insensitively so "unlock Social" actually removes the shield
            // and the receipt reports "Social" instead of falling back to "App".
            if tier == .category,
               let hint = categoryDisplayHint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hint.isEmpty {
                guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
                let removedByName = await ActiveLockStore.shared
                    .removeCategoryShieldsByDisplayName(hint)
                afterMutationCheckpoint(.unshieldRemoved)
                guard identity.isCurrent else {
                    return Self.staleIdentityResult
                }
                if let match = strongestShield(in: removedByName) {
                    // Re-ask with the matched category's name so any remaining
                    // shield on that category (or an `all`-tier shield) is still
                    // disclosed, mirroring the happy-path category branch below.
                    let post = await ActiveLockStore.shared.effectiveState(
                        for: AppQuery(categoryHint: match.displayName.lowercased())
                    )
                    afterMutationCheckpoint(.unshieldEffectiveStateResolved)
                    guard identity.isCurrent else {
                        return Self.staleIdentityResult
                    }
                    for record in removedByName {
                        cancelScheduled(recordKey: record.recordKey)
                    }
                    let eff = effectiveStateFrom(
                        post.stillCovered,
                        isBlocked: post.blockedAfter,
                        possibleSavedList: post.possibleSavedListCoverage
                    )
                    return .confirmedExact(
                        verb: .unshield,
                        displayName: match.displayName,
                        effectiveState: eff
                    )
                }
            }
            return .failed(.nothingToUnlock)
        }
        afterMutationCheckpoint(.unshieldRemoved)
        guard identity.isCurrent else {
            return Self.staleIdentityResult
        }

        // P2 fix: narrow the post-query so the "Still shielded by …" disclosure
        // only mentions shields that actually overlap what we just removed.
        // The broken version used AppQuery(nil, nil) which matched `all`-tier
        // shields + flagged every saved-list shield as "possibly covering" — so
        // `unshield list 1` would falsely claim list 2 might still cover it.
        let eff: AckEffectiveState
        switch tier {
        case .all, .allApps:
            // After removing the broadest possible shield, there is nothing
            // specific to "still cover" — effective state is trivially empty.
            eff = AckEffectiveState(isBlocked: false, shieldsCovering: [], possibleSavedListCoverage: false)
        case .category:
            // Re-ask with the same category hint. Remaining shields on that
            // category (or `all`-tier) are correctly reported; unrelated
            // saved-list shields on OTHER apps won't be flagged.
            let post = await ActiveLockStore.shared.effectiveState(
                for: AppQuery(categoryHint: targetKey)
            )
            guard identity.isCurrent else {
                return Self.staleIdentityResult
            }
            eff = effectiveStateFrom(
                post.stillCovered,
                isBlocked: post.blockedAfter,
                possibleSavedList: post.possibleSavedListCoverage
            )
        case .savedList:
            // Ask per-token: did any remaining shield cover an app that was in
            // the list we just removed? Union the results, dedup by recordKey.
            var union: [String: ShieldRecord] = [:]
            var blockedAny = false
            var possibleList = false
            for token in removed.record.appTokens {
                let s = await ActiveLockStore.shared.effectiveState(
                    for: AppQuery(token: token)
                )
                guard identity.isCurrent else {
                    return Self.staleIdentityResult
                }
                for r in s.stillCovered { union[r.recordKey] = r }
                if s.blockedAfter { blockedAny = true }
                if s.possibleSavedListCoverage { possibleList = true }
            }
            // Category tokens in the removed list: no bundle-level reverse lookup,
            // but we can still check if any `all`-tier or same-category shield remains.
            for _ in removed.record.categoryTokens {
                let s = await ActiveLockStore.shared.effectiveState(for: AppQuery())
                guard identity.isCurrent else {
                    return Self.staleIdentityResult
                }
                // `all`-tier always matches AppQuery(). This catches the edge case.
                for r in s.stillCovered where r.appliesToAll { union[r.recordKey] = r }
            }
            eff = effectiveStateFrom(
                Array(union.values),
                isBlocked: blockedAny,
                possibleSavedList: possibleList
            )
        case .exactApp:
            // removeExplicit is called for list/category/all; exactApp goes through
            // unshieldAppByBundle. Defensive default.
            eff = AckEffectiveState(isBlocked: false, shieldsCovering: [], possibleSavedListCoverage: false)
        }

        afterMutationCheckpoint(.unshieldEffectiveStateResolved)
        guard identity.isCurrent else {
            return Self.staleIdentityResult
        }
        cancelScheduled(recordKey: recordKey)

        return .confirmedExact(verb: .unshield, displayName: removed.record.displayName, effectiveState: eff)
    }

    private func unshieldAppByBundle(
        bundleID: String?,
        token: ApplicationToken?,
        displayName: String,
        categoryHint: String?,
        identity: CommandIdentityContext
    ) async -> AckResult {
        let tk = token ?? bundleID.flatMap { LocalAliasStore.shared.applicationToken(forLookupKey: $0) }
        let query = AppQuery(bundleID: bundleID, token: tk, categoryHint: categoryHint?.lowercased())
        let state = await ActiveLockStore.shared.effectiveState(for: query)
        guard identity.isCurrent else { return Self.staleIdentityResult }

        if let exactAppShield = state.shieldsCovering.first(where: { $0.tier == .exactApp }) {
            guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
            guard let removed = await ActiveLockStore.shared.removeShield(recordKey: exactAppShield.recordKey) else {
                guard identity.isCurrent else { return Self.staleIdentityResult }
                return .failed(.nothingToUnlock)
            }
            afterMutationCheckpoint(.unshieldRemoved)
            guard identity.isCurrent else {
                return Self.staleIdentityResult
            }
            let post = await ActiveLockStore.shared.effectiveState(for: query)
            afterMutationCheckpoint(.unshieldEffectiveStateResolved)
            guard identity.isCurrent else {
                return Self.staleIdentityResult
            }
            cancelScheduled(recordKey: exactAppShield.recordKey)
            let eff = effectiveStateFrom(post.stillCovered, isBlocked: post.blockedAfter, possibleSavedList: post.possibleSavedListCoverage)
            return .confirmedExact(verb: .unshield, displayName: removed.record.displayName, effectiveState: eff)
        }

        let broader = state.shieldsCovering.filter { $0.tier != .exactApp }
        switch broader.count {
        case 0:
            return .failed(.nothingToUnlock)
        case 1:
            let s = broader[0]
            return .failed(.execution(
                "\(displayName) is shielded by \(s.displayName). To release it, use \"unlock \(s.displayName)\"."
            ))
        default:
            let sources = broader.map { s -> String in
                if let exp = s.expiresAt {
                    let f = DateFormatter(); f.timeStyle = .short
                    return "\(s.displayName) (until \(f.string(from: exp)))"
                }
                return "\(s.displayName) (permanent)"
            }.joined(separator: ", ")
            return .failed(.execution(
                "\(displayName) is shielded by \(broader.count) sources: \(sources). Unlock one explicitly."
            ))
        }
    }

    // MARK: - Unblock

    private func executeUnblock(
        cmd: LockCommand,
        identity: CommandIdentityContext
    ) async -> AckResult {
        guard let bid = cmd.target.bundleID else { return .failed(.malformed) }
        guard await prepareForMutation(identity) else { return Self.staleIdentityResult }
        guard let removed = await ActiveLockStore.shared.removeBlock(
            bundleID: bid,
            categoryHint: cmd.target.categoryHint
        ) else {
            guard identity.isCurrent else { return Self.staleIdentityResult }
            return .failed(.nothingToUnlock)
        }
        afterMutationCheckpoint(.unblockRemoved)
        guard identity.isCurrent else {
            return Self.staleIdentityResult
        }
        let eff = effectiveStateFrom(
            removed.stillShieldedBy,
            isBlocked: false,
            possibleSavedList: removed.possibleSavedListCoverage
        )
        return .confirmedExact(verb: .unblock, displayName: removed.record.displayName, effectiveState: eff)
    }

    // MARK: - DeviceActivity scheduling

    private func scheduleRelock(recordKey: String, expiresAt: Date) throws {
        let now = Date()
        let requestedInterval = expiresAt.timeIntervalSince(now)
        let minInterval = TimeInterval(Self.minScheduleMinutes * 60)
        let clampedEnd = requestedInterval < minInterval
            ? now.addingTimeInterval(minInterval)
            : expiresAt
        let calendar = Calendar.current
        let startComp = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComp = calendar.dateComponents([.hour, .minute, .second], from: clampedEnd)
        let schedule = DeviceActivitySchedule(intervalStart: startComp, intervalEnd: endComp, repeats: false)
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        try activityScheduler.startMonitoring(name, during: schedule)
    }

    private func cancelScheduled(recordKey: String) {
        let name = DeviceActivityName(deviceActivityNameFor(recordKey: recordKey))
        activityScheduler.stopMonitoring([name])
    }

    private func deviceActivityNameFor(recordKey: String) -> String {
        let data = recordKey.data(using: .utf8) ?? Data()
        let bytes = sha256Hex16(data)
        return "evlin.shield.\(bytes)"
    }
}

// MARK: - Helpers

private func sha256Hex16(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
}

enum ExecuteError: Error {
    case malformed
    case staleIdentity
    case listNotFound(String)
    case categoryNotConfigured(String)
    case applicationNotConfigured(String)
    case notImplemented(String)

    var ackFailure: AckFailure {
        switch self {
        case .malformed: return .malformed
        case .staleIdentity: return .execution("stale_identity")
        case .listNotFound(let n): return .listNotFound(n)
        case .categoryNotConfigured(let n): return .categoryNotConfigured(n)
        case .applicationNotConfigured(let n): return .applicationNotConfigured(n)
        case .notImplemented(let reason): return .execution("Not implemented in MVP: \(reason)")
        }
    }
}
