//
//  MemoryView.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.10 — Settings → "What Evlin remembers".
//  Lists user/agent memory rows grouped by category, with edit/delete
//  swipe actions and pull-to-refresh.
//

import SwiftUI

struct MemoryView: View {
    let familyId: UUID
    @State private var memories: [Memory] = []
    @State private var loading = false
    @State private var editing: Memory?

    private var grouped: [(MemoryCategory, [Memory])] {
        Dictionary(grouping: memories, by: \.category)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.0) { (cat, items) in
                Section(cat.displayName) {
                    ForEach(items) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.text)
                            HStack {
                                if m.userLocked {
                                    Label("Locked", systemImage: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Text(m.confidence)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Edit") { editing = m }.tint(.blue)
                            Button("Delete", role: .destructive) {
                                Task { await delete(m) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("What Evlin remembers")
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing) { m in
            EditMemorySheet(memory: m) { updated in
                editing = nil
                if updated { Task { await reload() } }
            }
        }
        .overlay { if loading { ProgressView() } }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do { memories = try await MemoryService().list(familyId: familyId) }
        catch { print("memory list failed: \(error)") }
    }

    private func delete(_ m: Memory) async {
        do {
            try await MemoryService().delete(id: m.id)
            await reload()
        } catch { print("delete failed: \(error)") }
    }
}

private struct EditMemorySheet: View {
    let memory: Memory
    let onClose: (Bool) -> Void
    @State private var text: String

    init(memory: Memory, onClose: @escaping (Bool) -> Void) {
        self.memory = memory
        self.onClose = onClose
        self._text = State(initialValue: memory.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Memory text", text: $text, axis: .vertical)
            }
            .navigationTitle("Edit memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let body = MemoryUpdateBody(text: text, category: nil)
                            _ = try? await MemoryService().update(id: memory.id, body: body)
                            onClose(true)
                        }
                    }
                    .disabled(text.count < 10)
                }
            }
        }
    }
}
