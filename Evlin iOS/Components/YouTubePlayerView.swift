import SwiftUI
import WebKit

/// External-facing wrapper used by StrategyCard / VideoRecommendationCard.
///
/// This intentionally matches the original working UX:
/// - thumbnail in the chat card
/// - tap -> inline WKWebView starts the YouTube embed in-place
/// - YouTube/WebKit owns the fullscreen button and media chrome
///
/// Do not wrap this in a SwiftUI fullScreenCover. That creates a second
/// fullscreen layer on top of WebKit's own media fullscreen, which is the
/// source of the "close one layer, reveal another layer" behavior.
struct YouTubePlayerView: View {
    let videoId: String
    let thumbnail: String
    @Binding var isPlaying: Bool
    @State private var localIsPlaying = false

    var body: some View {
        ZStack {
            if shouldPlay {
                InlineYouTubeWebView(videoId: videoId)
                    .background(Color.black)
            } else {
                Button {
#if DEBUG
                    print("[YouTubePlayer] thumbnail tapped videoId=\(videoId)")
#endif
                    localIsPlaying = true
                    isPlaying = true
                } label: {
                    thumbnailContent
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Play YouTube video")
            }
        }
        .onChange(of: isPlaying) { _, newValue in
            if newValue {
                localIsPlaying = true
            }
        }
    }

    private var shouldPlay: Bool {
        isPlaying || localIsPlaying
    }

    private var thumbnailContent: some View {
        ZStack {
            AsyncImage(url: URL(string: thumbnail)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.evPrimaryContainer)
            }

            Circle()
                .fill(Color.red)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.white)
                        .offset(x: 2)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
    }
}

/// Loads the YouTube embed URL as the WKWebView's top-level document.
///
/// YouTube now requires embedded players inside WebViews to identify the API
/// client. Direct top-level loading preserves the original inline player ->
/// WebKit fullscreen flow; the explicit Referer header avoids Error 153.
struct InlineYouTubeWebView: UIViewRepresentable {
    let videoId: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator

        context.coordinator.loadedVideoId = videoId
        load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoId != videoId else { return }
        context.coordinator.loadedVideoId = videoId
        load(into: webView)
    }

    private func load(into webView: WKWebView) {
        let identityURL = clientIdentityURL
        guard let embedURL = embedURL(identityURL: identityURL) else { return }
        var request = URLRequest(url: embedURL)
        request.setValue(identityURL.absoluteString, forHTTPHeaderField: "Referer")
#if DEBUG
        print("[YouTubePlayer] loading embed videoId=\(videoId) referer=\(identityURL.absoluteString) url=\(embedURL.absoluteString)")
#endif
        webView.load(request)
    }

    private var clientIdentityURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Bundle.main.bundleIdentifier?.lowercased() ?? "com.evlin.evlin-ios"
        return components.url ?? URL(string: "https://com.evlin.evlin-ios")!
    }

    private func embedURL(identityURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/embed/\(videoId)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "controls", value: "1"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "origin", value: identityURL.absoluteString),
            URLQueryItem(name: "widget_referrer", value: identityURL.absoluteString)
        ]
        return components.url
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedVideoId: String?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
#if DEBUG
            print("[YouTubePlayer] didStart url=\(webView.url?.absoluteString ?? "nil")")
#endif
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
#if DEBUG
            print("[YouTubePlayer] didCommit url=\(webView.url?.absoluteString ?? "nil")")
#endif
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
            print("[YouTubePlayer] didFinish url=\(webView.url?.absoluteString ?? "nil")")
#endif
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[YouTubePlayer] didFail error=\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[YouTubePlayer] didFailProvisional error=\(error.localizedDescription)")
        }
    }
}
