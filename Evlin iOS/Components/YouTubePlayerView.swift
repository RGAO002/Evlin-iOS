import SwiftUI
import WebKit

struct YouTubePlayerView: View {
    let videoId: String
    let thumbnail: String
    @Binding var isPlaying: Bool

    var body: some View {
        Group {
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
                .accessibilityLabel("Play YouTube video")
            }
        }
    }
}

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
        // iOS 10+ : empty set means autoplay/play don't need a user
        // gesture. The thumbnail tap that flipped `isPlaying` already
        // counts as the user action, so this lets the embed load and
        // play immediately instead of staying on the YouTube poster.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        context.coordinator.loadedVideoId = videoId
        // baseURL must use https so the iframe is allowed to load
        // YouTube's player code.
        webView.loadHTMLString(
            Self.embedHTML(for: videoId),
            baseURL: URL(string: "https://www.youtube.com")
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoId != videoId else { return }
        context.coordinator.loadedVideoId = videoId
        webView.loadHTMLString(
            Self.embedHTML(for: videoId),
            baseURL: URL(string: "https://www.youtube.com")
        )
    }

    static func embedHTML(for videoId: String) -> String {
        // playsinline=1 is required on iOS so the player stays inside the
        // WKWebView (combined with `allowsInlineMediaPlayback = true`).
        // With playsinline=0 the player just shows the thumbnail and
        // never starts because the OS expects a native fullscreen
        // takeover that our embed never invokes.
        //
        // Embed host: switched from youtube-nocookie.com → youtube.com.
        // The nocookie variant has tighter referrer/embed policies and
        // some videos that allow regular embedding refuse to load there
        // ("Video unavailable" inside the iframe). Plain embed.youtube.com
        // is broadly compatible.
        //
        // Removed enablejsapi=1 — we don't post messages to the player and
        // it adds an extra origin check.
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background: #000000;
                }

                iframe {
                    width: 100%;
                    height: 100%;
                    border: 0;
                }
            </style>
        </head>
        <body>
            <iframe
                src="https://www.youtube.com/embed/\(videoId)?playsinline=1&autoplay=1&rel=0&modestbranding=1"
                title="YouTube video player"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
    }

    final class Coordinator {
        var loadedVideoId: String?
    }
}
