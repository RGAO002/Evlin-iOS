import SwiftUI

/// Routes shared by every navigation stack in the parent shell (Home,
/// Insights). Adding a new pushable destination to either tab? Add the
/// case here and handle it in `appNavigationDestination`.
enum AppRoute: Hashable {
    case profile(ChildProfile, taskId: Int? = nil)
    case notifications
    /// Pushable Task Detail. We carry the full child + task by id so we
    /// can reach the live task model inside the view.
    case taskDetail(child: ChildProfile, taskId: Int)
    /// Pushable per-device app-limits screen. Mirrors `taskDetail` —
    /// pushes onto the same stack so edge-swipe-back works.
    case deviceDetail(device: DeviceItem, childId: String)
}

/// Compatibility alias — older code referenced `HomeRoute`.
typealias HomeRoute = AppRoute

struct ContentView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    var body: some View {
        ZStack {
            Group {
                if !onboardingComplete {
                    OnboardingCoordinator()
                } else if appMode != "parent" && appMode != "child" {
                    OnboardingCoordinator()   // fallback
                } else if appMode == "parent" {
                    ParentRootView()
                } else {
                    // Big-kid product UI (`BigKidRootView`) when paired + API base is
                    // known; otherwise legacy lock / pairing shell (`ChildModeView`).
                    ChildModeExperienceView()
                }
            }

            #if DEBUG
            // Single-device dev affordance: float a small P/K pill that
            // toggles parent ↔ child mode. Drag to reposition.
            if onboardingComplete && (appMode == "parent" || appMode == "child") {
                FloatingModeToggle()
            }
            // Parent-side BigKid debug — opens the trigger / approve /
            // review-task sheet that calls /api/v1/parent/* endpoints.
            // Only surfaces while we're actually in parent mode.
            if onboardingComplete && appMode == "parent" {
                VStack {
                    HStack {
                        ParentBigKidDebugButton()
                            .padding(.leading, 12)
                            .padding(.top, 8)
                        Spacer()
                    }
                    Spacer()
                }
            }
            #endif
        }
    }
}

struct ParentRootView: View {
    @State private var selectedTab: EvlinTab = .home
    @State private var profilePath = NavigationPath()
    @State private var insightsPath = NavigationPath()
    @State private var banner: (title: String, body: String, avatarURL: String?)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .home:
                    NavigationStack(path: $profilePath) {
                        HomeView(
                            selectedTab: $selectedTab,
                            onOpenProfile: { child in profilePath.append(AppRoute.profile(child)) },
                            onOpenNotifications: { profilePath.append(AppRoute.notifications) }
                        )
                        .appNavigationDestination(
                            path: $profilePath,
                            selectedTab: $selectedTab
                        )
                    }
                case .calendar:
                    CalendarView()
                case .chat:
                    ChatView()
                case .library:
                    LibraryView()
                case .insights:
                    NavigationStack(path: $insightsPath) {
                        InsightsView(
                            onOpenNotifications: {
                                insightsPath.append(AppRoute.notifications)
                            }
                        )
                        .appNavigationDestination(
                            path: $insightsPath,
                            selectedTab: $selectedTab
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            EvlinTabBar(selectedTab: $selectedTab)
        }
        .overlay(alignment: .top) {
            if let b = banner {
                NotificationBanner(
                    title: b.title,
                    message: b.body,
                    avatarURL: b.avatarURL,
                    onDismiss: { withAnimation { banner = nil } }
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(80)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: banner?.title)
    }
}

// MARK: - Shared navigation destinations

extension View {
    /// Centralised destination resolver for `AppRoute`. Used by every
    /// tab-scoped `NavigationStack` so that pushing the same case from
    /// Home or Insights produces the same screen with the same back
    /// behaviour.
    @ViewBuilder
    func appNavigationDestination(
        path: Binding<NavigationPath>,
        selectedTab: Binding<EvlinTab>
    ) -> some View {
        self.navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .profile(let child, let taskId):
                ProfileView(
                    child: child,
                    initialTaskId: taskId,
                    onBack: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    },
                    onOpenCalendar: { selectedTab.wrappedValue = .calendar },
                    onOpenTaskDetail: { task in
                        path.wrappedValue.append(
                            AppRoute.taskDetail(child: child, taskId: task.id)
                        )
                    },
                    onOpenDevice: { device in
                        path.wrappedValue.append(
                            AppRoute.deviceDetail(device: device, childId: child.id)
                        )
                    }
                )
            case .notifications:
                NotificationPanel(
                    onClose: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    },
                    onOpenTask: { childId, taskId in
                        guard let child = ChildProfile.all.first(where: { $0.id == childId }) else { return }
                        path.wrappedValue.append(
                            AppRoute.taskDetail(child: child, taskId: taskId)
                        )
                    }
                )
            case .taskDetail(let child, let taskId):
                TaskDetailView(
                    childId: child.id,
                    taskId: taskId,
                    onBack: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    }
                )
            case .deviceDetail(let device, let childId):
                DeviceAppsSheet(
                    device: device,
                    childId: childId,
                    onClose: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    }
                )
            }
        }
    }
}

// MARK: - Previews

// Full app shell (all 5 tabs + tab bar). Skips onboarding by bypassing ContentView.
#Preview("Parent Shell") {
    ParentRootView()
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}

// ContentView honoring @AppStorage — starts at onboarding if you haven't completed it.
#Preview("ContentView") {
    ContentView()
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}
