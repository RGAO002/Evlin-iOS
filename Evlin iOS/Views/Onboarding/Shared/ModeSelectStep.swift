import SwiftUI

struct ModeSelectStep: View {
    /// Chooses Parent vs Child → continues into the normal pairing / permissions flow.
    let onSelect: (OnboardingMode) -> Void
    /// Single Device Mode (demo purpose only): many testers have just ONE device. This runs the
    /// FULL real onboarding on one phone, then shows a P/K float to switch this device between
    /// parent and kid for single-device testing. Replaces the old parent/kid "(demo)" skip cards.
    let onSingleDevice: () -> Void

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
                selectionCard(
                    title: "Parent Device",
                    description: "Set up Evlin on your phone to manage your child's device.",
                    icon: "person.fill.checkmark"
                ) { onSelect(.parent) }

                selectionCard(
                    title: "Child Device",
                    description: "This is my child's phone. Pair it with the parent's Evlin.",
                    icon: "person.fill"
                ) { onSelect(.child) }
            }
            .padding(.horizontal, Spacing.xl)

            // Single Device Mode — runs the REAL onboarding on one phone, then
            // exposes a P/K float to test both roles. Available in ALL builds
            // (many testers have just one device). The float itself stays gated
            // at runtime by SingleDeviceSession.isActive, so a real single-role
            // device never shows it — the safety invariant is preserved.
            singleDeviceFooter

            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    /// Demo purpose only — one card that runs the full real onboarding on a single device.
    private var singleDeviceFooter: some View {
        VStack(alignment: .center, spacing: Spacing.lg) {
            Text("Demo only")
                .font(.evCaption)
                .foregroundStyle(Color.evOutline)
                .multilineTextAlignment(.center)

            selectionCard(
                title: "Single Device Mode",
                description: "Test on a single phone — you'll play both the parent and the kid.",
                icon: "iphone"
            ) { onSingleDevice() }
            .padding(.horizontal, Spacing.xl)
        }
        .padding(.top, Spacing.section)
    }

    @ViewBuilder
    private func selectionCard(title: String, description: String, icon: String, action: @escaping () -> Void) -> some View {
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
