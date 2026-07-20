import Foundation
import FamilyControls
import ManagedSettings

/// C-3 Task 2 (decision D-2): the Home settings "Lock Selected Apps" /
/// "Unlock Selected Apps" debug buttons keep working, but they route through
/// ONE stable manual `ActiveLockStore` record instead of writing
/// ManagedSettings shield fields directly via `ScreenTimeManager`.
///
/// - Lock upserts the single `savedList:home-settings-selected` record
///   (`.manual` source, permanent until unlocked).
/// - Unlock removes ONLY that record. It never calls `unshieldAll`, never
///   touches automatic-source records (earned/task/reflection/limit), never
///   clears blocks, and changes no override or accounting.
enum HomeSettingsLockRouting {
    /// Stable target key for the one Home settings manual record.
    static let targetKey = "home-settings-selected"

    /// Stable record key — the ONLY record the Home unlock action may remove.
    static let recordKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: targetKey)

    /// Build the Home settings manual record from the current picker
    /// selection. Returns `nil` for a fully empty selection — there is
    /// nothing to lock, and an empty `.savedList` record would be
    /// meaningless (and reaped by the saved-list drop logic anyway).
    static func makeRecord(
        selection: FamilyActivitySelection,
        childID: UUID,
        issuedAt: Date = Date(),
        commandID: UUID = UUID()
    ) -> ShieldRecord? {
        guard !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
        else { return nil }
        return makeRecordUnchecked(
            appTokens: selection.applicationTokens,
            categoryTokens: selection.categoryTokens,
            webDomainTokens: selection.webDomainTokens,
            childID: childID,
            issuedAt: issuedAt,
            commandID: commandID
        )
    }

    /// Record construction without the emptiness guard. Split out so tests —
    /// which cannot fabricate FamilyControls tokens — can still pin the exact
    /// record shape (tier, stable key, `.manual` only, `webOpen == false`).
    static func makeRecordUnchecked(
        appTokens: Set<ApplicationToken>,
        categoryTokens: Set<ActivityCategoryToken>,
        webDomainTokens: Set<WebDomainToken>,
        childID: UUID,
        issuedAt: Date = Date(),
        commandID: UUID = UUID()
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: .savedList,
            targetKey: targetKey,
            displayName: "Home Selected Apps",
            lastCommandID: commandID,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: webDomainTokens,
            appliesToAll: false,
            issuedAt: issuedAt,
            expiresAt: nil,
            originalRequest: "Home settings: Lock Selected Apps",
            targetChildID: childID,
            sources: [.manual],
            webOpen: false
        )
    }

    /// Upsert the Home settings record (force overwrites the previous
    /// snapshot — re-locking re-bakes the current selection, no confirm
    /// prompt). Returns `false` for an empty selection.
    @discardableResult
    static func lock(
        selection: FamilyActivitySelection,
        childID: UUID,
        store: ActiveLockStore = .shared
    ) async -> Bool {
        guard let record = makeRecord(selection: selection, childID: childID) else {
            return false
        }
        if case .added = await store.addShield(record, force: true) {
            return true
        }
        return false
    }

    /// Remove ONLY the stable Home settings record. Returns whether a record
    /// was actually removed.
    @discardableResult
    static func unlock(store: ActiveLockStore = .shared) async -> Bool {
        await store.removeShield(recordKey: recordKey) != nil
    }
}
