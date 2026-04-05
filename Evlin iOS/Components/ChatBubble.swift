import SwiftUI

enum ChatRole: String, Codable {
    case parent
    case agent
}

struct ChatBubble: View {
    let content: String
    let role: ChatRole
    let timestamp: Date

    var body: some View {
        HStack {
            if role == .parent { Spacer(minLength: 40) }

            VStack(alignment: role == .parent ? .trailing : .leading, spacing: 6) {
                if role == .agent {
                    agentAvatar
                }

                Text(content)
                    .font(.evBodyMedium)
                    .foregroundStyle(role == .parent ? Color.evOnPrimary : Color.evOnSurface)
                    .lineSpacing(4)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg + 2)
                    .background(bubbleBackground)

                Text(timestamp, style: .time)
                    .evTimestampStyle()
                    .padding(.horizontal, 4)
            }

            if role == .agent { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if role == .parent {
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(Color.evPrimary)
        } else {
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(Color.evSurfaceContainerLowest)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.xl)
                        .stroke(Color.evOutlineVariant.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color(hex: 0x191C1E).opacity(0.04), radius: 12, y: 4)
        }
    }

    private var agentAvatar: some View {
        HStack(spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.evPrimary)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )

            Text("Evlin Sentinel")
                .font(.evLabelLarge)
                .foregroundStyle(Color.evPrimary)
        }
    }
}
