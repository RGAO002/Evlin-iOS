import SwiftUI

struct QuickPromptChip: View {
    let icon: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(.evBodySmall)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(Color.evPrimary)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .background(
                Capsule()
                    .fill(Color.evSurfaceContainerLowest)
                    .overlay(
                        Capsule()
                            .stroke(Color.evOutlineVariant.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
