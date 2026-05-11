// Evlin iOS/Evlin iOS/Views/Debug/TokenAliasInspectionView.swift
import SwiftUI
import FamilyControls
import ManagedSettings

/// Debug-only readout: each picker-named row vs **`LocalAliasStore`** lookup keys encoding the same token.
struct TokenAliasInspectionView: View {
    @EnvironmentObject private var screenTimeManager: ScreenTimeManager
    @State private var inspectorRefreshTick = 0

    /// Bumped so we re-read `@Published selectedApps` after returning from Managed Apps without leaving this screen.
    private var sel: FamilyActivitySelection {
        _ = inspectorRefreshTick
        return screenTimeManager.selectedApps
    }
    private var aliasStore: LocalAliasStore { LocalAliasStore.shared }

    private var knownCategoryTokensFromRows: Set<ActivityCategoryToken> {
        Set(sel.categories.compactMap(\.token))
    }

    private var orphanCategoryTokens: [ActivityCategoryToken] {
        sel.categoryTokens.filter { !knownCategoryTokensFromRows.contains($0) }
    }

    var body: some View {
        List {
            Section("Current Managed Apps snapshot") {
                LabeledContent("applications (metadata)") { Text("\(sel.applications.count)") }
                LabeledContent("categories (metadata)") { Text("\(sel.categories.count)") }
                LabeledContent("applicationTokens") { Text("\(sel.applicationTokens.count)") }
                LabeledContent("categoryTokens") { Text("\(sel.categoryTokens.count)") }
            }

            if ManagedSelectionAliasSync.metadataStarved(selection: sel) {
                Section {
                    Text(
                        """
                        iOS returned rows with tokens but **blank** `localizedDisplayName` / `bundleIdentifier`. \
                        Evlin can’t build Chat aliases until Apple surfaces those strings (common on Simulator; also seen on some device builds). \
                        Try a **real device** with Screen Time authorized, or another iOS version. \
                        If you ever had a good picker session, the **persisted snapshots** below can still back-fill keys.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                }
            }

            Section {
                if sel.categories.isEmpty {
                    Text("Picker returned no category rows (`categories` is empty). Keys may still rebuild from **Persisted snapshot** below after you last saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(sel.categories.enumerated()), id: \.offset) { idx, cat in
                    categoryPickerRow(offset: idx, cat: cat)
                }
            } header: {
                Text("Categories — picker labels vs LocalAlias keys")
            } footer: {
                Text("Green checkmark: inferred Chat semantic hint (e.g. entertainment) is present among persisted keys for that token. Orange triangle: semantic missing or uncertain.")
                    .font(.caption)
            }

            Section {
                let snaps = ManagedSelectionAliasSync.debugCategorySnapshots()
                if snaps.isEmpty {
                    Text("No persisted label snapshot yet. Open Managed Apps, confirm selection, dismiss picker once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(snaps.enumerated()), id: \.offset) { idx, snap in
                        persistedCategorySnapshotRow(offset: idx, label: snap.label, token: snap.token)
                    }
                }
            } header: {
                Text("Persisted category label snapshot (`evlin.managedCategoryLabelSnapshot`)")
            }

            Section {
                let rows = ManagedSelectionAliasSync.debugApplicationSnapshots()
                if rows.isEmpty {
                    if sel.applicationTokens.isEmpty {
                        Text("No application tokens in the current Managed Apps selection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if ManagedSelectionAliasSync.metadataStarved(selection: sel) {
                        Text(
                            """
                            Tokens exist but we never persisted display names / bundle IDs (picker gave blank metadata). \
                            Try a physical device + Screen Time approved. After a healthy picker session once, reopen this inspector.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                    } else {
                        Text("No application snapshot blob yet — save Managed Apps from Settings after installing this build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, snap in
                        persistedAppSnapshotRow(offset: idx, displayName: snap.displayName, bundle: snap.bundleIdentifier, token: snap.token)
                    }
                }
            } header: {
                Text("Persisted app label snapshot (`evlin.managedApplicationLabelSnapshot`)")
            }

            Section {
                if orphanCategoryTokens.isEmpty {
                    Text("Every category token has a picker row.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(orphanCategoryTokens.enumerated()), id: \.offset) { idx, tok in
                        orphanedCategoryRow(offset: idx, token: tok)
                    }
                }
            } header: {
                Text("Category tokens without a picker row")
            }

            Section {
                let apps = Array(sel.applications.enumerated())
                if apps.isEmpty {
                    Text("No picker app rows (`applications` is empty). Relaunch-only token sets won’t show names until you reopen Managed Apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps.prefix(200), id: \.offset) { pair in
                        appRow(offset: pair.offset, app: pair.element)
                    }
                    if apps.count > 200 {
                        Text("Showing first 200 apps — truncated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Apps — display / bundle vs LocalAlias keys")
            }
        }
        .navigationTitle("Tokens ↔ aliases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reload") {
                    inspectorRefreshTick += 1
                }
                .accessibilityLabel("Reload selection from Managed Apps")
            }
        }
    }

    @ViewBuilder
    private func persistedAppSnapshotRow(
        offset: Int,
        displayName: String?,
        bundle: String?,
        token: ApplicationToken?
    ) -> some View {
        let nameLine = {
            let n = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return n.isEmpty ? "— (no display name)" : n
        }()
        let bundleLine = {
            let b = bundle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return b.isEmpty ? "— (no bundle id)" : b
        }()
        let keys = token.map { aliasStore.applicationLookupKeys(equalTo: $0) } ?? []
        let inSel = token.map { sel.applicationTokens.contains($0) } ?? false

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("[app snap \(offset)] ").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(inSel ? "in sel" : "not in sel")
                    .font(.caption2.monospaced())
                    .foregroundStyle(inSel ? Color.secondary : Color.orange)
            }
            Text(nameLine).font(.subheadline).fontWeight(.medium)
            Text(bundleLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if token == nil {
                Text("Failed to decode snapshot token plist.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(keys.isEmpty ? "Stored keys: —" : "Keys (\(keys.count)): \(keys.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(keys.isEmpty ? Color.orange : Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func categoryPickerRow(offset: Int, cat: ActivityCategory) -> some View {
        let rawTrimmed = cat.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameDisplay: String = {
            if let r = rawTrimmed, !r.isEmpty { return r }
            return "— (blank name)"
        }()
        let semantic = SemanticCategoryAliasSync.semanticAliasKey(forPickerLabel: cat.localizedDisplayName)
        let token = cat.token
        let keys = token.map { aliasStore.categoryLookupKeys(equalTo: $0) } ?? []
        let semanticOK = semantic.map { keys.contains($0) } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("[\(offset)] ")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(nameDisplay).font(.subheadline).fontWeight(.semibold)
                Spacer(minLength: 8)
                if token != nil {
                    Image(systemName: semanticOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(semanticOK ? Color.evSecondary : Color.evError)
                        .font(.caption)
                }
            }
            if token == nil {
                Text("No ActivityCategory token from picker.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                if let semantic {
                    LabeledContent("Chat semantic hint") { Text(semantic).fontDesign(.monospaced) }
                    if !semanticOK {
                        Text("Expected semantic alias not stored for this token. Save Managed Apps again.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(rawTrimmed == nil || rawTrimmed?.isEmpty == true
                         ? "Blank category title from iOS — semantic keys can’t be inferred."
                         : "No heuristic Chat key for this label — lock by **exact picker name**.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(keys.isEmpty ? "Stored keys: —" : "Stored keys (\(keys.count)): \(keys.joined(separator: ", "))")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Category \(nameDisplay)")
    }

    @ViewBuilder
    private func persistedCategorySnapshotRow(offset: Int, label: String, token: ActivityCategoryToken?) -> some View {
        let semantic = SemanticCategoryAliasSync.semanticAliasKey(forPickerLabel: label)
        let keys = token.map { aliasStore.categoryLookupKeys(equalTo: $0) } ?? []
        let inSelection = token.map { sel.categoryTokens.contains($0) } ?? false

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("[snapshot \(offset)] ").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(label).font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(inSelection ? "in sel" : "not in sel")
                    .font(.caption2.monospaced())
                    .foregroundStyle(inSelection ? Color.secondary : Color.orange)
            }
            if token == nil {
                Text("Failed to decode snapshot token plist.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                if let semantic {
                    Text("Semantic: \(semantic) — \(keys.contains(semantic) ? "✓ persisted" : "✗ missing from keys")")
                        .font(.caption)
                        .foregroundStyle(keys.contains(semantic) ? Color.secondary : Color.orange)
                }
                Text(keys.isEmpty ? "Stored keys: —" : "Keys: \(keys.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func orphanedCategoryRow(offset: Int, token: ActivityCategoryToken) -> some View {
        let keys = aliasStore.categoryLookupKeys(equalTo: token)
        VStack(alignment: .leading, spacing: 4) {
            Text("Orphan #\(offset)").font(.caption).foregroundStyle(.secondary)
            Text(keys.isEmpty ? "No persisted LocalAlias keys for this opaque token yet." : "Stored keys (\(keys.count)): \(keys.joined(separator: ", "))")
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(keys.isEmpty ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func appRow(offset: Int, app: Application) -> some View {
        if let tok = app.token {
            let name = app.localizedDisplayName ?? "—"
            let bundle = app.bundleIdentifier ?? "—"
            let keys = aliasStore.applicationLookupKeys(equalTo: tok)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("[\(offset)]")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(name).font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: keys.count >= 2 ? "checkmark.circle.fill" : (keys.isEmpty ? "exclamationmark.triangle.fill" : "minus.circle.fill"))
                        .foregroundStyle(keys.count >= 2 ? Color.evSecondary : (keys.isEmpty ? Color.evError : Color.evOutline))
                        .font(.caption)
                }
                Text(bundle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(keys.isEmpty ? "Stored keys: —" : "Keys (\(keys.count)): \(keys.joined(separator: ", "))")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(keys.isEmpty ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if keys.count == 1 {
                    Text("Only one lookup key saved (prefer both display name & bundle ID).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("[\(offset)] \(app.localizedDisplayName ?? "App") — no token")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TokenAliasInspectionView()
            .environmentObject(ScreenTimeManager.shared)
    }
}
#endif
