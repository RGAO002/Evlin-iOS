import Foundation

/// One-shot migration from legacy `evlin.activeLocks` to new shield/block stores.
/// Pre-launch app: safe to discard legacy data if the old schema can't be reconstructed
/// (the old ActiveLock shape didn't carry tier/targetKey in a way that maps cleanly
/// to the new ShieldRecord recordKey scheme).
enum ActiveLockMigration {
    static let legacyKey = "evlin.activeLocks"
    static let shieldsKey = "evlin.shieldRecords"
    static let blocksKey = "evlin.blockRecords"

    static func runIfNeeded() {
        let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
        guard let legacyData = defaults?.data(forKey: legacyKey) else { return }

        // If new keys are already populated, we've migrated. Skip.
        if defaults?.data(forKey: shieldsKey) != nil {
            // Clean up residual legacy key as defensive hygiene.
            defaults?.removeObject(forKey: legacyKey)
            return
        }

        // Drop legacy; pre-launch so no real user state is lost.
        _ = legacyData  // referenced to silence unused-var warnings
        defaults?.removeObject(forKey: legacyKey)

        // Initialize empty new keys so subsequent reads succeed.
        if let emptyShields = try? PropertyListEncoder().encode([String: String]()) {
            defaults?.set(emptyShields, forKey: shieldsKey)
        }
        if let emptyBlocks = try? PropertyListEncoder().encode([String: String]()) {
            defaults?.set(emptyBlocks, forKey: blocksKey)
        }
    }
}
