import SwiftUI

struct WhyChildAppleIDStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Maximum needs Family Sharing")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("This is the Apple setup that lets a parent manage a child's Screen Time from the parent phone.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.xl) {
                bullet("person.2.fill", "The child must have a Child Apple Account in your Family Sharing group.")
                bullet("iphone.and.arrow.forward", "The child phone must be signed in with that child account.")
                bullet("checkmark.shield.fill", "Evlin on the child phone requests .child authorization, then iOS asks the parent to approve.")
                bullet("list.bullet.rectangle", "After that, Evlin on the parent phone can show Apple's picker for the child's apps.")
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("If you skip this, Evlin still works in Standard mode, but the app picker has to run on the child phone.")
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
                Text("Set up Child Apple Account")
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
                .multilineTextAlignment(.leading)
        }
    }
}
