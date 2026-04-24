import SwiftUI
import FamilyControls

@main
struct Evlin_iOSApp: App {
    @StateObject private var apiClient = APIClient()
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

    /// Tracks lifecycle so CommandPoller can start/stop with the scene.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // One-shot migration from legacy evlin.activeLocks store.
        // Pre-launch, so safe to drop legacy data. See plan Phase 11.
        ActiveLockMigration.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(apiClient)
                .environmentObject(screenTimeManager)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
                .onAppear { startPollerIfPaired() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: startPollerIfPaired()
                    case .background, .inactive: CommandPoller.shared.stop()
                    @unknown default: break
                    }
                }
        }
    }

    /// Start CommandPoller at the app level, not tied to any specific view.
    ///
    /// Why app-level: the poller used to live in ChildModeView.onAppear, but
    /// that meant commands queued while the user was on a parent tab (Chat)
    /// never got picked up — the receipt would time out. For single-device
    /// testing this was 100% reproducible. On a real 2-device setup the
    /// parent device won't have `evlin.childDeviceID` set (only the child
    /// device's pairing writes it), so this no-ops on parent devices.
    private func startPollerIfPaired() {
        guard let raw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let deviceID = UUID(uuidString: raw)
        else { return }
        CommandPoller.shared.start(deviceID: deviceID, apiClient: apiClient)
    }
}
