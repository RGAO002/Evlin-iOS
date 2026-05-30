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

protocol LockListStoreReading {
    func groupedApplicationAliases() -> [(label: String, keys: [String], bundleID: String?)]
    func allListNames() -> [String]
}

extension LocalAliasStore: LockListStoreReading {}

struct LockListManagerSnapshot: Equatable {
    let apps: [LockListAppEntry]
    let lists: [String]

    static func make(from store: any LockListStoreReading) -> LockListManagerSnapshot {
        let apps = store.groupedApplicationAliases().map { entry in
            LockListAppEntry(
                label: entry.label,
                keys: entry.keys,
                bundleID: entry.bundleID
            )
        }
        let lists = store.allListNames()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return LockListManagerSnapshot(apps: apps, lists: lists)
    }
}

@MainActor
final class LockListManagerModel: ObservableObject {
    @Published private(set) var apps: [LockListAppEntry] = []
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
        List {
            Section {
                Text("Manage the apps and saved lists Evlin can lock from this device. This screen only reads local Screen Time aliases; active locks are not changed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showAddApp = true
                } label: {
                    Label("Add app", systemImage: "plus.app")
                }

                Button {
                    showAddList = true
                } label: {
                    Label("Add list", systemImage: "rectangle.stack.badge.plus")
                }
            }

            Section("Apps (\(model.apps.count))") {
                if model.apps.isEmpty {
                    Text("No apps saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.apps) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            NameWithIcon(name: app.label, kind: .app, titleFont: .body)
                            if let bundleID = app.bundleID {
                                Text(bundleID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                }
            }

            Section("Saved Lists (\(model.lists.count))") {
                if model.lists.isEmpty {
                    Text("No saved lists yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.lists, id: \.self) { list in
                        NameWithIcon(name: list, kind: .savedList, titleFont: .body)
                    }
                }
            }
        }
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
