import SwiftUI
import FamilyControls
import ManagedSettings

/// Add App captures exactly one application token, binds it to a canonical
/// catalog app, requires a visual `Label(token)` confirmation, then uploads one
/// app catalog record scoped to this child device.
struct AddAppFlowView: View {
    let childDeviceID: UUID
    let onSaved: () -> Void

    @EnvironmentObject var apiClient: APIClient

    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var pendingRow: PendingAppRow?
    @State private var uploading = false
    @State private var errorText: String?
    @State private var saveBanner: String?
    @State private var highlightedRows = Set<UUID>()

    private var counts: SelectionCounts {
        SelectionCounts(selection)
    }

    private var validation: CaptureValidation {
        CapturePathValidator.validate(.app, counts)
    }

    private var singleToken: ApplicationToken? {
        selection.applicationTokens.first
    }

    var body: some View {
        Form {
            Section {
                Button("Pick app") {
                    showPicker = true
                }
                .familyActivityPicker(isPresented: $showPicker, selection: $selection)

                Text("\(counts.applicationTokens) apps · \(counts.categoryTokens) categories · \(counts.webDomainTokens) websites")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !validation.isValid, let reason = validation.reason {
                    Text(reason.rawValue)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let saveBanner {
                    AddAppSaveValidationBanner(message: saveBanner)
                }
            } header: {
                Text("Add one app")
            } footer: {
                Text("The Apple picker can select more than one item. Evlin accepts only one app here; use Add List for groups.")
            }

            if validation.isValid, let token = singleToken {
                Section {
                    CatalogBindRowView(
                        token: token,
                        row: bindingForRow(),
                        apiClient: apiClient,
                        isHighlighted: pendingRow.map { highlightedRows.contains($0.id) } ?? false
                    )
                } header: {
                    Text("Which app is this?")
                } footer: {
                    Text("Match the iOS token to the App Store, confirm the visual match, then save. Evlin never guesses or drops an unlabeled app.")
                }
            } else if counts.applicationTokens > 0 || counts.categoryTokens > 0 || counts.webDomainTokens > 0 {
                Section {
                    Button("Save app") {
                        attemptSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }

            if validation.isValid {
                Section {
                    Button {
                        attemptSave()
                    } label: {
                        saveButtonLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uploading)

                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Add App")
        .onChange(of: selection) { _, newValue in
            saveBanner = nil
            errorText = nil
            highlightedRows = []
            rebuildPendingRow(from: newValue)
        }
    }

    @ViewBuilder
    private var saveButtonLabel: some View {
        if uploading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if pendingRow?.isLockableApp == true {
            Text("Save lockable app")
                .frame(maxWidth: .infinity)
        } else {
            Text("Save app")
                .frame(maxWidth: .infinity)
        }
    }

    private func bindingForRow() -> Binding<PendingAppRow> {
        Binding(
            get: {
                pendingRow ?? PendingAppRow(
                    rowID: UUID(),
                    tokenBase64: "",
                    tokenAvailable: false
                )
            },
            set: { pendingRow = $0 }
        )
    }

    private func rebuildPendingRow(from newValue: FamilyActivitySelection) {
        let newValidation = CapturePathValidator.validate(.app, SelectionCounts(newValue))
        guard newValidation.isValid, let token = newValue.applicationTokens.first else {
            pendingRow = nil
            return
        }
        let blob = (try? AppCatalogBlobEncoder.base64(token)) ?? ""
        pendingRow = PendingAppRow(
            rowID: UUID(),
            tokenBase64: blob,
            tokenAvailable: !blob.isEmpty
        )
    }

    private func attemptSave() {
        guard validation.isValid else {
            saveBanner = validation.reason?.rawValue ?? "Fix the selection before saving."
            highlightedRows = []
            return
        }

        guard let token = singleToken else {
            saveBanner = "Pick an app first"
            highlightedRows = []
            return
        }

        Task {
            await upload(token: token)
        }
    }

    @MainActor
    private func upload(token: ApplicationToken) async {
        guard let row = pendingRow,
              let app = row.makeUploadApp(sourceDeviceID: childDeviceID)
        else {
            var model = CaptureSheetModel(rows: pendingRow.map { [$0] } ?? [])
            model.attemptSave()
            saveBanner = model.errorBanner ?? "Confirm the app name first."
            highlightedRows = Set(model.highlightedRows.compactMap { index in
                model.rows.indices.contains(index) ? model.rows[index].id : nil
            })
            return
        }

        var model = CaptureSheetModel(rows: [row])
        model.attemptSave()
        guard model.isPresented == false else {
            saveBanner = model.errorBanner
            highlightedRows = Set(model.highlightedRows.compactMap { index in
                model.rows.indices.contains(index) ? model.rows[index].id : nil
            })
            return
        }

        uploading = true
        defer { uploading = false }
        saveBanner = nil
        highlightedRows = []

        LocalAliasStore.shared.saveApplicationAliases(
            token: token,
            displayName: app.displayName,
            bundleIdentifier: app.bundleID
        )

        do {
            let response = try await apiClient.uploadChildAppCatalog(deviceID: childDeviceID, apps: [app])
            let backendAliasKey = response.apps.first?.id ?? app.aliasKey
            LocalAliasStore.shared.saveApplicationAliases(
                token: token,
                displayName: app.displayName,
                bundleIdentifier: app.bundleID,
                catalogAliasKey: backendAliasKey
            )
            onSaved()
        } catch {
            errorText = "Saved locally, backend sync failed: \(error.localizedDescription)"
            onSaved()
        }
    }
}

private struct AddAppSaveValidationBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }
}
