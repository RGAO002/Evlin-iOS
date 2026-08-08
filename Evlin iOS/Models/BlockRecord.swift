import Foundation
import FamilyControls
import ManagedSettings

/// A block on a single app (by bundleID).
/// Unique per bundleID. Permanent (expiresAt=nil) blocks lift only via
/// explicit `unblock` / `unblockAll`. Timed blocks (expiresAt set) get a
/// DeviceActivityMonitor schedule that fires intervalDidEnd at expiry,
/// at which point the extension removes the record and recomputes the
/// effective shield/block state.
/// See spec §3.1.
struct BlockRecord: Codable, Sendable, Equatable {
    let bundleID: String      // unique key in ActiveLockStore
    let displayName: String
    let blockedAt: Date
    let lastCommandID: UUID
    let originalRequest: String
    let targetChildID: UUID
    /// Nil for permanent block (default, historical behavior). Non-nil
    /// means a timed block — DeviceActivityMonitor will fire at this
    /// instant and the extension will remove this record.
    var expiresAt: Date? = nil
    /// Opaque per-device token, when one is known (catalog-verified command or
    /// alias store). Purely additive: records without one keep the bundle-id
    /// behavior, and no block is ever refused for lacking a token. Carried so
    /// `blockedApplications` can hold a token-backed `Application` — the form
    /// enforcement verifiably honors — instead of relying solely on the
    /// bundle-id form (under suspicion since 2026-08-06, unresolved).
    var appToken: ApplicationToken? = nil
}
