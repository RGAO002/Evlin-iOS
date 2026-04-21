import SwiftUI

struct ContentView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    var body: some View {
        Group {
            if !onboardingComplete {
                OnboardingView()
            } else if appMode != "parent" && appMode != "child" {
                SetupView()
            } else if appMode == "parent" {
                ParentRootView()
            } else {
                ChildModeView()
            }
        }
    }
}

struct ParentRootView: View {
    @State private var selectedTab: EvlinTab = .home
    @State private var profilePath = NavigationPath()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .home:
                    NavigationStack(path: $profilePath) {
                        HomeView(
                            selectedTab: $selectedTab,
                            onOpenProfile: { child in profilePath.append(child) }
                        )
                        .navigationDestination(for: ChildProfile.self) { child in
                            ProfileView(
                                child: child,
                                onBack: { profilePath.removeLast() },
                                onOpenCalendar: { selectedTab = .calendar }
                            )
                        }
                    }
                case .calendar:
                    CalendarView()
                case .chat:
                    ChatView()
                case .library:
                    LibraryView()
                case .insights:
                    InsightsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            EvlinTabBar(selectedTab: $selectedTab)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(APIClient(baseURL: "http://preview"))
        .environmentObject(ScreenTimeManager.shared)
}
