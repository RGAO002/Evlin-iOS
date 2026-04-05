import SwiftUI
import FamilyControls

@main
struct Evlin_iOSApp: App {
    @StateObject private var apiClient = APIClient()
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

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
                .task {
                    // Auto-request authorization on first launch
                    if !screenTimeManager.isAuthorized {
                        await screenTimeManager.requestAuthorization()
                    }
                }
        }
    }
}
