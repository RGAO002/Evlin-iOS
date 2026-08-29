import Foundation

nonisolated enum MeteringWorkTerminal: String, Codable, Sendable {
    case pending, succeeded, superseded, rejected, abandoned
}

nonisolated struct MeteringRetryState: Codable, Equatable, Sendable {
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastErrorCode: String?
    var terminal: MeteringWorkTerminal
}

nonisolated struct MeteringNetworkClaim: Codable, Equatable, Sendable {
    static let leaseDuration: TimeInterval = 60

    let token: UUID
    let claimedAt: Date
    let expiresAt: Date
}

nonisolated enum MeteringRetryPolicy {
    static let delays: [TimeInterval] = [0, 5, 15, 60, 300]

    static func nextAttempt(after failureCount: Int, now: Date) -> Date {
        let index = min(max(failureCount, 1), delays.count - 1)
        return now.addingTimeInterval(delays[index])
    }
}

nonisolated struct MeteringPolicyGeneration: Codable, Equatable, Sendable {
    let generationID: UUID
    let protocolVersion: Int
    let childDeviceID: UUID
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
    let measurementSelectionBytes: Data
    let createdAt: Date
    var retiredAt: Date?
    var configuredPoolMinutes: Int? = nil
    var configuredDeviceCapMinutes: Int? = nil
}

nonisolated struct MeteringDesiredPolicy: Codable, Equatable, Sendable {
    let commandID: UUID
    let ownerChildDeviceID: UUID
    let orderingToken: Int64
    let policyRevision: String
    let usageDate: String
    let canonicalTimezone: String
    let dailyPoolMinutes: Int
    let deviceCapMinutes: Int
    let remainingMinutes: Int?
    let enforcementSetID: UUID?
    let receivedAt: Date
    var appliedAt: Date?
    var ackedAt: Date?
}

nonisolated enum MeteringPolicyIngressDisposition: Equatable, Sendable {
    case acceptedNeedsOwner
    case duplicatePending
    case duplicateApplied
    case superseded(latestOrderingToken: Int64)
    case equalTokenConflict
}

nonisolated enum DeviceDailyEpochStatus: String, Codable, Sendable {
    case active, paused, exhausted, retired
}

nonisolated enum MeteringEpochBaseSource: String, Codable, Sendable {
    case childState200, registration200, registrationConflict409
}

nonisolated enum BaseCorrectionState: String, Codable, Sendable {
    case available, used
}

nonisolated enum MeteringEpochRetireReason: String, Codable, Sendable {
    case dayRollover, policyChange, selectionChange, enforcementSetChange
    case identityRecovery, gateResumeConservative, authoritativeBaseMismatch
    case coverageExpired, activationSuperseded
    // The route stopped delivering while nothing about the key changed —
    // retired so a fresh physical route can be minted under the paired
    // `delivery_recovery` replacement reason (the registry keeps the
    // switchover window alive only when retire and replacement reasons
    // match).
    case deliveryRecovery
}

nonisolated struct DeviceDailyEpoch: Codable, Equatable, Sendable {
    let epochID: UUID
    let protocolVersion: Int
    let childDeviceID: UUID
    let usageDate: String
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
    let startedAt: Date
    var registeredAt: Date?
    let baseAcceptedMinutes: Int
    let baseSource: MeteringEpochBaseSource
    var lastRawThresholdMinutes: Int
    var excludedWhilePausedMinutes: Int
    var status: DeviceDailyEpochStatus
    var resumeBoundaryPending: Bool
    var retiredAt: Date?
    var retireReason: MeteringEpochRetireReason?
    var exhaustedAt: Date?
    var baseCorrectionState: BaseCorrectionState
    var authoritativeBaseConflict: EpochRegistrationConflictDTO? = nil
}

nonisolated struct DatedSchedulePlan: Codable, Equatable, Sendable {
    // DIAGNOSTIC A/B (2026-07-24): topology 6 = arm-from-now interval start.
    // Thresholds already crossed at arm time never fire (finding ④, confirmed on
    // clean device tonight); starting the interval at arm time makes fresh usage
    // count from zero, matching the only shapes that ever fired on device.
    static let currentTopologyVersion = 8

    let usageDate: String
    let timezoneIdentifier: String
    let calendarIdentifier: String
    let topologyVersion: Int?
    let intervalStartAt: Date?

    init(
        usageDate: String,
        timezoneIdentifier: String,
        calendarIdentifier: String,
        topologyVersion: Int? = currentTopologyVersion,
        intervalStartAt: Date? = nil
    ) {
        self.usageDate = usageDate
        self.timezoneIdentifier = timezoneIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.topologyVersion = topologyVersion
        self.intervalStartAt = intervalStartAt
    }
}

nonisolated struct MeteringEventPlan: Codable, Equatable, Sendable {
    let eventName: String
    let thresholdMinutes: Int
}

/// The ladder arithmetic, in the one file every metering target links.
///
/// `MeteringDatedSchedule` used to own it, but BUG 1's fix makes the STORE
/// re-cut ladders (a base that moves without its rungs is what reported 305
/// minutes into a 180-minute pool), and `DeviceEpochStore` is compiled into
/// `EvlinPushApplier`, which does not carry `MeteringDatedSchedule`.
/// `MeteringDatedSchedule` now delegates here so there is exactly one cut.
nonisolated enum MeteringLadderMath {
    static let bucketMinutes = 5
    static let guardEventCount = 48

    /// One minute-fine rung at the front of every ladder — a designated
    /// sacrifice. The conservative resume eats the FIRST bell as its
    /// calibration boundary; with a 5-minute first rung that cost 5 real
    /// minutes after every reflection/task resume. A single t1 caps the
    /// calibration loss at exactly one minute (the eaten rung goes to the
    /// exclusion high-water, so it never debits the pool), and the bar then
    /// moves on the normal 5-minute cadence. Deliberately ONE rung: a t1..t4
    /// lead made the bar drain minute-by-minute, which read as broken
    /// (2026-08-07, Fred).
    static let fineLeadRungCount = 1

    /// Rungs covering `remainingMinutes`: minute-fine lead rungs, then
    /// `bucketMinutes` steps widened just enough to stay within
    /// `guardEventCount` events.
    static func thresholds(remainingMinutes: Int) -> [Int] {
        guard remainingMinutes > 0 else { return [] }
        let coarseBudget = guardEventCount - fineLeadRungCount
        let minimumStep = remainingMinutes / coarseBudget
            + (remainingMinutes % coarseBudget == 0 ? 0 : 1)
        let step = max(
            bucketMinutes,
            ((minimumStep + bucketMinutes - 1) / bucketMinutes) * bucketMinutes
        )
        var result = (1...fineLeadRungCount).filter { $0 < min(step, remainingMinutes) }
        result += stride(from: step, through: remainingMinutes, by: step)
        if result.last != remainingMinutes {
            result.append(remainingMinutes)
        }
        return result
    }

    /// The absolute ceiling of one usage date: the highest minute total any rung
    /// of that day's ladder may ever report. `nil` when the generation predates
    /// the pool/cap capture, in which case no bound is claimed rather than one
    /// being invented.
    static func ceiling(poolMinutes: Int?, capMinutes: Int?) -> Int? {
        guard let poolMinutes, let capMinutes else { return nil }
        let ceiling = min(poolMinutes, capMinutes)
        return ceiling > 0 ? ceiling : nil
    }

    /// Cuts a fresh ladder for `routeID` over the minutes still available above
    /// `ladderBaseMinutes`. `nil` when nothing meaningful is left, so callers can
    /// tell "re-cut" apart from "there is no ladder left to cut".
    static func plannedEvents(
        routeID: UUID,
        ladderBaseMinutes: Int,
        ceilingMinutes: Int,
        physicalGenerationOffsetMinutes: Int = 0
    ) -> [MeteringEventPlan]? {
        let remaining = ceilingMinutes - max(0, ladderBaseMinutes)
        guard remaining >= bucketMinutes else { return nil }
        let cut = thresholds(remainingMinutes: remaining)
        guard !cut.isEmpty else { return nil }
        let activityName = "evlin.earned.v2.\(routeID.uuidString.lowercased())"
        return cut.map { threshold in
            let physicalThreshold = threshold + max(0, physicalGenerationOffsetMinutes)
            return MeteringEventPlan(
                eventName: "\(activityName).t\(physicalThreshold)",
                thresholdMinutes: physicalThreshold
            )
        }
    }
}

nonisolated enum MeteringRouteLifecycle: String, Codable, Sendable {
    case planned, active, retired, tombstoned
}

nonisolated struct MeteringCallbackRoute: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let namespace: String
    let generationID: UUID
    let generationKey: MeteringGenerationKey
    let ownerChildDeviceID: UUID
    let usageDate: String
    let epochID: UUID
    var plannedSchedule: DatedSchedulePlan
    var installedSchedule: DatedSchedulePlan?
    var plannedEvents: [MeteringEventPlan]
    var installedEvents: [MeteringEventPlan]?
    var lifecycle: MeteringRouteLifecycle
    let createdAt: Date
    /// The epoch base `plannedEvents` was cut against — i.e. what a rung of this
    /// ladder MEANS. A threshold `T` promises "the child has now used
    /// `ladderBaseMinutes + T` minutes today", and the ladder is cut so
    /// `ladderBaseMinutes + topRung == min(pool, cap)`.
    ///
    /// It exists because the base and the ladder are two records of the same
    /// fact and they were free to drift apart. `absorbCreditedProgressForRearm`
    /// raised `epoch.baseAcceptedMinutes` without re-cutting the rungs, so a
    /// ladder cut for base 20 (top rung 160) was still armed while the base read
    /// 145 — and `base + threshold` reported 305 minutes against a 180-minute
    /// pool (iPad 2026-07-25 13:37, `used:295` / `used:305`). Reporting against
    /// THIS value instead of the live base makes the sample correct even when
    /// Apple re-delivers a rung of a ladder the store has already moved past,
    /// which no amount of atomicity around the re-arm can prevent.
    ///
    /// `nil` = a route persisted before this field existed. Its ladder base is
    /// unknowable, so the callback path falls back to the epoch base and leans
    /// on the ceiling clamp; `repairLadderBaseInvariantIfNeeded` re-cuts it into
    /// a self-consistent state on the next recovery pass.
    var ladderBaseMinutes: Int? = nil

    /// Physical minutes already present in Apple's counter when this route was
    /// armed. Its event thresholds are shifted by this amount, while accounting
    /// subtracts it. Route scope is essential: late callbacks from an older
    /// route must continue to use that route's own physical scale.
    ///
    /// Optional for backward-compatible decoding. Nil means zero and every new
    /// day, identity, or policy generation starts at zero unless an arm-grace
    /// calibration explicitly re-cuts this exact route lineage.
    var physicalGenerationOffsetMinutes: Int? = nil
}

nonisolated struct MeteringRouteTombstone: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let eventNames: [String]
    let ownerChildDeviceID: UUID
    let usageDate: String
    let epochID: UUID
    let generationID: UUID
    let canonicalDayEnd: Date
    var stopAcknowledgedAt: Date?
    var referencedWorkIDs: Set<UUID>
    var retainedUntil: Date?
}

nonisolated enum MeteringInstallAuthorization: String, Codable, Sendable {
    case registrationRequired, registered, futurePlanned, offlinePending
}

nonisolated enum ActivityInstallPhase: String, Codable, Sendable {
    case pendingStart, starting, installed, verified, dualActive
    case active, pendingStop, stopped
}

nonisolated enum MeteringProcessRole: String, Codable, Sendable {
    case app
    case deviceActivityMonitor = "deviceActivityMonitor"
    case pushApplier = "pushApplier"
}

nonisolated struct MeteringProcessIdentity: Equatable, Sendable {
    let role: MeteringProcessRole
    let instanceID: UUID

    init(role: MeteringProcessRole, instanceID: UUID) {
        self.role = role
        self.instanceID = instanceID
    }
}

nonisolated struct ActivityInstallClaim: Codable, Equatable, Sendable {
    static let leaseDuration: TimeInterval = 60

    let token: UUID
    let process: MeteringProcessRole
    let instanceID: UUID
    let claimedAt: Date
    let expiresAt: Date
}

nonisolated struct ActivityInstallWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let routeID: UUID
    var authorization: MeteringInstallAuthorization
    var phase: ActivityInstallPhase
    var claim: ActivityInstallClaim?
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated struct EpochRegistrationWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let routeID: UUID
    let request: EpochRegistrationRequestDTO
    var claim: MeteringNetworkClaim?
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated struct EpochActivationWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let routeID: UUID
    let request: EpochActivationRequestDTO
    var claim: MeteringNetworkClaim?
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated enum EpochSampleAuthorization: String, Codable, Sendable {
    case legacyDeliverable, waitingForRegistration, v2Deliverable
}

nonisolated struct MeteringAuthorizedCallbackInput: Codable, Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let eventName: String
    let namespace: String
    let thresholdMinutes: Int
    let observedAt: Date
    let now: Date
    let jitterSeconds: Int
}

/// A provenance-valid callback that arrived before its route finished
/// activating.
///
/// Apple back-delivers thresholds the day's ledger has already met within ~1s of
/// `startMonitoring`, while a route only reaches `.active` after two network
/// round trips (registration + activation). Any mid-day (re)arm therefore loses
/// that first delivery to the strict `lifecycle == .active` provenance guard —
/// and Apple never re-sends a threshold it considers delivered, so the minutes
/// were gone for good (observed 2026-07-24 at 19:13 and 19:46). Parking the
/// callback here and replaying it once the route activates makes the race
/// non-lossy without relaxing any provenance check.
nonisolated struct DeferredMeteringCallback: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let routeID: UUID
    let activityName: String
    let eventName: String
    let namespace: String
    let thresholdMinutes: Int
    let observedAt: Date
    let jitterSeconds: Int
    let parkedAt: Date

    /// Route + event is the natural identity: a redelivery of the same threshold
    /// must collapse onto the same entry rather than accumulate.
    static func key(routeID: UUID, eventName: String) -> String {
        "\(routeID.uuidString.lowercased())|\(eventName)"
    }
}

nonisolated struct MeteringTerminalShieldCandidate: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
    let usageDate: String
    let enforcementSetID: UUID
    let thresholdMinutes: Int
    let observedAt: Date
}

nonisolated enum MeteringAuthorizedCallbackResult: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case discarded(reason: String)
}

nonisolated struct MeteringPreparedAuthorizedCallback: Equatable, Sendable {
    let result: MeteringAuthorizedCallbackResult
    let work: EpochSampleWork?
}

private nonisolated struct MeteringCallbackVerdictContext {
    let routeLifecycle: String
    let coverageStatus: String?
    let coverageReadyThrough: String?
    let epochUsageDate: String?
    let epochStatus: String?
    let epochStartedAt: Date?
    let baseAcceptedMinutes: Int?
    let lastRawThresholdMinutes: Int?
    let excludedWhilePausedMinutes: Int?
    let physicalGenerationOffsetMinutes: Int?
    let sampleAlreadyExisted: Bool
}

private nonisolated struct TerminalRegistrationHistoryKey: Hashable {
    let ownerChildDeviceID: UUID
    let epochID: UUID
    let routeID: UUID
    let requestBytes: Data
    let terminal: String
    let errorCode: String?
    let attemptCount: Int
}

nonisolated struct EpochSampleWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let epochID: UUID?
    let routeID: UUID?
    let request: EpochSampleRequestDTO
    var authorization: EpochSampleAuthorization
    var claim: MeteringNetworkClaim?
    var retry: MeteringRetryState
    let createdAt: Date
}

nonisolated enum LegacyCompatibilityPhase: String, Codable, Sendable {
    case activeV1, dualLanePreparingV2, retiringV1, stoppedV1
}

nonisolated struct LegacyGenerationProvenance: Codable, Equatable, Sendable {
    let activityName: String
    let deviceID: String
    let offsetMinutes: Int
    let usageDate: String
    let timezoneIdentifier: String
    let generationKey: MeteringGenerationKey?
    let armedAt: Date?

    init(
        activityName: String,
        deviceID: String,
        offsetMinutes: Int,
        usageDate: String,
        timezoneIdentifier: String,
        generationKey: MeteringGenerationKey? = nil,
        armedAt: Date? = nil
    ) {
        self.activityName = activityName
        self.deviceID = deviceID
        self.offsetMinutes = offsetMinutes
        self.usageDate = usageDate
        self.timezoneIdentifier = timezoneIdentifier
        self.generationKey = generationKey
        self.armedAt = armedAt
    }
}

nonisolated struct LegacyCompatibilityMonitorState: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let lifecycleVersion: Int
    var active: LegacyGenerationProvenance?
    var pending: LegacyGenerationProvenance?
    var retiringActivityNames: [String]
    var breadcrumbActivityNames: [String]
    var scalarActiveActivityName: String?
    var isStopped: Bool
    var phase: LegacyCompatibilityPhase
    var stopAcknowledgedAt: Date?
}

nonisolated enum LegacyMeteringActivity {
    static let legacyActivityName = "evlin.earned.budget"
    static let generatedActivityPrefix = "evlin.earned.budget."

    static func canonicalDeviceID(_ raw: String?) -> String? {
        guard let raw,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return id.uuidString.lowercased()
    }

    static func generatedActivityName(id: UUID) -> String {
        generatedActivityPrefix + id.uuidString.lowercased()
    }

    static func isEarnedActivityName(_ raw: String) -> Bool {
        raw == legacyActivityName || raw.hasPrefix(generatedActivityPrefix)
    }

    static func isValid(_ generation: LegacyGenerationProvenance) -> Bool {
        isEarnedActivityName(generation.activityName)
            && canonicalDeviceID(generation.deviceID) != nil
            && generation.offsetMinutes >= 0
            && EarnedTimeStore.isCanonicalUsageDate(generation.usageDate)
            && TimeZone(identifier: generation.timezoneIdentifier) != nil
    }

    static func authorizedCallback(
        activityName: String,
        currentDeviceID: String?,
        state: LegacyCompatibilityMonitorState?
    ) -> LegacyGenerationProvenance? {
        guard let state,
              state.phase == .activeV1 || state.phase == .dualLanePreparingV2,
              canonicalDeviceID(currentDeviceID)
                == state.ownerChildDeviceID.uuidString.lowercased(),
              let active = state.active,
              active.activityName == activityName,
              isValid(active)
        else { return nil }
        return active
    }

    static func isAuthorized(
        generation: LegacyGenerationProvenance,
        store: DeviceEpochStore
    ) -> Bool {
        // V1 callbacks must never mutate local accounting after the v2-only
        // cutover. `authorizedCallback` is intentionally retained for cleanup
        // provenance, but execution authorization is permanently denied.
        _ = generation
        _ = store
        return false
    }

    @discardableResult
    static func performIfAuthorized(
        generation: LegacyGenerationProvenance,
        store: DeviceEpochStore,
        defaults: UserDefaults?,
        mutationKeys: [String] = [],
        beforeFinalAuthorizationCheck: () -> Void = {},
        rollbackExternalState: () -> Void = {},
        _ operation: () -> Void
    ) -> Bool {
        guard isAuthorized(generation: generation, store: store) else { return false }
        let before = snapshot(defaults: defaults, keys: mutationKeys)
        operation()
        let written = snapshot(defaults: defaults, keys: mutationKeys)
        beforeFinalAuthorizationCheck()
        guard isAuthorized(generation: generation, store: store) else {
            restore(defaults: defaults, prior: before, whereCurrentMatches: written)
            defaults?.synchronize()
            rollbackExternalState()
            return false
        }
        return true
    }

    static func stopTargets(_ legacy: LegacyCompatibilityMonitorState?) -> [String] {
        uniqueTargets(
            [legacy?.pending?.activityName]
                + (legacy?.retiringActivityNames.map(Optional.some) ?? [])
                + (legacy?.breadcrumbActivityNames.map(Optional.some) ?? [])
                + [legacy?.active?.activityName, legacy?.scalarActiveActivityName, legacyActivityName]
        )
    }

    static func recoverInterruptedTransition(
        store: DeviceEpochStore,
        owner: UUID,
        stopMonitoring: ([String]) -> Void,
        now: Date = Date()
    ) {
        guard let snapshot = try? store.read().legacy,
              snapshot.ownerChildDeviceID == owner
        else { return }
        let hasInterruptedReplacement = snapshot.pending != nil
            || !snapshot.retiringActivityNames.isEmpty
        guard hasInterruptedReplacement || snapshot.phase == .retiringV1 else { return }
        let targets = stopTargets(snapshot).filter { $0 != snapshot.active?.activityName }
        if !targets.isEmpty { stopMonitoring(targets) }
        try? store.transaction(expectedOwner: owner) { state in
            guard var current = state.legacy,
                  current.ownerChildDeviceID == owner
            else { return }
            if current.phase == .retiringV1 {
                current.active = nil
                current.pending = nil
                current.retiringActivityNames = []
                current.breadcrumbActivityNames = []
                current.scalarActiveActivityName = nil
                current.phase = .stoppedV1
                current.stopAcknowledgedAt = now
            } else {
                current.pending = nil
                current.retiringActivityNames = []
                current.breadcrumbActivityNames = []
                current.phase = current.active == nil ? .stoppedV1 : .activeV1
                current.stopAcknowledgedAt = current.active == nil ? now : nil
            }
            state.legacy = current
        }
    }

    @discardableResult
    static func installReplacement(
        _ next: LegacyGenerationProvenance,
        store: DeviceEpochStore,
        owner: UUID,
        startMonitoring: (String) throws -> Void,
        stopMonitoring: ([String]) -> Void,
        now: Date = Date()
    ) -> Bool {
        guard isValid(next),
              canonicalDeviceID(next.deviceID) == owner.uuidString.lowercased(),
              next.activityName.hasPrefix(generatedActivityPrefix)
        else { return false }

        recoverInterruptedTransition(
            store: store,
            owner: owner,
            stopMonitoring: stopMonitoring,
            now: now
        )
        let previous = try? store.read().legacy
        do {
            try store.transaction(expectedOwner: owner) { state in
                guard state.ratchets[owner].map({ $0.localSelection == .v1 }) ?? true else {
                    throw DeviceEpochStoreError.ownerMismatch
                }
                var legacy = state.legacy ?? LegacyCompatibilityMonitorState(
                    ownerChildDeviceID: owner,
                    lifecycleVersion: 2,
                    active: nil,
                    pending: nil,
                    retiringActivityNames: [],
                    breadcrumbActivityNames: [],
                    scalarActiveActivityName: nil,
                    isStopped: false,
                    phase: .activeV1,
                    stopAcknowledgedAt: nil
                )
                guard legacy.ownerChildDeviceID == owner else {
                    throw DeviceEpochStoreError.ownerMismatch
                }
                legacy.pending = next
                legacy.phase = .activeV1
                legacy.stopAcknowledgedAt = nil
                state.legacy = legacy
            }
            try startMonitoring(next.activityName)
        } catch {
            try? store.transaction(expectedOwner: owner) { state in
                state.legacy = previous
            }
            stopMonitoring([next.activityName])
            return false
        }

        var targets: [String] = []
        do {
            try store.transaction(expectedOwner: owner) { state in
                guard var legacy = state.legacy,
                      legacy.ownerChildDeviceID == owner,
                      legacy.pending == next
                else { throw DeviceEpochStoreError.readbackMismatch }
                targets = stopTargets(legacy).filter { $0 != next.activityName }
                legacy.active = next
                legacy.pending = nil
                legacy.retiringActivityNames = targets
                legacy.breadcrumbActivityNames = targets
                legacy.scalarActiveActivityName = next.activityName
                legacy.phase = .activeV1
                legacy.stopAcknowledgedAt = nil
                state.legacy = legacy
            }
        } catch {
            stopMonitoring([next.activityName])
            try? store.transaction(expectedOwner: owner) { state in
                state.legacy = previous
            }
            return false
        }

        if !targets.isEmpty { stopMonitoring(targets) }
        try? store.transaction(expectedOwner: owner) { state in
            guard var legacy = state.legacy,
                  legacy.ownerChildDeviceID == owner,
                  legacy.active == next
            else { return }
            legacy.retiringActivityNames = []
            legacy.breadcrumbActivityNames = []
            state.legacy = legacy
        }
        return true
    }

    @discardableResult
    static func stopPersisted(
        store: DeviceEpochStore,
        owner: UUID,
        stopMonitoring: ([String]) -> Void,
        now: Date = Date()
    ) -> Bool {
        let snapshot = try? store.read().legacy
        let targets = stopTargets(snapshot)
        do {
            try store.transaction(expectedOwner: owner) { state in
                var legacy = state.legacy ?? LegacyCompatibilityMonitorState(
                    ownerChildDeviceID: owner,
                    lifecycleVersion: 2,
                    active: nil,
                    pending: nil,
                    retiringActivityNames: [],
                    breadcrumbActivityNames: [],
                    scalarActiveActivityName: nil,
                    isStopped: false,
                    phase: .activeV1,
                    stopAcknowledgedAt: nil
                )
                guard legacy.ownerChildDeviceID == owner else {
                    throw DeviceEpochStoreError.ownerMismatch
                }
                legacy.retiringActivityNames = targets
                legacy.phase = .retiringV1
                legacy.stopAcknowledgedAt = nil
                state.legacy = legacy
            }
        } catch {
            return false
        }
        if !targets.isEmpty { stopMonitoring(targets) }
        do {
            try store.transaction(expectedOwner: owner) { state in
                guard var legacy = state.legacy,
                      legacy.ownerChildDeviceID == owner,
                      legacy.phase == .retiringV1
                else { return }
                legacy.active = nil
                legacy.pending = nil
                legacy.retiringActivityNames = []
                legacy.breadcrumbActivityNames = []
                legacy.scalarActiveActivityName = nil
                legacy.phase = .stoppedV1
                legacy.stopAcknowledgedAt = now
                state.legacy = legacy
            }
            return true
        } catch {
            return false
        }
    }

    private struct DefaultsValue {
        let key: String
        let value: Any?
    }

    private static func snapshot(defaults: UserDefaults?, keys: [String]) -> [DefaultsValue] {
        keys.map { DefaultsValue(key: $0, value: defaults?.object(forKey: $0)) }
    }

    private static func restore(
        defaults: UserDefaults?,
        prior: [DefaultsValue],
        whereCurrentMatches written: [DefaultsValue]
    ) {
        guard let defaults else { return }
        for priorValue in prior {
            let writtenValue = written.first { $0.key == priorValue.key }?.value
            guard defaultsValuesEqual(defaults.object(forKey: priorValue.key), writtenValue) else {
                continue
            }
            if let value = priorValue.value {
                defaults.set(value, forKey: priorValue.key)
            } else {
                defaults.removeObject(forKey: priorValue.key)
            }
        }
    }

    private static func defaultsValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let left?, let right?): return (left as AnyObject).isEqual(right)
        }
    }

    fileprivate static func uniqueTargets(_ names: [String?]) -> [String] {
        var result: [String] = []
        for name in names.compactMap({ $0 })
            where isEarnedActivityName(name) && !result.contains(name) {
            result.append(name)
        }
        return result
    }
}

nonisolated enum MonitorCoverageStatus: String, Codable, Sendable {
    case ready, installLimited, coverageExhausted
}

nonisolated struct MonitorCoverageState: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let requiredFromUsageDate: String
    let requiredThroughUsageDate: String
    var readyThroughUsageDate: String?
    var status: MonitorCoverageStatus
    var refreshedAt: Date
    var errorCode: String?
}

nonisolated struct EarnedShieldReference: Codable, Equatable, Sendable {
    let operationID: UUID
    let ownerChildDeviceID: UUID
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
    let recordKey: String
    let expectedRecordBytes: Data
    var retry: MeteringRetryState
    let createdAt: Date
}

extension EarnedShieldReference {
    func matches(
        operationID: UUID,
        ownerChildDeviceID: UUID,
        generationID: UUID,
        epochID: UUID,
        routeID: UUID,
        recordKey: String,
        expectedRecordBytes: Data
    ) -> Bool {
        self.operationID == operationID
            && self.ownerChildDeviceID == ownerChildDeviceID
            && self.generationID == generationID
            && self.epochID == epochID
            && self.routeID == routeID
            && self.recordKey == recordKey
            && self.expectedRecordBytes == expectedRecordBytes
    }
}

nonisolated struct IdentityCleanupWork: Codable, Equatable, Sendable {
    let workID: UUID
    let oldOwnerChildDeviceID: UUID
    var newOwnerChildDeviceID: UUID?
    let oldEpochIDs: [UUID]
    let oldRouteIDs: [UUID]
    let oldActivityNames: [String]
    let oldRegistrationWorkIDs: [UUID]
    let oldActivationWorkIDs: [UUID]
    let oldSampleWorkIDs: [UUID]
    let oldInstallWorkIDs: [UUID]
    let oldFallbackKeys: [String]
    let oldShieldOperationIDs: [UUID]
    let oldUsageDates: [String]
    var retry: MeteringRetryState
    var terminalizedWorkIDs: Set<UUID>
    var purgedFallbackKeys: Set<String>
    var releasedShieldOperationIDs: Set<UUID>
    var stopAcknowledgedActivityNames: Set<String>
    var clearedUsageDates: Set<String>
    var ownerMirrorTransitionAcknowledged: Bool
    let createdAt: Date
}

nonisolated struct RolloverEffectsWork: Codable, Equatable, Sendable {
    let workID: UUID
    let ownerChildDeviceID: UUID
    let fromUsageDate: String
    let toUsageDate: String
    let oldEpochID: UUID
    let newEpochID: UUID
    let oldRouteID: UUID
    let newRouteID: UUID
    var retry: MeteringRetryState
    var earnedSourceResetAcknowledged: Bool
    var perAppResetAcknowledged: Bool
    var taskStateResetAcknowledged: Bool
    var bypassExpiryAcknowledged: Bool
    var registrationAcknowledged: Bool
    var installAcknowledged: Bool
    var activationAcknowledged: Bool
    var oldStopAcknowledged: Bool
    let createdAt: Date
}

nonisolated enum MeteringWorkKind: String, Codable, Equatable, Sendable {
    case identityCleanup = "identity_cleanup"
    case rollover
    case registration
    case install
    case activation
    case sample
    case shield

    var priority: Int {
        switch self {
        case .identityCleanup: return 0
        case .rollover: return 1
        case .registration: return 2
        case .install: return 3
        case .activation: return 4
        case .sample: return 5
        case .shield: return 6
        }
    }
}

nonisolated struct MeteringDueWork: Equatable, Sendable {
    let workID: UUID
    let kind: MeteringWorkKind
    let nextAttemptAt: Date
    let createdAt: Date
}

nonisolated enum MeteringClaimedNetworkWork: Sendable {
    case registration(EpochRegistrationWork, MeteringNetworkClaim)
    case activation(EpochActivationWork, MeteringNetworkClaim)
    case sample(EpochSampleWork, MeteringNetworkClaim)
}

nonisolated enum MeteringLocalProtocolSelection: String, Codable, Sendable {
    case v1, v2Pending, dualActive, v2
}

nonisolated enum V2RouteHandoffPhase: String, Codable, Sendable {
    case preparing, dualV2, cutoverReady, committed
}

nonisolated struct V2RouteHandoff: Codable, Equatable, Sendable {
    let handoffID: UUID
    let ownerChildDeviceID: UUID
    let fromGenerationID: UUID
    let fromEpochID: UUID
    let fromRouteID: UUID
    let toGenerationID: UUID
    let toEpochID: UUID
    let toRouteID: UUID
    var phase: V2RouteHandoffPhase
    var priorRouteInputClosedAt: Date?
    var registrationAcknowledgedAt: Date?
    var activationAcknowledgedAt: Date?
    var priorStopAcknowledgedAt: Date?
    let createdAt: Date
    /// Same-key replacements need an explicit, auditable reason. In
    /// particular, a physical route whose one-shot event names were already
    /// delivered must recover through a fresh identity, not masquerade as a
    /// policy change or re-arm the consumed names in place.
    var explicitRecovery: MeteringExplicitRecovery? = nil
    /// Physical event names are single-use. One replacement is allowed for a
    /// handoff lineage; a second consumed candidate falls back to the prior.
    var consumedCandidateReplacementCount: Int? = nil
}

nonisolated struct MeteringOwnerRatchet: Codable, Equatable, Sendable {
    let ownerChildDeviceID: UUID
    var advertisedVersion: Int
    var localSelection: MeteringLocalProtocolSelection
    var registeredV2At: Date?
    var dualActiveAt: Date?
    var activatedV2At: Date?
}

nonisolated struct DeviceEpochStoreState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5

    var schemaVersion: Int
    var ownerChildDeviceID: UUID?
    var generations: [UUID: MeteringPolicyGeneration]
    var activeGenerationID: UUID?
    var epochs: [UUID: DeviceDailyEpoch]
    var activeEpochID: UUID?
    var routes: [UUID: MeteringCallbackRoute]
    var activeRouteID: UUID?
    var tombstones: [UUID: MeteringRouteTombstone]
    var v2RouteHandoff: V2RouteHandoff?
    var legacy: LegacyCompatibilityMonitorState?
    var registrationWork: [UUID: EpochRegistrationWork]
    var activationWork: [UUID: EpochActivationWork]
    var sampleWork: [UUID: EpochSampleWork]
    var installWork: [UUID: ActivityInstallWork]
    var shieldReferences: [UUID: EarnedShieldReference]
    var identityCleanupWork: IdentityCleanupWork?
    /// One-shot transition provenance retained after a same-owner cleanup
    /// replaces the old root. The first registration consumes it atomically.
    var pendingRegistrationRecovery: MeteringExplicitRecovery?
    var rolloverEffectsWork: RolloverEffectsWork?
    var coverage: MonitorCoverageState?
    var ratchets: [UUID: MeteringOwnerRatchet]
    var desiredPolicy: MeteringDesiredPolicy?
    var deferredCallbacks: [String: DeferredMeteringCallback]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        ownerChildDeviceID: UUID? = nil,
        generations: [UUID: MeteringPolicyGeneration] = [:],
        activeGenerationID: UUID? = nil,
        epochs: [UUID: DeviceDailyEpoch] = [:],
        activeEpochID: UUID? = nil,
        routes: [UUID: MeteringCallbackRoute] = [:],
        activeRouteID: UUID? = nil,
        tombstones: [UUID: MeteringRouteTombstone] = [:],
        v2RouteHandoff: V2RouteHandoff? = nil,
        legacy: LegacyCompatibilityMonitorState? = nil,
        registrationWork: [UUID: EpochRegistrationWork] = [:],
        activationWork: [UUID: EpochActivationWork] = [:],
        sampleWork: [UUID: EpochSampleWork] = [:],
        installWork: [UUID: ActivityInstallWork] = [:],
        shieldReferences: [UUID: EarnedShieldReference] = [:],
        identityCleanupWork: IdentityCleanupWork? = nil,
        pendingRegistrationRecovery: MeteringExplicitRecovery? = nil,
        rolloverEffectsWork: RolloverEffectsWork? = nil,
        coverage: MonitorCoverageState? = nil,
        ratchets: [UUID: MeteringOwnerRatchet] = [:],
        desiredPolicy: MeteringDesiredPolicy? = nil,
        deferredCallbacks: [String: DeferredMeteringCallback] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.ownerChildDeviceID = ownerChildDeviceID
        self.generations = generations
        self.activeGenerationID = activeGenerationID
        self.epochs = epochs
        self.activeEpochID = activeEpochID
        self.routes = routes
        self.activeRouteID = activeRouteID
        self.tombstones = tombstones
        self.v2RouteHandoff = v2RouteHandoff
        self.legacy = legacy
        self.registrationWork = registrationWork
        self.activationWork = activationWork
        self.sampleWork = sampleWork
        self.installWork = installWork
        self.shieldReferences = shieldReferences
        self.identityCleanupWork = identityCleanupWork
        self.pendingRegistrationRecovery = pendingRegistrationRecovery
        self.rolloverEffectsWork = rolloverEffectsWork
        self.coverage = coverage
        self.ratchets = ratchets
        self.desiredPolicy = desiredPolicy
        self.deferredCallbacks = deferredCallbacks
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ownerChildDeviceID, generations, activeGenerationID
        case epochs, activeEpochID, routes, activeRouteID, tombstones
        case v2RouteHandoff, legacy, registrationWork, activationWork, sampleWork
        case installWork, shieldReferences, identityCleanupWork, pendingRegistrationRecovery
        case rolloverEffectsWork
        case coverage, ratchets, desiredPolicy, deferredCallbacks
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        ownerChildDeviceID = try values.decodeIfPresent(UUID.self, forKey: .ownerChildDeviceID)
        generations = try values.decodeIfPresent([UUID: MeteringPolicyGeneration].self, forKey: .generations) ?? [:]
        activeGenerationID = try values.decodeIfPresent(UUID.self, forKey: .activeGenerationID)
        epochs = try values.decodeIfPresent([UUID: DeviceDailyEpoch].self, forKey: .epochs) ?? [:]
        activeEpochID = try values.decodeIfPresent(UUID.self, forKey: .activeEpochID)
        routes = try values.decodeIfPresent([UUID: MeteringCallbackRoute].self, forKey: .routes) ?? [:]
        activeRouteID = try values.decodeIfPresent(UUID.self, forKey: .activeRouteID)
        tombstones = try values.decodeIfPresent([UUID: MeteringRouteTombstone].self, forKey: .tombstones) ?? [:]
        v2RouteHandoff = try values.decodeIfPresent(V2RouteHandoff.self, forKey: .v2RouteHandoff)
        legacy = try values.decodeIfPresent(LegacyCompatibilityMonitorState.self, forKey: .legacy)
        registrationWork = try values.decodeIfPresent([UUID: EpochRegistrationWork].self, forKey: .registrationWork) ?? [:]
        activationWork = try values.decodeIfPresent([UUID: EpochActivationWork].self, forKey: .activationWork) ?? [:]
        sampleWork = try values.decodeIfPresent([UUID: EpochSampleWork].self, forKey: .sampleWork) ?? [:]
        installWork = try values.decodeIfPresent([UUID: ActivityInstallWork].self, forKey: .installWork) ?? [:]
        shieldReferences = try values.decodeIfPresent([UUID: EarnedShieldReference].self, forKey: .shieldReferences) ?? [:]
        identityCleanupWork = try values.decodeIfPresent(IdentityCleanupWork.self, forKey: .identityCleanupWork)
        pendingRegistrationRecovery = try values.decodeIfPresent(
            MeteringExplicitRecovery.self,
            forKey: .pendingRegistrationRecovery
        )
        rolloverEffectsWork = try values.decodeIfPresent(RolloverEffectsWork.self, forKey: .rolloverEffectsWork)
        coverage = try values.decodeIfPresent(MonitorCoverageState.self, forKey: .coverage)
        ratchets = try values.decodeIfPresent([UUID: MeteringOwnerRatchet].self, forKey: .ratchets) ?? [:]
        desiredPolicy = try values.decodeIfPresent(MeteringDesiredPolicy.self, forKey: .desiredPolicy)
        deferredCallbacks = try values.decodeIfPresent(
            [String: DeferredMeteringCallback].self,
            forKey: .deferredCallbacks
        ) ?? [:]
    }
}

extension DeviceEpochStoreState {
    // DeviceEpochStore also compiles in Push, which intentionally excludes
    // MeteringDatedSchedule.swift. This mirrors MeteringHorizonPlanner.dateCount.
    private static let currentHorizonDateCount = 8

    func hasExactSuccessfulActivation(
        owner: UUID,
        epochID: UUID,
        routeID: UUID
    ) -> Bool {
        let matches = activationWork.values.filter {
            $0.ownerChildDeviceID == owner
                && $0.epochID == epochID
                && $0.routeID == routeID
        }
        return matches.count == 1 && matches[0].retry.terminal == .succeeded
    }

    func dueWork(now: Date) -> [MeteringDueWork] {
        var work: [MeteringDueWork] = []

        func append(_ workID: UUID, kind: MeteringWorkKind, retry: MeteringRetryState, createdAt: Date) {
            guard retry.terminal == .pending, retry.nextAttemptAt <= now else { return }
            work.append(MeteringDueWork(workID: workID, kind: kind, nextAttemptAt: retry.nextAttemptAt, createdAt: createdAt))
        }

        if let identityCleanupWork {
            append(identityCleanupWork.workID, kind: .identityCleanup, retry: identityCleanupWork.retry, createdAt: identityCleanupWork.createdAt)
        }
        if let rolloverEffectsWork {
            append(rolloverEffectsWork.workID, kind: .rollover, retry: rolloverEffectsWork.retry, createdAt: rolloverEffectsWork.createdAt)
        }
        for value in registrationWork.values {
            append(value.workID, kind: .registration, retry: value.retry, createdAt: value.createdAt)
        }
        for value in installWork.values {
            switch value.phase {
            case .pendingStart, .starting, .installed:
                append(value.workID, kind: .install, retry: value.retry, createdAt: value.createdAt)
            case .verified, .dualActive, .active, .pendingStop, .stopped:
                break
            }
        }
        for value in activationWork.values {
            // The activation POST is idempotent. Its response can be lost after
            // the backend has already changed the epoch to paused, exhausted,
            // or retired, so mutable epoch status must not suppress the exact
            // request replay. Claim-time authorization still proves the owner,
            // route, epoch, registration, and install tuple.
            guard routes[value.routeID]?.lifecycle == .active else { continue }
            append(value.workID, kind: .activation, retry: value.retry, createdAt: value.createdAt)
        }
        for value in sampleWork.values {
            guard value.authorization != .waitingForRegistration else { continue }
            append(value.workID, kind: .sample, retry: value.retry, createdAt: value.createdAt)
        }
        // Shield references are deliberately NOT due work. Nothing claims them:
        // `claimFirstDispatchable` rejects `.shield`, `dueInstallWork` filters to
        // `.install`, and `settleLeadingInvalidRegistration` only looks at
        // `.registration`. Their retry state is also never terminalized — a
        // reference is written once when the cap shield is applied and then kept
        // for release bookkeeping — so every one of them stayed permanently due
        // with a past `nextAttemptAt`, sat at the head of the ordering, and
        // starved every registration/activation/sample created after it. One
        // cap hit therefore froze the device's whole metering pipeline for good
        // (iPad 2026-07-25: a reference from 02:43 blocked the 04:42 rollover
        // registration, which never reached attempt 1). Shield lifecycle is
        // driven by `EarnedShieldEffectStore`, not by this queue.
        _ = shieldReferences

        return work.sorted {
            if $0.nextAttemptAt != $1.nextAttemptAt { return $0.nextAttemptAt < $1.nextAttemptAt }
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority < $1.kind.priority }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.workID.uuidString.lowercased() < $1.workID.uuidString.lowercased()
        }
    }
}

nonisolated protocol DeviceEpochStoreLocking: Sendable {
    func withLock<T>(_ body: () -> T) -> T?
}

extension ActiveLockPersistenceLock: DeviceEpochStoreLocking {}

nonisolated protocol DeviceEpochFileIO: Sendable {
    func read(from url: URL) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
    func remove(at url: URL) throws
}

extension DeviceEpochFileIO {
    func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

nonisolated struct SystemDeviceEpochFileIO: DeviceEpochFileIO {
    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

nonisolated enum DeviceEpochStoreError: Error, Equatable {
    case appGroupContainerUnavailable
    case lockUnavailable
    case ownerMismatch
    case unsupportedSchema(Int)
    case readbackMismatch
    case restorationFailed
    case retryableConflict
    case executionBudgetExpired
}

private enum DeviceEpochStoreInvariantError: Error {
    case invalidState(String)
}

private struct LegacyActivityLifecyclePayload: Decodable {
    let version: Int
    let active: LegacyGenerationProvenance?
    let pending: LegacyGenerationProvenance?
    let retiringActivityNames: [String]
    let isStopped: Bool

    private enum CodingKeys: String, CodingKey {
        case version, active, pending, retiringActivityNames, isStopped
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...2).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: values,
                debugDescription: "unsupported legacy metering lifecycle version"
            )
        }
        active = try values.decodeIfPresent(LegacyGenerationProvenance.self, forKey: .active)
        pending = try values.decodeIfPresent(LegacyGenerationProvenance.self, forKey: .pending)
        retiringActivityNames = try values.decodeIfPresent(
            [String].self,
            forKey: .retiringActivityNames
        ) ?? []
        isStopped = try values.decodeIfPresent(Bool.self, forKey: .isStopped) ?? false
    }

    var isValid: Bool {
        let reserved = Set([active?.activityName, pending?.activityName].compactMap { $0 })
        return active.map(LegacyMeteringActivity.isValid) != false
            && pending.map(LegacyMeteringActivity.isValid) != false
            && (active == nil || pending == nil || active?.activityName != pending?.activityName)
            && retiringActivityNames.allSatisfy(LegacyMeteringActivity.isEarnedActivityName)
            && retiringActivityNames.allSatisfy { !reserved.contains($0) }
            && (!isStopped || (active == nil && pending == nil))
    }
}

nonisolated final class DeviceEpochStore: @unchecked Sendable {
    static let shared = DeviceEpochStore()
    static let fileName = "metering-device-epoch-store-v4.json"

    /// FIX-Q: how long after a route is armed a too-early rung is treated as
    /// Apple back-firing already-crossed thresholds (calibration) instead of
    /// impossible progress (cheating). Real bursts land within a second or
    /// two of arm; 90s keeps slow-daemon deliveries inside the window while
    /// staying far below the 5-minute rung spacing, so a genuine rung can
    /// never be mistaken for a burst.
    static let armGraceCalibrationSeconds: TimeInterval = 90

    private let fileURL: URL?
    private let lock: any DeviceEpochStoreLocking
    private let fileIO: any DeviceEpochFileIO
    private let ownerProvider: @Sendable () -> UUID?
    private let legacyDefaults: UserDefaults?
    private let stateDecoder: (@Sendable (Data?) throws -> DeviceEpochStoreState)?

    private static let legacyLifecycleKey = ["evlin", "earned", "activityLifecycle"]
        .joined(separator: ".")
    private static let legacyBreadcrumbsKey = ["evlin", "earned", "activityBreadcrumbs"]
        .joined(separator: ".")
    private static let legacyActiveNameKey = ["evlin", "earned", "activeActivityName"]
        .joined(separator: ".")

    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    init(
        fileURL: URL? = nil,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        fileIO: any DeviceEpochFileIO = SystemDeviceEpochFileIO(),
        ownerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: MeteringOwnerMirror.suiteName),
        stateDecoder: (@Sendable (Data?) throws -> DeviceEpochStoreState)? = nil
    ) {
        self.fileURL = fileURL
        self.lock = lock
        self.fileIO = fileIO
        self.ownerProvider = ownerProvider
        self.legacyDefaults = legacyDefaults
        self.stateDecoder = stateDecoder
    }

    func read() throws -> DeviceEpochStoreState {
        let url = try resolvedFileURL()
        let snapshot = try withLock { try fileIO.read(from: url) }
        if let snapshot {
            let state = try decodeState(snapshot)
            try validateStatic(state, expectedOwner: nil, requireOwnerMatch: false)
            try removeLegacyDefaultsAfterVerifiedRoot()
            return state
        }
        return try readOrMigrateAbsentRoot(at: url)
    }

    /// Recovery primitive: delete the persisted metering state entirely so the
    /// next `read()`/`transaction` starts from a fresh empty store (the store is
    /// file-backed with no in-memory cache, so removing the
    /// file is sufficient). Used only by the K-device nuclear reset (see
    /// `MeteringNuclearReset`) to dig out of a wedged state — paused epoch +
    /// `coverageExhausted` + churned retired epochs — that `Repair`
    /// (stale-activity cleanup) cannot clear. Callers MUST have already stopped
    /// Apple's activities so no in-flight callback transaction rewrites the file
    /// after this returns.
    func purgePersistedState() throws {
        try withLock {
            let url = try resolvedFileURL()
            try fileIO.remove(at: url)
        }
    }

    func ingestDesiredPolicy(
        _ policy: MeteringDesiredPolicy
    ) throws -> MeteringPolicyIngressDisposition {
        guard policy.orderingToken > 0,
              !policy.policyRevision.isEmpty,
              !policy.usageDate.isEmpty,
              !policy.canonicalTimezone.isEmpty,
              policy.dailyPoolMinutes > 0,
              policy.deviceCapMinutes > 0,
              policy.appliedAt == nil,
              policy.ackedAt == nil,
              policy.ownerChildDeviceID == ownerProvider()
        else { throw DeviceEpochStoreError.ownerMismatch }

        return try transaction(expectedOwner: policy.ownerChildDeviceID) { state in
            guard let current = state.desiredPolicy else {
                state.desiredPolicy = policy
                return .acceptedNeedsOwner
            }
            if policy.orderingToken < current.orderingToken {
                return .superseded(latestOrderingToken: current.orderingToken)
            }
            if policy.orderingToken > current.orderingToken {
                state.desiredPolicy = policy
                return .acceptedNeedsOwner
            }
            guard Self.sameDesiredPolicyAuthority(current, policy) else {
                return .equalTokenConflict
            }
            return current.appliedAt == nil ? .duplicatePending : .duplicateApplied
        }
    }

    func markDesiredPolicyApplied(
        commandID: UUID,
        orderingToken: Int64,
        policyRevision: String,
        appliedAt: Date
    ) throws {
        let owner = ownerProvider()
        try transaction(expectedOwner: owner) { state in
            guard var current = state.desiredPolicy,
                  current.commandID == commandID,
                  current.orderingToken == orderingToken,
                  current.policyRevision == policyRevision,
                  current.ownerChildDeviceID == owner
            else { throw DeviceEpochStoreError.readbackMismatch }
            if let existing = current.appliedAt {
                guard existing == appliedAt else { throw DeviceEpochStoreError.readbackMismatch }
                return
            }
            current.appliedAt = appliedAt
            state.desiredPolicy = current
        }
    }

    func markDesiredPolicyAcknowledged(
        commandID: UUID,
        orderingToken: Int64,
        policyRevision: String,
        ackedAt: Date
    ) throws {
        let owner = ownerProvider()
        try transaction(expectedOwner: owner) { state in
            guard var current = state.desiredPolicy,
                  current.commandID == commandID,
                  current.orderingToken == orderingToken,
                  current.policyRevision == policyRevision,
                  current.ownerChildDeviceID == owner,
                  current.appliedAt != nil
            else { throw DeviceEpochStoreError.readbackMismatch }
            if let existing = current.ackedAt {
                guard existing == ackedAt else { throw DeviceEpochStoreError.readbackMismatch }
                return
            }
            current.ackedAt = ackedAt
            state.desiredPolicy = current
        }
    }

    private static func sameDesiredPolicyAuthority(
        _ lhs: MeteringDesiredPolicy,
        _ rhs: MeteringDesiredPolicy
    ) -> Bool {
        lhs.commandID == rhs.commandID
            && lhs.ownerChildDeviceID == rhs.ownerChildDeviceID
            && lhs.orderingToken == rhs.orderingToken
            && lhs.policyRevision == rhs.policyRevision
            && lhs.usageDate == rhs.usageDate
            && lhs.canonicalTimezone == rhs.canonicalTimezone
            && lhs.dailyPoolMinutes == rhs.dailyPoolMinutes
            && lhs.deviceCapMinutes == rhs.deviceCapMinutes
            && lhs.remainingMinutes == rhs.remainingMinutes
            && lhs.enforcementSetID == rhs.enforcementSetID
            && lhs.receivedAt == rhs.receivedAt
    }

    func isCurrentOwner(_ owner: UUID) -> Bool {
        ownerProvider() == owner
    }

    /// Claims a genuinely empty root after the external owner mirror has
    /// already been durably moved to `owner`. Existing roots and cleanup work
    /// must use the identity-cleanup state machine instead.
    @discardableResult
    func claimInitialOwner(_ owner: UUID) throws -> Bool {
        try transaction(
            expectedOwner: owner,
            bootstrapOwnerIfMissing: false
        ) { state in
            if state.ownerChildDeviceID == owner {
                return false
            }
            guard state.ownerChildDeviceID == nil,
                  state.identityCleanupWork == nil
            else { throw DeviceEpochStoreError.ownerMismatch }
            state.ownerChildDeviceID = owner
            return true
        }
    }

    /// Durably closes every callback/work authority owned by `oldOwner` before
    /// any external identity mirror is allowed to change. Replaying the same
    /// transition returns the original work ID without rewriting bytes.
    @discardableResult
    func prepareIdentityCleanup(
        oldOwner: UUID,
        newOwner: UUID?,
        oldFallbackKeys: [String],
        now: Date
    ) throws -> UUID {
        try transaction(expectedOwner: oldOwner) { state in
            if let existing = state.identityCleanupWork {
                guard existing.oldOwnerChildDeviceID == oldOwner,
                      existing.newOwnerChildDeviceID == newOwner,
                      existing.oldFallbackKeys == Array(Set(oldFallbackKeys)).sorted()
                else { throw DeviceEpochStoreError.ownerMismatch }
                return existing.workID
            }

            let oldGenerations = state.generations.values.filter { $0.childDeviceID == oldOwner }
            let oldEpochs = state.epochs.values.filter { $0.childDeviceID == oldOwner }
            let oldRoutes = state.routes.values.filter { $0.ownerChildDeviceID == oldOwner }
            let oldRouteIDs = Set(oldRoutes.map(\.routeID))
            let oldEpochIDs = Set(oldEpochs.map(\.epochID))
            let registrationIDs = state.registrationWork.values
                .filter { $0.ownerChildDeviceID == oldOwner }.map(\.workID)
            let activationIDs = state.activationWork.values
                .filter { $0.ownerChildDeviceID == oldOwner }.map(\.workID)
            let sampleIDs = state.sampleWork.values
                .filter { $0.ownerChildDeviceID == oldOwner }.map(\.workID)
            let installIDs = state.installWork.values
                .filter { $0.ownerChildDeviceID == oldOwner }.map(\.workID)
            let shieldIDs = state.shieldReferences.values
                .filter { $0.ownerChildDeviceID == oldOwner }.map(\.operationID)
            var activityNames = Set(oldRoutes.map(\.activityName))
            if let legacy = state.legacy, legacy.ownerChildDeviceID == oldOwner {
                [legacy.active?.activityName, legacy.pending?.activityName, legacy.scalarActiveActivityName]
                    .compactMap { $0 }.forEach { activityNames.insert($0) }
                legacy.retiringActivityNames.forEach { activityNames.insert($0) }
                legacy.breadcrumbActivityNames.forEach { activityNames.insert($0) }
            }

            let workID = UUID()
            state.identityCleanupWork = IdentityCleanupWork(
                workID: workID,
                oldOwnerChildDeviceID: oldOwner,
                newOwnerChildDeviceID: newOwner,
                oldEpochIDs: oldEpochIDs.sorted(by: Self.uuidLess),
                oldRouteIDs: oldRouteIDs.sorted(by: Self.uuidLess),
                oldActivityNames: activityNames.sorted(),
                oldRegistrationWorkIDs: registrationIDs.sorted(by: Self.uuidLess),
                oldActivationWorkIDs: activationIDs.sorted(by: Self.uuidLess),
                oldSampleWorkIDs: sampleIDs.sorted(by: Self.uuidLess),
                oldInstallWorkIDs: installIDs.sorted(by: Self.uuidLess),
                oldFallbackKeys: Array(Set(oldFallbackKeys)).sorted(),
                oldShieldOperationIDs: shieldIDs.sorted(by: Self.uuidLess),
                oldUsageDates: Array(Set(oldEpochs.map(\.usageDate))).sorted(),
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                terminalizedWorkIDs: [],
                purgedFallbackKeys: [],
                releasedShieldOperationIDs: [],
                stopAcknowledgedActivityNames: [],
                clearedUsageDates: [],
                ownerMirrorTransitionAcknowledged: false,
                createdAt: now
            )

            for generation in oldGenerations {
                state.generations[generation.generationID]?.retiredAt = now
            }
            for epoch in oldEpochs {
                state.epochs[epoch.epochID]?.status = .retired
                state.epochs[epoch.epochID]?.retiredAt = now
                state.epochs[epoch.epochID]?.retireReason = .identityRecovery
            }
            for route in oldRoutes {
                guard let epoch = state.epochs[route.epochID],
                      let dayEnd = state.canonicalDayEnd(
                        usageDate: route.usageDate,
                        timeZoneIdentifier: epoch.canonicalTimezone
                      )
                else { throw DeviceEpochStoreError.readbackMismatch }
                state.routes[route.routeID]?.lifecycle = .tombstoned
                if state.tombstones[route.routeID] == nil {
                    state.tombstones[route.routeID] = MeteringRouteTombstone(
                        routeID: route.routeID,
                        activityName: route.activityName,
                        eventNames: route.plannedEvents.map(\.eventName),
                        ownerChildDeviceID: oldOwner,
                        usageDate: route.usageDate,
                        epochID: route.epochID,
                        generationID: route.generationID,
                        canonicalDayEnd: dayEnd,
                        stopAcknowledgedAt: nil,
                        referencedWorkIDs: Set(sampleIDs.filter {
                            state.sampleWork[$0]?.routeID == route.routeID
                        }),
                        retainedUntil: nil
                    )
                }
            }
            if state.activeGenerationID.map({ Set(oldGenerations.map(\.generationID)).contains($0) }) == true {
                state.activeGenerationID = nil
            }
            if state.activeEpochID.map({ oldEpochIDs.contains($0) }) == true {
                state.activeEpochID = nil
            }
            if state.activeRouteID.map({ oldRouteIDs.contains($0) }) == true {
                state.activeRouteID = nil
            }
            if state.v2RouteHandoff?.ownerChildDeviceID == oldOwner {
                state.v2RouteHandoff = nil
            }
            if state.coverage?.ownerChildDeviceID == oldOwner {
                state.coverage = nil
            }
            return workID
        }
    }

    /// Adopts the already-reserved route for the next canonical usage date.
    /// Preparation is one atomic, idempotent write and deliberately leaves the
    /// old route active until recovery has verified every new-day effect.
    @discardableResult
    func prepareCanonicalRollover(
        owner: UUID,
        toUsageDate: String,
        now: Date
    ) throws -> UUID {
        // Every `throw` below used to be swallowed by the caller
        // (`BigKidStatePoller` only `print`ed it), so a device that could not
        // roll over silently stayed on the previous day FOREVER while the
        // poller retried every 10 s. The rollover verdict is now recorded on
        // both paths, with the full invariant message.
        var fromUsageDate = ""
        do {
            let workID = try transaction(expectedOwner: owner) { state in
            guard let oldRouteID = state.activeRouteID,
                  let oldRoute = state.routes[oldRouteID],
                  oldRoute.ownerChildDeviceID == owner,
                  oldRoute.lifecycle == .active,
                  let oldEpoch = state.epochs[oldRoute.epochID],
                  oldEpoch.childDeviceID == owner
            else {
                throw DeviceEpochStoreInvariantError.invalidState(
                    "rollover has no active old route"
                )
            }
            fromUsageDate = oldRoute.usageDate

            if let existing = state.rolloverEffectsWork,
               existing.retry.terminal == .pending {
                guard existing.ownerChildDeviceID == owner,
                      existing.fromUsageDate == oldRoute.usageDate,
                      existing.toUsageDate == toUsageDate,
                      existing.oldEpochID == oldEpoch.epochID,
                      existing.oldRouteID == oldRoute.routeID,
                      let existingNewRoute = state.routes[existing.newRouteID],
                      existingNewRoute.epochID == existing.newEpochID,
                      existingNewRoute.usageDate == existing.toUsageDate,
                      existingNewRoute.lifecycle == .planned || existingNewRoute.lifecycle == .active,
                      let existingNewEpoch = state.epochs[existing.newEpochID],
                      existingNewEpoch.usageDate == existing.toUsageDate
                else {
                    throw DeviceEpochStoreInvariantError.invalidState(
                        "a different rollover is already pending"
                    )
                }
                return existing.workID
            }

            let nextUsageDate = state.routes.values
                .filter { route in
                    route.ownerChildDeviceID == owner
                        && route.generationID == oldRoute.generationID
                        && route.usageDate > oldRoute.usageDate
                        && route.lifecycle == .planned
                }
                .map(\.usageDate)
                .min()
            guard let nextUsageDate,
                  nextUsageDate == toUsageDate,
                  let newRoute = state.routes.values.first(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.generationID == oldRoute.generationID
                          && $0.usageDate == toUsageDate
                          && $0.lifecycle == .planned
                  }),
                  let newEpoch = state.epochs[newRoute.epochID],
                  newEpoch.childDeviceID == owner,
                  newEpoch.usageDate == toUsageDate
            else {
                throw DeviceEpochStoreInvariantError.invalidState(
                    "rollover does not target the next reserved canonical route"
                )
            }

            let matchingInstallKeys = state.installWork.compactMap { key, work in
                work.routeID == newRoute.routeID ? key : nil
            }
            guard matchingInstallKeys.count == 1,
                  let newInstallKey = matchingInstallKeys.first,
                  var newInstall = state.installWork[newInstallKey]
            else {
                throw DeviceEpochStoreInvariantError.invalidState(
                    "rollover route does not have one install work item"
                )
            }
            if newInstall.retry.terminal == .superseded,
               newInstall.retry.lastErrorCode == "route_superseded",
               newInstall.authorization == .futurePlanned,
               newInstall.phase == .pendingStart,
               newInstall.claim == nil,
               state.hasCurrentRegistrationProvenance(
                   owner: owner,
                   epochID: newRoute.epochID,
                   routeID: newRoute.routeID
               ) {
                newInstall.retry = MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: nil,
                    terminal: .pending
                )
                state.installWork[newInstallKey] = newInstall
            }

            if let existing = state.rolloverEffectsWork {
                // A finished rollover is HISTORY: the only thing that matters is
                // that it belongs to this owner and is no longer running. It must
                // NOT be required to still own the active route.
                //
                // The previous version demanded `existing.newRouteID ==
                // oldRoute.routeID` (plus a matching committed handoff), i.e.
                // "yesterday's rollover product is still the live route". Any
                // policy change, per-app limit edit, reset or generation churn
                // replaces the active route — so from the first such change
                // onward this guard could never pass again and EVERY following
                // midnight threw "completed rollover cannot advance to the next
                // day". The device then stayed on the old (already exhausted)
                // day forever, silently: the poller retries every 10s and
                // `BigKidStatePoller` only prints the error. That is the
                // year-long "bar frozen after I changed something" pattern
                // (proven on iPad 2026-07-25: rollover product 2177C592 vs live
                // route 1CE7CC31 → stuck at 07-24 with 07-25 ready server-side).
                guard existing.ownerChildDeviceID == owner,
                      existing.retry.terminal != .pending
                else {
                    throw DeviceEpochStoreInvariantError.invalidState(
                        "a foreign or in-flight rollover blocks the next day"
                    )
                }
                // Drop the finished handoff only if it belongs to that rollover;
                // an unrelated live handoff must survive.
                if let handoff = state.v2RouteHandoff, handoff.handoffID == existing.workID {
                    state.v2RouteHandoff = nil
                }
            }

            let workID = UUID()
            state.rolloverEffectsWork = RolloverEffectsWork(
                workID: workID,
                ownerChildDeviceID: owner,
                fromUsageDate: oldRoute.usageDate,
                toUsageDate: toUsageDate,
                oldEpochID: oldEpoch.epochID,
                newEpochID: newEpoch.epochID,
                oldRouteID: oldRoute.routeID,
                newRouteID: newRoute.routeID,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                earnedSourceResetAcknowledged: false,
                perAppResetAcknowledged: false,
                taskStateResetAcknowledged: false,
                bypassExpiryAcknowledged: false,
                registrationAcknowledged: false,
                installAcknowledged: false,
                activationAcknowledged: false,
                oldStopAcknowledged: false,
                createdAt: now
            )
            return workID
            }
            MeteringFlightRecorder.emit(
                kind: .meteringDay,
                site: "store.rollover",
                verdict: "prepared",
                detail: MeteringFlightRecorder.detail([
                    ("from", fromUsageDate),
                    ("to", toUsageDate),
                    ("work", MeteringFlightRecorder.shortID(workID)),
                ]),
                transition: ScreenTimeEvent.Transition(
                    before: fromUsageDate,
                    after: toUsageDate
                )
            )
            return workID
        } catch {
            MeteringFlightRecorder.emit(
                kind: .meteringDay,
                site: "store.rollover",
                verdict: "prepare_failed",
                detail: MeteringFlightRecorder.detail([
                    ("from", fromUsageDate),
                    ("to", toUsageDate),
                    ("err", MeteringFlightRecorder.describe(error)),
                ]),
                transition: ScreenTimeEvent.Transition(
                    before: fromUsageDate,
                    after: toUsageDate
                )
            )
            throw error
        }
    }

    /// Preflight only. The effect store calls this before it durably records a
    /// prepared envelope so failed authorization cannot leave orphaned effect
    /// state behind.
    func canPrepareEarnedShieldReference(_ reference: EarnedShieldReference) throws -> Bool {
        guard isCurrentOwner(reference.ownerChildDeviceID) else { return false }
        let state = try read()
        return canApplyEarnedShieldReference(reference, in: state)
    }

    /// Atomically creates one exact operation reference, or verifies the
    /// existing operation is byte-for-byte the same. This is intentionally the
    /// only DeviceEpochStore mutation Task 14 needs for shield effects.
    func createOrVerifyEarnedShieldReference(_ reference: EarnedShieldReference) throws -> Bool {
        try transaction(expectedOwner: reference.ownerChildDeviceID) { state in
            if let existing = state.shieldReferences[reference.operationID] {
                return existing.matches(
                    operationID: reference.operationID,
                    ownerChildDeviceID: reference.ownerChildDeviceID,
                    generationID: reference.generationID,
                    epochID: reference.epochID,
                    routeID: reference.routeID,
                    recordKey: reference.recordKey,
                    expectedRecordBytes: reference.expectedRecordBytes
                )
            }
            guard canApplyEarnedShieldReference(reference, in: state) else { return false }
            state.shieldReferences[reference.operationID] = reference
            return true
        }
    }

    func hasExactEarnedShieldReference(_ expected: EarnedShieldReference) throws -> Bool {
        guard isCurrentOwner(expected.ownerChildDeviceID) else { return false }
        guard let reference = try read().shieldReferences[expected.operationID] else {
            return false
        }
        return reference.matches(
            operationID: expected.operationID,
            ownerChildDeviceID: expected.ownerChildDeviceID,
            generationID: expected.generationID,
            epochID: expected.epochID,
            routeID: expected.routeID,
            recordKey: expected.recordKey,
            expectedRecordBytes: expected.expectedRecordBytes
        )
    }

    /// Repairs roots written by the same-generation authoritative-base bug.
    ///
    /// The rejected candidate and the active prior route shared a generation,
    /// but terminalizing the candidate retired that shared generation. The
    /// corrected route was then rejected by the provenance firewall and left
    /// the handoff permanently preparing. This migration recognizes only that
    /// complete persisted shape and retries the existing corrected identity.
    @discardableResult
    func recoverLegacyRetiredPriorAuthoritativeCorrection(
        owner: UUID,
        now: Date
    ) throws -> Bool {
        guard isCurrentOwner(owner) else { return false }
        return try transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.ownerChildDeviceID == owner,
                  handoff.phase == .preparing,
                  state.activeGenerationID == handoff.fromGenerationID,
                  state.activeEpochID == handoff.fromEpochID,
                  state.activeRouteID == handoff.fromRouteID,
                  var priorGeneration = state.generations[handoff.fromGenerationID],
                  priorGeneration.childDeviceID == owner,
                  priorGeneration.retiredAt != nil,
                  let priorEpoch = state.epochs[handoff.fromEpochID],
                  priorEpoch.childDeviceID == owner,
                  priorEpoch.status == .active,
                  priorEpoch.retiredAt == nil,
                  let priorRoute = state.routes[handoff.fromRouteID],
                  priorRoute.ownerChildDeviceID == owner,
                  priorRoute.generationID == handoff.fromGenerationID,
                  priorRoute.epochID == handoff.fromEpochID,
                  priorRoute.lifecycle == .active,
                  let correctedGeneration = state.generations[handoff.toGenerationID],
                  correctedGeneration.childDeviceID == owner,
                  correctedGeneration.retiredAt == nil,
                  let correctedEpoch = state.epochs[handoff.toEpochID],
                  correctedEpoch.childDeviceID == owner,
                  correctedEpoch.status == .active,
                  correctedEpoch.retiredAt == nil,
                  correctedEpoch.baseSource == .registrationConflict409,
                  correctedEpoch.baseCorrectionState == .used,
                  let correctedRoute = state.routes[handoff.toRouteID],
                  correctedRoute.ownerChildDeviceID == owner,
                  correctedRoute.generationID == handoff.toGenerationID,
                  correctedRoute.epochID == handoff.toEpochID,
                  correctedRoute.lifecycle == .planned,
                  priorRoute.generationKey == correctedRoute.generationKey
            else { return false }

            let rejectedIntermediaries = state.routes.values.filter { route in
                guard route.ownerChildDeviceID == owner,
                      route.routeID != priorRoute.routeID,
                      route.routeID != correctedRoute.routeID,
                      route.generationID == handoff.fromGenerationID,
                      route.usageDate == priorRoute.usageDate,
                      route.generationKey == priorRoute.generationKey,
                      route.lifecycle == .tombstoned,
                      let epoch = state.epochs[route.epochID]
                else { return false }
                return epoch.status == .retired
                    && epoch.retireReason == .authoritativeBaseMismatch
                    && epoch.baseCorrectionState == .used
                    && epoch.authoritativeBaseConflict != nil
                    && state.tombstones[route.routeID] != nil
            }
            guard rejectedIntermediaries.count == 1 else { return false }

            let installKeys = state.installWork.compactMap { key, work -> UUID? in
                guard work.ownerChildDeviceID == owner,
                      work.routeID == correctedRoute.routeID,
                      work.authorization == .offlinePending,
                      work.phase == .pendingStart,
                      work.claim == nil,
                      work.retry.terminal == .superseded,
                      work.retry.lastErrorCode == "route_superseded"
                else { return nil }
                return key
            }
            let registrationKeys = state.registrationWork.compactMap {
                key, work -> UUID? in
                guard work.ownerChildDeviceID == owner,
                      work.epochID == correctedEpoch.epochID,
                      work.routeID == correctedRoute.routeID,
                      work.claim == nil,
                      work.retry.terminal == .superseded,
                      work.retry.lastErrorCode == "route_superseded"
                else { return nil }
                return key
            }
            guard installKeys.count == 1,
                  registrationKeys.count == 1,
                  !state.activationWork.values.contains(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.routeID == correctedRoute.routeID
                          && $0.retry.terminal == .succeeded
                  })
            else { return false }

            priorGeneration.retiredAt = nil
            state.generations[priorGeneration.generationID] = priorGeneration

            let installKey = installKeys[0]
            let priorInstallRetry = state.installWork[installKey]?.retry
            state.installWork[installKey]?.retry = MeteringRetryState(
                attemptCount: priorInstallRetry?.attemptCount ?? 0,
                nextAttemptAt: now,
                lastErrorCode: nil,
                terminal: .pending
            )

            let registrationKey = registrationKeys[0]
            let priorRegistrationRetry = state.registrationWork[registrationKey]?.retry
            state.registrationWork[registrationKey]?.retry = MeteringRetryState(
                attemptCount: priorRegistrationRetry?.attemptCount ?? 0,
                nextAttemptAt: now,
                lastErrorCode: nil,
                terminal: .pending
            )
            return true
        }
    }

    /// Repairs a base-correction handoff written before corrections declared
    /// identity recovery explicitly.
    ///
    /// Those roots already installed the corrected route and closed the prior
    /// route's input, but registered the unchanged immutable epoch key as a
    /// policy change. The backend correctly rejected that declaration and the
    /// device stayed at cutoverReady forever. Only rewrite the existing work
    /// when the complete historical shape matches; never mint another route.
    @discardableResult
    func recoverLegacySameKeyCorrectionReasonMismatch(
        owner: UUID,
        now: Date
    ) throws -> Bool {
        guard isCurrentOwner(owner) else { return false }
        return try transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff,
                  handoff.ownerChildDeviceID == owner,
                  handoff.phase == .cutoverReady,
                  handoff.explicitRecovery == nil,
                  state.activeGenerationID == handoff.fromGenerationID,
                  state.activeEpochID == handoff.fromEpochID,
                  state.activeRouteID == handoff.fromRouteID,
                  let priorGeneration = state.generations[handoff.fromGenerationID],
                  priorGeneration.childDeviceID == owner,
                  priorGeneration.retiredAt == nil,
                  let priorEpoch = state.epochs[handoff.fromEpochID],
                  priorEpoch.childDeviceID == owner,
                  priorEpoch.status == .active,
                  priorEpoch.retiredAt == nil,
                  let priorRoute = state.routes[handoff.fromRouteID],
                  priorRoute.ownerChildDeviceID == owner,
                  priorRoute.generationID == handoff.fromGenerationID,
                  priorRoute.epochID == handoff.fromEpochID,
                  priorRoute.lifecycle == .active,
                  let correctedGeneration = state.generations[handoff.toGenerationID],
                  correctedGeneration.childDeviceID == owner,
                  correctedGeneration.retiredAt == nil,
                  let correctedEpoch = state.epochs[handoff.toEpochID],
                  correctedEpoch.childDeviceID == owner,
                  correctedEpoch.status == .active,
                  correctedEpoch.retiredAt == nil,
                  correctedEpoch.baseSource == .registrationConflict409,
                  correctedEpoch.baseCorrectionState == .used,
                  let correctedRoute = state.routes[handoff.toRouteID],
                  correctedRoute.ownerChildDeviceID == owner,
                  correctedRoute.generationID == handoff.toGenerationID,
                  correctedRoute.epochID == handoff.toEpochID,
                  correctedRoute.lifecycle == .active,
                  priorRoute.usageDate == correctedRoute.usageDate,
                  priorRoute.generationKey == correctedRoute.generationKey,
                  let priorInstall = state.installWork.values.first(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.routeID == priorRoute.routeID
                  }),
                  priorInstall.phase == .active
            else { return false }

            let correctedInstallKeys = state.installWork.compactMap {
                key, work -> UUID? in
                guard work.ownerChildDeviceID == owner,
                      work.routeID == correctedRoute.routeID,
                      work.authorization == .offlinePending,
                      work.phase == .dualActive,
                      work.claim == nil
                else { return nil }
                return key
            }
            let registrationKeys = state.registrationWork.compactMap {
                key, work -> UUID? in
                guard work.ownerChildDeviceID == owner,
                      work.epochID == correctedEpoch.epochID,
                      work.routeID == correctedRoute.routeID,
                      work.request.reason == .policyChange,
                      work.claim == nil,
                      work.retry.terminal == .rejected,
                      work.retry.lastErrorCode == "replacement_reason_mismatch"
                else { return nil }
                return key
            }
            guard correctedInstallKeys.count == 1,
                  registrationKeys.count == 1,
                  !state.activationWork.values.contains(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.epochID == correctedEpoch.epochID
                          && $0.routeID == correctedRoute.routeID
                          && $0.retry.terminal == .succeeded
                  })
            else { return false }

            let registrationKey = registrationKeys[0]
            guard let registration = state.registrationWork[registrationKey] else {
                return false
            }
            let request = registration.request
            let correctedRequest = EpochRegistrationRequestDTO(
                protocolVersion: request.protocolVersion,
                epochID: request.epochID,
                deviceID: request.deviceID,
                usageDate: request.usageDate,
                timezone: request.timezone,
                policyRevision: request.policyRevision,
                measurementSelectionDigest: request.measurementSelectionDigest,
                enforcementSetID: request.enforcementSetID,
                startedAt: request.startedAt,
                baseAcceptedMinutes: request.baseAcceptedMinutes,
                reason: .identityRecovery
            )
            state.registrationWork[registrationKey] = EpochRegistrationWork(
                workID: registration.workID,
                ownerChildDeviceID: registration.ownerChildDeviceID,
                epochID: registration.epochID,
                routeID: registration.routeID,
                request: correctedRequest,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: registration.createdAt
            )
            handoff.explicitRecovery = .identityRecovery
            state.v2RouteHandoff = handoff
            return true
        }
    }

    /// Release is never a generic source removal. The operation must still be
    /// referenced by this owner and the originating epoch must have entered one
    /// of the narrow terminal paths that is allowed to unwind earned shielding.
    func canReleaseEarnedShieldReference(_ expected: EarnedShieldReference) throws -> Bool {
        let snapshot = try read()
        if let cleanup = snapshot.identityCleanupWork,
           cleanup.oldOwnerChildDeviceID == expected.ownerChildDeviceID,
           cleanup.oldShieldOperationIDs.contains(expected.operationID) {
            return try identityCleanupTransaction(workID: cleanup.workID) { state, _ in
                canReleaseEarnedShieldReference(expected, in: state)
            }
        }
        return try transaction(expectedOwner: expected.ownerChildDeviceID) { state in
            canReleaseEarnedShieldReference(expected, in: state)
        }
    }

    private func canReleaseEarnedShieldReference(
        _ expected: EarnedShieldReference,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard let reference = state.shieldReferences[expected.operationID],
                  reference.matches(
                    operationID: expected.operationID,
                    ownerChildDeviceID: expected.ownerChildDeviceID,
                    generationID: expected.generationID,
                    epochID: expected.epochID,
                    routeID: expected.routeID,
                    recordKey: expected.recordKey,
                    expectedRecordBytes: expected.expectedRecordBytes
                  ),
                  reference.ownerChildDeviceID == expected.ownerChildDeviceID,
                  let epoch = state.epochs[reference.epochID],
                  let route = state.routes[reference.routeID],
                  epoch.childDeviceID == expected.ownerChildDeviceID,
                  route.ownerChildDeviceID == expected.ownerChildDeviceID,
                  route.generationID == reference.generationID,
                  route.epochID == reference.epochID
        else { return false }

            let correctionOrRetirement = epoch.status == .retired
                || epoch.retiredAt != nil
                || epoch.authoritativeBaseConflict != nil
                || route.lifecycle == .retired
                || route.lifecycle == .tombstoned
            let rollover = state.rolloverEffectsWork.map {
                $0.ownerChildDeviceID == expected.ownerChildDeviceID
                    && $0.oldEpochID == reference.epochID
                    && $0.oldRouteID == reference.routeID
            } ?? false
            let identityCleanup = state.identityCleanupWork.map {
                $0.oldOwnerChildDeviceID == expected.ownerChildDeviceID
                    && $0.oldShieldOperationIDs.contains(expected.operationID)
            } ?? false
            let coverageExpired = state.coverage.map {
                $0.ownerChildDeviceID == expected.ownerChildDeviceID
                    && $0.status == .coverageExhausted
                    && route.usageDate < $0.requiredFromUsageDate
            } ?? false
        return correctionOrRetirement || rollover || identityCleanup || coverageExpired
    }

    private func canApplyEarnedShieldReference(
        _ reference: EarnedShieldReference,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard state.ownerChildDeviceID == reference.ownerChildDeviceID,
              state.activeGenerationID == reference.generationID,
              state.activeEpochID == reference.epochID,
              state.activeRouteID == reference.routeID,
              let generation = state.generations[reference.generationID],
              generation.childDeviceID == reference.ownerChildDeviceID,
              generation.retiredAt == nil,
              let epoch = state.epochs[reference.epochID],
              epoch.childDeviceID == reference.ownerChildDeviceID,
              epoch.status == .active,
              epoch.retiredAt == nil,
              epoch.exhaustedAt == nil,
              let route = state.routes[reference.routeID],
              route.ownerChildDeviceID == reference.ownerChildDeviceID,
              route.generationID == reference.generationID,
              route.epochID == reference.epochID,
              route.lifecycle == .active,
              !reference.recordKey.isEmpty,
              !reference.expectedRecordBytes.isEmpty
        else { return false }
        return true
    }

    /// Read-only terminal preflight. This only recognizes the immutable final
    /// event in a route; callback authority is still revalidated under the
    /// store transaction before any sample or shield receipt is committed.
    func terminalShieldCandidate(
        _ input: MeteringAuthorizedCallbackInput,
        owner: UUID
    ) throws -> MeteringTerminalShieldCandidate? {
        guard isCurrentOwner(owner) else { return nil }
        let state = try read()
        guard state.ownerChildDeviceID == owner,
              let route = state.routes[input.routeID],
              let generation = state.generations[route.generationID],
              let epoch = state.epochs[route.epochID],
              route.ownerChildDeviceID == owner,
              route.activityName == input.activityName,
              route.namespace == input.namespace,
              route.epochID == epoch.epochID,
              route.generationID == generation.generationID,
              let terminal = route.plannedEvents.max(by: {
                  $0.thresholdMinutes < $1.thresholdMinutes
              }),
              terminal.eventName == input.eventName,
              terminal.thresholdMinutes == input.thresholdMinutes
        else { return nil }
        return MeteringTerminalShieldCandidate(
            operationID: route.routeID,
            ownerChildDeviceID: owner,
            generationID: generation.generationID,
            epochID: epoch.epochID,
            routeID: route.routeID,
            usageDate: epoch.usageDate,
            enforcementSetID: epoch.enforcementSetID,
            thresholdMinutes: terminal.thresholdMinutes,
            observedAt: input.observedAt
        )
    }

    /// Keeps one diagnostic row for each repeated terminal registration result.
    /// Pending and successful work are never compacted because they still carry
    /// protocol state; this only removes semantically equivalent historical
    /// failures with the same immutable request and retry verdict.
    @discardableResult
    func compactTerminalRegistrationHistory(owner: UUID) throws -> Int {
        guard isCurrentOwner(owner) else { return 0 }
        return try transaction(expectedOwner: owner) { state in
            // Identity cleanup names exact historical work IDs and must finish
            // before those rows can be compacted. Rollover and handoff refer to
            // routes/epochs instead; retaining the newest row per terminal
            // result preserves every decision they inspect.
            guard state.identityCleanupWork == nil else { return 0 }

            var newestByKey: [TerminalRegistrationHistoryKey: EpochRegistrationWork] = [:]
            var compactableIDs: Set<UUID> = []
            for work in state.registrationWork.values
            where work.ownerChildDeviceID == owner
                && work.claim == nil
                && work.retry.terminal != .pending
                && work.retry.terminal != .succeeded {
                let key = TerminalRegistrationHistoryKey(
                    ownerChildDeviceID: work.ownerChildDeviceID,
                    epochID: work.epochID,
                    routeID: work.routeID,
                    requestBytes: try Self.encoder.encode(work.request),
                    terminal: work.retry.terminal.rawValue,
                    errorCode: work.retry.lastErrorCode,
                    attemptCount: work.retry.attemptCount
                )
                compactableIDs.insert(work.workID)
                if let current = newestByKey[key] {
                    if work.createdAt > current.createdAt
                        || (work.createdAt == current.createdAt
                            && work.workID.uuidString < current.workID.uuidString) {
                        newestByKey[key] = work
                    }
                } else {
                    newestByKey[key] = work
                }
            }

            let retainedIDs = Set(newestByKey.values.map(\.workID))
            let removableIDs = compactableIDs.subtracting(retainedIDs)
            for workID in removableIDs {
                state.registrationWork[workID] = nil
            }
            return removableIDs.count
        }
    }

    /// Bounds the control-plane root after the daemon has confirmed that a
    /// retired generation no longer owns any physical activity.
    ///
    /// Physical stop must happen first. A crash between stop and this
    /// transaction is harmless because the next recovery observes the same
    /// absent names and retries collection. References that can still drive an
    /// effect keep their generation intact.
    @discardableResult
    func compactPhysicallyAbsentRetiredHistory(
        owner: UUID,
        physicallyInstalledActivityNames: Set<String>,
        now: Date = Date()
    ) throws -> Int {
        guard isCurrentOwner(owner) else { return 0 }
        return try transaction(expectedOwner: owner) { state in
            guard state.identityCleanupWork == nil else { return 0 }

            var protectedGenerationIDs: Set<UUID> = []
            var protectedEpochIDs: Set<UUID> = []
            var protectedRouteIDs: Set<UUID> = []
            var sampleCompactionBlockedRouteIDs: Set<UUID> = []
            if let handoff = state.v2RouteHandoff {
                protectedGenerationIDs.formUnion([
                    handoff.fromGenerationID,
                    handoff.toGenerationID,
                ])
                protectedEpochIDs.formUnion([handoff.fromEpochID, handoff.toEpochID])
                protectedRouteIDs.formUnion([handoff.fromRouteID, handoff.toRouteID])
                sampleCompactionBlockedRouteIDs.formUnion([
                    handoff.fromRouteID,
                    handoff.toRouteID,
                ])
            }
            if let rollover = state.rolloverEffectsWork,
               rollover.retry.terminal == .pending {
                protectedEpochIDs.formUnion([rollover.oldEpochID, rollover.newEpochID])
                protectedRouteIDs.formUnion([rollover.oldRouteID, rollover.newRouteID])
                sampleCompactionBlockedRouteIDs.formUnion([
                    rollover.oldRouteID,
                    rollover.newRouteID,
                ])
            }
            protectedEpochIDs.formUnion(state.shieldReferences.values.map(\.epochID))
            protectedRouteIDs.formUnion(state.shieldReferences.values.map(\.routeID))
            protectedRouteIDs.formUnion(state.deferredCallbacks.values.map(\.routeID))
            sampleCompactionBlockedRouteIDs.formUnion(
                state.deferredCallbacks.values.map(\.routeID)
            )

            let retiredGenerationIDs = Set(state.generations.values.compactMap {
                generation -> UUID? in
                guard generation.childDeviceID == owner,
                      generation.retiredAt != nil,
                      generation.generationID != state.activeGenerationID
                else { return nil }
                return generation.generationID
            })

            // A retained retired generation may still carry many already-sent
            // rungs. One maximum successful sample preserves the accepted
            // high-water; pending work and current-route history are untouched.
            var removedCount = 0
            let compactableRetiredRouteIDs = Set(state.routes.values.compactMap {
                route -> UUID? in
                guard state.generations[route.generationID]?.retiredAt != nil,
                      !sampleCompactionBlockedRouteIDs.contains(route.routeID),
                      !physicallyInstalledActivityNames.contains(route.activityName)
                else { return nil }
                return route.routeID
            })
            for routeID in compactableRetiredRouteIDs {
                let works = state.sampleWork.values.filter { $0.routeID == routeID }
                guard works.allSatisfy({
                    $0.claim == nil && $0.retry.terminal != .pending
                }) else { continue }
                let retainedSucceededID = works
                    .filter { $0.retry.terminal == .succeeded }
                    .max {
                        if $0.request.estimatedMinutes != $1.request.estimatedMinutes {
                            return $0.request.estimatedMinutes < $1.request.estimatedMinutes
                        }
                        if $0.createdAt != $1.createdAt {
                            return $0.createdAt < $1.createdAt
                        }
                        return $0.workID.uuidString > $1.workID.uuidString
                    }?
                    .workID
                let removable = works.compactMap { work -> UUID? in
                    work.workID == retainedSucceededID ? nil : work.workID
                }
                for workID in removable {
                    state.sampleWork[workID] = nil
                }
                if var tombstone = state.tombstones[routeID] {
                    tombstone.referencedWorkIDs.subtract(removable)
                    state.tombstones[routeID] = tombstone
                }
                removedCount += removable.count
            }

            let removableRetiredRouteIDs = Set(state.routes.values.compactMap {
                route -> UUID? in
                let retiredGenerationIsCollectable =
                    retiredGenerationIDs.contains(route.generationID)
                    && !protectedGenerationIDs.contains(route.generationID)
                let stoppedSupersededRouteIsCollectable: Bool = {
                    guard route.lifecycle == .tombstoned,
                          route.routeID != state.activeRouteID,
                          route.epochID != state.activeEpochID,
                          let epoch = state.epochs[route.epochID],
                          epoch.status == .retired,
                          epoch.retireReason == .activationSuperseded,
                          let tombstone = state.tombstones[route.routeID],
                          let stoppedAt = tombstone.stopAcknowledgedAt,
                          now.timeIntervalSince(stoppedAt) >= Self.lateCallbackGraceSeconds
                    else { return false }
                    return state.installWork.values
                        .filter { $0.routeID == route.routeID }
                        .allSatisfy {
                            $0.phase == .stopped
                                && $0.claim == nil
                        }
                }()
                guard retiredGenerationIsCollectable || stoppedSupersededRouteIsCollectable,
                      !protectedRouteIDs.contains(route.routeID),
                      !protectedEpochIDs.contains(route.epochID),
                      route.lifecycle != .active,
                      !physicallyInstalledActivityNames.contains(route.activityName),
                      state.registrationWork.values
                        .filter({ $0.routeID == route.routeID })
                        .allSatisfy({
                            $0.claim == nil && $0.retry.terminal != .pending
                        }),
                      state.activationWork.values
                        .filter({ $0.routeID == route.routeID })
                        .allSatisfy({
                            $0.claim == nil && $0.retry.terminal != .pending
                        }),
                      state.sampleWork.values
                        .filter({ $0.routeID == route.routeID })
                        .allSatisfy({
                            $0.claim == nil && $0.retry.terminal != .pending
                        }),
                      state.installWork.values
                        .filter({ $0.routeID == route.routeID })
                        .allSatisfy({ $0.claim == nil })
                else { return nil }
                return route.routeID
            })
            for routeID in removableRetiredRouteIDs {
                guard let route = state.routes[routeID] else { continue }
                let registrationIDs = state.registrationWork.values
                    .filter { $0.routeID == routeID }
                    .map(\.workID)
                let activationIDs = state.activationWork.values
                    .filter { $0.routeID == routeID }
                    .map(\.workID)
                let sampleIDs = state.sampleWork.values
                    .filter { $0.routeID == routeID }
                    .map(\.workID)
                let installIDs = state.installWork.values
                    .filter { $0.routeID == routeID }
                    .map(\.workID)
                registrationIDs.forEach { state.registrationWork[$0] = nil }
                activationIDs.forEach { state.activationWork[$0] = nil }
                sampleIDs.forEach { state.sampleWork[$0] = nil }
                installIDs.forEach { state.installWork[$0] = nil }
                state.tombstones[routeID] = nil
                state.routes[routeID] = nil
                if !state.routes.values.contains(where: { $0.epochID == route.epochID }) {
                    state.epochs[route.epochID] = nil
                }
                removedCount += 1
                    + registrationIDs.count
                    + activationIDs.count
                    + sampleIDs.count
                    + installIDs.count
            }
            for generationID in retiredGenerationIDs
            where !protectedGenerationIDs.contains(generationID)
                && !state.routes.values.contains(where: {
                    $0.generationID == generationID
                }) {
                state.generations[generationID] = nil
                removedCount += 1
            }
            return removedCount
        }
    }

    /// The callback boundary is deliberately the sole local producer of v2
    /// sample work. Authority checks and mutation share one root decode under
    /// the lock; rejected callbacks cannot bootstrap an empty root.
    func prepareAuthorizedV2Callback(
        _ input: MeteringAuthorizedCallbackInput,
        owner: UUID
    ) throws -> MeteringPreparedAuthorizedCallback {
        guard isCurrentOwner(owner) else {
            return MeteringPreparedAuthorizedCallback(
                result: .discarded(reason: "owner_mismatch"),
                work: nil
            )
        }

        let state = try read()
        guard state.ownerChildDeviceID == owner else {
            return MeteringPreparedAuthorizedCallback(
                result: .discarded(
                    reason: state.ownerChildDeviceID == nil
                        ? "missing_owner"
                        : "owner_mismatch"
                ),
                work: nil
            )
        }
        guard state.routes[input.routeID] != nil else {
            return MeteringPreparedAuthorizedCallback(
                result: .discarded(
                    reason: state.tombstones[input.routeID] == nil
                        ? "unknown_route"
                        : "tombstoned_route"
                ),
                work: nil
            )
        }

        var candidate = state
        let result = authorizeV2Callback(
            &candidate,
            input: input,
            owner: owner,
            preparedShieldReference: nil
        )
        try checkOwner(expectedOwner: owner, state: candidate)
        try validateStatic(candidate, expectedOwner: owner, requireOwnerMatch: true)
        try validateTransactionDelta(candidate: candidate, priorState: state)

        let work: EpochSampleWork?
        if case let .queued(workID) = result {
            work = candidate.sampleWork[workID]
        } else {
            work = nil
        }
        return MeteringPreparedAuthorizedCallback(result: result, work: work)
    }

    /// The callback boundary is deliberately the sole local producer of v2
    /// sample work. Authority checks and mutation share one root decode under
    /// the lock; rejected callbacks cannot bootstrap an empty root.
    func enqueueAuthorizedV2Callback(
        _ input: MeteringAuthorizedCallbackInput,
        owner: UUID,
        preparedShieldReference: EarnedShieldReference? = nil
    ) throws -> MeteringAuthorizedCallbackResult {
        guard isCurrentOwner(owner) else {
            recordCallbackVerdict(
                .discarded(reason: "owner_mismatch"),
                input: input,
                site: "store.callback",
                context: nil
            )
            return .discarded(reason: "owner_mismatch")
        }

        do {
            var enqueued: EpochSampleWork?
            var context: MeteringCallbackVerdictContext?
            let result = try transaction(
                expectedOwner: owner,
                bootstrapOwnerIfMissing: false,
                allowPersistedOwnerMismatchForNoop: true,
                debugLabel: "v2_callback"
            ) { state -> MeteringAuthorizedCallbackResult in
                let sampleIDsBeforeAuthorization = Set(state.sampleWork.keys)
                if state.ownerChildDeviceID != owner {
                    context = callbackVerdictContext(
                        input: input,
                        state: state,
                        sampleAlreadyExisted: false
                    )
                    return .discarded(
                        reason: state.ownerChildDeviceID == nil
                            ? "missing_owner"
                            : "owner_mismatch"
                    )
                }
                guard state.routes[input.routeID] != nil else {
                    context = callbackVerdictContext(
                        input: input,
                        state: state,
                        sampleAlreadyExisted: false
                    )
                    return .discarded(
                        reason: state.tombstones[input.routeID] == nil
                            ? "unknown_route"
                            : "tombstoned_route"
                    )
                }
                let outcome = authorizeV2Callback(
                    &state,
                    input: input,
                    owner: owner,
                    preparedShieldReference: preparedShieldReference
                )
                if case .queued(let workID) = outcome {
                    enqueued = state.sampleWork[workID]
                    context = callbackVerdictContext(
                        input: input,
                        state: state,
                        sampleAlreadyExisted: sampleIDsBeforeAuthorization.contains(workID)
                    )
                } else {
                    context = callbackVerdictContext(
                        input: input,
                        state: state,
                        sampleAlreadyExisted: false
                    )
                }
                return outcome
            }
            recordCallbackVerdict(
                result,
                input: input,
                site: "store.callback",
                context: context
            )
            if let enqueued, context?.sampleAlreadyExisted == false {
                recordSampleEnqueued(enqueued, site: "store.callback")
            }
            return result
        } catch {
            // A throwing transaction (readback mismatch, invariant violation)
            // used to lose the callback with no trace at all — the caller only
            // saw `throws` and the extension logged it to a key that the next
            // callback overwrote.
            MeteringFlightRecorder.emitError(
                site: "store.callback",
                error: error,
                detail: MeteringFlightRecorder.detail([
                    ("evt", input.eventName),
                    ("thr", String(input.thresholdMinutes)),
                ]),
                corrID: input.routeID
            )
            throw error
        }
    }

    /// Flight-recorder emission for a newly created v2 sample work item — the
    /// head of the sample chain. `estimatedMinutes` is the number the backend
    /// will actually be told (`base + raw - excludedWhilePaused`), so a bar
    /// that disagrees with the device can be traced to the exact minute value
    /// that left here.
    private func recordSampleEnqueued(_ work: EpochSampleWork, site: String) {
        MeteringFlightRecorder.emit(
            kind: .meteringSample,
            site: site,
            verdict: "enqueued",
            detail: MeteringFlightRecorder.detail([
                ("work", MeteringFlightRecorder.shortID(work.workID)),
                ("date", work.request.usageDate),
                ("auth", work.authorization.rawValue),
                ("sampleID", work.request.clientSampleID),
            ]),
            nums: ScreenTimeEvent.Nums(
                used: work.request.estimatedMinutes,
                threshold: work.request.thresholdMinutes
            ),
            corrID: work.routeID
        )
    }

    /// Flight-recorder emission for one v2 threshold verdict.
    ///
    /// Every branch exit of `authorizeV2Callback` funnels its
    /// `MeteringAuthorizedCallbackResult` through here, together with the
    /// numbers the decision was actually made on (`baseAcceptedMinutes`,
    /// `lastRawThresholdMinutes`, `excludedWhilePausedMinutes`) and the
    /// coverage status — so "too_early" and "epoch_not_active" stop being
    /// unfalsifiable one-word mysteries.
    ///
    /// The three legacy debug defaults (`evlin.metering.lastV2ThresholdOutcome`
    /// et al.) are intentionally left alone; this is additive.
    private func recordCallbackVerdict(
        _ result: MeteringAuthorizedCallbackResult,
        input: MeteringAuthorizedCallbackInput,
        site: String,
        context: MeteringCallbackVerdictContext?
    ) {
        let verdict: String
        switch result {
        case .queued:
            // A rung that re-fires resolves to the SAME sample work item.
            // Calling both "queued" hid genuine duplicate storms.
            verdict = context?.sampleAlreadyExisted == true ? "queued_duplicate" : "queued"
        case .discarded(let reason):
            verdict = reason
        }
        var pairs: [(String, String)] = [
            ("evt", input.eventName),
            ("life", context?.routeLifecycle ?? "no_route"),
        ]
        if let coverageStatus = context?.coverageStatus {
            pairs.append(("cover", coverageStatus))
            pairs.append(("ready", context?.coverageReadyThrough ?? "nil"))
        } else if context != nil {
            pairs.append(("cover", "none"))
        }
        if let epochUsageDate = context?.epochUsageDate {
            pairs.append(("date", epochUsageDate))
            pairs.append(("status", context?.epochStatus ?? "unknown"))
            // The physical-time bound that produces `too_early`.
            if let startedAt = context?.epochStartedAt {
                pairs.append(("started", ISO8601DateFormatter().string(from: startedAt)))
            }
        }
        if case .queued(let workID) = result {
            pairs.append(("work", MeteringFlightRecorder.shortID(workID)))
        }
        MeteringFlightRecorder.emit(
            kind: .meteringGuard,
            site: site,
            verdict: verdict,
            detail: MeteringFlightRecorder.detail(pairs),
            nums: ScreenTimeEvent.Nums(
                base: context?.baseAcceptedMinutes,
                raw: context?.lastRawThresholdMinutes,
                threshold: input.thresholdMinutes,
                excluded: context?.excludedWhilePausedMinutes,
                offset: context?.physicalGenerationOffsetMinutes
            ),
            corrID: input.routeID
        )
    }

    private func callbackVerdictContext(
        input: MeteringAuthorizedCallbackInput,
        state: DeviceEpochStoreState,
        sampleAlreadyExisted: Bool
    ) -> MeteringCallbackVerdictContext {
        let route = state.routes[input.routeID]
        let epoch = route.flatMap { state.epochs[$0.epochID] }
        return MeteringCallbackVerdictContext(
            routeLifecycle: route?.lifecycle.rawValue ?? "no_route",
            coverageStatus: state.coverage?.status.rawValue,
            coverageReadyThrough: state.coverage?.readyThroughUsageDate,
            epochUsageDate: epoch?.usageDate,
            epochStatus: epoch?.status.rawValue,
            epochStartedAt: epoch?.startedAt,
            baseAcceptedMinutes: epoch?.baseAcceptedMinutes,
            lastRawThresholdMinutes: epoch?.lastRawThresholdMinutes,
            excludedWhilePausedMinutes: epoch?.excludedWhilePausedMinutes,
            physicalGenerationOffsetMinutes: route?.physicalGenerationOffsetMinutes,
            sampleAlreadyExisted: sampleAlreadyExisted
        )
    }

    /// Credits callbacks that were parked awaiting activation and whose route has
    /// since become active, and prunes entries that can never be credited (route
    /// gone or tombstoned, or the grace window elapsed).
    ///
    /// Replay runs the parked input back through the SAME authorization path, so
    /// every guard — provenance, physical-time plausibility, coverage, ratchet —
    /// is enforced exactly as it would have been for a live callback. A replayed
    /// entry can never re-park, because parking requires `lifecycle == .planned`.
    @discardableResult
    func replayDeferredCallbacks(owner: UUID, now: Date) throws -> [MeteringAuthorizedCallbackResult] {
        guard isCurrentOwner(owner) else { return [] }
        let priorState = try read()
        guard !priorState.deferredCallbacks.isEmpty else { return [] }
        // Replayed inputs + their verdicts, emitted AFTER the transaction
        // commits so a rolled-back write never leaves a phantom in the
        // timeline. Pruned (never-creditable) parks are counted separately —
        // silently dropping them is how birth-race callbacks used to vanish.
        var replayed: [(MeteringAuthorizedCallbackInput, MeteringAuthorizedCallbackResult)] = []
        var prunedReasons: [String] = []
        var enqueued: [EpochSampleWork] = []
        let results = try transaction(expectedOwner: owner) { state in
            var results: [MeteringAuthorizedCallbackResult] = []
            for key in state.deferredCallbacks.keys.sorted() {
                guard let parked = state.deferredCallbacks[key] else { continue }
                guard parked.ownerChildDeviceID == owner,
                      state.tombstones[parked.routeID] == nil,
                      let route = state.routes[parked.routeID]
                else {
                    state.deferredCallbacks[key] = nil
                    prunedReasons.append("route_gone")
                    continue
                }
                switch route.lifecycle {
                case .active:
                    state.deferredCallbacks[key] = nil
                    let input = MeteringAuthorizedCallbackInput(
                        routeID: parked.routeID,
                        activityName: parked.activityName,
                        eventName: parked.eventName,
                        namespace: parked.namespace,
                        thresholdMinutes: parked.thresholdMinutes,
                        observedAt: parked.observedAt,
                        now: now,
                        jitterSeconds: parked.jitterSeconds
                    )
                    let result = authorizeV2Callback(
                        &state,
                        input: input,
                        owner: owner,
                        preparedShieldReference: nil
                    )
                    replayed.append((input, result))
                    if case .queued(let workID) = result,
                       priorState.sampleWork[workID] == nil,
                       let work = state.sampleWork[workID] {
                        enqueued.append(work)
                    }
                    results.append(result)
                case .planned:
                    if now.timeIntervalSince(parked.parkedAt) > Self.deferredCallbackGraceSeconds {
                        if let epoch = state.epochs[route.epochID],
                           epoch.resumeBoundaryPending,
                           let terminalThreshold = route.plannedEvents
                               .map(\.thresholdMinutes)
                               .max(),
                           parked.thresholdMinutes >= terminalThreshold,
                           let installID = state.installWork.first(where: {
                               $0.value.ownerChildDeviceID == owner
                                   && $0.value.routeID == route.routeID
                           })?.key {
                            // The expired park is still durable proof that the
                            // daemon consumed this route's entire one-shot
                            // ladder before it became authoritative. Preserve
                            // that proof for the existing physical-identity
                            // repair instead of activating a deaf route.
                            state.installWork[installID]?.retry.lastErrorCode =
                                "physical_events_consumed_too_early"
                        }
                        state.deferredCallbacks[key] = nil
                        prunedReasons.append("grace_elapsed")
                    }
                case .retired, .tombstoned:
                    state.deferredCallbacks[key] = nil
                    prunedReasons.append("route_\(route.lifecycle.rawValue)")
                }
            }
            return results
        }
        for (input, result) in replayed {
            let sampleAlreadyExisted: Bool
            if case .queued(let workID) = result {
                sampleAlreadyExisted = priorState.sampleWork[workID] != nil
            } else {
                sampleAlreadyExisted = false
            }
            recordCallbackVerdict(
                result,
                input: input,
                site: "store.replay",
                context: callbackVerdictContext(
                    input: input,
                    state: priorState,
                    sampleAlreadyExisted: sampleAlreadyExisted
                )
            )
        }
        for work in enqueued {
            recordSampleEnqueued(work, site: "store.replay")
        }
        if !replayed.isEmpty || !prunedReasons.isEmpty {
            MeteringFlightRecorder.emit(
                kind: .meteringReplay,
                site: "store.replay",
                verdict: replayed.isEmpty ? "pruned_only" : "replayed",
                detail: MeteringFlightRecorder.detail([
                    ("parked", String(priorState.deferredCallbacks.count)),
                    ("pruned", prunedReasons.sorted().joined(separator: ",")),
                ]),
                nums: ScreenTimeEvent.Nums(count: replayed.count)
            )
        }
        return results
    }

    private func authorizeV2Callback(
        _ state: inout DeviceEpochStoreState,
        input: MeteringAuthorizedCallbackInput,
        owner: UUID,
        preparedShieldReference: EarnedShieldReference?
    ) -> MeteringAuthorizedCallbackResult {
        if state.tombstones[input.routeID] != nil {
            return .discarded(reason: "tombstoned_route")
        }
        // P3 late-callback grace: a genuine callback for a route retired mid-flight
        // (Apple delivers 5-15 min late) is credited to the current active epoch —
        // without relaxing the strict current-route provenance guard below.
        if let adopted = adoptLateRetiredCallbackIfEligible(&state, input: input, owner: owner) {
            return adopted
        }
        // FIX-A birth race: Apple back-delivers already-met thresholds ~1s after
        // startMonitoring, before the route can finish activating. Park those
        // instead of dropping them; `replayDeferredCallbacks` credits them once
        // the route is active. Every provenance check still applies — only the
        // lifecycle is allowed to be `.planned`.
        if let parked = parkCallbackAwaitingActivationIfEligible(&state, input: input, owner: owner) {
            return parked
        }
        guard state.ownerChildDeviceID == owner,
              let route = state.routes[input.routeID],
              let generation = state.generations[route.generationID],
              var epoch = state.epochs[route.epochID],
              route.ownerChildDeviceID == owner,
              route.routeID == input.routeID,
              route.activityName == input.activityName,
              route.namespace == input.namespace,
              route.lifecycle == .active,
              route.epochID == epoch.epochID,
              route.generationID == generation.generationID,
              route.usageDate == epoch.usageDate,
              epoch.childDeviceID == owner,
              epoch.protocolVersion == 2,
              epoch.canonicalTimezone == generation.canonicalTimezone,
              epoch.policyRevision == generation.policyRevision,
              epoch.measurementSelectionDigest == generation.measurementSelectionDigest,
              epoch.enforcementSetID == generation.enforcementSetID,
              generation.childDeviceID == owner,
              generation.protocolVersion == 2,
              generation.retiredAt == nil,
              route.plannedEvents.contains(where: {
                  $0.eventName == input.eventName && $0.thresholdMinutes == input.thresholdMinutes
              })
        else {
            return .discarded(reason: "route_provenance_mismatch")
        }

        // Thresholds are RELATIVE to this epoch: the ladder is cut over
        // `remaining = pool - baseAcceptedMinutes` and a sample reports
        // `base + threshold`. So a threshold T genuinely requires T minutes of
        // wall clock since `startedAt` — do NOT credit the base here (tried
        // 2026-07-24, it silently disables this anti-cheat bound for every epoch
        // born with a base). Apple's own events count the whole day
        // Events use `includesPastActivity: false`, but on-device evidence shows
        // that starting a replacement from inside this extension callback can
        // still synchronously consume every new one-shot event. The guard below
        // rejects that false progress and marks the physical route for a fresh
        // identity; it must never weaken the elapsed-time bound.
        let physicalOffset = max(0, route.physicalGenerationOffsetMinutes ?? 0)
        let logicalThreshold = max(0, input.thresholdMinutes - physicalOffset)
        let earliest = epoch.startedAt.addingTimeInterval(
            TimeInterval(logicalThreshold * 60 - input.jitterSeconds)
        )
        guard input.observedAt >= earliest else {
            // FIX-Q: a rung firing within seconds of ARM is Apple back-firing
            // thresholds the day's counter has already crossed — a partial
            // burst. Those bells are calibration, not cheating: absorb them
            // into the exclusion high-water (which can only REDUCE future
            // credit, so the anti-cheat bound is not weakened) and leave the
            // route alive — its rungs above the burst are still armed and
            // will fire on real usage. Death-stamping these routes is what
            // fed the mint→burst→mint repair storm (iPhone 2026-08-05 03:12,
            // 30 epochs in ten minutes) and every "re-arm goes mute" day.
            let armedAt = route.installedSchedule?.intervalStartAt ?? route.createdAt
            if input.observedAt.timeIntervalSince(armedAt) < Self.armGraceCalibrationSeconds,
               input.observedAt >= armedAt.addingTimeInterval(-1) {
                epoch.lastRawThresholdMinutes = max(
                    epoch.lastRawThresholdMinutes, input.thresholdMinutes
                )
                epoch.excludedWhilePausedMinutes = max(
                    epoch.excludedWhilePausedMinutes, input.thresholdMinutes
                )
                state.epochs[epoch.epochID] = epoch
                let installKeys = state.installWork.compactMap { key, work in
                    work.routeID == route.routeID ? key : nil
                }
                if input.thresholdMinutes > physicalOffset,
                   installKeys.count == 1,
                   let installKey = installKeys.first {
                    state.installWork[installKey]?.retry.lastErrorCode =
                        "arm_grace_calibration_requires_offset_recut"
                }
                return .discarded(reason: "arm_grace_calibration")
            }
            let installKeys = state.installWork.compactMap { key, work in
                work.routeID == route.routeID ? key : nil
            }
            if installKeys.count == 1, let installKey = installKeys.first {
                state.installWork[installKey]?.retry.lastErrorCode =
                    "physical_events_consumed_too_early"
            }
            return .discarded(reason: "too_early")
        }

        guard hasCallbackCoverage(route: route, owner: owner, state: state),
              let ratchet = state.ratchets[owner],
              ratchet.localSelection != .v1
        else {
            return .discarded(reason: "epoch_not_active")
        }

        let sampleAuthorization: EpochSampleAuthorization
        switch callbackInstallAuthorization(route: route, epoch: epoch, owner: owner, state: state) {
        case .accepted(let authorization):
            sampleAuthorization = authorization
        case .discarded(let reason):
            return .discarded(reason: reason)
        }

        if epoch.status == .paused {
            guard sampleAuthorization == .v2Deliverable else {
                return .discarded(reason: "paused_route_unregistered")
            }
            switch pausedCallbackRouteAuthorization(
                route: route,
                epoch: epoch,
                owner: owner,
                ratchet: ratchet,
                state: state
            ) {
            case .discarded(let reason):
                return .discarded(reason: reason)
            case .accepted:
                break
            }
            epoch.lastRawThresholdMinutes = max(epoch.lastRawThresholdMinutes, input.thresholdMinutes)
            epoch.excludedWhilePausedMinutes = max(epoch.excludedWhilePausedMinutes, input.thresholdMinutes)
            state.epochs[epoch.epochID] = epoch
            return .discarded(reason: "paused")
        }

        guard epoch.status == .active,
              epoch.retiredAt == nil,
              epoch.exhaustedAt == nil,
              epoch.authoritativeBaseConflict == nil
        else {
            return .discarded(reason: "epoch_not_active")
        }

        if let adopted = adoptPreBarrierPriorCallbackIfEligible(
            &state,
            input: input,
            owner: owner,
            priorRoute: route,
            priorEpoch: epoch
        ) {
            return adopted
        }

        switch callbackRouteAuthorization(
            route: route,
            epoch: epoch,
            owner: owner,
            observedAt: input.observedAt,
            ratchet: ratchet,
            state: state
        ) {
        case .discarded(let reason):
            return .discarded(reason: reason)
        case .accepted:
            break
        }

        if epoch.resumeBoundaryPending {
            if let handoff = state.v2RouteHandoff,
               handoff.phase == .preparing,
               handoff.fromRouteID == route.routeID {
                // The prior route remains countable during make-before-break,
                // but the replacement owns the resume boundary. Consuming it
                // on the prior would let the successor count a cross-boundary
                // bucket as ordinary usage.
                return .discarded(reason: "resume_boundary_handoff_preparing")
            }
            guard sampleAuthorization == .v2Deliverable
                    || sampleAuthorization == .waitingForRegistration
            else {
                return .discarded(reason: "resume_boundary_unregistered")
            }
            epoch.lastRawThresholdMinutes = max(epoch.lastRawThresholdMinutes, input.thresholdMinutes)
            epoch.excludedWhilePausedMinutes = max(epoch.excludedWhilePausedMinutes, input.thresholdMinutes)
            epoch.resumeBoundaryPending = false
            state.epochs[epoch.epochID] = epoch
            return .discarded(reason: "resume_boundary")
        }

        // A calibration high-water above this route's planned physical offset
        // means its terminal bell is physically early. Keep the sample (it is
        // still useful ledger evidence), but never install the terminal shield
        // until recovery has re-cut the route with the matching offset.
        if let reference = preparedShieldReference,
           epoch.excludedWhilePausedMinutes <= physicalOffset {
            guard let terminal = route.plannedEvents.max(by: {
                $0.thresholdMinutes < $1.thresholdMinutes
            }),
                  terminal.eventName == input.eventName,
                  terminal.thresholdMinutes == input.thresholdMinutes,
                  reference.operationID == route.routeID,
                  reference.ownerChildDeviceID == owner,
                  reference.generationID == route.generationID,
                  reference.epochID == route.epochID,
                  reference.routeID == route.routeID,
                  canApplyEarnedShieldReference(reference, in: state)
            else {
                return .discarded(reason: "shield_reference_mismatch")
            }
            if let existing = state.shieldReferences[reference.operationID] {
                guard existing.matches(
                    operationID: reference.operationID,
                    ownerChildDeviceID: reference.ownerChildDeviceID,
                    generationID: reference.generationID,
                    epochID: reference.epochID,
                    routeID: reference.routeID,
                    recordKey: reference.recordKey,
                    expectedRecordBytes: reference.expectedRecordBytes
                ) else {
                    return .discarded(reason: "shield_reference_mismatch")
                }
            } else {
                state.shieldReferences[reference.operationID] = reference
            }
        }

        let rawThreshold = max(epoch.lastRawThresholdMinutes, input.thresholdMinutes)
        // BUG 1 — report against the base THIS LADDER was cut from, not the
        // epoch's current base.
        //
        // A rung is a promise about a total: "t150 means 150 minutes past the
        // base this ladder was cut for". `absorbCreditedProgressForRearm` used
        // to move the base without re-cutting the rungs, and any rung Apple
        // still held then resolved against a base that had grown underneath it:
        // base 145 + a rung from a ladder cut at base 20 reported 295 and 305
        // minutes into a 180-minute pool (iPad 2026-07-25 13:37). The re-arm is
        // now atomic with the re-cut, but Apple can re-deliver a rung of a
        // registration the store has already replaced, so the ladder's own base
        // — not the live one — is what a rung must be resolved against.
        let ladderBase = state.ladderBaseMinutes(for: route)
        let uncappedMinutes = ladderBase + max(0, rawThreshold - epoch.excludedWhilePausedMinutes)
        // Cheap insurance, deliberately independent of the invariant above: no
        // sample may ever claim more than the day's whole pool, however the
        // ledger got there.
        let ceilingMinutes = state.ladderCeilingMinutes(for: route)
        let estimatedMinutes = ceilingMinutes.map { min(uncappedMinutes, $0) } ?? uncappedMinutes
        if let ceilingMinutes, uncappedMinutes > ceilingMinutes {
            MeteringFlightRecorder.emit(
                kind: .meteringSample,
                site: "store.callback",
                verdict: "clamped_over_ceiling",
                detail: MeteringFlightRecorder.detail([
                    ("ladderBase", String(ladderBase)),
                    ("epochBase", String(epoch.baseAcceptedMinutes)),
                    ("ceiling", String(ceilingMinutes)),
                ]),
                nums: ScreenTimeEvent.Nums(
                    used: estimatedMinutes,
                    base: epoch.baseAcceptedMinutes,
                    raw: epoch.lastRawThresholdMinutes,
                    threshold: rawThreshold
                ),
                corrID: route.routeID,
                transition: ScreenTimeEvent.Transition(
                    before: String(uncappedMinutes),
                    after: String(estimatedMinutes)
                )
            )
        }
        let clientSampleID = MeteringSampleWireAliases.clientSampleID(
            lane: .v2,
            routeID: route.routeID,
            thresholdMinutes: rawThreshold
        )
        if let existing = state.sampleWork.values.first(where: {
            $0.ownerChildDeviceID == owner && $0.request.clientSampleID == clientSampleID
        }) {
            return .queued(sampleWorkID: existing.workID)
        }

        epoch.lastRawThresholdMinutes = rawThreshold
        state.epochs[epoch.epochID] = epoch
        let workID = UUID()
        state.sampleWork[workID] = EpochSampleWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: epoch.epochID,
            routeID: route.routeID,
            request: EpochSampleRequestDTO(
                deviceID: owner,
                usageDate: epoch.usageDate,
                timezone: epoch.canonicalTimezone,
                activityName: MeteringSampleWireAliases.activityName(routeID: route.routeID),
                eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: rawThreshold),
                thresholdMinutes: rawThreshold,
                estimatedMinutes: estimatedMinutes,
                observedAt: input.observedAt,
                clientSampleID: clientSampleID,
                protocolVersion: 2,
                epochID: epoch.epochID,
                generationArmedAt: nil,
                generationOffsetMinutes: nil
            ),
            authorization: sampleAuthorization,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: input.now,
                lastErrorCode: nil,
                terminal: .pending
            ),
            createdAt: input.now
        )
        return .queued(sampleWorkID: workID)
    }

    /// P3 late-callback grace window. Apple delivers threshold callbacks 5-15 min
    /// after the usage they describe; 20 min covers that plus margin while still
    /// bounding stale-replay exposure.
    private static let lateCallbackGraceSeconds: TimeInterval = 20 * 60

    /// How long a callback may wait for its route to activate. Activation is two
    /// network round trips, so minutes are normal and hours mean it will never
    /// happen.
    static let deferredCallbackGraceSeconds: TimeInterval = 60 * 60

    /// Bounds the parking area so a pathological arm loop cannot grow the store.
    private static let deferredCallbackCapacity = 32

    /// Parks a callback whose route passes every provenance check but has not
    /// finished activating yet (`lifecycle == .planned`). Returns nil — meaning
    /// "fall through to the strict guard" — for anything else, so no other
    /// discard path changes behaviour.
    private func parkCallbackAwaitingActivationIfEligible(
        _ state: inout DeviceEpochStoreState,
        input: MeteringAuthorizedCallbackInput,
        owner: UUID
    ) -> MeteringAuthorizedCallbackResult? {
        guard state.ownerChildDeviceID == owner,
              let route = state.routes[input.routeID],
              route.lifecycle == .planned,
              route.ownerChildDeviceID == owner,
              route.routeID == input.routeID,
              route.activityName == input.activityName,
              route.namespace == input.namespace,
              let generation = state.generations[route.generationID],
              let epoch = state.epochs[route.epochID],
              route.epochID == epoch.epochID,
              route.generationID == generation.generationID,
              route.usageDate == epoch.usageDate,
              epoch.childDeviceID == owner,
              epoch.protocolVersion == 2,
              epoch.retiredAt == nil,
              epoch.canonicalTimezone == generation.canonicalTimezone,
              epoch.policyRevision == generation.policyRevision,
              epoch.measurementSelectionDigest == generation.measurementSelectionDigest,
              epoch.enforcementSetID == generation.enforcementSetID,
              generation.childDeviceID == owner,
              generation.protocolVersion == 2,
              generation.retiredAt == nil,
              route.plannedEvents.contains(where: {
                  $0.eventName == input.eventName && $0.thresholdMinutes == input.thresholdMinutes
              })
        else { return nil }

        let key = DeferredMeteringCallback.key(routeID: input.routeID, eventName: input.eventName)
        // Drop entries whose grace has elapsed before enforcing capacity, so a
        // burst of dead parks can never crowd out a live one.
        state.deferredCallbacks = state.deferredCallbacks.filter { _, parked in
            input.now.timeIntervalSince(parked.parkedAt) <= Self.deferredCallbackGraceSeconds
        }
        let sameRoute = state.deferredCallbacks.filter {
            $0.value.ownerChildDeviceID == owner
                && $0.value.routeID == input.routeID
        }
        if let highest = sameRoute.values.max(by: {
            $0.thresholdMinutes < $1.thresholdMinutes
        }), highest.thresholdMinutes >= input.thresholdMinutes {
            return .discarded(reason: "deferred_pending_activation")
        }
        for existingKey in sameRoute.keys {
            state.deferredCallbacks[existingKey] = nil
        }
        guard state.deferredCallbacks[key] != nil
                || state.deferredCallbacks.count < Self.deferredCallbackCapacity
        else {
            return .discarded(reason: "deferred_capacity_exhausted")
        }
        state.deferredCallbacks[key] = DeferredMeteringCallback(
            ownerChildDeviceID: owner,
            routeID: input.routeID,
            activityName: input.activityName,
            eventName: input.eventName,
            namespace: input.namespace,
            thresholdMinutes: input.thresholdMinutes,
            observedAt: input.observedAt,
            jitterSeconds: input.jitterSeconds,
            parkedAt: input.now
        )
        return .discarded(reason: "deferred_pending_activation")
    }

    /// Credits a genuine but late threshold callback whose route was retired
    /// mid-flight (policy replacement) to the CURRENT active epoch's base via
    /// high-water — the year-long "bars frozen" root cause was silently dropping
    /// exactly these. This never relaxes the strict current-route provenance guard
    /// (`callbackRouteAuthorization`); it only fires when a current active epoch of
    /// the SAME day / owner / selection-digest / enforcement-set exists, and
    /// `max()` means it can never inflate beyond genuinely-observed usage. Returns
    /// nil to fall through to the strict path (which then discards as before).
    private func adoptLateRetiredCallbackIfEligible(
        _ state: inout DeviceEpochStoreState,
        input: MeteringAuthorizedCallbackInput,
        owner: UUID
    ) -> MeteringAuthorizedCallbackResult? {
        guard state.ownerChildDeviceID == owner,
              let retiredRoute = state.routes[input.routeID],
              retiredRoute.ownerChildDeviceID == owner,
              retiredRoute.activityName == input.activityName,
              retiredRoute.namespace == input.namespace,
              let retiredGeneration = state.generations[retiredRoute.generationID],
              let retiredEpoch = state.epochs[retiredRoute.epochID],
              retiredEpoch.epochID == retiredRoute.epochID,
              retiredRoute.usageDate == retiredEpoch.usageDate,
              retiredRoute.plannedEvents.contains(where: {
                  $0.eventName == input.eventName && $0.thresholdMinutes == input.thresholdMinutes
              })
        else { return nil }

        // Only genuinely-retired routes qualify — live routes take the strict path.
        let isRetired = retiredRoute.lifecycle != .active
            || retiredGeneration.retiredAt != nil
            || retiredEpoch.retiredAt != nil
        guard isRetired else { return nil }

        // Retirement must be recent relative to callback arrival (grace window).
        guard let retiredAt = [retiredGeneration.retiredAt, retiredEpoch.retiredAt]
                .compactMap({ $0 }).max(),
              input.now >= retiredAt,
              input.now.timeIntervalSince(retiredAt) <= Self.lateCallbackGraceSeconds
        else { return nil }

        // The current active epoch must be the SAME measurement lineage. A genuine
        // selection change (different apps) is NOT the same measurement — fall
        // through and conservatively drop rather than mis-credit.
        guard let currentEpochID = state.activeEpochID,
              let currentEpoch = state.epochs[currentEpochID],
              let currentRouteID = state.activeRouteID,
              let currentRoute = state.routes[currentRouteID],
              currentEpoch.epochID == currentRoute.epochID,
              currentEpoch.status == .active,
              currentEpoch.retiredAt == nil,
              currentEpoch.exhaustedAt == nil,
              currentEpoch.authoritativeBaseConflict == nil,
              currentEpoch.childDeviceID == owner,
              currentEpoch.usageDate == retiredEpoch.usageDate,
              currentEpoch.measurementSelectionDigest == retiredEpoch.measurementSelectionDigest,
              currentEpoch.enforcementSetID == retiredEpoch.enforcementSetID
        else { return nil }

        // Offer the lost minutes to the backend: the retired epoch observed
        // `base + threshold`, but observation alone is not authority to lift the
        // current epoch's base.
        //
        // BUG 1: this is the second place a base is lifted, and it lifts it from
        // a DIFFERENT epoch's ladder. Bound it by the day's ceiling for the same
        // reason the callback path is bounded — an unbounded lift here would
        // reproduce the compounding through the late-adoption door.
        let ceilingMinutes = state.ladderCeilingMinutes(for: currentRoute)
        let recoveredUncapped = retiredEpoch.baseAcceptedMinutes + input.thresholdMinutes
        let recovered = ceilingMinutes.map { min(recoveredUncapped, $0) } ?? recoveredUncapped
        guard recovered > currentEpoch.baseAcceptedMinutes else {
            return .discarded(reason: "late_retired_already_counted")
        }
        if let ceilingMinutes, recoveredUncapped > ceilingMinutes {
            MeteringFlightRecorder.emit(
                kind: .meteringSample,
                site: "store.lateAdopt",
                verdict: "clamped_over_ceiling",
                detail: MeteringFlightRecorder.detail([
                    ("ceiling", String(ceilingMinutes)),
                ]),
                nums: ScreenTimeEvent.Nums(
                    used: recovered,
                    threshold: input.thresholdMinutes
                ),
                corrID: currentRoute.routeID,
                transition: ScreenTimeEvent.Transition(
                    before: String(recoveredUncapped),
                    after: String(recovered)
                )
            )
        }
        // Queue one sample for the CURRENT route/epoch so the bar advances. Keyed
        // off the retired route id so it can never collide with the current route's
        // own threshold samples (dedup-safe). The current base remains unchanged
        // until this work reaches `.succeeded`; a later re-arm then carries the
        // accepted request estimate through the same proof path as every other
        // sample.
        let estimatedMinutes = recovered
        let clientSampleID = MeteringSampleWireAliases.clientSampleID(
            lane: .v2,
            routeID: retiredRoute.routeID,
            thresholdMinutes: input.thresholdMinutes
        )
        if let existing = state.sampleWork.values.first(where: {
            $0.ownerChildDeviceID == owner && $0.request.clientSampleID == clientSampleID
        }) {
            return .queued(sampleWorkID: existing.workID)
        }
        let workID = UUID()
        state.sampleWork[workID] = EpochSampleWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: currentEpoch.epochID,
            routeID: currentRoute.routeID,
            request: EpochSampleRequestDTO(
                deviceID: owner,
                usageDate: currentEpoch.usageDate,
                timezone: currentEpoch.canonicalTimezone,
                activityName: MeteringSampleWireAliases.activityName(routeID: currentRoute.routeID),
                eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: input.thresholdMinutes),
                thresholdMinutes: input.thresholdMinutes,
                estimatedMinutes: estimatedMinutes,
                observedAt: input.observedAt,
                clientSampleID: clientSampleID,
                protocolVersion: 2,
                epochID: currentEpoch.epochID,
                generationArmedAt: nil,
                generationOffsetMinutes: nil
            ),
            authorization: .v2Deliverable,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: input.now,
                lastErrorCode: nil,
                terminal: .pending
            ),
            createdAt: input.now
        )
        return .queued(sampleWorkID: workID)
    }

    private enum CallbackAuthorization {
        case accepted
        case discarded(String)
    }

    private enum CallbackInstallAuthorization {
        case accepted(EpochSampleAuthorization)
        case discarded(String)
    }

    private func callbackRouteAuthorization(
        route: MeteringCallbackRoute,
        epoch: DeviceDailyEpoch,
        owner: UUID,
        observedAt: Date,
        ratchet: MeteringOwnerRatchet,
        state: DeviceEpochStoreState
    ) -> CallbackAuthorization {
        guard state.hasCurrentRegistrationProvenance(owner: owner, epochID: epoch.epochID, routeID: route.routeID) else {
            return .discarded("route_not_current")
        }

        if ratchet.localSelection == .dualActive {
            return state.activeRouteID == nil
                && state.activeGenerationID == route.generationID
                && state.activeEpochID == epoch.epochID
                ? .accepted
                : .discarded("initial_dual_active_mismatch")
        }

        guard let handoff = state.v2RouteHandoff else {
            return state.activeRouteID == route.routeID ? .accepted : .discarded("route_not_active")
        }
        guard handoff.ownerChildDeviceID == owner else { return .discarded("handoff_owner_mismatch") }

        switch handoff.phase {
        case .preparing:
            guard route.routeID == handoff.fromRouteID,
                  state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff)
            else { return .discarded("handoff_preparing") }
            return .accepted
        case .dualV2:
            guard state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
                  route.routeID == handoff.fromRouteID || route.routeID == handoff.toRouteID
            else { return .discarded("handoff_route_mismatch") }
            return .accepted
        case .cutoverReady:
            if route.routeID == handoff.fromRouteID {
                guard let closedAt = handoff.priorRouteInputClosedAt,
                      observedAt <= closedAt
                else { return .discarded("handoff_prior_input_closed") }
                return .discarded("handoff_prior_input_adoptable")
            }
            guard route.routeID == handoff.toRouteID,
                  state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff)
            else { return .discarded("handoff_route_mismatch") }
            return .accepted
        case .committed:
            return state.activeRouteID == route.routeID ? .accepted : .discarded("handoff_committed")
        }
    }

    private func pausedCallbackRouteAuthorization(
        route: MeteringCallbackRoute,
        epoch: DeviceDailyEpoch,
        owner: UUID,
        ratchet: MeteringOwnerRatchet,
        state: DeviceEpochStoreState
    ) -> CallbackAuthorization {
        guard epoch.status == .paused,
              epoch.registeredAt != nil,
              epoch.retiredAt == nil,
              epoch.exhaustedAt == nil,
              epoch.authoritativeBaseConflict == nil,
              state.ownerChildDeviceID == owner,
              state.activeGenerationID == route.generationID,
              state.activeEpochID == route.epochID
        else { return .discarded("paused_route_not_current") }

        if ratchet.localSelection == .dualActive {
            return state.activeRouteID == nil
                ? .accepted
                : .discarded("paused_initial_dual_active_mismatch")
        }

        guard state.activeRouteID == route.routeID else {
            return .discarded("paused_route_not_current")
        }
        let conservativeReplacementPending = state.routes.values.contains { candidate in
            guard candidate.routeID != route.routeID,
                  candidate.ownerChildDeviceID == owner,
                  candidate.generationID == route.generationID,
                  candidate.usageDate == route.usageDate,
                  candidate.lifecycle == .planned,
                  let candidateEpoch = state.epochs[candidate.epochID]
            else { return false }
            return candidateEpoch.status == .active
                && candidateEpoch.retiredAt == nil
                && candidateEpoch.resumeBoundaryPending
                && candidateEpoch.baseSource == .childState200
        }
        guard !conservativeReplacementPending else {
            return .discarded("paused_replacement_pending")
        }
        guard let handoff = state.v2RouteHandoff else { return .accepted }
        guard handoff.ownerChildDeviceID == owner else {
            return .discarded("paused_handoff_owner_mismatch")
        }

        switch handoff.phase {
        case .preparing:
            return .discarded("paused_handoff_preparing")
        case .dualV2:
            // A replacement route has opened; the old paused lane is no longer
            // proof that the usage gate remains closed.
            return .discarded("paused_handoff_replacement")
        case .cutoverReady:
            return .discarded("handoff_prior_input_closed")
        case .committed:
            return handoff.toRouteID == route.routeID
                && handoff.toEpochID == route.epochID
                && handoff.toGenerationID == route.generationID
                ? .accepted
                : .discarded("paused_handoff_route_mismatch")
        }
    }

    private func hasCallbackCoverage(
        route: MeteringCallbackRoute,
        owner: UUID,
        state: DeviceEpochStoreState
    ) -> Bool {
        guard let coverage = state.coverage else { return true }
        guard coverage.ownerChildDeviceID == owner else { return false }
        // A callback IS proof that Apple has this exact route armed — it is the
        // daemon telling us the threshold fired. Coverage is only a local,
        // periodically-recomputed *snapshot* of whether the monitors look
        // installed, and it is deliberately conservative: `refreshCoverage`
        // reports `coverageExhausted` for a route it cannot confirm, including
        // during the sub-second window right after `startMonitoring` when the
        // daemon has not yet published the activity. Letting that snapshot veto
        // the daemon's own delivery discards genuinely earned minutes that Apple
        // will never re-send (iPad 2026-07-25: every re-arm produced a callback
        // dropped as `epoch_not_active` while coverage caught up seconds later).
        // Coverage still guards OTHER routes, where it is the only signal.
        if state.activeRouteID == route.routeID { return true }
        if let handoff = state.v2RouteHandoff,
           handoff.ownerChildDeviceID == owner,
           handoff.toRouteID == route.routeID,
           handoff.toEpochID == route.epochID,
           handoff.toGenerationID == route.generationID,
           handoff.phase == .dualV2 || handoff.phase == .cutoverReady,
           state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff) {
            return true
        }
        return coverage.status != .coverageExhausted
            && (coverage.readyThroughUsageDate ?? "") >= route.usageDate
    }

    private func adoptPreBarrierPriorCallbackIfEligible(
        _ state: inout DeviceEpochStoreState,
        input: MeteringAuthorizedCallbackInput,
        owner: UUID,
        priorRoute: MeteringCallbackRoute,
        priorEpoch: DeviceDailyEpoch
    ) -> MeteringAuthorizedCallbackResult? {
        guard let handoff = state.v2RouteHandoff,
              handoff.phase == .cutoverReady,
              handoff.ownerChildDeviceID == owner,
              handoff.fromRouteID == priorRoute.routeID,
              handoff.fromEpochID == priorEpoch.epochID,
              let closedAt = handoff.priorRouteInputClosedAt,
              input.observedAt <= closedAt,
              state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
              let candidateRoute = state.routes[handoff.toRouteID],
              var candidateEpoch = state.epochs[handoff.toEpochID],
              candidateRoute.ownerChildDeviceID == owner,
              candidateRoute.epochID == candidateEpoch.epochID,
              candidateRoute.generationID == handoff.toGenerationID,
              candidateRoute.usageDate == priorRoute.usageDate,
              candidateEpoch.status == .active,
              candidateEpoch.retiredAt == nil
        else { return nil }

        let priorBase = state.ladderBaseMinutes(for: priorRoute)
        let uncapped = priorBase + max(
            0,
            input.thresholdMinutes - priorEpoch.excludedWhilePausedMinutes
        )
        let estimated = state.ladderCeilingMinutes(for: priorRoute)
            .map { min(uncapped, $0) } ?? uncapped
        let clientSampleID = MeteringSampleWireAliases.clientSampleID(
            lane: .v2,
            routeID: priorRoute.routeID,
            thresholdMinutes: input.thresholdMinutes
        )
        if let existing = state.sampleWork.values.first(where: {
            $0.ownerChildDeviceID == owner
                && $0.request.clientSampleID == clientSampleID
        }) {
            return .queued(sampleWorkID: existing.workID)
        }

        candidateEpoch.lastRawThresholdMinutes = max(
            candidateEpoch.lastRawThresholdMinutes,
            input.thresholdMinutes
        )
        state.epochs[candidateEpoch.epochID] = candidateEpoch
        let workID = UUID()
        state.sampleWork[workID] = EpochSampleWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: candidateEpoch.epochID,
            routeID: candidateRoute.routeID,
            request: EpochSampleRequestDTO(
                deviceID: owner,
                usageDate: candidateEpoch.usageDate,
                timezone: candidateEpoch.canonicalTimezone,
                activityName: MeteringSampleWireAliases.activityName(
                    routeID: candidateRoute.routeID
                ),
                eventName: MeteringSampleWireAliases.eventName(
                    thresholdMinutes: input.thresholdMinutes
                ),
                thresholdMinutes: input.thresholdMinutes,
                estimatedMinutes: estimated,
                observedAt: input.observedAt,
                clientSampleID: clientSampleID,
                protocolVersion: 2,
                epochID: candidateEpoch.epochID,
                generationArmedAt: nil,
                generationOffsetMinutes: nil
            ),
            authorization: candidateEpoch.registeredAt == nil
                ? .waitingForRegistration
                : .v2Deliverable,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: input.now,
                lastErrorCode: nil,
                terminal: .pending
            ),
            createdAt: input.now
        )
        return .queued(sampleWorkID: workID)
    }

    private func callbackInstallAuthorization(
        route: MeteringCallbackRoute,
        epoch: DeviceDailyEpoch,
        owner: UUID,
        state: DeviceEpochStoreState
    ) -> CallbackInstallAuthorization {
        let matches = state.installWork.values.filter { $0.routeID == route.routeID }
        guard matches.count == 1, let install = matches.first,
              install.ownerChildDeviceID == owner,
              install.phase == .dualActive || install.phase == .active
        else { return .discarded("install_not_exact") }

        if epoch.registeredAt != nil {
            guard install.authorization == .registered else {
                return .discarded("install_registration_mismatch")
            }
            if let handoff = state.v2RouteHandoff,
               handoff.ownerChildDeviceID == owner,
               handoff.toEpochID == epoch.epochID,
               handoff.toRouteID == route.routeID,
               !state.hasExactSuccessfulActivation(
                   owner: owner,
                   epochID: epoch.epochID,
                   routeID: route.routeID
               ) {
                return .accepted(.waitingForRegistration)
            }
            return .accepted(.v2Deliverable)
        }

        guard install.authorization == .offlinePending,
              let handoff = state.v2RouteHandoff,
              handoff.ownerChildDeviceID == owner,
              handoff.toRouteID == route.routeID,
              handoff.toEpochID == route.epochID,
              handoff.toGenerationID == route.generationID,
              handoff.phase == .dualV2 || handoff.phase == .cutoverReady,
              state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
              (state.routes[handoff.fromRouteID]?.usageDate == route.usageDate
                || state.isExactCanonicalRolloverCandidate(
                    owner: owner,
                    handoff: handoff,
                    route: route
                ))
        else { return .discarded("unregistered_route_not_candidate") }
        return .accepted(.waitingForRegistration)
    }

    func dueInstallWork(owner: UUID, now: Date) throws -> [ActivityInstallWork] {
        let state = try read()
        guard state.ownerChildDeviceID == owner else { throw DeviceEpochStoreError.ownerMismatch }
        let dueByWorkID = Dictionary(uniqueKeysWithValues: state.dueWork(now: now).map {
            ($0.workID, $0)
        })
        return state.installWork.values.filter { work in
            guard dueByWorkID[work.workID]?.kind == .install else { return false }
            switch work.phase {
            case .pendingStart, .starting, .installed:
                return true
            case .verified, .dualActive, .active, .pendingStop, .stopped:
                return false
            }
        }.sorted { lhs, rhs in
            let lhsDate = state.routes[lhs.routeID]?.usageDate ?? ""
            let rhsDate = state.routes[rhs.routeID]?.usageDate ?? ""
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            guard let lhsDue = dueByWorkID[lhs.workID],
                  let rhsDue = dueByWorkID[rhs.workID]
            else {
                return lhs.workID.uuidString.lowercased()
                    < rhs.workID.uuidString.lowercased()
            }
            if lhsDue.nextAttemptAt != rhsDue.nextAttemptAt {
                return lhsDue.nextAttemptAt < rhsDue.nextAttemptAt
            }
            if lhsDue.createdAt != rhsDue.createdAt {
                return lhsDue.createdAt < rhsDue.createdAt
            }
            return lhs.workID.uuidString.lowercased()
                < rhs.workID.uuidString.lowercased()
        }
    }

    @discardableResult
    func prepareCurrentDayInstallStartMigrationIfNeeded(
        owner: UUID,
        now: Date
    ) throws -> UUID? {
        try transaction(expectedOwner: owner) { state -> UUID? in
            guard let routeID = state.activeRouteID,
                  var route = state.routes[routeID],
                  route.ownerChildDeviceID == owner,
                  route.lifecycle == .active,
                  (route.plannedSchedule.topologyVersion ?? 0) < DatedSchedulePlan.currentTopologyVersion,
                  MeteringEpochContract.canonicalUsageDate(
                      at: now,
                      timezoneIdentifier: route.plannedSchedule.timezoneIdentifier
                  ) == route.usageDate,
                  let epoch = state.epochs[route.epochID],
                  epoch.lastRawThresholdMinutes == 0
            else { return nil }
            guard let timeZone = TimeZone(
                identifier: route.plannedSchedule.timezoneIdentifier
            ) else { return nil }
            let usageDateParts = route.usageDate.split(separator: "-").compactMap {
                Int($0)
            }
            guard usageDateParts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = timeZone
            guard let canonicalStart = calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: usageDateParts[0],
                month: usageDateParts[1],
                day: usageDateParts[2]
            )) else { return nil }
            let matchingInstallKeys = state.installWork.compactMap { key, work in
                work.routeID == routeID ? key : nil
            }
            guard matchingInstallKeys.count == 1,
                  let installKey = matchingInstallKeys.first,
                  var install = state.installWork[installKey],
                  install.phase == .active
            else { return nil }

            route.plannedSchedule = DatedSchedulePlan(
                usageDate: route.plannedSchedule.usageDate,
                timezoneIdentifier: route.plannedSchedule.timezoneIdentifier,
                calendarIdentifier: route.plannedSchedule.calendarIdentifier,
                topologyVersion: DatedSchedulePlan.currentTopologyVersion,
                // DIAGNOSTIC A/B: arm-from-now — fresh usage counts from zero so
                // the low thresholds are NOT pre-crossed at install time.
                intervalStartAt: max(now, canonicalStart)
            )
            state.routes[routeID] = route
            install.phase = .pendingStart
            install.claim = nil
            install.retry = MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: now,
                lastErrorCode: nil,
                terminal: .pending
            )
            state.installWork[installKey] = install
            return install.workID
        }
    }

    @discardableResult
    func finalizeCurrentDayInstallStartMigrationIfNeeded(owner: UUID) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard state.v2RouteHandoff == nil,
                  let routeID = state.activeRouteID,
                  let route = state.routes[routeID],
                  route.ownerChildDeviceID == owner,
                  route.lifecycle == .active,
                  route.plannedSchedule.intervalStartAt != nil
            else { return false }
            let matchingInstallKeys = state.installWork.compactMap { key, work in
                work.routeID == routeID ? key : nil
            }
            guard matchingInstallKeys.count == 1,
                  let installKey = matchingInstallKeys.first,
                  state.installWork[installKey]?.phase == .verified
            else { return false }
            state.installWork[installKey]?.phase = .active
            return true
        }
    }

    func claimInstallWork(
        workID: UUID,
        owner: UUID,
        processIdentity: MeteringProcessIdentity,
        now: Date
    ) throws -> (work: ActivityInstallWork, priorPhase: ActivityInstallPhase, claim: ActivityInstallClaim)? {
        try transaction(expectedOwner: owner) { state -> (work: ActivityInstallWork, priorPhase: ActivityInstallPhase, claim: ActivityInstallClaim)? in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  work.retry.terminal == .pending,
                  work.retry.nextAttemptAt <= now
            else { return nil }
            switch work.phase {
            case .pendingStart, .starting, .installed:
                break
            case .verified, .dualActive, .active, .pendingStop, .stopped:
                return nil
            }
            guard var route = state.routes[work.routeID],
                  state.hasCurrentInstallProvenance(
                      owner: owner,
                      route: route,
                      authorization: work.authorization
                  )
            else {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "route_superseded"
                state.installWork[key] = work
                return nil
            }
            if let claim = work.claim, claim.expiresAt > now {
                return nil
            }
            let priorPhase = work.phase
            let claim = ActivityInstallClaim(
                token: UUID(),
                process: processIdentity.role,
                instanceID: processIdentity.instanceID,
                claimedAt: now,
                expiresAt: now.addingTimeInterval(ActivityInstallClaim.leaseDuration)
            )
            work.claim = claim
            if work.phase == .pendingStart {
                work.phase = .starting
            }
            state.installWork[key] = work
            return (work, priorPhase, claim)
        }
    }

    /// Fold the progress already credited on a route into the epoch's base,
    /// immediately before that route is re-armed with Apple.
    ///
    /// Re-arming restarts the daemon's counter at zero (the events carry
    /// `includesPastActivity: false`), but the ladder keeps its rungs — so a
    /// route sitting at `lastRawThresholdMinutes = 10` needs 15 more minutes of
    /// real use before any rung can exceed what is already credited. That gap is
    /// invisible dead time: the child keeps using the device and the bar does
    /// not move. Since every policy edit, reset or repair re-arms, this is the
    /// mechanism behind "the bar froze after I changed something" (iPad
    /// 2026-07-25: three re-arms in an hour, each buying a fresh dead zone).
    ///
    /// Moving the credited minutes into `baseAcceptedMinutes` and resetting the
    /// raw high-water keeps the ledger identical — base + raw is unchanged — and
    /// makes the next rung mean "5 more minutes" again. No-op when nothing has
    /// been credited yet.
    ///
    /// BUG 1: moving the base is only half the operation. The rungs are cut over
    /// `ceiling - base`, so a base that moves without its ladder leaves every
    /// rung meaning more minutes than it did when it was armed — base 145 under
    /// a ladder cut at base 20 made the top rung report 305 minutes into a
    /// 180-minute pool (iPad 2026-07-25 13:37). The re-cut therefore happens in
    /// THIS transaction, and `route.ladderBaseMinutes` records which base the
    /// new rungs belong to. Callers must arm what the store holds AFTER this
    /// returns, not the configuration they read before it.
    /// - Parameter trigger: what caused the re-arm (`install`, `rekick`,
    ///   `policy_change`, `rollover`, …). Recorded in the flight-recorder
    ///   event so a base that jumped can be attributed to the exact re-arm
    ///   that carried it — the "bar froze after I changed something" trail.
    @discardableResult
    func absorbCreditedProgressForRearm(
        routeID: UUID,
        owner: UUID,
        trigger: String = "unspecified"
    ) throws -> Bool {
        var beforeBase = 0
        var beforeRaw = 0
        var afterBase = 0
        var absorbed = false
        var skipReason = "no_epoch"
        defer {
            MeteringFlightRecorder.emit(
                kind: .meteringRearm,
                site: "store.absorb",
                verdict: absorbed ? "absorbed" : skipReason,
                detail: MeteringFlightRecorder.detail([
                    ("trigger", trigger),
                    ("beforeBase", String(beforeBase)),
                    ("beforeRaw", String(beforeRaw)),
                    ("afterBase", String(afterBase)),
                ]),
                nums: ScreenTimeEvent.Nums(base: afterBase, raw: beforeRaw),
                corrID: routeID,
                transition: ScreenTimeEvent.Transition(
                    before: "base:\(beforeBase)+raw:\(beforeRaw)",
                    after: "base:\(afterBase)+raw:0"
                )
            )
        }
        do {
            return try transaction(expectedOwner: owner) { state in
            guard var route = state.routes[routeID],
                  route.ownerChildDeviceID == owner,
                  var epoch = state.epochs[route.epochID],
                  epoch.childDeviceID == owner
            else { return false }
            beforeBase = epoch.baseAcceptedMinutes
            beforeRaw = epoch.lastRawThresholdMinutes
            guard epoch.status == .active else {
                skipReason = "epoch_\(epoch.status.rawValue)"
                return false
            }
            guard epoch.lastRawThresholdMinutes > 0 else {
                skipReason = "nothing_credited"
                afterBase = epoch.baseAcceptedMinutes
                return false
            }
            // Raw callbacks are observations, not credits. The backend can
            // reject one as physically impossible after it has already raised
            // `lastRawThresholdMinutes`; carrying that high-water into the next
            // ladder permanently poisons the route. Only a durable succeeded
            // sample for this exact route/epoch proves the backend accepted the
            // estimate.
            let acceptedBase = state.highestDurablyAcceptedMinutes(
                owner: owner,
                epoch: epoch,
                route: route
            ) ?? epoch.baseAcceptedMinutes
            // The ladder must be re-cut for the carried base in this same
            // transaction.
            let carried: Int
            let candidateLadder: [MeteringEventPlan]?
            let physicalOffset = max(0, route.physicalGenerationOffsetMinutes ?? 0)
            if let ceiling = state.ladderCeilingMinutes(for: route) {
                // The base may never pass the day's ceiling, whatever the raw
                // high-water says. Without this the absorb COMPOUNDS: a rung of
                // a stale ladder re-populates `lastRawThresholdMinutes`, the
                // next re-arm folds it in again, and the base climbs 145 → 305
                // → 425 → 460 against a 180-minute pool (iPad 2026-07-25). The
                // re-cut is what stops those stale rungs being credited at all;
                // this is the bound that holds even if one slips through.
                carried = min(acceptedBase, ceiling)
                candidateLadder = MeteringLadderMath.plannedEvents(
                    routeID: route.routeID,
                    ladderBaseMinutes: carried,
                    ceilingMinutes: ceiling,
                    physicalGenerationOffsetMinutes: physicalOffset
                )
            } else {
                // Generation predates the pool/cap capture, so there is no
                // honest ceiling to shrink against — inventing one from the
                // current rungs would refuse absorbs the ledger has legitimately
                // passed. Keep the ladder's SPAN and only re-anchor it to the
                // carried base; the invariant that matters (a rung means
                // `ladderBase + T`) still holds, and the report path simply
                // claims no clamp it cannot justify.
                carried = acceptedBase
                candidateLadder = MeteringLadderMath.plannedEvents(
                    routeID: route.routeID,
                    ladderBaseMinutes: 0,
                    ceilingMinutes: max(
                        0,
                        (route.plannedEvents.map(\.thresholdMinutes).max() ?? 0)
                            - physicalOffset
                    ),
                    physicalGenerationOffsetMinutes: physicalOffset
                )
            }
            guard let recut = candidateLadder else {
                // Nothing left above the carried base: absorbing here would
                // raise the base under a ladder that can no longer be re-cut,
                // which is exactly the state BUG 1 produced. Leave the ledger
                // untouched; the day is over and the terminal rung owns it.
                skipReason = "no_remaining"
                afterBase = epoch.baseAcceptedMinutes
                return false
            }
            route.plannedEvents = recut
            route.ladderBaseMinutes = carried
            state.routes[route.routeID] = route
            afterBase = carried
            absorbed = true
            state.epochs[epoch.epochID] = DeviceDailyEpoch(
                epochID: epoch.epochID,
                protocolVersion: epoch.protocolVersion,
                childDeviceID: epoch.childDeviceID,
                usageDate: epoch.usageDate,
                canonicalTimezone: epoch.canonicalTimezone,
                policyRevision: epoch.policyRevision,
                measurementSelectionDigest: epoch.measurementSelectionDigest,
                enforcementSetID: epoch.enforcementSetID,
                startedAt: epoch.startedAt,
                registeredAt: epoch.registeredAt,
                baseAcceptedMinutes: carried,
                baseSource: epoch.baseSource,
                lastRawThresholdMinutes: physicalOffset,
                // Zeroed together with the raw high-water: the paused minutes it
                // recorded were measured on the raw scale that just collapsed
                // into the base, so keeping it would subtract them twice.
                excludedWhilePausedMinutes: physicalOffset,
                status: epoch.status,
                resumeBoundaryPending: epoch.resumeBoundaryPending,
                retiredAt: epoch.retiredAt,
                retireReason: epoch.retireReason,
                exhaustedAt: epoch.exhaustedAt,
                baseCorrectionState: epoch.baseCorrectionState,
                authoritativeBaseConflict: epoch.authoritativeBaseConflict
            )
            return true
            }
        } catch {
            // A failed absorb is worse than a no-op: the caller re-arms anyway
            // and the child then loses `beforeRaw` minutes of dead time.
            absorbed = false
            skipReason = "tx_error"
            MeteringFlightRecorder.emitError(
                site: "store.absorb",
                error: error,
                detail: MeteringFlightRecorder.detail([("trigger", trigger)]),
                corrID: routeID
            )
            throw error
        }
    }

    /// Self-heal for devices already carrying a base/ladder split (BUG 1).
    ///
    /// The iPad this was found on holds `base=145` under a ladder cut at base 20
    /// whose top rung is 160 — `145 + 160 = 305` against a 180-minute pool. That
    /// state cannot repair itself: nothing re-cuts a ladder once it is planned,
    /// so every rung Apple still holds keeps over-reporting until midnight, and
    /// each further re-arm folds a stale rung back in (145 → 305 → 425 → 460).
    /// This runs on every recovery pass, detects the three ways the invariant
    /// can be broken, and re-cuts today's ladder against the epoch's real
    /// ledger — bounded by the pool, which is what pulls a compounded base back.
    ///
    /// Detection is deliberately not "`ladderBaseMinutes == nil`": routes
    /// persisted before that field are the majority and most of them are
    /// perfectly consistent. A route is only rewritten when its ladder can
    /// actually over-run the day (`ladderBase + topRung > ceiling`), when it
    /// records a base its epoch no longer agrees with, or when the base has
    /// already climbed past the whole pool.
    ///
    /// The install work is pushed back to `pendingStart` so the installer arms
    /// the corrected ladder — leaving Apple holding rungs the store has re-cut
    /// away would be a milder version of the same bug.
    @discardableResult
    func repairLadderBaseInvariantIfNeeded(owner: UUID, now: Date) throws -> Bool {
        try replaceActiveRouteIfNeeded(
            owner: owner,
            daemonMissingRouteID: nil,
            now: now
        )
    }

    /// Replaces an active logical route that Apple's daemon no longer holds.
    ///
    /// Re-registering the same activity/event names is not recovery: threshold
    /// callbacks and sample work IDs are deterministic, so accepted rungs are
    /// consumed forever under that physical identity. Use the same proven
    /// make-before-break transition as ladder repair, preserving the durable
    /// ledger while minting fresh activity and event names.
    @discardableResult
    func replaceMissingActiveRouteIfNeeded(
        owner: UUID,
        missingRouteID: UUID,
        now: Date
    ) throws -> Bool {
        try replaceActiveRouteIfNeeded(
            owner: owner,
            daemonMissingRouteID: missingRouteID,
            now: now
        )
    }

    private func replaceActiveRouteIfNeeded(
        owner: UUID,
        daemonMissingRouteID: UUID?,
        now: Date
    ) throws -> Bool {
        var verdict = "consistent"
        var beforeSummary = ""
        var afterSummary = ""
        var repairedRouteID: UUID?
        defer {
            if verdict != "consistent" {
            MeteringFlightRecorder.emit(
                kind: .meteringRepair,
                site: "store.ladderRepair",
                verdict: verdict,
                detail: MeteringFlightRecorder.detail([
                    ("route", MeteringFlightRecorder.shortID(repairedRouteID)),
                ]),
                corrID: repairedRouteID,
                transition: ScreenTimeEvent.Transition(
                    before: beforeSummary,
                    after: afterSummary
                )
            )
            }
        }
        var consumedCandidateWasAbandoned = false
        if try transaction(expectedOwner: owner, { state in
            let recovered = state.replaceConsumedHandoffCandidateIfNeeded(
                owner: owner,
                now: now
            )
            if recovered {
                consumedCandidateWasAbandoned = state.v2RouteHandoff == nil
            }
            return recovered
        }) {
            verdict = consumedCandidateWasAbandoned
                ? "consumed_candidate_abandoned"
                : "replacement_consumed_handoff_candidate"
            return true
        }

        return try transaction(expectedOwner: owner) { state in
            guard state.v2RouteHandoff == nil,
                  let routeID = state.activeRouteID,
                  var route = state.routes[routeID],
                  route.ownerChildDeviceID == owner,
                  route.lifecycle == .active,
                  var epoch = state.epochs[route.epochID],
                  epoch.childDeviceID == owner,
                  epoch.status == .active,
                  epoch.retiredAt == nil,
                  epoch.authoritativeBaseConflict == nil,
                  let ceiling = state.ladderCeilingMinutes(for: route),
                  let topRung = route.plannedEvents.map(\.thresholdMinutes).max()
            else { return false }

            let ladderBase = state.ladderBaseMinutes(for: route)
            let routeOffset = max(0, route.physicalGenerationOffsetMinutes ?? 0)
            let logicalTopRung = max(0, topRung - routeOffset)
            let overrunsPool = ladderBase + logicalTopRung > ceiling
            let disagreesWithEpoch = route.ladderBaseMinutes != epoch.baseAcceptedMinutes
            // A base that has already climbed past the whole pool is the
            // compounded form of the same split (iPad: base 460 against a
            // 180-minute pool) and must be pulled back even if the ladder alone
            // happens to look plausible.
            let baseExceedsPool = epoch.baseAcceptedMinutes > ceiling
            let durablyAccepted = state.highestDurablyAcceptedMinutes(
                owner: owner,
                epoch: epoch,
                route: route
            )
            let routeInstallRows = state.installWork.values.filter {
                $0.routeID == routeID
            }
            // The old repair re-armed the same physical activity after some of
            // its one-shot event names had already produced accepted samples.
            // Its install marker survives even after the numbers become
            // perfectly consistent, making this an exact persisted diagnosis
            // rather than a timeout or timestamp heuristic.
            let reusedPhysicalIdentityAfterInPlaceRepair =
                routeInstallRows.count == 1
                && routeInstallRows[0].retry.lastErrorCode == "ladder_base_repaired"
                && state.sampleWork.values.contains {
                    $0.routeID == routeID && $0.retry.terminal == .succeeded
                }
            let physicalEventsConsumedTooEarly =
                routeInstallRows.count == 1
                && routeInstallRows[0].retry.lastErrorCode
                    == "physical_events_consumed_too_early"
            let armCalibrationRequiresOffsetRecut =
                routeInstallRows.count == 1
                && routeInstallRows[0].retry.lastErrorCode
                    == "arm_grace_calibration_requires_offset_recut"
            let daemonLostActiveRoute = daemonMissingRouteID == routeID
            // An arm-time burst absorbed by the FIX-Q grace path raises the
            // exclusion high-water without a death stamp. When it swallows the
            // TOP rung, every armed one-shot has already fired and no future
            // bell can ever credit (`max(0, raw - excluded)` is pinned to 0) —
            // the ladder is deaf while all six triggers above read healthy
            // (iPad 2026-08-06 00:03: 21 bells absorbed in 3s up to t40 = the
            // terminal rung; the bar never moved again). Re-cut it here: the
            // fresh ladder is based at the durably accepted value, so its
            // rungs sit above Apple's day counter and survive the re-arm.
            let exclusionSwallowedWholeLadder =
                max(0, epoch.excludedWhilePausedMinutes - routeOffset) >= logicalTopRung
                && logicalTopRung > 0
            // A poisoned base can be internally self-consistent: the affected
            // iPad held base=225, ladderBase=225 and rungs 5/10/15 under a
            // 240-minute ceiling. Only the succeeded backend work proves that
            // 100, not 225, was the last accepted value.
            // A successful rung advances the durable estimate while the
            // ladder base intentionally stays fixed. Comparing the backend
            // evidence with the base alone made every accepted t5/t10/... look
            // like corruption and minted a fresh physical route after each
            // callback. Compare like with like: the estimate represented by
            // this exact ladder base and its current accepted raw high-water.
            let projectedAccepted = min(
                ladderBase + max(
                    0,
                    epoch.lastRawThresholdMinutes - epoch.excludedWhilePausedMinutes
                ),
                ceiling
            )
            // Recovery reaches this check before it drains network work. A raw
            // rung with pending sample work has not been rejected; comparing it
            // with the last durable value would manufacture an identity change
            // during every normal callback/upload race (and indefinitely while
            // offline). Defer only this authority check until the sample reaches
            // a terminal verdict. Structural ladder violations still repair.
            let hasUnsettledSampleEvidence = state.sampleWork.values.contains {
                $0.ownerChildDeviceID == owner
                    && $0.epochID == epoch.epochID
                    && $0.routeID == route.routeID
                    && $0.retry.terminal == .pending
            }
            let disagreesWithDurableAuthority = durablyAccepted.map {
                !hasUnsettledSampleEvidence && $0 != projectedAccepted
            } ?? false
            guard overrunsPool
                    || disagreesWithEpoch
                    || baseExceedsPool
                    || disagreesWithDurableAuthority
                    || reusedPhysicalIdentityAfterInPlaceRepair
                    || physicalEventsConsumedTooEarly
                    || armCalibrationRequiresOffsetRecut
                    || exclusionSwallowedWholeLadder
                    || daemonLostActiveRoute
            else { return false }

            // Already clamped as far as this repair can go — do not re-run.
            //
            // The exhausted branch below cannot clear its own trigger: it leaves
            // the stale rungs armed on purpose, so `overrunsPool` stays true and
            // the next recovery pass repairs the identical state again. Measured
            // on the iPad 2026-07-25: 45 identical `clamped_exhausted` records in
            // three minutes, every one with `before == after`. Harmless to the
            // ledger, but it is a no-op loop that burns the pass and drowns the
            // flight recorder (repair events carry a transition, so the recorder
            // deliberately never suppresses them).
            //
            // Deliberately NOT a permanent flag: the guard reads live values, so
            // a later pool increase raises `ceiling`, a cut becomes possible
            // again, and the real repair runs on the very next pass.
            let alreadyClampedAtCeiling = epoch.baseAcceptedMinutes == ceiling
                && route.ladderBaseMinutes == ceiling
                && epoch.lastRawThresholdMinutes == 0
                && epoch.excludedWhilePausedMinutes == 0
            if alreadyClampedAtCeiling { return false }

            repairedRouteID = routeID
            beforeSummary = "base:\(epoch.baseAcceptedMinutes)"
                + "+raw:\(epoch.lastRawThresholdMinutes)"
                + "/ladder:\(ladderBase)+\(topRung)"

            // Re-cut from the highest value durably accepted by the backend.
            // `lastRawThresholdMinutes` is only an observation: it may belong to
            // a sample the backend rejected as physically impossible. Using it
            // here reintroduced the same poison during cold-start recovery that
            // `absorbCreditedProgressForRearm` had just removed.
            let accepted = durablyAccepted ?? epoch.baseAcceptedMinutes
            let ledger = min(accepted, ceiling)
            let candidateOffset = armCalibrationRequiresOffsetRecut
                ? max(routeOffset, epoch.excludedWhilePausedMinutes)
                : routeOffset
            let candidateEpochID = UUID()
            let candidateRouteID = UUID()
            let candidateInstallID = UUID()
            guard let candidateEvents = MeteringLadderMath.plannedEvents(
                routeID: candidateRouteID,
                ladderBaseMinutes: ledger,
                ceilingMinutes: ceiling,
                physicalGenerationOffsetMinutes: candidateOffset
            ) else {
                // The pool is spent: there is nothing left to cut, so the rungs
                // Apple still holds stay armed. They can no longer over-report —
                // `ladderBaseMinutes` now equals the ceiling and the callback
                // clamp bounds the total — and the terminal rung still locks.
                state.epochs[epoch.epochID] = DeviceDailyEpoch(
                    epochID: epoch.epochID,
                    protocolVersion: epoch.protocolVersion,
                    childDeviceID: epoch.childDeviceID,
                    usageDate: epoch.usageDate,
                    canonicalTimezone: epoch.canonicalTimezone,
                    policyRevision: epoch.policyRevision,
                    measurementSelectionDigest: epoch.measurementSelectionDigest,
                    enforcementSetID: epoch.enforcementSetID,
                    startedAt: epoch.startedAt,
                    registeredAt: epoch.registeredAt,
                    baseAcceptedMinutes: ledger,
                    baseSource: epoch.baseSource,
                    lastRawThresholdMinutes: 0,
                    excludedWhilePausedMinutes: 0,
                    status: epoch.status,
                    resumeBoundaryPending: epoch.resumeBoundaryPending,
                    retiredAt: epoch.retiredAt,
                    retireReason: epoch.retireReason,
                    exhaustedAt: epoch.exhaustedAt,
                    baseCorrectionState: epoch.baseCorrectionState,
                    authoritativeBaseConflict: epoch.authoritativeBaseConflict
                )
                route.ladderBaseMinutes = ledger
                state.routes[routeID] = route
                verdict = "clamped_exhausted"
                afterSummary = "base:\(ledger)+raw:0/ceiling:\(ceiling)"
                return true
            }

            guard let generation = state.generations[route.generationID] else {
                return false
            }

            // DeviceActivity threshold events are one-shot under their
            // activity/event names. Re-installing a corrected ladder on this
            // same route can read back perfectly while every new rung has
            // already fired earlier in the day. Mint a fresh physical identity
            // and let the existing make-before-break barrier prove it before
            // retiring the route that is still authoritative.
            let priorInstallKeys = state.installWork.compactMap { key, work in
                work.routeID == routeID ? key : nil
            }
            guard priorInstallKeys.count == 1,
                  let priorInstallKey = priorInstallKeys.first
            else { return false }
            if state.installWork[priorInstallKey]?.phase == .verified {
                // Older recovery code could verify the daemon readback after
                // the route had already become the logical active route without
                // promoting its install row. Normalize that persisted split so
                // the cutover barrier can later prove and retire this exact row.
                state.installWork[priorInstallKey]?.phase = .active
                state.installWork[priorInstallKey]?.claim = nil
                state.installWork[priorInstallKey]?.retry.terminal = .succeeded
            }
            let candidateEpoch = DeviceDailyEpoch(
                epochID: candidateEpochID,
                protocolVersion: epoch.protocolVersion,
                childDeviceID: epoch.childDeviceID,
                usageDate: epoch.usageDate,
                canonicalTimezone: epoch.canonicalTimezone,
                policyRevision: epoch.policyRevision,
                measurementSelectionDigest: epoch.measurementSelectionDigest,
                enforcementSetID: epoch.enforcementSetID,
                startedAt: now,
                registeredAt: nil,
                baseAcceptedMinutes: ledger,
                baseSource: .childState200,
                lastRawThresholdMinutes: candidateOffset,
                excludedWhilePausedMinutes: candidateOffset,
                status: .active,
                resumeBoundaryPending: false,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            let candidateRoute = MeteringCallbackRoute(
                routeID: candidateRouteID,
                activityName: "evlin.earned.v2.\(candidateRouteID.uuidString.lowercased())",
                namespace: "evlin.earned.v2.",
                generationID: generation.generationID,
                generationKey: route.generationKey,
                ownerChildDeviceID: owner,
                usageDate: route.usageDate,
                epochID: candidateEpochID,
                plannedSchedule: DatedSchedulePlan(
                    usageDate: route.plannedSchedule.usageDate,
                    timezoneIdentifier: route.plannedSchedule.timezoneIdentifier,
                    calendarIdentifier: route.plannedSchedule.calendarIdentifier,
                    topologyVersion: DatedSchedulePlan.currentTopologyVersion,
                    intervalStartAt: now
                ),
                installedSchedule: nil,
                plannedEvents: candidateEvents,
                installedEvents: nil,
                lifecycle: .planned,
                createdAt: now,
                ladderBaseMinutes: ledger,
                physicalGenerationOffsetMinutes: candidateOffset
            )
            state.epochs[candidateEpochID] = candidateEpoch
            state.routes[candidateRouteID] = candidateRoute
            state.installWork[candidateInstallID] = ActivityInstallWork(
                workID: candidateInstallID,
                ownerChildDeviceID: owner,
                routeID: candidateRouteID,
                authorization: .offlinePending,
                phase: .pendingStart,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastErrorCode: "physical_identity_repaired",
                    terminal: .pending
                ),
                createdAt: now
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: owner,
                fromGenerationID: route.generationID,
                fromEpochID: epoch.epochID,
                fromRouteID: route.routeID,
                toGenerationID: generation.generationID,
                toEpochID: candidateEpochID,
                toRouteID: candidateRouteID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: now,
                explicitRecovery: .identityRecovery
            )
            if daemonLostActiveRoute {
                verdict = "replacement_daemon_missing"
            } else if reusedPhysicalIdentityAfterInPlaceRepair {
                verdict = "replacement_reused_identity"
            } else if physicalEventsConsumedTooEarly {
                verdict = "replacement_consumed_events"
            } else if armCalibrationRequiresOffsetRecut {
                verdict = "replacement_arm_calibration_offset"
            } else {
                verdict = overrunsPool || baseExceedsPool
                    ? "replacement_overrun"
                    : "replacement_desync"
            }
            afterSummary = "base:\(ledger)+raw:\(candidateOffset)"
                + "/route:\(candidateRouteID.uuidString.lowercased())"
                + "/offset:\(candidateOffset)"
                + "/ladder:\(ledger)+\(candidateEvents.map(\.thresholdMinutes).max() ?? 0)"
            return true
        }
    }

    func recordInstalledRoute(workID: UUID, token: UUID, owner: UUID, now: Date) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  let claim = work.claim,
                  claim.token == token,
                  claim.expiresAt > now
            else { return false }
            guard let route = state.routes[work.routeID],
                  state.hasCurrentInstallProvenance(
                      owner: owner,
                      route: route,
                      authorization: work.authorization
                  )
            else {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "route_superseded"
                state.installWork[key] = work
                return false
            }
            work.phase = .installed
            state.installWork[key] = work
            state.routes[route.routeID]?.installedSchedule = route.plannedSchedule
            state.routes[route.routeID]?.installedEvents = route.plannedEvents
            return true
        }
    }

    @discardableResult
    func reconcileEpochStartsFromSuccessfulRegistrations(owner: UUID) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            var changed = false
            for work in state.registrationWork.values
            where work.ownerChildDeviceID == owner && work.retry.terminal == .succeeded {
                changed = state.reconcileEpochStartFromSuccessfulRegistration(work) || changed
            }
            return changed
        }
    }

    func recordVerifiedRoute(workID: UUID, token: UUID, owner: UUID, now: Date) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  let claim = work.claim,
                  claim.token == token,
                  claim.expiresAt > now
            else { return false }
            guard let route = state.routes[work.routeID],
                  state.hasCurrentInstallProvenance(
                      owner: owner,
                      route: route,
                      authorization: work.authorization
                  )
            else {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "route_superseded"
                state.installWork[key] = work
                return false
            }
            work.phase = .verified
            work.claim = nil
            state.installWork[key] = work
            state.routes[route.routeID]?.installedSchedule = route.plannedSchedule
            state.routes[route.routeID]?.installedEvents = route.plannedEvents
            return true
        }
    }

    func deferInstallWork(
        workID: UUID,
        token: UUID,
        owner: UUID,
        now: Date,
        code: String,
        installLimited: Bool
    ) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  let claim = work.claim,
                  claim.token == token,
                  claim.expiresAt > now
            else { return false }
            guard let failedRoute = state.routes[work.routeID],
                  state.hasCurrentInstallProvenance(
                      owner: owner,
                      route: failedRoute,
                      authorization: work.authorization
                  )
            else {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "route_superseded"
                state.installWork[key] = work
                return false
            }
            work.phase = .pendingStart
            work.claim = nil
            work.retry.attemptCount += 1
            work.retry.nextAttemptAt = MeteringRetryPolicy.nextAttempt(after: work.retry.attemptCount, now: now)
            work.retry.lastErrorCode = code
            state.installWork[key] = work
            if installLimited {
                let horizonUsageDates = state.currentHorizonUsageDates(
                    owner: owner,
                    generationID: failedRoute.generationID
                )
                let routes = state.routes.values.filter {
                    $0.ownerChildDeviceID == owner
                        && $0.generationID == failedRoute.generationID
                        && horizonUsageDates.contains($0.usageDate)
                        && state.hasEligibleRouteEpochGeneration(
                            owner: owner,
                            route: $0,
                            epoch: state.epochs[$0.epochID],
                            generation: state.generations[$0.generationID]
                        )
                }
                guard let first = horizonUsageDates.first, let last = horizonUsageDates.last else { return true }
                let functioningRouteIDs = Set(state.installWork.values.compactMap { work -> UUID? in
                    switch work.phase {
                    case .verified, .dualActive, .active:
                        return work.routeID
                    case .pendingStart, .starting, .installed, .pendingStop, .stopped:
                        return nil
                    }
                })
                var coverage = MonitorCoverageState(
                    ownerChildDeviceID: owner,
                    requiredFromUsageDate: first,
                    requiredThroughUsageDate: last,
                    readyThroughUsageDate: nil,
                    status: .installLimited,
                    refreshedAt: now,
                    errorCode: code
                )
                let coveredDates = Set(routes.compactMap { route -> String? in
                    guard functioningRouteIDs.contains(route.routeID) else { return nil }
                    return route.usageDate
                })
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                guard let firstRequiredDate = formatter.date(from: coverage.requiredFromUsageDate),
                      let lastRequiredDate = formatter.date(from: coverage.requiredThroughUsageDate)
                else { return true }
                var date = firstRequiredDate
                var readyThrough: String?
                while date <= lastRequiredDate {
                    let usageDate = formatter.string(from: date)
                    guard coveredDates.contains(usageDate) else { break }
                    readyThrough = usageDate
                    guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                    date = next
                }
                coverage.readyThroughUsageDate = readyThrough
                coverage.status = .installLimited
                coverage.refreshedAt = now
                coverage.errorCode = code
                state.coverage = coverage
            }
            return true
        }
    }

    func supersedeInstallWork(workID: UUID, token: UUID, owner: UUID, now: Date) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  let claim = work.claim,
                  claim.token == token,
                  claim.expiresAt > now
            else { return false }
            work.claim = nil
            work.retry.terminal = .superseded
            work.retry.lastErrorCode = "route_superseded"
            state.installWork[key] = work
            return true
        }
    }

    /// Permanently removes a route that Apple may have installed but that never
    /// advanced beyond `.planned` after its measurement window opened.
    ///
    /// Stopping only the daemon activity is insufficient: its still-pending
    /// install work can start the same dead route again later in the same
    /// recovery pass. This transition retires the unusable physical identity and
    /// all of its work atomically. The existing horizon planner can then mint a
    /// fresh route for the same policy generation and usage date.
    @discardableResult
    func retireStuckPlannedRoute(
        routeID: UUID,
        owner: UUID,
        now: Date
    ) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard var route = state.routes[routeID],
                  route.ownerChildDeviceID == owner,
                  route.lifecycle == .planned,
                  routeID != state.activeRouteID,
                  state.v2RouteHandoff.map({
                      $0.fromRouteID == routeID || $0.toRouteID == routeID
                  }) != true,
                  state.rolloverEffectsWork.map({
                      $0.oldRouteID == routeID || $0.newRouteID == routeID
                  }) != true,
                  var epoch = state.epochs[route.epochID],
                  epoch.childDeviceID == owner,
                  epoch.status == .active,
                  epoch.retiredAt == nil,
                  let dayEnd = state.canonicalDayEnd(
                      usageDate: route.usageDate,
                      timeZoneIdentifier: epoch.canonicalTimezone
                  )
            else { return false }

            let installKeys = state.installWork.compactMap { key, work in
                work.ownerChildDeviceID == owner && work.routeID == routeID ? key : nil
            }
            guard installKeys.count == 1,
                  let installKey = installKeys.first,
                  var install = state.installWork[installKey]
            else {
                return false
            }

            let hadSuccessfulRegistration = state.registrationWork.values.contains {
                $0.ownerChildDeviceID == owner
                    && $0.epochID == route.epochID
                    && $0.routeID == routeID
                    && $0.retry.terminal == .succeeded
            }
            let isCurrentCanonicalDay = MeteringEpochContract.canonicalUsageDate(
                at: now,
                timezoneIdentifier: epoch.canonicalTimezone
            ) == route.usageDate

            let relatedWorkIDs = Set(
                state.registrationWork.values.filter {
                    $0.ownerChildDeviceID == owner && $0.routeID == routeID
                }.map(\.workID)
                    + state.activationWork.values.filter {
                        $0.ownerChildDeviceID == owner && $0.routeID == routeID
                    }.map(\.workID)
                    + state.sampleWork.values.filter {
                        $0.ownerChildDeviceID == owner && $0.routeID == routeID
                    }.map(\.workID)
                    + [install.workID]
            )

            epoch.status = .retired
            epoch.retiredAt = now
            epoch.retireReason = .coverageExpired
            state.epochs[epoch.epochID] = epoch

            route.lifecycle = .tombstoned
            state.routes[routeID] = route
            state.tombstones[routeID] = MeteringRouteTombstone(
                routeID: routeID,
                activityName: route.activityName,
                eventNames: route.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: route.usageDate,
                epochID: route.epochID,
                generationID: route.generationID,
                canonicalDayEnd: dayEnd,
                stopAcknowledgedAt: nil,
                referencedWorkIDs: relatedWorkIDs,
                retainedUntil: nil
            )

            for (key, var work) in state.registrationWork
            where work.ownerChildDeviceID == owner
                && work.routeID == routeID
                && work.retry.terminal == .pending {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "stuck_planned_route"
                state.registrationWork[key] = work
            }
            for (key, var work) in state.activationWork
            where work.ownerChildDeviceID == owner
                && work.routeID == routeID
                && work.retry.terminal == .pending {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "stuck_planned_route"
                state.activationWork[key] = work
            }
            for (key, var work) in state.sampleWork
            where work.ownerChildDeviceID == owner
                && work.routeID == routeID
                && work.retry.terminal == .pending {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "stuck_planned_route"
                state.sampleWork[key] = work
            }
            install.claim = nil
            install.phase = .pendingStop
            install.retry.terminal = .superseded
            install.retry.lastErrorCode = "stuck_planned_route"
            state.installWork[installKey] = install
            state.deferredCallbacks = state.deferredCallbacks.filter {
                $0.value.routeID != routeID
            }
            if state.activeEpochID == epoch.epochID {
                state.activeEpochID = nil
            }
            if hadSuccessfulRegistration,
               isCurrentCanonicalDay,
               state.pendingRegistrationRecovery == nil {
                // The backend has already accepted this immutable epoch key.
                // Its replacement is a new physical identity, not an initial
                // registration. Reuse the durable recovery-reason channel so
                // the next horizon cannot be rejected as an illegal duplicate.
                state.pendingRegistrationRecovery = .identityRecovery
            }
            return true
        }
    }

    @discardableResult
    /// True when this route's registration has already FAILED terminally — the
    /// backend rejected it (409) and nothing will retry it. The install is then
    /// waiting on an event that can never arrive.
    ///
    /// Without this the two halves deadlock: the installer defers forever on
    /// `registrationRequired` while the registration work sits `.rejected`, so
    /// the device holds no armed route, every threshold that fires has no epoch
    /// to bill, and the pool freezes while each surface still looks healthy.
    /// Observed three times with three different 409 reasons
    /// (`replacement_reason_mismatch` 08-04, `policy_revision_mismatch` and
    /// `gate_resume_requires_paused_predecessor` 08-07) — the rejection reason
    /// is irrelevant, the deadlock is structural.
    nonisolated static func hasTerminallyFailedRegistration(
        _ state: DeviceEpochStoreState,
        owner: UUID,
        routeID: UUID
    ) -> Bool {
        state.registrationWork.values.contains {
            $0.ownerChildDeviceID == owner
                && $0.routeID == routeID
                && $0.retry.terminal == .rejected
        }
    }

    func supersedeUnprovenRegistrationRequiredInstall(
        workID: UUID,
        owner: UUID,
        now: Date
    ) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  work.ownerChildDeviceID == owner,
                  work.authorization == .registrationRequired,
                  work.phase == .pendingStart,
                  work.retry.terminal == .pending,
                  let route = state.routes[work.routeID]
            else { return false }

            // Registration is dead → this install can never proceed. Retire the
            // route so the next recovery pass re-paves a fresh one, instead of
            // deferring once a minute forever.
            if Self.hasTerminallyFailedRegistration(state, owner: owner, routeID: route.routeID) {
                work.claim = nil
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "registration_rejected"
                state.installWork[key] = work
                state.routes[route.routeID]?.lifecycle = .tombstoned
                if state.activeRouteID == route.routeID {
                    state.activeRouteID = nil
                }
                return true
            }

            guard var generation = state.generations[route.generationID],
                  generation.generationID != state.activeGenerationID,
                  !state.isNewestDesiredPolicyGeneration(
                      owner: owner,
                      generationID: generation.generationID
                  ),
                  !state.hasCurrentInstallProvenance(
                      owner: owner,
                      route: route,
                      authorization: work.authorization
                  )
            else { return false }
            work.claim = nil
            work.retry.terminal = .superseded
            work.retry.lastErrorCode = "route_superseded"
            state.installWork[key] = work
            generation.retiredAt = generation.retiredAt ?? now
            state.generations[generation.generationID] = generation
            return true
        }
    }

    @discardableResult
    func claimFirstNetworkWork(
        owner: UUID,
        now: Date,
        isEligible: (DeviceEpochStoreState, MeteringDueWork) -> Bool
    ) throws -> MeteringClaimedNetworkWork? {
        try transaction(expectedOwner: owner) { state in
            let dueWork = state.dueWork(now: now)
            guard let first = dueWork.first else { return nil }
            func onlyReadyInstallEnvelopesPrecede(_ item: MeteringDueWork) -> Bool {
                guard let candidateIndex = dueWork.firstIndex(where: {
                    $0.workID == item.workID
                }) else { return false }
                return dueWork[..<candidateIndex].allSatisfy { preceding in
                    guard preceding.kind == .install,
                          let install = state.installWork.values.first(where: {
                              $0.workID == preceding.workID
                          }),
                          install.ownerChildDeviceID == owner
                    else { return false }
                    switch install.phase {
                    // .stopped is a churn husk: its daemon mutation is over and it
                    // will never perform network work, so it cannot invalidate a
                    // sample behind it. Treating it as blocking starved the sample
                    // queue forever after any replacement (49 envelopes, 6 stopped
                    // → t10 sample attemptCount=0 for hours, 2026-07-24).
                    case .verified, .dualActive, .active, .stopped:
                        return true
                    case .pendingStart:
                        // Future horizon coverage is best-effort and may wait for
                        // DeviceActivity capacity. It is unrelated to the exact
                        // current route whose network work is already authorized,
                        // so it must not strand that route's activation or samples.
                        //
                        // `registrationRequired` is the same story with a
                        // different label: that install is itself blocked waiting
                        // for ITS OWN registration, so it can never perform the
                        // daemon mutation this ordering rule exists to protect.
                        // Treating it as blocking is head-of-line starvation —
                        // it sat at the head deferring once a minute while the
                        // CURRENT route's activation never got a single attempt,
                        // so the cutover hung in `cutoverReady`, the retired
                        // epoch kept receiving the bells, and the pool froze
                        // (2026-08-07; same shape as the 07-24 sample starvation
                        // this switch already documents).
                        return install.authorization == .futurePlanned
                            || install.authorization == .registrationRequired
                    case .starting, .installed:
                        // A future-horizon daemon install can outlive the short
                        // NSE recovery window. It must not hold the already
                        // authorized current route's activation behind its
                        // install claim; activation is a network acknowledgement
                        // and does not mutate DeviceActivityCenter state.
                        return item.kind == .activation
                            && install.authorization == .futurePlanned
                    case .pendingStop:
                        return false
                    }
                }
            }
            let due: MeteringDueWork
            if isEligible(state, first) {
                due = first
            } else if first.kind == .install,
                      let networkChild = dueWork.dropFirst().first(where: { item in
                          guard isEligible(state, item) else { return false }
                          switch item.kind {
                          case .registration:
                              return true
                          case .sample:
                              guard let sample = state.sampleWork.values.first(where: {
                                  $0.workID == item.workID
                              }) else { return false }
                              if sample.authorization == .legacyDeliverable { return true }
                              return sample.authorization == .v2Deliverable
                                  && onlyReadyInstallEnvelopesPrecede(item)
                          case .activation:
                              return onlyReadyInstallEnvelopesPrecede(item)
                          case .identityCleanup, .rollover, .install, .shield:
                              return false
                          }
                      }) {
                // Installation is local work. It must not strand registration
                // or the v1 lane that keeps accounting alive during cutover.
                due = networkChild
            } else if first.kind == .rollover,
                      let rollover = state.rolloverEffectsWork,
                      rollover.workID == first.workID,
                      rollover.retry.terminal == .pending,
                      let handoff = state.v2RouteHandoff,
                      handoff.handoffID == rollover.workID,
                      handoff.ownerChildDeviceID == owner,
                      let childWork = dueWork.dropFirst().first(where: { item in
                          guard isEligible(state, item) else { return false }
                          switch item.kind {
                          case .registration:
                              return state.registrationWork.values.contains {
                                  $0.workID == item.workID
                                      && $0.epochID == rollover.newEpochID
                                      && $0.routeID == rollover.newRouteID
                              }
                          case .activation:
                              return state.activationWork.values.contains {
                                  $0.workID == item.workID
                                      && $0.epochID == rollover.newEpochID
                                      && $0.routeID == rollover.newRouteID
                              }
                          case .sample:
                              return handoff.phase == .dualV2
                                  && state.sampleWork.values.contains {
                                      $0.workID == item.workID
                                          && $0.epochID == rollover.oldEpochID
                                          && $0.routeID == rollover.oldRouteID
                                  }
                          case .identityCleanup, .rollover, .install, .shield:
                              return false
                          }
                      })
            {
                // Rollover remains the controlling highest-priority envelope;
                // only its exact old-route drain and new-route network children
                // may pass it.
                due = childWork
            } else {
                guard let handoff = state.v2RouteHandoff,
                      handoff.ownerChildDeviceID == owner,
                      handoff.phase == .cutoverReady,
                      state.activeGenerationID == handoff.fromGenerationID,
                      state.activeEpochID == handoff.fromEpochID,
                      state.activeRouteID == handoff.fromRouteID,
                      state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
                      let candidateRoute = state.routes[handoff.toRouteID],
                      candidateRoute.ownerChildDeviceID == owner,
                      candidateRoute.generationID == handoff.toGenerationID,
                      candidateRoute.epochID == handoff.toEpochID,
                      let candidateEpoch = state.epochs[handoff.toEpochID],
                      candidateEpoch.childDeviceID == owner,
                      candidateEpoch.authoritativeBaseConflict == nil,
                      isAuthorizedBarrierCandidate(
                          handoff: handoff,
                          candidateEpoch: candidateEpoch,
                          state: state
                      ),
                      let candidateIndex = dueWork.firstIndex(where: { item in
                          switch item.kind {
                          case .registration:
                              return state.registrationWork.values.contains {
                                  $0.workID == item.workID
                                      && $0.ownerChildDeviceID == owner
                                      && $0.epochID == handoff.toEpochID
                                      && $0.routeID == handoff.toRouteID
                              }
                          case .activation:
                              return state.activationWork.values.contains {
                                  $0.workID == item.workID
                                      && $0.ownerChildDeviceID == owner
                                      && $0.epochID == handoff.toEpochID
                                      && $0.routeID == handoff.toRouteID
                              }
                          case .identityCleanup, .rollover, .install, .sample, .shield:
                              return false
                          }
                      }),
                      dueWork[..<candidateIndex].allSatisfy({ item in
                          guard item.kind == .install,
                                let install = state.installWork.values.first(where: { $0.workID == item.workID }),
                                install.ownerChildDeviceID == owner
                          else { return false }
                          switch install.phase {
                          case .verified, .dualActive, .active:
                              return true
                          case .stopped:
                              return install.routeID == handoff.fromRouteID
                                  && state.hasExactStaleDayPriorAbsent(owner: owner, handoff: handoff)
                          case .pendingStart, .starting, .installed, .pendingStop:
                              return false
                          }
                      }),
                      isEligible(state, dueWork[candidateIndex])
                else { return nil }
                due = dueWork[candidateIndex]
            }
            let claim = MeteringNetworkClaim(
                token: UUID(),
                claimedAt: now,
                expiresAt: now.addingTimeInterval(MeteringNetworkClaim.leaseDuration)
            )
            switch due.kind {
            case .registration:
                guard let key = state.registrationWork.first(where: { $0.value.workID == due.workID })?.key,
                      var work = state.registrationWork[key],
                      work.claim.map({ $0.expiresAt <= now }) ?? true
                else { return nil }
                work.claim = claim
                state.registrationWork[key] = work
                return .registration(work, claim)
            case .activation:
                guard let key = state.activationWork.first(where: { $0.value.workID == due.workID })?.key,
                      var work = state.activationWork[key],
                      work.claim.map({ $0.expiresAt <= now }) ?? true
                else { return nil }
                work.claim = claim
                state.activationWork[key] = work
                return .activation(work, claim)
            case .sample:
                guard let key = state.sampleWork.first(where: { $0.value.workID == due.workID })?.key,
                      var work = state.sampleWork[key],
                      work.claim.map({ $0.expiresAt <= now }) ?? true
                else { return nil }
                work.claim = claim
                state.sampleWork[key] = work
                return .sample(work, claim)
            case .identityCleanup, .rollover, .install, .shield:
                return nil
            }
        }
    }

    private func isAuthorizedBarrierCandidate(
        handoff: V2RouteHandoff,
        candidateEpoch: DeviceDailyEpoch,
        state: DeviceEpochStoreState
    ) -> Bool {
        let authoritativeCorrection = candidateEpoch.baseSource == .registrationConflict409
            && candidateEpoch.baseCorrectionState == .used
        let conservativeResume = handoff.fromGenerationID == handoff.toGenerationID
            && candidateEpoch.baseSource == .childState200
            && candidateEpoch.resumeBoundaryPending
            && state.epochs[handoff.fromEpochID]?.status == .paused
        let namedReplacement: Bool
        if let priorEpoch = state.epochs[handoff.fromEpochID] {
            let activeKey = MeteringEpochKey(
                protocolVersion: priorEpoch.protocolVersion,
                childDeviceID: priorEpoch.childDeviceID,
                usageDate: priorEpoch.usageDate,
                canonicalTimezone: priorEpoch.canonicalTimezone,
                policyRevision: priorEpoch.policyRevision,
                measurementSelectionDigest: priorEpoch.measurementSelectionDigest,
                enforcementSetID: priorEpoch.enforcementSetID
            )
            let candidateKey = MeteringEpochKey(
                protocolVersion: candidateEpoch.protocolVersion,
                childDeviceID: candidateEpoch.childDeviceID,
                usageDate: candidateEpoch.usageDate,
                canonicalTimezone: candidateEpoch.canonicalTimezone,
                policyRevision: candidateEpoch.policyRevision,
                measurementSelectionDigest: candidateEpoch.measurementSelectionDigest,
                enforcementSetID: candidateEpoch.enforcementSetID
            )
            namedReplacement = MeteringEpochContract.replacementReason(
                active: activeKey,
                next: candidateKey,
                explicitRecovery: nil
            ) != nil
        } else {
            namedReplacement = false
        }
        return authoritativeCorrection || conservativeResume || namedReplacement
    }

    @discardableResult
    internal func transaction<Value>(
        expectedOwner: UUID?,
        bootstrapOwnerIfMissing: Bool = true,
        allowPersistedOwnerMismatchForNoop: Bool = false,
        debugLabel: String? = nil,
        _ mutate: (inout DeviceEpochStoreState) throws -> Value
    ) throws -> Value {
        try requireRecoveryExecutionBudget()
        debugTransactionCheckpoint(debugLabel, stage: "before_lock")
        let url = try resolvedFileURL()
        for attempt in 0...2 {
            let initialData = try withLock {
                return try fileIO.read(from: url)
            }
            debugTransactionCheckpoint(debugLabel, stage: "snapshot_copied")
            debugTransactionCheckpoint(debugLabel, stage: "initial_read")
            let loaded = try decodeSnapshot(initialData)
            debugTransactionCheckpoint(debugLabel, stage: "state_loaded")
            let priorData = loaded.persistedData
            var state = loaded.state
            try validateStatic(state, expectedOwner: nil, requireOwnerMatch: false)
            debugTransactionCheckpoint(debugLabel, stage: "prior_validated")
            if allowPersistedOwnerMismatchForNoop {
                guard ownerProvider() == expectedOwner else {
                    throw DeviceEpochStoreError.ownerMismatch
                }
            } else {
                try checkOwner(expectedOwner: expectedOwner, state: state)
            }

            if bootstrapOwnerIfMissing, state.ownerChildDeviceID == nil {
                state.ownerChildDeviceID = expectedOwner
            }

            var candidate = state
            let value = try mutate(&candidate)
            debugTransactionCheckpoint(debugLabel, stage: "mutation_complete")

            // A rejected callback may inspect an unowned root, but must not
            // bootstrap it merely by arriving. The loaded root was already
            // statically validated above, so an unchanged transaction is safe.
            guard candidate != state else {
                debugTransactionCheckpoint(debugLabel, stage: "unchanged_complete")
                return value
            }

            try checkOwner(expectedOwner: expectedOwner, state: candidate)
            try validateStatic(candidate, expectedOwner: expectedOwner, requireOwnerMatch: true)
            try validateTransactionDelta(candidate: candidate, priorState: state)
            debugTransactionCheckpoint(debugLabel, stage: "candidate_validated")

            // Re-encoding an unchanged Codable value can produce different bytes on
            // some SDKs. Rejected callback paths must be byte-identical no-ops.
            let encoded = try Self.encoder.encode(candidate)
            debugTransactionCheckpoint(debugLabel, stage: "candidate_encoded")
            guard encoded != priorData else {
                debugTransactionCheckpoint(debugLabel, stage: "same_bytes_complete")
                return value
            }
            let committed = try withLock { () throws -> Bool in
                let currentData = try fileIO.read(from: url)
                guard currentData == priorData else { return false }
                guard ownerProvider() == expectedOwner else {
                    throw DeviceEpochStoreError.ownerMismatch
                }
                var writeAttempted = false
                do {
                    writeAttempted = true
                    try fileIO.writeAtomically(encoded, to: url)
                    guard let readbackData = try fileIO.read(from: url),
                          readbackData == encoded
                    else { throw DeviceEpochStoreError.readbackMismatch }
                    guard ownerProvider() == expectedOwner else {
                        throw DeviceEpochStoreError.ownerMismatch
                    }
                    return true
                } catch {
                    if writeAttempted {
                        do {
                            try restore(priorData, at: url)
                        } catch {
                            throw DeviceEpochStoreError.restorationFailed
                        }
                    }
                    throw error
                }
            }
            if committed {
                debugTransactionCheckpoint(debugLabel, stage: "candidate_written")
                try removeLegacyDefaultsAfterVerifiedRoot()
                debugTransactionCheckpoint(debugLabel, stage: "transaction_complete")
                return value
            }
            debugTransactionCheckpoint(debugLabel, stage: "cas_conflict_\(attempt + 1)")
        }
        throw DeviceEpochStoreError.retryableConflict
    }

    private func debugTransactionCheckpoint(_ label: String?, stage: String) {
#if DEBUG
        guard let label,
              let defaults = UserDefaults(suiteName: MeteringOwnerMirror.suiteName)
        else { return }
        defaults.set(
            "\(ISO8601DateFormatter().string(from: Date())) \(label).\(stage)",
            forKey: "evlin.metering.lastTransactionStage"
        )
        defaults.synchronize()
#endif
    }

    /// Continue one already-prepared identity retirement after the mutable
    /// owner mirror has changed. Authority comes only from the exact durable
    /// cleanup work ID; both the work ID and the old root owner are rechecked
    /// before persistence and on readback.
    @discardableResult
    func identityCleanupTransaction<Value>(
        workID: UUID,
        _ mutate: (inout DeviceEpochStoreState, inout IdentityCleanupWork) throws -> Value
    ) throws -> Value {
        try requireRecoveryExecutionBudget()
        let url = try resolvedFileURL()
        for _ in 0...2 {
            let initialData = try withLock { try fileIO.read(from: url) }
            let loaded = try decodeSnapshot(initialData)
            let priorData = loaded.persistedData
            let state = loaded.state
            guard let oldOwner = state.ownerChildDeviceID,
                  var cleanup = state.identityCleanupWork,
                  cleanup.workID == workID
            else { throw DeviceEpochStoreError.ownerMismatch }
            try validateStatic(state, expectedOwner: oldOwner, requireOwnerMatch: true)

            var candidate = state
            let value = try mutate(&candidate, &cleanup)
            guard candidate.ownerChildDeviceID == oldOwner,
                  candidate.identityCleanupWork == state.identityCleanupWork
            else { throw DeviceEpochStoreError.ownerMismatch }
            candidate.identityCleanupWork = cleanup
            guard candidate.identityCleanupWork?.workID == workID else {
                throw DeviceEpochStoreError.ownerMismatch
            }
            try validateStatic(candidate, expectedOwner: oldOwner, requireOwnerMatch: true)
            try validateTransactionDelta(candidate: candidate, priorState: state)
            guard candidate != state else { return value }

            let encoded = try Self.encoder.encode(candidate)
            let committed = try withLock { () throws -> Bool in
                guard try fileIO.read(from: url) == priorData else { return false }
                var writeAttempted = false
                do {
                    writeAttempted = true
                    try fileIO.writeAtomically(encoded, to: url)
                    guard let readbackData = try fileIO.read(from: url),
                          readbackData == encoded
                    else { throw DeviceEpochStoreError.readbackMismatch }
                    return true
                } catch {
                    if writeAttempted {
                        do {
                            try restore(priorData, at: url)
                        } catch {
                            throw DeviceEpochStoreError.restorationFailed
                        }
                    }
                    throw error
                }
            }
            if committed { return value }
        }
        throw DeviceEpochStoreError.retryableConflict
    }

    /// Binds an already-prepared "remove this device" cleanup to the one
    /// device identity created by a later successful pairing. The transition
    /// is deliberately one-way: a cleanup may move from no target to exactly
    /// one target, but can never be redirected to a different device.
    @discardableResult
    func adoptIdentityCleanupTarget(
        workID: UUID,
        newOwner: UUID,
        now: Date = Date()
    ) throws -> Bool {
        try identityCleanupTransaction(workID: workID) { _, cleanup in
            if cleanup.newOwnerChildDeviceID == newOwner {
                return false
            }
            guard cleanup.newOwnerChildDeviceID == nil else {
                throw DeviceEpochStoreError.ownerMismatch
            }

            cleanup.newOwnerChildDeviceID = newOwner
            cleanup.ownerMirrorTransitionAcknowledged = false
            cleanup.retry = MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: now,
                lastErrorCode: nil,
                terminal: .pending
            )
            return true
        }
    }

    /// Marks the durable cleanup terminal only after every item captured in
    /// its envelope has an exact acknowledgement. The succeeded envelope is
    /// deliberately persisted before root handoff so a crash at this boundary
    /// can resume without repeating external effects.
    @discardableResult
    func markIdentityCleanupSucceeded(workID: UUID) throws -> Bool {
        try identityCleanupTransaction(workID: workID) { _, cleanup in
            let allWorkIDs = Set(
                cleanup.oldRegistrationWorkIDs
                    + cleanup.oldActivationWorkIDs
                    + cleanup.oldSampleWorkIDs
                    + cleanup.oldInstallWorkIDs
            )
            guard cleanup.terminalizedWorkIDs == allWorkIDs,
                  cleanup.purgedFallbackKeys == Set(cleanup.oldFallbackKeys),
                  cleanup.releasedShieldOperationIDs == Set(cleanup.oldShieldOperationIDs),
                  cleanup.stopAcknowledgedActivityNames == Set(cleanup.oldActivityNames),
                  cleanup.clearedUsageDates == Set(cleanup.oldUsageDates),
                  cleanup.ownerMirrorTransitionAcknowledged
            else { return false }
            cleanup.retry.terminal = .succeeded
            cleanup.retry.lastErrorCode = nil
            return true
        }
    }

    /// Repairs the crash window between changing the mutable App Group owner
    /// mirror and durably acknowledging that exact transition in cleanup work.
    ///
    /// The persisted cleanup envelope, not the recovery caller, names the only
    /// owner allowed to acknowledge the transition. A third identity therefore
    /// cannot complete or steal an in-flight cleanup.
    @discardableResult
    func recoverIdentityCleanupMirrorAcknowledgement(workID: UUID) throws -> Bool {
        try identityCleanupTransaction(workID: workID) { _, cleanup in
            guard !cleanup.ownerMirrorTransitionAcknowledged,
                  ownerProvider() == cleanup.newOwnerChildDeviceID
            else { return false }
            cleanup.ownerMirrorTransitionAcknowledged = true
            return true
        }
    }

    /// Hands authority to the already-mirrored new owner only after the
    /// succeeded cleanup envelope has survived a durable write. No old-owner
    /// object is retained in the new root; delayed callbacks are rejected by
    /// the mutable owner mirror before they can bootstrap work.
    @discardableResult
    func finalizeIdentityCleanup(workID: UUID) throws -> Bool {
        try requireRecoveryExecutionBudget()
        let url = try resolvedFileURL()
        for _ in 0...2 {
            let initialData = try withLock { try fileIO.read(from: url) }
            let loaded = try decodeSnapshot(initialData)
            let priorData = loaded.persistedData
            let state = loaded.state
            guard let oldOwner = state.ownerChildDeviceID,
                  let cleanup = state.identityCleanupWork,
                  cleanup.workID == workID
            else { return false }
            try validateStatic(state, expectedOwner: oldOwner, requireOwnerMatch: true)
            guard cleanup.retry.terminal == .succeeded,
                  ownerProvider() == cleanup.newOwnerChildDeviceID
            else { return false }

            let candidate = DeviceEpochStoreState(
                ownerChildDeviceID: cleanup.newOwnerChildDeviceID,
                pendingRegistrationRecovery: cleanup.oldOwnerChildDeviceID
                    == cleanup.newOwnerChildDeviceID
                    ? .identityRecovery
                    : nil
            )
            try validateStatic(
                candidate,
                expectedOwner: cleanup.newOwnerChildDeviceID,
                requireOwnerMatch: true
            )
            let encoded = try Self.encoder.encode(candidate)
            let committed = try withLock { () throws -> Bool in
                guard try fileIO.read(from: url) == priorData else { return false }
                guard ownerProvider() == cleanup.newOwnerChildDeviceID else { return false }
                var writeAttempted = false
                do {
                    writeAttempted = true
                    try fileIO.writeAtomically(encoded, to: url)
                    guard let readbackData = try fileIO.read(from: url),
                          readbackData == encoded
                    else { throw DeviceEpochStoreError.readbackMismatch }
                    return true
                } catch {
                    if writeAttempted {
                        do {
                            try restore(priorData, at: url)
                        } catch {
                            throw DeviceEpochStoreError.restorationFailed
                        }
                    }
                    throw error
                }
            }
            if committed { return true }
        }
        throw DeviceEpochStoreError.retryableConflict
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "invalid device epoch date"
                )
            }
            return date
        }
        return decoder
    }()

    private static let legacyDecoder = JSONDecoder()

    private func withLock<T>(_ work: () throws -> T) throws -> T {
        guard let result = lock.withLock({ () -> Result<T, Error> in
            do {
                return .success(try work())
            } catch {
                return .failure(error)
            }
        }) else {
            throw DeviceEpochStoreError.lockUnavailable
        }
        return try result.get()
    }

    private func requireRecoveryExecutionBudget() throws {
        guard MeteringRecoveryExecutionContext.budget?.canStartTransaction() != false else {
            throw DeviceEpochStoreError.executionBudgetExpired
        }
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURL { return fileURL }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MeteringOwnerMirror.suiteName
        ) else {
            throw DeviceEpochStoreError.appGroupContainerUnavailable
        }
        return container.appendingPathComponent(Self.fileName)
    }

    private func decodeState(_ data: Data?) throws -> DeviceEpochStoreState {
        if let stateDecoder {
            return try stateDecoder(data)
        }
        guard let data else { return DeviceEpochStoreState() }
        let state = try Self.decoder.decode(DeviceEpochStoreState.self, from: data)
        guard (1...DeviceEpochStoreState.currentSchemaVersion).contains(state.schemaVersion) else {
            throw DeviceEpochStoreError.unsupportedSchema(state.schemaVersion)
        }
        var migrated = state
        migrated.schemaVersion = DeviceEpochStoreState.currentSchemaVersion
        return migrated
    }

    private func decodeSnapshot(
        _ data: Data?
    ) throws -> (state: DeviceEpochStoreState, persistedData: Data?) {
        if let data {
            let state = try decodeState(data)
            try validateStatic(state, expectedOwner: nil, requireOwnerMatch: false)
            return (state, data)
        }
        if let migrated = try decodeLegacyState() {
            try validateStatic(migrated, expectedOwner: nil, requireOwnerMatch: false)
            return (migrated, nil)
        }
        return (DeviceEpochStoreState(), nil)
    }

    private func readOrMigrateAbsentRoot(at url: URL) throws -> DeviceEpochStoreState {
        guard let migrated = try decodeLegacyState() else {
            return DeviceEpochStoreState()
        }
        try validateStatic(migrated, expectedOwner: nil, requireOwnerMatch: false)
        let encoded = try Self.encoder.encode(migrated)
        let committedData = try withLock { () throws -> Data in
            if let concurrentData = try fileIO.read(from: url) {
                return concurrentData
            }
            do {
                try fileIO.writeAtomically(encoded, to: url)
                guard let readback = try fileIO.read(from: url), readback == encoded else {
                    throw DeviceEpochStoreError.readbackMismatch
                }
                return readback
            } catch {
                do {
                    try restore(nil, at: url)
                } catch {
                    throw DeviceEpochStoreError.restorationFailed
                }
                throw error
            }
        }
        let verified = try decodeState(committedData)
        try validateStatic(verified, expectedOwner: nil, requireOwnerMatch: false)
        try removeLegacyDefaultsAfterVerifiedRoot()
        return verified
    }

    private func decodeLegacyState() throws -> DeviceEpochStoreState? {
        guard let defaults = legacyDefaults,
              let lifecycleData = defaults.data(forKey: Self.legacyLifecycleKey)
        else { return nil }
        let lifecycle = try Self.legacyDecoder.decode(
            LegacyActivityLifecyclePayload.self,
            from: lifecycleData
        )
        guard lifecycle.isValid else {
            throw DeviceEpochStoreError.readbackMismatch
        }

        let owner = lifecycle.active.flatMap { UUID(uuidString: $0.deviceID) }
            ?? lifecycle.pending.flatMap { UUID(uuidString: $0.deviceID) }
            ?? ownerProvider()
        guard let owner else { return nil }
        let phase: LegacyCompatibilityPhase
        if lifecycle.isStopped {
            phase = .stoppedV1
        } else if lifecycle.pending != nil {
            phase = .dualLanePreparingV2
        } else if !lifecycle.retiringActivityNames.isEmpty {
            phase = .retiringV1
        } else {
            phase = .activeV1
        }
        let retiring = LegacyMeteringActivity.uniqueTargets(
            lifecycle.retiringActivityNames.map(Optional.some)
        )
        let breadcrumbs = LegacyMeteringActivity.uniqueTargets(
            (defaults.stringArray(forKey: Self.legacyBreadcrumbsKey) ?? []).map(Optional.some)
        )
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            legacy: LegacyCompatibilityMonitorState(
                ownerChildDeviceID: owner,
                lifecycleVersion: lifecycle.version,
                active: lifecycle.active,
                pending: lifecycle.pending,
                retiringActivityNames: retiring,
                breadcrumbActivityNames: breadcrumbs,
                scalarActiveActivityName: defaults.string(forKey: Self.legacyActiveNameKey),
                isStopped: lifecycle.isStopped,
                phase: phase,
                stopAcknowledgedAt: nil
            )
        )
    }

    private func removeLegacyDefaultsAfterVerifiedRoot() throws {
        guard let legacyDefaults else { return }
        let keys = [
            Self.legacyLifecycleKey,
            Self.legacyBreadcrumbsKey,
            Self.legacyActiveNameKey,
        ]
        guard keys.contains(where: { legacyDefaults.object(forKey: $0) != nil }) else {
            return
        }
        keys.forEach(legacyDefaults.removeObject(forKey:))
        legacyDefaults.synchronize()
        guard keys.allSatisfy({ legacyDefaults.object(forKey: $0) == nil }) else {
            throw DeviceEpochStoreError.readbackMismatch
        }
    }

    private func checkOwner(expectedOwner: UUID?, state: DeviceEpochStoreState) throws {
        guard ownerProvider() == expectedOwner else {
            throw DeviceEpochStoreError.ownerMismatch
        }
        guard state.ownerChildDeviceID == nil || state.ownerChildDeviceID == expectedOwner else {
            throw DeviceEpochStoreError.ownerMismatch
        }
    }

    private func validateStatic(
        _ state: DeviceEpochStoreState,
        expectedOwner: UUID?,
        requireOwnerMatch: Bool
    ) throws {
        guard state.schemaVersion == DeviceEpochStoreState.currentSchemaVersion else {
            throw DeviceEpochStoreError.unsupportedSchema(state.schemaVersion)
        }
        if requireOwnerMatch, state.ownerChildDeviceID != expectedOwner {
            throw DeviceEpochStoreError.ownerMismatch
        }

        let owner = expectedOwner ?? state.ownerChildDeviceID
        let hasPersistedObjects = !state.generations.isEmpty
            || !state.epochs.isEmpty
            || !state.routes.isEmpty
            || !state.tombstones.isEmpty
            || state.v2RouteHandoff != nil
            || state.legacy != nil
            || !state.registrationWork.isEmpty
            || !state.activationWork.isEmpty
            || !state.sampleWork.isEmpty
            || !state.installWork.isEmpty
            || !state.shieldReferences.isEmpty
            || state.identityCleanupWork != nil
            || state.rolloverEffectsWork != nil
            || state.coverage != nil
            || !state.ratchets.isEmpty
            || state.desiredPolicy != nil
        guard let owner else {
            if hasPersistedObjects {
                throw DeviceEpochStoreInvariantError.invalidState("persisted objects have no owner")
            }
            return
        }

        func generationKey(for generation: MeteringPolicyGeneration) -> MeteringGenerationKey {
            MeteringGenerationKey(
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID
            )
        }

        func generationMatches(_ generation: MeteringPolicyGeneration, _ epoch: DeviceDailyEpoch) -> Bool {
            generation.protocolVersion == epoch.protocolVersion
                && generation.childDeviceID == epoch.childDeviceID
                && generation.canonicalTimezone == epoch.canonicalTimezone
                && generation.policyRevision == epoch.policyRevision
                && generation.measurementSelectionDigest == epoch.measurementSelectionDigest
                && generation.enforcementSetID == epoch.enforcementSetID
        }

        for (generationID, generation) in state.generations {
            guard generationID == generation.generationID,
                  generation.childDeviceID == owner,
                  (generation.configuredPoolMinutes == nil)
                    == (generation.configuredDeviceCapMinutes == nil),
                  generation.configuredPoolMinutes.map { $0 > 0 } ?? true,
                  generation.configuredDeviceCapMinutes.map { $0 > 0 } ?? true,
                  generation.measurementSelectionDigest == MeteringEpochContract.selectionDigest(
                      persistedBytes: generation.measurementSelectionBytes
                  )
            else {
                throw DeviceEpochStoreInvariantError.invalidState("generation identity or selection digest is invalid")
            }
        }

        if let activeGenerationID = state.activeGenerationID {
            guard let generation = state.generations[activeGenerationID], generation.childDeviceID == owner else {
                throw DeviceEpochStoreInvariantError.invalidState("active generation is missing")
            }
        }

        for (epochID, epoch) in state.epochs {
            guard epochID == epoch.epochID,
                  epoch.childDeviceID == owner,
                  state.generations.values.contains(where: { generationMatches($0, epoch) })
            else {
                throw DeviceEpochStoreInvariantError.invalidState("epoch identity or generation coherence is invalid")
            }
        }

        if let activeEpochID = state.activeEpochID {
            guard let epoch = state.epochs[activeEpochID], epoch.childDeviceID == owner else {
                throw DeviceEpochStoreInvariantError.invalidState("active epoch is missing")
            }
        }

        for (routeID, route) in state.routes {
            guard routeID == route.routeID,
                  route.ownerChildDeviceID == owner,
                  let generation = state.generations[route.generationID],
                  generation.childDeviceID == owner,
                  route.generationKey == generationKey(for: generation),
                  let epoch = state.epochs[route.epochID],
                  epoch.childDeviceID == owner,
                  generationMatches(generation, epoch),
                  epoch.usageDate == route.usageDate,
                  route.plannedSchedule.usageDate == route.usageDate,
                  route.plannedSchedule.timezoneIdentifier == generation.canonicalTimezone
            else {
                throw DeviceEpochStoreInvariantError.invalidState("route generation or epoch coherence is invalid")
            }
            if route.lifecycle == .tombstoned, state.tombstones[routeID] == nil {
                throw DeviceEpochStoreInvariantError.invalidState("tombstoned route has no tombstone")
            }
        }

        if let activeRouteID = state.activeRouteID {
            guard let activeRoute = state.routes[activeRouteID],
                  activeRoute.lifecycle == .active,
                  state.activeEpochID == activeRoute.epochID,
                  state.activeGenerationID == activeRoute.generationID
            else {
                throw DeviceEpochStoreInvariantError.invalidState("active route references are incoherent")
            }
        }

        for (tombstoneID, tombstone) in state.tombstones {
            guard tombstoneID == tombstone.routeID,
                  let route = state.routes[tombstone.routeID],
                  route.ownerChildDeviceID == tombstone.ownerChildDeviceID,
                  route.epochID == tombstone.epochID,
                  route.generationID == tombstone.generationID,
                  route.activityName == tombstone.activityName,
                  route.usageDate == tombstone.usageDate
            else {
                throw DeviceEpochStoreInvariantError.invalidState("route tombstone is incoherent")
            }
        }

        for work in state.registrationWork.values {
            guard work.ownerChildDeviceID == owner,
                  let route = state.routes[work.routeID],
                  route.epochID == work.epochID,
                  let epoch = state.epochs[work.epochID],
                  work.request.usageDate == route.usageDate,
                  work.request.usageDate == epoch.usageDate,
                  work.request.protocolVersion == 2,
                  work.request.deviceID == owner,
                  work.request.epochID == work.epochID
            else {
                throw DeviceEpochStoreInvariantError.invalidState("registration work references an invalid route")
            }
        }
        for work in state.activationWork.values {
            guard work.ownerChildDeviceID == owner,
                  let route = state.routes[work.routeID],
                  route.epochID == work.epochID,
                  work.request.protocolVersion == 2,
                  work.request.deviceID == owner,
                  work.request.routeID == work.routeID
            else {
                throw DeviceEpochStoreInvariantError.invalidState("activation work references an invalid route")
            }
        }
        for work in state.sampleWork.values {
            guard work.ownerChildDeviceID == owner,
                  work.request.deviceID == owner,
                  work.request.lane != nil
            else {
                throw DeviceEpochStoreInvariantError.invalidState("sample work has the wrong owner")
            }
            switch work.authorization {
            case .legacyDeliverable:
                guard work.epochID == nil,
                      work.routeID == nil,
                      work.request.lane == .v1
                else {
                    throw DeviceEpochStoreInvariantError.invalidState("legacy sample work is not a v1 sample")
                }
            case .waitingForRegistration, .v2Deliverable:
                guard let routeID = work.routeID,
                      let epochID = work.epochID,
                      let route = state.routes[routeID],
                      let epoch = state.epochs[epochID],
                      route.ownerChildDeviceID == owner,
                      route.epochID == epochID,
                      epoch.childDeviceID == owner,
                      work.request.epochID == epochID,
                      work.request.lane == .v2,
                      work.request.activityName == MeteringSampleWireAliases.activityName(routeID: routeID)
                        || work.request.activityName == route.activityName,
                      work.request.usageDate == route.usageDate,
                      work.request.usageDate == epoch.usageDate,
                      work.createdAt >= route.createdAt
                else {
                    throw DeviceEpochStoreInvariantError.invalidState("v2 sample work references an invalid route")
                }
            }
        }
        for work in state.installWork.values {
            guard work.ownerChildDeviceID == owner, state.routes[work.routeID] != nil else {
                throw DeviceEpochStoreInvariantError.invalidState("install work references an invalid route")
            }
        }

        if let coverage = state.coverage, coverage.ownerChildDeviceID != owner {
            throw DeviceEpochStoreInvariantError.invalidState("coverage has the wrong owner")
        }
        for (ratchetID, ratchet) in state.ratchets {
            guard ratchetID == ratchet.ownerChildDeviceID, ratchet.ownerChildDeviceID == owner else {
                throw DeviceEpochStoreInvariantError.invalidState("ratchet has the wrong owner")
            }
        }

        if let desired = state.desiredPolicy {
            guard desired.ownerChildDeviceID == owner,
                  desired.orderingToken > 0,
                  !desired.policyRevision.isEmpty,
                  !desired.usageDate.isEmpty,
                  !desired.canonicalTimezone.isEmpty,
                  desired.dailyPoolMinutes > 0,
                  desired.deviceCapMinutes > 0,
                  desired.ackedAt == nil || desired.appliedAt != nil
            else {
                throw DeviceEpochStoreInvariantError.invalidState("desired policy is invalid")
            }
        }

        if let handoff = state.v2RouteHandoff {
            guard handoff.ownerChildDeviceID == owner,
                  state.generations[handoff.fromGenerationID]?.childDeviceID == owner,
                  state.generations[handoff.toGenerationID]?.childDeviceID == owner,
                  let fromEpoch = state.epochs[handoff.fromEpochID],
                  let toEpoch = state.epochs[handoff.toEpochID],
                  let fromRoute = state.routes[handoff.fromRouteID],
                  let toRoute = state.routes[handoff.toRouteID],
                  fromEpoch.childDeviceID == owner,
                  toEpoch.childDeviceID == owner,
                  fromRoute.ownerChildDeviceID == owner,
                  toRoute.ownerChildDeviceID == owner,
                  fromRoute.generationID == handoff.fromGenerationID,
                  toRoute.generationID == handoff.toGenerationID,
                  fromRoute.epochID == handoff.fromEpochID,
                  toRoute.epochID == handoff.toEpochID,
                  fromRoute.routeID != toRoute.routeID,
                  fromEpoch.epochID != toEpoch.epochID
            else {
                throw DeviceEpochStoreInvariantError.invalidState("handoff references are not same-owner routes and epochs")
            }

            switch handoff.phase {
            case .preparing:
                break
            case .dualV2:
                guard state.activeRouteID == handoff.fromRouteID else {
                    throw DeviceEpochStoreInvariantError.invalidState("dualV2 must keep prior route active")
                }
            case .cutoverReady:
                guard state.activeRouteID == handoff.fromRouteID else {
                    throw DeviceEpochStoreInvariantError.invalidState("cutoverReady must keep prior route active")
                }
                guard let closedAt = handoff.priorRouteInputClosedAt else {
                    throw DeviceEpochStoreInvariantError.invalidState("prior route barrier is incomplete")
                }
                if state.sampleWork.values.contains(where: {
                    $0.routeID == handoff.fromRouteID && $0.retry.terminal == .pending
                }) {
                    throw DeviceEpochStoreInvariantError.invalidState("prior route sample work is pending")
                }
                if state.sampleWork.values.contains(where: {
                    $0.routeID == handoff.fromRouteID && $0.createdAt > closedAt
                }) {
                    throw DeviceEpochStoreInvariantError.invalidState("prior route callback crossed barrier")
                }
            case .committed:
                guard let closedAt = handoff.priorRouteInputClosedAt else {
                    throw DeviceEpochStoreInvariantError.invalidState("prior route barrier is incomplete")
                }
                let priorRouteSampleWork = state.sampleWork.values.filter {
                    $0.routeID == handoff.fromRouteID
                }
                guard priorRouteSampleWork.allSatisfy({ work in
                    switch work.retry.terminal {
                    case .pending:
                        return false
                    case .succeeded, .superseded, .rejected, .abandoned:
                        return true
                    }
                }), !priorRouteSampleWork.contains(where: { $0.createdAt > closedAt }) else {
                    throw DeviceEpochStoreInvariantError.invalidState("prior route sample work is not closed")
                }
                let candidateInstalls = state.installWork.values.filter { $0.routeID == handoff.toRouteID }
                let priorInstalls = state.installWork.values.filter { $0.routeID == handoff.fromRouteID }
                let successfulActivations = state.activationWork.values.filter {
                    $0.ownerChildDeviceID == owner
                        && $0.epochID == handoff.toEpochID
                        && $0.routeID == handoff.toRouteID
                        && $0.retry.terminal == .succeeded
                }
                let priorTombstone = state.tombstones[handoff.fromRouteID]
                guard candidateInstalls.count == 1,
                      priorInstalls.count == 1,
                      successfulActivations.count == 1,
                      state.activeRouteID == handoff.toRouteID,
                      state.activeEpochID == handoff.toEpochID,
                      state.activeGenerationID == handoff.toGenerationID,
                      toEpoch.registeredAt != nil,
                      toRoute.lifecycle == .active,
                      toRoute.installedSchedule != nil,
                      toRoute.installedEvents != nil,
                      candidateInstalls[0].phase == .active,
                      fromEpoch.status == .retired,
                      fromEpoch.retiredAt != nil,
                      fromEpoch.retireReason != nil,
                      fromRoute.lifecycle == .tombstoned,
                      priorInstalls[0].phase == .pendingStop || priorInstalls[0].phase == .stopped,
                      handoff.registrationAcknowledgedAt != nil,
                      handoff.activationAcknowledgedAt != nil
                else {
                    throw DeviceEpochStoreInvariantError.invalidState("handoff collection prerequisites are incomplete")
                }
                if priorInstalls[0].phase == .stopped {
                    guard priorTombstone?.stopAcknowledgedAt != nil,
                          handoff.priorStopAcknowledgedAt != nil
                    else {
                        throw DeviceEpochStoreInvariantError.invalidState("stopped prior route is missing absence acknowledgement")
                    }
                } else {
                    guard priorTombstone?.stopAcknowledgedAt == nil,
                          handoff.priorStopAcknowledgedAt == nil
                    else {
                        throw DeviceEpochStoreInvariantError.invalidState("pending prior stop is unexpectedly acknowledged")
                    }
                }
            }
        }
    }

    private func validateTransactionDelta(
        candidate: DeviceEpochStoreState,
        priorState: DeviceEpochStoreState
    ) throws {
        let priorHandoff = priorState.v2RouteHandoff
        let candidateHandoff = candidate.v2RouteHandoff

        if let priorHandoff {
            guard let candidateHandoff else {
                guard canCollectHandoff(priorHandoff, from: priorState)
                        || canDetachCommittedHandoffForPreparedRollover(
                            priorHandoff,
                            in: candidate
                        )
                        || canAbandonConsumedPhysicalCandidate(
                            priorHandoff,
                            in: candidate
                        )
                        || canAbandonAuthoritativeBaseCorrection(priorHandoff, in: candidate)
                        || canAbandonConservativeResume(priorHandoff, in: candidate)
                        || canAbandonSupersededCandidate(priorHandoff, in: candidate)
                        || canAbandonPausedCrossDaySupersededHandoff(priorHandoff, in: candidate)
                        || canAbandonElapsedCandidate(priorHandoff, in: candidate)
                        || canCancelBackwardPreparingHandoff(priorHandoff, in: candidate)
                        || canPrepareIdentityCleanupRemovingHandoff(
                            priorHandoff,
                            from: priorState,
                            to: candidate
                        ) else {
                    throw DeviceEpochStoreInvariantError.invalidState("handoff was removed before exact stop acknowledgement")
                }
                return
            }
            if !hasSameImmutableTuple(candidateHandoff, as: priorHandoff) {
                guard isAuthoritativeBaseCorrectionHandoffReplacement(
                    from: priorHandoff,
                    to: candidateHandoff,
                    in: candidate
                ) || isConsumedPhysicalCandidateHandoffReplacement(
                    from: priorHandoff,
                    to: candidateHandoff,
                    in: candidate
                ) else {
                    throw DeviceEpochStoreInvariantError.invalidState("handoff immutable tuple changed")
                }
                return
            }
            guard isAllowedHandoffTransition(from: priorHandoff.phase, to: candidateHandoff.phase) else {
                throw DeviceEpochStoreInvariantError.invalidState("handoff phase moved illegally")
            }
        } else if candidateHandoff?.phase == .committed {
            throw DeviceEpochStoreInvariantError.invalidState("committed handoff has no durable predecessor")
        }

        guard let handoff = candidateHandoff,
              handoff.phase == .cutoverReady || handoff.phase == .committed else {
            return
        }
        let priorSampleIDs = Set(priorState.sampleWork.keys)
        let newlyAppendedPriorWork = candidate.sampleWork.contains { workID, work in
            work.routeID == handoff.fromRouteID && !priorSampleIDs.contains(workID)
        }
        guard !newlyAppendedPriorWork else {
            throw DeviceEpochStoreInvariantError.invalidState("prior route work was appended with barrier")
        }

        guard handoff.phase == .committed else { return }
        guard let priorHandoff else {
            throw DeviceEpochStoreInvariantError.invalidState("committed handoff has no durable predecessor")
        }

        let candidatePriorInstalls = candidate.installWork.values.filter {
            $0.routeID == handoff.fromRouteID
        }
        guard candidatePriorInstalls.count == 1 else {
            throw DeviceEpochStoreInvariantError.invalidState("prior route install is ambiguous")
        }
        let candidatePriorPhase = candidatePriorInstalls[0].phase

        switch priorHandoff.phase {
        case .cutoverReady:
            guard candidatePriorPhase == .pendingStop,
                  candidate.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt == nil,
                  handoff.priorStopAcknowledgedAt == nil
            else {
                throw DeviceEpochStoreInvariantError.invalidState("cutover must persist pending stop before acknowledgement")
            }
        case .committed:
            let priorInstalls = priorState.installWork.values.filter {
                $0.routeID == handoff.fromRouteID
            }
            guard priorInstalls.count == 1 else {
                throw DeviceEpochStoreInvariantError.invalidState("prior committed install is ambiguous")
            }
            let priorPhase = priorInstalls[0].phase
            if priorPhase == .pendingStop && candidatePriorPhase == .stopped {
                guard priorState.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt == nil,
                      priorHandoff.priorStopAcknowledgedAt == nil,
                      candidate.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt != nil,
                      handoff.priorStopAcknowledgedAt != nil
                else {
                    throw DeviceEpochStoreInvariantError.invalidState("stop acknowledgement was not atomic")
                }
            } else if priorPhase != candidatePriorPhase {
                throw DeviceEpochStoreInvariantError.invalidState("prior install stop phase moved illegally")
            }
        case .preparing, .dualV2:
            throw DeviceEpochStoreInvariantError.invalidState("handoff committed before cutover barrier")
        }
    }

    private func canPrepareIdentityCleanupRemovingHandoff(
        _ handoff: V2RouteHandoff,
        from prior: DeviceEpochStoreState,
        to candidate: DeviceEpochStoreState
    ) -> Bool {
        guard prior.identityCleanupWork == nil,
              let cleanup = candidate.identityCleanupWork,
              cleanup.oldOwnerChildDeviceID == handoff.ownerChildDeviceID,
              cleanup.retry.terminal == .pending,
              Set(cleanup.oldEpochIDs).isSuperset(of: [
                handoff.fromEpochID,
                handoff.toEpochID,
              ]),
              Set(cleanup.oldRouteIDs).isSuperset(of: [
                handoff.fromRouteID,
                handoff.toRouteID,
              ]),
              candidate.activeGenerationID == nil,
              candidate.activeEpochID == nil,
              candidate.activeRouteID == nil
        else { return false }

        return cleanup.oldEpochIDs.allSatisfy { epochID in
            candidate.epochs[epochID]?.status == .retired
                && candidate.epochs[epochID]?.retireReason == .identityRecovery
        } && cleanup.oldRouteIDs.allSatisfy { routeID in
            candidate.routes[routeID]?.lifecycle == .tombstoned
                && candidate.tombstones[routeID]?.ownerChildDeviceID
                    == cleanup.oldOwnerChildDeviceID
        } && candidate.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt == nil
            && candidate.tombstones[handoff.toRouteID]?.stopAcknowledgedAt == nil
    }

    private func hasSameImmutableTuple(_ candidate: V2RouteHandoff, as prior: V2RouteHandoff) -> Bool {
        candidate.handoffID == prior.handoffID
            && candidate.ownerChildDeviceID == prior.ownerChildDeviceID
            && candidate.fromGenerationID == prior.fromGenerationID
            && candidate.fromEpochID == prior.fromEpochID
            && candidate.fromRouteID == prior.fromRouteID
            && candidate.toGenerationID == prior.toGenerationID
            && candidate.toEpochID == prior.toEpochID
            && candidate.toRouteID == prior.toRouteID
            && candidate.createdAt == prior.createdAt
    }

    private func isAllowedHandoffTransition(
        from prior: V2RouteHandoffPhase,
        to candidate: V2RouteHandoffPhase
    ) -> Bool {
        if prior == candidate { return true }
        switch (prior, candidate) {
        case (.preparing, .dualV2), (.dualV2, .cutoverReady), (.cutoverReady, .committed):
            return true
        default:
            return false
        }
    }

    private func canCollectHandoff(
        _ handoff: V2RouteHandoff,
        from state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase == .committed,
              let handoffStopAcknowledgedAt = handoff.priorStopAcknowledgedAt
        else { return false }
        let priorInstalls = state.installWork.values.filter {
            $0.ownerChildDeviceID == handoff.ownerChildDeviceID
                && $0.routeID == handoff.fromRouteID
        }
        guard priorInstalls.count == 1,
              priorInstalls[0].phase == .stopped,
              let tombstone = state.tombstones[handoff.fromRouteID],
              tombstone.ownerChildDeviceID == handoff.ownerChildDeviceID,
              tombstone.generationID == handoff.fromGenerationID,
              tombstone.epochID == handoff.fromEpochID,
              tombstone.routeID == handoff.fromRouteID,
              tombstone.stopAcknowledgedAt == handoffStopAcknowledgedAt
        else { return false }
        return true
    }

    private func canDetachCommittedHandoffForPreparedRollover(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase == .committed,
              handoff.priorStopAcknowledgedAt == nil,
              state.activeGenerationID == handoff.toGenerationID,
              state.activeEpochID == handoff.toEpochID,
              state.activeRouteID == handoff.toRouteID,
              let rollover = state.rolloverEffectsWork,
              rollover.ownerChildDeviceID == handoff.ownerChildDeviceID,
              rollover.retry.terminal == .pending,
              rollover.oldEpochID == handoff.toEpochID,
              rollover.oldRouteID == handoff.toRouteID,
              let priorInstall = state.installWork.values.first(where: {
                  $0.ownerChildDeviceID == handoff.ownerChildDeviceID
                      && $0.routeID == handoff.fromRouteID
              }),
              state.installWork.values.filter({
                  $0.ownerChildDeviceID == handoff.ownerChildDeviceID
                      && $0.routeID == handoff.fromRouteID
              }).count == 1,
              priorInstall.phase == .pendingStop,
              let tombstone = state.tombstones[handoff.fromRouteID],
              tombstone.ownerChildDeviceID == handoff.ownerChildDeviceID,
              tombstone.epochID == handoff.fromEpochID,
              tombstone.generationID == handoff.fromGenerationID,
              tombstone.stopAcknowledgedAt == nil
        else { return false }
        return true
    }

    private func isAuthoritativeBaseCorrectionHandoffReplacement(
        from prior: V2RouteHandoff,
        to replacement: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard prior.phase == .cutoverReady,
              replacement.phase == .preparing,
              replacement.ownerChildDeviceID == prior.ownerChildDeviceID,
              replacement.fromGenerationID == prior.fromGenerationID,
              replacement.fromEpochID == prior.fromEpochID,
              replacement.fromRouteID == prior.fromRouteID,
              replacement.toGenerationID != prior.toGenerationID,
              replacement.toEpochID != prior.toEpochID,
              replacement.toRouteID != prior.toRouteID,
              // Authoritative-base correction and physical-event recovery are
              // independent transitions. A 409 correction must preserve the
              // physical replacement budget instead of consuming it.
              (replacement.consumedCandidateReplacementCount ?? 0)
                == (prior.consumedCandidateReplacementCount ?? 0),
              state.activeGenerationID == prior.fromGenerationID,
              state.activeEpochID == prior.fromEpochID,
              state.activeRouteID == prior.fromRouteID,
              let rejectedEpoch = state.epochs[prior.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .authoritativeBaseMismatch,
              rejectedEpoch.baseCorrectionState == .used,
              rejectedEpoch.authoritativeBaseConflict != nil,
              state.routes[prior.toRouteID]?.lifecycle == .tombstoned,
              state.tombstones[prior.toRouteID] != nil,
              let correctedEpoch = state.epochs[replacement.toEpochID],
              correctedEpoch.status == .active,
              correctedEpoch.baseCorrectionState == .used,
              correctedEpoch.baseSource == .registrationConflict409,
              let correctedRoute = state.routes[replacement.toRouteID],
              correctedRoute.lifecycle == .planned,
              state.installWork.values.filter({
                  $0.routeID == replacement.toRouteID
                      && $0.authorization == .offlinePending
                      && $0.phase == .pendingStart
                      && $0.retry.terminal == .pending
              }).count == 1,
              state.registrationWork.values.filter({
                  $0.epochID == replacement.toEpochID
                      && $0.routeID == replacement.toRouteID
                      && $0.retry.terminal == .pending
              }).count == 1
        else { return false }
        return correctedEpoch.baseAcceptedMinutes
            == rejectedEpoch.authoritativeBaseConflict?.authoritativeSnapshot.estimatedMinutes
    }

    private func isConsumedPhysicalCandidateHandoffReplacement(
        from prior: V2RouteHandoff,
        to replacement: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard replacement.phase == .preparing,
              replacement.ownerChildDeviceID == prior.ownerChildDeviceID,
              replacement.fromGenerationID == prior.fromGenerationID,
              replacement.fromEpochID == prior.fromEpochID,
              replacement.fromRouteID == prior.fromRouteID,
              replacement.toGenerationID != prior.toGenerationID,
              replacement.toEpochID != prior.toEpochID,
              replacement.toRouteID != prior.toRouteID,
              state.activeGenerationID == prior.fromGenerationID,
              state.activeEpochID == prior.fromEpochID,
              state.activeRouteID == prior.fromRouteID,
              let rejectedEpoch = state.epochs[prior.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .identityRecovery,
              state.routes[prior.toRouteID]?.lifecycle == .tombstoned,
              state.tombstones[prior.toRouteID] != nil,
              state.installWork.values.filter({
                  $0.routeID == prior.toRouteID
                      && $0.phase == .pendingStop
                      && $0.retry.terminal == .pending
                      && ($0.retry.lastErrorCode == "physical_events_consumed_too_early"
                          || $0.retry.lastErrorCode
                              == "arm_grace_calibration_requires_offset_recut")
              }).count == 1,
              let replacementEpoch = state.epochs[replacement.toEpochID],
              replacementEpoch.status == .active,
              replacementEpoch.retiredAt == nil,
              let replacementRoute = state.routes[replacement.toRouteID],
              replacementRoute.lifecycle == .planned,
              state.installWork.values.filter({
                  $0.routeID == replacement.toRouteID
                      && $0.authorization == .offlinePending
                      && $0.phase == .pendingStart
                      && $0.retry.terminal == .pending
              }).count == 1
        else { return false }
        guard let priorRoute = state.routes[prior.toRouteID] else { return false }
        let priorOffset = max(0, priorRoute.physicalGenerationOffsetMinutes ?? 0)
        let replacementOffset = max(
            0, replacementRoute.physicalGenerationOffsetMinutes ?? 0
        )
        return replacementRoute.plannedEvents.map { $0.thresholdMinutes - replacementOffset }
            == priorRoute.plannedEvents.map { $0.thresholdMinutes - priorOffset }
    }

    private func canAbandonConsumedPhysicalCandidate(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard (handoff.consumedCandidateReplacementCount ?? 0) >= 1,
              handoff.phase == .preparing
                || handoff.phase == .dualV2
                || handoff.phase == .cutoverReady,
              state.activeGenerationID == handoff.fromGenerationID,
              state.activeEpochID == handoff.fromEpochID,
              state.activeRouteID == handoff.fromRouteID,
              let rejectedEpoch = state.epochs[handoff.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .identityRecovery,
              state.generations[handoff.toGenerationID]?.retiredAt != nil,
              state.routes[handoff.toRouteID]?.lifecycle == .tombstoned,
              state.tombstones[handoff.toRouteID]?.stopAcknowledgedAt == nil
        else { return false }
        let installs = state.installWork.values.filter {
            $0.routeID == handoff.toRouteID
        }
        guard installs.count == 1,
              installs[0].phase == .pendingStop,
              installs[0].retry.terminal == .pending,
              (installs[0].retry.lastErrorCode == "physical_events_consumed_too_early"
                || installs[0].retry.lastErrorCode
                    == "arm_grace_calibration_requires_offset_recut")
        else { return false }
        return !state.registrationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
        } && !state.activationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
        } && !state.sampleWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
        }
    }

    private func canAbandonAuthoritativeBaseCorrection(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase == .cutoverReady,
              state.activeGenerationID == handoff.fromGenerationID,
              state.activeEpochID == handoff.fromEpochID,
              state.activeRouteID == handoff.fromRouteID,
              let rejectedEpoch = state.epochs[handoff.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .authoritativeBaseMismatch,
              rejectedEpoch.baseCorrectionState == .used,
              rejectedEpoch.authoritativeBaseConflict != nil,
              state.routes[handoff.toRouteID]?.lifecycle == .tombstoned,
              state.tombstones[handoff.toRouteID] != nil
        else { return false }
        return state.registrationWork.values
            .filter { $0.epochID == handoff.toEpochID && $0.routeID == handoff.toRouteID }
            .allSatisfy { $0.retry.terminal != .pending }
    }

    private func canAbandonConservativeResume(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase == .cutoverReady,
              handoff.fromGenerationID == handoff.toGenerationID,
              state.activeGenerationID == handoff.fromGenerationID,
              state.activeEpochID == handoff.fromEpochID,
              state.activeRouteID == handoff.fromRouteID,
              state.epochs[handoff.fromEpochID]?.status == .paused,
              let rejectedEpoch = state.epochs[handoff.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .gateResumeConservative,
              rejectedEpoch.resumeBoundaryPending,
              rejectedEpoch.baseSource == .childState200,
              state.routes[handoff.toRouteID]?.lifecycle == .tombstoned,
              state.tombstones[handoff.toRouteID] != nil,
              state.installWork.values.filter({
                  $0.routeID == handoff.toRouteID && $0.phase == .pendingStop
              }).count == 1
        else { return false }
        let registrationTerminated = state.registrationWork.values.contains {
            $0.epochID == handoff.toEpochID
                && $0.routeID == handoff.toRouteID
                && $0.retry.terminal != .pending
                && $0.retry.terminal != .succeeded
        }
        let activationTerminated = state.activationWork.values.contains {
            $0.epochID == handoff.toEpochID
                && $0.routeID == handoff.toRouteID
                && $0.retry.terminal != .pending
                && $0.retry.terminal != .succeeded
        }
        return registrationTerminated || activationTerminated
    }

    private func canAbandonSupersededCandidate(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase == .cutoverReady,
              state.activeGenerationID == handoff.fromGenerationID,
              state.activeEpochID == handoff.fromEpochID,
              state.activeRouteID == handoff.fromRouteID,
              let rejectedEpoch = state.epochs[handoff.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .activationSuperseded,
              let rejectedRoute = state.routes[handoff.toRouteID],
              rejectedRoute.lifecycle == .tombstoned,
              state.tombstones[handoff.toRouteID] != nil,
              state.installWork.values.filter({
                  $0.routeID == handoff.toRouteID && $0.phase == .pendingStop
              }).count == 1
        else { return false }
        let candidateRegistrations = state.registrationWork.values.filter {
            $0.epochID == handoff.toEpochID
                && $0.routeID == handoff.toRouteID
        }
        let registrationTerminated = candidateRegistrations.contains {
            $0.retry.terminal != .pending
                && $0.retry.terminal != .succeeded
        }
        let registrationStillUsable = candidateRegistrations.contains {
            $0.retry.terminal == .pending || $0.retry.terminal == .succeeded
        }
        let candidateActivations = state.activationWork.values.filter {
            $0.epochID == handoff.toEpochID
                && $0.routeID == handoff.toRouteID
        }
        let activationTerminated = candidateActivations.contains {
            $0.retry.terminal != .pending && $0.retry.terminal != .succeeded
        }
        let activationStillUsable = candidateActivations.contains {
            $0.retry.terminal == .pending || $0.retry.terminal == .succeeded
        }
        let registrationFailed = registrationTerminated && !registrationStillUsable
        let activationFailedAfterRegistration = candidateRegistrations.contains {
            $0.retry.terminal == .succeeded
        } && activationTerminated && !activationStillUsable
        let hasNewerCandidate = state.routes.values.contains {
            $0.ownerChildDeviceID == handoff.ownerChildDeviceID
                && $0.routeID != handoff.fromRouteID
                && $0.routeID != handoff.toRouteID
                && $0.usageDate == rejectedRoute.usageDate
                && $0.generationID != handoff.fromGenerationID
                && $0.generationID != handoff.toGenerationID
                && $0.lifecycle == .planned
                && state.epochs[$0.epochID]?.status == .active
        }
        let hasSuccessor = hasNewerCandidate || hasPreparedNextDayRolloverReplacing(
            handoff,
            rejectedRoute: rejectedRoute,
            in: state
        )
        return (registrationFailed || activationFailedAfterRegistration)
            && (registrationFailed || hasSuccessor)
            && !state.sampleWork.values.contains {
                $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
            }
            && !state.deferredCallbacks.values.contains {
                $0.routeID == handoff.toRouteID
            }
    }

    private func hasPreparedNextDayRolloverReplacing(
        _ handoff: V2RouteHandoff,
        rejectedRoute: MeteringCallbackRoute?,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard let rejectedRoute,
              let rollover = state.rolloverEffectsWork,
              rollover.ownerChildDeviceID == handoff.ownerChildDeviceID,
              rollover.retry.terminal == .pending,
              rollover.oldEpochID == handoff.fromEpochID,
              rollover.oldRouteID == handoff.fromRouteID,
              rejectedRoute.usageDate < rollover.toUsageDate,
              let nextRoute = state.routes[rollover.newRouteID],
              nextRoute.epochID == rollover.newEpochID,
              nextRoute.usageDate == rollover.toUsageDate,
              nextRoute.lifecycle == .planned || nextRoute.lifecycle == .active
        else { return false }
        return true
    }

    private func canCancelBackwardPreparingHandoff(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase == .preparing,
              state.activeGenerationID == handoff.fromGenerationID,
              state.activeEpochID == handoff.fromEpochID,
              state.activeRouteID == handoff.fromRouteID,
              let priorRoute = state.routes[handoff.fromRouteID],
              let candidateRoute = state.routes[handoff.toRouteID],
              candidateRoute.lifecycle == .planned,
              let candidateGeneration = state.generations[handoff.toGenerationID],
              candidateRoute.createdAt < priorRoute.createdAt || candidateGeneration.retiredAt != nil
        else { return false }
        let installs = state.installWork.values.filter { $0.routeID == handoff.toRouteID }
        guard installs.count == 1,
              installs[0].phase == .pendingStart,
              installs[0].retry.terminal == .superseded,
              installs[0].retry.lastErrorCode == "backward_handoff_cancelled"
        else { return false }
        return !state.activationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .succeeded
        }
    }

    private func canAbandonPausedCrossDaySupersededHandoff(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase != .committed,
              state.activeGenerationID == handoff.fromGenerationID,
              state.activeEpochID == handoff.fromEpochID,
              state.activeRouteID == handoff.fromRouteID,
              state.epochs[handoff.fromEpochID]?.status == .paused,
              let fromRoute = state.routes[handoff.fromRouteID],
              let rejectedRoute = state.routes[handoff.toRouteID],
              fromRoute.usageDate < rejectedRoute.usageDate,
              rejectedRoute.lifecycle == .tombstoned,
              let rejectedEpoch = state.epochs[handoff.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .activationSuperseded,
              state.tombstones[handoff.toRouteID] != nil
        else { return false }
        let installs = state.installWork.values.filter { $0.routeID == handoff.toRouteID }
        guard installs.count == 1 else { return false }
        let install = installs[0]
        let wasNeverInstalled = install.phase == .stopped
            && install.retry.terminal == .superseded
            && install.retry.lastErrorCode == "route_superseded"
            && state.tombstones[handoff.toRouteID]?.stopAcknowledgedAt != nil
        let stopIsDurablyPending = install.phase == .pendingStop
            && state.tombstones[handoff.toRouteID]?.stopAcknowledgedAt == nil
        guard wasNeverInstalled || stopIsDurablyPending else { return false }
        return !state.registrationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
        } && !state.activationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
        } && !state.activationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .succeeded
        }
    }

    /// #53 (FIX-0c): validator twin of the recovery driver's
    /// `abandonElapsedCandidateHandoffIfNeeded`. Purely structural — the
    /// temporal trigger (the candidate's day has ended) lives in the driver;
    /// this only whitelists the resulting delta: cutover never happened, the
    /// candidate is retired as superseded with a tombstone, its install is
    /// either durably pending-stop or stopped-with-acknowledgement, and no
    /// network work for it remains pending or succeeded-activated.
    private func canAbandonElapsedCandidate(
        _ handoff: V2RouteHandoff,
        in state: DeviceEpochStoreState
    ) -> Bool {
        guard handoff.phase != .committed,
              state.activeRouteID == handoff.fromRouteID,
              let rejectedRoute = state.routes[handoff.toRouteID],
              rejectedRoute.lifecycle == .tombstoned,
              let rejectedEpoch = state.epochs[handoff.toEpochID],
              rejectedEpoch.status == .retired,
              rejectedEpoch.retireReason == .activationSuperseded,
              state.tombstones[handoff.toRouteID] != nil
        else { return false }
        let installs = state.installWork.values.filter { $0.routeID == handoff.toRouteID }
        guard installs.count == 1 else { return false }
        let install = installs[0]
        let wasNeverInstalled = install.phase == .stopped
            && install.retry.terminal == .superseded
            && install.retry.lastErrorCode == "candidate_day_elapsed"
            && state.tombstones[handoff.toRouteID]?.stopAcknowledgedAt != nil
        let stopIsDurablyPending = install.phase == .pendingStop
            && state.tombstones[handoff.toRouteID]?.stopAcknowledgedAt == nil
        guard wasNeverInstalled || stopIsDurablyPending else { return false }
        return !state.registrationWork.values.contains {
            $0.routeID == handoff.toRouteID && $0.retry.terminal == .pending
        } && !state.activationWork.values.contains {
            $0.routeID == handoff.toRouteID
                && ($0.retry.terminal == .pending || $0.retry.terminal == .succeeded)
        }
    }

    private func restore(_ priorData: Data?, at url: URL) throws {
        var restoreError: Error?
        do {
            if let priorData {
                try fileIO.writeAtomically(priorData, to: url)
            } else {
                try fileIO.remove(at: url)
            }
        } catch {
            restoreError = error
        }

        let restoredData: Data?
        do {
            restoredData = try fileIO.read(from: url)
        } catch {
            throw DeviceEpochStoreError.restorationFailed
        }
        guard restoreError == nil, restoredData == priorData else {
            throw DeviceEpochStoreError.restorationFailed
        }
    }
}

extension DeviceEpochStoreState {
    /// The one unretired generation that best represents the latest desired
    /// policy when no active route or handoff has established provenance yet.
    /// Selection edits can mint several generations under one policy revision;
    /// only the newest may remain a registration-required candidate.
    func isNewestDesiredPolicyGeneration(owner: UUID, generationID: UUID) -> Bool {
        guard ownerChildDeviceID == owner,
              let desired = desiredPolicy,
              desired.ownerChildDeviceID == owner,
              let candidate = generations[generationID],
              candidate.childDeviceID == owner,
              candidate.retiredAt == nil,
              candidate.policyRevision == desired.policyRevision,
              candidate.canonicalTimezone == desired.canonicalTimezone,
              desired.enforcementSetID.map({ $0 == candidate.enforcementSetID }) ?? true
        else { return false }

        let newest = generations.values
            .filter { generation in
                generation.childDeviceID == owner
                    && generation.retiredAt == nil
                    && generation.policyRevision == desired.policyRevision
                    && generation.canonicalTimezone == desired.canonicalTimezone
                    && (
                        desired.enforcementSetID.map {
                            $0 == generation.enforcementSetID
                        } ?? true
                    )
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.generationID.uuidString.lowercased()
                    < $1.generationID.uuidString.lowercased()
            }
            .first
        return newest?.generationID == generationID
    }

    nonisolated func highestDurablyAcceptedMinutes(
        owner: UUID,
        epoch: DeviceDailyEpoch,
        route: MeteringCallbackRoute
    ) -> Int? {
        let registeredBases = registrationWork.values.compactMap { work -> Int? in
            guard work.ownerChildDeviceID == owner,
                  work.epochID == epoch.epochID,
                  work.routeID == route.routeID,
                  work.retry.terminal == .succeeded,
                  registrationRequest(work.request, matches: epoch, route: route, owner: owner)
            else { return nil }
            return work.request.baseAcceptedMinutes
        }
        let acceptedSamples = sampleWork.values.compactMap { work -> Int? in
            guard work.ownerChildDeviceID == owner,
                  work.epochID == epoch.epochID,
                  work.routeID == route.routeID,
                  work.retry.terminal == .succeeded,
                  work.request.protocolVersion == 2,
                  work.request.epochID == epoch.epochID,
                  work.request.deviceID == owner,
                  work.request.usageDate == epoch.usageDate
            else { return nil }
            return work.request.estimatedMinutes
        }
        return (registeredBases + acceptedSamples).max()
    }

    @discardableResult
    nonisolated mutating func reconcileEpochStartFromSuccessfulRegistration(
        _ work: EpochRegistrationWork
    ) -> Bool {
        guard work.retry.terminal == .succeeded,
              let route = routes[work.routeID],
              let epoch = epochs[work.epochID],
              registrationRequest(
                  work.request,
                  matches: epoch,
                  route: route,
                  owner: work.ownerChildDeviceID
              ),
              epoch.startedAt != work.request.startedAt
        else { return false }

        epochs[epoch.epochID] = DeviceDailyEpoch(
            epochID: epoch.epochID,
            protocolVersion: epoch.protocolVersion,
            childDeviceID: epoch.childDeviceID,
            usageDate: epoch.usageDate,
            canonicalTimezone: epoch.canonicalTimezone,
            policyRevision: epoch.policyRevision,
            measurementSelectionDigest: epoch.measurementSelectionDigest,
            enforcementSetID: epoch.enforcementSetID,
            startedAt: work.request.startedAt,
            registeredAt: epoch.registeredAt,
            baseAcceptedMinutes: epoch.baseAcceptedMinutes,
            baseSource: epoch.baseSource,
            lastRawThresholdMinutes: epoch.lastRawThresholdMinutes,
            excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
            status: epoch.status,
            resumeBoundaryPending: epoch.resumeBoundaryPending,
            retiredAt: epoch.retiredAt,
            retireReason: epoch.retireReason,
            exhaustedAt: epoch.exhaustedAt,
            baseCorrectionState: epoch.baseCorrectionState,
            authoritativeBaseConflict: epoch.authoritativeBaseConflict
        )
        return true
    }

    private nonisolated func registrationRequest(
        _ request: EpochRegistrationRequestDTO,
        matches epoch: DeviceDailyEpoch,
        route: MeteringCallbackRoute,
        owner: UUID
    ) -> Bool {
        request.protocolVersion == 2
            && request.deviceID == owner
            && request.epochID == epoch.epochID
            && route.epochID == epoch.epochID
            && route.ownerChildDeviceID == owner
            && request.usageDate == epoch.usageDate
            && request.usageDate == route.usageDate
            && request.timezone == epoch.canonicalTimezone
            && request.policyRevision == epoch.policyRevision
            && request.measurementSelectionDigest == epoch.measurementSelectionDigest
            && request.enforcementSetID == epoch.enforcementSetID
    }

    /// The day ceiling this route's ladder must respect, taken from the policy
    /// the generation was created with. `nil` only for generations persisted
    /// before pool/cap were captured — those get no clamp because inventing one
    /// would be worse than reporting the raw number.
    func ladderCeilingMinutes(for route: MeteringCallbackRoute) -> Int? {
        guard let generation = generations[route.generationID] else { return nil }
        return MeteringLadderMath.ceiling(
            poolMinutes: generation.configuredPoolMinutes,
            capMinutes: generation.configuredDeviceCapMinutes
        )
    }

    /// What a rung of `route`'s CURRENTLY PLANNED ladder is relative to.
    /// Falls back to the epoch base for routes persisted before
    /// `ladderBaseMinutes` existed.
    func ladderBaseMinutes(for route: MeteringCallbackRoute) -> Int {
        route.ladderBaseMinutes ?? epochs[route.epochID]?.baseAcceptedMinutes ?? 0
    }

    func hasCurrentInstallProvenance(
        owner: UUID,
        route: MeteringCallbackRoute,
        authorization: MeteringInstallAuthorization
    ) -> Bool {
        if hasCurrentRegistrationProvenance(
            owner: owner,
            epochID: route.epochID,
            routeID: route.routeID
        ) {
            return true
        }

        guard authorization == .futurePlanned,
              ownerChildDeviceID == owner,
              hasEligibleRouteEpochGeneration(
                  owner: owner,
                  route: route,
                  epoch: epochs[route.epochID],
                  generation: generations[route.generationID]
              ),
              currentHorizonUsageDates(
                  owner: owner,
                  generationID: route.generationID
              ).contains(route.usageDate),
              let handoff = v2RouteHandoff,
              handoff.ownerChildDeviceID == owner,
              handoff.toGenerationID == route.generationID,
              handoff.phase == .preparing
                || handoff.phase == .dualV2
                || handoff.phase == .cutoverReady
        else { return false }

        return hasExactHandoffPriorProvenance(owner: owner, handoff: handoff)
    }

    func isExactCanonicalRolloverCandidate(
        owner: UUID,
        handoff: V2RouteHandoff,
        route: MeteringCallbackRoute
    ) -> Bool {
        guard let rollover = rolloverEffectsWork else { return false }
        return rollover.retry.terminal == .pending
            && rollover.ownerChildDeviceID == owner
            && rollover.workID == handoff.handoffID
            && rollover.oldEpochID == handoff.fromEpochID
            && rollover.newEpochID == handoff.toEpochID
            && rollover.oldRouteID == handoff.fromRouteID
            && rollover.newRouteID == handoff.toRouteID
            && rollover.newRouteID == route.routeID
            && rollover.newEpochID == route.epochID
            && rollover.toUsageDate == route.usageDate
            && rollover.fromUsageDate != rollover.toUsageDate
    }

    func hasCurrentRegistrationProvenance(owner: UUID, epochID: UUID, routeID: UUID) -> Bool {
        guard ownerChildDeviceID == owner,
              let route = routes[routeID],
              let epoch = epochs[epochID],
              let generation = generations[route.generationID],
              hasEligibleRouteEpochGeneration(owner: owner, route: route, epoch: epoch, generation: generation),
              currentHorizonUsageDates(owner: owner, generationID: route.generationID).contains(route.usageDate)
        else { return false }

        if activeGenerationID == route.generationID {
            return true
        }

        guard let handoff = v2RouteHandoff,
              handoff.ownerChildDeviceID == owner,
              handoff.toGenerationID == route.generationID,
              handoff.toEpochID == epochID,
              handoff.toRouteID == routeID,
              handoff.phase == .preparing || handoff.phase == .dualV2 || handoff.phase == .cutoverReady
        else { return false }
        return hasExactHandoffPriorProvenance(owner: owner, handoff: handoff)
    }

    @discardableResult
    mutating func replaceAuthoritativeBaseMismatchCandidate(
        owner: UUID,
        rejectedEpochID: UUID,
        rejectedRouteID: UUID,
        conflict: EpochRegistrationConflictDTO,
        now: Date
    ) -> Bool {
        if replaceInitialAuthoritativeBaseMismatchCandidate(
            owner: owner,
            rejectedEpochID: rejectedEpochID,
            rejectedRouteID: rejectedRouteID,
            conflict: conflict,
            now: now
        ) {
            return true
        }

        guard ownerChildDeviceID == owner,
              var handoff = v2RouteHandoff,
              handoff.ownerChildDeviceID == owner,
              handoff.toEpochID == rejectedEpochID,
              handoff.toRouteID == rejectedRouteID,
              handoff.phase == .cutoverReady,
              let rejectedRoute = routes[rejectedRouteID],
              var rejectedEpoch = epochs[rejectedEpochID],
              let rejectedGeneration = generations[rejectedRoute.generationID],
              rejectedRoute.epochID == rejectedEpochID,
              rejectedEpoch.childDeviceID == owner,
              rejectedRoute.ownerChildDeviceID == owner,
              rejectedEpoch.authoritativeBaseConflict == nil,
              conflict.authoritativeSnapshot.childDeviceID == owner,
              conflict.authoritativeSnapshot.usageDate == rejectedEpoch.usageDate,
              conflict.authoritativeSnapshot.usageDate == rejectedRoute.usageDate,
              let rejectedCanonicalDayEnd = canonicalDayEnd(
                  usageDate: rejectedRoute.usageDate,
                  timeZoneIdentifier: rejectedEpoch.canonicalTimezone
              )
        else { return false }

        let correctionAvailable = rejectedEpoch.baseCorrectionState == .available
        terminalizeAuthoritativeBaseCandidate(
            epochID: rejectedEpochID,
            routeID: rejectedRouteID,
            conflict: conflict,
            canonicalDayEnd: rejectedCanonicalDayEnd,
            now: now
        )

        // A correction is intentionally single-use. The cutoverReady invariant
        // guarantees a LIVE prior route here, so a second 409 falls back to it
        // and mints nothing. (The dead-end case — no live prior — is the
        // INITIAL path below, where the budget is relaxed.)
        guard correctionAvailable else {
            v2RouteHandoff = nil
            return false
        }

        guard let terminalizedRejectedEpoch = epochs[rejectedEpochID] else { return false }
        rejectedEpoch = terminalizedRejectedEpoch
        let correctedGenerationID = UUID()
        let correctedEpochID = UUID()
        let correctedRouteID = UUID()
        let correctedInstallID = UUID()
        let correctedRegistrationID = UUID()
        let correctedGeneration = MeteringPolicyGeneration(
            generationID: correctedGenerationID,
            protocolVersion: rejectedGeneration.protocolVersion,
            childDeviceID: owner,
            canonicalTimezone: rejectedGeneration.canonicalTimezone,
            policyRevision: rejectedGeneration.policyRevision,
            measurementSelectionDigest: rejectedGeneration.measurementSelectionDigest,
            enforcementSetID: rejectedGeneration.enforcementSetID,
            measurementSelectionBytes: rejectedGeneration.measurementSelectionBytes,
            createdAt: now,
            retiredAt: nil,
            configuredPoolMinutes: rejectedGeneration.configuredPoolMinutes,
            configuredDeviceCapMinutes: rejectedGeneration.configuredDeviceCapMinutes
        )
        let correctedEpoch = DeviceDailyEpoch(
            epochID: correctedEpochID,
            protocolVersion: rejectedEpoch.protocolVersion,
            childDeviceID: owner,
            usageDate: rejectedEpoch.usageDate,
            canonicalTimezone: rejectedEpoch.canonicalTimezone,
            policyRevision: rejectedEpoch.policyRevision,
            measurementSelectionDigest: rejectedEpoch.measurementSelectionDigest,
            enforcementSetID: rejectedEpoch.enforcementSetID,
            startedAt: now,
            registeredAt: nil,
            baseAcceptedMinutes: conflict.authoritativeSnapshot.estimatedMinutes,
            baseSource: .registrationConflict409,
            lastRawThresholdMinutes: 0,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .used
        )
        let correctedRoute = MeteringCallbackRoute(
            routeID: correctedRouteID,
            activityName: callbackActivityName(routeID: correctedRouteID),
            namespace: "evlin.earned.v2.",
            generationID: correctedGenerationID,
            generationKey: rejectedRoute.generationKey,
            ownerChildDeviceID: owner,
            usageDate: rejectedRoute.usageDate,
            epochID: correctedEpochID,
            plannedSchedule: rejectedRoute.plannedSchedule,
            installedSchedule: nil,
            plannedEvents: rejectedRoute.plannedEvents.map { event in
                MeteringEventPlan(
                    eventName: callbackEventName(routeID: correctedRouteID, thresholdMinutes: event.thresholdMinutes),
                    thresholdMinutes: event.thresholdMinutes
                )
            },
            installedEvents: nil,
            lifecycle: .planned,
            createdAt: now,
            // Deliberately carries the REJECTED route's ladder base: the rungs
            // are a relabelled copy of the old ladder, while the epoch's base
            // jumps to the backend's authoritative figure. Recording the honest
            // (stale) base is what lets `repairLadderBaseInvariantIfNeeded`
            // notice the split and re-cut, instead of the split silently
            // re-pricing every rung (BUG 1).
            ladderBaseMinutes: rejectedRoute.ladderBaseMinutes
        )
        let pendingRetry = MeteringRetryState(
            attemptCount: 0,
            nextAttemptAt: now,
            lastErrorCode: nil,
            terminal: .pending
        )
        let correctedRequest = EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: correctedEpochID,
            deviceID: owner,
            usageDate: correctedEpoch.usageDate,
            timezone: correctedEpoch.canonicalTimezone,
            policyRevision: correctedEpoch.policyRevision,
            measurementSelectionDigest: correctedEpoch.measurementSelectionDigest,
            enforcementSetID: correctedEpoch.enforcementSetID,
            startedAt: correctedEpoch.startedAt,
            baseAcceptedMinutes: correctedEpoch.baseAcceptedMinutes,
            reason: .policyChange
        )

        generations[correctedGenerationID] = correctedGeneration
        epochs[correctedEpochID] = correctedEpoch
        routes[correctedRouteID] = correctedRoute
        installWork[correctedInstallID] = ActivityInstallWork(
            workID: correctedInstallID,
            ownerChildDeviceID: owner,
            routeID: correctedRouteID,
            authorization: .offlinePending,
            phase: .pendingStart,
            claim: nil,
            retry: pendingRetry,
            createdAt: now
        )
        registrationWork[correctedRegistrationID] = EpochRegistrationWork(
            workID: correctedRegistrationID,
            ownerChildDeviceID: owner,
            epochID: correctedEpochID,
            routeID: correctedRouteID,
            request: correctedRequest,
            claim: nil,
            retry: pendingRetry,
            createdAt: now
        )
        handoff = V2RouteHandoff(
            handoffID: UUID(),
            ownerChildDeviceID: owner,
            fromGenerationID: handoff.fromGenerationID,
            fromEpochID: handoff.fromEpochID,
            fromRouteID: handoff.fromRouteID,
            toGenerationID: correctedGenerationID,
            toEpochID: correctedEpochID,
            toRouteID: correctedRouteID,
            phase: .preparing,
            priorRouteInputClosedAt: nil,
            registrationAcknowledgedAt: nil,
            activationAcknowledgedAt: nil,
            priorStopAcknowledgedAt: nil,
            createdAt: now,
            consumedCandidateReplacementCount:
                handoff.consumedCandidateReplacementCount
        )
        v2RouteHandoff = handoff
        return true
    }

    @discardableResult
    mutating func replaceConsumedHandoffCandidateIfNeeded(
        owner: UUID,
        now: Date
    ) -> Bool {
        let replacementRouteID = UUID()
        guard ownerChildDeviceID == owner,
              let current = v2RouteHandoff,
              current.ownerChildDeviceID == owner,
              current.phase == .preparing
                || current.phase == .dualV2
                || current.phase == .cutoverReady,
              hasExactHandoffPriorProvenance(owner: owner, handoff: current),
              var rejectedRoute = routes[current.toRouteID],
              var rejectedEpoch = epochs[current.toEpochID],
              let rejectedGeneration = generations[current.toGenerationID],
              rejectedRoute.routeID == current.toRouteID,
              rejectedRoute.epochID == rejectedEpoch.epochID,
              rejectedRoute.generationID == rejectedGeneration.generationID,
              rejectedRoute.ownerChildDeviceID == owner,
              rejectedEpoch.childDeviceID == owner,
              rejectedEpoch.status == .active,
              rejectedEpoch.retiredAt == nil,
              let rejectedInstallKey = installWork.first(where: {
                  $0.value.routeID == rejectedRoute.routeID
              })?.key,
              installWork.values.filter({
                  $0.routeID == rejectedRoute.routeID
              }).count == 1,
              (installWork[rejectedInstallKey]?.retry.lastErrorCode
                == "physical_events_consumed_too_early"
                || installWork[rejectedInstallKey]?.retry.lastErrorCode
                    == "arm_grace_calibration_requires_offset_recut"),
              !rejectedRoute.plannedEvents.isEmpty,
              let dayEnd = canonicalDayEnd(
                  usageDate: rejectedRoute.usageDate,
                  timeZoneIdentifier: rejectedEpoch.canonicalTimezone
              )
        else { return false }

        let rejectedOffset = max(
            0, rejectedRoute.physicalGenerationOffsetMinutes ?? 0
        )
        let replacementOffset = max(
            rejectedOffset,
            rejectedEpoch.excludedWhilePausedMinutes
        )
        let replacementEvents = rejectedRoute.plannedEvents.map {
            let logicalThreshold = max(0, $0.thresholdMinutes - rejectedOffset)
            let physicalThreshold = logicalThreshold + replacementOffset
            return MeteringEventPlan(
                eventName: callbackEventName(
                    routeID: replacementRouteID,
                    thresholdMinutes: physicalThreshold
                ),
                thresholdMinutes: physicalThreshold
            )
        }
        let replacementGenerationID = UUID()
        let replacementEpochID = UUID()
        let replacementInstallID = UUID()
        let pending = MeteringRetryState(
            attemptCount: 0,
            nextAttemptAt: now,
            lastErrorCode: nil,
            terminal: .pending
        )

        rejectedEpoch.status = .retired
        rejectedEpoch.retiredAt = now
        rejectedEpoch.retireReason = .identityRecovery
        epochs[rejectedEpoch.epochID] = rejectedEpoch
        if rejectedGeneration.generationID != current.fromGenerationID {
            generations[rejectedGeneration.generationID]?.retiredAt = now
        }
        rejectedRoute.lifecycle = .tombstoned
        routes[rejectedRoute.routeID] = rejectedRoute

        let relatedWorkIDs = Set(
            registrationWork.values.filter {
                $0.epochID == rejectedEpoch.epochID
                    && $0.routeID == rejectedRoute.routeID
            }.map(\.workID)
            + activationWork.values.filter {
                $0.epochID == rejectedEpoch.epochID
                    && $0.routeID == rejectedRoute.routeID
            }.map(\.workID)
            + sampleWork.values.filter {
                $0.epochID == rejectedEpoch.epochID
                    && $0.routeID == rejectedRoute.routeID
            }.map(\.workID)
            + installWork.values.filter {
                $0.routeID == rejectedRoute.routeID
            }.map(\.workID)
        )
        tombstones[rejectedRoute.routeID] = MeteringRouteTombstone(
            routeID: rejectedRoute.routeID,
            activityName: rejectedRoute.activityName,
            eventNames: rejectedRoute.plannedEvents.map(\.eventName),
            ownerChildDeviceID: owner,
            usageDate: rejectedRoute.usageDate,
            epochID: rejectedEpoch.epochID,
            generationID: rejectedGeneration.generationID,
            canonicalDayEnd: dayEnd,
            stopAcknowledgedAt: nil,
            referencedWorkIDs: relatedWorkIDs,
            retainedUntil: nil
        )
        for (key, var work) in registrationWork
        where work.routeID == rejectedRoute.routeID {
            work.claim = nil
            work.retry = terminalRetry(
                work.retry,
                code: "physical_events_consumed_too_early"
            )
            registrationWork[key] = work
        }
        for (key, var work) in activationWork
        where work.routeID == rejectedRoute.routeID {
            work.claim = nil
            work.retry = terminalRetry(
                work.retry,
                code: "physical_events_consumed_too_early"
            )
            activationWork[key] = work
        }
        for (key, var work) in sampleWork
        where work.routeID == rejectedRoute.routeID {
            work.claim = nil
            work.retry = terminalRetry(
                work.retry,
                code: "physical_events_consumed_too_early"
            )
            sampleWork[key] = work
        }
        var rejectedInstall = installWork[rejectedInstallKey]!
        rejectedInstall.claim = nil
        rejectedInstall.phase = .pendingStop
        rejectedInstall.retry = MeteringRetryState(
            attemptCount: 0,
            nextAttemptAt: now,
            lastErrorCode: "physical_events_consumed_too_early",
            terminal: .pending
        )
        installWork[rejectedInstallKey] = rejectedInstall

        // A physical replacement is intentionally single-use. If Apple also
        // consumes the replacement at install time, preserve the functioning
        // prior authority and retire the candidate instead of minting an
        // unbounded chain of identities.
        guard (current.consumedCandidateReplacementCount ?? 0) < 1 else {
            v2RouteHandoff = nil
            return true
        }

        let replacementGeneration = MeteringPolicyGeneration(
            generationID: replacementGenerationID,
            protocolVersion: rejectedGeneration.protocolVersion,
            childDeviceID: owner,
            canonicalTimezone: rejectedGeneration.canonicalTimezone,
            policyRevision: rejectedGeneration.policyRevision,
            measurementSelectionDigest: rejectedGeneration.measurementSelectionDigest,
            enforcementSetID: rejectedGeneration.enforcementSetID,
            measurementSelectionBytes: rejectedGeneration.measurementSelectionBytes,
            createdAt: now,
            retiredAt: nil,
            configuredPoolMinutes: rejectedGeneration.configuredPoolMinutes,
            configuredDeviceCapMinutes: rejectedGeneration.configuredDeviceCapMinutes
        )
        let replacementEpoch = DeviceDailyEpoch(
            epochID: replacementEpochID,
            protocolVersion: rejectedEpoch.protocolVersion,
            childDeviceID: owner,
            usageDate: rejectedEpoch.usageDate,
            canonicalTimezone: rejectedEpoch.canonicalTimezone,
            policyRevision: rejectedEpoch.policyRevision,
            measurementSelectionDigest: rejectedEpoch.measurementSelectionDigest,
            enforcementSetID: rejectedEpoch.enforcementSetID,
            startedAt: now,
            registeredAt: nil,
            baseAcceptedMinutes: rejectedEpoch.baseAcceptedMinutes,
            baseSource: rejectedEpoch.baseSource,
            lastRawThresholdMinutes: replacementOffset,
            excludedWhilePausedMinutes: replacementOffset,
            status: .active,
            resumeBoundaryPending: rejectedEpoch.resumeBoundaryPending,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: rejectedEpoch.baseCorrectionState
        )
        let replacementRoute = MeteringCallbackRoute(
            routeID: replacementRouteID,
            activityName: callbackActivityName(routeID: replacementRouteID),
            namespace: rejectedRoute.namespace,
            generationID: replacementGenerationID,
            generationKey: rejectedRoute.generationKey,
            ownerChildDeviceID: owner,
            usageDate: rejectedRoute.usageDate,
            epochID: replacementEpochID,
            plannedSchedule: DatedSchedulePlan(
                usageDate: rejectedRoute.usageDate,
                timezoneIdentifier: rejectedRoute.plannedSchedule.timezoneIdentifier,
                calendarIdentifier: rejectedRoute.plannedSchedule.calendarIdentifier,
                topologyVersion: DatedSchedulePlan.currentTopologyVersion,
                intervalStartAt: now
            ),
            installedSchedule: nil,
            plannedEvents: replacementEvents,
            installedEvents: nil,
            lifecycle: .planned,
            createdAt: now,
            ladderBaseMinutes: rejectedEpoch.baseAcceptedMinutes,
            physicalGenerationOffsetMinutes: replacementOffset
        )
        generations[replacementGenerationID] = replacementGeneration
        epochs[replacementEpochID] = replacementEpoch
        routes[replacementRouteID] = replacementRoute
        installWork[replacementInstallID] = ActivityInstallWork(
            workID: replacementInstallID,
            ownerChildDeviceID: owner,
            routeID: replacementRouteID,
            authorization: .offlinePending,
            phase: .pendingStart,
            claim: nil,
            retry: pending,
            createdAt: now
        )
        v2RouteHandoff = V2RouteHandoff(
            handoffID: UUID(),
            ownerChildDeviceID: owner,
            fromGenerationID: current.fromGenerationID,
            fromEpochID: current.fromEpochID,
            fromRouteID: current.fromRouteID,
            toGenerationID: replacementGenerationID,
            toEpochID: replacementEpochID,
            toRouteID: replacementRouteID,
            phase: .preparing,
            priorRouteInputClosedAt: nil,
            registrationAcknowledgedAt: nil,
            activationAcknowledgedAt: nil,
            priorStopAcknowledgedAt: nil,
            createdAt: now,
            explicitRecovery: current.explicitRecovery ?? .identityRecovery,
            consumedCandidateReplacementCount:
                (current.consumedCandidateReplacementCount ?? 0) + 1
        )
        return true
    }

    private mutating func replaceInitialAuthoritativeBaseMismatchCandidate(
        owner: UUID,
        rejectedEpochID: UUID,
        rejectedRouteID: UUID,
        conflict: EpochRegistrationConflictDTO,
        now: Date
    ) -> Bool {
        guard ownerChildDeviceID == owner,
              v2RouteHandoff == nil,
              ratchets[owner] == nil || ratchets[owner]?.localSelection == .v1,
              activeGenerationID != nil,
              activeEpochID == rejectedEpochID,
              activeRouteID == nil,
              let rejectedRoute = routes[rejectedRouteID],
              var rejectedEpoch = epochs[rejectedEpochID],
              let rejectedGeneration = generations[rejectedRoute.generationID],
              activeGenerationID == rejectedGeneration.generationID,
              rejectedRoute.epochID == rejectedEpochID,
              rejectedRoute.ownerChildDeviceID == owner,
              rejectedRoute.lifecycle == .planned,
              rejectedEpoch.childDeviceID == owner,
              rejectedEpoch.status == .active,
              rejectedEpoch.registeredAt == nil,
              (rejectedEpoch.authoritativeBaseConflict == nil
                  || rejectedEpoch.authoritativeBaseConflict == conflict),
              // The correction budget is single-use to stop a LOOP, not to
              // stop progress. On this path there is no live prior route to
              // fall back to (no handoff, no active route), so refusing a
              // second 409 left the device with a candidate that could never
              // register: the installer deferred `registrationRequired` every
              // minute, no sample was ever sent, and the pool stayed frozen
              // for the rest of the day while the parent's badge still read
              // ACTIVE (Fred's K-iPhone, 2026-08-13 15:00 onward — per-app
              // limits kept counting, the pool did not). A second 409 whose
              // authoritative base MOVED is new information (minutes accrued
              // between attempts) and must be adoptable; one repeating the
              // number we already adopted is a real loop and stays refused.
              (rejectedEpoch.baseCorrectionState == .available
                  || rejectedEpoch.baseAcceptedMinutes
                      != conflict.authoritativeSnapshot.estimatedMinutes),
              conflict.authoritativeSnapshot.childDeviceID == owner,
              conflict.authoritativeSnapshot.usageDate == rejectedEpoch.usageDate,
              conflict.authoritativeSnapshot.usageDate == rejectedRoute.usageDate,
              let rejectedInstallKey = installWork.first(where: {
                  $0.value.routeID == rejectedRouteID
              })?.key,
              installWork.values.filter({ $0.routeID == rejectedRouteID }).count == 1,
              installWork[rejectedInstallKey]?.phase == .pendingStart,
              !registrationWork.values.contains(where: {
                  $0.epochID == rejectedEpochID
                      && $0.routeID == rejectedRouteID
                      && $0.retry.terminal == .succeeded
              }),
              !activationWork.values.contains(where: {
                  $0.epochID == rejectedEpochID
                      && $0.routeID == rejectedRouteID
                      && $0.retry.terminal == .succeeded
              }),
              let rejectedCanonicalDayEnd = canonicalDayEnd(
                  usageDate: rejectedRoute.usageDate,
                  timeZoneIdentifier: rejectedEpoch.canonicalTimezone
              )
        else { return false }

        terminalizeAuthoritativeBaseCandidate(
            epochID: rejectedEpochID,
            routeID: rejectedRouteID,
            conflict: conflict,
            canonicalDayEnd: rejectedCanonicalDayEnd,
            now: now
        )
        guard let terminalizedRejectedEpoch = epochs[rejectedEpochID] else { return false }
        rejectedEpoch = terminalizedRejectedEpoch

        let correctedGenerationID = UUID()
        let correctedEpochID = UUID()
        let correctedRouteID = UUID()
        let correctedInstallID = UUID()
        let correctedRegistrationID = UUID()
        let correctedGeneration = MeteringPolicyGeneration(
            generationID: correctedGenerationID,
            protocolVersion: rejectedGeneration.protocolVersion,
            childDeviceID: owner,
            canonicalTimezone: rejectedGeneration.canonicalTimezone,
            policyRevision: rejectedGeneration.policyRevision,
            measurementSelectionDigest: rejectedGeneration.measurementSelectionDigest,
            enforcementSetID: rejectedGeneration.enforcementSetID,
            measurementSelectionBytes: rejectedGeneration.measurementSelectionBytes,
            createdAt: now,
            retiredAt: nil,
            configuredPoolMinutes: rejectedGeneration.configuredPoolMinutes,
            configuredDeviceCapMinutes: rejectedGeneration.configuredDeviceCapMinutes
        )
        let correctedEpoch = DeviceDailyEpoch(
            epochID: correctedEpochID,
            protocolVersion: rejectedEpoch.protocolVersion,
            childDeviceID: owner,
            usageDate: rejectedEpoch.usageDate,
            canonicalTimezone: rejectedEpoch.canonicalTimezone,
            policyRevision: rejectedEpoch.policyRevision,
            measurementSelectionDigest: rejectedEpoch.measurementSelectionDigest,
            enforcementSetID: rejectedEpoch.enforcementSetID,
            startedAt: now,
            registeredAt: nil,
            baseAcceptedMinutes: conflict.authoritativeSnapshot.estimatedMinutes,
            baseSource: .registrationConflict409,
            lastRawThresholdMinutes: 0,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .used
        )
        let correctedRoute = MeteringCallbackRoute(
            routeID: correctedRouteID,
            activityName: callbackActivityName(routeID: correctedRouteID),
            namespace: "evlin.earned.v2.",
            generationID: correctedGenerationID,
            generationKey: rejectedRoute.generationKey,
            ownerChildDeviceID: owner,
            usageDate: rejectedRoute.usageDate,
            epochID: correctedEpochID,
            plannedSchedule: rejectedRoute.plannedSchedule,
            installedSchedule: nil,
            plannedEvents: rejectedRoute.plannedEvents.map { event in
                MeteringEventPlan(
                    eventName: callbackEventName(
                        routeID: correctedRouteID,
                        thresholdMinutes: event.thresholdMinutes
                    ),
                    thresholdMinutes: event.thresholdMinutes
                )
            },
            installedEvents: nil,
            lifecycle: .planned,
            createdAt: now,
            // Deliberately carries the REJECTED route's ladder base: the rungs
            // are a relabelled copy of the old ladder, while the epoch's base
            // jumps to the backend's authoritative figure. Recording the honest
            // (stale) base is what lets `repairLadderBaseInvariantIfNeeded`
            // notice the split and re-cut, instead of the split silently
            // re-pricing every rung (BUG 1).
            ladderBaseMinutes: rejectedRoute.ladderBaseMinutes
        )
        let pendingRetry = MeteringRetryState(
            attemptCount: 0,
            nextAttemptAt: now,
            lastErrorCode: nil,
            terminal: .pending
        )
        let correctedRequest = EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: correctedEpochID,
            deviceID: owner,
            usageDate: correctedEpoch.usageDate,
            timezone: correctedEpoch.canonicalTimezone,
            policyRevision: correctedEpoch.policyRevision,
            measurementSelectionDigest: correctedEpoch.measurementSelectionDigest,
            enforcementSetID: correctedEpoch.enforcementSetID,
            startedAt: correctedEpoch.startedAt,
            baseAcceptedMinutes: correctedEpoch.baseAcceptedMinutes,
            reason: .initial
        )

        generations[correctedGenerationID] = correctedGeneration
        epochs[correctedEpochID] = correctedEpoch
        routes[correctedRouteID] = correctedRoute
        installWork[correctedInstallID] = ActivityInstallWork(
            workID: correctedInstallID,
            ownerChildDeviceID: owner,
            routeID: correctedRouteID,
            authorization: .registrationRequired,
            phase: .pendingStart,
            claim: nil,
            retry: pendingRetry,
            createdAt: now
        )
        registrationWork[correctedRegistrationID] = EpochRegistrationWork(
            workID: correctedRegistrationID,
            ownerChildDeviceID: owner,
            epochID: correctedEpochID,
            routeID: correctedRouteID,
            request: correctedRequest,
            claim: nil,
            retry: pendingRetry,
            createdAt: now
        )
        activeGenerationID = correctedGenerationID
        activeEpochID = correctedEpochID
        activeRouteID = nil
        return true
    }

    private mutating func terminalizeAuthoritativeBaseCandidate(
        epochID: UUID,
        routeID: UUID,
        conflict: EpochRegistrationConflictDTO,
        canonicalDayEnd: Date,
        now: Date
    ) {
        guard var epoch = epochs[epochID], var route = routes[routeID] else { return }
        epoch.authoritativeBaseConflict = conflict
        epoch.baseCorrectionState = .used
        epoch.status = .retired
        epoch.retiredAt = now
        epoch.retireReason = .authoritativeBaseMismatch
        epochs[epochID] = epoch
        let generationStillOwnsActivePrior = activeRouteID
            .flatMap { routes[$0] }
            .map {
                $0.routeID != routeID
                    && $0.generationID == route.generationID
                    && $0.lifecycle == .active
            } ?? false
        if !generationStillOwnsActivePrior {
            generations[route.generationID]?.retiredAt = now
        }

        route.lifecycle = .tombstoned
        routes[routeID] = route
        let relatedWorkIDs = Set(
            registrationWork.values.filter { $0.epochID == epochID && $0.routeID == routeID }.map(\.workID)
                + activationWork.values.filter { $0.epochID == epochID && $0.routeID == routeID }.map(\.workID)
                + sampleWork.values.filter { $0.epochID == epochID && $0.routeID == routeID }.map(\.workID)
                + installWork.values.filter { $0.routeID == routeID }.map(\.workID)
        )
        tombstones[routeID] = MeteringRouteTombstone(
            routeID: routeID,
            activityName: route.activityName,
            eventNames: route.plannedEvents.map(\.eventName),
            ownerChildDeviceID: route.ownerChildDeviceID,
            usageDate: route.usageDate,
            epochID: epochID,
            generationID: route.generationID,
            canonicalDayEnd: canonicalDayEnd,
            stopAcknowledgedAt: nil,
            referencedWorkIDs: relatedWorkIDs,
            retainedUntil: nil
        )
        for (key, var work) in registrationWork where work.epochID == epochID && work.routeID == routeID {
            work.claim = nil
            work.retry = terminalRetry(work.retry, code: "authoritative_base_mismatch")
            registrationWork[key] = work
        }
        for (key, var work) in activationWork where work.epochID == epochID && work.routeID == routeID {
            work.claim = nil
            work.retry = terminalRetry(work.retry, code: "authoritative_base_mismatch")
            activationWork[key] = work
        }
        for (key, var work) in sampleWork where work.epochID == epochID && work.routeID == routeID {
            work.claim = nil
            work.retry = terminalRetry(work.retry, code: "authoritative_base_mismatch")
            sampleWork[key] = work
        }
        for (key, var work) in installWork where work.routeID == routeID {
            work.claim = nil
            work.phase = .pendingStop
            work.retry = terminalRetry(work.retry, code: "authoritative_base_mismatch")
            installWork[key] = work
        }
    }

    func canonicalDayEnd(
        usageDate: String,
        timeZoneIdentifier: String
    ) -> Date? {
        let parts = usageDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let timeZone = TimeZone(identifier: timeZoneIdentifier)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let start = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: start)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day
        else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    private func terminalRetry(_ retry: MeteringRetryState, code: String) -> MeteringRetryState {
        MeteringRetryState(
            attemptCount: retry.attemptCount,
            nextAttemptAt: retry.nextAttemptAt,
            lastErrorCode: code,
            terminal: .superseded
        )
    }

    private func callbackActivityName(routeID: UUID) -> String {
        "evlin.earned.v2.\(routeID.uuidString.lowercased())"
    }

    private func callbackEventName(routeID: UUID, thresholdMinutes: Int) -> String {
        "\(callbackActivityName(routeID: routeID)).t\(thresholdMinutes)"
    }

    func hasExactHandoffPriorProvenance(owner: UUID, handoff: V2RouteHandoff) -> Bool {
        guard handoff.ownerChildDeviceID == owner,
              handoff.phase == .preparing || handoff.phase == .dualV2 || handoff.phase == .cutoverReady,
              let fromRoute = routes[handoff.fromRouteID],
              let fromEpoch = epochs[handoff.fromEpochID],
              let fromGeneration = generations[handoff.fromGenerationID],
              let toRoute = routes[handoff.toRouteID],
              let toEpoch = epochs[handoff.toEpochID],
              fromRoute.ownerChildDeviceID == owner,
              fromRoute.routeID == handoff.fromRouteID,
              fromRoute.epochID == handoff.fromEpochID,
              fromRoute.generationID == handoff.fromGenerationID,
              fromRoute.lifecycle == .active,
              fromEpoch.childDeviceID == owner,
              fromEpoch.epochID == handoff.fromEpochID,
              fromGeneration.childDeviceID == owner,
              fromGeneration.generationID == handoff.fromGenerationID,
              fromGeneration.retiredAt == nil,
              activeRouteID == handoff.fromRouteID,
              activeEpochID == handoff.fromEpochID,
              activeGenerationID == handoff.fromGenerationID
        else { return false }

        let hasActivePrior = fromEpoch.status == .active
            && fromEpoch.retiredAt == nil
            && hasEligibleRouteEpochGeneration(
                owner: owner,
                route: fromRoute,
                epoch: fromEpoch,
                generation: fromGeneration
            )
            && (
                currentHorizonUsageDates(
                    owner: owner,
                    generationID: handoff.fromGenerationID
                ).contains(fromRoute.usageDate)
                || isExactCanonicalDayRolloverPrior(
                    handoff: handoff,
                    fromRoute: fromRoute,
                    fromEpoch: fromEpoch,
                    toRoute: toRoute,
                    toEpoch: toEpoch,
                    generation: fromGeneration
                )
            )
        if hasActivePrior { return true }

        // A closed accounting gate must not erase the next canonical day.
        // Task and reflection locks intentionally pause the predecessor, and
        // the server registers the new-day epoch as paused until the gate
        // reopens. The tuple below is still an exact canonical rollover: same
        // owner, generation and immutable policy fields, advancing by exactly
        // one local calendar day. Allowing that tuple to activate as paused
        // gives the device a registered identity for today without permitting
        // accounting while the gate remains closed.
        let hasPausedCanonicalRolloverPrior = fromEpoch.status == .paused
            && fromEpoch.retiredAt == nil
            && isExactCanonicalDayRolloverPrior(
                handoff: handoff,
                fromRoute: fromRoute,
                fromEpoch: fromEpoch,
                toRoute: toRoute,
                toEpoch: toEpoch,
                generation: fromGeneration
            )
        if hasPausedCanonicalRolloverPrior { return true }

        // `.active` is accepted alongside `.paused`: the SERVER now reopens the
        // gate in place (`mark_metering_gate_open`), so by the time this
        // resume handoff reaches its cutover the predecessor it was minted for
        // has frequently already been flipped back to running. Demanding
        // `.paused` made the authorization fail forever — the activation work
        // never became eligible (attempts=0), the handoff sat in
        // `cutoverReady`, the retired predecessor kept receiving every bell,
        // and the pool froze while all three surfaces reported healthy
        // (2026-08-07, real device, 50 minutes). The other conditions below
        // still pin this to exactly one same-day, same-generation, same-policy
        // conservative resume, so widening the status is not a loosening of
        // provenance.
        // NOTE on `resumeBoundaryPending`: it is a ONE-SHOT flag, consumed the
        // moment the candidate receives its first bell (the sacrificed
        // calibration rung). Requiring it here made this authorization a race:
        // if a bell arrived before the cutover ran — which is exactly what
        // happens whenever activation is delayed at all — the flag was already
        // false and the handoff could never be authorized again. The pool then
        // froze with the retired predecessor still receiving every bell
        // (2026-08-07, real device: flag consumed at 20:42:05, activation work
        // created at 20:43:42, dead ever after).
        //
        // The handoff's own `explicitRecovery` records what this cutover IS and
        // is never consumed, so it is the durable form of the same fact.
        let candidateIsConservativeResume = toEpoch.resumeBoundaryPending
            || handoff.explicitRecovery == .gateResumeConservative
        let hasPausedPriorConservativeResume = (
                fromEpoch.status == .paused || fromEpoch.status == .active
            )
            && fromEpoch.retiredAt == nil
            && toEpoch.status == .active
            && toEpoch.retiredAt == nil
            && candidateIsConservativeResume
            && toEpoch.baseSource == .childState200
            && handoff.fromGenerationID == handoff.toGenerationID
            && fromRoute.usageDate == toRoute.usageDate
            && fromRoute.usageDate == fromEpoch.usageDate
            && toRoute.usageDate == toEpoch.usageDate
            && fromEpoch.canonicalTimezone == toEpoch.canonicalTimezone
            && fromEpoch.policyRevision == toEpoch.policyRevision
            && fromEpoch.measurementSelectionDigest == toEpoch.measurementSelectionDigest
            && fromEpoch.enforcementSetID == toEpoch.enforcementSetID
            && ratchets[owner]?.localSelection == .v2
        if hasPausedPriorConservativeResume { return true }

        let hasPausedPriorCrossDayResume: Bool = {
            guard fromEpoch.status == .paused,
                  fromEpoch.retiredAt == nil,
                  toEpoch.status == .active,
                  toEpoch.retiredAt == nil,
                  toEpoch.resumeBoundaryPending,
                  toEpoch.baseSource == .childState200,
                  fromRoute.usageDate == fromEpoch.usageDate,
                  toRoute.usageDate == toEpoch.usageDate,
                  fromRoute.usageDate < toRoute.usageDate,
                  let toGeneration = generations[handoff.toGenerationID],
                  toGeneration.childDeviceID == owner,
                  toGeneration.retiredAt == nil,
                  toRoute.ownerChildDeviceID == owner,
                  toRoute.generationID == toGeneration.generationID,
                  toRoute.epochID == toEpoch.epochID,
                  toEpoch.canonicalTimezone == toGeneration.canonicalTimezone,
                  toEpoch.policyRevision == toGeneration.policyRevision,
                  toEpoch.measurementSelectionDigest == toGeneration.measurementSelectionDigest,
                  toEpoch.enforcementSetID == toGeneration.enforcementSetID,
                  let desiredPolicy,
                  desiredPolicy.ownerChildDeviceID == owner,
                  desiredPolicy.usageDate == toEpoch.usageDate,
                  desiredPolicy.canonicalTimezone == toEpoch.canonicalTimezone,
                  desiredPolicy.policyRevision == toEpoch.policyRevision,
                  desiredPolicy.enforcementSetID == nil
                    || desiredPolicy.enforcementSetID == toEpoch.enforcementSetID,
                  ratchets[owner]?.localSelection == .v2
            else { return false }
            return true
        }()
        if hasPausedPriorCrossDayResume { return true }

        // An already-activated initial epoch can be authoritatively retired
        // before this device observes the response. It may make exactly one
        // replacement cutover, but only after the initial v2 ratchet and only
        // once the prior lane has passed the same closed-input barrier as a
        // normal active-prior cutover.
        let hasAcknowledgedRetiredPriorRecovery = handoff.phase == .cutoverReady
            && fromEpoch.status == .retired
            && fromEpoch.retiredAt == nil
            && ratchets[owner]?.localSelection == .v2
            && ratchets[owner]?.advertisedVersion == 2
            && ratchets[owner]?.activatedV2At != nil
            && legacy?.phase == .stoppedV1
            && fromRoute.usageDate == toRoute.usageDate
            && isValidUsageDate(
                fromRoute.usageDate,
                timeZoneIdentifier: fromGeneration.canonicalTimezone
            )
        return hasAcknowledgedRetiredPriorRecovery
    }

    func hasExactStaleDayPriorAbsent(owner: UUID, handoff: V2RouteHandoff) -> Bool {
        guard hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
              let fromRoute = routes[handoff.fromRouteID],
              let toRoute = routes[handoff.toRouteID],
              fromRoute.usageDate < toRoute.usageDate,
              isStaleActiveRouteConfirmedAbsent(
                  owner: owner,
                  routeID: handoff.fromRouteID
              )
        else { return false }
        return true
    }

    func isStaleActiveRouteConfirmedAbsent(owner: UUID, routeID: UUID) -> Bool {
        guard ownerChildDeviceID == owner,
              activeRouteID == routeID,
              let route = routes[routeID],
              route.ownerChildDeviceID == owner,
              route.lifecycle == .active,
              activeEpochID == route.epochID,
              let epoch = epochs[route.epochID],
              epoch.childDeviceID == owner,
              epoch.status == .active,
              epoch.retiredAt == nil,
              activeGenerationID == route.generationID,
              let generation = generations[route.generationID],
              generation.childDeviceID == owner,
              generation.retiredAt == nil,
              route.installedSchedule != nil,
              !(route.installedEvents?.isEmpty ?? true)
        else { return false }
        let matches = installWork.values.filter {
            $0.ownerChildDeviceID == owner && $0.routeID == routeID
        }
        guard matches.count == 1, let install = matches.first else { return false }
        return install.phase == .stopped
            && install.retry.terminal == .succeeded
            && install.retry.lastErrorCode == "stale_day_prior_absent"
    }

    private func isExactCanonicalDayRolloverPrior(
        handoff: V2RouteHandoff,
        fromRoute: MeteringCallbackRoute,
        fromEpoch: DeviceDailyEpoch,
        toRoute: MeteringCallbackRoute,
        toEpoch: DeviceDailyEpoch,
        generation: MeteringPolicyGeneration
    ) -> Bool {
        guard handoff.phase == .cutoverReady,
              handoff.fromGenerationID == handoff.toGenerationID,
              fromRoute.generationID == generation.generationID,
              toRoute.generationID == generation.generationID,
              fromRoute.usageDate == fromEpoch.usageDate,
              toRoute.usageDate == toEpoch.usageDate,
              (toEpoch.status == .active || toEpoch.status == .paused),
              toEpoch.retiredAt == nil,
              toEpoch.childDeviceID == fromEpoch.childDeviceID,
              toEpoch.canonicalTimezone == fromEpoch.canonicalTimezone,
              toEpoch.policyRevision == fromEpoch.policyRevision,
              toEpoch.measurementSelectionDigest == fromEpoch.measurementSelectionDigest,
              toEpoch.enforcementSetID == fromEpoch.enforcementSetID,
              isNextCanonicalUsageDate(
                  fromRoute.usageDate,
                  toRoute.usageDate,
                  timeZoneIdentifier: generation.canonicalTimezone
              )
        else { return false }
        return true
    }

    private func isNextCanonicalUsageDate(
        _ prior: String,
        _ next: String,
        timeZoneIdentifier: String
    ) -> Bool {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let priorDate = formatter.date(from: prior),
              formatter.string(from: priorDate) == prior,
              let nextDate = calendar.date(byAdding: .day, value: 1, to: priorDate)
        else { return false }
        return formatter.string(from: nextDate) == next
    }

    func currentHorizonUsageDates(owner: UUID, generationID: UUID) -> [String] {
        guard let generation = generations[generationID],
              generation.childDeviceID == owner,
              generation.retiredAt == nil
        else { return [] }
        let dates = Set(routes.values.compactMap { route -> String? in
            guard route.generationID == generationID,
                  hasCurrentHorizonRouteDate(
                      owner: owner,
                      route: route,
                      epoch: epochs[route.epochID],
                      generation: generation
                  ),
                  isValidUsageDate(route.usageDate, timeZoneIdentifier: generation.canonicalTimezone)
            else { return nil }
            return route.usageDate
        })
        return dates.sorted(by: >).prefix(Self.currentHorizonDateCount).sorted()
    }

    func hasEligibleRouteEpochGeneration(
        owner: UUID,
        route: MeteringCallbackRoute,
        epoch: DeviceDailyEpoch?,
        generation: MeteringPolicyGeneration?
    ) -> Bool {
        guard route.ownerChildDeviceID == owner,
              route.lifecycle == .planned || route.lifecycle == .active,
              hasCurrentHorizonRouteDate(
                  owner: owner,
                  route: route,
                  epoch: epoch,
                  generation: generation
              )
        else { return false }
        return true
    }

    private func hasCurrentHorizonRouteDate(
        owner: UUID,
        route: MeteringCallbackRoute,
        epoch: DeviceDailyEpoch?,
        generation: MeteringPolicyGeneration?
    ) -> Bool {
        guard route.ownerChildDeviceID == owner,
              let epoch,
              epoch.childDeviceID == owner,
              epoch.epochID == route.epochID,
              epoch.status == .active,
              epoch.retiredAt == nil,
              route.usageDate == epoch.usageDate,
              let generation,
              generation.childDeviceID == owner,
              generation.generationID == route.generationID,
              generation.retiredAt == nil,
              generation.protocolVersion == epoch.protocolVersion,
              generation.canonicalTimezone == epoch.canonicalTimezone,
              generation.policyRevision == epoch.policyRevision,
              generation.measurementSelectionDigest == epoch.measurementSelectionDigest,
              generation.enforcementSetID == epoch.enforcementSetID
        else { return false }
        return true
    }

    private func isValidUsageDate(_ usageDate: String, timeZoneIdentifier: String) -> Bool {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: usageDate) else { return false }
        return formatter.string(from: date) == usageDate
    }

    func retryState(for workID: UUID, kind: MeteringWorkKind) -> MeteringRetryState? {
        switch kind {
        case .registration:
            return registrationWork.values.first { $0.workID == workID }?.retry
        case .activation:
            return activationWork.values.first { $0.workID == workID }?.retry
        case .sample:
            return sampleWork.values.first { $0.workID == workID }?.retry
        case .identityCleanup, .rollover, .install, .shield:
            return nil
        }
    }

    func networkClaim(for workID: UUID, kind: MeteringWorkKind) -> MeteringNetworkClaim? {
        switch kind {
        case .registration:
            return registrationWork.values.first { $0.workID == workID }?.claim
        case .activation:
            return activationWork.values.first { $0.workID == workID }?.claim
        case .sample:
            return sampleWork.values.first { $0.workID == workID }?.claim
        case .identityCleanup, .rollover, .install, .shield:
            return nil
        }
    }

    mutating func setNetworkClaim(_ claim: MeteringNetworkClaim?, for workID: UUID, kind: MeteringWorkKind) {
        switch kind {
        case .registration:
            guard let key = registrationWork.first(where: { $0.value.workID == workID })?.key else { return }
            registrationWork[key]?.claim = claim
        case .activation:
            guard let key = activationWork.first(where: { $0.value.workID == workID })?.key else { return }
            activationWork[key]?.claim = claim
        case .sample:
            guard let key = sampleWork.first(where: { $0.value.workID == workID })?.key else { return }
            sampleWork[key]?.claim = claim
        case .identityCleanup, .rollover, .install, .shield:
            break
        }
    }
}
