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
    let usageDate: String
    let timezoneIdentifier: String
    let calendarIdentifier: String
}

nonisolated struct MeteringEventPlan: Codable, Equatable, Sendable {
    let eventName: String
    let thresholdMinutes: Int
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
    let plannedSchedule: DatedSchedulePlan
    var installedSchedule: DatedSchedulePlan?
    let plannedEvents: [MeteringEventPlan]
    var installedEvents: [MeteringEventPlan]?
    var lifecycle: MeteringRouteLifecycle
    let createdAt: Date
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

nonisolated struct MeteringAuthorizedCallbackInput: Equatable, Sendable {
    let routeID: UUID
    let activityName: String
    let eventName: String
    let namespace: String
    let thresholdMinutes: Int
    let observedAt: Date
    let now: Date
    let jitterSeconds: Int
}

nonisolated enum MeteringAuthorizedCallbackResult: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case discarded(reason: String)
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
    let armSignature: String
    let usageDate: String
    let timezoneIdentifier: String
    let armedAt: Date?
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

nonisolated struct IdentityCleanupWork: Codable, Equatable, Sendable {
    let workID: UUID
    let oldOwnerChildDeviceID: UUID
    let newOwnerChildDeviceID: UUID?
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
    case v1, dualActive, v2
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
    static let currentSchemaVersion = 4

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
    var rolloverEffectsWork: RolloverEffectsWork?
    var coverage: MonitorCoverageState?
    var ratchets: [UUID: MeteringOwnerRatchet]

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
        rolloverEffectsWork: RolloverEffectsWork? = nil,
        coverage: MonitorCoverageState? = nil,
        ratchets: [UUID: MeteringOwnerRatchet] = [:]
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
        self.rolloverEffectsWork = rolloverEffectsWork
        self.coverage = coverage
        self.ratchets = ratchets
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ownerChildDeviceID, generations, activeGenerationID
        case epochs, activeEpochID, routes, activeRouteID, tombstones
        case v2RouteHandoff, legacy, registrationWork, activationWork, sampleWork
        case installWork, shieldReferences, identityCleanupWork, rolloverEffectsWork
        case coverage, ratchets
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
        rolloverEffectsWork = try values.decodeIfPresent(RolloverEffectsWork.self, forKey: .rolloverEffectsWork)
        coverage = try values.decodeIfPresent(MonitorCoverageState.self, forKey: .coverage)
        ratchets = try values.decodeIfPresent([UUID: MeteringOwnerRatchet].self, forKey: .ratchets) ?? [:]
    }
}

extension DeviceEpochStoreState {
    // DeviceEpochStore also compiles in Push, which intentionally excludes
    // MeteringDatedSchedule.swift. This mirrors MeteringHorizonPlanner.dateCount.
    private static let currentHorizonDateCount = 8

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
            append(value.workID, kind: .install, retry: value.retry, createdAt: value.createdAt)
        }
        for value in activationWork.values {
            append(value.workID, kind: .activation, retry: value.retry, createdAt: value.createdAt)
        }
        for value in sampleWork.values {
            append(value.workID, kind: .sample, retry: value.retry, createdAt: value.createdAt)
        }
        for value in shieldReferences.values {
            append(value.operationID, kind: .shield, retry: value.retry, createdAt: value.createdAt)
        }

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
}

private enum DeviceEpochStoreInvariantError: Error {
    case invalidState(String)
}

nonisolated final class DeviceEpochStore: @unchecked Sendable {
    static let shared = DeviceEpochStore()
    static let fileName = "metering-device-epoch-store-v4.json"

    private let fileURL: URL?
    private let lock: any DeviceEpochStoreLocking
    private let fileIO: any DeviceEpochFileIO
    private let ownerProvider: @Sendable () -> UUID?

    init(
        fileURL: URL? = nil,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        fileIO: any DeviceEpochFileIO = SystemDeviceEpochFileIO(),
        ownerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current
    ) {
        self.fileURL = fileURL
        self.lock = lock
        self.fileIO = fileIO
        self.ownerProvider = ownerProvider
    }

    func read() throws -> DeviceEpochStoreState {
        try withLock { try loadState() }
    }

    func isCurrentOwner(_ owner: UUID) -> Bool {
        ownerProvider() == owner
    }

    /// The callback boundary is deliberately the sole local producer of v2
    /// sample work. It performs a non-mutating preflight first so rejected
    /// callbacks cannot bootstrap an empty root, then repeats every authority
    /// check under the root lock before any high-water or queue mutation.
    func enqueueAuthorizedV2Callback(
        _ input: MeteringAuthorizedCallbackInput,
        owner: UUID
    ) throws -> MeteringAuthorizedCallbackResult {
        guard isCurrentOwner(owner) else {
            return .discarded(reason: "owner_mismatch")
        }

        let preflight = try read()
        guard preflight.ownerChildDeviceID == owner else {
            return .discarded(reason: preflight.ownerChildDeviceID == nil ? "missing_owner" : "owner_mismatch")
        }
        guard preflight.routes[input.routeID] != nil else {
            return .discarded(reason: preflight.tombstones[input.routeID] == nil ? "unknown_route" : "tombstoned_route")
        }

        return try transaction(expectedOwner: owner) { state in
            authorizeV2Callback(&state, input: input, owner: owner)
        }
    }

    private func authorizeV2Callback(
        _ state: inout DeviceEpochStoreState,
        input: MeteringAuthorizedCallbackInput,
        owner: UUID
    ) -> MeteringAuthorizedCallbackResult {
        if state.tombstones[input.routeID] != nil {
            return .discarded(reason: "tombstoned_route")
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

        let earliest = epoch.startedAt.addingTimeInterval(
            TimeInterval(input.thresholdMinutes * 60 - input.jitterSeconds)
        )
        guard input.observedAt >= earliest else {
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

        switch callbackRouteAuthorization(route: route, epoch: epoch, owner: owner, ratchet: ratchet, state: state) {
        case .discarded(let reason):
            return .discarded(reason: reason)
        case .accepted:
            break
        }

        if epoch.resumeBoundaryPending {
            guard sampleAuthorization == .v2Deliverable else {
                return .discarded(reason: "resume_boundary_unregistered")
            }
            epoch.lastRawThresholdMinutes = max(epoch.lastRawThresholdMinutes, input.thresholdMinutes)
            epoch.excludedWhilePausedMinutes = max(epoch.excludedWhilePausedMinutes, input.thresholdMinutes)
            epoch.resumeBoundaryPending = false
            state.epochs[epoch.epochID] = epoch
            return .discarded(reason: "resume_boundary")
        }

        let rawThreshold = max(epoch.lastRawThresholdMinutes, input.thresholdMinutes)
        let estimatedMinutes = epoch.baseAcceptedMinutes + max(0, rawThreshold - epoch.excludedWhilePausedMinutes)
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
                activityName: route.activityName,
                eventName: input.eventName,
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
            return .discarded("handoff_preparing")
        case .dualV2:
            guard state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
                  route.routeID == handoff.fromRouteID || route.routeID == handoff.toRouteID
            else { return .discarded("handoff_route_mismatch") }
            return .accepted
        case .cutoverReady:
            if route.routeID == handoff.fromRouteID {
                return .discarded("handoff_prior_input_closed")
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
        return coverage.ownerChildDeviceID == owner
            && coverage.status == .ready
            && (coverage.readyThroughUsageDate ?? "") >= route.usageDate
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
            return install.authorization == .registered
                ? .accepted(.v2Deliverable)
                : .discarded("install_registration_mismatch")
        }

        guard install.authorization == .offlinePending,
              let handoff = state.v2RouteHandoff,
              handoff.ownerChildDeviceID == owner,
              handoff.toRouteID == route.routeID,
              handoff.toEpochID == route.epochID,
              handoff.toGenerationID == route.generationID,
              handoff.phase == .dualV2 || handoff.phase == .cutoverReady,
              state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
              state.routes[handoff.fromRouteID]?.usageDate == route.usageDate
        else { return .discarded("unregistered_route_not_candidate") }
        return .accepted(.waitingForRegistration)
    }

    func dueInstallWork(owner: UUID, now: Date) throws -> [ActivityInstallWork] {
        let state = try read()
        guard state.ownerChildDeviceID == owner else { throw DeviceEpochStoreError.ownerMismatch }
        return state.dueWork(now: now).compactMap { due in
            guard due.kind == .install else { return nil }
            return state.installWork.values.first { $0.workID == due.workID }
        }.filter { work in
            switch work.phase {
            case .pendingStart, .starting, .installed:
                return true
            case .verified, .dualActive, .active, .pendingStop, .stopped:
                return false
            }
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
            guard let route = state.routes[work.routeID],
                  state.hasCurrentRegistrationProvenance(
                      owner: owner,
                      epochID: route.epochID,
                      routeID: route.routeID
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

    func recordInstalledRoute(workID: UUID, token: UUID, owner: UUID, now: Date) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  let claim = work.claim,
                  claim.token == token,
                  claim.expiresAt > now
            else { return false }
            guard let route = state.routes[work.routeID],
                  state.hasCurrentRegistrationProvenance(owner: owner, epochID: route.epochID, routeID: route.routeID)
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

    func recordVerifiedRoute(workID: UUID, token: UUID, owner: UUID, now: Date) throws -> Bool {
        try transaction(expectedOwner: owner) { state in
            guard let key = state.installWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.installWork[key],
                  let claim = work.claim,
                  claim.token == token,
                  claim.expiresAt > now
            else { return false }
            guard let route = state.routes[work.routeID],
                  state.hasCurrentRegistrationProvenance(owner: owner, epochID: route.epochID, routeID: route.routeID)
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
                  state.hasCurrentRegistrationProvenance(
                      owner: owner,
                      epochID: failedRoute.epochID,
                      routeID: failedRoute.routeID
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

    @discardableResult
    func claimFirstNetworkWork(
        owner: UUID,
        now: Date,
        isEligible: (DeviceEpochStoreState, MeteringDueWork) -> Bool
    ) throws -> MeteringClaimedNetworkWork? {
        try transaction(expectedOwner: owner) { state in
            let dueWork = state.dueWork(now: now)
            guard let first = dueWork.first else { return nil }
            let due: MeteringDueWork
            if isEligible(state, first) {
                due = first
            } else {
                guard let handoff = state.v2RouteHandoff,
                      handoff.ownerChildDeviceID == owner,
                      handoff.phase == .cutoverReady,
                      state.activeGenerationID == handoff.fromGenerationID,
                      state.activeEpochID == handoff.fromEpochID,
                      state.activeRouteID == handoff.fromRouteID,
                      state.hasExactHandoffPriorProvenance(owner: owner, handoff: handoff),
                      let correctedRoute = state.routes[handoff.toRouteID],
                      correctedRoute.ownerChildDeviceID == owner,
                      correctedRoute.generationID == handoff.toGenerationID,
                      correctedRoute.epochID == handoff.toEpochID,
                      let correctedEpoch = state.epochs[handoff.toEpochID],
                      correctedEpoch.childDeviceID == owner,
                      correctedEpoch.baseSource == .registrationConflict409,
                      correctedEpoch.baseCorrectionState == .used,
                      correctedEpoch.authoritativeBaseConflict == nil,
                      let correctionIndex = dueWork.firstIndex(where: { item in
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
                      dueWork[..<correctionIndex].allSatisfy({ item in
                          guard item.kind == .install,
                                let install = state.installWork.values.first(where: { $0.workID == item.workID }),
                                install.ownerChildDeviceID == owner
                          else { return false }
                          switch install.phase {
                          case .verified, .dualActive, .active:
                              return true
                          case .pendingStart, .starting, .installed, .pendingStop, .stopped:
                              return false
                          }
                      }),
                      isEligible(state, dueWork[correctionIndex])
                else { return nil }
                due = dueWork[correctionIndex]
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

    @discardableResult
    internal func transaction<Value>(
        expectedOwner: UUID?,
        _ mutate: (inout DeviceEpochStoreState) throws -> Value
    ) throws -> Value {
        try withLock {
            let url = try resolvedFileURL()
            let priorData = try fileIO.read(from: url)
            var state = try decodeState(priorData)
            try validateStatic(state, expectedOwner: nil, requireOwnerMatch: false)
            try checkOwner(expectedOwner: expectedOwner, state: state)

            if state.ownerChildDeviceID == nil {
                state.ownerChildDeviceID = expectedOwner
            }

            var candidate = state
            let value = try mutate(&candidate)
            try checkOwner(expectedOwner: expectedOwner, state: candidate)
            try validateStatic(candidate, expectedOwner: expectedOwner, requireOwnerMatch: true)
            try validateTransactionDelta(candidate: candidate, priorState: state)

            // Re-encoding an unchanged Codable value can produce different bytes on
            // some SDKs. Rejected callback paths must be byte-identical no-ops.
            guard candidate != state else { return value }

            let encoded = try Self.encoder.encode(candidate)
            guard encoded != priorData else { return value }
            var writeAttempted = false
            do {
                writeAttempted = true
                try fileIO.writeAtomically(encoded, to: url)
                guard let readbackData = try fileIO.read(from: url) else {
                    throw DeviceEpochStoreError.readbackMismatch
                }
                // File IO must return the exact canonical payload we wrote. Comparing
                // decoded values can reject a valid write when Codable normalizes Date.
                guard readbackData == encoded else {
                    throw DeviceEpochStoreError.readbackMismatch
                }
                let readback = try decodeState(readbackData)
                try validateStatic(readback, expectedOwner: expectedOwner, requireOwnerMatch: true)
                try checkOwner(expectedOwner: expectedOwner, state: readback)
                return value
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

    private func resolvedFileURL() throws -> URL {
        if let fileURL { return fileURL }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MeteringOwnerMirror.suiteName
        ) else {
            throw DeviceEpochStoreError.appGroupContainerUnavailable
        }
        return container.appendingPathComponent(Self.fileName)
    }

    private func loadState() throws -> DeviceEpochStoreState {
        let url = try resolvedFileURL()
        let state = try decodeState(try fileIO.read(from: url))
        try validateStatic(state, expectedOwner: nil, requireOwnerMatch: false)
        return state
    }

    private func decodeState(_ data: Data?) throws -> DeviceEpochStoreState {
        guard let data else { return migrateLegacyIfNeeded(DeviceEpochStoreState()) }
        let state = try Self.decoder.decode(DeviceEpochStoreState.self, from: data)
        guard (1...DeviceEpochStoreState.currentSchemaVersion).contains(state.schemaVersion) else {
            throw DeviceEpochStoreError.unsupportedSchema(state.schemaVersion)
        }
        var migrated = state
        migrated.schemaVersion = DeviceEpochStoreState.currentSchemaVersion
        return migrateLegacyIfNeeded(migrated)
    }

    private func migrateLegacyIfNeeded(_ input: DeviceEpochStoreState) -> DeviceEpochStoreState {
        guard input.legacy == nil else { return input }
        let defaults = UserDefaults(suiteName: MeteringOwnerMirror.suiteName)
        guard let lifecycle = EarnedActivityGeneration.loadLifecycle(defaults: defaults) else {
            return input
        }

        let owner = input.ownerChildDeviceID
            ?? lifecycle.active.flatMap { UUID(uuidString: $0.deviceID) }
            ?? lifecycle.pending.flatMap { UUID(uuidString: $0.deviceID) }
            ?? ownerProvider()
        guard let owner else { return input }

        func provenance(_ generation: EarnedActivityGeneration.Generation?) -> LegacyGenerationProvenance? {
            guard let generation else { return nil }
            return LegacyGenerationProvenance(
                activityName: generation.activityName,
                deviceID: generation.deviceID,
                offsetMinutes: generation.offsetMinutes,
                armSignature: generation.armSignature,
                usageDate: generation.usageDate,
                timezoneIdentifier: generation.timezoneIdentifier,
                armedAt: generation.armedAt
            )
        }

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

        var migrated = input
        migrated.ownerChildDeviceID = owner
        migrated.legacy = LegacyCompatibilityMonitorState(
            ownerChildDeviceID: owner,
            lifecycleVersion: lifecycle.version,
            active: provenance(lifecycle.active),
            pending: provenance(lifecycle.pending),
            retiringActivityNames: lifecycle.retiringActivityNames,
            breadcrumbActivityNames: EarnedActivityGeneration.loadBreadcrumbs(defaults: defaults),
            scalarActiveActivityName: defaults?.string(forKey: EarnedActivityGeneration.activeActivityNameKey),
            isStopped: lifecycle.isStopped,
            phase: phase,
            stopAcknowledgedAt: nil
        )
        return migrated
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
                      work.request.activityName == route.activityName,
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
                        || canAbandonAuthoritativeBaseCorrection(priorHandoff, in: candidate) else {
                    throw DeviceEpochStoreInvariantError.invalidState("handoff was removed before exact stop acknowledgement")
                }
                return
            }
            if !hasSameImmutableTuple(candidateHandoff, as: priorHandoff) {
                guard isAuthoritativeBaseCorrectionHandoffReplacement(
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

        // A correction is intentionally single-use. A second 409 leaves the
        // functioning prior route in place, but cannot mint a third candidate.
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
            retiredAt: nil
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
            createdAt: now
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
            createdAt: now
        )
        v2RouteHandoff = handoff
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
        generations[route.generationID]?.retiredAt = now

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
            && currentHorizonUsageDates(
                owner: owner,
                generationID: handoff.fromGenerationID
            ).contains(fromRoute.usageDate)
        if hasActivePrior { return true }

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
            && legacy?.isStopped == true
            && fromRoute.usageDate == toRoute.usageDate
            && isValidUsageDate(
                fromRoute.usageDate,
                timeZoneIdentifier: fromGeneration.canonicalTimezone
            )
        return hasAcknowledgedRetiredPriorRecovery
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
