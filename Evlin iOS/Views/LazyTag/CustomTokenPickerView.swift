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

struct CustomTokenPickerView: View {
    let request: LazyTagRequest
    let onSelect: (Any, LazyTagRequest) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
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

    private var sections: [LazyTagCatalogSection] {
        LazyTagCatalogModel.sections(from: targets, searchText: searchText)
    }

    private var canSave: Bool {
        selectedTarget != nil && !isSaving
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                searchBar
                Divider()
                listBody
                if let errorMessage {
                    Divider()
                    errorBanner(errorMessage)
                }
                Divider()
                footer
            }
            .navigationTitle("Tag target")
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Which catalog target is")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("\"\(request.target)\"?")
                .font(.custom("Manrope", size: 24).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text("Choose an app, category, or custom list. Evlin will save \"\(request.target)\" as an alias on that backend catalog target.")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
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
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.evSurfaceContainerLow)
    }

    @ViewBuilder
    private var listBody: some View {
        if isLoading {
            ProgressView("Loading catalog...")
                .font(.custom("Inter", size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if childDeviceID == nil {
            emptyState(message: "No child device is selected. Pair or select a child before saving chat aliases.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.type) { section in
                        catalogSection(section)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
        }
    }

    private func catalogSection(_ section: LazyTagCatalogSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.2)
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
                    .foregroundStyle(Color.evOutline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.evSurfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(section.targets) { target in
                    targetRow(target)
                }
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
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Add or capture the target on the kid device first. Parent chat only saves metadata aliases to existing catalog targets.")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    private func emptyCopy(for type: LazyTagCatalogTargetType) -> String {
        switch type {
        case .app:
            return "No matching catalog apps."
        case .category:
            return "No matching categories. Categories cover current and future apps Apple classifies there."
        case .list:
            return "No matching custom lists."
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
                case .failure(.missingChildDevice):
                    errorMessage = "No child device is selected."
                case .failure:
                    errorMessage = "Could not save the alias. Try again."
                }
            }
        }
    }
}
