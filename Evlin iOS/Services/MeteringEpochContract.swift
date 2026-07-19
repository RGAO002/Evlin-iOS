import CryptoKit
import Foundation

nonisolated protocol MeteringClock: Sendable {
    var now: Date { get }
}

nonisolated struct MeteringGenerationKey: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let childDeviceID: UUID
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
}

nonisolated struct MeteringEpochKey: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let childDeviceID: UUID
    let usageDate: String
    let canonicalTimezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
}

nonisolated enum MeteringEpochReplacementReason: String, Codable, CaseIterable,
    Equatable, Hashable, Sendable {
    case initial
    case dayRollover = "day_rollover"
    case policyChange = "policy_change"
    case selectionChange = "selection_change"
    case enforcementSetChange = "enforcement_set_change"
    case identityRecovery = "identity_recovery"
    case gateResumeExactRebase = "gate_resume_exact_rebase"
    case gateResumeConservative = "gate_resume_conservative"
}

nonisolated enum MeteringExplicitRecovery: String, Codable, Equatable, Sendable {
    case identityRecovery = "identity_recovery"
    case gateResumeExactRebase = "gate_resume_exact_rebase"
    case gateResumeConservative = "gate_resume_conservative"
}

nonisolated enum MeteringGenerationDecision: Equatable, Sendable {
    case keep
    case install(MeteringGenerationKey)
}

nonisolated enum MeteringCallbackVerdict: String, Codable, Sendable {
    case accept
    case rejectOwner
    case rejectEpoch
    case rejectUsageDate
    case rejectPolicy
    case rejectNamespace
    case rejectNegativeDelta
    case rejectTooEarly
}

nonisolated struct MeteringCallbackInput: Equatable, Sendable {
    let activeEpochID: UUID
    let callbackEpochID: UUID
    let activeOwnerDeviceID: UUID
    let callbackOwnerDeviceID: UUID
    let activeUsageDate: String
    let callbackUsageDate: String
    let activePolicyRevision: String
    let callbackPolicyRevision: String
    let expectedEventNamespace: String
    let callbackEventNamespace: String
    let adjustedEstimateMinutes: Int
    let baseAcceptedMinutes: Int
    let startedAt: Date
    let callbackAt: Date
    let jitterSeconds: Int
}

nonisolated struct MeteringEffects: Codable, Equatable, Sendable {
    var localEstimateMutations = 0
    var retryEnqueues = 0
    var networkDispatches = 0
    var backendSampleRows = 0
    var ledgerMutations = 0
    var notifications = 0
    var shieldMutations = 0
    var monitorStarts = 0
    var monitorStops = 0
    var epochReplacements = 0
}

nonisolated enum MeteringBooleanObservation: Codable, Equatable, Sendable {
    case value(Bool)
    case values([Bool])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .value(value)
        } else {
            self = .values(try container.decode([Bool].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .value(value):
            try container.encode(value)
        case let .values(values):
            try container.encode(values)
        }
    }
}

nonisolated enum GenerationInputKind: String, Codable, Equatable, Sendable {
    case generationPollChurn = "generation_poll_churn"
    case generationMutableOffset = "generation_mutable_offset"
    case generationSelectionDigest = "generation_selection_digest"
    case generationReadinessReplacement = "generation_readiness_replacement"
}

nonisolated struct GenerationEpochInput: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Int
    let canonicalDate: String
}

nonisolated struct GenerationIdentityFields: Codable, Equatable, Sendable {
    let policyID: String
    let selectionBytesBase64: String
    let childDeviceID: UUID

    enum CodingKeys: String, CodingKey {
        case policyID = "policyId"
        case selectionBytesBase64
        case childDeviceID = "childDeviceId"
    }
}

nonisolated struct MeteringReadinessInput: Codable, Equatable, Sendable {
    let configured: Bool
    let authorized: Bool
    let selectionPresent: Bool
    let identityPresent: Bool

    var isReady: Bool {
        configured && authorized && selectionPresent && identityPresent
    }
}

nonisolated enum MeteringReplacementAxis: String, Codable, Equatable, Sendable {
    case none
    case canonicalDate = "canonical_date"
    case policy
    case selection
    case enforcementSet = "enforcement_set"
    case identity
    case gate
}

nonisolated enum MeteringReplacementRecoveryTrigger: String, Codable, Equatable, Sendable {
    case identityRecovered = "identity_recovered"
    case resumeExactRebase = "resume_exact_rebase"
    case resumeConservative = "resume_conservative"
}

nonisolated struct MeteringReplacementClassificationInput: Codable, Equatable, Sendable {
    let changedAxis: MeteringReplacementAxis
    let recoveryTrigger: MeteringReplacementRecoveryTrigger?
}

nonisolated struct GenerationInput: Codable, Equatable, Sendable {
    let kind: GenerationInputKind
    let epoch: GenerationEpochInput?
    let pollTimes: [Int]?
    let epochIdentityFields: GenerationIdentityFields?
    let acceptedOffsetMinutes: [Int]?
    let persistedSelectionBytesBase64: String?
    let reorderedSelectionBytesBase64: String?
    let ready: MeteringReadinessInput?
    let notReadyVariants: [MeteringReadinessInput]?
    let replacementClassification: [MeteringReplacementClassificationInput]?
}

nonisolated struct MeteringReadinessObservation: Codable, Equatable, Sendable {
    let armed: Bool
    let firstThresholdExposed: Bool
}

nonisolated struct GenerationObservation: Codable, Equatable, Sendable {
    let epochID: UUID?
    let generationIdentityCount: Int?
    let monitorIdentityCount: Int?
    let persistedSelectionSha256: String?
    let reorderedDigestDiffers: Bool?
    let ready: MeteringReadinessObservation?
    let notReadyVariants: [String]?
    let replacementReasons: [String]?
    let forbiddenReplacementReason: String?
    let effects: MeteringEffects

    enum CodingKeys: String, CodingKey {
        case epochID = "epochId"
        case generationIdentityCount, monitorIdentityCount, persistedSelectionSha256
        case reorderedDigestDiffers, ready, notReadyVariants, replacementReasons
        case forbiddenReplacementReason, effects
    }

    init(
        epochID: UUID? = nil,
        generationIdentityCount: Int? = nil,
        monitorIdentityCount: Int? = nil,
        persistedSelectionSha256: String? = nil,
        reorderedDigestDiffers: Bool? = nil,
        ready: MeteringReadinessObservation? = nil,
        notReadyVariants: [String]? = nil,
        replacementReasons: [String]? = nil,
        forbiddenReplacementReason: String? = nil,
        effects: MeteringEffects
    ) {
        self.epochID = epochID
        self.generationIdentityCount = generationIdentityCount
        self.monitorIdentityCount = monitorIdentityCount
        self.persistedSelectionSha256 = persistedSelectionSha256
        self.reorderedDigestDiffers = reorderedDigestDiffers
        self.ready = ready
        self.notReadyVariants = notReadyVariants
        self.replacementReasons = replacementReasons
        self.forbiddenReplacementReason = forbiddenReplacementReason
        self.effects = effects
    }
}

nonisolated enum CallbackInputKind: String, Codable, Equatable, Sendable {
    case callbackPhysicalPlausibility = "callback_physical_plausibility"
    case callbackDelayedAccept = "callback_delayed_accept"
    case callbackProgressPolls = "callback_progress_polls"
    case callbackStaleDay = "callback_stale_day"
    case callbackIdentityFirewall = "callback_identity_firewall"
}

nonisolated enum CallbackMeasurement: String, Codable, Equatable, Sendable {
    case earnedTime = "earned_time"
    case perApp = "per_app"
}

nonisolated struct CallbackSampleInput: Codable, Equatable, Sendable {
    let at: Int
    let adjustedEstimateMinutes: Int
    let measurement: CallbackMeasurement?
    let perAppLimitMinutes: Int?
    let canonicalDate: String?
}

nonisolated struct CallbackVectorInput: Codable, Equatable, Sendable {
    let kind: CallbackInputKind
    let epochStartedAt: Int?
    let callbacks: [CallbackSampleInput]?
    let callback: CallbackSampleInput?
    let jitterSeconds: Int?
    let ordinaryPollCount: Int?
    let activeDate: String?
    let callbackOwnerChildDeviceID: UUID?
    let presentedChildDeviceID: UUID?
    let oldOwnerQueuedWork: Int?

    enum CodingKeys: String, CodingKey {
        case kind, epochStartedAt, callbacks, callback, jitterSeconds, ordinaryPollCount
        case activeDate
        case callbackOwnerChildDeviceID = "callbackOwnerChildDeviceId"
        case presentedChildDeviceID = "presentedChildDeviceId"
        case oldOwnerQueuedWork
    }
}

nonisolated struct CallbackObservation: Codable, Equatable, Sendable {
    let accepted: MeteringBooleanObservation
    let acceptedEstimateMinutes: Int?
    let monitorIdentityCount: Int?
    let oldOwnerQueuedWorkRemaining: Int?
    let newOwnerMutated: Bool?
    let effects: MeteringEffects

    init(
        accepted: MeteringBooleanObservation,
        acceptedEstimateMinutes: Int? = nil,
        monitorIdentityCount: Int? = nil,
        oldOwnerQueuedWorkRemaining: Int? = nil,
        newOwnerMutated: Bool? = nil,
        effects: MeteringEffects
    ) {
        self.accepted = accepted
        self.acceptedEstimateMinutes = acceptedEstimateMinutes
        self.monitorIdentityCount = monitorIdentityCount
        self.oldOwnerQueuedWorkRemaining = oldOwnerQueuedWorkRemaining
        self.newOwnerMutated = newOwnerMutated
        self.effects = effects
    }
}

nonisolated enum GateInputKind: String, Codable, Equatable, Sendable {
    case gateCanonicalRollover = "gate_canonical_rollover"
    case gatePauseResume = "gate_pause_resume"
    case gateTaskBypass = "gate_task_bypass"
    case gateReflectionPrecedence = "gate_reflection_precedence"
    case gateTimezoneSplit = "gate_timezone_split"
    case gateCanonicalTimezoneReplacement = "gate_canonical_timezone_replacement"
}

nonisolated struct GateTimestampInput: Codable, Equatable, Sendable {
    let canonicalDate: String?
    let at: Int
}

nonisolated struct GateBucketInput: Codable, Equatable, Sendable {
    let startAt: Int
    let endAt: Int
}

nonisolated struct GateInput: Codable, Equatable, Sendable {
    let kind: GateInputKind
    let before: GateTimestampInput?
    let after: GateTimestampInput?
    let monitorIsRepeating: Bool?
    let pauseAt: Int?
    let resumeAt: Int?
    let appProcessEvent: Bool?
    let buckets: [GateBucketInput]?
    let taskBypassDates: [String]?
    let checks: [GateTimestampInput]?
    let canonicalDate: String?
    let taskBypassActive: Bool?
    let reflectionActive: Bool?
    let deviceTimezone: String?
    let canonicalTimezone: String?
    let oldCanonicalTimezone: String?
    let newCanonicalTimezone: String?
    let at: Int?
    let oldDateBypassMarkers: [String]?
    let oldDateOverrideMarkers: [String]?
    let oldCallbackDate: String?

    enum CodingKeys: String, CodingKey {
        case kind, before, after, monitorIsRepeating, pauseAt, resumeAt, appProcessEvent
        case buckets, taskBypassDates, checks, canonicalDate, taskBypassActive
        case reflectionActive, deviceTimezone, canonicalTimezone, oldCanonicalTimezone
        case newCanonicalTimezone, at, oldDateBypassMarkers, oldDateOverrideMarkers
        case oldCallbackDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(GateInputKind.self, forKey: .kind)
        before = try container.decodeIfPresent(GateTimestampInput.self, forKey: .before)
        after = try container.decodeIfPresent(GateTimestampInput.self, forKey: .after)
        monitorIsRepeating = try container.decodeIfPresent(Bool.self, forKey: .monitorIsRepeating)
        pauseAt = try container.decodeIfPresent(Int.self, forKey: .pauseAt)
        resumeAt = try container.decodeIfPresent(Int.self, forKey: .resumeAt)
        appProcessEvent = try container.decodeIfPresent(Bool.self, forKey: .appProcessEvent)
        buckets = try container.decodeIfPresent([GateBucketInput].self, forKey: .buckets)
        taskBypassDates = try container.decodeIfPresent([String].self, forKey: .taskBypassDates)
        if let dateChecks = try? container.decode([String].self, forKey: .checks) {
            checks = dateChecks.map { GateTimestampInput(canonicalDate: $0, at: 0) }
        } else {
            checks = try container.decodeIfPresent([GateTimestampInput].self, forKey: .checks)
        }
        canonicalDate = try container.decodeIfPresent(String.self, forKey: .canonicalDate)
        taskBypassActive = try container.decodeIfPresent(Bool.self, forKey: .taskBypassActive)
        reflectionActive = try container.decodeIfPresent(Bool.self, forKey: .reflectionActive)
        deviceTimezone = try container.decodeIfPresent(String.self, forKey: .deviceTimezone)
        canonicalTimezone = try container.decodeIfPresent(String.self, forKey: .canonicalTimezone)
        oldCanonicalTimezone = try container.decodeIfPresent(String.self, forKey: .oldCanonicalTimezone)
        newCanonicalTimezone = try container.decodeIfPresent(String.self, forKey: .newCanonicalTimezone)
        at = try container.decodeIfPresent(Int.self, forKey: .at)
        oldDateBypassMarkers = try container.decodeIfPresent([String].self, forKey: .oldDateBypassMarkers)
        oldDateOverrideMarkers = try container.decodeIfPresent([String].self, forKey: .oldDateOverrideMarkers)
        oldCallbackDate = try container.decodeIfPresent(String.self, forKey: .oldCallbackDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encodeIfPresent(monitorIsRepeating, forKey: .monitorIsRepeating)
        try container.encodeIfPresent(pauseAt, forKey: .pauseAt)
        try container.encodeIfPresent(resumeAt, forKey: .resumeAt)
        try container.encodeIfPresent(appProcessEvent, forKey: .appProcessEvent)
        try container.encodeIfPresent(buckets, forKey: .buckets)
        try container.encodeIfPresent(taskBypassDates, forKey: .taskBypassDates)
        try container.encodeIfPresent(checks, forKey: .checks)
        try container.encodeIfPresent(canonicalDate, forKey: .canonicalDate)
        try container.encodeIfPresent(taskBypassActive, forKey: .taskBypassActive)
        try container.encodeIfPresent(reflectionActive, forKey: .reflectionActive)
        try container.encodeIfPresent(deviceTimezone, forKey: .deviceTimezone)
        try container.encodeIfPresent(canonicalTimezone, forKey: .canonicalTimezone)
        try container.encodeIfPresent(oldCanonicalTimezone, forKey: .oldCanonicalTimezone)
        try container.encodeIfPresent(newCanonicalTimezone, forKey: .newCanonicalTimezone)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(oldDateBypassMarkers, forKey: .oldDateBypassMarkers)
        try container.encodeIfPresent(oldDateOverrideMarkers, forKey: .oldDateOverrideMarkers)
        try container.encodeIfPresent(oldCallbackDate, forKey: .oldCallbackDate)
    }
}

nonisolated struct GateObservation: Codable, Equatable, Sendable {
    let retiredEpochCount: Int?
    let createdEpochCount: Int?
    let monitorIdentityCount: Int?
    let countedBuckets: [Bool]?
    let countingEnabled: MeteringBooleanObservation?
    let pauseReason: String?
    let rollover: [Bool]?
    let oldCallbackAccepted: Bool?
    let projectedCanonicalDate: String?
    let oldDateBypassActive: Bool?
    let oldDateOverrideActive: Bool?
    let effects: MeteringEffects

    init(
        retiredEpochCount: Int? = nil,
        createdEpochCount: Int? = nil,
        monitorIdentityCount: Int? = nil,
        countedBuckets: [Bool]? = nil,
        countingEnabled: MeteringBooleanObservation? = nil,
        pauseReason: String? = nil,
        rollover: [Bool]? = nil,
        oldCallbackAccepted: Bool? = nil,
        projectedCanonicalDate: String? = nil,
        oldDateBypassActive: Bool? = nil,
        oldDateOverrideActive: Bool? = nil,
        effects: MeteringEffects
    ) {
        self.retiredEpochCount = retiredEpochCount
        self.createdEpochCount = createdEpochCount
        self.monitorIdentityCount = monitorIdentityCount
        self.countedBuckets = countedBuckets
        self.countingEnabled = countingEnabled
        self.pauseReason = pauseReason
        self.rollover = rollover
        self.oldCallbackAccepted = oldCallbackAccepted
        self.projectedCanonicalDate = projectedCanonicalDate
        self.oldDateBypassActive = oldDateBypassActive
        self.oldDateOverrideActive = oldDateOverrideActive
        self.effects = effects
    }
}

nonisolated enum LedgerInputKind: String, Codable, Equatable, Sendable {
    case ledgerDeviceAttribution = "ledger_device_attribution"
    case ledgerDeviceCap = "ledger_device_cap"
    case ledgerSharedExhaustion = "ledger_shared_exhaustion"
    case ledgerPerAppLimit = "ledger_per_app_limit"
}

nonisolated enum MeteringAttributedMutationKind: String, Codable, Sendable {
    case ledger
    case shield
    case receipt
}

nonisolated enum MeteringCredentialKind: String, Codable, Sendable {
    case epoch
    case enforcementSet = "enforcement_set"
    case appLimitRule = "app_limit_rule"
}

nonisolated struct MeteringCredentialReference: Codable, Equatable, Sendable {
    let kind: MeteringCredentialKind
    let id: UUID
}

nonisolated struct MeteringAttributedMutation: Codable, Equatable, Sendable {
    let kind: MeteringAttributedMutationKind
    let childDeviceID: UUID
    let source: String
    let credentialKind: MeteringCredentialKind
    let credentialID: UUID

    enum CodingKeys: String, CodingKey {
        case kind
        case childDeviceID = "childDeviceId"
        case source, credentialKind
        case credentialID = "credentialId"
    }
}

nonisolated struct MeteringAcceptedUsageInput: Codable, Equatable, Sendable {
    let childDeviceID: UUID
    let source: String
    let credential: MeteringCredentialReference
    let earnedMinutes: Int
    let ownRemainingBeforeMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "childDeviceId"
        case source, credential, earnedMinutes, ownRemainingBeforeMinutes
    }
}

nonisolated struct MeteringEnforcementTargetInput: Codable, Equatable, Sendable {
    let childDeviceID: UUID
    let credential: MeteringCredentialReference

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "childDeviceId"
        case credential
    }
}

nonisolated struct MeteringAppLimitRuleInput: Codable, Equatable, Sendable {
    let childDeviceID: UUID
    let source: String?
    let credential: MeteringCredentialReference
    let bundleID: String
    let remainingMinutesBefore: Int?
    let consumedMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "childDeviceId"
        case source, credential
        case bundleID = "bundleId"
        case remainingMinutesBefore, consumedMinutes
    }
}

nonisolated struct LedgerInput: Codable, Equatable, Sendable {
    let kind: LedgerInputKind
    let poolMinutes: Int?
    let accepted: MeteringAcceptedUsageInput?
    let siblingChildDeviceID: UUID?
    let enforcementSets: [MeteringEnforcementTargetInput]?
    let sharedRemainingBeforeMinutes: Int?
    let devices: [MeteringEnforcementTargetInput]?
    let reachedRule: MeteringAppLimitRuleInput?
    let unrelatedRules: [MeteringAppLimitRuleInput]?

    enum CodingKeys: String, CodingKey {
        case kind, poolMinutes, accepted
        case siblingChildDeviceID = "siblingChildDeviceId"
        case enforcementSets, sharedRemainingBeforeMinutes, devices, reachedRule
        case unrelatedRules
    }
}

nonisolated struct MeteringLedgerProjection: Codable, Equatable, Sendable {
    let sharedRemainingMinutes: Int
    let ownRemainingMinutes: [UUID: Int]
}

nonisolated struct LedgerObservation: Codable, Equatable, Sendable {
    let sharedRemainingMinutes: Int?
    let ownRemainingMinutes: [UUID: Int]?
    let attributedObservationsSort: [String]
    let attributedObservations: [MeteringAttributedMutation]
    let excludedChildDeviceIDs: [UUID]?
    let excludedCredentialIDs: [UUID]?
    let excludedRuleIDs: [UUID]?
    let effects: MeteringEffects

    enum CodingKeys: String, CodingKey {
        case sharedRemainingMinutes, ownRemainingMinutes, attributedObservationsSort
        case attributedObservations
        case excludedChildDeviceIDs = "excludedChildDeviceIds"
        case excludedCredentialIDs = "excludedCredentialIds"
        case excludedRuleIDs = "excludedRuleIds"
        case effects
    }

    init(
        sharedRemainingMinutes: Int? = nil,
        ownRemainingMinutes: [UUID: Int]? = nil,
        attributedObservationsSort: [String] = [
            "kind", "child_device_id", "source", "credential_kind", "credential_id"
        ],
        attributedObservations: [MeteringAttributedMutation],
        excludedChildDeviceIDs: [UUID]? = nil,
        excludedCredentialIDs: [UUID]? = nil,
        excludedRuleIDs: [UUID]? = nil,
        effects: MeteringEffects
    ) {
        self.sharedRemainingMinutes = sharedRemainingMinutes
        self.ownRemainingMinutes = ownRemainingMinutes
        self.attributedObservationsSort = attributedObservationsSort
        self.attributedObservations = attributedObservations
        self.excludedChildDeviceIDs = excludedChildDeviceIDs
        self.excludedCredentialIDs = excludedCredentialIDs
        self.excludedRuleIDs = excludedRuleIDs
        self.effects = effects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharedRemainingMinutes = try container.decodeIfPresent(Int.self, forKey: .sharedRemainingMinutes)
        if let encoded = try container.decodeIfPresent([String: Int].self, forKey: .ownRemainingMinutes) {
            var decoded: [UUID: Int] = [:]
            var sourceKeys: [UUID: String] = [:]
            for (key, value) in encoded {
                guard let id = UUID(uuidString: key) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .ownRemainingMinutes,
                        in: container,
                        debugDescription: "invalid child device UUID \(key)"
                    )
                }
                if let sourceKey = sourceKeys[id] {
                    throw DecodingError.dataCorruptedError(
                        forKey: .ownRemainingMinutes,
                        in: container,
                        debugDescription: "child device UUID keys \(sourceKey) and \(key) normalize to the same UUID"
                    )
                }
                sourceKeys[id] = key
                decoded[id] = value
            }
            ownRemainingMinutes = decoded
        } else {
            ownRemainingMinutes = nil
        }
        attributedObservationsSort = try container.decode(
            [String].self,
            forKey: .attributedObservationsSort
        )
        attributedObservations = try container.decode(
            [MeteringAttributedMutation].self,
            forKey: .attributedObservations
        )
        excludedChildDeviceIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .excludedChildDeviceIDs
        )
        excludedCredentialIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .excludedCredentialIDs
        )
        excludedRuleIDs = try container.decodeIfPresent([UUID].self, forKey: .excludedRuleIDs)
        effects = try container.decode(MeteringEffects.self, forKey: .effects)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sharedRemainingMinutes, forKey: .sharedRemainingMinutes)
        let encodedOwnRemaining = ownRemainingMinutes?.reduce(into: [String: Int]()) {
            $0[$1.key.uuidString.lowercased()] = $1.value
        }
        try container.encodeIfPresent(encodedOwnRemaining, forKey: .ownRemainingMinutes)
        try container.encode(attributedObservationsSort, forKey: .attributedObservationsSort)
        try container.encode(attributedObservations, forKey: .attributedObservations)
        try container.encodeIfPresent(excludedChildDeviceIDs, forKey: .excludedChildDeviceIDs)
        try container.encodeIfPresent(excludedCredentialIDs, forKey: .excludedCredentialIDs)
        try container.encodeIfPresent(excludedRuleIDs, forKey: .excludedRuleIDs)
        try container.encode(effects, forKey: .effects)
    }
}

nonisolated struct MeteringStateSnapshot: Codable, Equatable, Sendable {
    let generationID: UUID
    let epochID: UUID
    let usageDate: String
    let baseAcceptedMinutes: Int
    let localEstimateMinutes: Int
    let latestRawThresholdMinutes: Int
    let excludedRawMinutes: Int
    let pendingRetryIDs: [UUID]
    let monitorArmed: Bool
}

nonisolated enum ManualSourceAction: String, Codable, Equatable, Sendable {
    case lock
    case unlock
}

nonisolated struct ManualInput: Codable, Equatable, Sendable {
    let sourceSets: [UUID: Set<String>]
    let meteringState: MeteringStateSnapshot
    let action: ManualSourceAction
}

nonisolated struct ManualObservation: Codable, Equatable, Sendable {
    let sourceSets: [UUID: Set<String>]
    let meteringState: MeteringStateSnapshot
}

nonisolated enum ProtocolInputKind: String, Codable, Equatable, Sendable {
    case protocolV1Compatibility = "protocol_v1_compatibility"
    case protocolV1TerminalDrop = "protocol_v1_terminal_drop"
}

nonisolated struct ProtocolRequestInput: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let at: Int
}

nonisolated struct ProtocolInput: Codable, Equatable, Sendable {
    let kind: ProtocolInputKind
    let deviceProtocolVersion: Int
    let ratchetedProtocolVersion: Int?
    let request: ProtocolRequestInput
}

nonisolated struct MeteringProtocolDisposition: Codable, Equatable, Sendable {
    let accepted: Bool
    let counted: Bool
    let compatibilityBranch: Bool
    let terminal: Bool
    let retryable: Bool
}

nonisolated struct ProtocolObservation: Codable, Equatable, Sendable {
    let accepted: Bool?
    let compatibilityBranch: Bool?
    let counted: Bool?
    let terminal: Bool
    let retried: Bool?
    let effects: MeteringEffects

    init(
        accepted: Bool? = nil,
        compatibilityBranch: Bool? = nil,
        counted: Bool? = nil,
        terminal: Bool,
        retried: Bool? = nil,
        effects: MeteringEffects
    ) {
        self.accepted = accepted
        self.compatibilityBranch = compatibilityBranch
        self.counted = counted
        self.terminal = terminal
        self.retried = retried
        self.effects = effects
    }
}

nonisolated enum PerAppOrderingInputKind: String, Codable, Equatable, Sendable {
    case perAppOrdering = "per_app_ordering"
}

nonisolated enum PerAppVersionCommandKind: String, Codable, Equatable, Sendable {
    case set
    case clear
}

nonisolated struct PerAppVersionCommand: Codable, Equatable, Sendable {
    let kind: PerAppVersionCommandKind
    let orderingToken: Int
    let ruleID: UUID

    enum CodingKeys: String, CodingKey {
        case kind, orderingToken
        case ruleID = "ruleId"
    }
}

nonisolated struct PerAppVersionState: Codable, Equatable, Sendable {
    let activeRuleID: UUID?
    let latestOrderingToken: Int?
}

nonisolated struct PerAppOrderingResult: Codable, Equatable, Sendable {
    let state: PerAppVersionState
    let applied: Bool
}

nonisolated struct PerAppOrderingInput: Codable, Equatable, Sendable {
    let kind: PerAppOrderingInputKind
    let commands: [PerAppVersionCommand]
}

nonisolated struct PerAppOrderingObservation: Codable, Equatable, Sendable {
    let finalState: String
    let tombstoneOrderingToken: Int?
    let applied: [Bool]
    let activeRuleID: UUID?
    let effects: MeteringEffects

    enum CodingKeys: String, CodingKey {
        case finalState, tombstoneOrderingToken, applied
        case activeRuleID = "activeRuleId"
        case effects
    }

    init(
        finalState: String,
        tombstoneOrderingToken: Int?,
        applied: [Bool],
        activeRuleID: UUID? = nil,
        effects: MeteringEffects
    ) {
        self.finalState = finalState
        self.tombstoneOrderingToken = tombstoneOrderingToken
        self.applied = applied
        self.activeRuleID = activeRuleID
        self.effects = effects
    }
}

nonisolated enum AppLimitVectorKind: String, Codable, Equatable, Sendable {
    case newerSet = "newer_set"
    case olderSet = "older_set"
    case newerClear = "newer_clear"
    case oldSetAfterClear = "old_set_after_clear"
    case equalAppliedSet = "equal_applied_set"
    case equalAppliedClear = "equal_applied_clear"
    case equalNSEPending = "equal_nse_pending"
    case equalTokenConflict = "equal_token_conflict"
    case convergentIngest = "convergent_ingest"
    case progressStable = "progress_stable"
    case noPastActivity = "no_past_activity"
    case impossibleCallback = "impossible_callback"
    case delayedCallback = "delayed_callback"
    case lateCallback = "late_callback"
    case pausedCallback = "paused_callback"
    case conservativeResume = "conservative_resume"
    case restartPreservesIgnored = "restart_preserves_ignored"
    case readbackCurrent = "readback_current"
    case wrongProvenance = "wrong_provenance"
    case perAppExhaustion = "per_app_exhaustion"
}

nonisolated enum AppLimitVectorCommandKind: String, Codable, Equatable, Sendable {
    case set
    case clear
}

nonisolated enum AppLimitVectorCommandSource: String, Codable, Equatable, Sendable {
    case poll
    case notificationServiceExtension = "notification_service_extension"
    case wakeRecovery = "wake_recovery"
}

nonisolated enum AppLimitVectorDisposition: String, Codable, Equatable, Sendable {
    case acceptedNeedsOwner = "accepted_needs_owner"
    case duplicatePending = "duplicate_pending"
    case duplicateApplied = "duplicate_applied"
    case superseded
    case equalTokenConflict = "equal_token_conflict"
}

nonisolated struct AppLimitVectorCommand: Codable, Equatable, Sendable {
    let commandID: UUID
    let orderingToken: Int64
    let kind: AppLimitVectorCommandKind
    let payloadDigest: String
    let source: AppLimitVectorCommandSource

    enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case orderingToken = "orderingToken"
        case kind
        case payloadDigest = "payloadDigest"
        case source
    }
}

nonisolated struct AppLimitVectorSlot: Codable, Equatable, Sendable {
    let latestOrderingToken: Int64?
    let latestKind: AppLimitVectorCommandKind?
    let latestPayloadDigest: String?
    let activeRulePresent: Bool
    let clearTombstonePresent: Bool
    let pendingOwnerWorkCount: Int
    let appliedReceiptPresent: Bool

    enum CodingKeys: String, CodingKey {
        case latestOrderingToken = "latestOrderingToken"
        case latestKind = "latestKind"
        case latestPayloadDigest = "latestPayloadDigest"
        case activeRulePresent = "activeRulePresent"
        case clearTombstonePresent = "clearTombstonePresent"
        case pendingOwnerWorkCount = "pendingOwnerWorkCount"
        case appliedReceiptPresent = "appliedReceiptPresent"
    }

    init(
        latestOrderingToken: Int64? = nil,
        latestKind: AppLimitVectorCommandKind? = nil,
        latestPayloadDigest: String? = nil,
        activeRulePresent: Bool = false,
        clearTombstonePresent: Bool = false,
        pendingOwnerWorkCount: Int = 0,
        appliedReceiptPresent: Bool = false
    ) {
        self.latestOrderingToken = latestOrderingToken
        self.latestKind = latestKind
        self.latestPayloadDigest = latestPayloadDigest
        self.activeRulePresent = activeRulePresent
        self.clearTombstonePresent = clearTombstonePresent
        self.pendingOwnerWorkCount = pendingOwnerWorkCount
        self.appliedReceiptPresent = appliedReceiptPresent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latestOrderingToken: try container.decodeIfPresent(Int64.self, forKey: .latestOrderingToken),
            latestKind: try container.decodeIfPresent(AppLimitVectorCommandKind.self, forKey: .latestKind),
            latestPayloadDigest: try container.decodeIfPresent(String.self, forKey: .latestPayloadDigest),
            activeRulePresent: try container.decodeIfPresent(Bool.self, forKey: .activeRulePresent) ?? false,
            clearTombstonePresent: try container.decodeIfPresent(Bool.self, forKey: .clearTombstonePresent) ?? false,
            pendingOwnerWorkCount: try container.decodeIfPresent(Int.self, forKey: .pendingOwnerWorkCount) ?? 0,
            appliedReceiptPresent: try container.decodeIfPresent(Bool.self, forKey: .appliedReceiptPresent) ?? false
        )
    }
}

nonisolated struct AppLimitVectorProvenance: Codable, Equatable, Sendable {
    let ruleID: UUID?
    let activityName: String?
    let eventName: String?
    let usageDate: String?
    let ruleRevision: Int64?
    let armID: UUID?

    enum CodingKeys: String, CodingKey {
        case ruleID = "ruleId"
        case activityName = "activityName"
        case eventName = "eventName"
        case usageDate = "usageDate"
        case ruleRevision = "ruleRevision"
        case armID = "armId"
    }
}

nonisolated struct AppLimitVectorPhysicalTime: Codable, Equatable, Sendable {
    let rawThresholdMinutes: Int
    let baseAcceptedMinutes: Int
    let ignoredWhilePausedMinutes: Int
    let startedAt: Int
    let observedAt: Int
    let pausedSecondsWithinArm: Int
    let paused: Bool

    enum CodingKeys: String, CodingKey {
        case rawThresholdMinutes = "rawThresholdMinutes"
        case baseAcceptedMinutes = "baseAcceptedMinutes"
        case ignoredWhilePausedMinutes = "ignoredWhilePausedMinutes"
        case startedAt = "startedAt"
        case observedAt = "observedAt"
        case pausedSecondsWithinArm = "pausedSecondsWithinArm"
        case paused
    }

    init(
        rawThresholdMinutes: Int = 0,
        baseAcceptedMinutes: Int = 0,
        ignoredWhilePausedMinutes: Int = 0,
        startedAt: Int = 0,
        observedAt: Int = 0,
        pausedSecondsWithinArm: Int = 0,
        paused: Bool = false
    ) {
        self.rawThresholdMinutes = rawThresholdMinutes
        self.baseAcceptedMinutes = baseAcceptedMinutes
        self.ignoredWhilePausedMinutes = ignoredWhilePausedMinutes
        self.startedAt = startedAt
        self.observedAt = observedAt
        self.pausedSecondsWithinArm = pausedSecondsWithinArm
        self.paused = paused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rawThresholdMinutes: try container.decodeIfPresent(Int.self, forKey: .rawThresholdMinutes) ?? 0,
            baseAcceptedMinutes: try container.decodeIfPresent(Int.self, forKey: .baseAcceptedMinutes) ?? 0,
            ignoredWhilePausedMinutes: try container.decodeIfPresent(Int.self, forKey: .ignoredWhilePausedMinutes) ?? 0,
            startedAt: try container.decodeIfPresent(Int.self, forKey: .startedAt) ?? 0,
            observedAt: try container.decodeIfPresent(Int.self, forKey: .observedAt) ?? 0,
            pausedSecondsWithinArm: try container.decodeIfPresent(Int.self, forKey: .pausedSecondsWithinArm) ?? 0,
            paused: try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        )
    }
}

nonisolated struct AppLimitReceiptObservation: Codable, Equatable, Sendable {
    let present: Bool
    let ruleID: UUID?
    let orderingToken: Int64?
    let armID: UUID?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case present
        case ruleID = "ruleId"
        case orderingToken = "orderingToken"
        case armID = "armId"
        case source
    }

    init(
        present: Bool = false,
        ruleID: UUID? = nil,
        orderingToken: Int64? = nil,
        armID: UUID? = nil,
        source: String? = nil
    ) {
        self.present = present
        self.ruleID = ruleID
        self.orderingToken = orderingToken
        self.armID = armID
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            present: try container.decodeIfPresent(Bool.self, forKey: .present) ?? false,
            ruleID: try container.decodeIfPresent(UUID.self, forKey: .ruleID),
            orderingToken: try container.decodeIfPresent(Int64.self, forKey: .orderingToken),
            armID: try container.decodeIfPresent(UUID.self, forKey: .armID),
            source: try container.decodeIfPresent(String.self, forKey: .source)
        )
    }
}

nonisolated struct AppLimitVectorPermutation: Codable, Equatable, Sendable {
    let source: AppLimitVectorCommandSource
}

nonisolated struct AppLimitVectorInput: Codable, Equatable, Sendable {
    let kind: AppLimitVectorKind
    let ruleID: UUID
    let command: AppLimitVectorCommand?
    let slot: AppLimitVectorSlot
    let provenance: AppLimitVectorProvenance?
    let physicalTime: AppLimitVectorPhysicalTime?
    let receipt: AppLimitReceiptObservation?
    let workIDs: [UUID]
    let ruleIDs: [UUID]
    let permutations: [AppLimitVectorPermutation]

    enum CodingKeys: String, CodingKey {
        case kind
        case ruleID = "ruleId"
        case command, slot, provenance, receipt
        case physicalTime = "physicalTime"
        case workIDs = "workIds"
        case ruleIDs = "ruleIds"
        case permutations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AppLimitVectorKind.self, forKey: .kind)
        ruleID = try container.decode(UUID.self, forKey: .ruleID)
        command = try container.decodeIfPresent(AppLimitVectorCommand.self, forKey: .command)
        slot = try container.decodeIfPresent(AppLimitVectorSlot.self, forKey: .slot) ?? AppLimitVectorSlot()
        provenance = try container.decodeIfPresent(AppLimitVectorProvenance.self, forKey: .provenance)
        physicalTime = try container.decodeIfPresent(AppLimitVectorPhysicalTime.self, forKey: .physicalTime)
        receipt = try container.decodeIfPresent(AppLimitReceiptObservation.self, forKey: .receipt)
        workIDs = try container.decodeIfPresent([UUID].self, forKey: .workIDs) ?? []
        ruleIDs = try container.decodeIfPresent([UUID].self, forKey: .ruleIDs) ?? []
        permutations = try container.decodeIfPresent([AppLimitVectorPermutation].self, forKey: .permutations) ?? []
    }
}

nonisolated struct AppLimitEffects: Codable, Equatable, Sendable {
    var localAcceptedEstimateMutations = 0
    var retryQueueMutations = 0
    var networkRequests = 0
    var backendSampleRows = 0
    var backendLedgerMutations = 0
    var perAppLedgerMutations = 0
    var deviceTotalLedgerMutations = 0
    var sharedPoolLedgerMutations = 0
    var notifications = 0
    var shieldSourceMutations = 0
    var scheduleArms = 0
    var scheduleStops = 0
    var commandWorkMutations = 0
    var tombstoneMutations = 0
    var appliedReceiptMutations = 0
}

nonisolated struct AppLimitVectorObservation: Codable, Equatable, Sendable {
    let disposition: AppLimitVectorDisposition
    let activeRulePresent: Bool
    let clearTombstonePresent: Bool
    let pendingOwnerWorkCount: Int
    let receiptReused: Bool
    let replacementIdentityChanged: Bool
    let includesPastActivity: Bool
    let physicalTimeDecision: String
    let adjustedEstimateMinutes: Int
    let ignoredWhilePausedMinutes: Int
    let readbackCurrent: Bool
    let unaffectedRuleIDs: [UUID]
    let sortedRuleIDs: [UUID]
    let sortedWorkIDs: [UUID]
    let canonicalStoreBytes: String
    let permutationCanonicalStoreBytes: [String]
    let permutationReceipts: [AppLimitReceiptObservation]
    let receipt: AppLimitReceiptObservation
    let effects: AppLimitEffects

    enum CodingKeys: String, CodingKey {
        case disposition
        case activeRulePresent = "activeRulePresent"
        case clearTombstonePresent = "clearTombstonePresent"
        case pendingOwnerWorkCount = "pendingOwnerWorkCount"
        case receiptReused = "receiptReused"
        case replacementIdentityChanged = "replacementIdentityChanged"
        case includesPastActivity = "includesPastActivity"
        case physicalTimeDecision = "physicalTimeDecision"
        case adjustedEstimateMinutes = "adjustedEstimateMinutes"
        case ignoredWhilePausedMinutes = "ignoredWhilePausedMinutes"
        case readbackCurrent = "readbackCurrent"
        case unaffectedRuleIDs = "unaffectedRuleIds"
        case sortedRuleIDs = "sortedRuleIds"
        case sortedWorkIDs = "sortedWorkIds"
        case canonicalStoreBytes = "canonicalStoreBytes"
        case permutationCanonicalStoreBytes = "permutationCanonicalStoreBytes"
        case permutationReceipts = "permutationReceipts"
        case receipt, effects
    }
}

nonisolated struct MeteringEpochRuntime: Equatable, Sendable {
    let epochID: UUID
    let key: MeteringEpochKey
}

nonisolated struct MeteringEpochContext: Equatable, Sendable {
    let epochID: UUID
    let key: MeteringEpochKey
    let explicitRecovery: MeteringExplicitRecovery?
}

nonisolated enum MeteringEpochTransition: Equatable, Sendable {
    case keep(MeteringEpochRuntime)
    case install(MeteringEpochRuntime, MeteringEpochReplacementReason)
}

nonisolated enum MeteringEpochContract {
    static let defaultJitterSeconds = 30
    static let maximumJitterSeconds = 60

    static func selectionDigest(persistedBytes: Data) -> String {
        SHA256.hash(data: persistedBytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func generationDecision(
        active: MeteringGenerationKey?,
        next: MeteringGenerationKey
    ) -> MeteringGenerationDecision {
        active == next ? .keep : .install(next)
    }

    static func replacementReason(
        active: MeteringEpochKey?,
        next: MeteringEpochKey,
        explicitRecovery: MeteringExplicitRecovery?
    ) -> MeteringEpochReplacementReason? {
        guard let active else { return .initial }

        if active.childDeviceID != next.childDeviceID
            || explicitRecovery == .identityRecovery {
            return .identityRecovery
        }
        if explicitRecovery == .gateResumeExactRebase {
            return .gateResumeExactRebase
        }
        if explicitRecovery == .gateResumeConservative {
            return .gateResumeConservative
        }
        if active.usageDate != next.usageDate {
            return .dayRollover
        }
        if active.protocolVersion != next.protocolVersion
            || active.canonicalTimezone != next.canonicalTimezone
            || active.policyRevision != next.policyRevision {
            return .policyChange
        }
        if active.measurementSelectionDigest != next.measurementSelectionDigest {
            return .selectionChange
        }
        if active.enforcementSetID != next.enforcementSetID {
            return .enforcementSetChange
        }
        return nil
    }

    static func callbackVerdict(_ input: MeteringCallbackInput) -> MeteringCallbackVerdict {
        guard input.activeOwnerDeviceID == input.callbackOwnerDeviceID else {
            return .rejectOwner
        }
        guard input.activeEpochID == input.callbackEpochID else {
            return .rejectEpoch
        }
        guard input.activeUsageDate == input.callbackUsageDate else {
            return .rejectUsageDate
        }
        guard input.activePolicyRevision == input.callbackPolicyRevision else {
            return .rejectPolicy
        }
        guard input.expectedEventNamespace == input.callbackEventNamespace else {
            return .rejectNamespace
        }
        guard input.adjustedEstimateMinutes >= input.baseAcceptedMinutes else {
            return .rejectNegativeDelta
        }
        let (deltaMinutes, deltaOverflow) = input.adjustedEstimateMinutes
            .subtractingReportingOverflow(input.baseAcceptedMinutes)
        guard !deltaOverflow else {
            return .rejectTooEarly
        }
        guard input.callbackAt >= input.startedAt else {
            return .rejectTooEarly
        }

        let elapsedSeconds = input.callbackAt.timeIntervalSince(input.startedAt)
        let clampedJitter = min(max(input.jitterSeconds, 0), maximumJitterSeconds)
        let (requiredSeconds, secondsOverflow) = deltaMinutes.multipliedReportingOverflow(by: 60)
        guard !secondsOverflow else {
            return .rejectTooEarly
        }
        return TimeInterval(requiredSeconds) <= elapsedSeconds + TimeInterval(clampedJitter)
            ? .accept
            : .rejectTooEarly
    }

    static func effects(for verdict: MeteringCallbackVerdict) -> MeteringEffects {
        guard verdict == .accept else { return MeteringEffects() }
        return MeteringEffects(
            localEstimateMutations: 1,
            retryEnqueues: 1,
            networkDispatches: 1
        )
    }

    static func nextEpoch(
        active: MeteringEpochRuntime?,
        context: MeteringEpochContext
    ) -> MeteringEpochTransition {
        let reason = replacementReason(
            active: active?.key,
            next: context.key,
            explicitRecovery: context.explicitRecovery
        )
        guard let reason else {
            return .keep(active ?? MeteringEpochRuntime(epochID: context.epochID, key: context.key))
        }
        return .install(
            MeteringEpochRuntime(epochID: context.epochID, key: context.key),
            reason
        )
    }

    static func countingAllowed(
        tasksDone: Bool,
        taskBypassDate: String?,
        reflectionActive: Bool,
        usageDate: String
    ) -> Bool {
        (tasksDone || taskBypassDate == usageDate) && !reflectionActive
    }

    static func projectLedger(
        pool: Int,
        acceptedByDevice: [UUID: Int],
        caps: [UUID: Int]
    ) -> MeteringLedgerProjection {
        var acceptedTotal = 0
        for accepted in acceptedByDevice.values {
            acceptedTotal = saturatingAdd(
                acceptedTotal,
                nonnegativeMinutes(accepted)
            )
        }

        var projectedOwn: [UUID: Int] = [:]
        for (deviceID, cap) in caps {
            projectedOwn[deviceID] = remainingMinutes(
                before: cap,
                consumed: acceptedByDevice[deviceID, default: 0]
            )
        }
        return MeteringLedgerProjection(
            sharedRemainingMinutes: remainingMinutes(
                before: pool,
                consumed: acceptedTotal
            ),
            ownRemainingMinutes: projectedOwn
        )
    }

    static func nonnegativeMinutes(_ minutes: Int) -> Int {
        max(0, minutes)
    }

    static func remainingMinutes(before: Int, consumed: Int) -> Int {
        let normalizedBefore = nonnegativeMinutes(before)
        let normalizedConsumed = nonnegativeMinutes(consumed)
        guard normalizedBefore > normalizedConsumed else { return 0 }
        return normalizedBefore - normalizedConsumed
    }

    static func isPositiveExhaustionTransition(before: Int, consumed: Int) -> Bool {
        let normalizedBefore = nonnegativeMinutes(before)
        let normalizedConsumed = nonnegativeMinutes(consumed)
        return normalizedBefore > 0
            && normalizedConsumed > 0
            && normalizedConsumed >= normalizedBefore
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    static func applyManual(_ input: ManualInput) -> ManualObservation {
        let sourceSets = input.sourceSets.mapValues { sources -> Set<String> in
            var sources = sources
            switch input.action {
            case .lock:
                sources.insert("manual")
            case .unlock:
                sources.remove("manual")
            }
            return sources
        }
        return ManualObservation(
            sourceSets: sourceSets,
            meteringState: input.meteringState
        )
    }

    static func protocolDisposition(
        advertisedVersion: Int,
        deviceRatchet: Int?,
        sampleVersion: Int
    ) -> MeteringProtocolDisposition {
        if let deviceRatchet, sampleVersion < deviceRatchet {
            return MeteringProtocolDisposition(
                accepted: false,
                counted: false,
                compatibilityBranch: false,
                terminal: true,
                retryable: false
            )
        }

        let accepted = sampleVersion == advertisedVersion
        return MeteringProtocolDisposition(
            accepted: accepted,
            counted: accepted,
            compatibilityBranch: accepted && sampleVersion == 1 && deviceRatchet == nil,
            terminal: !accepted,
            retryable: false
        )
    }

    static func applyPerAppCommand(
        state: PerAppVersionState,
        command: PerAppVersionCommand
    ) -> PerAppOrderingResult {
        if let latest = state.latestOrderingToken,
           command.orderingToken <= latest {
            return PerAppOrderingResult(state: state, applied: false)
        }

        let activeRuleID: UUID?
        switch command.kind {
        case .set:
            activeRuleID = command.ruleID
        case .clear:
            activeRuleID = nil
        }
        return PerAppOrderingResult(
            state: PerAppVersionState(
                activeRuleID: activeRuleID,
                latestOrderingToken: command.orderingToken
            ),
            applied: true
        )
    }

    static func canonicalUsageDate(
        at date: Date,
        timezoneIdentifier: String
    ) -> String? {
        guard let timezone = TimeZone(identifier: timezoneIdentifier) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            year,
            month,
            day
        )
    }
}

nonisolated protocol MeteringMonitorInstalling {
    mutating func install(_ key: MeteringGenerationKey) throws
    mutating func stop(_ key: MeteringGenerationKey)
}

nonisolated struct MeteringGenerationReconciler {
    private(set) var active: MeteringGenerationKey?

    mutating func reconcile<Installer: MeteringMonitorInstalling>(
        next: MeteringGenerationKey,
        installer: inout Installer
    ) throws {
        guard case let .install(replacement) = MeteringEpochContract.generationDecision(
            active: active,
            next: next
        ) else {
            return
        }

        let previous = active
        try installer.install(replacement)
        if let previous {
            installer.stop(previous)
        }
        active = replacement
    }
}

nonisolated enum MeteringJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([MeteringJSONValue])
    case object([String: MeteringJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MeteringJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MeteringJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    var objectValue: [String: MeteringJSONValue] { if case let .object(value) = self { return value }; return [:] }
    var arrayValue: [MeteringJSONValue] { if case let .array(value) = self { return value }; return [] }
    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
    var intValue: Int? { if case let .int(value) = self { return value }; return nil }
    var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }
}

nonisolated struct MeteringPhase3Input: Codable, Equatable {
    let value: MeteringJSONValue
    var kind: String { value.objectValue["kind"]?.stringValue ?? "" }

    init(from decoder: Decoder) throws { value = try MeteringJSONValue(from: decoder) }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

nonisolated struct MeteringPhase3Observation: Codable, Equatable {
    let value: MeteringJSONValue

    init(_ value: MeteringJSONValue) { self.value = value }
    init(from decoder: Decoder) throws { value = try MeteringJSONValue(from: decoder) }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

nonisolated enum MeteringReferenceRules {
    private static let referenceOwnerID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    private static let referenceEpochID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    private static let referenceEnforcementSetID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
    )!

    static func evaluateGeneration(_ input: GenerationInput) -> GenerationObservation {
        switch input.kind {
        case .generationPollChurn:
            guard let epoch = input.epoch, input.pollTimes != nil else {
                return GenerationObservation(effects: MeteringEffects())
            }
            return GenerationObservation(
                epochID: epoch.id,
                monitorIdentityCount: 1,
                effects: effects(monitorStarts: 1)
            )

        case .generationMutableOffset:
            guard let identity = input.epochIdentityFields,
                  let persistedBytes = Data(base64Encoded: identity.selectionBytesBase64),
                  let offsets = input.acceptedOffsetMinutes else {
                return GenerationObservation(effects: MeteringEffects())
            }
            let key = MeteringGenerationKey(
                protocolVersion: 1,
                childDeviceID: identity.childDeviceID,
                canonicalTimezone: "UTC",
                policyRevision: identity.policyID,
                measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                    persistedBytes: persistedBytes
                ),
                enforcementSetID: referenceEnforcementSetID
            )
            let keys = offsets.map { _ in key }
            let identityCount = keys.first.map { first in
                keys.allSatisfy { $0 == first } ? 1 : keys.count
            } ?? 0
            return GenerationObservation(
                generationIdentityCount: identityCount,
                monitorIdentityCount: keys.isEmpty ? 0 : 1,
                effects: effects(
                    acceptedCount: offsets.count,
                    monitorStarts: keys.isEmpty ? 0 : 1
                )
            )

        case .generationSelectionDigest:
            guard let persistedBase64 = input.persistedSelectionBytesBase64,
                  let reorderedBase64 = input.reorderedSelectionBytesBase64,
                  let persisted = Data(base64Encoded: persistedBase64),
                  let reordered = Data(base64Encoded: reorderedBase64) else {
                return GenerationObservation(effects: MeteringEffects())
            }
            let persistedDigest = MeteringEpochContract.selectionDigest(persistedBytes: persisted)
            let reorderedDigest = MeteringEpochContract.selectionDigest(persistedBytes: reordered)
            return GenerationObservation(
                persistedSelectionSha256: persistedDigest,
                reorderedDigestDiffers: persistedDigest != reorderedDigest,
                effects: MeteringEffects()
            )

        case .generationReadinessReplacement:
            guard let ready = input.ready,
                  let notReady = input.notReadyVariants,
                  let classifications = input.replacementClassification else {
                return GenerationObservation(effects: MeteringEffects())
            }
            let reasons = classifications.compactMap {
                replacementReason(for: $0)?.rawValue
            }
            return GenerationObservation(
                ready: MeteringReadinessObservation(
                    armed: ready.isReady,
                    firstThresholdExposed: ready.isReady
                ),
                notReadyVariants: notReady.map { $0.isReady ? "ready" : "not_ready" },
                replacementReasons: reasons,
                forbiddenReplacementReason: "poll_refresh",
                effects: effects(
                    monitorStarts: ready.isReady ? 1 : 0,
                    replacements: reasons.isEmpty ? 0 : 1
                )
            )
        }
    }

    static func evaluateCallback(_ input: CallbackVectorInput) -> CallbackObservation {
        switch input.kind {
        case .callbackPhysicalPlausibility:
            let startedAt = input.epochStartedAt ?? 0
            let accepted = (input.callbacks ?? []).map {
                callbackAccepted(sample: $0, startedAt: startedAt)
            }
            let acceptedCount = accepted.filter { $0 }.count
            return CallbackObservation(
                accepted: .values(accepted),
                effects: effects(acceptedCount: acceptedCount)
            )

        case .callbackDelayedAccept:
            guard let callback = input.callback else {
                return CallbackObservation(
                    accepted: .value(false),
                    effects: MeteringEffects()
                )
            }
            let accepted = callbackAccepted(
                sample: callback,
                startedAt: input.epochStartedAt ?? 0,
                jitterSeconds: input.jitterSeconds ?? MeteringEpochContract.defaultJitterSeconds
            )
            return CallbackObservation(
                accepted: .value(accepted),
                acceptedEstimateMinutes: accepted ? callback.adjustedEstimateMinutes : nil,
                effects: effects(acceptedCount: accepted ? 1 : 0)
            )

        case .callbackProgressPolls:
            let accepted = (input.callbacks ?? []).map {
                callbackAccepted(sample: $0, startedAt: input.epochStartedAt ?? 0)
            }
            let acceptedCount = accepted.filter { $0 }.count
            let acceptedEstimate = zip(input.callbacks ?? [], accepted)
                .filter(\.1)
                .map { $0.0.adjustedEstimateMinutes }
                .max()
            return CallbackObservation(
                accepted: .values(accepted),
                acceptedEstimateMinutes: acceptedEstimate,
                monitorIdentityCount: input.ordinaryPollCount == nil ? 0 : 1,
                effects: effects(
                    acceptedCount: acceptedCount,
                    monitorStarts: input.ordinaryPollCount == nil ? 0 : 1
                )
            )

        case .callbackStaleDay:
            guard let callback = input.callback else {
                return CallbackObservation(
                    accepted: .value(false),
                    effects: MeteringEffects()
                )
            }
            let accepted = callbackAccepted(
                sample: callback,
                startedAt: 0,
                activeDate: input.activeDate ?? "",
                callbackDate: callback.canonicalDate ?? ""
            )
            return CallbackObservation(
                accepted: .value(accepted),
                effects: effects(acceptedCount: accepted ? 1 : 0)
            )

        case .callbackIdentityFirewall:
            let owner = input.callbackOwnerChildDeviceID ?? referenceOwnerID
            let presented = input.presentedChildDeviceID ?? owner
            let sample = CallbackSampleInput(
                at: 0,
                adjustedEstimateMinutes: 0,
                measurement: nil,
                perAppLimitMinutes: nil,
                canonicalDate: nil
            )
            let accepted = callbackAccepted(
                sample: sample,
                startedAt: 0,
                activeOwner: owner,
                callbackOwner: presented
            )
            return CallbackObservation(
                accepted: .value(accepted),
                oldOwnerQueuedWorkRemaining: accepted ? input.oldOwnerQueuedWork : 0,
                newOwnerMutated: accepted,
                effects: effects(acceptedCount: accepted ? 1 : 0)
            )
        }
    }

    static func evaluateGate(_ input: GateInput) -> GateObservation {
        switch input.kind {
        case .gateCanonicalRollover:
            let changed = input.before?.canonicalDate != input.after?.canonicalDate
            return GateObservation(
                retiredEpochCount: changed ? 1 : 0,
                createdEpochCount: changed ? 1 : 0,
                monitorIdentityCount: input.monitorIsRepeating == true ? 1 : 0,
                effects: effects(replacements: changed ? 1 : 0)
            )

        case .gatePauseResume:
            let pauseAt = input.pauseAt ?? .min
            let resumeAt = input.resumeAt ?? .max
            let counted = (input.buckets ?? []).map { bucket in
                let hasPositiveDuration = bucket.endAt > bucket.startAt
                let whollyBeforePause = bucket.endAt <= pauseAt
                let whollyAfterResume = bucket.startAt >= resumeAt
                return hasPositiveDuration && (whollyBeforePause || whollyAfterResume)
            }
            return GateObservation(
                countedBuckets: counted,
                effects: effects(acceptedCount: counted.filter { $0 }.count)
            )

        case .gateTaskBypass:
            let bypassDates = Set(input.taskBypassDates ?? [])
            let enabled = (input.checks ?? []).map { check in
                let usageDate = check.canonicalDate ?? ""
                return MeteringEpochContract.countingAllowed(
                    tasksDone: false,
                    taskBypassDate: bypassDates.contains(usageDate) ? usageDate : nil,
                    reflectionActive: false,
                    usageDate: usageDate
                )
            }
            return GateObservation(
                countingEnabled: .values(enabled),
                effects: effects(acceptedCount: enabled.filter { $0 }.count)
            )

        case .gateReflectionPrecedence:
            let usageDate = input.canonicalDate ?? ""
            let enabled = MeteringEpochContract.countingAllowed(
                tasksDone: false,
                taskBypassDate: input.taskBypassActive == true ? usageDate : nil,
                reflectionActive: input.reflectionActive == true,
                usageDate: usageDate
            )
            return GateObservation(
                countingEnabled: .value(enabled),
                pauseReason: enabled ? nil : "reflection",
                effects: effects(acceptedCount: enabled ? 1 : 0)
            )

        case .gateTimezoneSplit:
            let timezone = input.canonicalTimezone ?? "UTC"
            let dates = (input.checks ?? []).map {
                MeteringEpochContract.canonicalUsageDate(
                    at: Date(timeIntervalSince1970: TimeInterval($0.at)),
                    timezoneIdentifier: timezone
                )
            }
            let rollover = dates.indices.map { index in
                index > 0 && dates[index] != dates[index - 1]
            }
            return GateObservation(
                rollover: rollover,
                effects: effects(replacements: rollover.filter { $0 }.count)
            )

        case .gateCanonicalTimezoneReplacement:
            let projectedDate = MeteringEpochContract.canonicalUsageDate(
                at: Date(timeIntervalSince1970: TimeInterval(input.at ?? 0)),
                timezoneIdentifier: input.newCanonicalTimezone ?? "UTC"
            ) ?? ""
            let oldKey = referenceEpochKey(
                usageDate: input.oldCallbackDate ?? projectedDate,
                canonicalTimezone: input.oldCanonicalTimezone ?? "UTC"
            )
            let newKey = referenceEpochKey(
                usageDate: projectedDate,
                canonicalTimezone: input.newCanonicalTimezone ?? "UTC"
            )
            let reason = MeteringEpochContract.replacementReason(
                active: oldKey,
                next: newKey,
                explicitRecovery: nil
            )
            let replaced = reason != nil
            let oldCallbackAccepted = !replaced
                && input.oldCallbackDate == projectedDate
            return GateObservation(
                retiredEpochCount: replaced ? 1 : 0,
                createdEpochCount: replaced ? 1 : 0,
                oldCallbackAccepted: oldCallbackAccepted,
                projectedCanonicalDate: projectedDate,
                oldDateBypassActive: Set(input.oldDateBypassMarkers ?? []).contains(projectedDate),
                oldDateOverrideActive: Set(input.oldDateOverrideMarkers ?? []).contains(projectedDate),
                effects: effects(replacements: replaced ? 1 : 0)
            )
        }
    }

    static func evaluateLedger(_ input: LedgerInput) -> LedgerObservation {
        switch input.kind {
        case .ledgerDeviceAttribution:
            guard let accepted = input.accepted,
                  let sibling = input.siblingChildDeviceID,
                  let pool = input.poolMinutes else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let earnedMinutes = MeteringEpochContract.nonnegativeMinutes(
                accepted.earnedMinutes
            )
            let projection = MeteringEpochContract.projectLedger(
                pool: pool,
                acceptedByDevice: [accepted.childDeviceID: earnedMinutes],
                caps: [accepted.childDeviceID: pool, sibling: pool]
            )
            let mutations = earnedMinutes > 0
                ? [mutation(.ledger, accepted.childDeviceID, accepted.source, accepted.credential)]
                : []
            return LedgerObservation(
                sharedRemainingMinutes: projection.sharedRemainingMinutes,
                ownRemainingMinutes: projection.ownRemainingMinutes,
                attributedObservations: sortedMutations(mutations),
                effects: effects(ledgerMutations: earnedMinutes > 0 ? 1 : 0)
            )

        case .ledgerDeviceCap:
            guard let accepted = input.accepted else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let earnedMinutes = MeteringEpochContract.nonnegativeMinutes(
                accepted.earnedMinutes
            )
            let capReached = MeteringEpochContract.isPositiveExhaustionTransition(
                before: accepted.ownRemainingBeforeMinutes ?? 0,
                consumed: earnedMinutes
            )
            let matching = (capReached ? input.enforcementSets ?? [] : []).filter {
                $0.childDeviceID == accepted.childDeviceID
            }
            let ledgerMutations = earnedMinutes > 0
                ? [mutation(.ledger, accepted.childDeviceID, accepted.source, accepted.credential)]
                : []
            let mutations = ledgerMutations + matching.flatMap { target in
                [
                    mutation(.receipt, target.childDeviceID, accepted.source, target.credential),
                    mutation(.shield, target.childDeviceID, accepted.source, target.credential)
                ]
            }
            let excluded = (input.enforcementSets ?? []).filter {
                !capReached || $0.childDeviceID != accepted.childDeviceID
            }
            return LedgerObservation(
                attributedObservations: sortedMutations(mutations),
                excludedChildDeviceIDs: excluded.map(\.childDeviceID),
                excludedCredentialIDs: excluded.map(\.credential.id),
                effects: effects(
                    ledgerMutations: earnedMinutes > 0 ? 1 : 0,
                    notifications: matching.count,
                    shieldMutations: matching.count
                )
            )

        case .ledgerSharedExhaustion:
            guard let accepted = input.accepted,
                  let before = input.sharedRemainingBeforeMinutes else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let earnedMinutes = MeteringEpochContract.nonnegativeMinutes(
                accepted.earnedMinutes
            )
            let remaining = MeteringEpochContract.remainingMinutes(
                before: before,
                consumed: earnedMinutes
            )
            let exhausted = MeteringEpochContract.isPositiveExhaustionTransition(
                before: before,
                consumed: earnedMinutes
            )
            let targets = exhausted ? input.devices ?? [] : []
            let ledgerMutations = earnedMinutes > 0
                ? [mutation(.ledger, accepted.childDeviceID, accepted.source, accepted.credential)]
                : []
            let mutations = ledgerMutations + targets.flatMap { target in
                [
                    mutation(.receipt, target.childDeviceID, accepted.source, target.credential),
                    mutation(.shield, target.childDeviceID, accepted.source, target.credential)
                ]
            }
            return LedgerObservation(
                sharedRemainingMinutes: remaining,
                attributedObservations: sortedMutations(mutations),
                effects: effects(
                    ledgerMutations: earnedMinutes > 0 ? 1 : 0,
                    notifications: targets.count,
                    shieldMutations: targets.count
                )
            )

        case .ledgerPerAppLimit:
            guard let rule = input.reachedRule,
                  let source = rule.source else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let consumedMinutes = MeteringEpochContract.nonnegativeMinutes(
                rule.consumedMinutes ?? 0
            )
            let reached = MeteringEpochContract.isPositiveExhaustionTransition(
                before: rule.remainingMinutesBefore ?? 0,
                consumed: consumedMinutes
            )
            let mutationKinds: [MeteringAttributedMutationKind]
            if consumedMinutes == 0 {
                mutationKinds = []
            } else if reached {
                mutationKinds = [.ledger, .receipt, .shield]
            } else {
                mutationKinds = [.ledger]
            }
            return LedgerObservation(
                attributedObservations: sortedMutations(
                    mutationKinds.map {
                        mutation($0, rule.childDeviceID, source, rule.credential)
                    }
                ),
                excludedRuleIDs: (input.unrelatedRules ?? []).map(\.credential.id),
                effects: effects(
                    ledgerMutations: consumedMinutes > 0 ? 1 : 0,
                    notifications: reached ? 1 : 0,
                    shieldMutations: reached ? 1 : 0
                )
            )
        }
    }

    static func evaluateManual(_ input: ManualInput) -> ManualObservation {
        MeteringEpochContract.applyManual(input)
    }

    static func evaluateProtocol(_ input: ProtocolInput) -> ProtocolObservation {
        let disposition = MeteringEpochContract.protocolDisposition(
            advertisedVersion: input.deviceProtocolVersion,
            deviceRatchet: input.ratchetedProtocolVersion,
            sampleVersion: input.request.protocolVersion
        )
        switch input.kind {
        case .protocolV1Compatibility:
            return ProtocolObservation(
                accepted: disposition.accepted,
                compatibilityBranch: disposition.compatibilityBranch,
                terminal: disposition.terminal,
                effects: effects(acceptedCount: disposition.accepted ? 1 : 0)
            )
        case .protocolV1TerminalDrop:
            return ProtocolObservation(
                counted: disposition.counted,
                terminal: disposition.terminal,
                retried: disposition.retryable,
                effects: effects(acceptedCount: disposition.counted ? 1 : 0)
            )
        }
    }

    static func evaluatePerAppOrdering(
        _ input: PerAppOrderingInput
    ) -> PerAppOrderingObservation {
        switch input.kind {
        case .perAppOrdering:
            var state = PerAppVersionState(activeRuleID: nil, latestOrderingToken: nil)
            var applied: [Bool] = []
            for command in input.commands {
                let result = MeteringEpochContract.applyPerAppCommand(
                    state: state,
                    command: command
                )
                state = result.state
                applied.append(result.applied)
            }
            return PerAppOrderingObservation(
                finalState: state.activeRuleID == nil ? "cleared" : "set",
                tombstoneOrderingToken: state.activeRuleID == nil
                    ? state.latestOrderingToken
                    : nil,
                applied: applied,
                activeRuleID: state.activeRuleID,
                effects: MeteringEffects()
            )
        }
    }

    static func evaluateAppLimitVector(
        _ input: AppLimitVectorInput
    ) -> AppLimitVectorObservation {
        let command = input.command
        let slot = input.slot
        let sortedRuleIDs = Array(Set([input.ruleID] + input.ruleIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let sortedWorkIDs = Array(Set(input.workIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        var disposition: AppLimitVectorDisposition = .acceptedNeedsOwner
        var activeRulePresent = slot.activeRulePresent
        var clearTombstonePresent = slot.clearTombstonePresent
        var pendingOwnerWorkCount = slot.pendingOwnerWorkCount
        var receiptReused = false
        var replacementIdentityChanged = false
        let includesPastActivity = false
        var physicalTimeDecision = "not_evaluated"
        var adjustedEstimateMinutes = 0
        var ignoredWhilePausedMinutes = 0
        var readbackCurrent = false
        var receipt = AppLimitReceiptObservation()
        var permutationCanonicalStoreBytes: [String] = []
        var permutationReceipts: [AppLimitReceiptObservation] = []
        var unaffectedRuleIDs: [UUID] = []
        var effects = AppLimitEffects()

        if let command {
            precondition(command.orderingToken > 0, "ordering_token must be a positive Int64")
            if let latestOrderingToken = slot.latestOrderingToken {
                if command.orderingToken < latestOrderingToken {
                    disposition = .superseded
                } else if command.orderingToken == latestOrderingToken {
                    if command.payloadDigest != slot.latestPayloadDigest {
                        disposition = .equalTokenConflict
                    } else if slot.appliedReceiptPresent {
                        disposition = .duplicateApplied
                        receiptReused = true
                    } else {
                        disposition = .duplicatePending
                    }
                }
            }
        }

        switch input.kind {
        case .olderSet, .oldSetAfterClear:
            disposition = .superseded
            activeRulePresent = false
            clearTombstonePresent = input.kind == .oldSetAfterClear
        case .equalTokenConflict:
            disposition = .equalTokenConflict
        case .equalAppliedSet, .equalAppliedClear:
            disposition = .duplicateApplied
            receiptReused = true
            activeRulePresent = input.kind == .equalAppliedSet
            clearTombstonePresent = input.kind == .equalAppliedClear
        case .equalNSEPending:
            disposition = .duplicatePending
            pendingOwnerWorkCount = 1
        case .newerSet:
            activeRulePresent = true
            pendingOwnerWorkCount = 1
            effects = AppLimitEffects(scheduleArms: 1, commandWorkMutations: 1)
        case .newerClear:
            activeRulePresent = false
            clearTombstonePresent = true
            pendingOwnerWorkCount = 1
            effects = AppLimitEffects(scheduleStops: 1, commandWorkMutations: 1, tombstoneMutations: 1)
        case .convergentIngest:
            precondition(
                input.permutations.map(\.source) == [.poll, .notificationServiceExtension, .wakeRecovery],
                "convergent ingest requires poll/NSE/wake order"
            )
            guard let command else { preconditionFailure("convergent ingest requires a command") }
            precondition(slot.latestOrderingToken == nil, "convergent ingest requires an initial empty slot")
            activeRulePresent = true
            pendingOwnerWorkCount = 0
            readbackCurrent = true
            receipt = AppLimitReceiptObservation(
                present: true,
                ruleID: input.ruleID,
                orderingToken: command.orderingToken,
                armID: UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000009"),
                source: "app_owner"
            )
            let storeBytes = canonicalAppLimitStoreBytes(
                activeRulePresent: true,
                clearTombstonePresent: false,
                pendingOwnerWorkCount: 0,
                ruleIDs: sortedRuleIDs,
                workIDs: sortedWorkIDs
            )
            permutationCanonicalStoreBytes = input.permutations.map { _ in storeBytes }
            permutationReceipts = input.permutations.map { _ in receipt }
            effects = AppLimitEffects(appliedReceiptMutations: 1)
        case .progressStable, .noPastActivity:
            activeRulePresent = true
        case .impossibleCallback, .delayedCallback, .lateCallback, .pausedCallback:
            activeRulePresent = true
            guard let physicalTime = input.physicalTime else {
                preconditionFailure("callback vector requires physical_time")
            }
            adjustedEstimateMinutes = physicalTime.baseAcceptedMinutes + max(
                0,
                physicalTime.rawThresholdMinutes - physicalTime.ignoredWhilePausedMinutes
            )
            ignoredWhilePausedMinutes = physicalTime.ignoredWhilePausedMinutes
            if physicalTime.paused {
                physicalTimeDecision = "paused"
                ignoredWhilePausedMinutes = max(
                    physicalTime.ignoredWhilePausedMinutes,
                    physicalTime.rawThresholdMinutes
                )
            } else {
                let activeElapsedSeconds = physicalTime.observedAt - physicalTime.startedAt
                    - physicalTime.pausedSecondsWithinArm
                let delta = adjustedEstimateMinutes - physicalTime.baseAcceptedMinutes
                let trusted = delta >= 0
                    && delta * 60 <= activeElapsedSeconds + MeteringEpochContract.defaultJitterSeconds
                physicalTimeDecision = trusted ? "accept" : "reject"
                if trusted {
                    effects = AppLimitEffects(
                        localAcceptedEstimateMutations: 1,
                        retryQueueMutations: 1,
                        networkRequests: 1,
                        backendSampleRows: 1,
                        backendLedgerMutations: 1
                    )
                }
            }
        case .conservativeResume, .restartPreservesIgnored:
            activeRulePresent = true
            replacementIdentityChanged = true
            ignoredWhilePausedMinutes = input.physicalTime?.ignoredWhilePausedMinutes ?? 0
            effects = AppLimitEffects(scheduleArms: 1, scheduleStops: 1)
        case .readbackCurrent:
            activeRulePresent = true
            let provenance = input.provenance
            readbackCurrent = command != nil
                && provenance?.ruleRevision == command?.orderingToken
                && input.receipt?.ruleID == input.ruleID
                && input.receipt?.orderingToken == command?.orderingToken
                && slot.latestOrderingToken == input.receipt?.orderingToken
                && input.receipt?.armID == provenance?.armID
                && input.receipt?.source == "app_owner"
            if let inputReceipt = input.receipt {
                receipt = AppLimitReceiptObservation(
                    present: true,
                    ruleID: inputReceipt.ruleID,
                    orderingToken: inputReceipt.orderingToken,
                    armID: inputReceipt.armID,
                    source: inputReceipt.source
                )
            }
        case .wrongProvenance:
            activeRulePresent = true
            physicalTimeDecision = "reject_provenance"
            let provenance = input.provenance
            let valid = provenance?.ruleID == input.ruleID
                && provenance?.activityName == "evlin.limit.\(input.ruleID.uuidString.lowercased())"
                && provenance?.eventName == "evlin.limit.t5"
                && provenance?.usageDate == "2026-07-17"
                && provenance?.ruleRevision == command?.orderingToken
            precondition(!valid, "wrong provenance vector requires a mismatched field")
        case .perAppExhaustion:
            activeRulePresent = true
            unaffectedRuleIDs = input.ruleIDs.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            effects = AppLimitEffects(
                backendLedgerMutations: 1,
                perAppLedgerMutations: 1,
                notifications: 1,
                shieldSourceMutations: 1
            )
        }

        return AppLimitVectorObservation(
            disposition: disposition,
            activeRulePresent: activeRulePresent,
            clearTombstonePresent: clearTombstonePresent,
            pendingOwnerWorkCount: pendingOwnerWorkCount,
            receiptReused: receiptReused,
            replacementIdentityChanged: replacementIdentityChanged,
            includesPastActivity: includesPastActivity,
            physicalTimeDecision: physicalTimeDecision,
            adjustedEstimateMinutes: adjustedEstimateMinutes,
            ignoredWhilePausedMinutes: ignoredWhilePausedMinutes,
            readbackCurrent: readbackCurrent,
            unaffectedRuleIDs: unaffectedRuleIDs,
            sortedRuleIDs: sortedRuleIDs,
            sortedWorkIDs: sortedWorkIDs,
            canonicalStoreBytes: canonicalAppLimitStoreBytes(
                activeRulePresent: activeRulePresent,
                clearTombstonePresent: clearTombstonePresent,
                pendingOwnerWorkCount: pendingOwnerWorkCount,
                ruleIDs: sortedRuleIDs,
                workIDs: sortedWorkIDs
            ),
            permutationCanonicalStoreBytes: permutationCanonicalStoreBytes,
            permutationReceipts: permutationReceipts,
            receipt: receipt,
            effects: effects
        )
    }

    private static func canonicalAppLimitStoreBytes(
        activeRulePresent: Bool,
        clearTombstonePresent: Bool,
        pendingOwnerWorkCount: Int,
        ruleIDs: [UUID],
        workIDs: [UUID]
    ) -> String {
        let value: [String: Any] = [
            "active_rule_present": activeRulePresent,
            "clear_tombstone_present": clearTombstonePresent,
            "pending_owner_work_count": pendingOwnerWorkCount,
            "rule_ids": ruleIDs.map { $0.uuidString.lowercased() },
            "work_ids": workIDs.map { $0.uuidString.lowercased() }
        ]
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .base64EncodedString()
    }

    /// Pure reference-model observations shared with the backend fixture.
    /// Tasks 9-19 bind these expected effects to the concrete store, monitor,
    /// transport, and shield implementations before the phase can close.
    static func evaluatePhase3(_ input: MeteringPhase3Input) -> MeteringPhase3Observation {
        let value = input.value.objectValue
        let kind = input.kind
        var output: [String: MeteringJSONValue] = [:]
        let effects = phase3Effects(for: value, kind: kind)

        switch kind {
        case "phase3_eight_date_horizon":
            let observations = value["generation_route_observations"]?.arrayValue ?? []
            let routes = value["route_ids"]?.arrayValue ?? []
            let generation = value["generation_id"]?.stringValue
            output["route_count"] = .int(routes.count)
            output["same_generation"] = .bool(observations.allSatisfy { $0.objectValue["generation_id"]?.stringValue == generation })
            output["same_route_ids"] = .bool(observations.count > 1 && observations.allSatisfy { $0.objectValue["route_ids"] == .array(routes) })
        case "phase3_coverage_exhaustion":
            let transition = value["coverage_transition"]?.objectValue ?? [:]
            let exhausted = (transition["ready_through_usage_date"]?.stringValue ?? "") < (transition["callback_usage_date"]?.stringValue ?? "")
            output["coverage_status"] = .string(exhausted ? "coverageExhausted" : "coverageReady")
            output["counted"] = .bool(!exhausted)
            output["preserved_sources"] = .array((value["unrelated_sources"]?.arrayValue ?? []).sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") })
        case "phase3_excessive_activities":
            let transition = value["coverage_transition"]?.objectValue ?? [:]
            output["coverage_status"] = .string(transition["failure"]?.stringValue == "excessiveActivities" ? "installLimited" : "installReady")
            output["preserved_route_ids"] = value["verified_route_ids"] ?? .array([])
            output["stopped_filling"] = .bool((transition["ready_through_usage_date"]?.stringValue ?? "") < (transition["next_planned_usage_date"]?.stringValue ?? ""))
        case "phase3_route_rejection":
            output["rejected_count"] = .int(value["cases"]?.arrayValue.count ?? 0)
            output["all_rejected_zero_effects"] = .bool((value["rejection_effects"]?.arrayValue ?? []).allSatisfy { $0.intValue == 0 })
            output["authorized_offline_queue_items"] = value["authorized_offline_case"]?.objectValue["queue_items"] ?? .int(0)
        case "phase3_install_claim_race":
            let events = value["claim_timeline"]?.arrayValue ?? []
            let starts = events.filter { $0.objectValue["event"]?.stringValue == "started" }
            output["claim_winners"] = .array(starts.compactMap { $0.objectValue["role"] })
            output["start_count"] = .int(starts.count)
            output["adopted_same_work_id"] = .bool(events.contains { $0.objectValue["event"]?.stringValue == "adopted" && $0.objectValue["work_id"] == value["work_id"] })
            output["duplicate_start_count"] = .int(max(0, starts.count - 1))
        case "phase3_recovery_envelopes":
            let rollover = value["rollover"]?.objectValue ?? [:]
            output["old_callback_counted"] = .bool(value["old_callback"]?.objectValue["owner_child_device_id"] == value["new_owner_child_device_id"])
            output["recovered_operation_ids"] = .array([value["shield_effect_operation_id"], rollover["old_route_id"], rollover["new_route_id"]].compactMap { $0 })
        case "phase3_task_pause_cas":
            let current = value["shield_record"]?.objectValue ?? [:]
            let expected = value["expected_applied"]?.objectValue ?? [:]
            let exactSources = (expected["sources"]?.arrayValue ?? []).filter { $0.stringValue != "earnedTime" }
            output["mismatch_preserves_bytes"] = .bool(current != expected)
            output["match_removes_only"] = .string("earnedTime")
            output["task_pause_preserved"] = .bool(exactSources.contains(.string("taskPause")))
        case "phase3_authoritative_base_correction":
            let phases = value["handoff_phases"]?.arrayValue ?? []
            let ids = ["prior_epoch_id", "rejected_candidate_epoch_id", "corrected_epoch_id", "prior_route_id", "rejected_candidate_route_id", "corrected_route_id"].compactMap { value[$0]?.stringValue }
            var maximum = Int.min
            let overlap = (value["overlap_estimates"]?.arrayValue ?? []).map { item -> MeteringJSONValue in
                maximum = max(maximum, item.intValue ?? Int.min); return .int(maximum)
            }
            output["prior_countable_until"] = phases.dropFirst(2).first ?? .null
            output["corrected_countable_after"] = phases.last ?? .null
            output["prior_work_must_settle"] = .bool(true)
            output["candidate_route_stopped_before_activation"] = .bool(false)
            output["epoch_ids_unique"] = .bool(Set(ids.prefix(3)).count == 3)
            output["route_ids_unique"] = .bool(Set(ids.suffix(3)).count == 3)
            output["overlap_monotonic_max"] = .array(overlap)
        case "phase3_install_lease":
            let winner = (value["actors"]?.arrayValue ?? []).min { ($0.objectValue["claimed_at"]?.stringValue ?? "") < ($1.objectValue["claimed_at"]?.stringValue ?? "") }?.objectValue["role"] ?? .null
            output["winner"] = winner
            output["before_expiry"] = .string("noop")
            output["after_expiry"] = .string("adopt")
            output["physical_starts"] = .int(1)
        case "phase3_retry_schedule":
            let priorities = ["identity_cleanup": 0, "rollover": 1, "registration": 2, "install": 3, "activation": 4, "sample": 5, "shield": 6]
            let due = (value["work_items"]?.arrayValue ?? []).sorted { left, right in
                let a = left.objectValue; let b = right.objectValue
                let leftKey = phase3DueKey(a, priorities: priorities)
                let rightKey = phase3DueKey(b, priorities: priorities)
                return leftKey.lexicographicallyPrecedes(rightKey)
            }
            output["retry_offsets_seconds"] = .array((value["retry_failures"]?.arrayValue ?? []).map { .int([0, 5, 15, 60, 300][min($0.intValue ?? 0, 4)]) })
            output["due_order"] = .array(due.compactMap { $0.objectValue["work_id"] })
        case "phase3_tombstone_retention":
            output["not_purge_before"] = .string("2026-07-18T04:00:00Z")
            output["retention_basis"] = .string("max(canonical_day_end+48h, stop_ack+24h)")
            output["purge_allowed_after"] = output["not_purge_before"]
        case "phase3_all_source_merge":
            output["preserved_sources"] = .array((value["sources"]?.arrayValue ?? []).sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") })
            output["normal_merge_preserves_all"] = .bool(true)
            output["cas_conflict_preserves_newer_durable_record"] = value["cas_conflict"] ?? .bool(false)
        case "phase3_gate_resume_conservative":
            let gate = value["gate_at_registration"]?.objectValue ?? [:]
            let phases = value["handoff_phases"]?.arrayValue ?? []
            let fresh = ["candidate_epoch_id", "resumed_epoch_id", "candidate_route_id", "resumed_route_id"].compactMap { value[$0]?.stringValue }
            output["registration_status"] = .string(gate["gate_open"]?.boolValue == false && gate["registration_accepted"]?.boolValue == false ? "paused" : "registered")
            output["activation_status"] = .string(gate["activation_requested"]?.boolValue == true ? "sent" : "not_sent")
            output["protocol_after_race"] = .int((gate["protocol_before"]?.intValue ?? 0) + (gate["protocol_ratcheted"]?.boolValue == true ? 1 : 0))
            output["prior_countable_until"] = phases.dropFirst(2).first ?? .null
            output["resumed_route_countable_after"] = phases.last ?? .null
            output["fresh_epoch_and_route"] = .bool(Set(fresh).count == fresh.count)
            output["handoff_phases"] = .array(phases)
        case "phase3_legacy_migration":
            let monitor = value["legacy_monitor"] ?? .object([:])
            output["provenance_preserved"] = .bool(true)
            output["provenance_before_registration"] = monitor
            output["provenance_after_registration"] = monitor
            output["provenance_after_activation"] = monitor
            output["v1_functional_until_activation"] = .bool(true)
            output["registration_alone_stops_v1"] = .bool(false)
            output["stale_v1_after_activation"] = .string("legacy_after_v2")
        case "phase3_v30_real_route":
            output = phase3V30Output(value)
        case "phase3_v30_artifact_contract":
            output["regular_nonempty_file_count"] = .int(value["files"]?.arrayValue.count ?? 0)
            output["request_hash_count"] = .int(value["request_files"]?.arrayValue.count ?? 0)
            output["manifest_self_hash"] = .bool(false)
            output["exact_route_reused_for_activation_and_v2"] = .bool(true)
        default: break
        }

        let observations: [MeteringJSONValue]
        if kind == "phase3_v30_real_route" {
            observations = [
                phase3Observation(for: kind),
                .object(["kind": .string("bank"), "assertion": .string("legacy bank remains separate")])
            ]
        } else {
            observations = [phase3Observation(for: kind)]
        }
        output["observations"] = .array(observations)
        output["effects"] = .object(effects)
        return MeteringPhase3Observation(.object(output))
    }

    private static func phase3Observation(for kind: String) -> MeteringJSONValue {
        let values: [String: (String, String)] = [
            "phase3_eight_date_horizon": ("routes", "eight dated routes"),
            "phase3_coverage_exhaustion": ("coverage", "uncovered callback has zero effects"),
            "phase3_excessive_activities": ("install", "verified routes survive excessiveActivities"),
            "phase3_route_rejection": ("rejection", "provenance rejection precedes all effects"),
            "phase3_install_claim_race": ("lease", "one winner and one physical start"),
            "phase3_recovery_envelopes": ("recovery", "identity and rollover envelopes are owner-fenced"),
            "phase3_v30_real_route": ("rows", "v1 and v2 are one monotonic ledger"),
            "phase3_task_pause_cas": ("shield", "CAS keeps taskPause"),
            "phase3_authoritative_base_correction": ("handoff", "prior route drains before corrected cutover"),
            "phase3_install_lease": ("lease", "claim lease is exactly 60 seconds"),
            "phase3_retry_schedule": ("retry", "all seven work priorities and install ties sort by the full due tuple"),
            "phase3_tombstone_retention": ("tombstone", "retention uses the later exact deadline"),
            "phase3_all_source_merge": ("merge", "all source provenance survives both paths"),
            "phase3_gate_resume_conservative": ("gate", "closed gate never ratchets or activates locally"),
            "phase3_legacy_migration": ("legacy", "active/pending/retiring provenance survives migration"),
            "phase3_v30_artifact_contract": ("artifact", "five exact request hashes plus manifest")
        ]
        let value = values[kind] ?? ("unknown", "")
        return .object(["kind": .string(value.0), "assertion": .string(value.1)])
    }

    private static func phase3Effects(
        for input: [String: MeteringJSONValue],
        kind: String
    ) -> [String: MeteringJSONValue] {
        var values = Dictionary(uniqueKeysWithValues: [
            "local_estimate_mutations", "retry_enqueues", "network_dispatches",
            "backend_sample_rows", "ledger_mutations", "notifications", "shield_mutations",
            "monitor_starts", "monitor_stops", "epoch_replacements", "route_state_mutations",
            "coverage_mutations", "queue_mutations", "bank_mutations", "lock_ledger_mutations",
            "retry_order_mutations"
        ].map { ($0, MeteringJSONValue.int(0)) })
        func set(_ key: String, _ value: Int) { values[key] = .int(value) }

        switch kind {
        case "phase3_eight_date_horizon":
            let count = input["route_ids"]?.arrayValue.count ?? 0
            set("monitor_starts", count); set("route_state_mutations", count); set("coverage_mutations", 1)
        case "phase3_coverage_exhaustion", "phase3_excessive_activities": set("coverage_mutations", 1)
        case "phase3_route_rejection": set("queue_mutations", input["authorized_offline_case"]?.objectValue["queue_items"]?.intValue ?? 0)
        case "phase3_install_claim_race", "phase3_install_lease":
            set("retry_enqueues", 1); set("monitor_starts", 1); set("route_state_mutations", 1)
        case "phase3_recovery_envelopes":
            set("shield_mutations", 1); set("monitor_starts", 1); set("monitor_stops", 1); set("epoch_replacements", 1); set("route_state_mutations", 2); set("coverage_mutations", 1); set("queue_mutations", 1); set("lock_ledger_mutations", 1)
        case "phase3_v30_real_route", "phase3_v30_artifact_contract":
            let scenario = kind == "phase3_v30_artifact_contract" ? input["scenario"]?.objectValue ?? [:] : [:]
            let requests = kind == "phase3_v30_artifact_contract" ? scenario["requests"]?.objectValue ?? [:] : input["requests"]?.objectValue ?? [:]
            let names = kind == "phase3_v30_artifact_contract" ? scenario["local_estimate_request_names"]?.arrayValue.compactMap(\.stringValue) ?? [] : ["v1", "v2"]
            let cap = kind == "phase3_v30_artifact_contract" ? scenario["device_cap_minutes"]?.intValue ?? 0 : input["device_cap_minutes"]?.intValue ?? 0
            let reached = names.compactMap { requests[$0]?.objectValue["estimated_minutes"]?.intValue }.max() ?? 0 >= cap
            set("local_estimate_mutations", names.count); set("network_dispatches", names.count); set("backend_sample_rows", names.count); set("ledger_mutations", names.count); set("notifications", reached ? 1 : 0); set("shield_mutations", reached ? 1 : 0); set("lock_ledger_mutations", reached ? 1 : 0)
        case "phase3_task_pause_cas": set("shield_mutations", 1)
        case "phase3_authoritative_base_correction", "phase3_gate_resume_conservative":
            let phaseCount = input["handoff_phases"]?.arrayValue.count ?? 0
            let priorCount = input["prior_work_items"]?.arrayValue.count ?? 0
            set("retry_enqueues", kind == "phase3_gate_resume_conservative" ? 2 : 1); set("network_dispatches", 1); set("monitor_starts", 1); set("epoch_replacements", 2); set("route_state_mutations", phaseCount); set("queue_mutations", priorCount + 1)
        case "phase3_retry_schedule":
            let count = input["work_items"]?.arrayValue.count ?? 0
            set("retry_enqueues", count); set("queue_mutations", count); set("retry_order_mutations", 1)
        case "phase3_tombstone_retention": set("monitor_stops", 1); set("route_state_mutations", 1)
        case "phase3_all_source_merge": set("shield_mutations", 2)
        case "phase3_legacy_migration":
            set("local_estimate_mutations", 1); set("retry_enqueues", 1); set("network_dispatches", 1); set("backend_sample_rows", 1); set("ledger_mutations", 1); set("monitor_starts", 1); set("monitor_stops", 1); set("route_state_mutations", 2); set("queue_mutations", 2)
        default: break
        }
        return values
    }

    private static func phase3V30Output(_ input: [String: MeteringJSONValue]) -> [String: MeteringJSONValue] {
        let requests = input["requests"]?.objectValue ?? [:]
        let pool = input["pool_minutes"]?.intValue ?? 0
        let cap = input["device_cap_minutes"]?.intValue ?? 0
        func sampleBody(_ name: String, counted: Bool, warning: MeteringJSONValue) -> MeteringJSONValue {
            let request = requests[name]?.objectValue ?? [:]
            let estimated = request["estimated_minutes"]?.intValue ?? 0
            return .object(["child_device_id": request["device_id"] ?? .null, "usage_date": request["usage_date"] ?? .null, "estimated_minutes": .int(estimated), "cap_minutes": .int(cap), "child_day_state": .string("available"), "used_minutes": .int(estimated), "remaining_minutes": .int(pool - estimated), "counted": .bool(counted), "warning": warning])
        }
        let v1 = sampleBody("v1", counted: true, warning: .null)
        let v2 = sampleBody("v2", counted: true, warning: .null)
        let stale = sampleBody("stale_v1", counted: false, warning: .string("legacy_after_v2"))
        let v1Keys = ["child_device_id", "usage_date", "estimated_minutes", "cap_minutes", "child_day_state", "used_minutes", "remaining_minutes", "counted", "warning"].map(MeteringJSONValue.string)
        let registrationBody: MeteringJSONValue = .object(["status": .string("registered"), "epoch_id": input["epoch_id"] ?? .null, "metering_protocol_version": .int(2), "snapshot": v1, "epoch_status": .string("active")])
        let activationBody: MeteringJSONValue = .object(["status": .string("activated"), "epoch_id": input["epoch_id"] ?? .null, "epoch_status": .string("active"), "metering_protocol_version": .int(2), "snapshot": v1])
        return [
            "http": .object([
                "v1": .object(["status_code": .int(200), "body_keys": .array(v1Keys), "body": v1]),
                "registration": .object(["status_code": .int(200), "body_keys": .array([.string("status"), .string("epoch_id"), .string("metering_protocol_version"), .string("snapshot"), .string("epoch_status")]), "body": registrationBody]),
                "activation": .object(["status_code": .int(200), "body_keys": .array([.string("status"), .string("epoch_id"), .string("epoch_status"), .string("metering_protocol_version"), .string("snapshot")]), "body": activationBody]),
                "v2": .object(["status_code": .int(200), "body_keys": .array(v1Keys), "body": v2]),
                "stale_v1": .object(["status_code": .int(200), "body_keys": .array(v1Keys), "body": stale])
            ]),
            "protocol_after_registration": .int(1), "protocol_after_activation": .int(2),
            "rows_after_v2": .object(["epochs": .int(1), "samples": .int(2), "device_days": .int(1), "days": .int(1), "lock_commands": .int(1), "commands": .int(1)]),
            "bank_minutes_left": .int(120), "stale_v1_row_and_bank_delta": .int(0)
        ]
    }

    private static func phase3DueKey(
        _ item: [String: MeteringJSONValue],
        priorities: [String: Int]
    ) -> [String] {
        [
            item["next_attempt_at"]?.stringValue ?? "",
            String(priorities[item["work_kind"]?.stringValue ?? ""] ?? 0),
            item["created_at"]?.stringValue ?? "",
            item["work_id"]?.stringValue ?? ""
        ]
    }

    private static func callbackAccepted(
        sample: CallbackSampleInput,
        startedAt: Int,
        jitterSeconds: Int = MeteringEpochContract.defaultJitterSeconds,
        activeDate: String = "1970-01-01",
        callbackDate: String = "1970-01-01",
        activeOwner: UUID = referenceOwnerID,
        callbackOwner: UUID = referenceOwnerID
    ) -> Bool {
        let value = MeteringCallbackInput(
            activeEpochID: referenceEpochID,
            callbackEpochID: referenceEpochID,
            activeOwnerDeviceID: activeOwner,
            callbackOwnerDeviceID: callbackOwner,
            activeUsageDate: activeDate,
            callbackUsageDate: callbackDate,
            activePolicyRevision: "reference-policy",
            callbackPolicyRevision: "reference-policy",
            expectedEventNamespace: "metering.reference",
            callbackEventNamespace: "metering.reference",
            adjustedEstimateMinutes: sample.adjustedEstimateMinutes,
            baseAcceptedMinutes: 0,
            startedAt: Date(timeIntervalSince1970: TimeInterval(startedAt)),
            callbackAt: Date(timeIntervalSince1970: TimeInterval(sample.at)),
            jitterSeconds: jitterSeconds
        )
        return MeteringEpochContract.callbackVerdict(value) == .accept
    }

    private static func replacementReason(
        for classification: MeteringReplacementClassificationInput
    ) -> MeteringEpochReplacementReason? {
        let active = referenceEpochKey()
        let next: MeteringEpochKey
        switch classification.changedAxis {
        case .none, .gate:
            next = active
        case .canonicalDate:
            next = referenceEpochKey(usageDate: "1970-01-02")
        case .policy:
            next = referenceEpochKey(policyRevision: "reference-policy-2")
        case .selection:
            next = referenceEpochKey(selectionDigest: "selection-2")
        case .enforcementSet:
            next = referenceEpochKey(
                enforcementSetID: UUID(
                    uuidString: "44444444-4444-4444-4444-444444444444"
                )!
            )
        case .identity:
            next = referenceEpochKey(
                childDeviceID: UUID(
                    uuidString: "55555555-5555-5555-5555-555555555555"
                )!
            )
        }

        let explicitRecovery: MeteringExplicitRecovery?
        switch classification.recoveryTrigger {
        case .identityRecovered:
            explicitRecovery = .identityRecovery
        case .resumeExactRebase:
            explicitRecovery = .gateResumeExactRebase
        case .resumeConservative:
            explicitRecovery = .gateResumeConservative
        case nil:
            explicitRecovery = nil
        }
        return MeteringEpochContract.replacementReason(
            active: classification.changedAxis == .none ? nil : active,
            next: next,
            explicitRecovery: explicitRecovery
        )
    }

    private static func referenceEpochKey(
        childDeviceID: UUID = referenceOwnerID,
        usageDate: String = "1970-01-01",
        canonicalTimezone: String = "UTC",
        policyRevision: String = "reference-policy",
        selectionDigest: String = "selection-1",
        enforcementSetID: UUID = referenceEnforcementSetID
    ) -> MeteringEpochKey {
        MeteringEpochKey(
            protocolVersion: 1,
            childDeviceID: childDeviceID,
            usageDate: usageDate,
            canonicalTimezone: canonicalTimezone,
            policyRevision: policyRevision,
            measurementSelectionDigest: selectionDigest,
            enforcementSetID: enforcementSetID
        )
    }

    private static func mutation(
        _ kind: MeteringAttributedMutationKind,
        _ childDeviceID: UUID,
        _ source: String,
        _ credential: MeteringCredentialReference
    ) -> MeteringAttributedMutation {
        MeteringAttributedMutation(
            kind: kind,
            childDeviceID: childDeviceID,
            source: source,
            credentialKind: credential.kind,
            credentialID: credential.id
        )
    }

    private static func sortedMutations(
        _ mutations: [MeteringAttributedMutation]
    ) -> [MeteringAttributedMutation] {
        mutations.sorted {
            [
                $0.kind.rawValue, $0.childDeviceID.uuidString.lowercased(), $0.source,
                $0.credentialKind.rawValue, $0.credentialID.uuidString.lowercased()
            ].lexicographicallyPrecedes([
                $1.kind.rawValue, $1.childDeviceID.uuidString.lowercased(), $1.source,
                $1.credentialKind.rawValue, $1.credentialID.uuidString.lowercased()
            ])
        }
    }

    private static func effects(
        acceptedCount: Int = 0,
        monitorStarts: Int = 0,
        replacements: Int = 0,
        ledgerMutations: Int = 0,
        notifications: Int = 0,
        shieldMutations: Int = 0
    ) -> MeteringEffects {
        MeteringEffects(
            localEstimateMutations: acceptedCount,
            networkDispatches: acceptedCount,
            backendSampleRows: acceptedCount,
            ledgerMutations: ledgerMutations,
            notifications: notifications,
            shieldMutations: shieldMutations,
            monitorStarts: monitorStarts,
            epochReplacements: replacements
        )
    }
}
