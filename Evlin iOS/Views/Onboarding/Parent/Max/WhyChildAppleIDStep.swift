import SwiftUI

struct WhyChildAppleIDStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Why Child Apple ID?")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("A one-time 5 minute setup unlocks remote management powers for Evlin.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.xl) {
                bullet("person.2.fill", "Select your child's apps remotely from YOUR phone.")
                bullet("lock.shield.fill", "Evlin cannot be uninstalled from the child's phone.")
                bullet("clock.fill", "Set time limits and bedtime without needing their help.")
                bullet("checkmark.seal.fill", "Official Apple Family Sharing — fully compliant.")
            }

            Spacer()

            Button(action: onContinue) {
                Text("Got it — let's set it up")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.evPrimary)
            )
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.evSurface)
    }

    @ViewBuilder
    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.evPrimary)
                .frame(width: 40, height: 40)
                .background(Color.evSurfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
            Text(text)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evPrimary)
                .padding(.top, Spacing.md)
        }
    }
}
