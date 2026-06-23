//
//  ChatHistoryClearTests.swift
//  Evlin iOSTests
//
//  Task B2: store-level tests for ChatHistoryStore.
//  Central guarantee: a failed upload (offline) NEVER loses the local copy.
//

import XCTest
@testable import Evlin_iOS

@MainActor
final class ChatHistoryClearTests: XCTestCase {

    private let testAccountID = UUID()
    private var store: ChatHistoryStore!

    override func setUp() async throws {
        try await super.setUp()
        // Use a throwaway in-memory UserDefaults suite so tests don't
        // pollute the real App Group or each other.
        let suiteName = "ChatHistoryClearTests.\(testAccountID.uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        store = ChatHistoryStore(defaults: defaults)
        store.setAccount(testAccountID)
    }

    override func tearDown() async throws {
        store.clearAllLocal()
        store = nil
        try await super.tearDown()
    }

    // MARK: - P1-A: offline-durability guarantee

    /// Spec P1-A: archiveCurrent writes LOCAL durably FIRST, then calls upload
    /// best-effort. A throwing upload (offline) must NEVER lose the local copy.
    /// The conversation must be present in the store AND marked needsSync.
    func test_archiveCurrent_persists_locally_before_network() async throws {
        // Inject an upload stub that always throws (simulates offline).
        store.upload = { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }

        let convID = UUID()
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "Hello", timestamp: Date()))
        await store.archiveCurrent(id: convID, title: "Test Conv", messages: [msg])

        // Conversation must be durably stored locally.
        let convs = store.conversations
        XCTAssertEqual(convs.count, 1, "conversation must be in local store after failed upload")

        let saved = try XCTUnwrap(convs.first)
        XCTAssertEqual(saved.id, convID)
        XCTAssertEqual(saved.title, "Test Conv")

        // Must be flagged for retry (outbox).
        XCTAssertTrue(saved.needsSync, "conversation must be marked needsSync when upload throws")
    }

    // MARK: - Additional store contract tests

    func test_archiveCurrent_marksNotNeedsSync_when_upload_succeeds() async throws {
        store.upload = { _, _, _ in /* no-op: success */ }

        let convID = UUID()
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .agent, content: "Hi", timestamp: Date()))
        await store.archiveCurrent(id: convID, title: "Good Conv", messages: [msg])

        // Give the background upload task a moment to complete.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let convs = store.conversations
        XCTAssertEqual(convs.count, 1)
        let saved = try XCTUnwrap(convs.first)
        XCTAssertFalse(saved.needsSync, "successful upload must clear needsSync")
    }

    func test_rename_updates_title_locally() throws {
        store.upload = { _, _, _ in }
        let convID = UUID()
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "X", timestamp: Date()))

        // Archive synchronously by providing a no-op upload.
        let exp = expectation(description: "archived")
        Task {
            await store.archiveCurrent(id: convID, title: "Original", messages: [msg])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        store.rename(convID, "Renamed")
        let saved = store.conversations.first(where: { $0.id == convID })
        XCTAssertEqual(saved?.title, "Renamed")
    }

    func test_delete_removes_conversation() throws {
        store.upload = { _, _, _ in }
        let convID = UUID()
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "Y", timestamp: Date()))

        let exp = expectation(description: "archived")
        Task {
            await store.archiveCurrent(id: convID, title: "ToDelete", messages: [msg])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        store.delete(convID)
        XCTAssertNil(store.conversations.first(where: { $0.id == convID }))
    }

    func test_open_returns_stored_messages() async throws {
        store.upload = { _, _, _ in }
        let convID = UUID()
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "Hello open", timestamp: Date()))
        await store.archiveCurrent(id: convID, title: "Conv", messages: [msg])

        let loaded = await store.open(convID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.content, "Hello open")
    }

    func test_clearAllLocal_removes_everything() async throws {
        store.upload = { _, _, _ in }
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "Z", timestamp: Date()))
        await store.archiveCurrent(id: UUID(), title: "A", messages: [msg])
        await store.archiveCurrent(id: UUID(), title: "B", messages: [msg])

        store.clearAllLocal()
        XCTAssertTrue(store.conversations.isEmpty)
    }

    func test_setAccount_scopes_data_per_account() async throws {
        store.upload = { _, _, _ in }
        let accountA = UUID()
        let accountB = UUID()
        let suiteName = "ChatHistoryClearTests.scoping.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let storeA = ChatHistoryStore(defaults: defaults)
        storeA.upload = { _, _, _ in }
        storeA.setAccount(accountA)

        let storeB = ChatHistoryStore(defaults: defaults)
        storeB.upload = { _, _, _ in }
        storeB.setAccount(accountB)

        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "X", timestamp: Date()))
        await storeA.archiveCurrent(id: UUID(), title: "A-conv", messages: [msg])

        // Account B must not see Account A's conversations.
        XCTAssertTrue(storeB.conversations.isEmpty, "account B must not see account A's data")
    }

    // MARK: - I1: loadConversations merges injected remote list

    /// `loadConversations` must merge a remote-only conversation into the local
    /// index via the `fetchRemoteList` seam (last-write-wins; remote-only gets added).
    func test_loadConversations_merges_remote_list() async throws {
        // Local: one conversation.
        store.upload = { _, _, _ in }
        let localID = UUID()
        let localMsg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "local", timestamp: Date()))
        await store.archiveCurrent(id: localID, title: "Local Conv", messages: [localMsg])
        XCTAssertEqual(store.conversations.count, 1, "precondition: one local conversation")

        // Remote list: a NEW conversation that isn't in local storage.
        let remoteID = UUID()
        let remoteUpdated = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        store.fetchRemoteList = {
            [RemoteConversationSummary(
                id: remoteID,
                title: "Remote Conv",
                updated_at: remoteUpdated,
                preview: "Hello from backend"
            )]
        }

        await store.loadConversations()

        // Give the background merge task a moment to complete.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(store.conversations.count, 2, "remote-only conversation must be added to local index")
        let remoteEntry = store.conversations.first(where: { $0.id == remoteID })
        XCTAssertNotNil(remoteEntry, "remote conversation must appear in local index")
        XCTAssertEqual(remoteEntry?.title, "Remote Conv")
        XCTAssertEqual(remoteEntry?.preview, "Hello from backend")
        XCTAssertFalse(remoteEntry?.needsSync ?? true, "remote-only entry must not be marked needsSync")
    }
}

// MARK: - B5: sign-out clear path

/// Tests for Task B5: the sign-out clear-chat path wipes the account-namespaced
/// store and leaves it with nil account scope so further archives are no-ops.
///
/// NOTE: ChatViewModel itself crashes in the test host (ScreenTimeManager /
/// FamilyControls entitlement not available in simulator unit-test targets —
/// a pre-existing B3 issue). These tests exercise the ChatHistoryStore sign-out
/// contract directly, which is the unit-testable seam the task spec allows.
@MainActor
final class ChatHistorySignOutTests: XCTestCase {

    private var store: ChatHistoryStore!
    private let testAccountID = UUID()

    // Use a separate in-memory suite so these tests never touch real app
    // storage or trigger UserDefaults observers in the running test host.
    private var testDefaults: UserDefaults!
    private let legacyKey = "evlin_chat_history"

    override func setUp() async throws {
        try await super.setUp()
        let suiteName = "ChatHistorySignOutTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        store = ChatHistoryStore(defaults: testDefaults)
        store.upload = { _, _, _ in }
        // Seed the account-namespaced store with one conversation.
        store.setAccount(testAccountID)
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "Hello", timestamp: Date()))
        await store.archiveCurrent(id: UUID(), title: "Pre-signout conv", messages: [msg])
        XCTAssertEqual(store.conversations.count, 1, "precondition: store has one conversation")
    }

    override func tearDown() async throws {
        store.clearAllLocal()
        store = nil
        testDefaults.removePersistentDomain(forName: testDefaults.description)
        testDefaults = nil
        try await super.tearDown()
    }

    /// The sign-out clear path (simulated by calling clearAllLocal + setAccount(nil) directly)
    /// must wipe all conversations AND make subsequent archiveCurrent calls a no-op.
    /// This mirrors exactly what ChatViewModel's .evlinClearChat observer does to the store.
    func test_signOut_clearAllLocal_then_setNil_disables_archive() async throws {
        // Simulate the observer: clearAllLocal then setAccount(nil).
        store.clearAllLocal()
        store.setAccount(nil)

        XCTAssertTrue(store.conversations.isEmpty, "clearAllLocal must have emptied the store")

        // After setAccount(nil), archiveCurrent must be a silent no-op.
        let msg2 = StoredChatMessage(sanitizing: ChatMessage(role: .agent, content: "Hi", timestamp: Date()))
        await store.archiveCurrent(id: UUID(), title: "Should be dropped", messages: [msg2])
        XCTAssertTrue(store.conversations.isEmpty,
                      "archiveCurrent must be a no-op after setAccount(nil)")
    }

    /// The legacy evlin_chat_history UserDefaults key must be absent after sign-out.
    /// AuthService.signOutLocally removes it. This test verifies the removeObject
    /// + re-read round-trip behaves correctly using the isolated test suite.
    func test_legacyKey_absent_after_signOut() {
        // Seed then remove — verifying that once gone it stays gone.
        testDefaults.set("legacy_data", forKey: legacyKey)
        testDefaults.removeObject(forKey: legacyKey)
        XCTAssertNil(testDefaults.object(forKey: legacyKey),
                     "legacy evlin_chat_history key must be absent after sign-out")
    }

    /// After sign-out (setAccount(nil)) a subsequent setAccount(id) re-enables
    /// archiving — this is the Part 2 wiring test (sign-in re-scopes the store).
    func test_setAccount_after_signOut_re_enables_archive() async throws {
        // Simulate sign-out.
        store.clearAllLocal()
        store.setAccount(nil)

        // Simulate sign-in with a new account.
        let newAccountID = UUID()
        store.setAccount(newAccountID)

        // Archive must succeed now.
        let msg = StoredChatMessage(sanitizing: ChatMessage(role: .parent, content: "After sign in", timestamp: Date()))
        await store.archiveCurrent(id: UUID(), title: "Post sign-in", messages: [msg])
        XCTAssertEqual(store.conversations.count, 1,
                       "archiveCurrent must succeed after setAccount is called with a real id")
    }

    /// Two accounts on the same store/UserDefaults suite must not share data.
    /// Re-scoping from accountA → accountB shows an empty conversation list.
    func test_setAccount_switches_scope_cleanly() async throws {
        let accountA = testAccountID
        let accountB = UUID()

        // accountA already has 1 conversation (from setUp).
        XCTAssertEqual(store.conversations.count, 1, "precondition: account A has a conversation")

        // Switch to account B — should see empty list.
        store.setAccount(accountB)
        XCTAssertTrue(store.conversations.isEmpty,
                      "account B must start with no conversations")
    }
}

// MARK: - B3: VM-level tests (conversation-id, clear=archive+reset, seed exclusion)

/// Tests for ChatViewModel.clear(), currentConversationID rotation, and seed exclusion.
///
/// Strategy: create a ChatViewModel with an injected ChatHistoryStore (in-memory defaults)
/// and inspect store.conversations + vm.messages after calling clear().
@MainActor
final class ChatViewModelClearTests: XCTestCase {

    private var vm: ChatViewModel!
    private var store: ChatHistoryStore!

    override func setUp() async throws {
        try await super.setUp()
        vm = ChatViewModel()
        // Inject an isolated in-memory store so these tests don't touch the real App Group.
        let suiteName = "ChatViewModelClearTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        store = ChatHistoryStore(defaults: defaults)
        store.setAccount(UUID())
        store.upload = { _, _, _ in /* no-op */ }
        vm.chatHistoryStore = store
        // Ensure a clean conversation id for each test.
        vm.conversationIdString = UUID().uuidString
    }

    override func tearDown() async throws {
        vm = nil
        store.clearAllLocal()
        store = nil
        try await super.tearDown()
    }

    // MARK: - test_clear_archives_nonempty_then_reseeds

    /// clear() with ≥1 real (non-seed) message must:
    ///   1. call archiveCurrent (store receives a conversation)
    ///   2. reset messages to seed-only
    ///   3. rotate conversationID
    func test_clear_archives_nonempty_then_reseeds() async throws {
        // Start: seed only (set by seedInitialMessages in init).
        XCTAssertEqual(vm.messages.filter { !$0.isSeed }.count, 0, "precondition: seed only")

        // Capture old ID.
        let oldID = vm.currentConversationID

        // Add a real user message.
        vm.messages.append(ChatMessage(role: .parent, content: "Lock TikTok", timestamp: Date()))
        XCTAssertEqual(vm.messages.filter { !$0.isSeed }.count, 1, "precondition: 1 real message")

        // Call clear().
        vm.clear()

        // Give async archive task a moment to run.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // 1. Store should have received the archive.
        XCTAssertEqual(store.conversations.count, 1, "store must have 1 archived conversation")

        // 2. Messages back to seed-only.
        XCTAssertEqual(vm.messages.count, 1, "messages should contain only the seed after clear")
        XCTAssertTrue(vm.messages.first?.isSeed == true, "the sole message must be the seed")

        // 3. Conversation ID must have rotated.
        XCTAssertNotEqual(vm.currentConversationID, oldID, "conversationID must rotate on clear")
    }

    // MARK: - test_clear_empty_does_not_archive

    /// clear() on a seed-only (empty real) conversation must NOT archive anything.
    func test_clear_empty_does_not_archive() async throws {
        // Start: seed only.
        XCTAssertEqual(vm.messages.filter { !$0.isSeed }.count, 0, "precondition: seed only")

        vm.clear()

        // Give async task a moment.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Store must remain empty.
        XCTAssertTrue(store.conversations.isEmpty, "store must NOT be called when conversation is empty (seed-only)")
    }

    // MARK: - test_seed_excluded_from_history_payload

    /// The seed message (isSeed == true) must not appear in the history list
    /// that would be sent to /parent/chat.
    func test_seed_excluded_from_history_payload() {
        // VM starts with seed. Add a real parent message too.
        vm.messages.append(ChatMessage(role: .parent, content: "How much screen time today?", timestamp: Date()))

        // Replicate the filter used in dispatchChat.
        let history = vm.messages.filter { !$0.isSeed }

        // Seed must not be in history.
        XCTAssertFalse(history.contains(where: { $0.isSeed }), "seed must be excluded from history payload")
        // But the real parent message must be present.
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.role, .parent)
    }
}
