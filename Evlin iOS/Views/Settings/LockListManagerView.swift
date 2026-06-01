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

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                addActions

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
        .onAppear { model.reload() }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func listRow(_ list: String) -> some View {
        HStack(spacing: 12) {
            NameWithIcon(name: list, kind: .savedList, titleFont: .body)
                .foregroundStyle(Color.evOnSurface)
            Spacer(minLength: 0)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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
