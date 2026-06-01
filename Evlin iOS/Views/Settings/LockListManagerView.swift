import Combine
import SwiftUI

struct LockListAppEntry: Identifiable, Equatable {
    let label: String
    let keys: [String]
    let bundleID: String?

    var id: String {
        ([label] + keys + [bundleID ?? ""]).joined(separator: "|")
    }
}

struct LockListCategoryEntry: Identifiable, Equatable {
    let name: String

    var id: String { name.lowercased() }

    var displayName: String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

protocol LockListStoreReading {
    func groupedApplicationAliases() -> [(label: String, keys: [String], bundleID: String?)]
    func allCategoryNames() -> [String]
    func allListNames() -> [String]
}

extension LocalAliasStore: LockListStoreReading {}

struct LockListManagerSnapshot: Equatable {
    let apps: [LockListAppEntry]
    let categories: [LockListCategoryEntry]
    let lists: [String]

    static func make(from store: any LockListStoreReading) -> LockListManagerSnapshot {
        let apps = store.groupedApplicationAliases().map { entry in
            LockListAppEntry(
                label: entry.label,
                keys: entry.keys,
                bundleID: entry.bundleID
            )
        }
        let categories = store.allCategoryNames()
            .map(LockListCategoryEntry.init(name:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let lists = store.allListNames()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return LockListManagerSnapshot(apps: apps, categories: categories, lists: lists)
    }
}

@MainActor
final class LockListManagerModel: ObservableObject {
    @Published private(set) var apps: [LockListAppEntry] = []
    @Published private(set) var categories: [LockListCategoryEntry] = []
    @Published private(set) var lists: [String] = []

    private let store: any LockListStoreReading

    init() {
        self.store = LocalAliasStore.shared
    }

    init(store: any LockListStoreReading) {
        self.store = store
    }

    func reload() {
        let snapshot = LockListManagerSnapshot.make(from: store)
        apps = snapshot.apps
        categories = snapshot.categories
        lists = snapshot.lists
    }
}

struct LockListManagerView: View {
    @EnvironmentObject var apiClient: APIClient

    let familyID: UUID
    let childDeviceID: UUID

    @StateObject private var model = LockListManagerModel()
    @State private var showAddApp = false
    @State private var showAddList = false
    @State private var syncing = false
    @State private var syncBanner: String?
    @State private var didAutoSync = false
    @State private var showClearAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                addActions
                syncRow

                section(
                    title: "Apps",
                    count: model.apps.count,
                    emptyText: "No apps saved yet. Tap “Add app” to capture one."
                ) {
                    ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { rowDivider }
                        appRow(app)
                    }
                }

                section(
                    title: "Categories",
                    count: model.categories.count,
                    emptyText: "No broad categories saved yet. Use Add app to capture a category."
                ) {
                    ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, category in
                        if index > 0 { rowDivider }
                        categoryRow(category)
                    }
                }

                section(
                    title: "Saved lists",
                    count: model.lists.count,
                    emptyText: "No saved lists yet. Group added apps and categories with “Create list”."
                ) {
                    ForEach(Array(model.lists.enumerated()), id: \.element) { index, list in
                        if index > 0 { rowDivider }
                        listRow(list)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background(Color.evSurface.ignoresSafeArea())
        .navigationTitle("Manage lock list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.apps.isEmpty || !model.categories.isEmpty || !model.lists.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Text("Clear All").foregroundStyle(Color.evError)
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove every app, category and list from this device’s lock list? This also clears them from Evlin. Nothing currently locked is affected.",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear everything", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            model.reload()
            // Auto-push anything that's local-only up to the backend catalog so the
            // parent can lock it by name. Idempotent upsert; runs once per appearance.
            if !didAutoSync {
                didAutoSync = true
                Task { await syncToBackend() }
            }
        }
        .sheet(isPresented: $showAddApp) {
            NavigationStack {
                AddAppFlowView(childDeviceID: childDeviceID) {
                    showAddApp = false
                    model.reload()
                }
                .environmentObject(apiClient)
            }
        }
        .sheet(isPresented: $showAddList) {
            NavigationStack {
                SavedListPickerView(
                    familyID: familyID,
                    owningDeviceID: childDeviceID,
                    mode: "child_device"
                ) { _ in
                    showAddList = false
                    model.reload()
                }
                .environmentObject(apiClient)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.evPrimary)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("Lock list")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text("The apps and saved lists Evlin can lock on this device. Editing here doesn’t change anything that’s locked right now.")
                    .font(.subheadline)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .lockListCard()
    }

    // MARK: - Sync to backend

    /// Apps/categories captured on this device live in `LocalAliasStore`, but the
    /// parent's chat / lazy-tag picker resolve against the BACKEND catalog. Anything
    /// that got into the local store without uploading (e.g. report-hydrated apps, or
    /// an Add-App whose upload failed) is invisible to the parent. This pushes the
    /// local app/category tokens up so they become lockable by name from parent chat.
    /// Status only — sync is automatic (see `.onAppear`). Shows a spinner while
    /// syncing and a warning only if it FAILED; silent on success.
    @ViewBuilder
    private var syncRow: some View {
        if syncing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Syncing to Evlin…")
                    .font(.caption)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        } else if let syncBanner {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.evTertiary)
                Text(syncBanner)
                    .font(.caption)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private func syncToBackend() async {
        syncing = true
        defer { syncing = false }
        var uploads: [ChildAppCatalogUploadApp] = []
        for app in model.apps {
            guard let key = app.keys.first,
                  let token = LocalAliasStore.shared.applicationToken(forLookupKey: key),
                  let blob = try? AppCatalogBlobEncoder.base64(token), !blob.isEmpty
            else { continue }
            uploads.append(ChildAppCatalogUploadApp(
                displayName: app.label,
                tokenKind: "app",
                bundleID: app.bundleID,
                aliases: app.keys,
                tokenAvailable: true,
                tokenDataBase64: blob,
                sourceDeviceID: childDeviceID
            ))
        }
        for category in model.categories {
            guard let token = LocalAliasStore.shared.categoryToken(forName: category.name),
                  let blob = try? AppCatalogBlobEncoder.base64(token), !blob.isEmpty
            else { continue }
            uploads.append(ChildAppCatalogUploadApp(
                displayName: category.displayName,
                tokenKind: "category",
                bundleID: nil,
                aliases: [category.name],
                tokenAvailable: true,
                tokenDataBase64: blob,
                sourceDeviceID: childDeviceID
            ))
        }
        guard !uploads.isEmpty else { return }   // nothing local-only to push; stay silent
        do {
            _ = try await apiClient.uploadChildAppCatalog(deviceID: childDeviceID, apps: uploads)
            syncBanner = nil   // success is silent — the apps just become lockable in parent chat
            model.reload()
        } catch {
            syncBanner = "Couldn’t sync your apps to Evlin (\(error.localizedDescription)). They’re saved on this device but won’t be lockable from parent chat until this succeeds."
        }
    }

    // MARK: - Add actions

    private var addActions: some View {
        HStack(spacing: 12) {
            addButton(
                title: "Add app",
                systemImage: "plus.app.fill",
                tint: Color.evPrimary
            ) { showAddApp = true }

            addButton(
                title: "Create list",
                systemImage: "rectangle.stack.badge.plus",
                tint: Color.evSecondary
            ) { showAddList = true }
        }
    }

    private func addButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        count: Int,
        emptyText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.evSurfaceContainerHigh)
                    )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if count == 0 {
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    content()
                }
            }
            .lockListCard()
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(Color.evOutlineVariant)
            .padding(.leading, 52)
    }

    // MARK: - Rows

    private func appRow(_ app: LockListAppEntry) -> some View {
        HStack(spacing: 12) {
            NameWithIcon(name: app.label, kind: .app, titleFont: .body)
                .foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 8)
            if let bundleID = app.bundleID {
                Text(bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            deleteButton { deleteApp(app) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func listRow(_ list: String) -> some View {
        HStack(spacing: 12) {
            NameWithIcon(name: list, kind: .savedList, titleFont: .body)
                .foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 0)
            deleteButton { deleteList(list) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func categoryRow(_ category: LockListCategoryEntry) -> some View {
        HStack(spacing: 12) {
            NameWithIcon(name: category.displayName, kind: .category, titleFont: .body)
                .foregroundStyle(Color.evOnSurface)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current + future apps Apple classifies here")
                    .font(.caption2)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text("broad")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.evPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.evPrimary.opacity(0.08)))
            deleteButton { deleteCategory(category) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.evError)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove from lock list")
    }

    // MARK: - Delete / clear

    private func deleteApp(_ app: LockListAppEntry) {
        LocalAliasStore.shared.removeApplicationAliases(keys: app.keys)
        model.reload()
        Task { await syncToBackend() }
    }

    private func deleteCategory(_ category: LockListCategoryEntry) {
        LocalAliasStore.shared.removeCategory(named: category.name)
        model.reload()
        Task { await syncToBackend() }
    }

    private func deleteList(_ list: String) {
        LocalAliasStore.shared.removeList(named: list)
        model.reload()
        Task { await syncToBackend() }
    }

    private func clearAll() {
        LocalAliasStore.shared.removeAllAliases()
        model.reload()
        // Push an EMPTY snapshot so the backend drops everything too (snapshot
        // semantics). syncToBackend() bails on an empty local set, so clear the
        // backend explicitly here.
        Task {
            syncing = true
            defer { syncing = false }
            do {
                _ = try await apiClient.uploadChildAppCatalog(deviceID: childDeviceID, apps: [])
                syncBanner = nil
            } catch {
                syncBanner = "Cleared on this device, but couldn’t clear Evlin (\(error.localizedDescription))."
            }
        }
    }
}

// MARK: - Informed-Sentinel card chrome (file-private)

private extension View {
    /// White surface card with a hairline outline + the app's premium shadow.
    /// Mirrors the "Informed Sentinel" card idiom used across Evlin views.
    func lockListCard() -> some View {
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

#if DEBUG
#Preview {
    NavigationStack {
        LockListManagerView(
            familyID: UUID(),
            childDeviceID: UUID()
        )
        .environmentObject(APIClient())
    }
}
#endif
