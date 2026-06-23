//
//  ChatHistoryStore.swift
//  Evlin iOS
//
//  Task B2: durable, account-namespaced local store of conversations with an
//  injected upload seam (outbox pattern for offline resilience).
//
//  Spec P1-A guarantee: `archiveCurrent` writes the local copy FIRST, then
//  calls `upload` best-effort. A failed upload marks `needsSync` and NEVER
//  loses the local data. Failed uploads are retried on `loadConversations`.
//

import Combine
import Foundation

// MARK: - ConversationSummary

/// Lightweight metadata record for one archived conversation. Stored as JSON
/// in UserDefaults, keyed per account (`chatconv.<accountID>.index`).
struct ConversationSummary: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String?
    let createdAt: Date
    var updatedAt: Date
    /// `true` when the last `upload` attempt failed; retried on next
    /// `loadConversations` call (outbox pattern).
    var needsSync: Bool
}

// MARK: - ChatHistoryStore

/// Durable, account-namespaced local store for chat conversations.
///
/// ### Offline-durability guarantee (spec P1-A)
/// `archiveCurrent` writes the local copy synchronously FIRST, then fires an
/// async background task to call `upload`. On failure the record is flagged
/// `needsSync = true` so no data is ever lost. The outbox is retried on the
/// next `loadConversations` call.
///
/// ### Account namespacing
/// All UserDefaults keys are prefixed `chatconv.<accountID>.` so multiple
/// accounts on the same device never share data. `setAccount(_:)` must be
/// called after sign-in. `clearAllLocal()` is called on sign-out.
///
/// ### Testability seam
/// The `upload` closure is a mutable var — tests inject a throwing stub to
/// exercise the outbox path without any real network.
@MainActor
final class ChatHistoryStore: ObservableObject {

    // MARK: - Types

    private enum Keys {
        static func index(for accountID: UUID) -> String {
            "chatconv.\(accountID.uuidString).index"
        }
        static func messages(for accountID: UUID, convID: UUID) -> String {
            "chatconv.\(accountID.uuidString).messages.\(convID.uuidString)"
        }
    }

    // MARK: - Published state

    /// The in-memory list of conversation summaries for the current account.
    @Published private(set) var conversations: [ConversationSummary] = []

    // MARK: - Upload seam

    /// Called after a successful local write. Tests inject a throwing stub.
    /// The default implementation will be wired to `APIClient` in Task B4.
    var upload: (_ id: UUID, _ title: String?, _ messages: [StoredChatMessage]) async throws -> Void = { _, _, _ in
        // Default no-op until wired in Task B4 (APIClient.authedRequest PUT).
        // Intentionally does not throw so a fresh install stays in-sync=true.
    }

    // MARK: - Private storage

    private let defaults: UserDefaults
    private var accountID: UUID?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    /// - Parameter defaults: The `UserDefaults` suite to use. Defaults to the
    ///   shared App Group suite (`group.com.evlin.ios`). Tests pass an
    ///   in-memory suite to avoid polluting real storage.
    init(defaults: UserDefaults = UserDefaults(suiteName: "group.com.evlin.ios") ?? .standard) {
        self.defaults = defaults
    }

    // MARK: - Account lifecycle

    /// Call after sign-in. Switches the active account and reloads the index.
    func setAccount(_ id: UUID?) {
        accountID = id
        conversations = id.map { loadIndex(for: $0) } ?? []
    }

    // MARK: - Archive (write-local-first)

    /// Durably archives `messages` into the local store FIRST, then attempts
    /// `upload` best-effort. A failed upload marks the record `needsSync`.
    ///
    /// This is the central offline-durability guarantee: even if the network
    /// is down, the conversation is never lost.
    func archiveCurrent(id: UUID, title: String?, messages: [StoredChatMessage]) async {
        guard let accountID else { return }

        // 1. Write messages blob.
        saveMessages(messages, for: accountID, convID: id)

        // 2. Upsert the summary in the index — marked needsSync until upload succeeds.
        let now = Date()
        var summary = conversations.first(where: { $0.id == id })
            ?? ConversationSummary(id: id, title: title, createdAt: now, updatedAt: now, needsSync: true)
        summary.title = title
        summary.updatedAt = now
        summary.needsSync = true
        upsert(summary, for: accountID)

        // 3. Fire background upload — best-effort; local copy is already safe.
        let uploadClosure = self.upload
        Task { [weak self] in
            do {
                try await uploadClosure(id, title, messages)
                // Upload succeeded — clear the needsSync flag.
                await self?.markSynced(id: id, accountID: accountID)
            } catch {
                // Upload failed — outbox flag already set; retry on next loadConversations.
            }
        }
    }

    // MARK: - Load

    /// Reloads the conversation index and retries any outbox entries.
    func loadConversations() async {
        guard let accountID else { return }
        conversations = loadIndex(for: accountID)
        await retryOutbox(for: accountID)
    }

    // MARK: - Open

    /// Returns the stored messages for a conversation, or empty if not found.
    func open(_ id: UUID) async -> [StoredChatMessage] {
        guard let accountID else { return [] }
        return loadMessages(for: accountID, convID: id)
    }

    // MARK: - Rename

    func rename(_ id: UUID, _ title: String) {
        guard let accountID else { return }
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        conversations[idx].updatedAt = Date()
        saveIndex(conversations, for: accountID)
    }

    // MARK: - Delete

    func delete(_ id: UUID) {
        guard let accountID else { return }
        conversations.removeAll { $0.id == id }
        saveIndex(conversations, for: accountID)
        defaults.removeObject(forKey: Keys.messages(for: accountID, convID: id))
    }

    // MARK: - Sign-out

    /// Clears all local data for the current account. Call on sign-out.
    func clearAllLocal() {
        guard let accountID else {
            conversations = []
            return
        }
        // Remove all message blobs for each conversation.
        for conv in conversations {
            defaults.removeObject(forKey: Keys.messages(for: accountID, convID: conv.id))
        }
        // Remove the index.
        defaults.removeObject(forKey: Keys.index(for: accountID))
        conversations = []
    }

    // MARK: - Private helpers

    private func loadIndex(for accountID: UUID) -> [ConversationSummary] {
        guard let data = defaults.data(forKey: Keys.index(for: accountID)),
              let list = try? decoder.decode([ConversationSummary].self, from: data)
        else { return [] }
        return list
    }

    private func saveIndex(_ list: [ConversationSummary], for accountID: UUID) {
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: Keys.index(for: accountID))
    }

    private func loadMessages(for accountID: UUID, convID: UUID) -> [StoredChatMessage] {
        guard let data = defaults.data(forKey: Keys.messages(for: accountID, convID: convID)),
              let msgs = try? decoder.decode([StoredChatMessage].self, from: data)
        else { return [] }
        return msgs
    }

    private func saveMessages(_ messages: [StoredChatMessage], for accountID: UUID, convID: UUID) {
        guard let data = try? encoder.encode(messages) else { return }
        defaults.set(data, forKey: Keys.messages(for: accountID, convID: convID))
    }

    private func upsert(_ summary: ConversationSummary, for accountID: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == summary.id }) {
            conversations[idx] = summary
        } else {
            conversations.insert(summary, at: 0)
        }
        saveIndex(conversations, for: accountID)
    }

    @MainActor
    private func markSynced(id: UUID, accountID: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].needsSync = false
        saveIndex(conversations, for: accountID)
    }

    private func retryOutbox(for accountID: UUID) async {
        let pending = conversations.filter { $0.needsSync }
        guard !pending.isEmpty else { return }
        let uploadClosure = self.upload
        for summary in pending {
            let msgs = loadMessages(for: accountID, convID: summary.id)
            Task { [weak self] in
                do {
                    try await uploadClosure(summary.id, summary.title, msgs)
                    await self?.markSynced(id: summary.id, accountID: accountID)
                } catch {
                    // Still offline — keep needsSync=true, retry next time.
                }
            }
        }
    }
}
