// Evlin iOS/Views/Settings/AliasManagementView.swift
//
// Parent-facing backend catalog alias manager. This screen intentionally
// edits catalog aliases on the backend, not the old LocalAliasStore map:
// parent/chat lazy-tag now resolves against the child's catalog targets.

import SwiftUI

struct AliasManagementView: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.familyID") private var familyIDString = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceIDString = ""

    var body: some View {
        Group {
            if UUID(uuidString: familyIDString) != nil || UUID(uuidString: childDeviceIDString) != nil {
                AliasChildDeviceSelectionScreen(
                    familyID: UUID(uuidString: familyIDString),
                    initialChildDeviceID: UUID(uuidString: childDeviceIDString),
                    client: apiClient
                )
            } else {
                ContentUnavailableView(
                    "No family paired",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Pair a family before managing chat aliases.")
                )
            }
        }
        .navigationTitle("Manage aliases")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AliasChildDeviceSelectionScreen: View {
    let familyID: UUID?
    let initialChildDeviceID: UUID?
    let client: APIClient

    @State private var children: [ParentChildDeviceSummaryDTO] = []
    @State private var selectedChildDeviceID: UUID?
    @State private var resolvedFamilyID: UUID?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("evlin.familyID") private var familyIDString = ""

    var body: some View {
        Group {
            if isLoading && children.isEmpty {
                ProgressView("Loading child devices...")
            } else if children.isEmpty {
                ContentUnavailableView(
                    "No child devices",
                    systemImage: "iphone.slash",
                    description: Text(errorMessage ?? "Pair a kid device before managing aliases.")
                )
            } else {
                VStack(spacing: 0) {
                    childSelector
                    if let childDeviceID = selectedChildDeviceID,
                       let familyID = resolvedFamilyID ?? familyID {
                        AliasCatalogManagerScreen(
                            familyID: familyID,
                            childDeviceID: childDeviceID,
                            client: client
                        )
                        .id(childDeviceID)
                    }
                }
            }
        }
        .task { await loadChildren() }
        .refreshable { await loadChildren() }
    }

    @ViewBuilder
    private var childSelector: some View {
        if children.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Child")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Picker("Child", selection: selectedChildBinding) {
                    ForEach(children) { child in
                        Text("\(child.displayName) · \(child.shortID)").tag(child.childDeviceID)
                    }
                }
                .pickerStyle(.segmented)
                if let selected = children.first(where: { $0.childDeviceID == selectedChildDeviceID }) {
                    childSummary(selected)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)
            .background(.background)
        } else if let only = children.first {
            childSummary(only)
            .padding([.horizontal, .top])
            .padding(.bottom, 8)
            .background(.background)
        }
    }

    private func childSummary(_ child: ParentChildDeviceSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Showing aliases for \(child.displayName) · \(child.shortID)", systemImage: "person.crop.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(child.catalogSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(child.catalogPreviewText)
                .font(.caption2.monospaced())
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedChildBinding: Binding<UUID> {
        Binding(
            get: { selectedChildDeviceID ?? children[0].childDeviceID },
            set: { selectedChildDeviceID = $0 }
        )
    }

    @MainActor
    private func loadChildren() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var preferredChild: ParentChildDeviceSummaryDTO?
            var lookupFamilyID = familyID

            if let initialChildDeviceID {
                do {
                    let current = try await client.fetchParentChildDevice(childDeviceID: initialChildDeviceID)
                    preferredChild = current.child
                    lookupFamilyID = current.familyID
                    selectedChildDeviceID = current.child.childDeviceID
                    resolvedFamilyID = current.familyID
                    familyIDString = current.familyID.uuidString
                } catch {
                    if familyID == nil {
                        throw error
                    }
                }
            }

            if let lookupFamilyID {
                do {
                    let fetched = try await client.fetchParentChildDevices(familyID: lookupFamilyID)
                    if !fetched.isEmpty {
                        children = fetched
                        resolvedFamilyID = lookupFamilyID
                        if let selectedChildDeviceID,
                           fetched.contains(where: { $0.childDeviceID == selectedChildDeviceID }) {
                            return
                        }
                        if let preferredChild,
                           fetched.contains(where: { $0.childDeviceID == preferredChild.childDeviceID }) {
                            selectedChildDeviceID = preferredChild.childDeviceID
                        } else if let initialChildDeviceID,
                                  fetched.contains(where: { $0.childDeviceID == initialChildDeviceID }) {
                            selectedChildDeviceID = initialChildDeviceID
                        } else {
                            selectedChildDeviceID = fetched.first?.childDeviceID
                        }
                        return
                    }
                } catch {
                    if preferredChild == nil {
                        throw error
                    }
                }
            }

            if let preferredChild {
                children = [preferredChild]
                selectedChildDeviceID = preferredChild.childDeviceID
                return
            }

            throw APIError.serverError(404)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AliasCatalogManagerScreen: View {
    private let iconSize: CGFloat = 44

    @StateObject private var model: AliasManagerModel
    @State private var addAliasTarget: LazyTagCatalogTarget?
    @State private var newAlias = ""
    @State private var renameAliasTarget: LazyTagCatalogTarget?
    @State private var renameOldAlias = ""
    @State private var renamedAlias = ""

    init(
        familyID: UUID,
        childDeviceID: UUID,
        client: AliasManagingClient
    ) {
        _model = StateObject(wrappedValue: AliasManagerModel(
            familyID: familyID,
            childDeviceID: childDeviceID,
            client: client
        ))
    }

    var body: some View {
        List {
            Section {
                Text("These names teach Evlin which catalog target you mean in chat. Tokens stay on the kid-side catalog; this page only edits aliases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading catalog aliases...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(model.sections, id: \.type) { section in
                Section(sectionTitle(for: section)) {
                    if section.targets.isEmpty {
                        Text(emptyCopy(for: section.type))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(section.targets) { target in
                            targetRow(target)
                        }
                    }
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Search aliases or targets")
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("Add alias", isPresented: addAliasBinding) {
            TextField("Alias", text: $newAlias)
            Button("Cancel", role: .cancel) {
                addAliasTarget = nil
                newAlias = ""
            }
            Button("Save") {
                guard let target = addAliasTarget else { return }
                Task {
                    await model.addAlias(newAlias, to: target)
                    newAlias = ""
                    addAliasTarget = nil
                }
            }
        } message: {
            Text("Add another chat name for this target.")
        }
        .alert("Rename alias", isPresented: renameAliasBinding) {
            TextField("Alias", text: $renamedAlias)
            Button("Cancel", role: .cancel) {
                resetRenameState()
            }
            Button("Save") {
                guard let target = renameAliasTarget else { return }
                Task {
                    await model.renameAlias(renameOldAlias, to: renamedAlias, for: target)
                    resetRenameState()
                }
            }
        } message: {
            Text("Rename this chat alias for the selected catalog target.")
        }
    }

    private var addAliasBinding: Binding<Bool> {
        Binding(
            get: { addAliasTarget != nil },
            set: { isPresented in
                if !isPresented {
                    addAliasTarget = nil
                    newAlias = ""
                }
            }
        )
    }

    private var renameAliasBinding: Binding<Bool> {
        Binding(
            get: { renameAliasTarget != nil },
            set: { isPresented in
                if !isPresented {
                    resetRenameState()
                }
            }
        )
    }

    private func resetRenameState() {
        renameAliasTarget = nil
        renameOldAlias = ""
        renamedAlias = ""
    }

    private func sectionTitle(for section: LazyTagCatalogSection) -> String {
        "\(section.title)s (\(section.targets.count))"
    }

    private func emptyCopy(for type: LazyTagCatalogTargetType) -> String {
        switch type {
        case .app: return "No app aliases in this catalog yet."
        case .category: return "No category aliases in this catalog yet."
        case .list: return "No list aliases in this catalog yet."
        }
    }

    @ViewBuilder
    private func targetRow(_ target: LazyTagCatalogTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                targetIcon(target)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(target.displayName)
                            .font(.headline)
                        if target.isManual {
                            Text("Manual")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(target.supportingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    addAliasTarget = target
                    newAlias = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add alias for \(target.displayName)")
            }

            if target.aliases.isEmpty {
                Text("Aliases registered to this target: none")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, iconSize + 12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aliases registered to this target")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(target.aliases, id: \.self) { alias in
                            aliasChip(alias, target: target)
                        }
                    }
                }
                .padding(.leading, iconSize + 12)
            }
        }
        .padding(.vertical, 4)
    }

    private func aliasChip(_ alias: String, target: LazyTagCatalogTarget) -> some View {
        HStack(spacing: 6) {
            Text(alias)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Button {
                renameAliasTarget = target
                renameOldAlias = alias
                renamedAlias = alias
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Rename alias \(alias)")
            Button {
                Task { await model.removeAlias(alias, from: target) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove alias \(alias)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private func targetIcon(_ target: LazyTagCatalogTarget) -> some View {
        switch target.type {
        case .app:
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                if let url = target.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Text(targetInitial(target))
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(targetInitial(target))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        case .category:
            Image(systemName: "square.grid.2x2.fill")
                .font(.title3.weight(.semibold))
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.blue)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        case .list:
            Image(systemName: "list.bullet.rectangle.fill")
                .font(.title3.weight(.semibold))
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.green)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private func targetInitial(_ target: LazyTagCatalogTarget) -> String {
        let trimmed = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}

#if DEBUG
private final class PreviewAliasClient: AliasManagingClient {
    func fetchLazyTagCatalogTargets(childDeviceID: UUID, query: String?) async throws -> [LazyTagCatalogTarget] {
        [
            .init(aliasKey: UUID(), type: .app, displayName: "Instagram", aliases: ["ig", "insta"], bundleID: "com.burbn.instagram"),
            .init(aliasKey: UUID(), type: .category, displayName: "Games", aliases: ["gaming"]),
            .init(aliasKey: UUID(), type: .list, displayName: "Entertainment", aliases: ["fun"], memberCount: 3),
        ]
    }

    func saveLazyTagAlias(familyID: UUID, childDeviceID: UUID, target: LazyTagCatalogTarget, alias: String) async throws -> LazyTagCatalogTarget {
        .init(aliasKey: target.aliasKey, type: target.type, displayName: target.displayName, aliases: target.aliases + [alias], bundleID: target.bundleID, artworkURL: target.artworkURL, isManual: target.isManual, memberCount: target.memberCount)
    }

    func removeLazyTagAlias(familyID: UUID, childDeviceID: UUID, target: LazyTagCatalogTarget, alias: String) async throws -> LazyTagCatalogTarget {
        .init(aliasKey: target.aliasKey, type: target.type, displayName: target.displayName, aliases: target.aliases.filter { $0 != alias }, bundleID: target.bundleID, artworkURL: target.artworkURL, isManual: target.isManual, memberCount: target.memberCount)
    }

    func renameLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        oldAlias: String,
        newAlias: String
    ) async throws -> LazyTagCatalogTarget {
        .init(
            aliasKey: target.aliasKey,
            type: target.type,
            displayName: target.displayName,
            aliases: target.aliases.map { $0 == oldAlias ? newAlias : $0 },
            bundleID: target.bundleID,
            artworkURL: target.artworkURL,
            isManual: target.isManual,
            memberCount: target.memberCount
        )
    }
}

#Preview {
    NavigationStack {
        AliasCatalogManagerScreen(
            familyID: UUID(),
            childDeviceID: UUID(),
            client: PreviewAliasClient()
        )
    }
}
#endif
