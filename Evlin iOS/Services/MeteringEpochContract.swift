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
}

nonisolated enum MeteringExplicitRecovery: String, Codable, Equatable, Sendable {
    case identityRecovery = "identity_recovery"
    case gateResumeExactRebase = "gate_resume_exact_rebase"
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
            ownRemainingMinutes = try Dictionary(uniqueKeysWithValues: encoded.map { key, value in
                guard let id = UUID(uuidString: key) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .ownRemainingMinutes,
                        in: container,
                        debugDescription: "invalid child device UUID \(key)"
                    )
                }
                return (id, value)
            })
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
        let acceptedTotal = acceptedByDevice.values.reduce(0, +)
        let ownRemaining = caps.mapValues { cap in cap }
            .mapValues { max(0, $0) }
        let projectedOwn = Dictionary(uniqueKeysWithValues: ownRemaining.map { deviceID, cap in
            (deviceID, max(0, cap - max(0, acceptedByDevice[deviceID, default: 0])))
        })
        return MeteringLedgerProjection(
            sharedRemainingMinutes: max(0, pool - max(0, acceptedTotal)),
            ownRemainingMinutes: projectedOwn
        )
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
            let resumeAt = input.resumeAt ?? .max
            let counted = (input.buckets ?? []).map { bucket in
                bucket.startAt >= resumeAt && bucket.endAt > bucket.startAt
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
            return GateObservation(
                retiredEpochCount: replaced ? 1 : 0,
                createdEpochCount: replaced ? 1 : 0,
                oldCallbackAccepted: input.oldCallbackDate == projectedDate,
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
            let projection = MeteringEpochContract.projectLedger(
                pool: pool,
                acceptedByDevice: [accepted.childDeviceID: accepted.earnedMinutes],
                caps: [accepted.childDeviceID: pool, sibling: pool]
            )
            return LedgerObservation(
                sharedRemainingMinutes: projection.sharedRemainingMinutes,
                ownRemainingMinutes: projection.ownRemainingMinutes,
                attributedObservations: sortedMutations([
                    mutation(.ledger, accepted.childDeviceID, accepted.source, accepted.credential)
                ]),
                effects: effects(ledgerMutations: 1)
            )

        case .ledgerDeviceCap:
            guard let accepted = input.accepted else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let matching = (input.enforcementSets ?? []).filter {
                $0.childDeviceID == accepted.childDeviceID
            }
            let mutations = [
                mutation(.ledger, accepted.childDeviceID, accepted.source, accepted.credential)
            ] + matching.flatMap { target in
                [
                    mutation(.receipt, target.childDeviceID, accepted.source, target.credential),
                    mutation(.shield, target.childDeviceID, accepted.source, target.credential)
                ]
            }
            let excluded = (input.enforcementSets ?? []).filter {
                $0.childDeviceID != accepted.childDeviceID
            }
            return LedgerObservation(
                attributedObservations: sortedMutations(mutations),
                excludedChildDeviceIDs: excluded.map(\.childDeviceID),
                excludedCredentialIDs: excluded.map(\.credential.id),
                effects: effects(
                    ledgerMutations: 1,
                    notifications: matching.count,
                    shieldMutations: matching.count
                )
            )

        case .ledgerSharedExhaustion:
            guard let accepted = input.accepted,
                  let before = input.sharedRemainingBeforeMinutes else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let exhausted = max(0, before - accepted.earnedMinutes) == 0
            let targets = exhausted ? input.devices ?? [] : []
            let mutations = [
                mutation(.ledger, accepted.childDeviceID, accepted.source, accepted.credential)
            ] + targets.flatMap { target in
                [
                    mutation(.receipt, target.childDeviceID, accepted.source, target.credential),
                    mutation(.shield, target.childDeviceID, accepted.source, target.credential)
                ]
            }
            return LedgerObservation(
                sharedRemainingMinutes: max(0, before - accepted.earnedMinutes),
                attributedObservations: sortedMutations(mutations),
                effects: effects(
                    ledgerMutations: 1,
                    notifications: targets.count,
                    shieldMutations: targets.count
                )
            )

        case .ledgerPerAppLimit:
            guard let rule = input.reachedRule,
                  let source = rule.source else {
                return LedgerObservation(attributedObservations: [], effects: MeteringEffects())
            }
            let reached = max(
                0,
                (rule.remainingMinutesBefore ?? 0) - (rule.consumedMinutes ?? 0)
            ) == 0
            let mutationKinds: [MeteringAttributedMutationKind] = reached
                ? [.ledger, .receipt, .shield]
                : [.ledger]
            return LedgerObservation(
                attributedObservations: sortedMutations(
                    mutationKinds.map {
                        mutation($0, rule.childDeviceID, source, rule.credential)
                    }
                ),
                excludedRuleIDs: (input.unrelatedRules ?? []).map(\.credential.id),
                effects: effects(
                    ledgerMutations: 1,
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
