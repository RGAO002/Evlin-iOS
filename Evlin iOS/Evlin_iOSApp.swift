import SwiftUI
import FamilyControls

@main
struct Evlin_iOSApp: App {
    @StateObject private var apiClient = APIClient()
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

    /// Tracks lifecycle so CommandPoller can start/stop with the scene.
    @Environment(\.scenePhase) private var scenePhase

    /// Mirrors FloatingModeToggle's storage so we can flip the poller on
    /// every parent↔child mode switch (single-device dev). On real
    /// two-device deployments the parent device never has
    /// `evlin.childDeviceID` set, so the guard inside is moot.
    @AppStorage("appMode") private var appMode: String = ""

    init() {
        // One-shot migration from legacy evlin.activeLocks store.
        // Pre-launch, so safe to drop legacy data. See plan Phase 11.
        ActiveLockMigration.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The Evlin design system ("Informed Sentinel") is a
                // light-mode-only spec — surface containers, card
                // backgrounds, ghost borders all assume light. Without
                // this, system dark mode flips Text() to white but
                // leaves our hardcoded light backgrounds light → white
                // text on white card → invisible (e.g. Instagram label
                // on ProposalCard, app names on the lazy-tag picker).
                // Force light app-wide instead of patching each view.
                .preferredColorScheme(.light)
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
                .onChange(of: appMode) { _, _ in
                    // Toggling P↔K starts/stops the poller — see the
                    // doc on startPollerIfPaired for why.
                    startPollerIfPaired()
                }
                .onReceive(NotificationCenter.default.publisher(for: .bigKidStateInvalidated)) { _ in
                    // Demo bootstrap (or parent approve) can rewrite `evlin.childDeviceID` while
                    // already in K mode — restart polling with the fresh UUID.
                    startPollerIfPaired()
                }
        }
    }

    /// Start CommandPoller only when the user is in K mode. The poller
    /// applies queued shield/block commands to THIS device's
    /// ManagedSettings, which is correct for the kid device but wrong
    /// for the parent device — the parent should never lock itself.
    ///
    /// Two-device deployment: parent device never has
    /// `evlin.childDeviceID` set (only the kid's pairing writes it), so
    /// the guard is moot there. The single-device dev affordance
    /// (FloatingModeToggle flipping appMode) is what makes mode-gating
    /// matter: P mode = parent dashboard view, no commands applied;
    /// switch to K mode = poller starts, queued commands flush.
    ///
    /// Tradeoff: commands queued while parent is in P mode wait until
    /// the user toggles to K mode. That's the behavior we want — it
    /// mirrors the real 2-device flow ("kid device picks up when it
    /// next polls"). On scenePhase != .active we stop too so a
    /// backgrounded kid device doesn't keep polling.
    private func startPollerIfPaired() {
        guard let raw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let deviceID = UUID(uuidString: raw)
        else { return }
        let appMode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        guard appMode == "child" else {
            CommandPoller.shared.stop()
            return
        }
        CommandPoller.shared.start(deviceID: deviceID, apiClient: apiClient)
    }
}
