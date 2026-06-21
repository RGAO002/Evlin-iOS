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
            source: .limit
        )
        var out = shields
        out[key] = record
        return out
    }

    /// Daily-reset strip: drop EVERY `source == .limit` record, leaving every
    /// `source == .manual` (parent/reflection) record untouched. Pure.
    static func strippingLimitShields(
        from shields: [String: ShieldRecord]
    ) -> [String: ShieldRecord] {
        shields.filter { $0.value.source != .limit }
    }
}
