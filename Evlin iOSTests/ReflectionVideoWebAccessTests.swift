import XCTest
@testable import Evlin_iOS

final class ReflectionVideoWebAccessTests: XCTestCase {
    func test_embed_url_uses_privacy_enhanced_youtube_host() throws {
        let identity = try XCTUnwrap(URL(string: "https://com.evlin.evlin-ios"))

        let url = try XCTUnwrap(
            ReflectionVideoWebAccess.embedURL(videoId: "dQw4w9WgXcQ", identityURL: identity)
        )

        XCTAssertEqual(url.host, "www.youtube-nocookie.com")
        XCTAssertEqual(url.path, "/embed/dQw4w9WgXcQ")
        XCTAssertFalse(url.absoluteString.contains("www.youtube.com"))
    }
}
