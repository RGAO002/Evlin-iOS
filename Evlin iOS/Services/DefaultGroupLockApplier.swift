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
        webDomainTokens: Set<WebDomainToken> = [],
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
            webDomainTokens: webDomainTokens,
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "default lock group",
            targetChildID: childID
        )
    }

    /// Reconcile only the parent's manual stake in the default selected-set
    /// record. Automatic sources remain intact, so a master unlock cannot
    /// accidentally bypass task, pool, device-limit, or per-app enforcement.
    static func reconcilingManualLock(
        in records: [String: ShieldRecord],
        selection: FamilyActivitySelection,
        childID: UUID,
        commandID: UUID,
        locked: Bool
    ) -> [String: ShieldRecord] {
        reconcilingSource(
            .manual,
            in: records,
            selection: selection,
            childID: childID,
            commandID: commandID,
            locked: locked
        )
    }

    static func reconcilingTimedParentLock(
        in records: [String: ShieldRecord],
        selection: FamilyActivitySelection,
        childID: UUID,
        commandID: UUID,
        locked: Bool
    ) -> [String: ShieldRecord] {
        reconcilingSource(
            .parentTimedLock,
            in: records,
            selection: selection,
            childID: childID,
            commandID: commandID,
            locked: locked
        )
    }

    private static func reconcilingSource(
        _ source: ShieldSource,
        in records: [String: ShieldRecord],
        selection: FamilyActivitySelection,
        childID: UUID,
        commandID: UUID,
        locked: Bool
    ) -> [String: ShieldRecord] {
        let key = DefaultLockGroup.shared.recordKey
        guard locked else {
            return ShieldSourceLogic.removingSource(source, fromRecordKey: key, in: records)
        }

        var result = records
        if var existing = result[key] {
            existing.appTokens = selection.applicationTokens
            existing.categoryTokens = selection.categoryTokens
            existing.webDomainTokens = selection.webDomainTokens
            existing.sources.insert(source)
            existing.lastCommandID = commandID
            existing.displayName = DefaultLockGroup.shared.name
            existing.targetChildID = childID
            result[key] = existing
        } else {
            var created = makeRecord(
                appTokens: selection.applicationTokens,
                categoryTokens: selection.categoryTokens,
                webDomainTokens: selection.webDomainTokens,
                childID: childID
            )
            created.lastCommandID = commandID
            created.sources = [source]
            result[key] = created
        }
        return result
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

    static func setManualLock(
        _ locked: Bool,
        selection: FamilyActivitySelection = DefaultLockGroupStore.load(),
        childID: UUID,
        commandID: UUID
    ) async -> Bool {
        await ActiveLockStore.shared.setDefaultGroupManualLock(
            locked,
            selection: selection,
            childID: childID,
            commandID: commandID
        )
    }

    static func setTimedParentLock(
        _ locked: Bool,
        selection: FamilyActivitySelection = DefaultLockGroupStore.load(),
        childID: UUID,
        commandID: UUID
    ) async -> Bool {
        await ActiveLockStore.shared.setDefaultGroupTimedParentLock(
            locked,
            selection: selection,
            childID: childID,
            commandID: commandID
        )
    }

    /// Remove the default lock group's saved-list shield.
    static func clear() async {
        await ActiveLockStore.shared.removeShield(recordKey: DefaultLockGroup.shared.recordKey)
    }
}
