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

nonisolated struct ActivityInstallClaim: Codable, Equatable, Sendable {
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

    @discardableResult
    func claimFirstNetworkWork(
        owner: UUID,
        now: Date,
        isEligible: (DeviceEpochStoreState, MeteringDueWork) -> Bool
    ) throws -> MeteringClaimedNetworkWork? {
        try transaction(expectedOwner: owner) { state in
            guard let due = state.dueWork(now: now).first,
                  isEligible(state, due)
            else { return nil }
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
    func transaction<Value>(
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
                let candidateInstallIsActive = state.installWork.values.contains {
                    $0.routeID == handoff.toRouteID && $0.phase == .active
                }
                let priorInstallIsStopped = state.installWork.values.contains {
                    $0.routeID == handoff.fromRouteID && $0.phase == .stopped
                }
                let priorTombstone = state.tombstones[handoff.fromRouteID]
                guard state.activeRouteID == handoff.toRouteID,
                      state.activeEpochID == handoff.toEpochID,
                      state.activeGenerationID == handoff.toGenerationID,
                      toEpoch.status == .active,
                      toEpoch.registeredAt != nil,
                      toRoute.lifecycle == .active,
                      toRoute.installedSchedule != nil,
                      toRoute.installedEvents != nil,
                      candidateInstallIsActive,
                      fromEpoch.status == .retired,
                      fromEpoch.retiredAt != nil,
                      fromEpoch.retireReason != nil,
                      fromRoute.lifecycle == .tombstoned,
                      priorTombstone?.stopAcknowledgedAt != nil,
                      priorInstallIsStopped,
                      handoff.registrationAcknowledgedAt != nil,
                      handoff.activationAcknowledgedAt != nil,
                      handoff.priorStopAcknowledgedAt != nil
                else {
                    throw DeviceEpochStoreInvariantError.invalidState("handoff collection prerequisites are incomplete")
                }
            }
        }
    }

    private func validateTransactionDelta(
        candidate: DeviceEpochStoreState,
        priorState: DeviceEpochStoreState
    ) throws {
        guard let handoff = candidate.v2RouteHandoff,
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

private extension DeviceEpochStoreState {
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
