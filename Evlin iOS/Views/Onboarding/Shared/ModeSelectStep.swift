import SwiftUI

struct ModeSelectStep: View {
    let onSelect: (OnboardingMode) -> Void

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()

            Circle()
                .fill(Color.evPrimary)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )

            VStack(spacing: Spacing.lg) {
                Text("Evlin")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Choose how this device will be used")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Spacing.lg) {
                modeCard(
                    title: "Parent Device",
                    description: "Set up Evlin on your phone to manage your child's device.",
                    icon: "person.fill.checkmark"
                ) { onSelect(.parent) }

                modeCard(
                    title: "Child Device",
                    description: "This is my child's phone. Pair it with the parent's Evlin.",
                    icon: "person.fill"
                ) { onSelect(.child) }
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    @ViewBuilder
    private func modeCard(title: String, description: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xl) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 48, height: 48)
                    .background(Color.evSurfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(title)
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evPrimary)
                    Text(description)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOutline)
            }
            .padding(Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(Color.evSurfaceContainerLowest)
                    .evGhostBorder()
            )
        }
        .buttonStyle(.plain)
    }
}
