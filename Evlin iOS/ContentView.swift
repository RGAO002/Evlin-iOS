import SwiftUI

struct ContentView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""
    @State private var selectedTab: EvlinTab = .chat
    @State private var showSettings = false

    var body: some View {
        Group {
            if !onboardingComplete {
                // Step 1: Permissions walkthrough
                OnboardingView()
            } else if appMode != "parent" && appMode != "child" {
                // Step 2: Choose Parent or Child mode
                SetupView()
            } else if appMode == "parent" {
                parentView
            } else if appMode == "child" {
                ChildModeView()
            }
        }
    }

    private var parentView: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader {
                showSettings = true
            }

            ZStack {
                switch selectedTab {
                case .chat:
                    ChatView()
                case .dashboard:
                    DashboardView()
                case .strategy:
                    StrategyView()
                case .library:
                    LibraryView()
                case .insights:
                    InsightsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            EvlinTabBar(selectedTab: $selectedTab)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(APIClient(baseURL: "http://preview"))
        .environmentObject(ScreenTimeManager.shared)
}
