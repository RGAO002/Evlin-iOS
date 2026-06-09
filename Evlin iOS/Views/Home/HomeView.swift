import SwiftUI

struct HomeView: View {
    @AppStorage("parentName") private var parentName: String = ""
    @State private var showSettings = false
    @Environment(FamilyStore.self) private var familyStore
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

    private var displayParentName: String {
        if let server = familyStore.selfParent?.display_name,
           !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return server
        }
        let trimmed = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "there" : trimmed
    }

    private var unreadCount: Int {
        notifications.filter(\.unread).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                EvlinAvatarView(
                    url: familyStore.selfParent?.avatar.signed_url,
                    name: displayParentName,
                    size: 40
                )
                .padding(.leading, 20)

                GlassmorphicHeader(title: "", kicker: "\(greeting), \(displayParentName)") {
                    HStack(spacing: 4) {
                        HeaderIconButton(systemName: "bell", badge: unreadCount > 0) {
                            onOpenNotifications()
                        }
                        HeaderIconButton(systemName: "gearshape") {
                            showSettings = true
                        }
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
                        let children = familyStore.childProfiles
                        if children.isEmpty {
                            HomeChildrenEmptyState(state: familyStore.state)
                        } else {
                            ForEach(children) { child in
                                // Each row is its OWN view that holds its
                                // own @Environment(ParentReflectionFixtureStore.self)
                                // observation. This sidesteps the SwiftUI/
                                // NavigationStack quirk where a top-of-stack
                                // child mutating the store doesn't invalidate
                                // the underlying-stack parent's body. The
                                // row, as a leaf observer, still re-evaluates
                                // its own body when the store changes — no
                                // need to wait for HomeView.body to re-run.
                                HomeChildRow(
                                    child: child,
                                    onOpenProfile: onOpenProfile
                                )
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .refreshable { await familyStore.refresh() }
        }
        .background(Color.evSurfaceContainerLow)
        .fullScreenCover(isPresented: $showSettings) {
            HomeSettingsSheet(onClose: { showSettings = false })
        }
    }
}

/// Per-child row used by the Home Children list. Lives in its own
/// View struct so each row holds an independent
/// `@Environment(ParentReflectionFixtureStore.self)` observation —
/// each row's body re-evaluates the moment the store mutates,
/// regardless of whether `HomeView` itself is the topmost view in a
/// NavigationStack.
private struct HomeChildRow: View {
    let child: ChildProfile
    var onOpenProfile: (ChildProfile) -> Void

    var body: some View {
        // ParentReflectionFixtureStore is a pure in-memory FIXTURE (no backend
        // polling) — hide its fabricated reflection status for beta (spec H4).
        // When a real reflection-poll store lands, restore the summary branch.
        ProfileCard(child: child) {
            onOpenProfile(child)
        }
    }
}

/// Placeholder shown when the FamilyStore has no children yet — e.g. not
/// signed in, pre-pairing, or a cold-cache load failure. Renders an
/// informative card rather than crashing on an empty list (spec §6.3).
private struct HomeChildrenEmptyState: View {
    let state: FamilyStore.LoadState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state == .loading ? "person.2" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.evOutline)
            Text(title)
                .font(.custom("Manrope", size: 15).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text(subtitle)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    private var title: String {
        switch state {
        case .loading: return "Loading your family…"
        case .failed:  return "Couldn't load your family"
        default:       return "No children yet"
        }
    }

    private var subtitle: String {
        switch state {
        case .loading: return "Fetching your children and devices."
        case .failed:  return "Pull to refresh, or check your connection."
        default:       return "Add a child to start managing their screen time."
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
    .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}

#Preview("Home — under reflection") {
    @Previewable @State var tab: EvlinTab = .home
    let store = ParentReflectionFixtureStore()
    store.simulateAssignment(childId: "preview-child")
    return HomeView(
        selectedTab: $tab,
        onOpenProfile: { _ in },
        onOpenNotifications: {}
    )
    .environment(store)
    .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}
