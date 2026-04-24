import SwiftUI
import FamilyControls

@main
struct Evlin_iOSApp: App {
    @StateObject private var apiClient = APIClient()
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

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
        }
    }
}
