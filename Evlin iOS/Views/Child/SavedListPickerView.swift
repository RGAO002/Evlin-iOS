import SwiftUI

enum SavedListMemberPlanner {
    static func members(
        selectedAppIDs: Set<UUID>,
        selectedCategoryIDs: Set<UUID>
    ) -> [CatalogListMemberUpload] {
        selectedAppIDs.sorted { $0.uuidString < $1.uuidString }.map {
            CatalogListMemberUpload(targetType: .app, aliasKey: $0)
        } + selectedCategoryIDs.sorted { $0.uuidString < $1.uuidString }.map {
            CatalogListMemberUpload(targetType: .category, aliasKey: $0)
        }
    }
}

/// Builds a custom lock list from app/category targets that have already been
/// captured on the kid device. This deliberately does not open
/// FamilyActivityPicker; picker capture creates token-backed targets, and this
/// screen only composes those targets into a backend member-set list.
struct SavedListPickerView: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let owningDeviceID: UUID
    let mode: String   // "child_device" or "parent_device"
    let editingListID: UUID?
    let initialName: String?
    let onSaved: (String) -> Void

    @State private var name: String = ""
    @State private var availableApps: [LockSetupCatalogRow] = []
    @State private var availableCategories: [LockSetupCatalogRow] = []
    @State private var selectedAppIDs: Set<UUID> = []
    @State private var selectedCategoryIDs: Set<UUID> = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?

    init(
        familyID: UUID,
        owningDeviceID: UUID,
        mode: String,
        editingListID: UUID? = nil,
        initialName: String? = nil,
        onSaved: @escaping (String) -> Void
    ) {
        self.familyID = familyID
        self.owningDeviceID = owningDeviceID
        self.mode = mode
        self.editingListID = editingListID
        self.initialName = initialName
        self.onSaved = onSaved
        _name = State(initialValue: initialName ?? "")
    }

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
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(Color.evError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.evError.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
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
                            title: app.title,
                            subtitle: app.bundleID ?? "App",
                            artworkURL: app.artworkURL
                        ) {
                            toggle(app.id, in: &selectedAppIDs)
                        }
                    }
                }
                memberSection(
                    title: "Categories",
                    count: availableCategories.count,
                    emptyText: "No categories yet. Use Add category first."
                ) {
                    ForEach(availableCategories) { category in
                        selectableRow(
                            id: category.id,
                            isSelected: selectedCategoryIDs.contains(category.id),
                            kind: .category,
                            title: category.title,
                            subtitle: "Category",
                            artworkURL: category.artworkURL
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
        .navigationTitle(editingListID == nil ? "Create list" : "Edit list")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reloadTargetsFromBackend()
        }
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
                Text("Group apps and categories you already added. Lists do not re-open the system picker.")
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
        artworkURL: URL? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.evSecondary : Color.evOutline)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    NameWithIcon(name: title, kind: kind, artworkURL: artworkURL, titleFont: .subheadline.weight(.semibold))
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
        Task { await reloadTargetsFromBackend() }
    }

    @MainActor
    private func reloadTargetsFromBackend() async {
        loading = true
        defer { loading = false }
        do {
            let catalog = try await apiClient.fetchChildLockSetupCatalog(deviceID: owningDeviceID)
            let model = LockSetupCatalogPresentationModel(catalog: catalog)
            availableApps = model.appRows
            availableCategories = model.categoryRows
            if let editingListID {
                guard let list = model.listRows.first(where: { $0.id == editingListID }) else {
                    loadError = "Couldn't load this list. Try again."
                    return
                }
                guard !list.members.isEmpty else {
                    loadError = "Couldn't load this list's members. Try again."
                    return
                }
                selectedAppIDs = Set(
                    list.members
                        .filter { $0.targetType == .app }
                        .map(\.aliasKey)
                )
                selectedCategoryIDs = Set(
                    list.members
                        .filter { $0.targetType == .category }
                        .map(\.aliasKey)
                )
            }
            loadError = nil
        } catch {
            loadError = "Could not load lock targets: \(error.localizedDescription)"
        }
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
        let members = SavedListMemberPlanner.members(
            selectedAppIDs: selectedAppIDs,
            selectedCategoryIDs: selectedCategoryIDs
        )
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
            let input = ControlListInput(
                aliasKey: editingListID,
                listName: trimmed,
                aliases: [trimmed],
                members: members,
                selectionBlobBase64: nil,
                // No raw FamilyActivitySelection is available in this ID-based
                // catalog composer (see file header) — see
                // LockedSetSelectionSemantics for why this is always false today.
                allSelected: false
            )
            if editingListID == nil {
                _ = try await apiClient.createControlList(input, deviceID: owningDeviceID)
            } else {
                _ = try await apiClient.updateControlList(input, deviceID: owningDeviceID)
            }
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
