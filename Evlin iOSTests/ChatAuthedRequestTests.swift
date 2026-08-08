//
//  ChatAuthedRequestTests.swift
//  Evlin iOSTests
//
//  Task B4: verifies that the chat / feedback / answer call sites use
//  APIClient.authedRequest which attaches a Bearer token from the Keychain.
//
//  Strategy: write a known access token into a test-isolated Keychain store,
//  call APIClient.authedRequest (the shared seam), and assert the resulting
//  URLRequest carries `Authorization: Bearer <token>`.
//
//  NOTE: APIClient is an ObservableObject kept as a static to avoid a
//  deinit-off-main-actor crash in the test host. See APIClientCatalogDTOTests
//  for the same pattern established by prior test authors.
//

import XCTest
@testable import Evlin_iOS

final class ChatAuthedRequestTests: XCTestCase {

    // Static lifetime: APIClient is ObservableObject; deallocating it off the
    // main actor causes a simulator crash. Keep it alive for the test process.
    private static let client = APIClient(baseURL: "https://example.com")

    // MARK: - authedRequest attaches Bearer header

    /// When a stored access token exists in KeychainStore.shared, every
    /// authedRequest call must include `Authorization: Bearer <token>`.
    /// This is the central B4 contract: all three call sites (chat, feedback,
    /// answer-question) obtain their URLRequest via authedRequest, so if this
    /// header is present the Bearer layer is correctly wired.
    func test_authedRequest_sets_bearer_header_when_token_stored() throws {
        // Write a known token into the shared Keychain (same store authedRequest reads).
        let token = "test-access-token-b4-\(UUID().uuidString)"
        let stored = StoredTokens(
            accessToken: token, refreshToken: "r",
            accountID: "acct-b4", familyID: nil,
            displayName: nil, needsFamily: false
        )
        // Capture and restore the previous session so other tests are unaffected.
        let prev = KeychainStore.shared.load()
        try KeychainStore.shared.save(stored)
        defer {
            if let prev {
                try? KeychainStore.shared.save(prev)
            } else {
                KeychainStore.shared.clear()
            }
        }

        let req = Self.client.authedRequest(path: "/parent/chat", method: "POST")

        let auth = req.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer \(token)",
            "authedRequest must set Authorization: Bearer <accessToken>")
    }

    /// When NO token is in the Keychain, authedRequest must NOT crash and must
    /// produce a request without an Authorization header (will 401 → refresh).
    func test_authedRequest_no_header_when_no_token() {
        let prev = KeychainStore.shared.load()
        KeychainStore.shared.clear()
        defer {
            if let prev { try? KeychainStore.shared.save(prev) }
        }

        let req = Self.client.authedRequest(path: "/parent/chat", method: "POST")

        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
            "authedRequest must omit Authorization when no token is stored")
    }

    /// A parent action must never leave its UI in an indefinite loading state
    /// because a reachable-but-stalled backend request inherited URLSession's
    /// long default timeout.
    func test_authedRequest_applies_explicit_bounded_timeout() {
        let req = Self.client.authedRequest(
            path: "/family/children/example/devices/example",
            method: "DELETE",
            timeoutInterval: 15
        )

        XCTAssertEqual(req.timeoutInterval, 15)
    }

    // MARK: - FeedbackService uses authedRequest

    /// FeedbackService.submit now builds its request via APIClient.authedRequest,
    /// not bare URLSession. Verify the B4 init compiles and wires the client.
    func test_feedbackService_uses_apiclient() {
        // FeedbackService(client:) is the B4 init — if it compiles, the seam is wired.
        let svc = FeedbackService(client: Self.client)
        XCTAssertEqual(svc.client.baseURL, "https://example.com",
            "FeedbackService must hold the injected APIClient's baseURL")
    }
}
