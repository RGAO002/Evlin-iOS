import SwiftUI
import FamilyControls
import ManagedSettings

/// Add App captures one or more application tokens plus broad categories. Each
/// app row must be named and explicitly confirmed before saving; category rows
/// use Apple's picker label and broad-coverage semantics.
struct AddAppFlowSaveResult: Equatable, Sendable {
    let savedApps: Int
    let savedCategories: Int
    let blockableAppCount: Int

    var isReadyForFirstBlock: Bool {
        blockableAppCount > 0
    }
}

struct AddAppFlowView: View {
    let childDeviceID: UUID
    let mode: AddTargetMode
    let onSaved: (AddAppFlowSaveResult) -> Void

    @EnvironmentObject var apiClient: APIClient

    @State private var selection = FamilyActivitySelection()
    @State private var draftSelection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var pickerError: String?
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
            && (mode == .app
                ? pendingRows.isEmpty == false
                : pendingCategoryRows.isEmpty == false && pendingCategoryRows.allSatisfy(\.isNamedCategory))
    }

    init(
        childDeviceID: UUID,
        mode: AddTargetMode = .app,
        onSaved: @escaping (AddAppFlowSaveResult) -> Void
    ) {
        self.childDeviceID = childDeviceID
        self.mode = mode
        self.onSaved = onSaved
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                pickerCard

                if counts.webDomainTokens > 0 {
                    AddAppSaveValidationBanner(message: "Websites are not supported here. Remove website selections before saving.")
                }

                if mode == .app, !pendingRows.isEmpty {
                    appsBindCard
                }

                if mode == .category, !pendingCategoryRows.isEmpty {
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
        .navigationTitle(mode.title)
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
                Text(mode == .app ? "Add apps" : "Add categories")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text(mode == .app
                    ? "Pick individual apps from this device. Category selections are ignored here."
                    : "Pick Apple categories from this device. App selections are ignored here.")
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
                draftSelection = normalizedDraftSelection(from: selection, mode: mode)
                pickerError = nil
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
                        Text(mode == .app ? "Pick app" : "Pick category")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.evOnSurface)
                        Text(mode == .app
                            ? "Choose one or more individual apps in one pass."
                            : "Choose one or more Apple categories in one pass.")
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
            .sheet(isPresented: $showPicker) {
                AddTargetPickerSheet(
                    mode: mode,
                    selection: $draftSelection,
                    errorText: pickerError,
                    onCancel: { showPicker = false },
                    onSave: { applyDraftSelection() }
                )
            }

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
            Text("Name what you selected")
                .font(.headline)
                .foregroundStyle(Color.evOnSurface)
            Text("We know this is a hassle, but Apple won't let Evlin read app names. Search the dropdown and choose the matching App Store result — you only have to do this once.")
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
            Text("Select the category")
                .font(.headline)
                .foregroundStyle(Color.evOnSurface)
            Text("Tap the Apple Screen Time category that matches the label above.")
                .font(.subheadline)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(pendingCategoryRows) { row in
                if let token = categoryTokensByRowID[row.id] {
                    CategoryBindRowView(
                        token: token,
                        row: binding(for: row)
                    )
                }
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
        switch mode {
        case .app:
            return "\(pendingRows.count) apps ready · \(counts.categoryTokens) ignored categories · \(counts.webDomainTokens) websites"
        case .category:
            return "\(pendingCategoryRows.count) categories ready · \(counts.applicationTokens) ignored apps · \(counts.webDomainTokens) websites"
        }
    }

    @ViewBuilder
    private var saveButtonLabel: some View {
        if uploading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if mode == .app, pendingRows.allSatisfy(\.isLockableApp), pendingRows.isEmpty == false {
            Text("Save apps")
                .frame(maxWidth: .infinity)
        } else if mode == .category, pendingCategoryRows.isEmpty == false {
            Text("Save categories")
                .frame(maxWidth: .infinity)
        } else if mode == .app, pendingRows.isEmpty == false {
            Text("Name every app before saving")
                .frame(maxWidth: .infinity)
        } else {
            Text(mode == .app ? "Save app" : "Save category")
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

    private func binding(for row: PendingCategoryRow) -> Binding<PendingCategoryRow> {
        Binding(
            get: {
                pendingCategoryRows.first(where: { $0.id == row.id }) ?? row
            },
            set: { newValue in
                if let index = pendingCategoryRows.firstIndex(where: { $0.id == row.id }) {
                    pendingCategoryRows[index] = newValue
                }
            }
        )
    }

    private func normalizedDraftSelection(
        from selection: FamilyActivitySelection,
        mode: AddTargetMode
    ) -> FamilyActivitySelection {
        var draft = FamilyActivitySelection(
            includeEntireCategory: AddTargetPickerConfiguration.includeEntireCategory(for: mode)
        )
        draft.applicationTokens = selection.applicationTokens
        draft.categoryTokens = selection.categoryTokens
        draft.webDomainTokens = selection.webDomainTokens
        return draft
    }

    private func applyDraftSelection() {
        let draftCounts = SelectionCounts(draftSelection)
        let decision = AddTargetFlowRules.decision(
            mode: mode,
            appCount: draftCounts.applicationTokens,
            categoryCount: draftCounts.categoryTokens,
            webDomainCount: draftCounts.webDomainTokens
        )
        var shell = AddTargetPickerShellModel()
        if shell.attemptSave(decision: decision) {
            selection = sanitizedSelectionForSave(from: draftSelection, decision: decision)
            saveBanner = decision.warning
            pickerError = nil
            showPicker = false
        } else {
            pickerError = decision.warning
            showPicker = true
        }
    }

    private func sanitizedSelectionForSave(
        from draft: FamilyActivitySelection,
        decision: AddTargetFlowRules.Decision
    ) -> FamilyActivitySelection {
        switch decision.action {
        case .saveApps:
            var selection = FamilyActivitySelection()
            selection.applicationTokens = draft.applicationTokens
            return selection
        case .saveCategories:
            // FamilyActivitySelection.categories is derived by the framework.
            // Preserve the picker-produced category selection and clear ignored buckets.
            var selection = draft
            selection.applicationTokens = []
            selection.webDomainTokens = []
            return selection
        case .reject:
            return draft
        }
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
            let display = PendingCategoryRow.initialDisplayName(pickerLabel: pickerName)
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

        let decision = AddTargetFlowRules.decision(
            mode: mode,
            appCount: pendingRows.count,
            categoryCount: pendingCategoryRows.count,
            webDomainCount: SelectionCounts(newValue).webDomainTokens
        )
        switch decision.action {
        case .saveApps:
            if !pendingCategoryRows.isEmpty {
                pendingCategoryRows = []
                categoryTokensByRowID = [:]
            }
        case .saveCategories:
            if !pendingRows.isEmpty {
                pendingRows = []
                appTokensByRowID = [:]
            }
        case .reject:
            break
        }
        saveBanner = decision.warning
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
        let savedAppRows: [PendingAppRow]
        if mode == .app, pendingRows.isEmpty == false {
            var model = CaptureSheetModel(rows: pendingRows)
            model.attemptSave()
            guard model.isPresented == false else {
                saveBanner = model.errorBanner
                highlightedRows = Set(model.highlightedRows.compactMap { index in
                    model.rows.indices.contains(index) ? model.rows[index].id : nil
                })
                return
            }
            savedAppRows = model.savedRows
        } else {
            savedAppRows = []
        }

        // Pair each pending row with its upload payload so we can correlate the
        // backend response without relying on the wire alias_key (which is now nil
        // for fresh captures — see makeUploadApp/makeUploadCategory).
        let appPairs: [(row: PendingAppRow, upload: ChildAppCatalogUploadApp)] =
            savedAppRows.compactMap { row in
                guard let upload = row.makeUploadApp(sourceDeviceID: childDeviceID) else { return nil }
                return (row, upload)
            }
        let shouldUploadCategories = mode == .category
        let categoryPairs: [(row: PendingCategoryRow, upload: ChildAppCatalogUploadApp)] =
            shouldUploadCategories ? pendingCategoryRows.map { ($0, $0.makeUploadCategory(sourceDeviceID: childDeviceID)) } : []
        if shouldUploadCategories {
            let blankCategories = pendingCategoryRows.filter { !$0.isNamedCategory }
            guard blankCategories.isEmpty else {
                saveBanner = "Name every category before saving."
                return
            }
        }
        let appPairsForUpload = mode == .app ? appPairs : []
        let categoryPairsForUpload = shouldUploadCategories ? categoryPairs : []
        let uploadRows = appPairsForUpload.map(\.upload) + categoryPairsForUpload.map(\.upload)
        guard !uploadRows.isEmpty else {
            saveBanner = mode == .app ? "Pick at least one app first." : "Pick at least one category first."
            return
        }

        uploading = true
        defer { uploading = false }
        saveBanner = nil
        highlightedRows = []

        for (row, upload) in appPairsForUpload {
            guard let token = appTokensByRowID[row.id] else { continue }
            LocalAliasStore.shared.saveApplicationAliases(
                token: token,
                displayName: upload.displayName,
                bundleIdentifier: upload.bundleID
            )
        }
        for (row, upload) in categoryPairsForUpload {
            guard let token = categoryTokensByRowID[row.id] else { continue }
            LocalAliasStore.shared.saveCategoryToken(token, forName: upload.displayName)
            if let semantic = upload.aliases.last {
                LocalAliasStore.shared.saveCategoryToken(token, forName: semantic)
            }
        }

        do {
            let response = try await apiClient.mergeChildAppCatalog(deviceID: childDeviceID, apps: uploadRows)
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
            for (row, upload) in appPairsForUpload {
                guard let token = appTokensByRowID[row.id] else { continue }
                LocalAliasStore.shared.saveApplicationAliases(
                    token: token,
                    displayName: upload.displayName,
                    bundleIdentifier: upload.bundleID,
                    catalogAliasKey: backendAliasKey(displayName: upload.displayName, bundleID: upload.bundleID, isCategory: false)
                )
            }
            for (row, upload) in categoryPairsForUpload {
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
            let blockableAppCount = appPairsForUpload.filter {
                ($0.upload.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }.count
            onSaved(AddAppFlowSaveResult(
                savedApps: appPairsForUpload.count,
                savedCategories: categoryPairsForUpload.count,
                blockableAppCount: blockableAppCount
            ))
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

private struct AddTargetPickerSheet: View {
    let mode: AddTargetMode
    @Binding var selection: FamilyActivitySelection
    let errorText: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FamilyActivityPicker(selection: $selection)

            if let errorText {
                AddPickerErrorToast(message: errorText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Button(action: onSave) {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.evPrimary, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.evOnSurface)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .presentationDetents([.large])
    }
}

private struct AddPickerErrorToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Color.evError)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            Color.evError.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct CategoryBindRowView: View {
    let token: ActivityCategoryToken
    @Binding var row: PendingCategoryRow

    /// Map the row's current state onto the panel's stateless `selectedKey` while
    /// preserving the exact `matchesSuggestion` semantics (semanticKey AND
    /// case-insensitive displayName). The capsule lights up only for a suggestion
    /// the row truly matches — never on semantic key alone.
    private var selectedKey: String? {
        AppleScreenTimeCategorySuggestions.visibleCapsules(for: row.displayName)
            .first { row.matchesSuggestion($0) }?
            .semanticKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(token)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.evSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            CategoryTagPanel(
                name: row.displayName,
                selectedKey: selectedKey,
                onPick: { suggestion in
                    row.applySuggestion(suggestion)
                }
            )
        }
        .padding(12)
        .background(Color.evSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
