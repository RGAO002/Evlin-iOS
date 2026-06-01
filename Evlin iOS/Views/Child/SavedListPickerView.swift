import SwiftUI

/// Builds a custom lock list from app/category targets that have already been
/// captured on the kid device. This deliberately does not open
/// FamilyActivityPicker; picker capture creates token-backed targets, and this
/// screen only composes those targets into a backend member-set list.
struct SavedListPickerView: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let owningDeviceID: UUID
    let mode: String   // "child_device" or "parent_device"
    let onSaved: (String) -> Void

    @State private var name: String = ""
    @State private var availableApps: [LocalCatalogAppTarget] = []
    @State private var availableCategories: [LocalCatalogCategoryTarget] = []
    @State private var selectedAppIDs: Set<UUID> = []
    @State private var selectedCategoryIDs: Set<UUID> = []
    @State private var saving = false
    @State private var saveError: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var selectedMemberCount: Int {
        selectedAppIDs.count + selectedCategoryIDs.count
    }

    private var canSave: Bool {
        trimmedName.isEmpty == false && selectedMemberCount > 0 && saving == false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                nameCard
                memberSection(
                    title: "Apps",
                    count: availableApps.count,
                    emptyText: "No named apps yet. Use Add app first."
                ) {
                    ForEach(availableApps) { app in
                        selectableRow(
                            id: app.id,
                            isSelected: selectedAppIDs.contains(app.id),
                            kind: .app,
                            title: app.label,
                            subtitle: app.bundleID ?? app.lookupKeys.first ?? "Token-backed app"
                        ) {
                            toggle(app.id, in: &selectedAppIDs)
                        }
                    }
                }
                memberSection(
                    title: "Categories",
                    count: availableCategories.count,
                    emptyText: "No categories yet. Capture a category with Add app."
                ) {
                    ForEach(availableCategories) { category in
                        selectableRow(
                            id: category.id,
                            isSelected: selectedCategoryIDs.contains(category.id),
                            kind: .category,
                            title: category.displayName,
                            subtitle: "Broad coverage: current + future apps Apple classifies here"
                        ) {
                            toggle(category.id, in: &selectedCategoryIDs)
                        }
                    }
                }
                saveCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background(Color.evSurface.ignoresSafeArea())
        .navigationTitle("Create list")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadTargets)
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evSecondary)
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("Create a list")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text("Group apps and broad Apple categories you already added. Lists do not re-open the system picker.")
                    .font(.subheadline)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .savedListCard()
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("List name")
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.evOnSurfaceVariant)

            TextField("e.g. Entertainment", text: $name)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.evSurfaceContainerLowest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1.5)
                }
        }
        .padding(16)
        .savedListCard()
    }

    private func memberSection<Content: View>(
        title: String,
        count: Int,
        emptyText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.evSurfaceContainerHigh))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if count == 0 {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                content()
            }
        }
        .savedListCard()
    }

    private func selectableRow(
        id: UUID,
        isSelected: Bool,
        kind: NameIconKind,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.evSecondary : Color.evOutline)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    NameWithIcon(name: title, kind: kind, titleFont: .subheadline.weight(.semibold))
                        .foregroundStyle(Color.evOnSurface)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evSecondaryContainer.opacity(0.36) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(selectedMemberCount) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await save() }
            } label: {
                if saving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Save list")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(canSave ? Color.white : Color.evOutline)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(canSave ? Color.evSecondary : Color.evSurfaceContainerHighest)
            )
            .disabled(canSave == false)
        }
        .padding(16)
        .savedListCard()
    }

    private func reloadTargets() {
        availableApps = LocalAliasStore.shared.catalogAppTargets()
        availableCategories = LocalAliasStore.shared.catalogCategoryTargets()
    }

    private func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }

    private func save() async {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }
        let selectedAppMembers = availableApps
            .filter { selectedAppIDs.contains($0.id) }
            .map { CatalogListMemberUpload(targetType: .app, aliasKey: $0.aliasKey) }
        let selectedCategoryMembers = availableCategories
            .filter { selectedCategoryIDs.contains($0.id) }
            .map { CatalogListMemberUpload(targetType: .category, aliasKey: $0.aliasKey) }
        let members = selectedAppMembers + selectedCategoryMembers
        guard !members.isEmpty else { return }

        saving = true
        defer { saving = false }
        saveError = nil

        do {
            _ = try await apiClient.upsertSavedListMeta(.init(
                familyID: familyID,
                owningDeviceID: owningDeviceID,
                name: trimmed,
                description: nil,
                mode: mode
            ))
            _ = try await apiClient.uploadCatalogList(
                deviceID: owningDeviceID,
                sourceDeviceID: owningDeviceID,
                listName: trimmed,
                aliases: [trimmed],
                selectionBlobBase64: nil,
                appCount: members.count,
                members: members
            )
            onSaved(trimmed)
        } catch {
            saveError = "Could not save list: \(error.localizedDescription)"
        }
    }
}

private extension View {
    func savedListCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
            .evShadow(.premium)
    }
}
