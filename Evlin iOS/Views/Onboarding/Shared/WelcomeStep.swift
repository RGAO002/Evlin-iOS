import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()

            Image("EvlinAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)

            VStack(spacing: Spacing.lg) {
                Text("Welcome to Evlin")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("The Informed Sentinel")
                    .font(.evHeadlineSmall)
                    .foregroundStyle(Color.evOnPrimaryContainer)
                Text("AI-powered parental control. Setup takes about 2 minutes.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.evPrimary)
            )
            .padding(.horizontal, Spacing.xl)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }
}
