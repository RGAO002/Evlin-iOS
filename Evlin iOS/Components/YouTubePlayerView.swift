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

        if #available(iOS 10.0, *) {
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        context.coordinator.loadedVideoId = videoId
        webView.loadHTMLString(Self.embedHTML(for: videoId), baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoId != videoId else { return }
        context.coordinator.loadedVideoId = videoId
        webView.loadHTMLString(Self.embedHTML(for: videoId), baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }

    static func embedHTML(for videoId: String) -> String {
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
                src="https://www.youtube-nocookie.com/embed/\(videoId)?playsinline=0&autoplay=1&rel=0&modestbranding=1"
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
