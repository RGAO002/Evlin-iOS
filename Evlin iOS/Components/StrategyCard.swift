import SwiftUI

struct StrategyCardData: Hashable {
    let title: String
    let status: String
    let category: String
    let videoLabel: String
    let videoDuration: String
    let tip: String
}

struct StrategyCard: View {
    let data: StrategyCardData
    var onWatchVideo: () -> Void = {}
    var onReviewStrategy: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            categoryLine
            videoTile
            proactiveTip
            actionButtons
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.5), lineWidth: 1)
        )
        .evShadow(.premium)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(data.title)
                .font(.custom("Manrope", size: 22).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(Color.evPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .heavy))
                Text(data.status.uppercased())
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
            }
            .foregroundStyle(Color.evError)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.evErrorContainer))
        }
    }

    private var categoryLine: some View {
        Text(data.category.uppercased())
            .font(.custom("Inter", size: 11).weight(.heavy))
            .tracking(1.6)
            .foregroundStyle(Color.evOnSurfaceVariant)
    }

    private var videoTile: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.evPrimaryGradient)

            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.videoLabel)
                    .font(.custom("Manrope", size: 16).weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(data.videoDuration) duration")
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
        }
        .frame(height: 160)
    }

    private var proactiveTip: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evSecondary)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Proactive Tip")
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evSecondary)
                Text(data.tip)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSecondaryContainer)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onWatchVideo) {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("WATCH VIDEO")
                        .font(.custom("Manrope", size: 12).weight(.heavy))
                        .tracking(0.9)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.evPrimary)
                )
            }
            .buttonStyle(.plain)

            Button(action: onReviewStrategy) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .bold))
                    Text("REVIEW STRATEGY")
                        .font(.custom("Manrope", size: 12).weight(.heavy))
                        .tracking(0.9)
                }
                .foregroundStyle(Color.evPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.evPrimary.opacity(0.3), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
