import Foundation

nonisolated enum EarnedShieldCAS {
    static func releasingEarnedSource(
        current: ShieldRecord?,
        expectedApplied: ShieldRecord
    ) -> ShieldRecord? {
        guard current == expectedApplied else { return current }
        var released = expectedApplied
        released.sources.remove(.earnedTime)
        return released.sources.isEmpty ? nil : released
    }
}
