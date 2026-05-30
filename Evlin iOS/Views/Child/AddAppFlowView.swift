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
            } header: {
                Text("Add one app")
            } footer: {
                Text("The Apple picker can select more than one item. Evlin accepts only one app here; use Add List for groups.")
            }

            if validation.isValid, let token = singleToken {
                Section("Which app is this?") {
                    CatalogBindRowView(
                        token: token,
                        row: bindingForRow(),
                        apiClient: apiClient
                    )
                }

                Section {
                    Button {
                        Task {
                            await upload(token: token)
                        }
                    } label: {
                        if uploading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Save app")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uploading || !(pendingRow?.isLockableApp ?? false))

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
            rebuildPendingRow(from: newValue)
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

    @MainActor
    private func upload(token: ApplicationToken) async {
        guard let row = pendingRow,
              let app = row.makeUploadApp(sourceDeviceID: childDeviceID)
        else {
            errorText = "Confirm the app name first."
            return
        }

        uploading = true
        defer { uploading = false }

        LocalAliasStore.shared.saveApplicationAliases(
            token: token,
            displayName: app.displayName,
            bundleIdentifier: app.bundleID
        )

        do {
            _ = try await apiClient.uploadChildAppCatalog(deviceID: childDeviceID, apps: [app])
            onSaved()
        } catch {
            errorText = "Saved locally, backend sync failed: \(error.localizedDescription)"
            onSaved()
        }
    }
}
