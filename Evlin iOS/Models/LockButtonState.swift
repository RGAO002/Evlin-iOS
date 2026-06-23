import Foundation

/// B8 — pure value that drives the ProfileView green/red lock button.
///
/// Derived from `DeviceLockStateResponse.covering_sources` + `exhausted`, or
/// from `EarnedSummaryDTO.state` for multi-device child-level display.
///
/// Three states:
/// - `.pending`           — no acked state yet (sources = nil); show spinner/neutral
/// - `.clear`             — selected set is unlocked (sources = [] AND not exhausted)
/// - `.shielded(who:)`    — locked; `who` lists which sources are active
enum LockButtonState: Equatable {
    case pending
    case clear
    case shielded(who: [String])

    // MARK: - Factory from lock-state acked fields

    /// Derive button state from the acked `covering_sources` array and the
    /// `exhausted` flag (both from `DeviceLockStateResponse`).
    ///
    /// Rules (in priority order):
    /// 1. If `exhausted == true` → `.shielded(who: sources ?? [])` (earned time ran out)
    /// 2. If `sources` is nil    → `.pending` (no acked state yet)
    /// 3. If `sources` is empty  → `.clear`
    /// 4. Otherwise              → `.shielded(who: sources)`
    static func from(coveringSources: [String]?, exhausted: Bool?) -> LockButtonState {
        if exhausted == true {
            return .shielded(who: coveringSources ?? [])
        }
        guard let sources = coveringSources else { return .pending }
        return sources.isEmpty ? .clear : .shielded(who: sources)
    }

    // MARK: - Factory from earned-summary state string

    /// Derive button state from `EarnedSummaryDTO.state`.
    /// Values: "ok" → clear; "exhausted" → shielded; nil → pending.
    static func from(summaryState: String?) -> LockButtonState {
        switch summaryState {
        case "exhausted": return .shielded(who: [])
        case "ok":        return .clear
        default:          return .pending
        }
    }

    // MARK: - Convenience

    /// True when the selected set is actively shielded (button should be red).
    var isShielded: Bool {
        if case .shielded = self { return true }
        return false
    }

    /// True when we have no acked state (button should be neutral / show spinner).
    var isPending: Bool { self == .pending }

    /// True when the selected set is clear (button should be green).
    var isClear: Bool { self == .clear }
}
