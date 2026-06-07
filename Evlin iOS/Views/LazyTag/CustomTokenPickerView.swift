// Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift
//
// Parent/chat lazy-tag picker. This is intentionally catalog-backed and does
// not open FamilyActivityPicker; kid-device token capture remains in the
// Add-App/onboarding flow.

import SwiftUI

// MARK: - Plan-arch lazy_tag factory

func customTokenPickerForCard(
    card: PlanArchCardPayload,
    onPicked: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
) -> CustomTokenPickerView {
    let targetName = (card.detail["target_name"]?.value as? String) ?? "the app"
    let rawKind = (card.detail["target_kind"]?.value as? String) ?? "app"
    let kind: AliasKind = rawKind == "category" ? .category : .app

    let request = LazyTagRequest(
        proposalToken: card.planToken,
        rowIndex: card.stepIndex,
        target: targetName,
        kind: kind
    )

    return CustomTokenPickerView(
        request: request,
        onSelect: { target, _ in
            if let catalogTarget = target as? LazyTagCatalogTarget {
                onPicked(catalogTarget.aliasKey.uuidString)
            } else {
                onPicked(String(describing: target))
            }
        },
        onCancel: onCancel
    )
}

struct AppStoreSearchRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    let query: String
    let targetDisplay: String
    let originalMessage: String
}

struct AppStoreSearchPickerView: View {
    let request: AppStoreSearchRequest
    let onSelect: (CatalogSearchResultDTO, AppStoreSearchRequest) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [CatalogSearchResultDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let apiClient: APIClient

    init(
        request: AppStoreSearchRequest,
        apiClient: APIClient = APIClient(),
        onSelect: @escaping (CatalogSearchResultDTO, AppStoreSearchRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.apiClient = apiClient
        self.onSelect = onSelect
        self.onCancel = onCancel
        _query = State(initialValue: request.query)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        searchBar
                        resultList
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                if let errorMessage {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                            .font(.custom("Inter", size: 12).weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.evError)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.evError.opacity(0.08))
                }
            }
            .background(Color.evSurface.ignoresSafeArea())
            .navigationTitle("Search App Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
            .task {
                await runSearch()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evPrimaryContainer)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text("Not in the list?")
                    .font(.custom("Manrope", size: 21).weight(.bold))
                    .foregroundStyle(Color.evOnSurface)
                Text("Search App Store, pick the real app, and Evlin will save \"\(request.targetDisplay)\" as an alias.")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .sentinelCatalogCard(cornerRadius: 18)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.evOutline)
            TextField("Search App Store", text: $query)
                .font(.custom("Inter", size: 14))
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    Task { await runSearch() }
                }
            Button("Search") {
                Task { await runSearch() }
            }
            .font(.custom("Inter", size: 12).weight(.bold))
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var resultList: some View {
        if isLoading {
            ProgressView("Searching...")
                .font(.custom("Inter", size: 13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if results.isEmpty {
            Text("No App Store matches. Try the full app name, or add it on the kid device first.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sentinelCatalogCard(cornerRadius: 18)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    if index > 0 {
                        Divider()
                            .overlay(Color.evOutlineVariant)
                            .padding(.leading, 58)
                    }
                    Button {
                        onSelect(result, request)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            appIcon(result)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.canonicalName)
                                    .font(.custom("Inter", size: 15).weight(.semibold))
                                    .foregroundStyle(Color.evOnSurface)
                                Text(result.bundleID ?? "No bundle id")
                                    .font(.custom("Inter", size: 11))
                                    .foregroundStyle(Color.evOutline)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.evOutline)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .disabled(result.bundleID == nil)
                }
            }
            .sentinelCatalogCard(cornerRadius: 18)
        }
    }

    @ViewBuilder
    private func appIcon(_ result: CatalogSearchResultDTO) -> some View {
        if let artworkURL = result.artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    appPlaceholder(result.canonicalName)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            appPlaceholder(result.canonicalName)
        }
    }

    private func appPlaceholder(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.custom("Inter", size: 14).weight(.heavy))
            .frame(width: 34, height: 34)
            .background(Color.evSurfaceContainer)
            .foregroundStyle(Color.evOnSurfaceVariant)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            results = try await apiClient.catalogSearch(q: trimmed)
        } catch {
            results = []
            errorMessage = "Could not search App Store. Check connection and try again."
        }
        isLoading = false
    }
}

struct CustomTokenPickerView: View {
    let request: LazyTagRequest
    let onSelect: (Any, LazyTagRequest) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("evlin.familyID") private var familyIDString: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceIDString: String = ""

    @State private var targets: [LazyTagCatalogTarget] = []
    @State private var selectedTarget: LazyTagCatalogTarget?
    @State private var searchText: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let apiClient: APIClient

    init(
        request: LazyTagRequest,
        apiClient: APIClient = APIClient(),
        onSelect: @escaping (Any, LazyTagRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.apiClient = apiClient
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    private var childDeviceID: UUID? {
        UUID(uuidString: childDeviceIDString)
    }

    private var familyID: UUID? {
        UUID(uuidString: familyIDString)
    }

    private var presentation: LazyTagCatalogPresentation {
        LazyTagCatalogModel.presentation(
            targets: targets,
            searchText: searchText,
            unresolvedName: request.target
        )
    }

    private var canSave: Bool {
        selectedTarget != nil && !presentation.isInformOnly && !isSaving
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        parentChatBadge
                        header
                        searchBar
                        listBody
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                if let errorMessage {
                    Divider()
                    errorBanner(errorMessage)
                }
                Divider()
                footer
            }
            .background(Color.evSurface.ignoresSafeArea())
            .navigationTitle("Add to lock list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        saveTapped()
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                await loadTargets()
            }
        }
    }

    private var parentChatBadge: some View {
        Text("Parent · AI chat")
            .font(.custom("Inter", size: 10).weight(.heavy))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(Color.evPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.evPrimaryContainer))
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evTertiary)
                Image(systemName: "tag.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text("First time seeing \"\(request.target)\"")
                    .font(.custom("Manrope", size: 21).weight(.bold))
                    .foregroundStyle(Color.evOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It isn’t in your kid’s lock list yet. Pick a captured app, category, or list below to point it at — or add it on the kid’s device first.")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Evlin will save \"\(request.target)\" as an alias on the backend catalog target you choose.")
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(Color.evOutline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evTertiaryContainer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evTertiary.opacity(0.35), lineWidth: 1)
        )
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.evOutline)
            TextField("Search catalog", text: $searchText)
                .font(.custom("Inter", size: 14))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.evOutline)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var listBody: some View {
        if isLoading {
            ProgressView("Loading catalog...")
                .font(.custom("Inter", size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if familyID == nil || childDeviceID == nil {
            emptyState(message: "No family or child device is selected. Pair or select a child before saving chat aliases.")
        } else if errorMessage == nil, let informMessage = presentation.informMessage {
            informOnlyState(message: informMessage)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(presentation.sections, id: \.type) { section in
                    catalogSection(section)
                }
            }
        }
    }

    private func catalogSection(_ section: LazyTagCatalogSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayTitle(for: section.type))
                    .font(.custom("Inter", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text("\(section.targets.count)")
                    .font(.custom("Inter", size: 10).weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.evSurfaceContainer)
                    .clipShape(Capsule())
                    .foregroundStyle(Color.evOutline)
            }

            if section.targets.isEmpty {
                Text(emptyCopy(for: section.type))
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sentinelCatalogCard(cornerRadius: 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(section.targets.enumerated()), id: \.element.id) { index, target in
                        if index > 0 {
                            Divider()
                                .overlay(Color.evOutlineVariant)
                                .padding(.leading, 58)
                        }
                        targetRow(target)
                    }
                }
                .sentinelCatalogCard(cornerRadius: 18)
            }
        }
    }

    private func targetRow(_ target: LazyTagCatalogTarget) -> some View {
        let isSelected = selectedTarget?.aliasKey == target.aliasKey
        return Button {
            selectedTarget = target
            errorMessage = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                targetIcon(target)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(target.displayName)
                            .font(.custom("Inter", size: 15).weight(.semibold))
                            .foregroundStyle(Color.evOnSurface)
                        if target.isManual {
                            Text("Manual")
                                .font(.custom("Inter", size: 9).weight(.heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.evTertiaryContainer)
                                .foregroundStyle(Color.evOnTertiaryContainer)
                                .clipShape(Capsule())
                        }
                    }
                    Text(target.supportingText)
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark" : "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func targetIcon(_ target: LazyTagCatalogTarget) -> some View {
        switch target.type {
        case .app:
            if let artworkURL = target.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        appPlaceholder(target.displayName)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                appPlaceholder(target.displayName)
            }
        case .category:
            iconBadge(systemName: "square.grid.2x2.fill", color: Color.evPrimary)
        case .list:
            iconBadge(systemName: "list.bullet.rectangle.fill", color: Color.evChildLiam)
        }
    }

    private func appPlaceholder(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.custom("Inter", size: 14).weight(.heavy))
            .frame(width: 34, height: 34)
            .background(Color.evSurfaceContainer)
            .foregroundStyle(Color.evOnSurfaceVariant)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func iconBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .bold))
            .frame(width: 34, height: 34)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Color.evOutline)
            Text(message)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 38)
        .frame(maxWidth: .infinity)
        .sentinelCatalogCard(cornerRadius: 18)
    }

    private func informOnlyState(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Color.evPrimary)
            Text(message)
                .font(.custom("Inter", size: 14).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 38)
        .frame(maxWidth: .infinity)
        .sentinelCatalogCard(cornerRadius: 18)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.custom("Inter", size: 12).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.evError)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evError.opacity(0.08))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Do not see it here?")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("Add or capture the target on the kid device first, or try `block \(request.target)`. Parent chat only saves metadata aliases to existing catalog targets.")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    private func displayTitle(for type: LazyTagCatalogTargetType) -> String {
        switch type {
        case .app: return "Apps"
        case .category: return "Categories"
        case .list: return "Lists"
        }
    }

    private func emptyCopy(for type: LazyTagCatalogTargetType) -> String {
        switch type {
        case .app:
            return "No matching apps."
        case .category:
            return "No matching categories. Categories cover current + future apps Apple classifies there."
        case .list:
            return "No matching lists."
        }
    }

    private func loadTargets() async {
        guard let childDeviceID else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            targets = try await apiClient.fetchLazyTagCatalogTargets(
                childDeviceID: childDeviceID,
                query: nil
            )
        } catch {
            errorMessage = "Could not load the catalog. Check connection and try again."
            targets = []
        }
        isLoading = false
    }

    private func saveTapped() {
        guard let selectedTarget else { return }
        isSaving = true
        errorMessage = nil
        Task {
            let result = await LazyTagPersistence.persistCatalogAlias(
                target: selectedTarget,
                requestedAlias: request.target,
                familyID: familyID,
                childDeviceID: childDeviceID,
                apiClient: apiClient
            )
            await MainActor.run {
                isSaving = false
                switch result {
                case .success:
                    onSelect(selectedTarget, request)
                    dismiss()
                case .failure(.emptyTarget):
                    errorMessage = "Alias is empty."
                case .failure(.missingFamily):
                    errorMessage = "No family is selected."
                case .failure(.missingChildDevice):
                    errorMessage = "No child device is selected."
                case .failure:
                    errorMessage = "Could not save the alias. Try again."
                }
            }
        }
    }
}

private extension View {
    func sentinelCatalogCard(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
            .evShadow(.premium)
    }
}
