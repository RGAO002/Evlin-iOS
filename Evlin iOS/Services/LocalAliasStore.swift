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
    private let applicationTokenKey = "evlin.applicationTokens"
    /// Lowercased display name → lowercased bundle id (for exact-app `targetKey` + queries).
    private let applicationDisplayToBundleKey = "evlin.applicationDisplayToBundle"

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

    // MARK: - Applications (Managed Apps → token lookup)

    /// Persists the same `ApplicationToken` under bundle id and/or display name keys.
    func saveApplicationAliases(token: ApplicationToken, displayName: String?, bundleIdentifier: String?) {
        guard let data = try? PropertyListEncoder().encode(token) else { return }
        var tokMap = loadApplicationTokenDict()
        if let bid = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            let b = bid.lowercased()
            tokMap[b] = data
        }
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let n = name.lowercased()
            tokMap[n] = data
            if let bid = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
                var bMap = loadDisplayToBundleDict()
                bMap[n] = bid.lowercased()
                persistDisplayToBundleDict(bMap)
            }
        }
        persistApplicationTokenDict(tokMap)
    }

    /// Case-insensitive: bundle id, **or** display name / free-text hint from the parent command.
    func applicationToken(forLookupKey key: String) -> ApplicationToken? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return nil }
        guard let data = loadApplicationTokenDict()[k] else { return nil }
        return try? PropertyListDecoder().decode(ApplicationToken.self, from: data)
    }

    /// When the command names an app by display string, map to its bundle id for stable `exactApp` keys.
    func primaryBundleID(forDisplayOrHint key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return nil }
        return loadDisplayToBundleDict()[k]
    }

    /// Debug: all persisted category lookup keys whose decoded token matches `token`.
    func categoryLookupKeys(equalTo token: ActivityCategoryToken) -> [String] {
        loadCategoryDict().compactMap { key, data -> String? in
            guard let t = try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: data),
                  t == token
            else { return nil }
            return key
        }
        .sorted()
    }

    /// Debug: all persisted application lookup keys whose decoded token matches `token`.
    func applicationLookupKeys(equalTo token: ApplicationToken) -> [String] {
        loadApplicationTokenDict().compactMap { key, data -> String? in
            guard let t = try? PropertyListDecoder().decode(ApplicationToken.self, from: data),
                  t == token
            else { return nil }
            return key
        }
        .sorted()
    }

    // MARK: - DeviceActivityReport hydration

    /// Read raw bytes the extension wrote via file-channel (alongside or
    /// instead of UserDefaults). Used by hydrate, exposed here so the E2E
    /// test page can show file channel byte count separately.
    func readAliasSnapshotFile() -> Data? {
        guard let url = aliasSnapshotFileURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Byte size + last-modified date of the file channel — diagnostic only.
    func aliasSnapshotFileInfo() -> (bytes: Int, modifiedAt: Date?) {
        guard let url = aliasSnapshotFileURL() else { return (0, nil) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        let modified = attrs?[.modificationDate] as? Date
        return (bytes, modified)
    }

    private func aliasSnapshotFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.evlin.ios")?
            .appendingPathComponent("alias-snapshot.plist")
    }


    /// Mirror of `EvlinDeviceActivityReport.AliasSnapshot` — keep byte-identical.
    private struct AliasSnapshot: Codable {
        struct App: Codable {
            let tokenData: Data
            let displayName: String
            let bundleIdentifier: String
            let parentCategoryName: String
        }
        struct Category: Codable {
            let tokenData: Data
            let displayName: String
        }
        let applications: [App]
        let categories: [Category]
        let generatedAt: Date
    }

    struct ReportHydrationResult {
        let appsSaved: Int
        let categoriesSaved: Int
        let generatedAt: Date?
        let status: String
        let snapshotBytes: Int
        let snapshotApps: Int
        let snapshotCategories: Int
        let appDecodeFailures: Int
        let categoryDecodeFailures: Int
        let skippedEmptyApps: Int

        static let noDefaults = ReportHydrationResult(
            appsSaved: 0,
            categoriesSaved: 0,
            generatedAt: nil,
            status: "App Group defaults unavailable",
            snapshotBytes: 0,
            snapshotApps: 0,
            snapshotCategories: 0,
            appDecodeFailures: 0,
            categoryDecodeFailures: 0,
            skippedEmptyApps: 0
        )

        static let noSnapshot = ReportHydrationResult(
            appsSaved: 0,
            categoriesSaved: 0,
            generatedAt: nil,
            status: "No evlin.aliasSnapshot data",
            snapshotBytes: 0,
            snapshotApps: 0,
            snapshotCategories: 0,
            appDecodeFailures: 0,
            categoryDecodeFailures: 0,
            skippedEmptyApps: 0
        )
    }

    /// Read the DeviceActivityReport extension's snapshot from App Group and
    /// flow it into our token aliases. This is the bridge that lets chat
    /// resolve "Instagram" → ApplicationToken without picker / lazy-tag.
    /// Idempotent — safe to call on every app launch / Home appearance.
    /// Returns counts of newly-saved aliases for diagnostic display.
    @discardableResult
    func hydrateFromReport() -> (apps: Int, categories: Int, generatedAt: Date?) {
        let result = hydrateFromReportDetailed()
        return (result.appsSaved, result.categoriesSaved, result.generatedAt)
    }

    /// Diagnostic version of `hydrateFromReport()` that explains exactly which
    /// stage failed: no App Group, no snapshot, plist decode failure, token
    /// decode failure, or rows skipped because Apple returned no usable name.
    @discardableResult
    func hydrateFromReportDetailed() -> ReportHydrationResult {
        guard let defaults else { return .noDefaults }
        // Try file channel first — it's a more reliable transport across the
        // extension/app process boundary than UserDefaults (no caching layer).
        // Fall back to UserDefaults if file is missing.
        let fileData = readAliasSnapshotFile()
        let userDefaultsData = defaults.data(forKey: "evlin.aliasSnapshot")
        guard let data = fileData ?? userDefaultsData else { return .noSnapshot }
        let snapshot: AliasSnapshot
        do {
            snapshot = try PropertyListDecoder().decode(AliasSnapshot.self, from: data)
        } catch {
            return ReportHydrationResult(
                appsSaved: 0,
                categoriesSaved: 0,
                generatedAt: nil,
                status: "Snapshot plist decode failed: \(error.localizedDescription)",
                snapshotBytes: data.count,
                snapshotApps: 0,
                snapshotCategories: 0,
                appDecodeFailures: 0,
                categoryDecodeFailures: 0,
                skippedEmptyApps: 0
            )
        }

        var appDecodeFailures = 0
        var categoryDecodeFailures = 0
        var skippedEmptyApps = 0
        var appsSaved = 0
        for app in snapshot.applications {
            guard let token = try? PropertyListDecoder().decode(ApplicationToken.self, from: app.tokenData) else {
                appDecodeFailures += 1
                continue
            }
            let cleanName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBundle = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty || !cleanBundle.isEmpty else {
                skippedEmptyApps += 1
                continue
            }
            saveApplicationAliases(
                token: token,
                displayName: cleanName.isEmpty ? nil : cleanName,
                bundleIdentifier: cleanBundle.isEmpty ? nil : cleanBundle
            )
            appsSaved += 1
        }

        var catsSaved = 0
        for cat in snapshot.categories {
            guard let token = try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: cat.tokenData) else {
                categoryDecodeFailures += 1
                continue
            }
            let clean = cat.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            saveCategoryToken(token, forName: clean)
            catsSaved += 1
        }

        return ReportHydrationResult(
            appsSaved: appsSaved,
            categoriesSaved: catsSaved,
            generatedAt: snapshot.generatedAt,
            status: "ok",
            snapshotBytes: data.count,
            snapshotApps: snapshot.applications.count,
            snapshotCategories: snapshot.categories.count,
            appDecodeFailures: appDecodeFailures,
            categoryDecodeFailures: categoryDecodeFailures,
            skippedEmptyApps: skippedEmptyApps
        )
    }

    // MARK: - Management (list + delete)

    /// All saved category lookup keys (lowercased), sorted.
    func allCategoryNames() -> [String] {
        loadCategoryDict().keys.sorted()
    }

    /// All saved application lookup keys (lowercased) — includes both
    /// display-name and bundle-id keys. Multiple keys can point at the
    /// same `ApplicationToken`. Sorted.
    func allApplicationKeys() -> [String] {
        loadApplicationTokenDict().keys.sorted()
    }

    /// Application aliases grouped by underlying token. Each group's keys
    /// (display names + bundle ids) all resolve to the same token, so a
    /// "delete this app's tag" action should drop them all together.
    /// Returns `(displayLabel, allKeys, bundleID?)` tuples sorted by label.
    func groupedApplicationAliases() -> [(label: String, keys: [String], bundleID: String?)] {
        let dict = loadApplicationTokenDict()
        let bMap = loadDisplayToBundleDict()
        // Group keys by raw token-data identity (Data is Hashable).
        var groups: [Data: [String]] = [:]
        for (key, data) in dict {
            groups[data, default: []].append(key)
        }
        return groups.map { (_, keys) -> (String, [String], String?) in
            let bundleSet = Set(bMap.values)
            let display = keys
                .filter { !bundleSet.contains($0) && !$0.contains(".") }
                .sorted()
                .first
            let bundle = keys.first(where: { bundleSet.contains($0) || $0.contains(".") })
            let label = display ?? bundle ?? keys.sorted().first ?? "?"
            return (label, keys.sorted(), bundle)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Remove a category alias by lookup name (case-insensitive).
    func removeCategory(named name: String) {
        var dict = loadCategoryDict()
        dict.removeValue(forKey: name.lowercased())
        persistCategoryDict(dict)
    }

    /// Remove an application alias for a single lookup key. Other keys
    /// pointing at the same token (e.g. its bundle id) are untouched.
    func removeApplicationAlias(key: String) {
        let k = key.lowercased()
        var tokMap = loadApplicationTokenDict()
        tokMap.removeValue(forKey: k)
        persistApplicationTokenDict(tokMap)
        var bMap = loadDisplayToBundleDict()
        bMap.removeValue(forKey: k)
        persistDisplayToBundleDict(bMap)
    }

    /// Remove every alias key in `keys` in one pass — used when the parent
    /// deletes "Instagram" and we want both the display-name key and the
    /// bundle-id key gone.
    func removeApplicationAliases(keys: [String]) {
        var tokMap = loadApplicationTokenDict()
        var bMap = loadDisplayToBundleDict()
        for k in keys {
            let lk = k.lowercased()
            tokMap.removeValue(forKey: lk)
            bMap.removeValue(forKey: lk)
        }
        persistApplicationTokenDict(tokMap)
        persistDisplayToBundleDict(bMap)
    }

    /// Wipe every saved alias (apps + categories + saved lists). Tokens in
    /// `ScreenTimeManager.selectedApps` and active shields are unaffected —
    /// this only clears the chat → token name lookup table.
    func removeAllAliases() {
        defaults?.removeObject(forKey: applicationTokenKey)
        defaults?.removeObject(forKey: applicationDisplayToBundleKey)
        defaults?.removeObject(forKey: categoryKey)
        defaults?.removeObject(forKey: listKey)
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

    private func loadApplicationTokenDict() -> [String: Data] {
        (defaults?.dictionary(forKey: applicationTokenKey) as? [String: Data]) ?? [:]
    }

    private func persistApplicationTokenDict(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: applicationTokenKey)
    }

    private func loadDisplayToBundleDict() -> [String: String] {
        (defaults?.dictionary(forKey: applicationDisplayToBundleKey) as? [String: String]) ?? [:]
    }

    private func persistDisplayToBundleDict(_ dict: [String: String]) {
        defaults?.set(dict, forKey: applicationDisplayToBundleKey)
    }
}
