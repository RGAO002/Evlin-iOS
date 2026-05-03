import SwiftUI
import WebKit

/// Reflection step 1 — kid watches the assigned YouTube video.
///
/// **Why no JS-bridge progress detection:** YouTube's IFrame API
/// hosted via `loadHTMLString` triggers Player Error 152/153 on
/// recent embeds (Apr 2026 Referer enforcement tightening). The
/// chat side worked around this in `Components/YouTubePlayerView.swift`
/// by loading the embed as a real HTTP request with an explicit
/// `Referer` header — same approach here. The trade-off is we lose
/// JS access to player events, so we estimate progress with a
/// SwiftUI timer driven off a fixed expected duration. Kid still
/// can't skip (controls hidden), and the timer pauses naturally
/// when the view is backgrounded — combined with the scenePhase
/// reset rule (spec §6.2) this is the soft fallback before AAC.
struct BigKidVideoView: View {
    let videoId: String
    let videoTitle: String
    /// Expected video length in seconds. The kid must dwell on this
    /// screen for at least this long before "Continue" enables.
    let expectedDurationSeconds: Double
    var onComplete: () async -> Void

    @State private var elapsed: Double = 0
    @State private var completing: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    private let tickInterval: Double = 0.5
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(videoId: String,
         videoTitle: String,
         expectedDurationSeconds: Double = 120,
         onComplete: @escaping () async -> Void) {
        self.videoId = videoId
        self.videoTitle = videoTitle
        self.expectedDurationSeconds = expectedDurationSeconds
        self.onComplete = onComplete
    }

    private var playbackPercent: Double {
        min(100, (elapsed / expectedDurationSeconds) * 100)
    }
    private var watched: Bool { elapsed >= expectedDurationSeconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.top, 6).padding(.bottom, 20)
            VideoEmbedView(videoId: videoId)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .frame(maxHeight: 440)
            VStack(spacing: 10) {
                progressBar.padding(.top, 20)
                lockHint
            }
            Spacer(minLength: 16)
            primaryButton.padding(.top, 20)
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
        .onReceive(timer) { _ in
            guard scenePhase == .active else { return }
            elapsed = min(expectedDurationSeconds, elapsed + tickInterval)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEP 1 OF 3 — REFLECTION TIME")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(EvlinKidColors.green500)
            Text(videoTitle)
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(EvlinKidColors.ink)
                .lineSpacing(3)
        }
    }

    private var progressBar: some View {
        EvKidProgressBar(value: playbackPercent, max: 100, tone: .primary, height: 6)
    }

    private var lockHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EvlinKidColors.ink3)
            Text("Watch the whole video — no skipping")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if watched {
            EvKidBigButton(isDisabled: completing, action: complete) {
                Text(completing ? "Saving…" : "Continue")
            }
        } else {
            EvKidBigButton(isDisabled: true, action: {}) {
                Text("Watching… \(remainingLabel)")
            }
        }
    }

    private var remainingLabel: String {
        let remaining = max(0, Int((expectedDurationSeconds - elapsed).rounded(.up)))
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "(%d:%02d)", m, s)
    }

    private func complete() {
        completing = true
        Task { await onComplete(); completing = false }
    }
}

/// WKWebView wrapper that loads `youtube.com/embed/<id>` as a real HTTP
/// request with a `Referer` header set to a synthetic origin derived
/// from the bundle id. Mirrors `Components/YouTubePlayerView.swift ::
/// InlineYouTubeWebView` — required to avoid Error 152/153 on recent
/// YouTube embed servers.
private struct VideoEmbedView: UIViewRepresentable {
    let videoId: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = context.coordinator

        context.coordinator.loadedVideoId = videoId
        load(into: web)
        return web
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
            // Disable controls + keyboard + fullscreen so the kid can't
            // skip ahead. Continue is gated on the SwiftUI timer in the
            // host view.
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "controls", value: "0"),
            URLQueryItem(name: "disablekb", value: "1"),
            URLQueryItem(name: "fs", value: "0"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "origin", value: identityURL.absoluteString),
            URLQueryItem(name: "widget_referrer", value: identityURL.absoluteString),
        ]
        return components.url
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedVideoId: String?
    }
}

#if DEBUG
#Preview {
    BigKidVideoView(videoId: "dQw4w9WgXcQ",
                    videoTitle: "Why rest time matters for your brain",
                    expectedDurationSeconds: 10,
                    onComplete: {})
}
#endif
