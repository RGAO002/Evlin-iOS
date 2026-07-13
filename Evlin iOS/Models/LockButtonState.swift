import Foundation

/// B8 — pure value that drives the ProfileView green/red lock button.
///
/// Derived from `DeviceLockStateResponse.covering_sources`, or from
/// `EarnedSummaryDTO.state` for multi-device child-level display.
///
/// Three states:
/// - `.pending`           — no acked state yet (sources = nil); show spinner/neutral
/// - `.clear`             — selected set is unlocked (sources = [])
/// - `.shielded(who:)`    — locked; `who` lists which sources are active
enum LockButtonState: Equatable {
    case pending
    case clear
    case shielded(who: [String])

    // MARK: - Factory from lock-state acked fields

    /// Derive button state from the acked `covering_sources` array.
    ///
    /// Rules (in priority order):
    /// 1. If `sources` is nil    → `.pending` (no acked state yet)
    /// 2. If `sources` is empty  → `.clear`
    /// 3. Otherwise              → `.shielded(who: sources)`
    ///
    /// `exhausted` is intentionally not enough to show a red Unlock button.
    /// The button is an App Controls lock toggle, so red means the selected set
    /// is actually covered by a shield source.
    static func from(coveringSources: [String]?, exhausted: Bool?) -> LockButtonState {
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

/// Manual selected-set state across every device linked to one child profile.
nonisolated enum ManualLockAggregateState: Equatable {
    case unlocked
    case locked
    case mixed
    case pending

    static func reduce(
        expectedDeviceCount: Int,
        coveringSources: [[String]?]
    ) -> ManualLockAggregateState {
        guard expectedDeviceCount > 0,
              coveringSources.count == expectedDeviceCount,
              coveringSources.allSatisfy({ $0 != nil })
        else { return .pending }

        let manualByDevice = coveringSources.map { isManualLocked(coveringSources: $0) == true }
        if manualByDevice.allSatisfy({ $0 }) { return .locked }
        if manualByDevice.allSatisfy({ !$0 }) { return .unlocked }
        return .mixed
    }

    static func isManualLocked(coveringSources: [String]?) -> Bool? {
        guard let coveringSources else { return nil }
        return coveringSources.contains(where: isManualSource)
    }

    private static func isManualSource(_ source: String) -> Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "manual"
    }
}

nonisolated struct ManualLockButtonPresentation: Equatable {
    enum Tone: Equatable {
        case lock
        case unlock
        case updating
    }

    let title: String
    let systemImage: String
    let tone: Tone
    let allowsTap: Bool

    static func from(
        state: ManualLockAggregateState,
        childName: String
    ) -> ManualLockButtonPresentation {
        switch state {
        case .unlocked:
            return ManualLockButtonPresentation(
                title: "Lock \(childName)'s devices",
                systemImage: "lock",
                tone: .lock,
                allowsTap: true
            )
        case .locked:
            return ManualLockButtonPresentation(
                title: "Unlock \(childName)'s devices",
                systemImage: "lock.open",
                tone: .unlock,
                allowsTap: true
            )
        case .mixed, .pending:
            return ManualLockButtonPresentation(
                title: "Updating \(childName)'s devices",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .updating,
                allowsTap: false
            )
        }
    }
}
