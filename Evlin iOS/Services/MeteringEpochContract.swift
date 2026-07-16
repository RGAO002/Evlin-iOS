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
        let deltaMinutes = input.adjustedEstimateMinutes - input.baseAcceptedMinutes
        guard deltaMinutes >= 0 else {
            return .rejectNegativeDelta
        }
        guard input.callbackAt >= input.startedAt else {
            return .rejectTooEarly
        }

        let elapsedSeconds = input.callbackAt.timeIntervalSince(input.startedAt)
        let clampedJitter = min(max(input.jitterSeconds, 0), maximumJitterSeconds)
        return TimeInterval(deltaMinutes * 60) <= elapsedSeconds + TimeInterval(clampedJitter)
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
