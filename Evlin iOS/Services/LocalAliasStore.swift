import Foundation
import FamilyControls
import ManagedSettings

struct LocalCatalogAppTarget: Identifiable, Equatable, Sendable {
    let aliasKey: UUID
    let label: String
    let lookupKeys: [String]
    let bundleID: String?

    var id: UUID { aliasKey }
}

struct LocalCatalogCategoryTarget: Identifiable, Equatable, Sendable {
    let aliasKey: UUID
    let name: String

    var id: UUID { aliasKey }

    var displayName: String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Local-device persistence for category tokens and saved-list selections.
/// Backed by App Group UserDefaults — shared with DeviceActivityMonitor extension.
final class LocalAliasStore: @unchecked Sendable {
    static let shared = LocalAliasStore()

    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let categoryKey = "evlin.categoryTokens"
    private let listKey = "evlin.savedListTokens"
    private let applicationTokenKey = "evlin.applicationTokens"
    private let catalogAliasKeyIndexKey = "evlin.catalogAliasKeyIndex"
    /// Lowercased display name → lowercased bundle id (for exact-app `targetKey` + queries).
    private let applicationDisplayToBundleKey = "evlin.applicationDisplayToBundle"

    // MARK: - Categories

    func saveCategoryToken(_ token: ActivityCategoryToken, forName name: String, catalogAliasKey: UUID? = nil) {
        var dict = loadCategoryDict()
        if let data = _encodeTokenJSON(token) {
            dict[name.lowercased()] = data
            persistCategoryDict(dict)
            if let catalogAliasKey {
                saveCatalogAliasKey(
                    catalogAliasKey,
                    targetType: .category,
                    encodedTokenKey: data.base64EncodedString()
                )
            }
        }
    }

    func categoryToken(forName name: String) -> ActivityCategoryToken? {
        let dict = loadCategoryDict()
        guard let data = dict[name.lowercased()] else { return nil }
        return _decodeTokenAny(ActivityCategoryToken.self, from: data)
    }

    // MARK: - Applications (Managed Apps → token lookup)

    /// Persists the same `ApplicationToken` under bundle id and/or display name keys.
    func saveApplicationAliases(
        token: ApplicationToken,
        displayName: String?,
        bundleIdentifier: String?,
        catalogAliasKey: UUID? = nil
    ) {
        guard let data = _encodeTokenJSON(token) else { return }
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
        if let catalogAliasKey {
            saveCatalogAliasKey(
                catalogAliasKey,
                targetType: .app,
                encodedTokenKey: data.base64EncodedString()
            )
        }
    }

    /// Case-insensitive: bundle id, **or** display name / free-text hint from the parent command.
    func applicationToken(forLookupKey key: String) -> ApplicationToken? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return nil }
        guard let data = loadApplicationTokenDict()[k] else { return nil }
        return _decodeTokenAny(ApplicationToken.self, from: data)
    }

    /// Case-insensitive app lookup that rejects aliases whose saved token is no
    /// longer present in the current Managed Apps selection. Treating that as a
    /// miss makes chat fall back to lazy tagging instead of applying stale tokens.
    func activeApplicationToken(
        forLookupKey key: String,
        activeTokens: Set<ApplicationToken>
    ) -> ApplicationToken? {
        guard let token = applicationToken(forLookupKey: key) else { return nil }
        guard activeTokens.contains(token) else {
            markStale(forLookupKey: key)
            return nil
        }
        return token
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
            guard let t = _decodeTokenAny(ActivityCategoryToken.self, from: data),
                  t == token
            else { return nil }
            return key
        }
        .sorted()
    }

    /// Debug: all persisted application lookup keys whose decoded token matches `token`.
    func applicationLookupKeys(equalTo token: ApplicationToken) -> [String] {
        loadApplicationTokenDict().compactMap { key, data -> String? in
            guard let t = _decodeTokenAny(ApplicationToken.self, from: data),
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
        // _decodeTokenAny tries JSON first, falls back to PropertyList for legacy
        // payloads. iOS 26 broke PropertyListEncoder on FamilyControls tokens.
        guard let snapshot = _decodeTokenAny(AliasSnapshot.self, from: data) else {
            return ReportHydrationResult(
                appsSaved: 0,
                categoriesSaved: 0,
                generatedAt: nil,
                status: "Snapshot decode failed (tried JSON + plist)",
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
            guard let token = _decodeTokenAny(ApplicationToken.self, from: app.tokenData) else {
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
            guard let token = _decodeTokenAny(ActivityCategoryToken.self, from: cat.tokenData) else {
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

    /// Saved app keys whose token is still in the active Managed Apps selection.
    /// Used for backend alias-state so stale aliases do not suppress lazy-tag cards.
    func allActiveApplicationKeys(activeTokens: Set<ApplicationToken>) -> [String] {
        loadApplicationTokenDict().compactMap { key, data -> String? in
            guard let token = _decodeTokenAny(ApplicationToken.self, from: data),
                  activeTokens.contains(token)
            else { return nil }
            return key
        }
        .sorted()
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

    /// Backend-backed app targets available for composing a saved list. These
    /// are stricter than `groupedApplicationAliases()` because they only include
    /// rows whose opaque token has a backend alias_key.
    func catalogAppTargets() -> [LocalCatalogAppTarget] {
        let dict = loadApplicationTokenDict()
        let bMap = loadDisplayToBundleDict()
        let index = loadCatalogAliasKeyIndex()
        var groups: [Data: [String]] = [:]
        for (key, data) in dict {
            groups[data, default: []].append(key)
        }

        return groups.compactMap { data, keys -> LocalCatalogAppTarget? in
            let encodedToken = data.base64EncodedString()
            guard let indexData = index[encodedToken],
                  let record = try? JSONDecoder().decode(CatalogAliasKeyRecord.self, from: indexData),
                  record.targetType == .app
            else { return nil }

            let bundleSet = Set(bMap.values)
            let display = keys
                .filter { !bundleSet.contains($0) && !$0.contains(".") }
                .sorted()
                .first
            let bundle = keys.first(where: { bundleSet.contains($0) || $0.contains(".") })
            let label = display ?? bundle ?? keys.sorted().first ?? "App"
            return LocalCatalogAppTarget(
                aliasKey: record.aliasKey,
                label: label,
                lookupKeys: keys.sorted(),
                bundleID: bundle
            )
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Backend-backed category targets available for composing a saved list.
    func catalogCategoryTargets() -> [LocalCatalogCategoryTarget] {
        let index = loadCatalogAliasKeyIndex()
        return loadCategoryDict().compactMap { name, data -> LocalCatalogCategoryTarget? in
            let encodedToken = data.base64EncodedString()
            guard let indexData = index[encodedToken],
                  let record = try? JSONDecoder().decode(CatalogAliasKeyRecord.self, from: indexData),
                  record.targetType == .category
            else { return nil }
            return LocalCatalogCategoryTarget(aliasKey: record.aliasKey, name: name)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

    /// Mark a saved app alias as stale by removing every lookup key backed by
    /// the same encoded token. This handles display-name + bundle-id aliases as
    /// one logical tag, so the next command prompts a fresh picker selection.
    @discardableResult
    func markStale(forLookupKey key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return false }

        var tokMap = loadApplicationTokenDict()
        guard let staleData = tokMap[k] else { return false }
        let staleKeys = Set(tokMap.compactMap { alias, data in
            data == staleData ? alias : nil
        })
        guard !staleKeys.isEmpty else { return false }

        for alias in staleKeys {
            tokMap.removeValue(forKey: alias)
        }
        persistApplicationTokenDict(tokMap)

        var bMap = loadDisplayToBundleDict()
        for alias in staleKeys {
            bMap.removeValue(forKey: alias)
        }
        let staleDisplayKeys = bMap.compactMap { display, bundle in
            staleKeys.contains(bundle) ? display : nil
        }
        for display in staleDisplayKeys {
            bMap.removeValue(forKey: display)
        }
        persistDisplayToBundleDict(bMap)
        return true
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
        defaults?.removeObject(forKey: catalogAliasKeyIndexKey)
    }

    // MARK: - Saved Lists

    func saveList(_ selection: FamilyActivitySelection, named name: String) {
        var dict = loadListDict()
        if let data = _encodeTokenJSON(selection) {
            dict[name.lowercased()] = data
            persistListDict(dict)
        }
    }

    func savedList(named name: String) -> FamilyActivitySelection? {
        let dict = loadListDict()
        guard let data = dict[name.lowercased()] else { return nil }
        return _decodeTokenAny(FamilyActivitySelection.self, from: data)
    }

    func allListNames() -> [String] {
        Array(loadListDict().keys)
    }

    // MARK: - Backend catalog member mapping

    /// Persist the backend `alias_key` corresponding to a locally-held opaque
    /// FamilyControls token. Saved lists use this to upload explicit member
    /// sets without ever exposing raw token bytes to the parent device.
    func saveCatalogAliasKey(
        _ aliasKey: UUID,
        targetType: CatalogListMemberTargetType,
        encodedTokenKey: String
    ) {
        let key = encodedTokenKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var dict = loadCatalogAliasKeyIndex()
        let record = CatalogAliasKeyRecord(targetType: targetType, aliasKey: aliasKey)
        guard let data = try? JSONEncoder().encode(record) else { return }
        dict[key] = data
        persistCatalogAliasKeyIndex(dict)
    }

    func catalogListMembers(
        applicationTokenKeys: [String],
        categoryTokenKeys: [String]
    ) -> [CatalogListMemberUpload] {
        let index = loadCatalogAliasKeyIndex()
        var seen = Set<UUID>()
        var members: [CatalogListMemberUpload] = []

        func appendIfKnown(_ tokenKey: String, expectedType: CatalogListMemberTargetType) {
            let key = tokenKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  let data = index[key],
                  let record = try? JSONDecoder().decode(CatalogAliasKeyRecord.self, from: data),
                  record.targetType == expectedType,
                  seen.insert(record.aliasKey).inserted
            else { return }
            members.append(CatalogListMemberUpload(targetType: expectedType, aliasKey: record.aliasKey))
        }

        for tokenKey in applicationTokenKeys {
            appendIfKnown(tokenKey, expectedType: .app)
        }
        for tokenKey in categoryTokenKeys {
            appendIfKnown(tokenKey, expectedType: .category)
        }
        return members
    }

    func catalogListMembers(for selection: FamilyActivitySelection) -> [CatalogListMemberUpload] {
        catalogListMembers(
            applicationTokenKeys: selection.applicationTokens.compactMap(encodedTokenKey),
            categoryTokenKeys: selection.categoryTokens.compactMap(encodedTokenKey)
        )
    }

    // MARK: - Private

    private struct CatalogAliasKeyRecord: Codable {
        let targetType: CatalogListMemberTargetType
        let aliasKey: UUID
    }

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

    private func loadCatalogAliasKeyIndex() -> [String: Data] {
        (defaults?.dictionary(forKey: catalogAliasKeyIndexKey) as? [String: Data]) ?? [:]
    }

    private func persistCatalogAliasKeyIndex(_ dict: [String: Data]) {
        defaults?.set(dict, forKey: catalogAliasKeyIndexKey)
    }

    private func loadDisplayToBundleDict() -> [String: String] {
        (defaults?.dictionary(forKey: applicationDisplayToBundleKey) as? [String: String]) ?? [:]
    }

    private func persistDisplayToBundleDict(_ dict: [String: String]) {
        defaults?.set(dict, forKey: applicationDisplayToBundleKey)
    }

    private func encodedTokenKey<T: Encodable>(_ token: T) -> String? {
        _encodeTokenJSON(token)?.base64EncodedString()
    }
}


// MARK: - Token-codable helpers (iOS 26 PropertyListEncoder crash workaround)

/// `PropertyListEncoder` trips `swift_dynamicCastFailure` when encoding
/// FamilyControls tokens on iOS 26 (binary plist Swift rewrite regression).
/// JSON encoding round-trips the same tokens without hitting that codepath.
@inline(__always)
fileprivate func _encodeTokenJSON<T: Encodable>(_ value: T) -> Data? {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return try? e.encode(value)
}

/// Try JSON first (new format), fall back to PropertyList (legacy data already
/// in UserDefaults from previous app versions). On the first successful plist
/// decode of any field, the caller's next save will re-write as JSON, gradually
/// migrating the user's storage.
@inline(__always)
fileprivate func _decodeTokenAny<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    let jd = JSONDecoder()
    jd.dateDecodingStrategy = .iso8601
    if let v = try? jd.decode(type, from: data) { return v }
    return try? PropertyListDecoder().decode(type, from: data)
}
