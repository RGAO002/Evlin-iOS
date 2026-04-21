import SwiftUI
import FamilyControls

/// Full onboarding walkthrough — guides user through all required permissions
/// before entering Parent or Child mode
struct OnboardingView: View {
    @EnvironmentObject var apiClient: APIClient
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

    @State private var currentStep = 0
    @State private var preventDeletionConfirmed = false

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            progressBar

            // Content
            Group {
                switch currentStep {
                case 0:
                    welcomeStep
                case 1:
                    screenTimeStep
                case 2:
                    preventDeletionStep
                case 3:
                    authorizationStep
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.evSurface)
        }
        .background(Color.evSurface)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<totalSteps, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step <= currentStep ? Color.evPrimary : Color.evOutlineVariant.opacity(0.3))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer()

            Circle()
                .fill(Color.evPrimary)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )

            VStack(spacing: Spacing.lg) {
                Text("Welcome to Evlin")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)

                Text("The Informed Sentinel")
                    .font(.evHeadlineSmall)
                    .foregroundStyle(Color.evOnPrimaryContainer)

                Text("Evlin helps you manage your child's screen time with AI-powered intelligence. Setup takes about 2 minutes and requires a few iOS settings.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            nextButton("Get Started")
        }
        .padding(Spacing.xl)
    }

    // MARK: - Step 1: Screen Time + Passcode

    private var screenTimeStep: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer(minLength: Spacing.md)

            Image(systemName: "hourglass")
                .font(.system(size: 56))
                .foregroundStyle(Color.evPrimary)

            VStack(spacing: Spacing.lg) {
                Text("Enable Screen Time")
                    .font(.evHeadlineMedium)
                    .foregroundStyle(Color.evPrimary)

                Text("Evlin uses Apple's Screen Time to manage apps. You'll also set a passcode — this is what keeps your child from disabling Evlin later.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Open Settings → Screen Time")
                stepRow("2", "Turn on Screen Time if it isn't already")
                stepRow("3", "Tap Lock Screen Time Settings")
                stepRow("4", "Set a 4-digit passcode your child doesn't know")
                stepRow("5", "Come back to Evlin and tap Continue")
            }
            .padding(Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(Color.evSurfaceContainerLowest)
                    .evGhostBorder()
            )
            .padding(.horizontal, Spacing.xl)

            Spacer()

            VStack(spacing: Spacing.lg) {
                openSettingsButton("Open Settings")

                Text("iOS will open the Settings app — scroll down and tap Screen Time to continue.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOutline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)

                nextButton("Continue")
            }
        }
        .padding(Spacing.xl)
    }

    // MARK: - Step 2: Prevent App Deletion  (NEW)

    private var preventDeletionStep: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer(minLength: Spacing.md)

            Image(systemName: "trash.slash.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.evTertiaryContainer)

            VStack(spacing: Spacing.lg) {
                Text("Prevent App Deletion")
                    .font(.evHeadlineMedium)
                    .foregroundStyle(Color.evPrimary)

                Text("Without this step, your child can simply delete Evlin to disable all restrictions. Enabling the \"Deleting Apps\" restriction locks down app removal — protected by the passcode you just set.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Settings → Screen Time")
                stepRow("2", "Tap Content & Privacy Restrictions")
                stepRow("3", "Turn on Content & Privacy Restrictions")
                stepRow("4", "Tap iTunes & App Store Purchases")
                stepRow("5", "Tap Deleting Apps → Don't Allow")
                stepRow("6", "Come back and confirm below")
            }
            .padding(Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(Color.evSurfaceContainerLowest)
                    .evGhostBorder()
            )
            .padding(.horizontal, Spacing.xl)

            // Note about side effect
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evOutline)
                Text("Side effect: your child won't be able to delete any app from this device until you turn the restriction off in Settings.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.horizontal, Spacing.xxxl)

            Spacer()

            VStack(spacing: Spacing.lg) {
                openSettingsButton("Open Settings")

                // Confirmation toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        preventDeletionConfirmed.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: preventDeletionConfirmed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 20))
                            .foregroundStyle(preventDeletionConfirmed ? Color.evSecondary : Color.evOutline)
                        Text("I've set \"Deleting Apps\" to Don't Allow")
                            .font(.evBodyMedium)
                            .foregroundStyle(Color.evOnSurface)
                        Spacer()
                    }
                    .padding(Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.evSurfaceContainerLow)
                    )
                }
                .buttonStyle(.plain)

                nextButton("Continue", enabled: preventDeletionConfirmed)
            }
        }
        .padding(Spacing.xl)
    }

    // MARK: - Step 3: FamilyControls Authorization

    private var authorizationStep: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer()

            Image(systemName: screenTimeManager.isAuthorized ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(screenTimeManager.isAuthorized ? Color.evSecondary : Color.evPrimary)

            VStack(spacing: Spacing.lg) {
                Text(screenTimeManager.isAuthorized ? "Authorization Complete" : "Authorize App Control")
                    .font(.evHeadlineMedium)
                    .foregroundStyle(Color.evPrimary)

                Text(screenTimeManager.isAuthorized
                     ? "Evlin is authorized to manage screen time on this device. You're all set!"
                     : "The last step: grant Evlin permission to apply the restrictions we just set up.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            if !screenTimeManager.isAuthorized {
                Button {
                    Task { await screenTimeManager.requestAuthorization() }
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 14))
                        Text("Authorize Screen Time")
                            .font(.evLabelLarge)
                    }
                    .foregroundStyle(Color.evOnPrimary)
                    .padding(.horizontal, Spacing.xxxl)
                    .padding(.vertical, Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.evPrimary)
                    )
                }

                if let error = screenTimeManager.errorMessage {
                    Text(error)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evError)
                        .padding(.horizontal, Spacing.xl)
                }
            }

            Spacer()

            Button {
                onboardingComplete = true
            } label: {
                Text("Continue to Setup")
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(screenTimeManager.isAuthorized ? Color.evPrimary : Color.evPrimary.opacity(0.4))
                    )
            }
            .disabled(!screenTimeManager.isAuthorized)
        }
        .padding(Spacing.xl)
    }

    // MARK: - Shared UI helpers

    private func stepRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            Text(number)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.evSecondaryFixedDim)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openSettingsButton(_ title: String) -> some View {
        Button {
            Task { await screenTimeManager.openScreenTimeSettings() }
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                Text(title)
                    .font(.evLabelLarge)
            }
            .foregroundStyle(Color.evOnPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.evPrimary)
            )
        }
    }

    private func nextButton(_ title: String, enabled: Bool = true) -> some View {
        Button {
            withAnimation { currentStep += 1 }
        } label: {
            Text(title)
                .font(.evLabelLarge)
                .foregroundStyle(Color.evOnPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(enabled ? Color.evPrimary : Color.evPrimary.opacity(0.35))
                )
        }
        .disabled(!enabled)
    }
}
