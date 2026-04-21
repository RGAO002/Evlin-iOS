import SwiftUI

struct ContentView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""
    @State private var selectedTab: EvlinTab = .chat
    @State private var showSettings = false

    /// Profile the parent selected at launch.
    /// Per current design: shown every launch (no persistence yet).
    @State private var activeChild: ChildProfile? = nil

    var body: some View {
        Group {
            if !onboardingComplete {
                // Step 1: Permissions walkthrough
                OnboardingView()
            } else if appMode != "parent" && appMode != "child" {
                // Step 2: Choose Parent or Child mode
                SetupView()
            } else if appMode == "parent" {
                if activeChild == nil {
                    // Step 3 (parent): pick which child profile
                    ProfilePickerView(
                        onSelect: { child in
                            withAnimation(.easeInOut(duration: 0.3)) {
                                activeChild = child
                            }
                        },
                        onAddChild: nil,         // not yet implemented
                        onSettings: { showSettings = true }
                    )
                    .transition(.opacity)
                } else {
                    parentView
                        .transition(.opacity)
                }
            } else if appMode == "child" {
                ChildModeView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var parentView: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Evlin") {
                HeaderIconButton(systemName: "gearshape") { showSettings = true }
            }

            ZStack {
                switch selectedTab {
                case .home:
                    HomeView()
                case .calendar:
                    CalendarView()
                case .chat:
                    ChatView(activeChild: activeChild)
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
