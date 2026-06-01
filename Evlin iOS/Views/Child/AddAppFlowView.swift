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

    private var hasSelection: Bool {
        counts.applicationTokens > 0 || counts.categoryTokens > 0 || counts.webDomainTokens > 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                pickerCard

                if hasSelection, !validation.isValid, let reason = validation.reason {
                    AddAppSaveValidationBanner(message: reason.rawValue)
                }

                if validation.isValid, let token = singleToken {
                    bindCard(token)
                }

                if hasSelection || saveBanner != nil || errorText != nil {
                    saveCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background(Color.evSurface.ignoresSafeArea())
        .navigationTitle("Add App")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { _, newValue in
            saveBanner = nil
            errorText = nil
            highlightedRows = []
            rebuildPendingRow(from: newValue)
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evPrimary)
                Image(systemName: "plus.app.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("Add one app")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text("Add App captures exactly one app token from this device. Use Add List when you want several apps or Apple categories together.")
                    .font(.subheadline)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .addAppCard()
    }

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.evPrimaryContainer)
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.evPrimary)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pick app")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.evOnSurface)
                        Text("Apple's picker can select more than one item. Evlin checks the count before saving.")
                            .font(.caption)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.evOutline)
                }
                .padding(14)
                .background(Color.evSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .familyActivityPicker(isPresented: $showPicker, selection: $selection)

            HStack(spacing: 8) {
                Text(selectionSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.evSurfaceContainerHigh))
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .addAppCard()
    }

    private func bindCard(_ token: ApplicationToken) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which app is this?")
                .font(.headline)
                .foregroundStyle(Color.evOnSurface)
            Text("The token and icon come from iOS. The app name and bundle ID come from the catalog match. Confirm they match before saving.")
                .font(.subheadline)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            CatalogBindRowView(
                token: token,
                row: bindingForRow(),
                apiClient: apiClient,
                isHighlighted: pendingRow.map { highlightedRows.contains($0.id) } ?? false
            )
        }
        .padding(16)
        .addAppCard()
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let saveBanner {
                AddAppSaveValidationBanner(message: saveBanner)
            }

            Button {
                attemptSave()
            } label: {
                saveButtonLabel
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(validation.isValid ? Color.white : Color.evOutline)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(validation.isValid ? Color.evPrimary : Color.evSurfaceContainerHighest)
            )
            .disabled(uploading || !validation.isValid)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .addAppCard()
    }

    private var selectionSummary: String {
        "\(counts.applicationTokens) apps · \(counts.categoryTokens) categories · \(counts.webDomainTokens) websites"
    }

    @ViewBuilder
    private var saveButtonLabel: some View {
        if uploading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if pendingRow?.isLockableApp == true {
            Text("Save lockable app")
                .frame(maxWidth: .infinity)
        } else if validation.isValid {
            Text("Confirm match before saving")
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
        .background(Color.evTertiaryContainer, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.evTertiaryFixedDim.opacity(0.75), lineWidth: 1)
        }
    }
}

private extension View {
    func addAppCard() -> some View {
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
