import SwiftUI
import ManagedSettings

struct DeletionProtectionStep: View {
    let onContinue: () -> Void

    @State private var applied = false

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()

            Circle()
                .fill(applied ? Color.evSecondaryContainer : Color.evPrimary)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: applied ? "checkmark.shield.fill" : "lock.shield.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(applied ? Color.evSecondary : Color.evOnPrimary)
                )

            VStack(spacing: Spacing.lg) {
                Text("Protect Evlin from deletion")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)
                Text("Evlin will now block itself from being deleted. Even if the child knows the device passcode, they won't be able to uninstall Evlin unless you turn this off.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }

            if applied {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                    Text("Evlin is now protected from deletion.")
                        .font(.evBodyMedium)
                        .foregroundStyle(Color.evSecondary)
                }
            }

            Spacer()

            Button {
                if applied { onContinue() } else { enable() }
            } label: {
                Text(applied ? "Continue" : "Enable Protection")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    private func enable() {
        let store = ManagedSettingsStore()
        store.application.denyAppRemoval = true
        applied = true
    }
}
