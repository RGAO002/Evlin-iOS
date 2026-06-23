import Foundation

/// Stable identity for the onboarding "default lock group" — the app/category
/// set a parent picks during onboarding and locks as a single `.savedList`
/// shield.
///
/// ## B6: backend-id canonicalisation
/// Once the backend `ChildCatalogList.id` is known (stored in
/// `EarnedTimeStore.shared.lockedSetID`) it becomes the canonical `id` so that
/// manual green-button locks and backend-commanded (earned-time) locks resolve
/// to the **same** `recordKey`. Before the backend id is synced the locally-
/// minted UUID (`evlin.defaultGroupID`) is used as a pre-sync fallback — this
/// preserves pre-B6 behaviour and lets the app function during onboarding
/// before the first backend sync completes.
final class DefaultLockGroup: @unchecked Sendable {
    static let shared = DefaultLockGroup()

    /// Shared with the DeviceActivityMonitor extension — must match the suite
    /// `LocalAliasStore` opens (see `LocalAliasStore.swift`).
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let idKey = "evlin.defaultGroupID"

    /// The canonical id for this lock group.
    ///
    /// Returns `EarnedTimeStore.shared.lockedSetID` once the backend id is
    /// known (B6). Falls back to the locally-minted UUID (minted once, persisted
    /// in the App Group) until the first backend sync completes.
    var id: String {
        // B6: prefer the backend ChildCatalogList.id when available.
        if let backendID = EarnedTimeStore.shared.lockedSetID, !backendID.isEmpty {
            return backendID
        }
        // Pre-sync fallback: mint / reuse a local UUID.
        return localUUID
    }

    /// The pre-sync local UUID. Minted once on first access and persisted so
    /// every call (within or across launches) returns the same value.
    /// Used as the `fromLocalID` argument when triggering the re-key migration.
    var localUUID: String {
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
