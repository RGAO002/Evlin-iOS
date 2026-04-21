import SwiftUI

// Matches screen-evlin.jsx's StrategyCard (lines 93-148).
struct StrategyCardData: Hashable {
    let title: String
    let status: String          // "Locked"
    let category: String        // "Active Monitoring › Immediate Action"
    let videoLabel: String      // "Managing Transition Frustration"
    let videoDuration: String   // "3:00"
    let tip: String
}

struct StrategyCard: View {
    let data: StrategyCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.evSecondaryFixedDim.opacity(0.3))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.evSecondary)
                }
                EvlinPill(text: data.status, tone: .success, size: .xs)
                Spacer()
            }

            Text(data.category.uppercased())
                .font(.custom("Inter", size: 9).weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Color.evOnSurfaceVariant)

            Text(data.title)
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(Color.evPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evPrimaryGradient)
                    .frame(width: 56, height: 42)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.videoLabel)
                        .font(.custom("Manrope", size: 13).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                        .lineLimit(1)
                    Text(data.videoDuration)
                        .font(.custom("Inter", size: 11).weight(.semibold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
            )

            Text(data.tip)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.5), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}
