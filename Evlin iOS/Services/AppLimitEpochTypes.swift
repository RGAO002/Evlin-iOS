import FamilyControls
import Foundation
import ManagedSettings

nonisolated struct AppLimitWindow: Codable, Sendable, Equatable {
    let startMinute: Int
    let endMinute: Int
    let repeats: Bool
    let timezone: String?
}

nonisolated struct AppLimitRule: Codable, Sendable, Equatable {
    let id: UUID
    let appTokens: Set<ApplicationToken>
    let bundleID: String
    let displayName: String
    let budgetMinutes: Int
    let window: AppLimitWindow
    let effectiveFrom: Date
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, appTokens, bundleID, displayName, budgetMinutes, window
        case effectiveFrom, expiresAt
    }

    init(
        id: UUID,
        appTokens: Set<ApplicationToken>,
        bundleID: String,
        displayName: String,
        budgetMinutes: Int,
        window: AppLimitWindow,
        effectiveFrom: Date,
        expiresAt: Date?
    ) {
        self.id = id
        self.appTokens = appTokens
        self.bundleID = bundleID
        self.displayName = displayName
        self.budgetMinutes = budgetMinutes
        self.window = window
        self.effectiveFrom = effectiveFrom
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        appTokens = Set(try values.decode([ApplicationToken].self, forKey: .appTokens))
        bundleID = try values.decode(String.self, forKey: .bundleID)
        displayName = try values.decode(String.self, forKey: .displayName)
        budgetMinutes = try values.decode(Int.self, forKey: .budgetMinutes)
        window = try values.decode(AppLimitWindow.self, forKey: .window)
        effectiveFrom = try values.decode(Date.self, forKey: .effectiveFrom)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        let sortedTokens = try appTokens.sorted {
            try Self.canonicalTokenBytes($0).lexicographicallyPrecedes(Self.canonicalTokenBytes($1))
        }
        try values.encode(sortedTokens, forKey: .appTokens)
        try values.encode(bundleID, forKey: .bundleID)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(budgetMinutes, forKey: .budgetMinutes)
        try values.encode(window, forKey: .window)
        try values.encode(effectiveFrom, forKey: .effectiveFrom)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }

    private static func canonicalTokenBytes(_ token: ApplicationToken) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(token)
    }
}

nonisolated enum AppLimitCommandSource: String, Codable, Sendable {
    case poll
    case notificationServiceExtension
    case wakeRecovery
}

nonisolated enum AppLimitCommandKind: String, Codable, Sendable {
    case set
    case clear
}

nonisolated struct AppLimitCommandEnvelope: Codable, Equatable, Sendable {
    let commandID: UUID
    let ruleID: UUID
    let orderingToken: Int64
    let kind: AppLimitCommandKind
    let payloadDigest: String
    let receivedAt: Date
    let source: AppLimitCommandSource
    let rule: AppLimitRule?
}

nonisolated struct AppLimitClearTombstone: Codable, Equatable, Sendable {
    let ruleID: UUID
    let orderingToken: Int64
    let payloadDigest: String
    let source: AppLimitCommandSource
    let clearedAt: Date
}

nonisolated struct AppLimitOwnerWork: Codable, Equatable, Sendable {
    let workID: UUID
    let commandID: UUID
    let ruleID: UUID
    let orderingToken: Int64
    let commandKind: AppLimitCommandKind
    let payloadDigest: String
    let source: AppLimitCommandSource
    let createdAt: Date
}

nonisolated struct AppLimitApplyReceipt: Codable, Equatable, Sendable {
    let ruleID: UUID
    let orderingToken: Int64
    let commandKind: AppLimitCommandKind
    let armID: UUID?
    let source: String
    let appliedAt: Date
    let storeRevision: UInt64
}

nonisolated enum AppLimitJournalEffectKind: String, Codable, Equatable, Sendable {
    case measurement
    case enforcement
}

nonisolated struct AppLimitEffectKey: Codable, Equatable, Hashable, Sendable {
    let ruleID: UUID
    let orderingToken: Int64
    let armID: UUID
    let effectKind: AppLimitJournalEffectKind
    let rawThresholdMinutes: Int

    var storageKey: String {
        [
            ruleID.uuidString.lowercased(),
            String(orderingToken),
            armID.uuidString.lowercased(),
            effectKind.rawValue,
            String(rawThresholdMinutes),
        ].joined(separator: ":")
    }
}

nonisolated struct AppLimitEffectLease: Codable, Equatable, Sendable {
    let leaseID: UUID
    let workerID: UUID
    let claimedAt: Date
    let expiresAt: Date
}

nonisolated struct AppLimitLocalEffectReceipt: Codable, Equatable, Sendable {
    let key: AppLimitEffectKey
    let source: String
    let appliedAt: Date
}

nonisolated struct AppLimitUsageEffectReceipt: Codable, Equatable, Sendable {
    let key: AppLimitEffectKey
    let usedMinutes: Int
    let currentOrderingToken: Int64
    let appliedAt: Date
}

nonisolated struct AppLimitBackendRejection: Codable, Equatable, Sendable {
    let currentOrderingToken: Int64
    let reason: String
    let rejectedAt: Date
}

nonisolated struct AppLimitEffectEnvelope: Codable, Equatable, Sendable {
    let key: AppLimitEffectKey
    let rule: AppLimitRule
    let provenance: AppLimitArmProvenance
    let adjustedEstimateMinutes: Int
    let createdAt: Date
    var lease: AppLimitEffectLease?
    var localReceipt: AppLimitLocalEffectReceipt?
    var usageReceipt: AppLimitUsageEffectReceipt?
    var backendRejection: AppLimitBackendRejection?
    var retryNotBefore: Date? = nil
    var retryAttemptCount: Int? = nil
}

nonisolated struct AppLimitEffectClaim: Equatable, Sendable {
    let effect: AppLimitEffectEnvelope
    let lease: AppLimitEffectLease
}

nonisolated struct AppLimitVersionSlot: Codable, Equatable, Sendable {
    let ruleID: UUID
    var latestOrderingToken: Int64
    var latestKind: AppLimitCommandKind
    var latestPayloadDigest: String
    var activeRule: AppLimitRule?
    var clearTombstone: AppLimitClearTombstone?
    var pendingOwnerWork: AppLimitOwnerWork?
    var appliedReceipt: AppLimitApplyReceipt?
    var armProvenance: AppLimitArmProvenance? = nil
}

nonisolated struct AppLimitReplacementKey: Codable, Equatable, Sendable {
    let ruleID: UUID
    let ruleRevision: Int64
    let childDeviceID: UUID
    let usageDate: String
    let timezone: String
    let scheduleWindow: AppLimitWindow
    let tokenDigest: String
    let budgetMinutes: Int
}

nonisolated struct AppLimitArmProvenance: Codable, Equatable, Sendable {
    let ruleID: UUID
    let ruleRevision: Int64
    let childDeviceID: UUID
    let usageDate: String
    let timezone: String
    let scheduleWindow: AppLimitWindow
    let tokenDigest: String
    let budgetMinutes: Int
    var startedAt: Date
    var baseAcceptedMinutes: Int
    var lastRawThresholdMinutes: Int
    var ignoredWhilePausedMinutes: Int
    let activityName: String
    let armID: UUID

    var replacementKey: AppLimitReplacementKey {
        AppLimitReplacementKey(
            ruleID: ruleID,
            ruleRevision: ruleRevision,
            childDeviceID: childDeviceID,
            usageDate: usageDate,
            timezone: timezone,
            scheduleWindow: scheduleWindow,
            tokenDigest: tokenDigest,
            budgetMinutes: budgetMinutes
        )
    }
}

nonisolated extension AppLimitVersionSlot {
    init(accepting command: AppLimitCommandEnvelope) {
        let ownerWork = AppLimitOwnerWork(
            workID: command.commandID,
            commandID: command.commandID,
            ruleID: command.ruleID,
            orderingToken: command.orderingToken,
            commandKind: command.kind,
            payloadDigest: command.payloadDigest,
            source: command.source,
            createdAt: command.receivedAt
        )
        self.init(
            ruleID: command.ruleID,
            latestOrderingToken: command.orderingToken,
            latestKind: command.kind,
            latestPayloadDigest: command.payloadDigest,
            activeRule: command.kind == .set ? command.rule : nil,
            clearTombstone: command.kind == .clear ? AppLimitClearTombstone(
                ruleID: command.ruleID,
                orderingToken: command.orderingToken,
                payloadDigest: command.payloadDigest,
                source: command.source,
                clearedAt: command.receivedAt
            ) : nil,
            pendingOwnerWork: ownerWork,
            appliedReceipt: nil
        )
    }
}

nonisolated struct AppLimitLegacyMigrationAudit: Codable, Equatable, Sendable {
    let sourceKey: String
    let sourceFormat: String
    let payloadSHA256: String
    let payloadByteCount: Int
    let migratedRuleCount: Int
    let migratedAtStoreRevision: UInt64
}

nonisolated struct AppLimitEpochStoreState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var storeRevision: UInt64
    var ownerChildDeviceID: UUID?
    var slots: [UUID: AppLimitVersionSlot]
    var legacyMigration: AppLimitLegacyMigrationAudit?
    var lastMutationSource: AppLimitCommandSource?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, storeRevision, ownerChildDeviceID, slots
        case legacyMigration, lastMutationSource
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        storeRevision: UInt64 = 0,
        ownerChildDeviceID: UUID? = nil,
        slots: [UUID: AppLimitVersionSlot] = [:],
        legacyMigration: AppLimitLegacyMigrationAudit? = nil,
        lastMutationSource: AppLimitCommandSource? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.storeRevision = storeRevision
        self.ownerChildDeviceID = ownerChildDeviceID
        self.slots = slots
        self.legacyMigration = legacyMigration
        self.lastMutationSource = lastMutationSource
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        storeRevision = try values.decode(UInt64.self, forKey: .storeRevision)
        ownerChildDeviceID = try values.decodeIfPresent(UUID.self, forKey: .ownerChildDeviceID)
        let encodedSlots = try values.decode(
            [String: AppLimitVersionSlot].self,
            forKey: .slots
        )
        var decodedSlots: [UUID: AppLimitVersionSlot] = [:]
        for (key, slot) in encodedSlots {
            guard let ruleID = UUID(uuidString: key), ruleID == slot.ruleID else {
                throw DecodingError.dataCorruptedError(
                    forKey: .slots,
                    in: values,
                    debugDescription: "slot key does not match rule identity"
                )
            }
            decodedSlots[ruleID] = slot
        }
        slots = decodedSlots
        legacyMigration = try values.decodeIfPresent(
            AppLimitLegacyMigrationAudit.self,
            forKey: .legacyMigration
        )
        lastMutationSource = try values.decodeIfPresent(
            AppLimitCommandSource.self,
            forKey: .lastMutationSource
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(storeRevision, forKey: .storeRevision)
        try values.encodeIfPresent(ownerChildDeviceID, forKey: .ownerChildDeviceID)
        let encodedSlots = Dictionary(uniqueKeysWithValues: slots.map {
            ($0.key.uuidString.lowercased(), $0.value)
        })
        try values.encode(encodedSlots, forKey: .slots)
        try values.encodeIfPresent(legacyMigration, forKey: .legacyMigration)
        try values.encodeIfPresent(lastMutationSource, forKey: .lastMutationSource)
    }

    @discardableResult
    mutating func replaceSlotIfNewer(_ candidate: AppLimitVersionSlot) -> Bool {
        guard candidate.latestOrderingToken >= 0 else { return false }
        if let current = slots[candidate.ruleID],
           candidate.latestOrderingToken <= current.latestOrderingToken {
            return false
        }
        slots[candidate.ruleID] = candidate
        return true
    }
}

nonisolated enum AppLimitCommandDisposition: Equatable, Sendable {
    case acceptedNeedsOwner
    case duplicatePending
    case duplicateApplied(AppLimitApplyReceipt)
    case superseded(latestOrderingToken: Int64)
    case equalTokenConflict
}

nonisolated protocol AppLimitOwnerReadbackPort: Sendable {
    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws
}

nonisolated enum AppLimitReceiptReadback {
    static func currentAppliedReceipt(
        ruleID: UUID,
        store: AppLimitEpochStore = .shared
    ) throws -> AppLimitApplyReceipt? {
        let state = try store.read()
        guard let slot = state.slots[ruleID],
              let receipt = slot.appliedReceipt,
              receipt.ruleID == ruleID,
              receipt.orderingToken == slot.latestOrderingToken,
              receipt.commandKind == slot.latestKind,
              !receipt.source.isEmpty
        else { return nil }
        switch slot.latestKind {
        case .set:
            guard slot.activeRule?.id == ruleID,
                  let armID = slot.armProvenance?.armID,
                  slot.armProvenance?.ruleRevision == slot.latestOrderingToken,
                  receipt.armID == armID
            else { return nil }
        case .clear:
            guard slot.activeRule == nil,
                  slot.clearTombstone?.orderingToken == slot.latestOrderingToken,
                  receipt.armID == nil
            else { return nil }
        }
        return receipt
    }
}
