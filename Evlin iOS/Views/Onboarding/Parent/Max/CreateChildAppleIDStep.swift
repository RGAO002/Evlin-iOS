import SwiftUI

struct CreateChildAppleIDStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Create a Child Apple ID")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("On THIS phone, follow these steps:")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Open Settings → Family")
                stepRow("2", "Tap Add Member → Create a Child Account")
                stepRow("3", "Follow Apple's prompts (~3 min)")
            }

            Button {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            } label: {
                Text("Open Family Settings")
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.evSurfaceContainerLow)
                            .evGhostBorder()
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onContinue) {
                Text("I've created the account")
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
