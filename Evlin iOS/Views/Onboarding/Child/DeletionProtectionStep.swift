import SwiftUI
/// Shows side-effect copy when enabled; hides it when user turns off.
/// Per spec §2 D5 + user feedback.
struct DeletionProtectionStep: View {
    @State private var isEnabled: Bool = true
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()

            Circle()
                .fill(Color.evPrimary)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )

            VStack(spacing: Spacing.lg) {
                Text("Protect Evlin from deletion")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)
                Text("If enabled, the child won't be able to delete Evlin from this phone, even if they know your passcode.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }

            Toggle("Prevent Evlin from being deleted", isOn: $isEnabled)
                .padding(.horizontal, Spacing.xl)
                .onChange(of: isEnabled) { _, newValue in
                    ScreenTimeManager.shared.setDeletionProtectionEnabled(newValue)
                }

            if isEnabled {
                Text("Note: iOS applies this setting phone-wide — it also prevents the child from deleting **other apps**. There is no per-app deletion protection on iOS.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
                    .transition(.opacity)
            }

            Spacer()

            Button {
                ScreenTimeManager.shared.setDeletionProtectionEnabled(isEnabled)
                onContinue()
            } label: {
                Text("Continue")
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
        .onAppear {
            isEnabled = ScreenTimeManager.shared.deletionProtectionEnabled
        }
    }
}
