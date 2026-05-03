import SwiftUI

/// Chooses which child-side shell to show. The historical `ChildModeView`
/// (lock status + pairing hints) stays as a **fallback** when we don't yet
/// have the credentials the big-kid stack needs. Once `evlin.childDeviceID`
/// parses as a UUID and the shared `APIClient` has a usable API root, we
/// show `BigKidRootView` — that's the JSX-matched big-kid product UI.
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
            } else {
                ChildModeView()
            }
        }
    }

    private var trimmedBase: String {
        apiClient.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
