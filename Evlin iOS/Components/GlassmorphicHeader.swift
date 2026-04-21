import SwiftUI

struct GlassmorphicHeader: View {
    /// Active child profile name — if set, shown as a pill that switches profiles on tap.
    var childName: String? = nil
    var onSwitchProfile: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil

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

            // Active child pill (tap to switch)
            if let name = childName {
                Button {
                    onSwitchProfile?()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.evSecondary)
                            .frame(width: 7, height: 7)
                        Text(name)
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Color.evSurfaceContainer)
                    )
                }
                .buttonStyle(.plain)
            }

            // Settings
            Button {
                onSettings?()
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
