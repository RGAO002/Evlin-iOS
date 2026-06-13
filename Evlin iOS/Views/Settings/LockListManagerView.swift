import Combine
import FamilyControls
import SwiftUI

struct LockListAppEntry: Identifiable, Equatable {
    let label: String
    let keys: [String]
    let bundleID: String?

    var id: String {
        ([label] + keys + [bundleID ?? ""]).joined(separator: "|")
    }

    /// "Verified" once the row carries a bundle id (catalog / Family-Dictionary
    /// binding); "Manual" when it is a labeled token-only binding the parent
    /// typed by hand. Drives the per-row badge in the Installed apps section.
    var isVerified: Bool {
        guard let bundleID else { return false }
        return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A row is "labeled" when it has a human display name distinct from a bare
    /// bundle id / token key. Unlabeled rows are surfaced in the Advanced shield
    /// tokens section and block Save until labeled or removed.
    var hasHumanLabel: Bool {
        guard LockSetupSaveRules.appRowIsLabeled(displayName: label) else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // A label that is just a bundle id (contains ".") or equals the row's
        // own bundle id is not a human-friendly name.
        if let bundleID, trimmed.caseInsensitiveCompare(bundleID) == .orderedSame {
            return false
        }
        return !trimmed.contains(".")
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
    /// Apps with a usable human label (Installed apps section).
    let apps: [LockListAppEntry]
    /// Token-only rows with no human label (Advanced shield tokens section).
    let advancedTokens: [LockListAppEntry]
    let categories: [LockListCategoryEntry]
    let lists: [String]

    static func make(from store: any LockListStoreReading) -> LockListManagerSnapshot {
        let allApps = store.groupedApplicationAliases().map { entry in
            LockListAppEntry(
                label: entry.label,
                keys: entry.keys,
                bundleID: entry.bundleID
            )
        }
        let labeled = allApps
            .filter { $0.hasHumanLabel }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let unlabeled = allApps
            .filter { !$0.hasHumanLabel }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let categories = store.allCategoryNames()
            .map(LockListCategoryEntry.init(name:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let lists = store.allListNames()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return LockListManagerSnapshot(
            apps: labeled,
            advancedTokens: unlabeled,
            categories: categories,
            lists: lists
        )
    }
}

@MainActor
final class LockListManagerModel: ObservableObject {
    @Published private(set) var catalog: LockSetupCatalogPresentationModel = .init(
        apps: [],
        categories: [],
        lists: []
    )
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?
    @Published private(set) var localOnlyWarning: String?
    @Published private(set) var apps: [LockListAppEntry] = []
    @Published private(set) var advancedTokens: [LockListAppEntry] = []
    @Published private(set) var categories: [LockListCategoryEntry] = []
    @Published private(set) var lists: [String] = []

    private let store: any LockListStoreReading

    init() {
        self.store = LocalAliasStore.shared
    }

    init(store: any LockListStoreReading) {
        self.store = store
    }

    func apply(catalog: LockSetupCatalog) {
        self.catalog = LockSetupCatalogPresentationModel(catalog: catalog)
    }

    func reload() {
        let snapshot = LockListManagerSnapshot.make(from: store)
        apps = snapshot.apps
        advancedTokens = snapshot.advancedTokens
        categories = snapshot.categories
        lists = snapshot.lists
    }
}

enum LockSetupRecoveryPlanner {
    static func recoverableLocalApps(_ snapshot: LockListManagerSnapshot) -> [LockListAppEntry] {
        snapshot.apps + snapshot.advancedTokens
    }

    static func missingLocalApps(
        _ localApps: [LockListAppEntry],
        backend: LockSetupCatalogPresentationModel
    ) -> [LockListAppEntry] {
        localApps.filter { app in
            !backend.appRows.contains { row in
                row.title.caseInsensitiveCompare(app.label) == .orderedSame
                    && row.bundleID == app.bundleID
            }
        }
    }

    static func uploadApp(
        app: LockListAppEntry,
        tokenDataBase64: String,
        childDeviceIDChanged: Bool
    ) -> ChildAppCatalogUploadApp {
        ChildAppCatalogUploadApp(
            aliasKey: nil,
            displayName: app.label,
            tokenKind: "app",
            bundleID: app.bundleID,
            aliases: app.keys,
            tokenAvailable: true,
            tokenDataBase64: tokenDataBase64,
            sourceDeviceID: nil
        )
    }

    static func missingLocalCategories(
        _ localCategories: [LockListCategoryEntry],
        backend: LockSetupCatalogPresentationModel
    ) -> [LockListCategoryEntry] {
        localCategories.filter { category in
            !backend.categoryRows.contains { row in
                row.title.caseInsensitiveCompare(category.displayName) == .orderedSame
            }
        }
    }
}

enum LockSetupManagerMode {
    case settings
    case onboarding
}

struct LockListManagerView: View {
    @EnvironmentObject var apiClient: APIClient

    let familyID: UUID
    let childDeviceID: UUID
    let mode: LockSetupManagerMode
    let onCompleted: (() -> Void)?

    @StateObject private var model = LockListManagerModel()
    @State private var showAddApp = false
    @State private var showAddCategory = false
    @State private var showAddList = false
    @State private var syncing = false
    @State private var syncBanner: String?
    @State private var deletingTargetID: UUID?
    @State private var editListRow: LockSetupCatalogRow?

    init(
        familyID: UUID,
        childDeviceID: UUID,
        mode: LockSetupManagerMode = .settings,
        onCompleted: (() -> Void)? = nil
    ) {
        self.familyID = familyID
        self.childDeviceID = childDeviceID
        self.mode = mode
        self.onCompleted = onCompleted
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                addActions
                syncRow

                section(
                    title: "Apps",
                    count: model.catalog.appRows.count,
                    description: appsSectionDescription,
                    emptyText: "No apps saved yet. Tap “Add app”."
                ) {
                    ForEach(Array(model.catalog.appRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { rowDivider }
                        backendTargetRow(row, kind: .app) {
                            deleteTarget(row)
                        }
                    }
                }

                section(
                    title: "Categories",
                    count: model.catalog.categoryRows.count,
                    description: categoriesSectionDescription,
                    emptyText: "No categories saved yet. Tap “Add category”."
                ) {
                    ForEach(Array(model.catalog.categoryRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { rowDivider }
                        backendTargetRow(row, kind: .category) {
                            deleteTarget(row)
                        }
                    }
                }

                section(
                    title: "Lists",
                    count: model.catalog.listRows.count,
                    description: listsSectionDescription,
                    emptyText: "No lists yet. Group added apps and categories with “Create list”."
                ) {
                    ForEach(Array(model.catalog.listRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { rowDivider }
                        backendTargetRow(
                            row,
                            kind: .savedList,
                            canEdit: true,
                            onEdit: { editListRow = row }
                        ) {
                            deleteTarget(row)
                        }
                    }
                }

                if mode == .onboarding {
                    if !model.catalog.hasUsableTarget {
                        // Onboarding-only hint: the Continue button requires at
                        // least one target, but nothing on screen said so — this
                        // tells the kid up front. (Hidden in Settings mode.)
                        Text("Pick at least one app, category, or list so Evlin has something to lock.")
                            .font(.footnote)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                    }
                    continueButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .background(Color.evSurface.ignoresSafeArea())
        .navigationTitle("App Controls")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reloadFromBackend(recoverLocal: true)
        }
        .sheet(isPresented: $showAddApp) {
            NavigationStack {
                AddAppFlowView(childDeviceID: childDeviceID, mode: .app) { _ in
                    showAddApp = false
                    Task { await reloadFromBackend(recoverLocal: false) }
                }
                .environmentObject(apiClient)
            }
        }
        .sheet(isPresented: $showAddCategory) {
            NavigationStack {
                AddAppFlowView(childDeviceID: childDeviceID, mode: .category) { _ in
                    showAddCategory = false
                    Task { await reloadFromBackend(recoverLocal: false) }
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
                    Task { await reloadFromBackend(recoverLocal: false) }
                }
                .environmentObject(apiClient)
            }
        }
        .sheet(item: $editListRow) { row in
            NavigationStack {
                SavedListPickerView(
                    familyID: familyID,
                    owningDeviceID: childDeviceID,
                    mode: "child_device",
                    editingListID: row.id,
                    initialName: row.title
                ) { _ in
                    editListRow = nil
                    Task { await reloadFromBackend(recoverLocal: false) }
                }
                .environmentObject(apiClient)
            }
        }
    }

    private var continueButton: some View {
        Button {
            if model.catalog.hasUsableTarget {
                onCompleted?()
            } else {
                syncBanner = "Add at least one app, category, or list before continuing."
            }
        } label: {
            Text("Continue")
                .frame(maxWidth: .infinity)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.catalog.hasUsableTarget ? Color.white : Color.evOutline)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.catalog.hasUsableTarget ? Color.evPrimary : Color.evSurfaceContainerHighest)
        )
        .disabled(!model.catalog.hasUsableTarget || syncing)
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
                Text("App Controls")
                    .font(.headline)
                    .foregroundStyle(Color.evOnSurface)
                Text("Add apps and categories from this child's device. Apps support usage insights and app-specific time limits; categories and lists help lock broader sets of apps.")
                    .font(.subheadline)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .lockListCard()
    }

    // MARK: - Backend reload and recovery

    @ViewBuilder
    private var syncRow: some View {
        if syncing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading from Evlin…")
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

    private func reloadFromBackend(recoverLocal: Bool = true) async {
        syncing = true
        defer { syncing = false }
        do {
            let first = try await apiClient.fetchChildLockSetupCatalog(deviceID: childDeviceID)
            let backend = LockSetupCatalogPresentationModel(catalog: first)
            if recoverLocal {
                let localSnapshot = LockListManagerSnapshot.make(from: LocalAliasStore.shared)
                var uploads: [ChildAppCatalogUploadApp] = []
                let localApps = LockSetupRecoveryPlanner.recoverableLocalApps(localSnapshot)
                for app in LockSetupRecoveryPlanner.missingLocalApps(localApps, backend: backend) {
                    guard let key = app.keys.first,
                          let token = LocalAliasStore.shared.applicationToken(forLookupKey: key),
                          let blob = try? AppCatalogBlobEncoder.base64(token),
                          !blob.isEmpty else { continue }
                    uploads.append(LockSetupRecoveryPlanner.uploadApp(
                        app: app,
                        tokenDataBase64: blob,
                        childDeviceIDChanged: true
                    ))
                }
                for category in LockSetupRecoveryPlanner.missingLocalCategories(localSnapshot.categories, backend: backend) {
                    guard let token = LocalAliasStore.shared.categoryToken(forName: category.name),
                          let blob = try? AppCatalogBlobEncoder.base64(token),
                          !blob.isEmpty else { continue }
                    uploads.append(ChildAppCatalogUploadApp(
                        aliasKey: nil,
                        displayName: category.displayName,
                        tokenKind: "category",
                        bundleID: nil,
                        aliases: [category.name],
                        tokenAvailable: true,
                        tokenDataBase64: blob,
                        sourceDeviceID: childDeviceID
                    ))
                }
                if !uploads.isEmpty {
                    _ = try await apiClient.mergeChildAppCatalog(deviceID: childDeviceID, apps: uploads)
                    let refreshed = try await apiClient.fetchChildLockSetupCatalog(deviceID: childDeviceID)
                    model.apply(catalog: refreshed)
                    syncBanner = nil
                    return
                }
            }
            model.apply(catalog: first)
            syncBanner = nil
        } catch {
            syncBanner = "Couldn’t load Evlin lock setup: \(error.localizedDescription). Try again."
        }
    }

    // MARK: - Add actions

    private let appsSectionDescription = "Apps added from this child's device. Evlin can recognize them by name, show usage insights, set app-specific limits, and block or shield them when needed."
    private let categoriesSectionDescription = "Broad Apple categories like Games or Social. Shielding a category can cover matching apps now and apps installed later."
    private let listsSectionDescription = "Custom groups of apps and categories. Use a group when one rule should lock a mix, e.g. YouTube + Games + Netflix."

    private var addActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                addButton(
                    title: "Add app",
                    systemImage: "plus.app.fill",
                    tint: Color.evPrimary
                ) { showAddApp = true }

                addButton(
                    title: "Add category",
                    systemImage: "square.grid.2x2.fill",
                    tint: Color.evSecondary
                ) { showAddCategory = true }
            }

            addButton(
                title: "Create list",
                systemImage: "rectangle.stack.badge.plus",
                tint: Color.evTertiary
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
        description: String,
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

            Text(description)
                .font(.caption)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
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

    private func backendTargetRow(
        _ row: LockSetupCatalogRow,
        kind: NameIconKind,
        canEdit: Bool = false,
        onEdit: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            NameWithIcon(name: row.title, kind: kind, artworkURL: row.artworkURL, titleFont: .body)
                .foregroundStyle(Color.evOnSurface)
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)

            if canEdit, let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.evPrimary)
                .disabled(deletingTargetID == row.id)
            }

            Button(action: onDelete) {
                ZStack {
                    if deletingTargetID == row.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.evError)
            .disabled(deletingTargetID == row.id)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func deleteTarget(_ row: LockSetupCatalogRow) {
        guard deletingTargetID == nil else { return }
        deletingTargetID = row.id
        Task {
            defer { deletingTargetID = nil }
            do {
                try await apiClient.deleteChildAppControlTarget(deviceID: childDeviceID, aliasKey: row.id)
                await reloadFromBackend(recoverLocal: false)
            } catch {
                syncBanner = "Couldn't delete \(row.title): \(error.localizedDescription)"
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
