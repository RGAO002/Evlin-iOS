import Foundation
import FamilyControls
import ManagedSettings

struct ActiveLock: Codable, Sendable, Identifiable {
    let id: UUID                   // same as commandID
    let tier: LockTier
    let blockedBundleIDs: Set<String>
    let shieldAppTokens: Set<ApplicationToken>
    let shieldCategoryTokens: Set<ActivityCategoryToken>
    let shieldsAllApplications: Bool?
    let issuedAt: Date
    let expiresAt: Date?
    let originalRequest: String
    let displayName: String
}
