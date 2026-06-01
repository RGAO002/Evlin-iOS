import SwiftUI
import FamilyControls
import ManagedSettings

/// Add App captures one or more application tokens plus broad categories. Each
/// app row must be named and explicitly confirmed before saving; category rows
/// use Apple's picker label and broad-coverage semantics.
struct AddAppFlowView: View {
    let childDeviceID: UUID
    let onSaved: () -> Void

    @EnvironmentObject var apiClient: APIClient

    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var pendingRows: [PendingAppRow] = []
    @State private var appTokensByRowID: [UUID: ApplicationToken] = [:]
    @State private var pendingCategoryRows: [PendingCategoryRow] = []
    @State private var categoryTokensByRowID: [UUID: ActivityCategoryToken] = [:]
    @State private var uploading = false
    @State private var errorText: String?
    @State private var saveBanner: String?
    @State private var highlightedRows = Set<UUID>()

    private var counts: SelectionCounts {
        SelectionCounts(selection)
    }

    private var hasSelection: Bool {
        counts.applicationTokens > 0 || counts.categoryTokens > 0 || counts.webDomainTokens > 0
    }

    private var canAttemptSave: Bool {
        uploading == false
            && counts.webDomainTokens == 0
            && (pendingRows.isEmpty == false || pendingCategoryRows.isEmpty == false)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                pickerCard

                if counts.webDomainTokens > 0 {
                    AddAppSaveValidationBanner(message: "Websites are not supported here. Remove website selections before saving.")
                }

                if !pendingRows.isEmpty {
                    appsBindCard
                }

                if !pendingCategoryRows.isEmpty {
                    categoriesCard
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
                Text("Add apps")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text("Pick apps and Apple categories from this device. Apps must be named before saving; categories cover current and future matching apps.")
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
                        Text("You can choose multiple apps and broad categories in one pass.")
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

    private var appsBindCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which app is this?")
                .font(.headline)
                .foregroundStyle(Color.evOnSurface)
            Text("The token and icon come from iOS. The app name and bundle ID come from the catalog match. Confirm every app before saving.")
                .font(.subheadline)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(pendingRows) { row in
                if let token = appTokensByRowID[row.id] {
                    CatalogBindRowView(
                        token: token,
                        row: binding(for: row),
                        apiClient: apiClient,
                        isHighlighted: highlightedRows.contains(row.id)
                    )
                }
            }
        }
        .padding(16)
        .addAppCard()
    }

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Broad categories")
                .font(.headline)
                .foregroundStyle(Color.evOnSurface)
            Text("Apple categories cover matching apps installed now and matching apps added later.")
                .font(.subheadline)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(pendingCategoryRows) { row in
                HStack(spacing: 12) {
                    NameWithIcon(name: row.semanticKey, kind: .category, titleFont: .subheadline.weight(.semibold))
                        .foregroundStyle(Color.evOnSurface)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .font(.caption)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                        Text("broad")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.evPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.evPrimary.opacity(0.08)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.evSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
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
            .foregroundStyle(canAttemptSave ? Color.white : Color.evOutline)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(canAttemptSave ? Color.evPrimary : Color.evSurfaceContainerHighest)
            )
            .disabled(!canAttemptSave)

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
        } else if pendingRows.allSatisfy(\.isLockableApp), pendingRows.isEmpty == false {
            Text(pendingCategoryRows.isEmpty ? "Save apps" : "Save apps and categories")
                .frame(maxWidth: .infinity)
        } else if pendingRows.isEmpty, pendingCategoryRows.isEmpty == false {
            Text("Save categories")
                .frame(maxWidth: .infinity)
        } else if pendingRows.isEmpty == false {
            Text("Name every app before saving")
                .frame(maxWidth: .infinity)
        } else {
            Text("Save app")
                .frame(maxWidth: .infinity)
        }
    }

    private func binding(for row: PendingAppRow) -> Binding<PendingAppRow> {
        Binding(
            get: {
                pendingRows.first(where: { $0.id == row.id }) ?? row
            },
            set: { newValue in
                if let index = pendingRows.firstIndex(where: { $0.id == row.id }) {
                    pendingRows[index] = newValue
                }
            }
        )
    }

    private func rebuildPendingRow(from newValue: FamilyActivitySelection) {
        let existingByBlob = Dictionary(uniqueKeysWithValues: pendingRows.map { ($0.tokenBase64, $0) })
        let appPairs = newValue.applicationTokens.compactMap { token -> (ApplicationToken, String)? in
            guard let blob = try? AppCatalogBlobEncoder.base64(token), !blob.isEmpty else { return nil }
            return (token, blob)
        }
        .sorted { $0.1 < $1.1 }

        pendingRows = appPairs.map { _, blob in
            existingByBlob[blob] ?? PendingAppRow(
                rowID: UUID(),
                tokenBase64: blob,
                tokenAvailable: true
            )
        }
        appTokensByRowID = Dictionary(uniqueKeysWithValues: zip(pendingRows, appPairs).map { row, pair in
            (row.id, pair.0)
        })

        let existingCategories = Dictionary(uniqueKeysWithValues: pendingCategoryRows.map { ($0.tokenBase64, $0) })
        let categoryPairs = newValue.categories.compactMap { category -> (ActivityCategoryToken, String, String, String)? in
            guard let token = category.token,
                  let blob = try? AppCatalogBlobEncoder.base64(token),
                  !blob.isEmpty
            else { return nil }
            let pickerName = category.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let semantic = SemanticCategoryAliasSync.semanticAliasKey(forPickerLabel: pickerName)
                ?? pickerName?.lowercased()
                ?? "category"
            let display = pickerName?.isEmpty == false ? pickerName! : NameWithIcon.displayName(semantic)
            return (token, blob, semantic, display)
        }
        .sorted { $0.2 < $1.2 }
        pendingCategoryRows = categoryPairs.map { _, blob, semantic, display in
            existingCategories[blob] ?? PendingCategoryRow(
                rowID: UUID(),
                semanticKey: semantic,
                displayName: display,
                tokenBase64: blob
            )
        }
        categoryTokensByRowID = Dictionary(uniqueKeysWithValues: zip(pendingCategoryRows, categoryPairs).map { row, pair in
            (row.id, pair.0)
        })
    }

    private func attemptSave() {
        guard hasSelection else {
            saveBanner = "Pick at least one app or category first."
            highlightedRows = []
            return
        }
        guard counts.webDomainTokens == 0 else {
            saveBanner = "Websites are not supported here. Remove website selections before saving."
            highlightedRows = []
            return
        }

        Task {
            await upload()
        }
    }

    @MainActor
    private func upload() async {
        var model = CaptureSheetModel(rows: pendingRows)
        model.attemptSave()
        guard model.isPresented == false else {
            saveBanner = model.errorBanner
            highlightedRows = Set(model.highlightedRows.compactMap { index in
                model.rows.indices.contains(index) ? model.rows[index].id : nil
            })
            return
        }

        // Pair each pending row with its upload payload so we can correlate the
        // backend response without relying on the wire alias_key (which is now nil
        // for fresh captures — see makeUploadApp/makeUploadCategory).
        let appPairs: [(row: PendingAppRow, upload: ChildAppCatalogUploadApp)] =
            model.savedRows.compactMap { row in
                guard let upload = row.makeUploadApp(sourceDeviceID: childDeviceID) else { return nil }
                return (row, upload)
            }
        let categoryPairs: [(row: PendingCategoryRow, upload: ChildAppCatalogUploadApp)] =
            pendingCategoryRows.map { ($0, $0.makeUploadCategory(sourceDeviceID: childDeviceID)) }
        let apps = appPairs.map(\.upload)
        let categories = categoryPairs.map(\.upload)
        guard !apps.isEmpty || !categories.isEmpty else {
            saveBanner = "Pick at least one app or category first."
            return
        }

        uploading = true
        defer { uploading = false }
        saveBanner = nil
        highlightedRows = []

        for (row, upload) in appPairs {
            guard let token = appTokensByRowID[row.id] else { continue }
            LocalAliasStore.shared.saveApplicationAliases(
                token: token,
                displayName: upload.displayName,
                bundleIdentifier: upload.bundleID
            )
        }
        for (row, upload) in categoryPairs {
            guard let token = categoryTokensByRowID[row.id] else { continue }
            LocalAliasStore.shared.saveCategoryToken(token, forName: upload.displayName)
            if let semantic = upload.aliases.last {
                LocalAliasStore.shared.saveCategoryToken(token, forName: semantic)
            }
        }

        do {
            let response = try await apiClient.uploadChildAppCatalog(deviceID: childDeviceID, apps: apps + categories)
            // The backend assigns its own alias_key. Map each response row back by
            // (displayName, bundleID, kind) so LocalAliasStore stores the REAL key
            // (nil if not found — never a bogus local id).
            func backendAliasKey(displayName: String, bundleID: String?, isCategory: Bool) -> UUID? {
                response.apps.first {
                    $0.displayName == displayName
                        && $0.bundleID == bundleID
                        && ($0.tokenKind.lowercased() == "category") == isCategory
                }?.id
            }
            for (row, upload) in appPairs {
                guard let token = appTokensByRowID[row.id] else { continue }
                LocalAliasStore.shared.saveApplicationAliases(
                    token: token,
                    displayName: upload.displayName,
                    bundleIdentifier: upload.bundleID,
                    catalogAliasKey: backendAliasKey(displayName: upload.displayName, bundleID: upload.bundleID, isCategory: false)
                )
            }
            for (row, upload) in categoryPairs {
                guard let token = categoryTokensByRowID[row.id] else { continue }
                let key = backendAliasKey(displayName: upload.displayName, bundleID: nil, isCategory: true)
                LocalAliasStore.shared.saveCategoryToken(
                    token,
                    forName: upload.displayName,
                    catalogAliasKey: key
                )
                for alias in upload.aliases {
                    LocalAliasStore.shared.saveCategoryToken(
                        token,
                        forName: alias,
                        catalogAliasKey: key
                    )
                }
            }
            onSaved()
        } catch {
            // Do NOT call onSaved() here — dismissing would hide the failure and
            // let a local-only save look like a real one. The app/category is saved
            // to LocalAliasStore but is NOT in the backend catalog, so the parent's
            // chat/lazy-tag can't see or lock it until this upload succeeds. Keep the
            // sheet open with a visible error so the user can retry.
            errorText = "Couldn't sync to Evlin: \(error.localizedDescription). Saved on this device only — it won't be lockable from parent chat until the sync succeeds. Check the connection and try Save again."
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
