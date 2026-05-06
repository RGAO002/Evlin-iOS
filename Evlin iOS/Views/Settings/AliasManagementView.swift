// Evlin iOS/Views/Settings/AliasManagementView.swift
//
// Parent-facing screen for reviewing and editing the chat → app/category
// alias map. When the parent says "lock IG" the chat agent looks up
// "Instagram" in `LocalAliasStore`. If they tagged the wrong thing (e.g.
// picked "Facebook" when the agent asked "which app is IG?"), every
// future "lock IG" misroutes — and there was no way to clean it up
// without reinstalling. This view surfaces the saved aliases and lets
// the parent delete individual entries or wipe the whole table.

import SwiftUI

struct AliasManagementView: View {
    @State private var apps: [(label: String, keys: [String], bundleID: String?)] = []
    @State private var categories: [String] = []
    @State private var lists: [String] = []
    @State private var showClearAllConfirm = false

    var body: some View {
        List {
            Section {
                Text("These are the names you've taught Evlin so far. Delete an entry if you tagged the wrong app or category — Evlin will ask again next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apps (\(apps.count))") {
                if apps.isEmpty {
                    Text("No app aliases saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps, id: \.label) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            NameWithIcon(name: entry.label, kind: .app, titleFont: .body)
                            if let bid = entry.bundleID {
                                Text(bid)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 32)
                            }
                            let aliasKeys = entry.keys.filter { $0 != entry.bundleID?.lowercased() }
                            if aliasKeys.count > 1 {
                                Text("Also matches: \(aliasKeys.filter { $0 != entry.label.lowercased() }.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            LocalAliasStore.shared.removeApplicationAliases(keys: apps[i].keys)
                        }
                        reload()
                    }
                }
            }

            Section("Categories (\(categories.count))") {
                if categories.isEmpty {
                    Text("No category aliases saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categories, id: \.self) { name in
                        NameWithIcon(name: name, kind: .category, titleFont: .body)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            LocalAliasStore.shared.removeCategory(named: categories[i])
                        }
                        reload()
                    }
                }
            }

            if !lists.isEmpty {
                Section("Saved Lists (\(lists.count))") {
                    ForEach(lists, id: \.self) { name in
                        NameWithIcon(name: name, kind: .savedList, titleFont: .body)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Label("Clear all saved aliases", systemImage: "trash")
                }
            } footer: {
                Text("Resets the entire name → app/category map. Active shields are not affected; only the chat lookup table is cleared.")
            }
        }
        .navigationTitle("Saved tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear { reload() }
        .confirmationDialog(
            "Clear every saved alias?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) {
                LocalAliasStore.shared.removeAllAliases()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Evlin will ask again the next time you say 'lock Instagram', 'lock games', etc.")
        }
    }

    private func reload() {
        apps = LocalAliasStore.shared.groupedApplicationAliases()
        categories = LocalAliasStore.shared.allCategoryNames()
        lists = LocalAliasStore.shared.allListNames()
    }
}

#if DEBUG
#Preview {
    NavigationStack { AliasManagementView() }
}
#endif
