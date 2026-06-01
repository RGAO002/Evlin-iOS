import SwiftUI
import FamilyControls

/// Launches FamilyActivityPicker, lets the user name the selection, writes to
/// LocalAliasStore, and POSTs metadata to the backend.
///
/// Callers: Child onboarding step, and later, the "Add list" action in Settings.
struct SavedListPickerView: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let owningDeviceID: UUID
    let mode: String   // "child_device" or "parent_device"
    let onSaved: (String) -> Void

    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var name: String = ""
    @State private var showPicker = false
    @State private var saving = false
    @State private var saveError: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var hasLockableSelection: Bool {
        selection.applicationTokens.isEmpty == false || selection.categoryTokens.isEmpty == false
    }

    private var canSave: Bool {
        trimmedName.isEmpty == false && hasLockableSelection && saving == false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                nameCard
                pickerCard
                selectionSummaryCard
                saveCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background(Color.evSurface.ignoresSafeArea())
        .navigationTitle("Add List")
        .navigationBarTitleDisplayMode(.inline)
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
                Text("New list")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text("Add List can include apps and Apple categories. Evlin saves the whole selection as one named lock target.")
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

            TextField("e.g. Games", text: $name)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
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

    private var pickerCard: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.evSecondaryContainer)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evSecondary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open App Picker")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.evOnSurface)
                    Text("Choose individual apps, broad Apple categories, or both.")
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.evOutline)
            }
            .padding(16)
            .savedListCard()
        }
        .buttonStyle(.plain)
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
    }

    private var selectionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Selection")
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text(selectionSummary)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.evSurfaceContainerHigh))
                Spacer(minLength: 0)
            }

            Text("Apple categories are broad coverage. They include matching apps installed now and matching apps added later.")
                .font(.subheadline)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            if hasLockableSelection == false {
                Text("Pick at least one app or category before saving.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.evSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .savedListCard()
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    private var selectionSummary: String {
        "\(selection.applicationTokens.count) apps · \(selection.categoryTokens.count) categories · \(selection.webDomainTokens.count) websites"
    }

    private func save() async {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }
        saving = true
        defer { saving = false }

        // 1. Write tokens locally (the source of truth for lookups)
        LocalAliasStore.shared.saveList(selection, named: trimmed)
        ManagedSelectionAliasSync.syncAll(from: selection)

        // 2. POST metadata to backend (so parent UI knows the list name exists)
        do {
            _ = try await apiClient.upsertSavedListMeta(.init(
                familyID: familyID,
                owningDeviceID: owningDeviceID,
                name: trimmed,
                description: nil,
                mode: mode
            ))

            // Also cache the full selection shape on the backend so the list can
            // be locked as a unit later. This is best-effort; the kid device's
            // LocalAliasStore remains the execution source of truth.
            if let blob = try? AppCatalogBlobEncoder.base64(selection) {
                let members = LocalAliasStore.shared.catalogListMembers(for: selection)
                _ = try? await apiClient.uploadCatalogList(
                    deviceID: owningDeviceID,
                    sourceDeviceID: owningDeviceID,
                    listName: trimmed,
                    aliases: [trimmed],
                    selectionBlobBase64: blob,
                    appCount: selection.applicationTokens.count
                        + selection.categoryTokens.count
                        + selection.webDomainTokens.count,
                    members: members.isEmpty ? nil : members
                )
            }
            onSaved(trimmed)
        } catch {
            saveError = "Saved locally, but backend sync failed: \(error.localizedDescription)"
            // Still consider it saved — local is source of truth for execution
            onSaved(trimmed)
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
