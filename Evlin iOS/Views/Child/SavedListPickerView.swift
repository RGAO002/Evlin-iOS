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

    @State private var selection = FamilyActivitySelection()
    @State private var name: String = ""
    @State private var showPicker = false
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Saved List")
                .font(.evHeadlineMedium)
                .padding(.top)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. list 1", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Button("Open App Picker") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .familyActivityPicker(isPresented: $showPicker, selection: $selection)

            VStack(alignment: .leading, spacing: 4) {
                Text("Selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(selection.applicationTokens.count) apps · \(selection.categoryTokens.count) categories · \(selection.webDomainTokens.count) websites")
                    .font(.subheadline)
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Spacer()

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
            .buttonStyle(.borderedProminent)
            .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty ||
                      (selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty))
        }
        .padding()
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        saving = true
        defer { saving = false }

        // 1. Write tokens locally (the source of truth for lookups)
        LocalAliasStore.shared.saveList(selection, named: trimmed)

        // 2. POST metadata to backend (so parent UI knows the list name exists)
        do {
            _ = try await apiClient.upsertSavedListMeta(.init(
                familyID: familyID,
                owningDeviceID: owningDeviceID,
                name: trimmed,
                description: nil,
                mode: mode
            ))
            onSaved(trimmed)
        } catch {
            saveError = "Saved locally, but backend sync failed: \(error.localizedDescription)"
            // Still consider it saved — local is source of truth for execution
            onSaved(trimmed)
        }
    }
}
