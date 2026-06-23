//
//  ChatHistorySheet.swift
//  Evlin iOS
//
//  Task B7: History sheet — native .sheet with grabber + swipe-down dismiss,
//  "Clear current chat" row, and a List of archived conversations with
//  swipe-to-delete and inert open (no ack polls).
//

import SwiftUI

struct ChatHistorySheet: View {
    @ObservedObject var store: ChatHistoryStore
    let vm: ChatViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            List {
                // MARK: - Clear current chat

                Section {
                    Button(role: .destructive) {
                        vm.clear()
                        isPresented = false
                    } label: {
                        Label("Clear current chat", systemImage: "trash")
                    }
                }

                // MARK: - Past conversations

                Section {
                    if store.conversations.isEmpty {
                        Text("No saved conversations yet.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(store.conversations) { summary in
                            Button {
                                Task {
                                    await vm.openConversation(summary.id)
                                    isPresented = false
                                }
                            } label: {
                                ConversationRow(summary: summary)
                            }
                            .tint(.primary)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let id = store.conversations[index].id
                                store.delete(id)
                            }
                        }
                    }
                } header: {
                    Text("Past Conversations")
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .task {
            await store.loadConversations()
        }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title ?? "Evlin")
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(summary.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let preview = summary.preview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
