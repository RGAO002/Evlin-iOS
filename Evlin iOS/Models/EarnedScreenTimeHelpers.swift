import Foundation

// MARK: - EarnedAppOptions
//
// Pure logic for computing the selectable limit-picker options for a single
// app inside DeviceAppsSheet. No SwiftUI, no network, no side effects —
// unit-testable without a device.
//
// Priority:
//   1. If the backend returned `allowed_app_options` in the policy, use those
//      filtered to ≤ deviceCap.
//   2. Otherwise fall back to DeviceAppsMockData.limitOptionsBase filtered to
//      ≤ deviceCap.
// In DEBUG builds, inject the 1-minute option at the front (never above cap).
// An existing rule whose budget > the (newly-lowered) cap is surfaced in
// `overCapExisting` but is NOT added to `selectable`.

enum EarnedAppOptions {

    struct Result: Equatable {
        /// Options the parent may select for a new or changed limit.
        let selectable: [Int]
        /// Existing budgets that exceed the current cap (app keeps running at
        /// its old value "until tomorrow" — shown as a read-only chip, not a
        /// selectable option).
        let overCapExisting: [Int]
    }

    /// Compute the selectable options and over-cap flags.
    ///
    /// - Parameters:
    ///   - policyOptions:  The `allowed_app_options` array from the backend
    ///                     policy, or `nil` when offline/unconfigured.
    ///   - deviceCap:      The device's current daily cap in minutes.
    ///   - existingBudget: The app's current rule budget (if it has one), or
    ///                     `nil` for a new app with no rule yet.
    ///   - isDebug:        Pass `true` in DEBUG builds to inject the 1-minute
    ///                     test option. Production callers pass `false`.
    static func compute(
        policyOptions: [Int]?,
        deviceCap: Int,
        existingBudget: Int?,
        isDebug: Bool
    ) -> Result {
        // Base set: policy-provided or offline fallback.
        let base: [Int]
        if let policy = policyOptions {
            base = policy
        } else {
            // DeviceAppsMockData.limitOptionsBase is the offline fallback
            // (release values only — the DEBUG 1-minute is injected below).
            base = DeviceAppsMockData.limitOptionsBase
        }

        // Filter to ≤ cap and deduplicate while preserving order.
        var selectable = base.filter { $0 <= deviceCap }

        // DEBUG: inject 1-minute at front (never if cap < 1).
        if isDebug && deviceCap >= 1 && !selectable.contains(1) {
            selectable.insert(1, at: 0)
        }

        // Over-cap existing budget: kept in the chip row but not selectable.
        var overCap: [Int] = []
        if let existing = existingBudget, existing > deviceCap {
            overCap = [existing]
            // Ensure it is NOT in selectable (it won't be because we filtered ≤ cap,
            // but be explicit).
            selectable = selectable.filter { $0 != existing }
        }

        return Result(selectable: selectable, overCapExisting: overCap)
    }

    /// Default pill value for a new app (no existing rule): min(60, deviceCap).
    static func defaultPill(deviceCap: Int) -> Int {
        min(60, deviceCap)
    }
}

// MARK: - EarnedLimitRange
//
// The one definition of what a daily limit may be, for every editor that sets
// one: the pool, a device's daily total, and the Daily Screen Time rule.
//
// It mirrors the backend's `_POOL_OPTIONS` (`range(15, 181, 5)`), which is the
// authority — a value outside it is rejected there. Kept as a named range
// rather than repeated literals because it had been written out separately in
// each editor, and a ceiling raised for a test in one place then shows up in a
// control the parent uses.

enum EarnedLimitRange {
    static let minimumMinutes = 15
    static let maximumMinutes = 180
    static let stepMinutes = 5

    /// The highest value an editor may offer, given a pool that may itself be
    /// out of range. Bounded by BOTH: a pool set beyond the product maximum
    /// (only reachable outside the parent UI) must not widen a slider.
    static func ceiling(poolMinutes: Int) -> Int {
        Swift.min(poolMinutes, maximumMinutes)
    }

    /// `value` snapped to the step and clamped into `minimum...ceiling`, with
    /// the floor collapsing when the ceiling is below it. `Slider` traps on an
    /// out-of-range binding, so every editor start value goes through here.
    static func clamped(_ value: Int, poolMinutes: Int) -> Int {
        let top = ceiling(poolMinutes: poolMinutes)
        let bottom = Swift.min(minimumMinutes, top)
        let snapped = Int((Double(value) / Double(stepMinutes)).rounded()) * stepMinutes
        return Swift.min(Swift.max(snapped, bottom), top)
    }
}

// MARK: - EarnedCapOptions
//
// Pure logic for computing device-cap picker options.
// Backend `allowed_cap_options` filtered to ≤ pool.
// Returns empty when no policy options are provided (the UI hides the picker).

enum EarnedCapOptions {
    /// Compute the selectable device-cap options.
    ///
    /// - Parameters:
    ///   - policyCapOptions: `allowed_cap_options` from the backend policy for
    ///                       this device, or `nil` when not yet loaded.
    ///   - poolMinutes:      The family's daily earned-time pool. Cap may not
    ///                       exceed the pool.
    static func compute(policyCapOptions: [Int]?, poolMinutes: Int) -> [Int] {
        guard let options = policyCapOptions else { return [] }
        return options.filter { $0 <= poolMinutes }
    }
}

// MARK: - EarnedCascadeDecision
//
// Pure logic for deciding whether lowering the pool or cap requires a cascade-
// confirm sheet (because existing devices/apps would be affected).
//
// The backend's dry-run endpoint returns a similar payload; this helper mirrors
// that decision locally so the UI can present the confirm sheet and the logic
// is unit-testable without a live network call.

enum EarnedCascadeDecision {

    enum DefaultAction: Equatable {
        case applyTomorrow
        case applyNow
    }

    struct AffectedDevice: Equatable {
        let deviceID: String
        let name: String
        let currentCapMinutes: Int
        let newCapMinutes: Int

        var description: String {
            "\(name) \(currentCapMinutes)m → \(newCapMinutes)m tomorrow"
        }
    }

    struct AffectedApp: Equatable {
        let bundleID: String
        let name: String
        let currentBudgetMinutes: Int
        let newBudgetMinutes: Int

        var description: String {
            "\(name) \(currentBudgetMinutes)m → \(newBudgetMinutes)m tomorrow"
        }
    }

    struct Result: Equatable {
        let needsConfirmation: Bool
        let affectedDevices: [AffectedDevice]
        let affectedApps: [AffectedApp]
        /// The UI pre-selects this action in the confirm sheet.
        let defaultAction: DefaultAction
    }

    /// Decide whether to show a cascade-confirm sheet.
    ///
    /// Triggers confirmation when:
    ///   - `newPoolMinutes` < `currentPoolMinutes` AND there are affected devices
    ///   - OR there are affected apps (cap was lowered below their existing rules)
    ///
    /// The affected lists are provided by the caller (either from a backend dry-run
    /// response or computed locally). The default action is always `.applyTomorrow`
    /// when confirmation is needed.
    static func decide(
        newPoolMinutes: Int,
        currentPoolMinutes: Int,
        affectedDevices: [AffectedDevice],
        affectedApps: [AffectedApp]
    ) -> Result {
        let hasAffected = !affectedDevices.isEmpty || !affectedApps.isEmpty
        let isReducing = newPoolMinutes < currentPoolMinutes

        let needsConfirm = hasAffected && (isReducing || !affectedApps.isEmpty)

        return Result(
            needsConfirmation: needsConfirm,
            affectedDevices: affectedDevices,
            affectedApps: affectedApps,
            defaultAction: needsConfirm ? .applyTomorrow : .applyNow
        )
    }
}
