import SwiftUI

struct HomeView: View {
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @AppStorage("parentName") private var parentName: String = "Morgan"
    @State private var showSettings = false
    @Binding var selectedTab: EvlinTab
    var onOpenProfile: (ChildProfile) -> Void
    var onOpenNotifications: () -> Void
    var onOpenReflection: (AppRoute) -> Void

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var unreadCount: Int {
        HomeMockData.notifications.filter(\.unread).count
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
                    // Children section
                    VStack(spacing: 14) {
                        SectionHead("Children", kicker: "Select a profile")
                        ForEach(ChildProfile.all) { child in
                            if let summary = reflectionStore.summary(for: child), summary.state != .none {
                                ParentReflectionStatusCard(
                                    child: child,
                                    summary: summary,
                                    layout: .homeCard,
                                    onViewReflection: {
                                        openReflection(summary, for: child)
                                    }
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

    private func openReflection(_ summary: ParentReflectionSummary, for child: ChildProfile) {
        switch summary.state {
        case .assignedPending:
            onOpenReflection(.reflectionPending(childId: child.id))
        case .completedReady:
            onOpenReflection(.reflectionArtifact(reflectionId: summary.id))
        case .none:
            break
        }
    }
}

#Preview {
    @Previewable @State var tab: EvlinTab = .home
    return HomeView(
        selectedTab: $tab,
        onOpenProfile: { _ in },
        onOpenNotifications: {},
        onOpenReflection: { _ in }
    )
    .environment(ParentReflectionFixtureStore())
}
