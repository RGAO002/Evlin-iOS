import XCTest
@testable import Evlin_iOS

final class ChatStreamClientTests: XCTestCase {
    func test_pre_connect_urlerrors_fallback() {
        for code in [URLError.cannotConnectToHost, .dnsLookupFailed,
                     .timedOut, .secureConnectionFailed] {
            XCTAssertEqual(ChatStreamClient.classify(
                statusCode: nil, urlError: URLError(code), gotHeaders: false),
                .fallbackToLegacy, "\(code)")
        }
    }

    func test_endpoint_missing_statuses_fallback() {
        for status in [404, 405, 501] {
            XCTAssertEqual(ChatStreamClient.classify(
                statusCode: status, urlError: nil, gotHeaders: true),
                .fallbackToLegacy)
        }
    }

    func test_server_responded_statuses_manual_retry() {
        for status in [403, 422, 429, 500, 502, 503] {
            if case .manualRetry = ChatStreamClient.classify(
                statusCode: status, urlError: nil, gotHeaders: true)! {} else {
                XCTFail("\(status) must be manualRetry")
            }
        }
    }

    func test_post_headers_drop_is_manual_retry() {
        if case .manualRetry = ChatStreamClient.classify(
            statusCode: 200, urlError: URLError(.networkConnectionLost),
            gotHeaders: true)! {} else { XCTFail() }
    }

    func test_401_is_not_classified_here() {
        // 401 is handled by the refresh path BEFORE classification.
        XCTAssertNil(ChatStreamClient.classify(
            statusCode: 401, urlError: nil, gotHeaders: true))
    }
}
