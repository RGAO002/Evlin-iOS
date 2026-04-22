import SwiftUI

enum HomeRoute: Hashable {
    case profile(ChildProfile)
    case notifications
}

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
                            onOpenProfile: { child in profilePath.append(HomeRoute.profile(child)) },
                            onOpenNotifications: { profilePath.append(HomeRoute.notifications) }
                        )
                        .navigationDestination(for: HomeRoute.self) { route in
                            switch route {
                            case .profile(let child):
                                ProfileView(
                                    child: child,
                                    onBack: { if !profilePath.isEmpty { profilePath.removeLast() } },
                                    onOpenCalendar: { selectedTab = .calendar }
                                )
                            case .notifications:
                                NotificationPanel(onClose: {
                                    if !profilePath.isEmpty { profilePath.removeLast() }
                                })
                            }
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

// MARK: - Previews

// Full app shell (all 5 tabs + tab bar). Skips onboarding by bypassing ContentView.
#Preview("Parent Shell (all tabs)") {
    ParentRootView()
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}

// ContentView honoring @AppStorage — starts at onboarding if you haven't completed it.
#Preview("ContentView (real flow)") {
    ContentView()
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}
