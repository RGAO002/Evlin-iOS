import SwiftUI

struct AgentReasoningCard: View {
    let label: String
    let content: String
    var icon: String = "chart.bar.xaxis"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evSecondary)

                Text(label)
                    .font(.evLabelMedium)
                    .foregroundStyle(Color.evSecondary)
                    .evLabelStyle()
            }

            Text(content)
                .font(.evBodySmall)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(3)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
        .overlay(
            HStack {
                Rectangle()
                    .fill(Color.evSecondary.opacity(0.6))
                    .frame(width: 4)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
    }
}
