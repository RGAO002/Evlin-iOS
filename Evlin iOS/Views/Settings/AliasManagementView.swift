// Evlin iOS/Views/Settings/AliasManagementView.swift
//
// Parent-facing app-alias manager. Rebuilt for Task F3:
//   - No child/device selector — familyID from @AppStorage
//   - One card per AppAliasRow (from GET /parent/app-aliases)
//   - Capability row: green "Lock & block" line or amber "add on kid phone" notice
//   - Alias chips, add/rename alerts, and search field reuse the existing visual style
//
// Visual palette: navy evPrimary, forest evSecondary / evSecondaryContainer,
// amber evTertiaryContainer / evOnTertiaryContainer.

import SwiftUI

struct AliasManagementView: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.familyID") private var familyIDString = ""

    var body: some View {
        Group {
            if let familyID = UUID(uuidString: familyIDString) {
                AliasAppListScreen(familyID: familyID, client: apiClient)
            } else {
                ContentUnavailableView(
                    "No family paired",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Pair a family before managing chat aliases.")
                )
            }
        }
        .navigationTitle("Manage aliases")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Main list screen

private struct AliasAppListScreen: View {
    private let iconSize: CGFloat = 46

    @StateObject private var model: AliasManagerModel
    @State private var addAliasRow: AppAliasRow?
    @State private var newAlias = ""
    @State private var renameAliasRow: AppAliasRow?
    @State private var renameOldAlias = ""
    @State private var renamedAlias = ""
    @State private var showAddAppSheet = false
    @State private var showDevicePickerSheet = false
    @State private var addAppTargetDeviceID: UUID?

    init(familyID: UUID, client: AppAliasManagingClient) {
        _model = StateObject(wrappedValue: AliasManagerModel(familyID: familyID, client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                explainer
                searchField

                if model.isLoading && model.rows.isEmpty {
                    loadingRow
                }

                if let error = model.errorMessage {
                    errorBanner(error)
                }

                if !model.isLoading && !model.rows.isEmpty && model.visibleRows.isEmpty {
                    Text("No apps match \"\(model.searchText)\".")
                        .font(.evBodyMedium)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .padding(.vertical, Spacing.md)
                }

                ForEach(model.visibleRows) { row in
                    appCard(row)
                }

                Color.clear.frame(height: Spacing.lg)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
        }
        .background(Color.evSurfaceContainerLow)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.load() }
        .task { await model.load() }
        // Add alias alert
        .alert("Add alias", isPresented: addAliasBinding) {
            TextField("Alias", text: $newAlias)
            Button("Cancel", role: .cancel) {
                addAliasRow = nil
                newAlias = ""
            }
            Button("Save") {
                guard let row = addAliasRow else { return }
                let alias = newAlias
                Task {
                    await model.addAlias(alias, to: row)
                    newAlias = ""
                    addAliasRow = nil
                }
            }
        } message: {
            Text("Add another chat name for this app.")
        }
        // Rename alias alert
        .alert("Rename alias", isPresented: renameAliasBinding) {
            TextField("Alias", text: $renamedAlias)
            Button("Cancel", role: .cancel) { resetRenameState() }
            Button("Save") {
                guard let row = renameAliasRow else { return }
                let old = renameOldAlias
                let new = renamedAlias
                Task {
                    await model.renameAlias(old, to: new, for: row)
                    resetRenameState()
                }
            }
        } message: {
            Text("Rename this chat alias for the selected app.")
        }
        // Add app on kid device (lock-enable flow)
        .sheet(isPresented: $showAddAppSheet) {
            if let deviceID = addAppTargetDeviceID {
                NavigationStack {
                    AddAppFlowView(
                        childDeviceID: deviceID,
                        mode: .app,
                        onSaved: { _ in showAddAppSheet = false }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddAppSheet = false }
                        }
                    }
                }
            }
        }
        // Device picker — shown when the family has more than one child device.
        .sheet(isPresented: $showDevicePickerSheet) {
            NavigationStack {
                List(model.childDevices) { device in
                    Button(device.displayName) {
                        addAppTargetDeviceID = device.childDeviceID
                        showDevicePickerSheet = false
                        showAddAppSheet = true
                    }
                }
                .navigationTitle("Choose kid's device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showDevicePickerSheet = false }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var explainer: some View {
        Text("Any app you can name can be blocked. Apps added on a kid's phone can also be locked.")
            .font(.evBodyMedium)
            .foregroundStyle(Color.evOnSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.evOutline)
            TextField("Search apps or names", text: $model.searchText)
                .font(.evBodyLarge)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.evOutline)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 10)
        .background(Color.evSurfaceContainer, in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }

    // MARK: - App card

    private func appCard(_ row: AppAliasRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Title row: icon + canonical name + bundle ID
            HStack(alignment: .center, spacing: Spacing.lg) {
                appIcon(row)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.canonicalName)
                        .font(.custom("Inter", size: 16).weight(.semibold))
                        .foregroundStyle(Color.evOnSurface)
                    Text(row.bundleID)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOutline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Alias chips
            aliasRow(row)

            // Capability row
            capabilityRow(row)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLowest, in: RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 0.5)
        )
    }

    // MARK: - Capability row

    @ViewBuilder
    private func capabilityRow(_ row: AppAliasRow) -> some View {
        if row.lockable {
            // Lock & block: at least one child device can receive a lock command
            let names = row.lockableDevices.map(\.childName).joined(separator: ", ")
            HStack(spacing: Spacing.md) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.evSecondary)
                Text("Lock & block · on \(names)")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evSecondary)
            }
        } else {
            // Block-only: no child devices have this app in catalog
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evOnTertiaryContainer)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("\"lock \(row.canonicalName)\" won't work yet — add it on a kid's phone to enable timed lock.")
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnTertiaryContainer)
                        .fixedSize(horizontal: false, vertical: true)
                    addToEnableLockButton(row)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.evTertiaryContainer, in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    @ViewBuilder
    private func addToEnableLockButton(_ row: AppAliasRow) -> some View {
        let devices = model.childDevices
        if devices.isEmpty {
            // No kid devices paired — disable the button and surface a hint.
            Text("Add on kid's phone")
                .font(.evLabelLarge)
                .foregroundStyle(Color.evOnTertiaryContainer.opacity(0.4))
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, 5)
                .background(
                    Color.evOnTertiaryContainer.opacity(0.06),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(Color.evOnTertiaryContainer.opacity(0.2), lineWidth: 1)
                )
                .accessibilityHint("No kid device is paired with this family.")
        } else {
            Button {
                if devices.count == 1 {
                    // Single device — go straight to AddAppFlowView.
                    addAppTargetDeviceID = devices[0].childDeviceID
                    showAddAppSheet = true
                } else {
                    // Multiple devices — show a picker first.
                    showDevicePickerSheet = true
                }
            } label: {
                Text("Add on kid's phone")
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evOnTertiaryContainer)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 5)
                    .background(
                        Color.evOnTertiaryContainer.opacity(0.12),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(Color.evOnTertiaryContainer.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Alias chips

    @ViewBuilder
    private func aliasRow(_ row: AppAliasRow) -> some View {
        if row.aliases.isEmpty {
            HStack(spacing: Spacing.md) {
                Text("No names yet")
                    .font(.evBodySmall)
                    .italic()
                    .foregroundStyle(Color.evOutline)
                addAliasChip(row)
            }
        } else {
            FlowLayout(spacing: 8) {
                ForEach(row.aliases, id: \.self) { alias in
                    aliasChip(alias, row: row)
                }
                addAliasChip(row)
            }
        }
    }

    private func aliasChip(_ alias: String, row: AppAliasRow) -> some View {
        HStack(spacing: 0) {
            Text(alias)
                .font(.evLabelLarge)
                .foregroundStyle(Color.evSecondary)
                .lineLimit(1)
                .padding(.leading, Spacing.lg)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    renameAliasRow = row
                    renameOldAlias = alias
                    renamedAlias = alias
                }
                .accessibilityLabel("Rename alias \(alias)")
            Button {
                Task { await model.removeAlias(alias, from: row) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.evSecondary)
                    .frame(width: 20, height: 20)
                    .background(Color.evSecondary.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 5)
            .accessibilityLabel("Remove alias \(alias)")
        }
        .background(Color.evSecondaryContainer, in: Capsule())
    }

    private func addAliasChip(_ row: AppAliasRow) -> some View {
        Button {
            addAliasRow = row
            newAlias = ""
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("add name")
                    .font(.evLabelLarge)
            }
            .foregroundStyle(Color.evPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 6)
            .overlay(
                Capsule()
                    .stroke(Color.evOutline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a name for \(row.canonicalName)")
    }

    // MARK: - App icon

    private func appIcon(_ row: AppAliasRow) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.evSurfaceContainer)
            if let url = row.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        appMonogram(row)
                    }
                }
            } else {
                appMonogram(row)
            }
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func appMonogram(_ row: AppAliasRow) -> some View {
        let initial = row.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).first
            .map { String($0).uppercased() } ?? "?"
        return Text(initial)
            .font(.custom("Inter", size: 17).weight(.semibold))
            .foregroundStyle(Color.evOnSurfaceVariant)
    }

    // MARK: - Status rows

    private var loadingRow: some View {
        HStack(spacing: Spacing.md) {
            ProgressView()
            Text("Loading apps…")
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .background(Color.evSurfaceContainerLowest, in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.evError)
            Text(message)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evError)
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(Color.evErrorContainer, in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }

    // MARK: - Alert bindings

    private var addAliasBinding: Binding<Bool> {
        Binding(
            get: { addAliasRow != nil },
            set: { if !$0 { addAliasRow = nil; newAlias = "" } }
        )
    }

    private var renameAliasBinding: Binding<Bool> {
        Binding(
            get: { renameAliasRow != nil },
            set: { if !$0 { resetRenameState() } }
        )
    }

    private func resetRenameState() {
        renameAliasRow = nil
        renameOldAlias = ""
        renamedAlias = ""
    }
}

// MARK: - Preview

#if DEBUG
private final class PreviewAppAliasClient: AppAliasManagingClient {
    func fetchAppAliases(familyID: UUID) async throws -> [AppAliasRow] {
        [
            AppAliasRow(
                familyAppID: UUID(),
                bundleID: "com.burbn.instagram",
                canonicalName: "Instagram",
                artworkURL: nil,
                aliases: ["ig", "insta"],
                blockable: true,
                lockableDevices: [
                    LockableDevice(childDeviceID: UUID(), childName: "Liam", deviceLabel: "Liam's iPhone"),
                    LockableDevice(childDeviceID: UUID(), childName: "Maya", deviceLabel: "Maya's iPhone"),
                ]
            ),
            AppAliasRow(
                familyAppID: UUID(),
                bundleID: "com.roblox.robloxmobile",
                canonicalName: "Roblox",
                artworkURL: nil,
                aliases: [],
                blockable: true,
                lockableDevices: []
            ),
            AppAliasRow(
                familyAppID: nil,
                bundleID: "com.google.youtube",
                canonicalName: "YouTube",
                artworkURL: nil,
                aliases: ["yt", "tube"],
                blockable: true,
                lockableDevices: []
            ),
        ]
    }

    func fetchParentChildDevices(familyID: UUID) async throws -> [ParentChildDeviceSummaryDTO] {
        func makeDevice(id: UUID, name: String) -> ParentChildDeviceSummaryDTO {
            let json = """
            {"child_device_id":"\(id.uuidString)","display_name":"\(name)",
             "child_auth_granted":true,"catalog_app_count":0,
             "catalog_category_count":0,"catalog_list_count":0,"catalog_preview":[]}
            """.data(using: .utf8)!
            return try! JSONDecoder().decode(ParentChildDeviceSummaryDTO.self, from: json)
        }
        return [
            makeDevice(id: UUID(), name: "Liam's iPhone"),
            makeDevice(id: UUID(), name: "Maya's iPhone"),
        ]
    }

    func addAppAlias(familyID: UUID, bundleID: String, alias: String) async throws {}
    func removeAppAlias(familyID: UUID, bundleID: String, alias: String) async throws {}
    func renameAppAlias(familyID: UUID, bundleID: String, old: String, new: String) async throws {}
}

#Preview {
    NavigationStack {
        AliasAppListScreen(
            familyID: UUID(),
            client: PreviewAppAliasClient()
        )
        .navigationTitle("Manage aliases")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
