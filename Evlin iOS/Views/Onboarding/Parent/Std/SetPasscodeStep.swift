import SwiftUI

struct SetPasscodeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Set Screen Time Passcode")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("On your child's phone, prevent them from changing Screen Time settings:")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Open Settings → Screen Time")
                stepRow("2", "Tap Lock Screen Time Settings")
                stepRow("3", "Set a 4-digit passcode they don't know")
            }

            Text("Evlin's own deletion protection is automatic — no extra step needed.")
                .font(.evBodySmall)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(.top, Spacing.md)

            Button {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            } label: {
                Text("Open Screen Time Settings")
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
                Text("I've set the passcode")
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
