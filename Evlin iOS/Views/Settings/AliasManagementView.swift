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
            if let familyID = UUID(uuidString: familyIDString),
               let childDeviceID = UUID(uuidString: childDeviceIDString) {
                AliasCatalogManagerScreen(
                    familyID: familyID,
                    childDeviceID: childDeviceID,
                    client: apiClient
                )
            } else {
                ContentUnavailableView(
                    "No child selected",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Pair a child device before managing chat aliases.")
                )
            }
        }
        .navigationTitle("Manage aliases")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AliasCatalogManagerScreen: View {
    @StateObject private var model: AliasManagerModel
    @State private var addAliasTarget: LazyTagCatalogTarget?
    @State private var newAlias = ""

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
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add alias for \(target.displayName)")
            }

            if target.aliases.isEmpty {
                Text("No aliases yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(target.aliases, id: \.self) { alias in
                        aliasChip(alias, target: target)
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    private func aliasChip(_ alias: String, target: LazyTagCatalogTarget) -> some View {
        HStack(spacing: 4) {
            Text(alias)
                .font(.caption.weight(.medium))
            Button {
                Task { await model.removeAlias(alias, from: target) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove alias \(alias)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private func targetIcon(_ target: LazyTagCatalogTarget) -> some View {
        switch target.type {
        case .app:
            if let url = target.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
            }
        case .category:
            Image(systemName: "square.grid.2x2.fill")
                .frame(width: 30, height: 30)
                .foregroundStyle(.blue)
        case .list:
            Image(systemName: "list.bullet.rectangle.fill")
                .frame(width: 30, height: 30)
                .foregroundStyle(.green)
        }
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
