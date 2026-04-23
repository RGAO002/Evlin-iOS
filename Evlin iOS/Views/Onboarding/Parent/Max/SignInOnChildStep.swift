import SwiftUI

struct SignInOnChildStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Sign In on Child's Phone")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("On your child's phone, follow these steps:")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Sign out of the existing Apple ID (if any)")
                stepRow("2", "Sign in with the Child Apple ID you just created")
                stepRow("3", "Return to Evlin — it's already running there in child mode")
            }

            Spacer()

            Button(action: onContinue) {
                Text("I've signed in on their phone")
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
    private func stepRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            Text(number)
                .font(.evLabelLarge)
                .foregroundStyle(Color.evOnPrimary)
                .frame(width: 28, height: 28)
                .background(Color.evPrimary)
                .clipShape(Circle())
            Text(text)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evPrimary)
                .padding(.top, Spacing.xs)
        }
    }
}
