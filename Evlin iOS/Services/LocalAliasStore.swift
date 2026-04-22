import Foundation
import FamilyControls
import ManagedSettings

/// Local-device persistence for category tokens and saved-list selections.
/// Backed by App Group UserDefaults — shared with DeviceActivityMonitor extension.
final class LocalAliasStore: @unchecked Sendable {
    static let shared = LocalAliasStore()

    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let categoryKey = "evlin.categoryTokens"
    private let listKey = "evlin.savedListTokens"

    // MARK: - Categories

    func saveCategoryToken(_ token: ActivityCategoryToken, forName name: String) {
        var dict = loadCategoryDict()
        if let data = try? PropertyListEncoder().encode(token) {
            dict[name.lowercased()] = data
            persistCategoryDict(dict)
        }
    }

    func categoryToken(forName name: String) -> ActivityCategoryToken? {
        let dict = loadCategoryDict()
        guard let data = dict[name.lowercased()] else { return nil }
        return try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: data)
    }

    // MARK: - Saved Lists

    func saveList(_ selection: FamilyActivitySelection, named name: String) {
        var dict = loadListDict()
        if let data = try? PropertyListEncoder().encode(selection) {
            dict[name.lowercased()] = data
            persistListDict(dict)
        }
    }

    func savedList(named name: String) -> FamilyActivitySelection? {
        let dict = loadListDict()
        guard let data = dict[name.lowercased()] else { return nil }
        return try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    func allListNames() -> [String] {
        Array(loadListDict().keys)
    }

    // MARK: - Private

    private func loadCategoryDict() -> [String: Data] {
        (defaults?.dictionary(forKey: categoryKey) as? [String: Data]) ?? [:]
    }

    private func persistCategoryDict(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: categoryKey)
    }

    private func loadListDict() -> [String: Data] {
        (defaults?.dictionary(forKey: listKey) as? [String: Data]) ?? [:]
    }

    private func persistListDict(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: listKey)
    }
}
