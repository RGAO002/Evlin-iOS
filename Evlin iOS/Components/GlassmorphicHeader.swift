import SwiftUI

struct GlassmorphicHeader: View {
    var onSettingsTapped: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Logo + Title
            HStack(spacing: Spacing.lg) {
                Circle()
                    .fill(Color.evPrimary)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.evOnPrimary)
                    )

                Text("Evlin")
                    .font(.evHeadlineSmall)
                    .foregroundStyle(Color.evPrimary)
            }

            Spacer()

            // Settings
            Button {
                onSettingsTapped?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(Spacing.md)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(height: 56)
        .background(
            Color.evSurface.opacity(0.85)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .fill(Color.evOutlineVariant.opacity(0.15))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}
