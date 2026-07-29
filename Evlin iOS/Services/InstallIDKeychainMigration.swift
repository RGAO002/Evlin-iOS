import Foundation

/// Moves `install_id` from UserDefaults into the Keychain, once.
///
/// The two device keys are easy to confuse, so to be explicit: the Keychain
/// mirror in `DeviceIdentity` holds the BACKEND device UUID, while
/// `install_id` is a separate value that has only ever lived in UserDefaults —
/// which means it is lost on reinstall, exactly when pairing v2 wants it as the
/// secondary lookup key. Storing it in the Keychain (its own
/// `keychain-access-groups` entry, which is a different mechanism from the App
/// Group) makes it survive.
///
/// The failure path matters as much as the happy one: a Keychain write can fail
/// transiently (device locked, for instance). Deleting the legacy value anyway
/// would leave the id in neither place and silently mint a new install identity
/// on the next launch, so a failed write keeps the candidate in the legacy slot
/// and the next attempt migrates the SAME value.
nonisolated enum InstallIDKeychainMigration {

    static func migrate(
        legacyValue: String?,
        keychainRead: () -> String?,
        keychainWrite: (String) -> Bool,
        deleteLegacy: () -> Void,
        stashLegacy: (String) -> Void
    ) -> String {
        // Once migrated, the Keychain is the only source of truth — the legacy
        // slot is never consulted again.
        if let existing = keychainRead() {
            return existing
        }

        let candidate: String
        if let legacy = legacyValue, UUID(uuidString: legacy) != nil {
            candidate = legacy
        } else {
            // Absent or malformed: this install has no trustworthy id, so mint
            // one rather than carrying a value of unknown provenance forward.
            candidate = UUID().uuidString
        }

        if keychainWrite(candidate) {
            deleteLegacy()
        } else {
            stashLegacy(candidate)
        }
        return candidate
    }
}
