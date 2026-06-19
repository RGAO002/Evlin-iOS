import Foundation

/// Stable local identity for the onboarding "default lock group" — the
/// app/category set a parent picks during onboarding and locks as a single
/// `.savedList` shield.
///
/// There is no backend list id for this set, so we mint a `UUID` once and
/// persist it in the shared App Group `UserDefaults` (same suite as
/// `LocalAliasStore`). That id becomes the `targetKey` for the saved-list
/// `ShieldRecord`, giving us a `recordKey` that is identical across calls and
/// app launches.
final class DefaultLockGroup: @unchecked Sendable {
    static let shared = DefaultLockGroup()

    /// Shared with the DeviceActivityMonitor extension — must match the suite
    /// `LocalAliasStore` opens (see `LocalAliasStore.swift`).
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let idKey = "evlin.defaultGroupID"

    /// Stable local id. Minted once on first access and persisted, so every
    /// call (within or across launches) returns the same value.
    var id: String {
        if let existing = defaults?.string(forKey: idKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        defaults?.set(minted, forKey: idKey)
        return minted
    }

    /// Display-only name for the default lock group.
    var name: String { "Locked set" }

    /// Saved-list shield record key for this group. Built via the canonical
    /// helper so the `"savedList:"` convention lives in exactly one place.
    var recordKey: String {
        ShieldRecord.makeRecordKey(tier: .savedList, targetKey: id)
    }
}
