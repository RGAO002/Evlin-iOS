import Foundation
import FamilyControls
import ManagedSettings

/// Result of addShield. See spec §3.3 and §3.4.
enum AddShieldResult: Codable, Sendable {
    case added
    case upgradedToPermanent(previousExpiry: Date)
    case extendedTimed(newExpiry: Date)
    case noOpShorterThanExisting
    case noOpAlreadyPermanent
    case needsConfirmation(NeedsConfirmationReason)
}

enum NeedsConfirmationReason: Codable, Sendable {
    case downgradePermanentToTimed(existingKey: String, newExpiry: Date)
}

enum AddBlockResult: Codable, Sendable {
    case added
    case alreadyBlocked
}

struct AppQuery: Sendable {
    var bundleID: String?
    var token: ApplicationToken?
    var categoryHint: String?

    init(bundleID: String? = nil, token: ApplicationToken? = nil, categoryHint: String? = nil) {
        self.bundleID = bundleID
        self.token = token
        self.categoryHint = categoryHint
    }
}

/// Snapshot of what's covering an app. See spec §3.5.
/// IMPORTANT: coverage for `savedList` tier can only be determined via token match.
/// If the query has no token (e.g. unblock by bundleID, where we never had a token),
/// savedList coverage is UNKNOWN. `possibleSavedListCoverage` flags this —
/// receipts must treat the target as "may still be covered" rather than asserting
/// "fully unrestricted".
struct EffectiveState: Sendable {
    var isBlocked: Bool
    var shieldsCovering: [ShieldRecord]           // shields we're sure cover
    var possibleSavedListCoverage: Bool           // true if savedList shields exist but query can't verify coverage
    var earliestFullyUnrestricted: Date?          // nil if permanent, blocked, or possibleSavedListCoverage=true

    /// Compatibility alias — some callers (ActionExecutor) still use the older name.
    var stillCovered: [ShieldRecord] { shieldsCovering }
    /// Alias for callers that want to know "is this app still under any coverage after the mutation".
    var blockedAfter: Bool { isBlocked }
}

/// Returned by removeShield — tells caller what's still covering the target (for receipt).
struct RemovedShield: Sendable {
    let record: ShieldRecord
    let stillCovered: [ShieldRecord]
    let blockedAfter: Bool
    var possibleSavedListCoverage: Bool = false
}

/// Returned by removeBlock.
struct RemovedBlock: Sendable {
    let record: BlockRecord
    let stillShieldedBy: [ShieldRecord]
    var possibleSavedListCoverage: Bool = false
}
