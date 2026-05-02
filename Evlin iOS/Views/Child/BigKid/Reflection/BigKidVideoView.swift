import SwiftUI
import WebKit

struct BigKidVideoView: View {
    let videoId: String
    let videoTitle: String
    var onComplete: () async -> Void

    @State private var playbackPercent: Double = 0
    @State private var ended: Bool = false
    @State private var completing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.top, 6).padding(.bottom, 20)
            VideoEmbedView(videoId: videoId,
                           onProgress: { playbackPercent = $0 },
                           onEnded: { ended = true })
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
        if ended || playbackPercent >= 99 {
            EvKidBigButton(isDisabled: completing,
                           action: complete) {
                Text(completing ? "Saving…" : "Continue")
            }
        } else {
            EvKidBigButton(isDisabled: true, action: {}) {
                Text("Watching...")
            }
        }
    }

    private func complete() {
        completing = true
        Task { await onComplete(); completing = false }
    }
}

private struct VideoEmbedView: UIViewRepresentable {
    let videoId: String
    let onProgress: (Double) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.add(context.coordinator, name: "evlinPlayer")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = context.coordinator
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}#p{width:100%;height:100%}</style></head>
        <body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(videoId)',
            playerVars:{playsinline:1,controls:0,disablekb:1,modestbranding:1,rel:0,fs:0},
            events:{
              onReady:function(){player.playVideo();
                setInterval(function(){
                  try{
                    var d=player.getDuration();var t=player.getCurrentTime();
                    if(d>0)window.webkit.messageHandlers.evlinPlayer.postMessage({k:'p',v:(t/d)*100});
                  }catch(e){}
                },500);},
              onStateChange:function(e){
                if(e.data===0)window.webkit.messageHandlers.evlinPlayer.postMessage({k:'end'});
              }
            }});
        }
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onProgress: (Double) -> Void
        let onEnded: () -> Void
        init(onProgress: @escaping (Double) -> Void, onEnded: @escaping () -> Void) {
            self.onProgress = onProgress; self.onEnded = onEnded
        }
        func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let dict = m.body as? [String: Any], let k = dict["k"] as? String else { return }
            if k == "p", let v = dict["v"] as? Double { onProgress(min(100, v)) }
            else if k == "end" { onEnded() }
        }
    }
}

#if DEBUG
#Preview {
    BigKidVideoView(videoId: "dQw4w9WgXcQ",
                    videoTitle: "Why rest time matters for your brain",
                    onComplete: {})
}
#endif
