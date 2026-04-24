import Foundation

/// A permanent block on a single app (by bundleID).
/// Unique per bundleID. No expiresAt — blocks only lift via `unblock` / `unblockAll`.
/// See spec §3.1.
struct BlockRecord: Codable, Sendable {
    let bundleID: String      // unique key in ActiveLockStore
    let displayName: String
    let blockedAt: Date
    let lastCommandID: UUID
    let originalRequest: String
    let targetChildID: UUID
}
