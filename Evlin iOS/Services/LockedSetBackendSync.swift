import Foundation
import FamilyControls

// MARK: - LockedSetSyncInputBuilder

/// Pure helper that converts a local `FamilyActivitySelection` (or a pre-computed
/// `[CatalogListMemberUpload]`) into a `ControlListInput` for the backend upsert.
///
/// Separated from the network call so it is unit-testable without mocks.
enum LockedSetSyncInputBuilder {

    /// Build from a raw member array. Returns nil when `members` is empty.
    static func build(
        members: [CatalogListMemberUpload],
        existingAliasKey: UUID?
    ) -> ControlListInput? {
        guard !members.isEmpty else { return nil }
        let name = DefaultLockGroup.shared.name
        return ControlListInput(
            aliasKey: existingAliasKey,
            listName: name,
            aliases: [name],
            members: members,
            selectionBlobBase64: nil
        )
    }

    /// Build from a `FamilyActivitySelection`. Returns nil when the selection
    /// maps to zero known members (no aliases recorded yet in LocalAliasStore).
    static func build(
        selection: FamilyActivitySelection,
        existingAliasKey: UUID?
    ) -> ControlListInput? {
        let members = LocalAliasStore.shared.catalogListMembers(for: selection)
        return build(members: members, existingAliasKey: existingAliasKey)
    }
}

// MARK: - syncLockedSetToBackend

/// Uploads the local "Locked set" `FamilyActivitySelection` to the backend as a
/// `ChildCatalogList` named `"Locked set"` (upsert: create on first call, update
/// on subsequent calls using the persisted `alias_key`).
///
/// Returns `nil` when the local selection is empty (no app/category members have
/// been bound in `LocalAliasStore` yet — nothing to upload). Returns the
/// `ControlListDTO` on success. Throws on network error — callers typically
/// suppress the error (via `try?`) so a transient failure here does not block the
/// lock button; the lazy-sync in `toggleDeviceLock` will retry on the next tap.
///
/// After a successful create/update the returned `ControlListDTO.aliasKey` is
/// persisted to `EarnedTimeStore.shared.lockedSetListAliasKey` so subsequent
/// calls take the update path instead of creating a duplicate list.
///
/// - Parameters:
///   - deviceID: The child device's backend UUID.
///   - apiClient: The shared `APIClient` instance.
@discardableResult
func syncLockedSetToBackend(
    deviceID: UUID,
    apiClient: APIClient
) async throws -> ControlListDTO? {
    let selection = DefaultLockGroupStore.load()
    let existingAliasKey = EarnedTimeStore.shared.lockedSetListAliasKey
    guard let input = LockedSetSyncInputBuilder.build(
        selection: selection,
        existingAliasKey: existingAliasKey
    ) else {
        return nil
    }

    let dto: ControlListDTO
    if existingAliasKey == nil {
        dto = try await apiClient.createControlList(input, deviceID: deviceID)
    } else {
        dto = try await apiClient.updateControlList(input, deviceID: deviceID)
    }
    EarnedTimeStore.shared.saveLockedSetListAliasKey(dto.aliasKey)
    return dto
}
