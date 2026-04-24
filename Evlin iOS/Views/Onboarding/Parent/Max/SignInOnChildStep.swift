import SwiftUI

struct SignInOnChildStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Use it on the child phone")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Now move to the child's iPhone. This is the step that links the phone to the child account.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "On the child's phone, open Settings.")
                stepRow("2", "Tap the Apple Account name at the top.")
                stepRow("3", "If it is not the child account, sign out and sign in with the Child Apple Account you created.")
                stepRow("4", "Confirm Settings > Family shows this child as part of your family.")
                stepRow("5", "Open Evlin on the child phone and continue the Child onboarding flow.")
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Important")
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("If the child phone is still signed in with a normal adult Apple Account, Evlin's .child authorization will fail.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.leading)
            }
            .padding(Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .fill(Color.evSurfaceContainerLowest)
            )

            Spacer()

            Button(action: onContinue) {
                Text("Child phone is signed in")
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
                .multilineTextAlignment(.leading)
        }
    }
}
