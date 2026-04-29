import SwiftUI
import WebKit

/// External-facing wrapper used by StrategyCard / VideoRecommendationCard.
///
/// Behavior (matches the pre-Error-153 user-remembered experience):
/// - Default: thumbnail + red play button.
/// - Tap (or external `isPlaying = true`) → swap in-place to an inline
///   WKWebView that auto-plays.
/// - User taps the YouTube player's fullscreen icon → iOS WebKit takes over
///   with system-native fullscreen chrome (Done button top-leading, AirPlay,
///   Picture-in-Picture, scrubber). This is what the user calls "iOS player
///   controls" — it's the OS chrome wrapping YouTube's iframe player.
///
/// Why we don't use loadHTMLString anymore:
/// YouTube tightened iframe embed Referer enforcement (Error 153) in late
/// 2025 / Apr 2026. `loadHTMLString(_, baseURL:)` produces an empty/synthetic
/// referrer that YouTube now rejects, regardless of baseURL.
/// `webView.load(URLRequest(url:))` to the actual embed URL is a real HTTP
/// navigation: the document IS the YouTube embed page, the origin IS
/// youtube.com, and sub-resource fetches get same-origin referrer naturally.
struct YouTubePlayerView: View {
    let videoId: String
    let thumbnail: String
    @Binding var isPlaying: Bool

    var body: some View {
        ZStack {
            if isPlaying {
                InlineYouTubeWebView(videoId: videoId)
                    .background(Color.black)
            } else {
                Button {
                    isPlaying = true
                } label: {
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
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Play YouTube video")
            }
        }
    }
}

/// Loads `https://www.youtube.com/embed/<id>?...` directly as the WKWebView's
/// document. Inline playback enabled; native iOS fullscreen chrome appears
/// when the user taps the player's fullscreen button.
struct InlineYouTubeWebView: UIViewRepresentable {
    let videoId: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // Empty set = autoplay/play don't require a user gesture. The
        // thumbnail tap that flipped isPlaying counts as the user gesture.
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

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
        // Real HTTP navigation to YouTube's embed page. Avoids the
        // loadHTMLString Referer trap that triggers YouTube Error 153.
        guard let url = URL(string:
            "https://www.youtube.com/embed/\(videoId)?playsinline=1&autoplay=1&rel=0&modestbranding=1"
        ) else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator { var loadedVideoId: String? }
}
