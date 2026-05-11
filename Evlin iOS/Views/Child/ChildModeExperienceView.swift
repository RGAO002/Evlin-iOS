import SwiftUI

/// Child-side shell router. When the device is paired (UUID present + API
/// base URL set) we show `BigKidRootView` — the JSX-matched big-kid UI.
/// Pre-pairing we show a minimal "ask parent to finish setup" placeholder.
/// (Previously this branch fell back to the legacy ChildModeView; that
/// view was deleted along with SettingsView once BigKid took over.)
struct ChildModeExperienceView: View {
    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    private var trimmedBase: String {
        apiClient.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
