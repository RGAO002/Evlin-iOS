import Foundation
import FamilyControls

/// Pure, side-effect-free transforms over the `[String: ShieldRecord]` shields
/// dict for the per-app time-limit subsystem (P7). The DeviceActivity extension
/// callbacks (`eventDidReachThreshold` / `intervalDidStart`) take framework types
/// that can't be invoked in a unit test, so the decision logic lives here as
/// plain dictionary→dictionary functions and the extension just wires them to
/// App Group I/O and the `ManagedSettingsStore` recompute.
///
/// Membership: this file is a member of BOTH the main app target (so the test
/// target can `@testable import Evlin_iOS` it) AND the `EvlinDeviceActivityMonitor`
/// extension target (so `DeviceActivityMonitorExtension` can call it). Keep it
/// free of any app-only / extension-only API.
enum LimitShieldLogic {

    /// Canonical `targetKey` for a limit rule's app: the lowercased `bundleID`.
    /// MUST match `ActiveLockStore.removeLimitShields` (which compares against
    /// `bundleID.trimmed.lowercased()`) and the `.exactApp` recordKey scheme.
    static func targetKey(for rule: AppLimitRule) -> String {
        rule.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Stable record key for a limit shield: the `exactApp:<bundleID>` form.
    /// `ActiveLockStore.removeLimitShields` matches on `targetKey == lowercased
    /// bundleID` (the exactApp recordKey scheme), so we reuse it here for a single
    /// consistent identity the recompute, P6 clear path, and merge all agree on.
    static func recordKey(for rule: AppLimitRule) -> String {
        ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: targetKey(for: rule))
    }

    /// Auto-shield the app for `rule` by inserting/merging a `source == .limit`
    /// `ShieldRecord` into `shields`, keyed by `recordKey(for:)`. The record is
    /// deliberately shaped to be matchable by `ActiveLockStore.removeLimitShields`
    /// (P6's clear path): `source == .limit`, `appTokens` = the rule's tokens, and
    /// `targetKey` = the lowercased `bundleID`. Pure: returns a new dict; never
    /// touches UserDefaults or the ManagedSettingsStore.
    ///
    /// Merge semantics: a re-fire for the same rule overwrites its own prior
    /// limit record (same `recordKey`), so repeated threshold hits stay idempotent
    /// and never accrete duplicates.
    static func applyingLimit(
        to shields: [String: ShieldRecord],
        rule: AppLimitRule,
        now: Date = Date()
    ) -> [String: ShieldRecord] {
        let key = recordKey(for: rule)
        let record = ShieldRecord(
            recordKey: key,
            tier: .exactApp,
            targetKey: targetKey(for: rule),
            displayName: rule.displayName,
            lastCommandID: rule.id,
            appTokens: rule.appTokens,
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: now,
            // Permanent within the day: the daily-reset branch (intervalDidStart
            // on the window) clears it, NOT a timed expiry. A non-nil expiresAt
            // would risk the main app's sweepExpired racing the reset.
            expiresAt: nil,
            originalRequest: "app limit reached: \(rule.displayName)",
            targetChildID: UUID(),
            sources: [.limit]
        )
        var out = shields
        out[key] = record
        return out
    }

    /// Daily-reset strip: remove the `.limit` source from EVERY record that carries
    /// it, then delete the record only when its sources set becomes empty.
    ///
    /// B1 carry fix: the prior implementation used a blanket `filter { !sources.contains(.limit) }`
    /// which deleted the WHOLE record for mixed-source records like `{.limit, .earnedTime}` or
    /// `{.limit, .manual}`. The correct behaviour is source-aware removal via
    /// `ShieldSourceLogic.strippingSource` — records whose non-limit sources survive are kept.
    /// Pure.
    static func strippingLimitShields(
        from shields: [String: ShieldRecord]
    ) -> [String: ShieldRecord] {
        ShieldSourceLogic.strippingSource(.limit, from: shields)
    }

    // MARK: - "Limit reached" notification copy

    /// Pure builder for the local "time's up" notification the DeviceActivity
    /// extension posts (on the kid's device) the moment a per-app budget is hit,
    /// just before it applies the shield. Kept here (no `UserNotifications`
    /// import) so the copy is unit-testable without the extension; the extension
    /// wraps the returned `(title, body)` in a `UNMutableNotificationContent`.
    ///
    /// - `appName`: the rule's `displayName`. A nil/blank name falls back to
    ///   "this app".
    /// - `minutes`: the rule's `budgetMinutes`. When nil (or non-positive) the
    ///   body omits the "N-min limit" clause and reads "today's limit" instead,
    ///   so we never render "0-min" or a dangling number.
    static func limitReachedNotification(
        appName: String?,
        minutes: Int?
    ) -> (title: String, body: String) {
        let trimmed = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmed?.isEmpty == false) ? trimmed! : "this app"
        let title = "Time's up on \(name)"
        let limitClause: String
        if let minutes, minutes > 0 {
            limitClause = "today's \(minutes)-min limit"
        } else {
            limitClause = "today's limit"
        }
        let body = "You've reached \(limitClause). \(name) unlocks tomorrow."
        return (title, body)
    }
}
