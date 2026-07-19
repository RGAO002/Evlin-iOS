import Foundation

/// Compatibility view over the active rows in `AppLimitEpochStore`.
///
/// Token-aware ingress writes version slots directly through the epoch store.
/// These legacy methods can update only token-zero compatibility slots, so an
/// unversioned caller cannot overwrite or clear a durable token authority.
nonisolated final class AppLimitRuleStore: @unchecked Sendable {
    static let shared = AppLimitRuleStore()
    static let legacyRulesKey = AppLimitEpochStore.legacyRulesKey

    private let epochStore: AppLimitEpochStore
    private let source: AppLimitCommandSource
    private let expectedOwnerProvider: @Sendable () -> UUID?

    init(
        epochStore: AppLimitEpochStore = .shared,
        source: AppLimitCommandSource = .poll,
        expectedOwnerProvider: @escaping @Sendable () -> UUID? = MeteringOwnerMirror.current
    ) {
        self.epochStore = epochStore
        self.source = source
        self.expectedOwnerProvider = expectedOwnerProvider
    }

    nonisolated deinit {}

    func upsert(_ rule: AppLimitRule) {
        try? epochStore.transaction(
            source: source,
            expectedOwner: expectedOwnerProvider()
        ) { state in
            if let current = state.slots[rule.id], current.latestOrderingToken > 0 {
                return
            }
            state.slots[rule.id] = AppLimitVersionSlot(
                ruleID: rule.id,
                latestOrderingToken: 0,
                latestKind: .set,
                latestPayloadDigest: "legacy-rule:\(AppLimitEpochStore.digest(of: rule))",
                activeRule: rule,
                clearTombstone: nil,
                pendingOwnerWork: nil,
                appliedReceipt: nil
            )
        }
    }

    func remove(ruleId: UUID) {
        try? epochStore.transaction(
            source: source,
            expectedOwner: expectedOwnerProvider()
        ) { state in
            guard let current = state.slots[ruleId],
                  current.latestOrderingToken == 0,
                  current.activeRule != nil
            else { return }
            let digest = "legacy-clear:\(current.latestPayloadDigest)"
            state.slots[ruleId] = AppLimitVersionSlot(
                ruleID: ruleId,
                latestOrderingToken: current.latestOrderingToken,
                latestKind: .clear,
                latestPayloadDigest: digest,
                activeRule: nil,
                clearTombstone: AppLimitClearTombstone(
                    ruleID: ruleId,
                    orderingToken: current.latestOrderingToken,
                    payloadDigest: digest,
                    source: source,
                    clearedAt: Date()
                ),
                pendingOwnerWork: nil,
                appliedReceipt: nil
            )
        }
    }

    func all() -> [AppLimitRule] {
        guard let state = try? epochStore.read() else { return [] }
        return state.slots.values.compactMap(\.activeRule)
    }

    func rule(forID id: UUID) -> AppLimitRule? {
        try? epochStore.read().slots[id]?.activeRule
    }

    func removeAll() {
        try? epochStore.reset()
    }
}
