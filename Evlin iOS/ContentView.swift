import SwiftUI

/// Routes shared by every navigation stack in the parent shell (Home,
/// Insights). Adding a new pushable destination to either tab? Add the
/// case here and handle it in `appNavigationDestination`.
enum AppRoute: Hashable {
    case profile(ChildProfile, taskId: Int? = nil)
    /// Deep-link from a "completed reflection" notification. Opens the
    /// child's Profile with the reflection sub-tab already toggled on
    /// (so the parent lands on the Step 1/2/3 listing inline under the
    /// reflection header card, rather than the standalone
    /// `reflectionArtifact` route used for non-notification entries).
    case profileReflection(ChildProfile, reflectionId: UUID)
    case notifications
    /// Pushable Task Detail. We carry the full child + task by id so we
    /// can reach the live task model inside the view.
    case taskDetail(child: ChildProfile, taskId: Int)
    case taskDetailByBackendID(child: ChildProfile, backendTaskId: UUID)
    /// Pushable per-device app-limits screen. Mirrors `taskDetail` —
    /// pushes onto the same stack so edge-swipe-back works.
    case deviceDetail(device: DeviceItem, childId: String)
    case reflectionPending(childId: String)
    case reflectionArtifact(reflectionId: UUID)
    case reflectionStepDetail(reflectionId: UUID, stepId: UUID)
}

/// Compatibility alias — older code referenced `HomeRoute`.
typealias HomeRoute = AppRoute

struct ContentView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    /// Draggable Parent / Child mode pill (`FloatingModeToggle`). Shown ONLY in Single Device
    /// Mode (demo): the flag is set AND all three real ids exist. A normal real-parent / real-kid
    /// device never sets the flag, so the float never appears — the safety invariant.
    private var showsSingleDeviceModesToggle: Bool {
        onboardingComplete && SingleDeviceSession.shared.isActive
    }

    var body: some View {
        ZStack {
            Group {
                if !onboardingComplete {
                    OnboardingCoordinator()
                } else if appMode != "parent" && appMode != "child" {
                    OnboardingCoordinator()   // fallback
                } else if appMode == "parent" {
                    ParentRootView()
                        // Parent push transport: upload this device's APNs token
                        // to its own parent Device row so parent-audience feed
                        // pushes (reflection-complete, lock-delay, device offline)
                        // deliver as banners. Idempotent POST upsert; routed by
                        // appMode so it can't clobber the kid's token. The token
                        // itself is already requested + cached at launch
                        // (didFinishLaunching), so we only need to replay the
                        // upload here once the parent row id exists.
                        //
                        // Also request notification *display* permission — the kid
                        // onboarding does this, but the parent app never did, so
                        // parent pushes were delivered (APNs 200) yet invisible.
                        .task {
                            AppDelegate.requestNotificationAuthorizationIfNeeded()
                            AppDelegate.uploadCachedAPNsTokenIfPossible(using: APIClient())
                        }
                } else {
                    // Big-kid product UI (`BigKidRootView`) when paired + API base
                    // is known; otherwise a minimal "waiting for setup" placeholder.
                    ChildModeExperienceView()
                }
            }

            if showsSingleDeviceModesToggle {
                FloatingModeToggle()
            }
        }
        .onAppear { repairMissingCompletedModeIfNeeded() }
    }

    static func repairedCompletedOnboardingMode(
        onboardingComplete: Bool,
        currentAppMode: String,
        storedTokens: StoredTokens?,
        childDeviceID: String?
    ) -> String? {
        guard onboardingComplete,
              currentAppMode != "parent",
              currentAppMode != "child"
        else { return nil }
        if let storedTokens,
           storedTokens.needsFamily == false,
           storedTokens.familyID != nil {
            return "parent"
        }
        if childDeviceID.flatMap(UUID.init(uuidString:)) != nil {
            return "child"
        }
        return nil
    }

    private func repairMissingCompletedModeIfNeeded() {
        guard let repaired = Self.repairedCompletedOnboardingMode(
            onboardingComplete: onboardingComplete,
            currentAppMode: appMode,
            storedTokens: KeychainStore.shared.load(),
            childDeviceID: UserDefaults.standard.string(forKey: "evlin.childDeviceID")
        ) else { return }
        appMode = repaired
    }
}

struct ParentRootView: View {
    static let nonChatContentBottomInset = EvlinTabBar.visibleHeight

    @State private var selectedTab: EvlinTab = .home
    @State private var profilePath = NavigationPath()
    @State private var insightsPath = NavigationPath()
    @State private var banner: (title: String, body: String, avatarURL: String?)? = nil
    @State private var reflectionStore = ParentReflectionFixtureStore()
    @State private var parentReflectionPollTask: Task<Void, Never>? = nil
    @AppStorage("evlin.childDeviceID") private var pairedChildID: String = ""
    @EnvironmentObject private var apiClient: APIClient
    @Environment(FamilyStore.self) private var familyStore
    /// Created with a placeholder client (SwiftUI can't read the environment at
    /// `@StateObject` init); `CalendarView.onAppear` rebinds the shell's real
    /// client before any request fires.
    @StateObject private var calendarStore = CalendarStore(api: APIClient())
    /// Drives the bell's red dot (new-since-opened). Default-inits its
    /// baseURL from the persisted serverURL.
    @StateObject private var notifBell = NotificationFeedClient()
    /// Owned by the shell (not ChatView) so chat state — messages, pending
    /// confirm cards, thinking indicator — survives tab switches. The tab
    /// content is a `switch`, so ChatView is destroyed on every switch; a
    /// ChatView-local @StateObject would drop any un-actioned confirm card.
    @StateObject private var chatViewModel = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Keep the app shell itself out of keyboard avoidance so the tab bar
        // stays pinned to the physical screen bottom. ChatView handles keyboard
        // lift locally for its input composer only.
        ZStack(alignment: .bottom) {
            ZStack {
                switch selectedTab {
                case .home:
                    NavigationStack(path: $profilePath) {
                        HomeView(
                            selectedTab: $selectedTab,
                            notifications: homeNotifications,
                            onOpenProfile: { child in profilePath.append(AppRoute.profile(child)) },
                            onOpenNotifications: { notifBell.markOpened(); profilePath.append(AppRoute.notifications) },
                            bellHasNew: notifBell.hasNew
                        )
                        .appNavigationDestination(
                            path: $profilePath,
                            selectedTab: $selectedTab,
                            notifications: homeNotifications,
                            children: familyStore.childProfiles,
                            reflectionStore: reflectionStore
                        )
                    }
                case .calendar:
                    CalendarView(store: calendarStore)
                        .onAppear { calendarStore.rebind(api: apiClient) }
                case .chat:
                    ChatView(viewModel: chatViewModel)
                case .library:
                    LibraryView()
                case .insights:
                    NavigationStack(path: $insightsPath) {
                        InsightsView(
                            bellHasNew: notifBell.hasNew,
                            onOpenNotifications: {
                                notifBell.markOpened()
                                insightsPath.append(AppRoute.notifications)
                            }
                        )
                        .appNavigationDestination(
                            path: $insightsPath,
                            selectedTab: $selectedTab,
                            notifications: homeNotifications,
                            children: familyStore.childProfiles,
                            reflectionStore: reflectionStore
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, selectedTab == .chat ? 0 : Self.nonChatContentBottomInset)

            EvlinTabBar(selectedTab: $selectedTab)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .padding(.bottom, EvlinTabBar.bottomOffset)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task { await notifBell.refresh() }
        .onChange(of: scenePhase) { _, p in
            if p == .active { Task { await notifBell.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .evlinOpenNotifications)) { _ in
            // A tapped push routes the parent to the bell.
            selectedTab = .home
            notifBell.markOpened()
            profilePath.append(AppRoute.notifications)
        }
        .onReceive(NotificationCenter.default.publisher(for: .evlinOpenNotificationEvent)) { note in
            guard let eventID = note.userInfo?["event_id"] as? String, !eventID.isEmpty else {
                selectedTab = .home
                notifBell.markOpened()
                profilePath.append(AppRoute.notifications)
                return
            }
            PendingNotificationOpenStore().clear(eventID)
            Task { await openNotificationEvent(eventID) }
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
        .environment(reflectionStore)
        .onAppear {
            startParentReflectionPolling()
            openPendingNotificationEventIfNeeded()
        }
        .onDisappear {
            parentReflectionPollTask?.cancel()
            parentReflectionPollTask = nil
        }
        .onChange(of: pairedChildID) { _, newValue in
            startParentReflectionPolling()
            AppDelegate.handleChildDeviceIDAvailability(
                newValue,
                appMode: "parent",
                using: apiClient
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .bigKidStateInvalidated)) { _ in
            Task { await refreshParentReflectionState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .evlinNotificationFeedInvalidated)) { _ in
            Task { await notifBell.refresh() }
        }
    }

    private var homeNotifications: [HomeNotification] {
        // Walk every child, build two notification streams:
        //   1. Completion (or rework) entries when the kid has
        //      finished a reflection and parent hasn't acted yet.
        //   2. Nudge entries when the kid tapped "Give them a nudge"
        //      after our previously-acknowledged timestamp.
        let completions: [HomeMockData.ReflectionCompletion] = familyStore.childProfiles.compactMap { child in
            guard let rid = reflectionStore.completedReflectionId(childId: child.id),
                  let summary = reflectionStore.summary(childId: child.id) else {
                return nil
            }
            return HomeMockData.ReflectionCompletion(
                childId: child.id,
                childName: child.name,
                reflectionId: rid,
                isRework: summary.parentRedoNote != nil
            )
        }
        let nudges: [HomeMockData.ReflectionNudge] = familyStore.childProfiles.compactMap { child in
            guard reflectionStore.pendingNudgeAt(childId: child.id) != nil,
                  let summary = reflectionStore.summary(childId: child.id) else {
                return nil
            }
            return HomeMockData.ReflectionNudge(
                childId: child.id,
                childName: child.name,
                reflectionId: summary.id
            )
        }
        // HP-13: this list is regenerated on every body evaluation with
        // unread == true, so read/dismiss state must come from the durable
        // ack store (written by NotificationPanel's actions) — otherwise
        // "Mark all read" / dismiss silently undo themselves on reopen.
        return HomeNotificationAckStore.applying(
            to: HomeMockData.notifications(
                completedReflections: completions,
                pendingNudges: nudges
            )
        )
    }

    private var pairedBackendChildID: UUID? {
        guard !pairedChildID.isEmpty else { return nil }
        return UUID(uuidString: pairedChildID)
    }

    /// HP-10: resolve which child OWNS the paired device. `pairedChildID`
    /// (`evlin.childDeviceID`) is a DEVICE id, so map it through the family
    /// aggregate: the `ChildDTO` whose `.devices` contains that device id is
    /// the owner. Falls back to the only child when the family has exactly
    /// one; returns nil when the store hasn't loaded yet (callers skip the
    /// sync round and retry on the next poll) or when no child matches in a
    /// multi-child family — never the previewLiam fixture, which used to pin
    /// reflection state to whatever child happened to be first.
    private var pairedChild: ChildProfile? {
        let profiles = familyStore.childProfiles
        guard !profiles.isEmpty else { return nil }
        if let owner = familyStore.children.first(where: { dto in
            dto.devices.contains {
                $0.device_id.caseInsensitiveCompare(pairedChildID) == .orderedSame
            }
        }) {
            return profiles.first { $0.id == owner.id }
        }
        return profiles.count == 1 ? profiles.first : nil
    }

    private func startParentReflectionPolling() {
        parentReflectionPollTask?.cancel()

        guard pairedBackendChildID != nil,
              BigKidParentClient(baseURLString: apiClient.baseURL) != nil else {
            return
        }

        parentReflectionPollTask = Task {
            await refreshParentReflectionState()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await refreshParentReflectionState()
            }
        }
    }

    @MainActor
    private func refreshParentReflectionState() async {
        guard let childID = pairedBackendChildID,
              let client = BigKidParentClient(baseURLString: apiClient.baseURL) else {
            return
        }
        // HP-10: the snapshot we fetch belongs to the child that owns the
        // paired device — store it under THAT child, never under
        // `childProfiles.first` / previewLiam. If the family aggregate
        // hasn't loaded yet (empty store), skip this round entirely; the
        // 8s poll (or the next bigKidStateInvalidated ping) retries.
        guard let child = pairedChild else { return }

        do {
            let snapshot = try await client.fetchKidState(childId: childID)
            if let req = snapshot.reflectionRequest {
                do {
                    let parentReq = try await apiClient.fetchReflectionForParent(reflectionId: req.id)
                    reflectionStore.syncBackendReflection(for: child, parentRequest: parentReq)
                } catch {
                    reflectionStore.syncBackendReflection(for: child, request: req)
                }
            } else {
                reflectionStore.syncBackendReflection(for: child, request: nil)
            }
        } catch {
            // Home should keep rendering its last known state if the
            // lightweight parent refresh misses once. ProfileView still
            // surfaces detailed refresh errors in its own task section.
        }
    }

    @MainActor
    private func openNotificationEvent(_ eventID: String) async {
        selectedTab = .home
        await notifBell.refresh()
        guard let notification = notifBell.items.first(where: { $0.eventId == eventID }) else {
            notifBell.markOpened()
            profilePath.append(AppRoute.notifications)
            return
        }
        notifBell.markOpened()
        await notifBell.mark(notification.id, action: "opened")
        openParentNotificationRoute(
            ParentNotificationRouteResolver.route(
                for: notification,
                children: familyStore.childProfiles
            )
        )
    }

    @MainActor
    private func openPendingNotificationEventIfNeeded() {
        guard let eventID = PendingNotificationOpenStore().consume() else { return }
        Task { await openNotificationEvent(eventID) }
    }

    @MainActor
    private func openParentNotificationRoute(_ route: ParentNotificationRoute?) {
        switch route {
        case .calendar:
            selectedTab = .calendar
        case .appRoute(let appRoute):
            selectedTab = .home
            profilePath.append(appRoute)
        case nil:
            selectedTab = .home
            profilePath.append(AppRoute.notifications)
        }
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
        selectedTab: Binding<EvlinTab>,
        notifications: [HomeNotification] = HomeMockData.notifications,
        children: [ChildProfile] = [],
        reflectionStore: ParentReflectionFixtureStore? = nil
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
                    },
                    onOpenReflection: { route in
                        path.wrappedValue.append(route)
                    }
                )
            case .profileReflection(let child, _):
                ProfileView(
                    child: child,
                    initialReflectionSubTab: true,
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
                    },
                    onOpenReflection: { route in
                        path.wrappedValue.append(route)
                    }
                )
            case .notifications:
                FeedNotificationPanel(
                    onClose: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    },
                    onOpenDeepLink: { link in
                        // Pop the notifications panel, then route to the target.
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                        switch ParentNotificationRouteResolver.route(for: link, children: children) {
                        case .calendar:
                            selectedTab.wrappedValue = .calendar
                        case .appRoute(let appRoute):
                            path.wrappedValue.append(appRoute)
                        case nil:
                            break
                        }
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
            case .taskDetailByBackendID(let child, let backendTaskId):
                TaskDetailView(
                    childId: child.id,
                    backendTaskId: backendTaskId,
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
            case .reflectionPending(let childId):
                ReflectionPendingView(
                    childId: childId,
                    onBack: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    }
                )
            case .reflectionArtifact(let reflectionId):
                ReflectionArtifactView(
                    reflectionId: reflectionId,
                    onBack: {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    }
                )
            case .reflectionStepDetail(let reflectionId, let stepId):
                ReflectionStepDetailView(
                    reflectionId: reflectionId,
                    stepId: stepId,
                    onBack: {
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
        .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}

// ContentView honoring @AppStorage — starts at onboarding if you haven't completed it.
#Preview("ContentView") {
    ContentView()
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
        .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}
