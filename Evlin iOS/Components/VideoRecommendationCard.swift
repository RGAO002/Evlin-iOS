import SwiftUI

/// Proactive video recommendation card shown after lock actions
/// Source: smart_recommendations_briefing — the "Supporting the Transition" card
struct VideoRecommendationCard: View {
    let video: RecommendedVideo
    var onSave: () -> Void = {}
    @State private var isPlayingInline = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: Spacing.lg) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evTertiaryContainer)
                    .padding(Spacing.md + 2)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.evTertiaryFixed)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("RECOMMENDED FOR YOU")
                        .font(.evLabelSmall)
                        .foregroundStyle(Color.evOutline)
                        .tracking(2)

                    Text("Supporting the Transition")
                        .font(.evHeadlineSmall)
                        .foregroundStyle(Color.evPrimary)
                }
                Spacer()
            }
            .padding(Spacing.xxl)
            .background(Color.evSurfaceContainerLow)

            // Content
            VStack(alignment: .leading, spacing: Spacing.xl) {
                // Video thumbnail with play button
                YouTubePlayerView(
                    videoId: video.videoId,
                    thumbnail: video.thumbnail,
                    isPlaying: $isPlayingInline
                )
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))

                // Title & description
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(video.title)
                        .font(.evHeadlineSmall)
                        .foregroundStyle(Color.evPrimary)

                    Text(video.description)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineSpacing(3)
                }

                // Tags
                HStack(spacing: Spacing.md) {
                    tagChip("Clinical Strategy", Color.evSurfaceContainerHigh)
                    tagChip("Actionable Now", Color.evSecondaryContainer)
                }

                // Actions
                HStack {
                    Button(action: onSave) {
                        HStack(spacing: Spacing.md) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 16))
                            Text("Save to Library")
                                .font(.evLabelLarge)
                        }
                        .foregroundStyle(Color.evPrimary)
                    }

                    Spacer()

                    Button {
                        isPlayingInline = true
                    } label: {
                        Text(isPlayingInline ? "Playing" : "Watch Now")
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evOnPrimary)
                            .padding(.horizontal, Spacing.xxl)
                            .padding(.vertical, Spacing.lg)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.md)
                                    .fill(Color.evPrimary)
                            )
                    }
                    .disabled(isPlayingInline)
                }
                .padding(.top, Spacing.md)
            }
            .padding(Spacing.xxl)
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(Color.evSurfaceContainerLowest)
        )
        .evAmbientShadow()
    }

    private func tagChip(_ text: String, _ bg: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(-0.3)
            .foregroundStyle(Color.evOnSurfaceVariant)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(RoundedRectangle(cornerRadius: CornerRadius.pill).fill(bg))
    }
}

struct RecommendedVideo {
    let title: String
    let description: String
    let thumbnail: String
    let videoId: String
}
