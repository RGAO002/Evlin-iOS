import Foundation

/// What a limit command means for the shield, decided from the command alone.
nonisolated enum AppLimitEnforcementDecision: Equatable, Sendable {
    /// Today's usage has reached the budget the parent just set — shield now.
    case shield(rule: AppLimitRule, usedTodayMinutes: Int)
    /// The budget is above today's usage (or the limit was removed) — release
    /// the `.limit` source for this rule.
    case release(ruleID: UUID, recordKey: String)
    /// Not enough information to decide. The owner (main app) settles it later.
    case defer_(reason: String)
}

/// Converges the per-app shield from the command that changed the budget.
///
/// ## Why the decision moved here
///
/// The backend used to own it, and got it wrong in a way that was invisible for
/// months (Fred, 2026-07-25: Snapchat used 20 min, budget raised 20 -> 120, no
/// unlock, app stuck shielded). Two defects, one shape:
///
///  1. It only acted on a TRANSITION, and had to guess the prior state to know
///     whether one occurred. Raising a limit goes through the CREATE path, which
///     assumed `was_exhausted = false` — so "was unlocked, is unlocked, nothing
///     to do", while the device sat locked from the rule that was just cleared.
///  2. The two operations that change enforcement — editing the budget and
///     toggling the rule off/on — went down different paths, so a fix to one
///     left the other wrong.
///
/// This type takes the opposite approach, and it is the whole point:
///
/// **Converge, never diff.** Compare today's usage against the budget that is
/// live NOW and state the answer. There is no prior state to get wrong, no
/// create-vs-update distinction, and no direction-specific branch: raising and
/// lowering are the same comparison read the same way. Applying the same
/// command twice is a no-op rather than a double effect.
///
/// It is deliberately PURE so the rule can be tested without a device, a push,
/// or a running app — the previous version could only be verified by locking a
/// real child out of a real app.
nonisolated enum AppLimitEnforcementConverger {

    /// `used >= budget` shields, anything else releases. See the type doc for
    /// why this is a comparison and not a transition.
    ///
    /// Returns `.defer_` — never a guess — when the command carries no
    /// authoritative usage figure. A missing number is not zero: treating it as
    /// zero would release a shield the child has genuinely earned, which is the
    /// one error in this whole area a parent would call a bug and a child would
    /// call a feature.
    /// - Parameter bundleID: the app the command targets, needed only for
    ///   `.clear` (whose envelope carries no rule). The shield's identity is the
    ///   BUNDLE, not the rule: every edit mints a fresh rule id, so a key derived
    ///   from the rule would fail to find the shield the previous rule installed
    ///   — which is the shape of the bug this whole type exists to remove.
    static func decide(
        for envelope: AppLimitCommandEnvelope,
        bundleID: String?
    ) -> AppLimitEnforcementDecision {
        switch envelope.kind {
        case .clear:
            // The limit no longer exists, so its shield must not outlive it —
            // whatever today's usage was. Other sources (manual, earned-time)
            // keep their own hold via `strippingSource`.
            guard let key = Self.recordKey(forBundleID: bundleID) else {
                return .defer_(reason: "clear_without_bundle")
            }
            return .release(ruleID: envelope.ruleID, recordKey: key)
        case .set:
            guard let rule = envelope.rule else {
                return .defer_(reason: "set_without_rule")
            }
            guard let usedToday = envelope.authoritativeUsedTodayMinutes else {
                return .defer_(reason: "no_authoritative_usage")
            }
            guard rule.budgetMinutes > 0 else {
                // A zero/negative budget is not "unlimited"; it is "no time at
                // all", and the child is over it the moment the rule exists.
                return .shield(rule: rule, usedTodayMinutes: max(0, usedToday))
            }
            if max(0, usedToday) >= rule.budgetMinutes {
                return .shield(rule: rule, usedTodayMinutes: max(0, usedToday))
            }
            return .release(
                ruleID: rule.id,
                recordKey: LimitShieldLogic.recordKey(for: rule)
            )
        }
    }

    /// The `.exactApp` record key for a bundle, normalised exactly as
    /// `LimitShieldLogic.targetKey(for:)` does — the two MUST agree or a shield
    /// installed by one path becomes invisible to the other.
    static func recordKey(forBundleID bundleID: String?) -> String? {
        guard let trimmed = bundleID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !trimmed.isEmpty
        else { return nil }
        return ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: trimmed)
    }

    /// The decision applied to a shield map. Pure, so the convergence itself is
    /// testable; the caller owns persistence.
    ///
    /// Release strips only the `.limit` source: a record also held by a manual
    /// lock or the earned-time pool survives with its remaining sources, which
    /// is why this cannot be a plain `removeValue`.
    static func converge(
        _ decision: AppLimitEnforcementDecision,
        into shields: [String: ShieldRecord],
        now: Date
    ) -> [String: ShieldRecord] {
        switch decision {
        case .defer_:
            return shields
        case .shield(let rule, _):
            return LimitShieldLogic.applyingLimit(to: shields, rule: rule, now: now)
        case .release(_, let recordKey):
            guard let existing = shields[recordKey] else { return shields }
            if isLegacyMisclassifiedLimitShield(existing) {
                var out = shields
                out.removeValue(forKey: recordKey)
                return out
            }
            let stripped = ShieldSourceLogic.strippingSource(
                .limit,
                from: [recordKey: existing]
            )
            var out = shields
            if let survivor = stripped[recordKey] {
                out[recordKey] = survivor
            } else {
                out.removeValue(forKey: recordKey)
            }
            return out
        }
    }

    /// One released backend path emitted exhausted app-limit effects as ordinary
    /// exact-app shields, so older builds persisted them as `.manual`. The request
    /// text is the only surviving provenance. Match the complete historical shape
    /// before removing it; a genuine manual or mixed-source record is never healed
    /// by this compatibility path.
    private static func isLegacyMisclassifiedLimitShield(_ record: ShieldRecord) -> Bool {
        record.tier == .exactApp
            && record.sources == [.manual]
            && record.limitRuleIDs.isEmpty
            && record.originalRequest
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("app limit exhausted:")
    }
}
