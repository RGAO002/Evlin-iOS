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
}
