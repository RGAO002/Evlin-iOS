import Foundation
import FamilyControls
import ManagedSettings

/// Hydrates **`LocalAliasStore`** from **`FamilyActivitySelection` metadata**.
///
/// - **Categories**: each `localizedDisplayName` (+ existing semantic keys from
///   `SemanticCategoryAliasSync`) maps to that row’s `ActivityCategoryToken`.
/// - **Apps**: each app’s `bundleIdentifier` and `localizedDisplayName` map to
///   `ApplicationToken` (same token object under both keys when both exist).
///
/// **Limitation:** Apple does not expose which apps belong to which category in
/// `FamilyActivitySelection`. We only persist **name ↔ token** lookups, not a
/// category→apps graph.
enum ManagedSelectionAliasSync {

    private static let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private static let categoryLabelSnapshotKey = "evlin.managedCategoryLabelSnapshot"
    private static let applicationLabelSnapshotKey = "evlin.managedApplicationLabelSnapshot"

    private struct PersistedCategoryLabel: Codable {
        let displayName: String
        let tokenEncoded: Data
    }

    private struct PersistedApplicationLabel: Codable {
        /// May be nil on some payloads; persist whatever the picker surfaced.
        var displayName: String?
        var bundleIdentifier: String?
        let tokenEncoded: Data
    }

    /// Run after Managed Apps save or when restoring selection on launch.
    static func syncAll(from selection: FamilyActivitySelection) {
        if !selection.categories.isEmpty {
            persistCategoryLabelSnapshot(from: selection)
        }
        if !selection.applications.isEmpty {
            persistApplicationLabelSnapshot(from: selection)
        }
        SemanticCategoryAliasSync.syncChatAliases(from: selection)
        if selection.categories.isEmpty, !selection.categoryTokens.isEmpty {
            reapplyCategoryAliasesFromSnapshot(tokens: selection.categoryTokens)
        }
        syncApplicationAliases(from: selection)
        if applicationMetadataLikelyAbsent(selection: selection),
           !selection.applicationTokens.isEmpty {
            reapplyApplicationAliasesFromSnapshot(tokens: selection.applicationTokens)
        }
    }

    /// True when Apple's picker surfaced category rows without any non-empty localized title.
    static func categoryPickerNamesMissing(selection: FamilyActivitySelection) -> Bool {
        guard !selection.categories.isEmpty else { return false }
        return selection.categories.allSatisfy { cat in
            let n = cat.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return n.isEmpty
        }
    }

    /// For debug HUD: localized labels missing on apps and/or categories but token counts are non-zero.
    static func metadataStarved(selection: FamilyActivitySelection) -> Bool {
        categoryPickerNamesMissing(selection: selection) || applicationMetadataLikelyAbsent(selection: selection)
    }

    /// Picker occasionally yields `applications` rows with tokens but blank names / bundle IDs.
    /// In that state we rebuild from the last persisted snapshot (`reapplyApplicationAliasesFromSnapshot`).
    private static func applicationMetadataLikelyAbsent(selection: FamilyActivitySelection) -> Bool {
        guard !selection.applicationTokens.isEmpty else { return false }
        if selection.applications.isEmpty { return true }
        let hasUsefulMeta = selection.applications.contains(where: appRowHasPersistableLabels)
        return !hasUsefulMeta
    }

    /// True when we could ever write a plist row worth keeping (non-empty trimmed name OR bundle).
    private static func appRowHasPersistableLabels(_ app: Application) -> Bool {
        guard app.token != nil else { return false }
        let b = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let n = app.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !b.isEmpty || !n.isEmpty
    }

    /// FamilyActivitySelection’s `categories` array is often **empty after plist decode** even when
    /// `categoryTokens` is intact. We keep a sidecar of (display name, token) captured when the
    /// picker last had metadata so `entertainment`-style hints still resolve after relaunch.
    private static func persistCategoryLabelSnapshot(from selection: FamilyActivitySelection) {
        var rows: [PersistedCategoryLabel] = []
        for cat in selection.categories {
            guard let token = cat.token,
                  let name = cat.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let encoded = try? JSONEncoder().encode(token)
            else { continue }
            rows.append(.init(displayName: name, tokenEncoded: encoded))
        }
        // Never overwrite good data with [] — Apple's picker sometimes returns category rows whose
        // `localizedDisplayName` is nil; writing an empty blob wiped our relaunch snapshots.
        guard !rows.isEmpty, let data = try? JSONEncoder().encode(rows) else { return }
        defaults?.set(data, forKey: categoryLabelSnapshotKey)
    }

    private static func persistApplicationLabelSnapshot(from selection: FamilyActivitySelection) {
        var rows: [PersistedApplicationLabel] = []
        for app in selection.applications {
            guard let token = app.token,
                  let encoded = try? JSONEncoder().encode(token)
            else { continue }
            guard appRowHasPersistableLabels(app) else { continue }
            let bundle = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = app.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(.init(displayName: name, bundleIdentifier: bundle, tokenEncoded: encoded))
        }
        guard !rows.isEmpty, let data = try? JSONEncoder().encode(rows) else { return }
        defaults?.set(data, forKey: applicationLabelSnapshotKey)
    }

    private static func reapplyCategoryAliasesFromSnapshot(tokens: Set<ActivityCategoryToken>) {
        guard let data = defaults?.data(forKey: categoryLabelSnapshotKey),
              let rows = try? JSONDecoder().decode([PersistedCategoryLabel].self, from: data)
        else { return }

        for row in rows {
            guard let tok = (try? JSONDecoder().decode(ActivityCategoryToken.self, from: row.tokenEncoded))
                         ?? (try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: row.tokenEncoded)),
                  tokens.contains(tok)
            else { continue }
            SemanticCategoryAliasSync.persistSemanticAndDisplayAliases(token: tok, displayName: row.displayName)
        }
    }

    private static func reapplyApplicationAliasesFromSnapshot(tokens: Set<ApplicationToken>) {
        guard let data = defaults?.data(forKey: applicationLabelSnapshotKey),
              let rows = try? JSONDecoder().decode([PersistedApplicationLabel].self, from: data)
        else { return }

        for row in rows {
            guard let tok = (try? JSONDecoder().decode(ApplicationToken.self, from: row.tokenEncoded))
                         ?? (try? PropertyListDecoder().decode(ApplicationToken.self, from: row.tokenEncoded)),
                  tokens.contains(tok)
            else { continue }
            LocalAliasStore.shared.saveApplicationAliases(
                token: tok,
                displayName: row.displayName,
                bundleIdentifier: row.bundleIdentifier
            )
        }
    }

    /// Debug: rows stored for relaunch semantic recovery `(picker label → token plist)`.
    static func debugCategorySnapshots() -> [(label: String, token: ActivityCategoryToken?)] {
        guard let data = defaults?.data(forKey: categoryLabelSnapshotKey),
              let rows = try? JSONDecoder().decode([PersistedCategoryLabel].self, from: data)
        else { return [] }
        return rows.map { row in
            let tok = (try? JSONDecoder().decode(ActivityCategoryToken.self, from: row.tokenEncoded))
                   ?? (try? PropertyListDecoder().decode(ActivityCategoryToken.self, from: row.tokenEncoded))
            return (row.displayName, tok)
        }
    }

    /// Debug: bundle / display persisted for opaque app tokens during a good picker session.
    static func debugApplicationSnapshots() -> [(displayName: String?, bundleIdentifier: String?, token: ApplicationToken?)] {
        guard let data = defaults?.data(forKey: applicationLabelSnapshotKey),
              let rows = try? JSONDecoder().decode([PersistedApplicationLabel].self, from: data)
        else { return [] }
        return rows.map { row in
            let tok = (try? JSONDecoder().decode(ApplicationToken.self, from: row.tokenEncoded))
                   ?? (try? PropertyListDecoder().decode(ApplicationToken.self, from: row.tokenEncoded))
            return (row.displayName, row.bundleIdentifier, tok)
        }
    }

    private static func syncApplicationAliases(from selection: FamilyActivitySelection) {
        for app in selection.applications {
            guard let tok = app.token else { continue }
            LocalAliasStore.shared.saveApplicationAliases(
                token: tok,
                displayName: app.localizedDisplayName,
                bundleIdentifier: app.bundleIdentifier
            )
        }
    }
}
