import CryptoKit
import Foundation

nonisolated enum AppLimitCallbackEffectKind: Equatable, Sendable {
    case measurement
    case enforcement
}

nonisolated struct AppLimitValidatedCallback: Equatable, Sendable {
    let rule: AppLimitRule
    let provenance: AppLimitArmProvenance
    let effectKind: AppLimitCallbackEffectKind
    let rawThresholdMinutes: Int
    let adjustedEstimateMinutes: Int
}

nonisolated enum AppLimitCallbackDecision: Equatable, Sendable {
    case accepted(AppLimitValidatedCallback)
    case paused(AppLimitValidatedCallback)
    case rejected(reason: String)
}

nonisolated enum AppLimitCallbackLocalLedger {
    static func record(
        _ callback: AppLimitValidatedCallback,
        store: EarnedTimeStore = .shared
    ) throws {
        try store.recordAppLimitUsageVerified(
            ruleID: callback.rule.id,
            usageDate: callback.provenance.usageDate,
            usedMinutes: callback.adjustedEstimateMinutes
        )
    }
}

/// Resolves one per-app callback against its persisted arm before any external
/// effect can observe it.
nonisolated final class AppLimitCallbackValidator: @unchecked Sendable {
    private struct Evaluation {
        let decision: AppLimitCallbackDecision
        let physicallyImpossibleCallback: AppLimitValidatedCallback?
    }

    private let store: AppLimitEpochStore

    init(store: AppLimitEpochStore = .shared) {
        self.store = store
    }

    func validate(
        activityName: String,
        eventName: String,
        canonicalUsageDate: String,
        observedAt: Date,
        usageCountingAllowed: Bool
    ) throws -> AppLimitCallbackDecision {
        try evaluate(
            activityName: activityName,
            eventName: eventName,
            canonicalUsageDate: canonicalUsageDate,
            observedAt: observedAt,
            usageCountingAllowed: usageCountingAllowed
        ).decision
    }

    private func evaluate(
        activityName: String,
        eventName: String,
        canonicalUsageDate: String,
        observedAt: Date,
        usageCountingAllowed: Bool
    ) throws -> Evaluation {
        let state = try store.read()
        let matches = state.slots.values.compactMap { slot -> (AppLimitVersionSlot, AppLimitArmProvenance)? in
            guard let provenance = slot.armProvenance,
                  provenance.activityName == activityName
            else { return nil }
            return (slot, provenance)
        }
        guard matches.count == 1, let (slot, provenance) = matches.first else {
            return Evaluation(
                decision: .rejected(reason: "unknown_activity"),
                physicallyImpossibleCallback: nil
            )
        }
        guard let rule = slot.activeRule,
              slot.latestKind == .set,
              state.ownerChildDeviceID == provenance.childDeviceID,
              slot.ruleID == provenance.ruleID,
              rule.id == provenance.ruleID,
              slot.latestOrderingToken == provenance.ruleRevision,
              canonicalUsageDate == provenance.usageDate,
              provenance.activityName
                == "evlin.limit.v2.\(provenance.armID.uuidString.lowercased())",
              provenance.scheduleWindow == rule.window,
              provenance.budgetMinutes == rule.budgetMinutes,
              provenance.tokenDigest == Self.tokenDigest(rule: rule)
        else {
            return Evaluation(
                decision: .rejected(reason: "stale_provenance"),
                physicallyImpossibleCallback: nil
            )
        }

        let (remainingBudgetMinutes, remainingOverflow) = provenance.budgetMinutes
            .subtractingReportingOverflow(provenance.baseAcceptedMinutes)
        guard !remainingOverflow,
              provenance.baseAcceptedMinutes >= 0,
              provenance.ignoredWhilePausedMinutes >= 0,
              remainingBudgetMinutes > 0,
              let parsedEvent = Self.parseEvent(
                eventName,
                armID: provenance.armID,
                remainingBudgetMinutes: remainingBudgetMinutes
              )
        else {
            return Evaluation(
                decision: .rejected(reason: "unexpected_event"),
                physicallyImpossibleCallback: nil
            )
        }
        let rawThresholdMinutes = parsedEvent.rawThresholdMinutes
        guard rawThresholdMinutes > 0,
              rawThresholdMinutes > provenance.lastRawThresholdMinutes
        else {
            return Evaluation(
                decision: .rejected(reason: "unexpected_event"),
                physicallyImpossibleCallback: nil
            )
        }

        let (unignoredThresholdMinutes, subtractionOverflow) = rawThresholdMinutes
            .subtractingReportingOverflow(provenance.ignoredWhilePausedMinutes)
        guard !subtractionOverflow else {
            return Evaluation(
                decision: .rejected(reason: "invalid_estimate"),
                physicallyImpossibleCallback: nil
            )
        }
        let (adjustedEstimateMinutes, overflow) = provenance.baseAcceptedMinutes
            .addingReportingOverflow(max(0, unignoredThresholdMinutes))
        guard !overflow else {
            return Evaluation(
                decision: .rejected(reason: "invalid_estimate"),
                physicallyImpossibleCallback: nil
            )
        }

        let callback = AppLimitValidatedCallback(
            rule: rule,
            provenance: provenance,
            effectKind: parsedEvent.effectKind,
            rawThresholdMinutes: rawThresholdMinutes,
            adjustedEstimateMinutes: adjustedEstimateMinutes
        )
        guard usageCountingAllowed else {
            return Evaluation(decision: .paused(callback), physicallyImpossibleCallback: nil)
        }
        guard MeteringCallbackPhysicalTime.allows(
            adjustedEstimateMinutes: adjustedEstimateMinutes,
            baseAcceptedMinutes: provenance.baseAcceptedMinutes,
            startedAt: provenance.startedAt,
            observedAt: observedAt
        ) else {
            return Evaluation(
                decision: .rejected(reason: "physically_impossible"),
                physicallyImpossibleCallback: callback
            )
        }
        return Evaluation(decision: .accepted(callback), physicallyImpossibleCallback: nil)
    }

    /// Owns the complete callback boundary. Accepted effects must first create
    /// their idempotent durable journal entry; only then may this consume the
    /// one-shot callback by advancing the persisted high-water. Reversing that
    /// order loses the callback forever if journal persistence fails.
    @discardableResult
    func process(
        activityName: String,
        eventName: String,
        canonicalUsageDate: String,
        observedAt: Date,
        usageCountingAllowed: Bool,
        acceptedEffect: (AppLimitValidatedCallback) throws -> Void
    ) throws -> AppLimitCallbackDecision {
        let evaluation = try evaluate(
            activityName: activityName,
            eventName: eventName,
            canonicalUsageDate: canonicalUsageDate,
            observedAt: observedAt,
            usageCountingAllowed: usageCountingAllowed
        )
        let decision = evaluation.decision
        switch decision {
        case .rejected(reason: "physically_impossible"):
            if let callback = evaluation.physicallyImpossibleCallback {
                _ = try markPhysicalEventsConsumed(callback, observedAt: observedAt)
            }
            return decision
        case .rejected:
            return decision
        case .paused(let callback):
            _ = try recordPausedIgnoredHighWater(callback)
            return decision
        case .accepted(let callback):
            try acceptedEffect(callback)
            guard try recordAcceptedHighWater(callback) else {
                return .rejected(reason: "duplicate_or_stale")
            }
            return decision
        }
    }

    func recordAcceptedHighWater(_ callback: AppLimitValidatedCallback) throws -> Bool {
        try updateHighWater(callback, allowAdvancedAcceptedHighWater: true) { provenance in
            guard callback.rawThresholdMinutes > provenance.lastRawThresholdMinutes else {
                return false
            }
            provenance.lastRawThresholdMinutes = callback.rawThresholdMinutes
            provenance.physicalEventsConsumedAt = nil
            return true
        }
    }

    private func markPhysicalEventsConsumed(
        _ callback: AppLimitValidatedCallback,
        observedAt: Date
    ) throws -> Bool {
        try updateHighWater(
            callback,
            allowAdvancedAcceptedHighWater: false
        ) { provenance in
            guard provenance.physicalEventsConsumedAt == nil else { return false }
            provenance.physicalEventsConsumedAt = observedAt
            return true
        }
    }

    func recordPausedIgnoredHighWater(_ callback: AppLimitValidatedCallback) throws -> Bool {
        try updateHighWater(callback, allowAdvancedAcceptedHighWater: false) { provenance in
            let next = max(provenance.ignoredWhilePausedMinutes, callback.rawThresholdMinutes)
            guard next != provenance.ignoredWhilePausedMinutes else { return false }
            provenance.ignoredWhilePausedMinutes = next
            return true
        }
    }

    private func updateHighWater(
        _ callback: AppLimitValidatedCallback,
        allowAdvancedAcceptedHighWater: Bool,
        update: (inout AppLimitArmProvenance) -> Bool
    ) throws -> Bool {
        try store.transaction(
            source: .wakeRecovery,
            expectedOwner: callback.provenance.childDeviceID
        ) { state in
            guard state.ownerChildDeviceID == callback.provenance.childDeviceID,
                  var slot = state.slots[callback.provenance.ruleID],
                  slot.latestKind == .set,
                  slot.latestOrderingToken == callback.provenance.ruleRevision,
                  slot.activeRule == callback.rule,
                  var provenance = slot.armProvenance,
                  Self.sameArmSnapshot(
                    provenance,
                    as: callback.provenance,
                    allowingAdvancedAcceptedHighWater: allowAdvancedAcceptedHighWater
                  )
            else { return false }
            guard update(&provenance) else { return false }
            slot.armProvenance = provenance
            state.slots[callback.provenance.ruleID] = slot
            return true
        }
    }

    private static func sameArmSnapshot(
        _ current: AppLimitArmProvenance,
        as validated: AppLimitArmProvenance,
        allowingAdvancedAcceptedHighWater: Bool
    ) -> Bool {
        current.replacementKey == validated.replacementKey
            && current.armID == validated.armID
            && current.activityName == validated.activityName
            && current.startedAt == validated.startedAt
            && current.baseAcceptedMinutes == validated.baseAcceptedMinutes
            && current.ignoredWhilePausedMinutes == validated.ignoredWhilePausedMinutes
            && current.physicalEventsConsumedAt == validated.physicalEventsConsumedAt
            && current.physicalReplacementAttemptCount
                == validated.physicalReplacementAttemptCount
            && (allowingAdvancedAcceptedHighWater
                || current.lastRawThresholdMinutes == validated.lastRawThresholdMinutes)
    }

    private static func parseEvent(
        _ eventName: String,
        armID: UUID,
        remainingBudgetMinutes: Int
    ) -> (effectKind: AppLimitCallbackEffectKind, rawThresholdMinutes: Int)? {
        let normalizedArmID = armID.uuidString.lowercased()
        if eventName == "evlin.limit.v2.\(normalizedArmID).budget" {
            return (.enforcement, remainingBudgetMinutes)
        }

        let prefix = "evlin.applimit.v2.\(normalizedArmID).t"
        guard eventName.hasPrefix(prefix) else { return nil }
        let suffix = String(eventName.dropFirst(prefix.count))
        guard let threshold = Int(suffix),
              eventName == "\(prefix)\(threshold)",
              measurementThresholds(
                remainingBudgetMinutes: remainingBudgetMinutes
              ).contains(threshold)
        else { return nil }
        return (.measurement, threshold)
    }

    /// Mirrors AppLimitPlanner.measurementThresholds. This file is shared with
    /// the monitor target, where the app-only planner is intentionally absent.
    private static func measurementThresholds(
        remainingBudgetMinutes: Int
    ) -> [Int] {
        guard remainingBudgetMinutes >= 2 else { return [] }
        let quarters = [0.25, 0.5, 0.75].map {
            Int((Double(remainingBudgetMinutes) * $0).rounded())
        }
        return Array(
            Set(quarters.filter { $0 > 0 && $0 < remainingBudgetMinutes })
        ).sorted()
    }

    private static func tokenDigest(rule: AppLimitRule) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = rule.appTokens.compactMap { try? encoder.encode($0) }.sorted {
            $0.lexicographicallyPrecedes($1)
        }
        var bytes = Data()
        for token in encoded {
            var count = UInt64(token.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(token)
        }
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
