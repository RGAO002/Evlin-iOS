import Combine
import SwiftUI
import WebKit

/// Reflection step 1 — kid watches the assigned YouTube video.
///
/// **YouTube embed strategy.** YouTube's IFrame API hosted via
/// `loadHTMLString` triggers Player Error 152/153 on recent embeds
/// (Apr 2026 Referer enforcement tightening). The chat side worked
/// around this in `Components/YouTubePlayerView.swift` by loading the
/// embed as a real HTTP request with an explicit `Referer` header —
/// same approach here.
///
/// **Real progress.** Inside the loaded YouTube embed page sits a
/// standard HTML5 `<video>` element. We inject a `WKUserScript` at
/// document-end that listens to that element's `timeupdate` and
/// `ended` events and forwards `(currentTime / duration)` plus
/// playback-state messages to the native `WKScriptMessageHandler`.
/// The kid still can't skip — `web.isUserInteractionEnabled = false`
/// kills all gestures, so the player just plays through.
struct BigKidVideoView: View {
    let videoId: String
    let videoTitle: String
    var onComplete: () async -> Void

    @State private var playbackPercent: Double = 0
    @State private var ended: Bool = false
    @State private var completing: Bool = false
    @StateObject private var bridge = VideoBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.top, 6).padding(.bottom, 20)
            ZStack {
                VideoEmbedView(
                    videoId: videoId,
                    bridge: bridge,
                    onProgress: { playbackPercent = min(100, $0) },
                    onEnded: { ended = true }
                )
                if ended {
                    // Cover YouTube's "more videos" endscreen with a flat
                    // black tile after playback finishes. CSS injection
                    // hides most of it, but YouTube periodically changes
                    // class names — this is the belt-and-suspenders path.
                    Rectangle().fill(Color.black)
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(EvlinKidColors.green500)
                        Text("Video done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .frame(maxHeight: 440)
            VStack(spacing: 10) {
                progressBar.padding(.top, 20)
                lockHint
            }
            demoSkipSection.padding(.top, 12)
            Spacer(minLength: 16)
            primaryButton.padding(.top, 20)
        }
        .padding(.horizontal, EvlinKidMetrics.Padding.screenH)
        .padding(.bottom, 30)
        .background(EvlinKidColors.surface.ignoresSafeArea())
    }

    /// Ships in all builds for investor / TestFlight demos; clearly labeled — not meant for prod kid UX.
    private var demoSkipSection: some View {
        VStack(spacing: 6) {
            Button {
                bridge.skipToNearEnd(secondsRemaining: 5)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Skip to last 5 seconds")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(Capsule().stroke(.orange.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            Text("Demo / QA only — bypasses watching the clip. This button won't appear in production.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EvlinKidColors.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var watched: Bool { ended || playbackPercent >= 99 }

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
                Text("Watching…")
            }
        }
    }

    private func complete() {
        completing = true
        Task { await onComplete(); completing = false }
    }
}

/// Holds a weak reference to the embedded WKWebView so the SwiftUI
/// host can poke at the player from the outside (e.g. a DEBUG "skip
/// to last 5s" button). Initialized inside `VideoEmbedView.makeUIView`.
final class VideoBridge: ObservableObject {
    fileprivate weak var webView: WKWebView?

    /// Seek the underlying HTML5 `<video>` to (duration − secondsRemaining).
    /// No-op while the duration is still 0 (e.g. video metadata not loaded yet).
    func skipToNearEnd(secondsRemaining: Double) {
        let js = """
        (function() {
          var v = document.querySelector('video');
          if (!v || !isFinite(v.duration) || v.duration <= 0) return;
          v.currentTime = Math.max(0, v.duration - \(secondsRemaining));
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// WKWebView wrapper that loads `youtube.com/embed/<id>` as a real HTTP
/// request with a `Referer` header set to a synthetic origin derived
/// from the bundle id. Mirrors `Components/YouTubePlayerView.swift ::
/// InlineYouTubeWebView` — required to avoid Error 152/153 on recent
/// YouTube embed servers.
///
/// On document-end we inject a JS user script that watches the embed
/// page's HTML5 `<video>` element and forwards `timeupdate` + `ended`
/// events to the host via a `WKScriptMessageHandler` named
/// `evlinPlayer`. Kid touch is blocked at the WKWebView layer.
/// YouTube embed view used by both the kid Step-1 player and the
/// parent-side reflection preview. `internal` access so
/// `ReflectionStepDetailView` can reuse it without duplicating the
/// embed/Referer/script-bridge plumbing.
struct VideoEmbedView: UIViewRepresentable {
    let videoId: String
    let bridge: VideoBridge
    let onProgress: (Double) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Inject the progress + end-detection bridge.
        let userScript = WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false   // YouTube nests the player in a sub-frame on some pages
        )
        cfg.userContentController.addUserScript(userScript)
        cfg.userContentController.add(context.coordinator, name: "evlinPlayer")

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = context.coordinator
        // Block all gestures inside the player. YouTube's HTML5 player
        // keeps double-tap-to-skip-10s active even with `controls=0`,
        // and there's no embed param to disable it. Killing user
        // interaction on the WKWebView itself is the cleanest stopper —
        // `autoplay=1` in the URL means the kid doesn't need to tap to
        // start playback anyway.
        web.isUserInteractionEnabled = false

        context.coordinator.loadedVideoId = videoId
        bridge.webView = web
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

    /// JS injected into the YouTube embed page at document-end. Two jobs:
    ///
    /// 1. Inject a `<style>` block hiding YouTube's end-screen "more
    ///    videos" overlay, suggested cards, and watermark. YouTube's
    ///    class names drift (`.ytp-endscreen-content`, `.ytp-ce-element`,
    ///    etc.), so we cover several variants. Combined with the
    ///    SwiftUI black overlay we paint over the player on `ended`,
    ///    this is belt-and-suspenders against the endscreen surfacing.
    ///
    /// 2. Poll for the `<video>` element (it appears asynchronously
    ///    after the player JS runs), then attach `timeupdate` / `ended`
    ///    listeners and forward events to the `evlinPlayer`
    ///    script-message handler.
    private static let bridgeJS = """
    (function() {
      if (window.__evlinAttached) return;
      window.__evlinAttached = true;

      // (1) Hide endscreen / cards / watermark via CSS.
      var css = [
        '.ytp-endscreen-content',
        '.ytp-ce-element',
        '.ytp-ce-covering-overlay',
        '.ytp-ce-element-shadow',
        '.ytp-ce-covering-image',
        '.ytp-ce-expanding-image',
        '.ytp-ce-element-show',
        '.ytp-pause-overlay',
        '.ytp-pause-overlay-container',
        '.ytp-suggested-action',
        '.ytp-suggested-action-badge',
        '.ytp-cards-button',
        '.ytp-cards-teaser',
        '.iv-branding',
        '.ytp-watermark',
        '.ytp-show-cards-title'
      ].join(',') + ' { display: none !important; opacity: 0 !important; visibility: hidden !important; }';
      var style = document.createElement('style');
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);

      // (2) Bridge HTML5 <video> events to native.
      function attach() {
        var v = document.querySelector('video');
        if (!v) { setTimeout(attach, 200); return; }
        function send(payload) {
          try { window.webkit.messageHandlers.evlinPlayer.postMessage(payload); } catch (e) {}
        }
        v.addEventListener('timeupdate', function() {
          var d = v.duration || 0;
          if (d > 0) send({ k: 'p', v: (v.currentTime / d) * 100 });
        });
        v.addEventListener('ended', function() {
          // Pause to keep YouTube from spinning up the endscreen card
          // animation right under our SwiftUI cover.
          try { v.pause(); } catch (e) {}
          send({ k: 'end' });
        });
      }
      attach();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onProgress: (Double) -> Void
        let onEnded: () -> Void
        var loadedVideoId: String?

        init(onProgress: @escaping (Double) -> Void, onEnded: @escaping () -> Void) {
            self.onProgress = onProgress
            self.onEnded = onEnded
        }

        func userContentController(_ uc: WKUserContentController,
                                    didReceive m: WKScriptMessage) {
            guard let dict = m.body as? [String: Any], let k = dict["k"] as? String else { return }
            switch k {
            case "p":
                if let v = dict["v"] as? Double { onProgress(v) }
            case "end":
                onEnded()
            default:
                break
            }
        }
    }
}

#if DEBUG
#Preview {
    BigKidVideoView(
        videoId: ReflectionVideoDisplay.rickRollVideoId,
        videoTitle: ReflectionVideoDisplay.cardTitle(
            videoId: ReflectionVideoDisplay.rickRollVideoId,
            serverTitle: "Ignored for Rick Roll",
            displayReason: "You stayed up past your bedtime on your tablet.",
            rawReason: "bedtime"
        ),
        onComplete: {}
    )
}
#endif
