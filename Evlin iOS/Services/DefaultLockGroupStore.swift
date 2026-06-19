import FamilyControls
import ManagedSettings

/// Thin wrapper over `LocalAliasStore` saved-list persistence, scoped to the
/// single default lock group's `FamilyActivitySelection`. Reads/writes the
/// saved list named after `DefaultLockGroup.shared.name` ("Locked set").
enum DefaultLockGroupStore {
    private static var listName: String { DefaultLockGroup.shared.name }

    static func load() -> FamilyActivitySelection {
        LocalAliasStore.shared.savedList(named: listName) ?? FamilyActivitySelection()
    }

    static func save(_ selection: FamilyActivitySelection) {
        LocalAliasStore.shared.saveList(selection, named: listName)
    }

    static func removeApp(_ token: ApplicationToken) {
        var s = load()
        s.applicationTokens.remove(token)
        save(s)
    }

    static func removeCategory(_ token: ActivityCategoryToken) {
        var s = load()
        s.categoryTokens.remove(token)
        save(s)
    }
}
