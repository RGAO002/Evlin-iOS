import SwiftUI

struct HomeView: View {
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @AppStorage("parentName") private var parentName: String = "Morgan"
    @State private var showSettings = false
    @Binding var selectedTab: EvlinTab
    var notifications: [HomeNotification] = HomeMockData.notifications
    var onOpenProfile: (ChildProfile) -> Void
    var onOpenNotifications: () -> Void

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var unreadCount: Int {
        notifications.filter(\.unread).count
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "", kicker: "\(greeting), \(parentName)") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "bell", badge: unreadCount > 0) {
                        onOpenNotifications()
                    }
                    HeaderIconButton(systemName: "gearshape") {
                        showSettings = true
                    }
                }
            }

            ScrollView {
                VStack(spacing: 28) {
                    // Children section. When a child has an active or
                    // completed reflection, swap the standard ProfileCard
                    // for the warm under-reflection card (image-1 design).
                    // Tap target is the same in both cases — open the
                    // child's profile (which itself shows reflection
                    // status + a "View reflection" CTA when applicable).
                    VStack(spacing: 14) {
                        SectionHead("Children", kicker: "Select a profile")
                        ForEach(ChildProfile.all) { child in
                            if let summary = reflectionStore.summary(for: child),
                               summary.state != .none {
                                ParentReflectionStatusCard(
                                    child: child,
                                    summary: summary,
                                    layout: .homeCard,
                                    onViewReflection: { onOpenProfile(child) }
                                )
                            } else {
                                ProfileCard(child: child) {
                                    onOpenProfile(child)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .fullScreenCover(isPresented: $showSettings) {
            HomeSettingsSheet(onClose: { showSettings = false })
        }
    }
}

#Preview("Home — no reflection") {
    @Previewable @State var tab: EvlinTab = .home
    return HomeView(
        selectedTab: $tab,
        onOpenProfile: { _ in },
        onOpenNotifications: {}
    )
    .environment(ParentReflectionFixtureStore())
}

#Preview("Home — Liam under reflection") {
    @Previewable @State var tab: EvlinTab = .home
    let store = ParentReflectionFixtureStore()
    store.simulateAssignment(childId: ChildProfile.liam.id)
    return HomeView(
        selectedTab: $tab,
        onOpenProfile: { _ in },
        onOpenNotifications: {}
    )
    .environment(store)
}
