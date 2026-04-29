import SwiftUI
import YouTubePlayerKit

/// External-facing wrapper used by StrategyCard / VideoRecommendationCard.
///
/// Behavior (matches the pre-YouTube-Error-153 experience):
/// - Default state: thumbnail + red play button.
/// - Tap (or external `isPlaying = true` from WATCH VIDEO button) → swaps
///   in-place to a YouTubePlayerKit inline player that auto-plays.
/// - When the user taps the player's fullscreen button, iOS WebKit takes
///   over with the system-native fullscreen chrome (Done button top-leading,
///   AirPlay, Picture-in-Picture, etc.). YouTube's controls remain inside,
///   wrapped by iOS — this is the closest iOS-native experience available
///   for YouTube content.
///
/// Why YouTubePlayerKit and not raw WKWebView: YouTube tightened iframe
/// embed Referer enforcement (Error 153) in late 2025 / Apr 2026. The kit
/// handles the WKWebView Referer/origin wiring correctly via a real HTTPS
/// origin, where our previous loadHTMLString + baseURL approach now fails.
struct YouTubePlayerView: View {
    let videoId: String
    let thumbnail: String
    @Binding var isPlaying: Bool

    var body: some View {
        Group {
            if isPlaying {
                YouTubePlayerKit.YouTubePlayerView(
                    YouTubePlayer(
                        source: .video(id: videoId),
                        parameters: .init(
                            autoPlay: true,
                            showControls: true,
                            showFullscreenButton: true,
                            restrictRelatedVideosToSameChannel: true,
                            // Critical: YouTubePlayerKit's default originURL is
                            // built from the app's bundle ID (e.g.
                            // https://com.evlin.evlin-ios) — YouTube's iframe
                            // player rejects that with Error 153 since Apr 2026.
                            // Override with a real origin so the &origin= URL
                            // parameter and the loadHTMLString baseURL both
                            // satisfy YouTube's referer/origin check.
                            originURL: URL(string: "https://www.youtube.com")
                        )
                    )
                )
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
