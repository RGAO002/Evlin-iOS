import SwiftUI
import FamilyControls

/// Full onboarding walkthrough — guides user through all required permissions
/// before entering Parent or Child mode
struct OnboardingView: View {
    @EnvironmentObject var apiClient: APIClient
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

    @State private var currentStep = 0

    private let totalSteps = 3

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

                Text("Evlin helps you manage your child's screen time with AI-powered intelligence. Before we begin, we need to set up a few permissions.")
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

    // MARK: - Step 1: Screen Time

    private var screenTimeStep: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer()

            Image(systemName: "hourglass")
                .font(.system(size: 56))
                .foregroundStyle(Color.evPrimary)

            VStack(spacing: Spacing.lg) {
                Text("Enable Screen Time")
                    .font(.evHeadlineMedium)
                    .foregroundStyle(Color.evPrimary)

                Text("Evlin uses Apple's Screen Time framework to manage app access. Please make sure Screen Time is turned on in your device settings.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            VStack(alignment: .leading, spacing: Spacing.lg) {
                stepRow("1", "Open the Settings app")
                stepRow("2", "Tap Screen Time")
                stepRow("3", "Turn on Screen Time if it's off")
                stepRow("4", "Tap Lock Screen Time Settings and set a passcode your child doesn't know")
                stepRow("5", "Come back here and tap Continue")
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
                Button {
                    Task { await screenTimeManager.openScreenTimeSettings() }
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14))
                        Text("Open Screen Time")
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

                Text("If iOS blocks a direct jump, you'll land in the Evlin settings page instead.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOutline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)

                Text("After enabling Screen Time, tap Continue")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOutline)

                nextButton("Continue")
            }
        }
        .padding(Spacing.xl)
    }

    // MARK: - Step 2: FamilyControls Authorization

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
                     : "Evlin needs permission to manage app access on this device. Tap the button below to authorize.")
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

    // MARK: - Step Row

    private func stepRow(_ number: String, _ text: String) -> some View {
        HStack(spacing: Spacing.lg) {
            Text(number)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.evSecondaryFixedDim)
            Text(text)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurface)
        }
    }

    // MARK: - Next Button

    private func nextButton(_ title: String) -> some View {
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
                        .fill(Color.evPrimary)
                )
        }
    }
}
