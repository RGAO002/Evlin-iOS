import Foundation

/// Projects the durable lock records into the effective enforcement set while
/// a parent unlock override is active. The policy is pure: it never changes
/// the durable records, their expiry schedules, or metering state.
nonisolated enum ParentUnlockOverridePolicy {
    struct Projection: Equatable, Sendable {
        let shields: [String: ShieldRecord]
        let blocks: [String: BlockRecord]
    }

    static func project(
        shields: [String: ShieldRecord],
        blocks: [String: BlockRecord],
        snapshot: ParentUnlockOverrideSnapshot?,
        reflectionActive: Bool
    ) -> Projection {
        guard let snapshot,
              snapshot.status == .active,
              !snapshot.envelope.cancelled
        else {
            return Projection(shields: shields, blocks: blocks)
        }

        let suppressedSources = shieldSources(for: snapshot.scopes)
        var projectedShields: [String: ShieldRecord] = [:]
        projectedShields.reserveCapacity(shields.count)

        for (key, record) in shields {
            if reflectionActive && isReflectionRecord(record) {
                projectedShields[key] = record
                continue
            }

            var projected = record
            projected.sources.subtract(suppressedSources)
            if !projected.sources.isEmpty {
                projectedShields[key] = projected
            }
        }

        let projectedBlocks = snapshot.scopes.contains(.manual) ? [:] : blocks
        return Projection(shields: projectedShields, blocks: projectedBlocks)
    }

    private static func shieldSources(
        for scopes: Set<ParentUnlockOverrideScope>
    ) -> Set<ShieldSource> {
        var sources: Set<ShieldSource> = []
        if scopes.contains(.manual) {
            sources.insert(.manual)
        }
        if scopes.contains(.earnedTime) {
            sources.insert(.earnedTime)
        }
        if scopes.contains(.taskPause) {
            sources.insert(.taskPause)
        }
        if scopes.contains(.deviceLimit) || scopes.contains(.perAppLimit) {
            sources.insert(.limit)
        }
        return sources
    }

    private static func isReflectionRecord(_ record: ShieldRecord) -> Bool {
        record.recordKey.hasPrefix("all:reflection:")
    }
}
