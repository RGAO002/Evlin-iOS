import SwiftUI

struct ContentView: View {
    @State private var selectedTab: EvlinTab = .chat
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            GlassmorphicHeader {
                showSettings = true
            }

            // Content
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

            // Tab bar
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
