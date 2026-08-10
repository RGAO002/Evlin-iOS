import Foundation
import FamilyControls

/// Shared entry points for arming the earned-budget DeviceActivity ladder and
/// for tearing down earned-time state when the child-device identity changes
/// (re-pairing under a new family / account switch).
///
/// Incident (2026-07-03): a kid device was re-registered under a new family
/// while the previous family's ladder (thresholds sized to a 140-min pool,
/// old measurement selection) stayed armed. Its `t185` event was reported
/// under the new identity and billed to the new family's 20-min pool,
/// exhausting it instantly ("Time's up" the moment a measured app opened).
/// Two invariants close that hole:
///
/// 1. The moment the stored child-device ID differs from the identity that
///    owns the current ladder/day state, the old ladder is stopped and the
///    per-family day state is cleared (`reconcileIdentityTransition`).
/// 2. A freshly saved measurement selection arms the ladder immediately
///    (`armIfReady` called from the capture view) instead of waiting for the
///    next scene activation, so no stale ladder survives the capture step.
@MainActor
enum EarnedBudgetArming {

    /// App-Group key remembering which child-device identity last owned the
    /// earned-budget ladder + EarnedTimeStore day state.
    static let identityOwnerKey = "evlin.earned.identityOwner"

    nonisolated static func canonicalDeviceIdentity(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let uuid = UUID(uuidString: trimmed)
        else { return nil }
        return uuid.uuidString.lowercased()
    }

    nonisolated static func isSameDeviceIdentity(_ lhs: String?, _ rhs: String?) -> Bool {
        if let left = canonicalDeviceIdentity(lhs),
           let right = canonicalDeviceIdentity(rhs) {
            return left == right
        }
        let leftRaw = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rightRaw = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !leftRaw.isEmpty && leftRaw == rightRaw
    }

    nonisolated static func requiresGenerationReplacement(
        _ activeGeneration: LegacyGenerationProvenance?
    ) -> Bool {
        activeGeneration?.armedAt == nil
    }

    nonisolated static func legacyGenerationKey(
        deviceID: UUID,
        timezoneIdentifier: String,
        policyRevision: String,
        selectionBytes: Data,
        enforcementSetID: UUID
    ) -> MeteringGenerationKey {
        MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: deviceID,
            canonicalTimezone: timezoneIdentifier,
            policyRevision: policyRevision,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: enforcementSetID
        )
    }

    nonisolated static func shouldReplaceLegacyGeneration(
        _ active: LegacyGenerationProvenance?,
        with nextKey: MeteringGenerationKey,
        usageDate: String,
        force: Bool
    ) -> Bool {
        guard !force,
              let active,
              active.armedAt != nil,
              active.generationKey == nextKey,
              active.usageDate == usageDate,
              active.timezoneIdentifier == nextKey.canonicalTimezone,
              canonicalDeviceIdentity(active.deviceID)
                == nextKey.childDeviceID.uuidString.lowercased()
        else { return true }
        return false
    }

    nonisolated static func replacementOffset(
        acceptedEstimateMinutes: Int?,
        runningOffsetMinutes: Int
    ) -> Int {
        max(0, acceptedEstimateMinutes ?? runningOffsetMinutes)
    }

    /// `nonisolated`: pure sequencing plus one store write, and it has to be
    /// callable from off the main thread now that the arm hops.
    @discardableResult
    nonisolated static func installReplacement(
        replacementOffset: Int,
        store: EarnedTimeStore,
        startMonitoring: () -> Bool
    ) -> Bool {
        guard startMonitoring() else { return false }
        store.earnedUsageOffsetMinutes = replacementOffset
        return true
    }

    /// `nonisolated`: defaults reads and a scheduler stop, no UI. Callable from
    /// off the main thread now that the daemon calls hop.
    nonisolated static func stopLegacyMonitoring(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        epochStore: DeviceEpochStore = .shared,
        stopMonitoring: (() -> Void)? = nil
    ) {
        if let owner = defaults?.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:)),
           let stopMonitoring {
            let stoppedPersisted = LegacyMeteringActivity.stopPersisted(
                store: epochStore,
                owner: owner,
                stopMonitoring: { _ in stopMonitoring() }
            )
            if !stoppedPersisted {
                stopMonitoring()
            }
        } else {
            EarnedBudgetScheduler.shared.stop()
        }
        defaults?.synchronize()
    }

    static func teardownFamilyIdentity(
        appGroupDefaults: UserDefaults? = UserDefaults(
            suiteName: EarnedTimeStore.appGroupSuiteName
        ),
        store: EarnedTimeStore = .shared,
        epochStore: DeviceEpochStore? = nil,
        stopMonitoring: (() -> Void)? = nil,
        beforeUsageClear: () -> Void = {},
        now: Date = Date()
    ) {
        if let epochStore,
           let oldOwner = appGroupDefaults?.string(forKey: "evlin.childId")
            .flatMap(UUID.init(uuidString:)) {
            let workID: UUID
            do {
                workID = try epochStore.prepareIdentityCleanup(
                    oldOwner: oldOwner,
                    newOwner: nil,
                    oldFallbackKeys: EarnedSampleReporter.retryKeys(deviceID: oldOwner),
                    now: now
                )
            } catch {
                // Fail closed: invalidate callbacks, but keep the owner mirror
                // intact so a later recovery attempt can still authorize and
                // persist the cleanup envelope.
                stopLegacyMonitoring(
                    defaults: appGroupDefaults,
                    stopMonitoring: stopMonitoring
                )
                return
            }
            stopLegacyMonitoring(
                defaults: appGroupDefaults,
                stopMonitoring: stopMonitoring
            )
            beforeUsageClear()
            store.clearUsageStateForIdentityChange()
            if let cleanup = try? epochStore.read().identityCleanupWork,
               cleanup.workID == workID {
                try? epochStore.identityCleanupTransaction(workID: workID) { _, work in
                    work.clearedUsageDates = Set(work.oldUsageDates)
                }
            }
            appGroupDefaults?.removeObject(forKey: "evlin.childId")
            appGroupDefaults?.synchronize()
            try? epochStore.identityCleanupTransaction(workID: workID) { _, work in
                work.ownerMirrorTransitionAcknowledged = true
            }
            return
        }

        // Legacy/no-v2-root compatibility path. Production identity entry
        // points pass DeviceEpochStore.shared and use the durable path above.
        stopLegacyMonitoring(
            defaults: appGroupDefaults,
            stopMonitoring: stopMonitoring
        )
        appGroupDefaults?.removeObject(forKey: "evlin.childId")
        appGroupDefaults?.synchronize()
        beforeUsageClear()
        store.clearUsageStateForIdentityChange()
    }

    static func mirrorChildIdentity(
        _ childID: UUID,
        appGroupDefaults: UserDefaults? = UserDefaults(
            suiteName: EarnedTimeStore.appGroupSuiteName
        ),
        readinessStore: EarnedTimeStore = .shared,
        epochStore: DeviceEpochStore? = nil,
        hasGenerationState: Bool? = nil,
        stopMonitoring: (() -> Void)? = nil,
        now: Date = Date()
    ) {
        let next = childID.uuidString.lowercased()
        let current = canonicalDeviceIdentity(
            appGroupDefaults?.string(forKey: "evlin.childId")
        )
        let lifecycle = try? (epochStore ?? .shared).read().legacy
        let boundDeviceMismatch = [
            lifecycle?.active?.deviceID,
            lifecycle?.pending?.deviceID,
        ]
        .compactMap(canonicalDeviceIdentity)
        .contains { $0 != next }
        let inferredGenerationState = lifecycle?.active != nil
            || lifecycle?.pending != nil
            || lifecycle?.retiringActivityNames.isEmpty == false
            || lifecycle?.breadcrumbActivityNames.isEmpty == false
            || lifecycle?.scalarActiveActivityName != nil
        if let epochStore,
           let cleanup = try? epochStore.read().identityCleanupWork,
           cleanup.newOwnerChildDeviceID == nil {
            // Pairing writes evlin.childId before this entry runs. The durable
            // cleanup envelope, not the mutable mirror, decides whether this
            // pairing may complete a prior no-owner teardown. The backend can
            // legitimately reuse the same device row after sign-out, so an
            // equal old/new UUID still has to adopt and finish the teardown.
            do {
                _ = try epochStore.adoptIdentityCleanupTarget(
                    workID: cleanup.workID,
                    newOwner: childID,
                    now: now
                )
                readinessStore.clearAuthoritativeStateReadiness()
                appGroupDefaults?.set(next, forKey: "evlin.childId")
                appGroupDefaults?.synchronize()
                try epochStore.identityCleanupTransaction(workID: cleanup.workID) { _, work in
                    work.ownerMirrorTransitionAcknowledged = true
                }
            } catch {
                // The cleanup envelope is the authority for this transition.
                // Do not write a new mirror if it cannot be adopted exactly.
                readinessStore.clearAuthoritativeStateReadiness()
                return
            }
            return
        }
        if current != next,
           let epochStore,
           let oldOwner = current.flatMap(UUID.init(uuidString:)) {
            let workID: UUID
            do {
                workID = try epochStore.prepareIdentityCleanup(
                    oldOwner: oldOwner,
                    newOwner: childID,
                    oldFallbackKeys: EarnedSampleReporter.retryKeys(deviceID: oldOwner),
                    now: now
                )
            } catch {
                readinessStore.clearAuthoritativeStateReadiness()
                stopLegacyMonitoring(
                    defaults: appGroupDefaults,
                    epochStore: epochStore,
                    stopMonitoring: stopMonitoring
                )
                return
            }
            readinessStore.clearAuthoritativeStateReadiness()
            stopLegacyMonitoring(
                defaults: appGroupDefaults,
                epochStore: epochStore,
                stopMonitoring: stopMonitoring
            )
            readinessStore.clearUsageStateForIdentityChange()
            if let cleanup = try? epochStore.read().identityCleanupWork,
               cleanup.workID == workID {
                try? epochStore.identityCleanupTransaction(workID: workID) { _, work in
                    work.clearedUsageDates = Set(work.oldUsageDates)
                }
            }
            appGroupDefaults?.set(next, forKey: "evlin.childId")
            appGroupDefaults?.synchronize()
            try? epochStore.identityCleanupTransaction(workID: workID) { _, work in
                work.ownerMirrorTransitionAcknowledged = true
            }
            return
        }
        if current != next || boundDeviceMismatch {
            readinessStore.clearAuthoritativeStateReadiness()
            if hasGenerationState ?? inferredGenerationState {
                stopLegacyMonitoring(
                    defaults: appGroupDefaults,
                    epochStore: epochStore ?? .shared,
                    stopMonitoring: stopMonitoring
                )
            }
        }
        appGroupDefaults?.set(next, forKey: "evlin.childId")
        appGroupDefaults?.synchronize()
        if let epochStore {
            do {
                _ = try epochStore.claimInitialOwner(childID)
            } catch {
                // Keep readiness closed. A later recovery pass may retry the
                // exact first claim, but must not arm against an unowned root.
                readinessStore.clearAuthoritativeStateReadiness()
            }
        }
    }

    nonisolated static func canArmAuthoritativeState(
        deviceID: UUID,
        store: EarnedTimeStore
    ) -> Bool {
        store.isAuthoritativeStateReady(deviceID: deviceID)
    }

    /// Detect a child-device identity change and tear down earned-time state
    /// armed under the previous identity: stop the old DeviceActivity ladder
    /// and clear day/usage state so old thresholds can never be billed to the
    /// new family. The measurement selection is kept — it describes THIS
    /// device's apps and remains valid across families.
    ///
    /// A first claim (no recorded owner: fresh install or upgrade from a
    /// build without this guard) records ownership without tearing down.
    ///
    /// Returns true when a transition was detected and state was torn down.
    @discardableResult
    static func reconcileIdentityTransition(
        epochStore: DeviceEpochStore? = .shared,
        standardDefaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = UserDefaults(
            suiteName: EarnedTimeStore.appGroupSuiteName
        ),
        readinessStore: EarnedTimeStore = .shared
    ) -> Bool {
        guard let currentRaw = standardDefaults.string(
                forKey: CommandPoller.childDeviceIDDefaultsKey),
              !currentRaw.isEmpty
        else { return false }
        let current = canonicalDeviceIdentity(currentRaw) ?? currentRaw

        let explicitOwnerRaw = appGroupDefaults?.string(forKey: identityOwnerKey)
        let mirroredOwnerRaw = appGroupDefaults?.string(forKey: "evlin.childId")
        let ownerRaw: String?
        if isSameDeviceIdentity(explicitOwnerRaw, currentRaw),
           let mirroredOwnerRaw,
           !isSameDeviceIdentity(mirroredOwnerRaw, currentRaw) {
            // A prior transition persisted the marker but failed before the
            // durable owner mirror moved. The mirror still owns the epoch
            // store and is the only valid cleanup authority.
            ownerRaw = mirroredOwnerRaw
        } else {
            ownerRaw = explicitOwnerRaw ?? mirroredOwnerRaw
        }
        if isSameDeviceIdentity(ownerRaw, currentRaw) {
            if explicitOwnerRaw != current {
                appGroupDefaults?.set(current, forKey: identityOwnerKey)
            }
            return false
        }

        guard let ownerRaw, !ownerRaw.isEmpty else {
            if let currentID = UUID(uuidString: currentRaw) {
                mirrorChildIdentity(
                    currentID,
                    appGroupDefaults: appGroupDefaults,
                    readinessStore: readinessStore,
                    epochStore: epochStore
                )
            }
            appGroupDefaults?.set(current, forKey: identityOwnerKey)
            return false
        }
        let owner = canonicalDeviceIdentity(ownerRaw) ?? ownerRaw

        if let currentID = UUID(uuidString: currentRaw) {
            mirrorChildIdentity(
                currentID,
                appGroupDefaults: appGroupDefaults,
                readinessStore: readinessStore,
                epochStore: epochStore
            )
            guard isSameDeviceIdentity(
                appGroupDefaults?.string(forKey: "evlin.childId"),
                currentRaw
            ) else {
                appGroupDefaults?.set(owner, forKey: identityOwnerKey)
                return false
            }
        } else {
            stopLegacyMonitoring(
                defaults: appGroupDefaults,
                epochStore: epochStore ?? .shared
            )
            appGroupDefaults?.removeObject(forKey: "evlin.childId")
            appGroupDefaults?.synchronize()
            readinessStore.clearUsageStateForIdentityChange()
        }
        appGroupDefaults?.set(current, forKey: identityOwnerKey)
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyEarnedIdentityTransition,
            "teardown owner=\(owner) current=\(current)"
        )
        ScreenTimeEventLog.emit(ScreenTimeEvent(
            ts: ISO8601DateFormatter().string(from: Date()),
            emitter: .kidApp,
            deviceID: current,
            dayKey: nil,
            kind: .decision,
            source: .earnedPool,
            app: "device-wide",
            reason: "identity_switch_teardown",
            nums: nil,
            transition: .init(before: owner, after: current),
            policyGen: nil,
            corrID: nil))
        return true
    }

    /// Arm (or re-arm) the earned-budget ladder when this is a child device
    /// with a saved measurement selection and an applied pool config. Safe to
    /// call repeatedly — arming replaces any previously armed ladder. The
    /// pool/cap policy is sourced from `EarnedTimeStore`, preserving already
    /// counted minutes as a re-arm offset before resuming from now.
    /// `async` because every DeviceActivity touch below has to leave the main
    /// thread: these are synchronous XPC round trips with no timeout, and this
    /// function is reached from BigKidStatePoller's ten-second loop and from the
    /// capture view's dismissal handler (Esen's finding #3). The guard chain
    /// stays on the main actor — it is UserDefaults and store reads, none of
    /// which block — so only the daemon calls hop.
    static func armIfReady(force: Bool = false) async {
        reconcileIdentityTransition()
        _ = await MeteringDeviceActivityGateway.perform("earnedBudget.recoverTransition") {
            EarnedBudgetScheduler.shared.recoverInterruptedTransition()
            return true
        }

        // Only arm on the child device.
        let mode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        guard mode == "child" else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped appMode=\(mode.isEmpty ? "(empty)" : mode)"
            )
            return
        }
        guard let currentRaw = UserDefaults.standard.string(
                forKey: CommandPoller.childDeviceIDDefaultsKey),
              !currentRaw.isEmpty
        else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped missing-child-device-id"
            )
            return
        }
        let current = canonicalDeviceIdentity(currentRaw) ?? currentRaw
        guard let currentDeviceID = UUID(uuidString: currentRaw) else { return }

        let localProtocolSelection = (try? DeviceEpochStore.shared.read())?
            .ratchets[currentDeviceID]?.localSelection
        guard EarnedBudgetScheduler.canInstallLegacyLadder(
            localSelection: localProtocolSelection
        ) else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped v2-metering-selected device=\(current)"
            )
            return
        }

        let store = EarnedTimeStore.shared
        let defaults = UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)
        guard canonicalDeviceIdentity(
            defaults?.string(forKey: "evlin.childId")
        ) == current,
        canArmAuthoritativeState(deviceID: currentDeviceID, store: store) else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped authoritative-state-not-ready device=\(current)"
            )
            return
        }
        guard let selection = store.measurementSelection else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped missing-measurement lockedSetID=\(store.lockedSetID ?? "(missing)")"
            )
            return
        }
        guard store.hasMeasurableSelection else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped empty-measurement lockedSetID=\(store.lockedSetID ?? "(missing)") \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }
        guard store.lockedSetID != nil else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped missing-locked-set \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }
        guard store.usageCountingAllowed else {
            await stopLegacyMonitoringOffMain()
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped usage-counting-paused \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }

        let poolMinutes = store.poolMinutes ?? 60
        let capMinutes = store.capMinutes ?? poolMinutes
        let usageContext = store.currentPolicyDateContext()
        let usageDate = usageContext.usageDate
        let timezoneIdentifier = usageContext.timezoneIdentifier
        let scalarOffset = store.earnedUsageOffsetMinutes
        guard let selectionBytes = store.measurementSelectionBytes,
              let enforcementSetRaw = store.lockedSetID,
              let enforcementSetID = UUID(uuidString: enforcementSetRaw)
        else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped incomplete-generation-identity"
            )
            return
        }
        let policyRevision = store.runtimePolicyRevision
            ?? "legacy-pool:\(poolMinutes)-cap:\(capMinutes)"
        let nextGenerationKey = legacyGenerationKey(
            deviceID: currentDeviceID,
            timezoneIdentifier: timezoneIdentifier,
            policyRevision: policyRevision,
            selectionBytes: selectionBytes,
            enforcementSetID: enforcementSetID
        )
        let lifecycle = try? DeviceEpochStore.shared.read().legacy
        let activeGeneration = lifecycle?.active
        let runningOffset = activeGeneration?.offsetMinutes ?? scalarOffset
        if let activeGeneration {
            store.earnedUsageOffsetMinutes = activeGeneration.offsetMinutes
        }
        guard shouldReplaceLegacyGeneration(
            activeGeneration,
            with: nextGenerationKey,
            usageDate: usageDate,
            force: force
        ) else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped already-armed pool=\(poolMinutes) cap=\(capMinutes) offset=\(runningOffset) \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }

        let replacementOffset = Self.replacementOffset(
            acceptedEstimateMinutes: store.acceptedEstimateMinutes,
            runningOffsetMinutes: runningOffset
        )
        guard let remainingPolicy = EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            offsetMinutes: replacementOffset
        ) else {
            await stopLegacyMonitoringOffMain(defaults: defaults)
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped no-remaining pool=\(poolMinutes) cap=\(capMinutes) offset=\(replacementOffset) \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }
        let replacementGeneration = LegacyGenerationProvenance(
            activityName: LegacyMeteringActivity.generatedActivityName(id: UUID()),
            deviceID: current,
            offsetMinutes: replacementOffset,
            usageDate: usageDate,
            timezoneIdentifier: timezoneIdentifier,
            generationKey: nextGenerationKey,
            armedAt: Date()
        )
        // The arm itself. `installReplacement` only writes the offset once the
        // monitor is actually running, so hopping the whole thing keeps that
        // ordering intact rather than recording an arm that never happened.
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        let armed = await MeteringDeviceActivityGateway.perform("earnedBudget.armFromNow") {
            installReplacement(
                replacementOffset: replacementOffset,
                store: store,
                startMonitoring: {
                    EarnedBudgetScheduler.shared.armFromNow(
                        poolMinutes: remainingPolicy.poolMinutes,
                        capMinutes: remainingPolicy.capMinutes,
                        selection: selection,
                        generation: replacementGeneration,
                        timeZone: timeZone
                    )
                }
            )
        }
        if armed == nil {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped gateway-refused pool=\(poolMinutes) cap=\(capMinutes)"
            )
        }
    }

    /// `stopLegacyMonitoring` off the main thread. Kept as its own hop so the
    /// two early-return branches above read the same as they did.
    private static func stopLegacyMonitoringOffMain(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios")
    ) async {
        _ = await MeteringDeviceActivityGateway.perform("earnedBudget.stopLegacy") {
            stopLegacyMonitoring(defaults: defaults)
            return true
        }
    }

}
