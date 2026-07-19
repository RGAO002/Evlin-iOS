import XCTest
@testable import Evlin_iOS

final class ReflectionVideoWebAccessTests: XCTestCase {
    /// C-3 architecture guard: the reflection video view must never write
    /// ManagedSettings shield fields directly. Web access for reflection
    /// playback is a record-level attribute (`ShieldRecord.webOpen`) honored
    /// by ActiveLockStore's projection — the single main-app writer.
    func test_video_source_has_no_direct_managed_settings_write() throws {
        let source = try sourceText("Evlin iOS/Views/Child/BigKid/Reflection/BigKidVideoView.swift")
        XCTAssertFalse(source.contains("ManagedSettingsStore()"))
        XCTAssertFalse(source.contains("allowPlaybackInEmbeddedWebView"))
    }

    /// Resolve repository paths from `#filePath` (never the process cwd).
    private func sourceText(_ repoRelativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Evlin iOSTests
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent(repoRelativePath),
            encoding: .utf8
        )
    }

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
