import Foundation
import FamilyControls
import ManagedSettings

/// Local applier for the onboarding "default lock group" — the app/category
/// set a parent picks during onboarding and locks as a single `.savedList`
/// shield. There is no backend list id, so the stable identity comes from
/// `DefaultLockGroup.shared` (locally minted, persisted in the App Group).
///
/// `apply` / `clear` go through the PUBLIC `ActiveLockStore` API; `apply` uses
/// `force: true` so re-locking overwrites the existing token sets rather than
/// merging. `makeRecord` is a pure builder so the record shape is unit-testable
/// without an actor or real tokens.
enum DefaultGroupLockApplier {
    static func makeRecord(
        appTokens: Set<ApplicationToken>,
        categoryTokens: Set<ActivityCategoryToken>,
        childID: UUID
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: DefaultLockGroup.shared.recordKey,
            tier: .savedList,
            targetKey: DefaultLockGroup.shared.id,
            displayName: DefaultLockGroup.shared.name,
            lastCommandID: UUID(),
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "default lock group",
            targetChildID: childID
        )
    }

    /// Apply the default lock group. `force: true` overwrites any existing
    /// saved-list record (replaces token sets) + persists + recomputes.
    static func apply(
        appTokens: Set<ApplicationToken>,
        categoryTokens: Set<ActivityCategoryToken>,
        childID: UUID
    ) async {
        let record = makeRecord(appTokens: appTokens, categoryTokens: categoryTokens, childID: childID)
        await ActiveLockStore.shared.addShield(record, force: true)
    }

    /// Remove the default lock group's saved-list shield.
    static func clear() async {
        await ActiveLockStore.shared.removeShield(recordKey: DefaultLockGroup.shared.recordKey)
    }
}
