import Foundation
import FamilyControls
import CryptoKit

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
    static let armSignatureKey = "evlin.earned.armSignature"

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

    nonisolated static func makeArmSignature(
        deviceID: String,
        usageDate: String,
        timezoneIdentifier: String,
        poolMinutes: Int,
        capMinutes: Int,
        offsetMinutes: Int,
        selectionFingerprint: String
    ) -> String {
        [
            canonicalDeviceIdentity(deviceID) ?? deviceID,
            usageDate,
            timezoneIdentifier,
            "pool=\(poolMinutes)",
            "cap=\(capMinutes)",
            "offset=\(max(0, offsetMinutes))",
            "selection=\(selectionFingerprint)",
        ].joined(separator: "|")
    }

    nonisolated static func shouldStartMonitoring(
        previousSignature: String?,
        nextSignature: String,
        force: Bool
    ) -> Bool {
        force || previousSignature != nextSignature
    }

    private static func selectionFingerprint(_ selection: FamilyActivitySelection) -> String {
        guard let data = try? JSONEncoder().encode(selection) else {
            return EarnedBudgetScheduler.selectionSummary(selection)
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func currentArmSignature(
        deviceID: String,
        usageDate: String,
        timezoneIdentifier: String,
        poolMinutes: Int,
        capMinutes: Int,
        offsetMinutes: Int,
        selection: FamilyActivitySelection
    ) -> String {
        makeArmSignature(
            deviceID: deviceID,
            usageDate: usageDate,
            timezoneIdentifier: timezoneIdentifier,
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            offsetMinutes: offsetMinutes,
            selectionFingerprint: selectionFingerprint(selection)
        )
    }

    nonisolated static func replacementOffset(
        acceptedEstimateMinutes: Int?,
        runningOffsetMinutes: Int
    ) -> Int {
        max(0, acceptedEstimateMinutes ?? runningOffsetMinutes)
    }

    @discardableResult
    static func installReplacement(
        replacementOffset: Int,
        replacementSignature: String,
        store: EarnedTimeStore,
        defaults: UserDefaults?,
        startMonitoring: () -> Bool
    ) -> Bool {
        guard startMonitoring() else { return false }
        store.earnedUsageOffsetMinutes = replacementOffset
        defaults?.set(replacementSignature, forKey: armSignatureKey)
        defaults?.synchronize()
        return true
    }

    static func stopAndInvalidateSignature(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        stopMonitoring: (() -> Void)? = nil
    ) {
        if let stopMonitoring {
            stopMonitoring()
        } else {
            EarnedBudgetScheduler.shared.stop()
        }
        defaults?.removeObject(forKey: EarnedActivityGeneration.lifecycleKey)
        defaults?.removeObject(forKey: EarnedActivityGeneration.activeActivityNameKey)
        defaults?.removeObject(forKey: armSignatureKey)
        defaults?.synchronize()
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
    static func reconcileIdentityTransition() -> Bool {
        guard let currentRaw = UserDefaults.standard.string(
                forKey: CommandPoller.childDeviceIDDefaultsKey),
              !currentRaw.isEmpty
        else { return false }
        let current = canonicalDeviceIdentity(currentRaw) ?? currentRaw

        let suite = UserDefaults(suiteName: "group.com.evlin.ios")
        let ownerRaw = suite?.string(forKey: identityOwnerKey)
        if isSameDeviceIdentity(ownerRaw, currentRaw) {
            if ownerRaw != current {
                suite?.set(current, forKey: identityOwnerKey)
            }
            return false
        }

        defer { suite?.set(current, forKey: identityOwnerKey) }
        guard let ownerRaw, !ownerRaw.isEmpty else { return false }
        let owner = canonicalDeviceIdentity(ownerRaw) ?? ownerRaw

        stopAndInvalidateSignature(defaults: suite)
        EarnedTimeStore.shared.clearUsageStateForIdentityChange()
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
    static func armIfReady(force: Bool = false) {
        reconcileIdentityTransition()
        EarnedBudgetScheduler.shared.recoverInterruptedTransition()

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

        let store = EarnedTimeStore.shared
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
            stopAndInvalidateSignature()
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped usage-counting-paused \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }

        let poolMinutes = store.poolMinutes ?? 60
        let capMinutes = store.capMinutes ?? poolMinutes
        let usageContext = store.usageContext()
        let usageDate = usageContext.usageDate
        let timezoneIdentifier = usageContext.timezoneIdentifier
        let defaults = UserDefaults(suiteName: EarnedTimeStore.appGroupSuiteName)
        let scalarOffset = store.earnedUsageOffsetMinutes
        let scalarSignature = defaults?.string(forKey: armSignatureKey)
        let migrationSignature = currentArmSignature(
            deviceID: current,
            usageDate: usageDate,
            timezoneIdentifier: timezoneIdentifier,
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            offsetMinutes: scalarOffset,
            selection: selection
        )
        if EarnedActivityGeneration.loadLifecycle(defaults: defaults) == nil {
            let persistedName = defaults?.string(
                forKey: EarnedActivityGeneration.activeActivityNameKey
            )
            let migrationName: String? = {
                if let persistedName,
                   persistedName.hasPrefix(EarnedActivityGeneration.generatedActivityPrefix) {
                    return persistedName
                }
                return scalarSignature == nil
                    ? nil
                    : EarnedActivityGeneration.legacyActivityName
            }()
            if let migrationName {
                EarnedActivityGeneration.migrateActiveIfNeeded(
                    .init(
                        activityName: migrationName,
                        offsetMinutes: scalarOffset,
                        armSignature: scalarSignature ?? migrationSignature,
                        usageDate: usageDate,
                        timezoneIdentifier: timezoneIdentifier
                    ),
                    defaults: defaults
                )
            }
        }
        let activeGeneration = EarnedActivityGeneration
            .loadLifecycle(defaults: defaults)?.active
        let runningOffset = activeGeneration?.offsetMinutes ?? scalarOffset
        if let activeGeneration {
            store.earnedUsageOffsetMinutes = activeGeneration.offsetMinutes
            defaults?.set(activeGeneration.armSignature, forKey: armSignatureKey)
            defaults?.set(
                activeGeneration.activityName,
                forKey: EarnedActivityGeneration.activeActivityNameKey
            )
            defaults?.synchronize()
        }
        let stableSignature = currentArmSignature(
            deviceID: current,
            usageDate: usageDate,
            timezoneIdentifier: timezoneIdentifier,
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            offsetMinutes: runningOffset,
            selection: selection
        )
        guard shouldStartMonitoring(
            previousSignature: activeGeneration?.armSignature
                ?? defaults?.string(forKey: armSignatureKey),
            nextSignature: stableSignature,
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
            stopAndInvalidateSignature(defaults: defaults)
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyEarnedArmAttempt,
                "skipped no-remaining pool=\(poolMinutes) cap=\(capMinutes) offset=\(replacementOffset) \(EarnedBudgetScheduler.selectionSummary(selection))"
            )
            return
        }
        let replacementSignature = currentArmSignature(
            deviceID: current,
            usageDate: usageDate,
            timezoneIdentifier: timezoneIdentifier,
            poolMinutes: poolMinutes,
            capMinutes: capMinutes,
            offsetMinutes: replacementOffset,
            selection: selection
        )
        let replacementGeneration = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            offsetMinutes: replacementOffset,
            armSignature: replacementSignature,
            usageDate: usageDate,
            timezoneIdentifier: timezoneIdentifier
        )
        _ = installReplacement(
            replacementOffset: replacementOffset,
            replacementSignature: replacementSignature,
            store: store,
            defaults: defaults,
            startMonitoring: {
                EarnedBudgetScheduler.shared.armFromNow(
                    poolMinutes: remainingPolicy.poolMinutes,
                    capMinutes: remainingPolicy.capMinutes,
                    selection: selection,
                    generation: replacementGeneration,
                    timeZone: TimeZone(identifier: timezoneIdentifier) ?? .current
                )
            }
        )
    }
}
