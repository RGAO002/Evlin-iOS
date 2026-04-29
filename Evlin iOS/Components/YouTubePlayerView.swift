import SwiftUI
import YouTubePlayerKit

/// External-facing wrapper used by StrategyCard / VideoRecommendationCard.
/// Renders a thumbnail + red play button. On tap, presents a full-screen
/// modal player (YouTubePlayerKit) with a Done button — the closest iOS-native
/// fullscreen experience available for YouTube content (true AVPlayer is not
/// possible since YouTube does not expose direct stream URLs).
///
/// YouTubePlayerKit handles the post-Apr-2026 YouTube Error 153 "Referer
/// required" embed change for us — our previous loadHTMLString+baseURL
/// approach broke when YouTube tightened enforcement.
///
/// The struct keeps the same name as before so call sites don't have to
/// change, but the kit's same-named SwiftUI view is referenced via module
/// qualification (`YouTubePlayerKit.YouTubePlayerView`) inside the cover.
struct YouTubePlayerView: View {
    let videoId: String
    let thumbnail: String
    @Binding var isPlaying: Bool

    @State private var showPlayer = false

    var body: some View {
        Button {
            showPlayer = true
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
        .fullScreenCover(isPresented: $showPlayer, onDismiss: { isPlaying = false }) {
            FullscreenYouTubePlayer(videoId: videoId) {
                showPlayer = false
            }
        }
        .onChange(of: isPlaying) { _, wantsPlayback in
            // Allow external callers (e.g. StrategyCard's WATCH VIDEO button)
            // to programmatically present the player by setting isPlaying = true.
            if wantsPlayback && !showPlayer {
                showPlayer = true
            }
        }
    }
}

/// Modal full-screen player. Black background, YouTubePlayerKit centered,
/// translucent Done button top-leading. Auto-plays on appear.
private struct FullscreenYouTubePlayer: View {
    let videoId: String
    var onDismiss: () -> Void

    @State private var player: YouTubePlayer

    init(videoId: String, onDismiss: @escaping () -> Void) {
        self.videoId = videoId
        self.onDismiss = onDismiss
        _player = State(initialValue: YouTubePlayer(
            source: .video(id: videoId),
            parameters: .init(
                autoPlay: true,
                showControls: true,
                showFullscreenButton: true,
                restrictRelatedVideosToSameChannel: true
            )
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            YouTubePlayerKit.YouTubePlayerView(player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .padding(.leading, 16)
            .padding(.top, 16)
            .accessibilityLabel("Close video")
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }
}
