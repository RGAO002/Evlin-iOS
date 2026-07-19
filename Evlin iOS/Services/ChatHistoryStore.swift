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
//  I1: a `fetchRemote` seam lets `loadConversations` merge the backend list
//  (last-write-wins by `updated_at`) and `open(_:)` hydrate a missing blob.
//  Default implementation is a no-op so B2/B3 unit tests (no network) still
//  pass without change.
//

import Combine
import Foundation

// MARK: - ConversationUploadPayload

/// Wire-format for PUT /parent/chat/conversations/{id}.
/// Sent via authedRequest in Task B4 when a conversation is archived.
struct ConversationUploadPayload: Codable {
    let title: String?
    let messages: [StoredChatMessage]
}

// MARK: - Remote DTOs (I1)

/// Wire-format for one entry in GET /parent/chat/conversations.
struct RemoteConversationSummary: Decodable {
    let id: UUID
    let title: String?
    let updated_at: String   // ISO-8601
    let preview: String?
}

/// Wire-format for GET /parent/chat/conversations/{id}.
struct RemoteConversationDetail: Decodable {
    let id: UUID
    let title: String?
    let updated_at: String   // ISO-8601
    let messages: [StoredChatMessage]
}

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
    /// Short preview of the last message (~80 chars). Populated on
    /// `archiveCurrent` and from the remote list's `preview` field (B7/I1).
    var preview: String?
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
/// ### Testability seams
/// `upload` and `fetchRemote` are mutable vars — tests inject stubs to
/// exercise paths without any real network.
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

    // MARK: - FetchRemote seam (I1)

    /// Called by `loadConversations` to get the remote summary list, and by
    /// `open(_:)` to hydrate a missing message blob. Default is a no-op so
    /// existing B2/B3 unit tests (which inject no network) still pass.
    ///
    /// The first closure returns `[RemoteConversationSummary]` (the list endpoint).
    /// The second closure returns `RemoteConversationDetail` for one id (the detail endpoint).
    var fetchRemoteList: () async throws -> [RemoteConversationSummary] = {
        return []
    }
    var fetchRemoteDetail: (_ id: UUID) async throws -> RemoteConversationDetail = { id in
        throw URLError(.unsupportedURL)
    }

    // MARK: - Private storage

    private let defaults: UserDefaults
    private var accountID: UUID?

    /// Read-only view of the account this store is currently bound to (`nil`
    /// before `setAccount(_:)` runs). `ChatViewModel.ensureAccountBound()` uses
    /// this to skip a redundant Keychain read once binding has happened.
    var boundAccountID: UUID? { accountID }

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

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Init

    /// - Parameter defaults: The `UserDefaults` suite to use. Defaults to the
    ///   shared App Group suite (`group.com.evlin.ios`). Tests pass an
    ///   in-memory suite to avoid polluting real storage.
    init(defaults: UserDefaults = UserDefaults(suiteName: "group.com.evlin.ios") ?? .standard) {
        self.defaults = defaults
    }

    nonisolated deinit {}

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

        // 2. Derive preview from the last non-empty message content (~80 chars).
        let previewText: String? = messages.reversed()
            .first(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { msg in
                let raw = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.count > 80 ? String(raw.prefix(80)) + "…" : raw
            }

        // 3. Upsert the summary in the index — marked needsSync until upload succeeds.
        let now = Date()
        var summary = conversations.first(where: { $0.id == id })
            ?? ConversationSummary(id: id, title: title, createdAt: now, updatedAt: now, needsSync: true)
        summary.title = title
        summary.updatedAt = now
        summary.needsSync = true
        summary.preview = previewText ?? summary.preview
        upsert(summary, for: accountID)

        // 4. Fire background upload — best-effort; local copy is already safe.
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

    // MARK: - Load (with remote merge, I1)

    /// Reloads the conversation index, best-effort merges the remote list
    /// (last-write-wins by `updated_at`), and retries any outbox entries.
    /// Network failure is silently ignored — local data is always shown.
    func loadConversations() async {
        guard let accountID else { return }
        conversations = loadIndex(for: accountID)

        // I1: fetch remote list best-effort and merge into local index.
        Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await self.fetchRemoteList()
                await self.mergeRemoteList(remote, accountID: accountID)
            } catch {
                // Offline or auth error — local data is already shown, no action needed.
            }
        }

        await retryOutbox(for: accountID)
    }

    // MARK: - Open (with remote hydration, I1)

    /// Returns the stored messages for a conversation. When the local blob is
    /// missing or empty, attempts to fetch the detail from the backend first
    /// (best-effort; returns empty on failure so UI stays responsive).
    func open(_ id: UUID) async -> [StoredChatMessage] {
        guard let accountID else { return [] }
        let local = loadMessages(for: accountID, convID: id)
        if !local.isEmpty { return local }

        // I1: no local blob — try to hydrate from backend.
        do {
            let detail = try await fetchRemoteDetail(id)
            if !detail.messages.isEmpty {
                saveMessages(detail.messages, for: accountID, convID: id)
                // Update summary metadata from remote detail.
                let isoDate = Self.iso8601.date(from: detail.updated_at) ?? Date()
                if let idx = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[idx].updatedAt = isoDate
                    conversations[idx].title = detail.title ?? conversations[idx].title
                    saveIndex(conversations, for: accountID)
                }
                return detail.messages
            }
        } catch {
            // Offline or not found — fall through and return empty.
        }
        return []
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

    /// I1: merge the remote summary list into the local index.
    /// Last-write-wins by `updated_at`; remote-only entries are added.
    @MainActor
    private func mergeRemoteList(_ remote: [RemoteConversationSummary], accountID: UUID) {
        var changed = false
        for rem in remote {
            let remDate = Self.iso8601.date(from: rem.updated_at)
                // Fallback: try without fractional seconds.
                ?? ISO8601DateFormatter().date(from: rem.updated_at)
                ?? Date(timeIntervalSince1970: 0)

            if let idx = conversations.firstIndex(where: { $0.id == rem.id }) {
                // Existing local entry — only update if remote is newer.
                if remDate > conversations[idx].updatedAt {
                    conversations[idx].title = rem.title ?? conversations[idx].title
                    conversations[idx].updatedAt = remDate
                    conversations[idx].preview = rem.preview ?? conversations[idx].preview
                    changed = true
                }
            } else {
                // Remote-only conversation — add to local index (blob hydrated lazily in open).
                let summary = ConversationSummary(
                    id: rem.id,
                    title: rem.title,
                    createdAt: remDate,
                    updatedAt: remDate,
                    needsSync: false,
                    preview: rem.preview
                )
                conversations.append(summary)
                changed = true
            }
        }
        if changed {
            // Re-sort newest-first.
            conversations.sort { $0.updatedAt > $1.updatedAt }
            saveIndex(conversations, for: accountID)
        }
    }
}
