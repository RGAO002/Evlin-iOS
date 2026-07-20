import CryptoKit
import Foundation

nonisolated final class AppLimitProvenanceStore: @unchecked Sendable {
    struct Resolution: Equatable, Sendable {
        let provenance: AppLimitArmProvenance
        let replaced: Bool
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
            if var existing = slot.armProvenance,
               existing.replacementKey == key {
                if acceptedBase > existing.baseAcceptedMinutes {
                    existing.baseAcceptedMinutes = acceptedBase
                    slot.armProvenance = existing
                    state.slots[canonicalRule.id] = slot
                }
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
