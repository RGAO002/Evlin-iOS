import CryptoKit
import Foundation

nonisolated enum AppLimitIntervalStartDecision: Equatable, Sendable {
    case notPerAppV2
    case resetLimitShields(
        rollover: AppLimitProvenanceStore.IntervalRolloverResult
    )
    case failClosed(reason: String)
}

nonisolated final class AppLimitIntervalStartRouter: @unchecked Sendable {
    private static let activityPrefix = "evlin.limit.v2."

    private let provenanceStore: AppLimitProvenanceStore

    init(provenanceStore: AppLimitProvenanceStore = AppLimitProvenanceStore()) {
        self.provenanceStore = provenanceStore
    }

    func route(activityName: String, now: Date) -> AppLimitIntervalStartDecision {
        guard activityName.hasPrefix(Self.activityPrefix) else {
            return .notPerAppV2
        }

        let suffix = String(activityName.dropFirst(Self.activityPrefix.count))
        guard let armID = UUID(uuidString: suffix),
              suffix.lowercased() == armID.uuidString.lowercased()
        else {
            return .failClosed(reason: "malformed_activity")
        }

        do {
            let result = try provenanceStore.rolloverRecurringInterval(
                activityName: activityName,
                now: now
            )
            switch result {
            case .rolledOver, .unchanged:
                return .resetLimitShields(rollover: result)
            case .rejected(let reason):
                return .failClosed(reason: reason)
            }
        } catch {
            return .failClosed(reason: "rollover_error")
        }
    }
}

nonisolated final class AppLimitProvenanceStore: @unchecked Sendable {
    struct Resolution: Equatable, Sendable {
        let provenance: AppLimitArmProvenance
        let replaced: Bool
    }

    enum IntervalRolloverResult: Equatable, Sendable {
        case rolledOver(from: String, to: String)
        case unchanged(usageDate: String)
        case rejected(reason: String)
    }

    private enum ProvenanceError: Error {
        case missingCurrentRule
        case ownerMismatch
        case staleArm
        case physicalRecoveryExhausted
    }

    private let store: AppLimitEpochStore
    private let armIDProvider: @Sendable () -> UUID

    init(
        store: AppLimitEpochStore = .shared,
        armIDProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.armIDProvider = armIDProvider
    }

    func resolve(
        rule: AppLimitRule,
        ownerChildDeviceID: UUID,
        now: Date
    ) throws -> Resolution {
        try store.transaction(
            source: .wakeRecovery,
            expectedOwner: ownerChildDeviceID
        ) { state in
            guard state.ownerChildDeviceID == ownerChildDeviceID else {
                throw ProvenanceError.ownerMismatch
            }
            guard var slot = state.slots[rule.id],
                  slot.latestKind == .set,
                  let canonicalRule = slot.activeRule,
                  Self.isSchedulingView(rule, of: canonicalRule)
            else { throw ProvenanceError.missingCurrentRule }

            let timezone = Self.timezone(for: canonicalRule.window)
            let timezoneID = canonicalRule.window.timezone.flatMap {
                TimeZone(identifier: $0) == nil ? nil : $0
            } ?? timezone.identifier
            let usageDate = Self.usageDate(now, timezone: timezone)
            let acceptedBase = max(0, canonicalRule.budgetMinutes - rule.budgetMinutes)
            let key = AppLimitReplacementKey(
                ruleID: canonicalRule.id,
                ruleRevision: slot.latestOrderingToken,
                childDeviceID: ownerChildDeviceID,
                usageDate: usageDate,
                timezone: timezoneID,
                scheduleWindow: canonicalRule.window,
                tokenDigest: Self.tokenDigest(rule: canonicalRule),
                budgetMinutes: canonicalRule.budgetMinutes
            )
            if let existing = slot.armProvenance,
               existing.replacementKey == key {
                guard existing.physicalEventsConsumedAt != nil else {
                    return Resolution(provenance: existing, replaced: false)
                }
                let replacementAttempt = existing.physicalReplacementAttemptCount ?? 0
                guard replacementAttempt < 2 else {
                    throw ProvenanceError.physicalRecoveryExhausted
                }

                let acceptedRaw = max(
                    0,
                    existing.lastRawThresholdMinutes - existing.ignoredWhilePausedMinutes
                )
                let (acceptedBase, overflow) = existing.baseAcceptedMinutes
                    .addingReportingOverflow(acceptedRaw)
                guard !overflow, acceptedBase < existing.budgetMinutes else {
                    throw ProvenanceError.physicalRecoveryExhausted
                }

                // Preserve the physical-time already earned by this policy arm.
                // Resetting the anchor to `now` makes Apple's inherited immediate
                // events look impossible again and can wedge the bar forever.
                let preservedStart = existing.startedAt.addingTimeInterval(
                    TimeInterval(acceptedRaw * 60)
                )
                if replacementAttempt == 1 {
                    // The first replacement is allowed immediately. If Apple
                    // consumes that replacement too, wait until the complete
                    // remaining budget is physically plausible before minting
                    // one final bounded identity. Polling may retry this check,
                    // but it cannot create identities while the check is false.
                    guard MeteringCallbackPhysicalTime.allows(
                        adjustedEstimateMinutes: existing.budgetMinutes,
                        baseAcceptedMinutes: acceptedBase,
                        startedAt: preservedStart,
                        observedAt: now
                    ) else {
                        throw ProvenanceError.physicalRecoveryExhausted
                    }
                }

                let armID = armIDProvider()
                var replacement = existing
                replacement.startedAt = preservedStart
                replacement.baseAcceptedMinutes = acceptedBase
                replacement.lastRawThresholdMinutes = 0
                replacement.ignoredWhilePausedMinutes = 0
                replacement.predecessorIgnoredWhilePausedMinutes = existing.ignoredWhilePausedMinutes
                replacement.monitorStartPending = true
                replacement.physicalEventsConsumedAt = nil
                replacement.physicalReplacementAttemptCount = replacementAttempt + 1
                replacement.activityName = Self.activityName(armID: armID)
                replacement.armID = armID
                slot.armProvenance = replacement
                state.slots[canonicalRule.id] = slot
                return Resolution(provenance: replacement, replaced: true)
            }

            let armID = armIDProvider()
            let provenance = AppLimitArmProvenance(
                ruleID: key.ruleID,
                ruleRevision: key.ruleRevision,
                childDeviceID: key.childDeviceID,
                usageDate: key.usageDate,
                timezone: key.timezone,
                scheduleWindow: key.scheduleWindow,
                tokenDigest: key.tokenDigest,
                budgetMinutes: key.budgetMinutes,
                startedAt: now,
                baseAcceptedMinutes: acceptedBase,
                lastRawThresholdMinutes: 0,
                ignoredWhilePausedMinutes: 0,
                activityName: Self.activityName(armID: armID),
                armID: armID
            )
            slot.armProvenance = provenance
            state.slots[canonicalRule.id] = slot
            return Resolution(provenance: provenance, replaced: true)
        }
    }

    func recordStartAttempt(
        _ provenance: AppLimitArmProvenance,
        ownerChildDeviceID: UUID,
        startedAt: Date
    ) throws -> AppLimitArmProvenance {
        try store.transaction(
            source: .wakeRecovery,
            expectedOwner: ownerChildDeviceID
        ) { state in
            guard state.ownerChildDeviceID == ownerChildDeviceID else {
                throw ProvenanceError.ownerMismatch
            }
            guard var slot = state.slots[provenance.ruleID],
                  var current = slot.armProvenance,
                  current.armID == provenance.armID,
                  current.replacementKey == provenance.replacementKey
            else { throw ProvenanceError.staleArm }

            // A physical replacement inherits the original elapsed-time anchor.
            // Only a genuinely new policy arm records the scheduler attempt time.
            if current.physicalReplacementAttemptCount == nil {
                current.startedAt = startedAt
            }
            slot.armProvenance = current
            state.slots[provenance.ruleID] = slot
            return current
        }
    }

    /// Advances the accounting identity of an already-running recurring Apple
    /// monitor. DeviceActivity resets its event counters at the interval
    /// boundary, so this transition must not replace or restart the monitor.
    func rolloverRecurringInterval(
        activityName: String,
        now: Date
    ) throws -> IntervalRolloverResult {
        let snapshot = try store.read()
        let snapshotMatches = snapshot.slots.values.compactMap { slot -> AppLimitArmProvenance? in
            guard slot.armProvenance?.activityName == activityName else { return nil }
            return slot.armProvenance
        }
        guard snapshotMatches.count == 1,
              let expectedOwner = snapshotMatches.first?.childDeviceID
        else {
            return .rejected(reason: "unknown_activity")
        }

        return try store.transaction(
            source: .wakeRecovery,
            expectedOwner: expectedOwner
        ) { state in
            let matches = state.slots.values.compactMap {
                slot -> (AppLimitVersionSlot, AppLimitArmProvenance)? in
                guard let provenance = slot.armProvenance,
                      provenance.activityName == activityName
                else { return nil }
                return (slot, provenance)
            }
            guard matches.count == 1, let (matchedSlot, provenance) = matches.first,
                  state.ownerChildDeviceID == expectedOwner,
                  provenance.childDeviceID == expectedOwner,
                  matchedSlot.latestKind == .set,
                  let rule = matchedSlot.activeRule,
                  rule.id == provenance.ruleID,
                  matchedSlot.ruleID == provenance.ruleID,
                  matchedSlot.latestOrderingToken == provenance.ruleRevision,
                  rule.window.repeats,
                  provenance.scheduleWindow == rule.window,
                  provenance.budgetMinutes == rule.budgetMinutes,
                  provenance.tokenDigest == Self.tokenDigest(rule: rule),
                  provenance.activityName
                    == "evlin.limit.v2.\(provenance.armID.uuidString.lowercased())",
                  let timezone = TimeZone(identifier: provenance.timezone)
            else {
                return .rejected(reason: "stale_provenance")
            }

            let usageDate = Self.usageDate(now, timezone: timezone)
            if usageDate == provenance.usageDate {
                return .unchanged(usageDate: usageDate)
            }
            guard usageDate > provenance.usageDate else {
                return .rejected(reason: "backward_usage_date")
            }

            var slot = matchedSlot
            slot.armProvenance = AppLimitArmProvenance(
                ruleID: provenance.ruleID,
                ruleRevision: provenance.ruleRevision,
                childDeviceID: provenance.childDeviceID,
                usageDate: usageDate,
                timezone: provenance.timezone,
                scheduleWindow: provenance.scheduleWindow,
                tokenDigest: provenance.tokenDigest,
                budgetMinutes: provenance.budgetMinutes,
                startedAt: now,
                baseAcceptedMinutes: 0,
                lastRawThresholdMinutes: 0,
                ignoredWhilePausedMinutes: 0,
                pausedAt: provenance.pausedAt,
                monitorStartPending: false,
                predecessorIgnoredWhilePausedMinutes: provenance.ignoredWhilePausedMinutes,
                physicalEventsConsumedAt: nil,
                physicalReplacementAttemptCount: nil,
                activityName: provenance.activityName,
                armID: provenance.armID
            )
            slot.authoritativeUsedTodayMinutes = 0
            state.slots[slot.ruleID] = slot
            return .rolledOver(from: provenance.usageDate, to: usageDate)
        }
    }

    private static func isSchedulingView(
        _ rule: AppLimitRule,
        of canonical: AppLimitRule
    ) -> Bool {
        rule.id == canonical.id
            && rule.appTokens == canonical.appTokens
            && rule.bundleID == canonical.bundleID
            && rule.displayName == canonical.displayName
            && rule.window == canonical.window
            && rule.effectiveFrom == canonical.effectiveFrom
            && rule.expiresAt == canonical.expiresAt
            && rule.budgetMinutes > 0
            && rule.budgetMinutes <= canonical.budgetMinutes
    }

    private static func timezone(for window: AppLimitWindow) -> TimeZone {
        window.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private static func activityName(armID: UUID) -> String {
        "evlin.limit.v2.\(armID.uuidString.lowercased())"
    }

    private static func usageDate(_ date: Date, timezone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timezone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
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
