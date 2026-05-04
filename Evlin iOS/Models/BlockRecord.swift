import Foundation

/// A block on a single app (by bundleID).
/// Unique per bundleID. Permanent (expiresAt=nil) blocks lift only via
/// explicit `unblock` / `unblockAll`. Timed blocks (expiresAt set) get a
/// DeviceActivityMonitor schedule that fires intervalDidEnd at expiry,
/// at which point the extension removes the record and recomputes the
/// effective shield/block state.
/// See spec §3.1.
struct BlockRecord: Codable, Sendable {
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
}
