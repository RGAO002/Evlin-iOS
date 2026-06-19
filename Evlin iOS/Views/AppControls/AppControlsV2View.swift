import SwiftUI
import FamilyControls
import ManagedSettings

/// App Controls v2 screen — Tasks 3.2 + 3.4 (accordion inline bind + upload-on-bind).
///
/// Replicates the `app-controls-v2-prototype.html` "App Controls v2" layout:
/// header "App Controls" + an "Add" button, a subtitle, then a **Categories**
/// section ON TOP (all rows shown) and an **Apps** section BELOW (lazy). Each
/// row is the real app/category icon + name (via `Label(token)`, which renders
/// the system-provided icon + label on the kid device — the name is not readable
/// as a `String`) plus a remove "x".
///
/// Tapping a row expands an inline **bind panel** below it (accordion). The app
/// panel embeds `AppStoreBindPanel` (App Store search); the category panel embeds
/// `CategoryTagPanel` (suggestion capsules). Picking a result/tag binds the token,
/// saves a LocalAliasStore alias immediately (so name-lock works even if the
/// upload fails), then uploads to the backend in a detached `Task` and re-saves
/// with the backend's real alias key. Unbound apps/categories are NEVER uploaded —
/// upload happens ONLY inside the bind handlers.
struct AppControlsV2View: View {
    let childDeviceID: UUID
    @EnvironmentObject var apiClient: APIClient

    @State private var selection: FamilyActivitySelection = DefaultLockGroupStore.load()
    @State private var showPicker = false

    // Accordion: at most one app and one category expanded at a time.
    @State private var expandedApp: ApplicationToken?
    @State private var expandedCategory: ActivityCategoryToken?

    // Soft inline error surfaced if a bind upload fails. The local alias is always
    // saved first, so a failure here never blocks naming on this device.
    @State private var bindError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                subtitle
                if let bindError {
                    bindErrorBanner(bindError)
                }
                categoriesSection
                appsSection
            }
            .padding(16)
        }
        .background(Color.evSurfaceContainer)
        .sheet(isPresented: $showPicker) {
            CombinedPickerSheet(
                initialSelection: selection,
                onSave: { newSelection in
                    DefaultLockGroupStore.save(newSelection)
                    reload()
                    showPicker = false
                },
                onCancel: { showPicker = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("App Controls")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.evOnSurface)

            Spacer()

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Color.evSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.evOutline, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 3)
    }

    private var subtitle: some View {
        Text("These all lock together as a group. Add an alias to a single one to also lock it by name.")
            .font(.footnote)
            .foregroundStyle(Color.evOnSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 14)
    }

    private func bindErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 12)
    }

    // MARK: - Categories (top, all shown)

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Categories")

            if selection.categoryTokens.isEmpty {
                emptyText("No categories.")
            } else {
                ForEach(Array(selection.categoryTokens), id: \.self) { token in
                    CategoryRow(
                        token: token,
                        isExpanded: expandedCategory == token,
                        onToggle: { toggleCategory(token) },
                        onRemove: {
                            if expandedCategory == token { expandedCategory = nil }
                            DefaultLockGroupStore.removeCategory(token)
                            reload()
                        },
                        onPick: { suggestion in bindCategory(token, suggestion: suggestion) }
                    )
                }
            }
        }
    }

    // MARK: - Apps (below, lazy)

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Apps")
                .padding(.top, 18)

            if selection.applicationTokens.isEmpty {
                emptyText("No apps.")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(selection.applicationTokens), id: \.self) { token in
                        AppRow(
                            token: token,
                            apiClient: apiClient,
                            isExpanded: expandedApp == token,
                            onToggle: { toggleApp(token) },
                            onRemove: {
                                if expandedApp == token { expandedApp = nil }
                                DefaultLockGroupStore.removeApp(token)
                                reload()
                            },
                            onPick: { result in bindApp(token, result: result) },
                            onManual: { name in
                                bindApp(token, result: CatalogSearchResult(canonicalName: name, bundleID: nil, aliases: []))
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Accordion toggles (only one expanded at a time)

    private func toggleApp(_ token: ApplicationToken) {
        bindError = nil
        if expandedApp == token {
            expandedApp = nil
        } else {
            expandedApp = token
            expandedCategory = nil
        }
    }

    private func toggleCategory(_ token: ActivityCategoryToken) {
        bindError = nil
        if expandedCategory == token {
            expandedCategory = nil
        } else {
            expandedCategory = token
            expandedApp = nil
        }
    }

    // MARK: - App bind handler (onPick + onManual share this)

    private func bindApp(_ appToken: ApplicationToken, result: CatalogSearchResult) {
        guard let b64 = (try? JSONEncoder().encode(appToken))?.base64EncodedString() else { return }
        var row = PendingAppRow(tokenBase64: b64)
        row.bind(result)
        row.confirm()
        guard let upload = row.makeUploadApp(sourceDeviceID: childDeviceID) else { return }

        // 1) Local alias FIRST so name-lock works even if the upload never lands.
        LocalAliasStore.shared.saveApplicationAliases(
            token: appToken,
            displayName: upload.displayName,
            bundleIdentifier: upload.bundleID
        )

        // Collapse the accordion immediately — the bind is committed locally.
        expandedApp = nil
        bindError = nil

        // 2) upload, then 3) re-save with the backend's real alias_key. Detached
        // so a slow/failed sync never blocks the UI; failure is a soft inline note.
        Task {
            do {
                let resp = try await apiClient.mergeChildAppCatalog(deviceID: childDeviceID, apps: [upload])
                let key = resp.apps.first {
                    $0.displayName == upload.displayName
                        && $0.bundleID == upload.bundleID
                        && $0.tokenKind.lowercased() != "category"
                }?.id
                LocalAliasStore.shared.saveApplicationAliases(
                    token: appToken,
                    displayName: upload.displayName,
                    bundleIdentifier: upload.bundleID,
                    catalogAliasKey: key
                )
            } catch {
                // Local alias already saved — do NOT block. Surface a soft note.
                await MainActor.run {
                    bindError = "Saved on this device. Couldn't sync to Evlin yet — it'll lock by name here, but won't be lockable from parent chat until the sync succeeds."
                }
            }
        }
    }

    // MARK: - Category bind handler

    private func bindCategory(_ catToken: ActivityCategoryToken, suggestion: AppleScreenTimeCategorySuggestion) {
        guard let b64 = (try? JSONEncoder().encode(catToken))?.base64EncodedString() else { return }
        let row = PendingCategoryRow(
            semanticKey: suggestion.semanticKey,
            displayName: suggestion.displayName,
            tokenBase64: b64
        )
        let upload = row.makeUploadCategory(sourceDeviceID: childDeviceID)

        // 1) Local alias FIRST — display name + every alias variant (mirrors
        // AddAppFlowView's category save) so name-lock works even if upload fails.
        LocalAliasStore.shared.saveCategoryToken(catToken, forName: upload.displayName)
        for alias in upload.aliases {
            LocalAliasStore.shared.saveCategoryToken(catToken, forName: alias)
        }

        // Collapse the accordion immediately — the bind is committed locally.
        expandedCategory = nil
        bindError = nil

        // 2) upload, then 3) re-save every name with the backend's real alias_key.
        Task {
            do {
                let resp = try await apiClient.mergeChildAppCatalog(deviceID: childDeviceID, apps: [upload])
                let key = resp.apps.first {
                    $0.displayName == upload.displayName
                        && $0.tokenKind.lowercased() == "category"
                }?.id
                LocalAliasStore.shared.saveCategoryToken(catToken, forName: upload.displayName, catalogAliasKey: key)
                for alias in upload.aliases {
                    LocalAliasStore.shared.saveCategoryToken(catToken, forName: alias, catalogAliasKey: key)
                }
            } catch {
                await MainActor.run {
                    bindError = "Saved on this device. Couldn't sync to Evlin yet — it'll lock by name here, but won't be lockable from parent chat until the sync succeeds."
                }
            }
        }
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.medium))
            .kerning(0.5)
            .foregroundStyle(Color.evOutline)
            .padding(.bottom, 6)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.evOutline)
            .padding(.vertical, 4)
    }

    private func reload() {
        selection = DefaultLockGroupStore.load()
    }
}

// MARK: - Rows

/// A category row: collapsed = icon + name (`Label(token)`) + chevron + remove "x".
/// Expanded = the same header (highlighted) with an inline `CategoryTagPanel` below.
private struct CategoryRow: View {
    let token: ActivityCategoryToken
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onPick: (AppleScreenTimeCategorySuggestion) -> Void

    var body: some View {
        EvacAccordionRow(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onRemove: onRemove,
            label: {
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.evOnSurface)
            },
            panel: {
                CategoryTagPanel(
                    name: "this category",
                    selectedKey: nil,
                    onPick: onPick
                )
            }
        )
    }
}

/// An app row: collapsed = icon + name (`Label(token)`) + chevron + remove "x".
/// Expanded = the same header (highlighted) with an inline `AppStoreBindPanel` below.
private struct AppRow: View {
    let token: ApplicationToken
    let apiClient: APIClient
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onPick: (CatalogSearchResult) -> Void
    let onManual: (String) -> Void

    var body: some View {
        EvacAccordionRow(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onRemove: onRemove,
            label: {
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.evOnSurface)
            },
            panel: {
                AppStoreBindPanel(
                    appName: "this app",
                    apiClient: apiClient,
                    onPick: onPick,
                    onManual: onManual
                )
            }
        )
    }
}

/// Shared accordion row chrome: a tappable bordered card holding the token label +
/// a trailing chevron + a remove "x". When expanded, the border turns green and the
/// supplied bind `panel` is rendered inline below the header, mirroring the
/// prototype's `.evac-row.open` + `.evac-panel`.
private struct EvacAccordionRow<Label: View, Panel: View>: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let label: Label
    @ViewBuilder let panel: Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: tapping the label area toggles the accordion; the remove "x"
            // and chevron are siblings so the "x" never triggers a toggle.
            HStack(spacing: 11) {
                Button(action: onToggle) {
                    HStack(spacing: 11) {
                        label
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isExpanded ? Color.evPrimary : Color.evOnSurfaceVariant)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }

            if isExpanded {
                panel
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isExpanded ? Color.evPrimary.opacity(0.06) : Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isExpanded ? Color.evPrimary : Color.evOutlineVariant, lineWidth: isExpanded ? 1 : 0.5)
        )
        .padding(.bottom, 8)
    }
}

#if DEBUG
#Preview {
    AppControlsV2View(childDeviceID: UUID())
        .environmentObject(APIClient(baseURL: "http://preview.local"))
}
#endif
