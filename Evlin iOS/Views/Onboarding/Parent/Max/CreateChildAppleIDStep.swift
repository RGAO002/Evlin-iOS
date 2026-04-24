import SwiftUI
import UIKit

struct CreateChildAppleIDStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Create the child account")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Do this on the parent's iPhone using the parent's Apple Account.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Open Settings on the parent's phone.")
                stepRow("2", "Tap your name at the top, then tap Family.")
                stepRow("3", "Tap Add Member or Add Child.")
                stepRow("4", "Choose Create Child Account, enter the child's birthday, then follow Apple's prompts.")
                stepRow("5", "When Apple finishes, confirm the child appears under Settings > Family.")
            }

            Button {
                openFamilySettings()
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

            Text("If the deep link does not land exactly on Family, open Settings manually and tap your name > Family.")
                .font(.evBodySmall)
                .foregroundStyle(Color.evOnSurfaceVariant)

            Spacer()

            Button(action: onContinue) {
                Text("Child account is created")
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

    private func openFamilySettings() {
        let candidates = [
            "App-prefs:root=APPLE_ACCOUNT&path=FAMILY",
            "App-Prefs:root=APPLE_ACCOUNT&path=FAMILY",
            "App-prefs:root=FAMILY",
            "App-Prefs:",
            UIApplication.openSettingsURLString,
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            UIApplication.shared.open(url)
            return
        }
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
