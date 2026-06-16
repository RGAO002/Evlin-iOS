import SwiftUI

/// Child-side shell router. When the device is paired (UUID present + API
/// base URL set) we show `BigKidRootView` — the JSX-matched big-kid UI.
/// Pre-pairing we show a minimal "ask parent to finish setup" placeholder.
/// (Previously this branch fell back to the legacy ChildModeView; that
/// view was deleted along with SettingsView once BigKid took over.)
struct ChildModeExperienceView: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    private var apiRootURL: URL? {
        let trimmed = apiClient.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private var pairedChildUUID: UUID? {
        UUID(uuidString: childDeviceID)
    }

    var body: some View {
        Group {
            if let url = apiRootURL, let childId = pairedChildUUID {
                BigKidRootView(baseURL: url, childId: childId)
                    .id("\(trimmedBase)|\(childDeviceID)")
                    .onAppear {
                        ScreenTimeManager.shared.syncDeletionProtectionToManagedSettings()
                    }
            } else {
                notPairedPlaceholder
            }
        }
    }

    private var notPairedPlaceholder: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "link.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.evOutline)
            Text("Waiting for setup")
                .font(.evHeadlineSmall)
                .foregroundStyle(Color.evOnSurface)
            Text("Ask the parent to finish pairing this device.")
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.section)

            // Escape hatch — this pre-pairing placeholder is otherwise a dead end
            // (e.g. the saved family no longer exists, so it waits forever). Safe
            // here because the device isn't paired yet: there are no parental
            // controls to undermine. Sends the device back to onboarding start.
            Button("Start over") { resetToLogin() }
                .font(.evLabelLarge)
                .foregroundStyle(Color.evPrimary)
                .padding(.top, Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    /// Clear the saved auth session + onboarding/pairing state and return to the
    /// start of onboarding (Welcome → role select → sign in). Wired to the
    /// "Start over" button on the pre-pairing placeholder so a stuck or
    /// mis-paired child device can be re-set-up.
    private func resetToLogin() {
        AuthService(api: apiClient).signOutLocally()
        let defaults = UserDefaults.standard
        for key in ["evlin.childDeviceID", "evlin.familyID", "evlin.childProfileID",
                    "evlin.childProfileName", "evlin.childBirthYear", "evlin.childGender",
                    "evlin.accountID", "evlin.parentProfileID"] {
            defaults.removeObject(forKey: key)
        }
        EvlinDemoShortcuts.clearFlag()
        appMode = ""
        onboardingComplete = false
    }

    private var trimmedBase: String {
        apiClient.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
