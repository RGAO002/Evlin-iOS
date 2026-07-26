import CryptoKit
import Foundation

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
                return Resolution(provenance: existing, replaced: false)
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

            current.startedAt = startedAt
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
