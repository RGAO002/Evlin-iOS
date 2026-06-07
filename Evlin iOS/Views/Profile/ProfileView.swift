import SwiftUI

struct ProfileView: View {
    let child: ChildProfile
    var initialTaskId: Int? = nil
    /// When true, the profile opens with `profileTab = .reflection`
    /// (Step 1/2/3 listing visible inline under the reflection header
    /// card) instead of the default overview sub-tab. Used by the
    /// "{Name} completed reflection" notification deep-link so the
    /// parent lands directly on the review surface.
    var initialReflectionSubTab: Bool = false
    var onBack: () -> Void = {}
    var onOpenCalendar: () -> Void = {}
    /// Called when the user opens a task. The parent stack should push a
    /// `.taskDetail` route — Task Detail is now a navigation push (right-
    /// to-left, edge-swipe back), no longer a fullScreenCover sheet.
    var onOpenTaskDetail: (TaskItem) -> Void = { _ in }
    /// Called when the user taps an enrolled device row. Same deal as
    /// `onOpenTaskDetail`: the parent stack pushes a `.deviceDetail`
    /// route so the per-device app-limits screen slides in from the
    /// right and supports edge-swipe back.
    var onOpenDevice: (DeviceItem) -> Void = { _ in }
    /// Called when the reflection status card CTA should push into the
    /// parent reflection flow.
    var onOpenReflection: (AppRoute) -> Void = { _ in }

    @State private var rules: [RuleItem] = []
    @State private var tasks: [TaskItem] = []
    @State private var events: [ProfileEvent] = []
    @State private var devices: [DeviceItem] = []
    @State private var editingRule: RuleItem? = nil
    @State private var showProfileMenu = false
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
    @State private var devicesExpanded = true
    @State private var rulesExpanded = true
    @State private var addMode: AddBottomMode? = nil
    /// In-profile sub-tab toggle for when an active reflection exists.
    /// The header card's CTA stripe flips between
    ///   `.overview`   — shows Current Tasks / Devices / Rules
    ///   `.reflection` — shows the Reflection Assignment listing inline
    /// matching the design HTML pattern (`profileTab` in screen-profile).
    /// Resets to `.overview` whenever the child changes.
    @State private var profileTab: ProfileSubTab = .overview
    @State private var showCancelReflectionAlert = false

    enum ProfileSubTab { case overview, reflection }

    // Backend wiring (Phase 12 — Profile ↔ BigKid task loop).
    // Active when this is Liam AND we have a paired child UUID stored
    // (parent received it during 6-digit pairing). Falls back to
    // ProfileMockData for other children or when not paired.
    @AppStorage("evlin.childDeviceID") private var pairedChildID: String = ""
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @Environment(FamilyStore.self) private var familyStore
    @EnvironmentObject private var apiClient: APIClient
    @State private var backendError: String? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    private var backendChildID: UUID? {
        guard child.id == "liam", !pairedChildID.isEmpty else { return nil }
        return UUID(uuidString: pairedChildID)
    }
    private var bigKidParent: BigKidParentClient? {
        guard backendChildID != nil else { return nil }
        return BigKidParentClient(baseURLString: apiClient.baseURL)
    }

    // Local mutable status so the Lock/Unlock button can flip the avatar
    // and pills without requiring a global mutation. See HTML 1029-1034.
    @State private var localStatus: ChildProfile.Status = .unlocked
    // Local mutable copy of the child's display fields so Edit Profile
    // can show changes within the session.
    @State private var localName: String = ""
    @State private var localAge: Int = 0
    @State private var localSubtitle: String = ""
    @State private var localAvatarURL: String? = nil

    private var displayChild: ChildProfile {
        ChildProfile(
            id: child.id,
            name: localName.isEmpty ? child.name : localName,
            age: localAge == 0 ? child.age : localAge,
            avatarURL: localAvatarURL ?? child.avatarURL,
            accentColor: child.accentColor,
            status: localStatus,
            timeLeft: child.timeLeft,
            timePct: child.timePct,
            subtitle: localSubtitle.isEmpty ? child.subtitle : localSubtitle
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "\(displayChild.name)'s Space", onBack: onBack) {
                Menu {
                    Button {
                        showEditProfile = true
                    } label: {
                        Label("Edit Profile", systemImage: "pencil")
                    }
                    #if DEBUG
                    Button {
                        reflectionStore.simulateAssignment(childId: child.id)
                    } label: {
                        Label("Simulate reflection assigned", systemImage: "figure.mind.and.body")
                    }
                    Button {
                        reflectionStore.simulateCompletion(childId: child.id)
                    } label: {
                        Label("Simulate reflection complete", systemImage: "checkmark.seal")
                    }
                    Button {
                        reflectionStore.simulateNudge(childId: child.id)
                    } label: {
                        Label("Simulate kid nudge", systemImage: "hand.point.up.left.fill")
                    }
                    Button {
                        reflectionStore.clear(childId: child.id)
                    } label: {
                        Label("Clear reflection state", systemImage: "xmark.circle")
                    }
                    #endif
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Profile", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.evOnSurface)
                        .frame(width: 40, height: 40)
                }
            }

            ScrollView {
                VStack(spacing: 26) {
                    // Header card: reflection state replaces time/lock UI
                    // while keeping the rest of the profile surface intact.
                    // Per design (HTML lines 1265-1357), the reflection
                    // header's CTA stripe is an inline sub-tab toggle:
                    // tap to switch between "View reflection" (overview
                    // sub-tab) and "Back to profile overview" (reflection
                    // sub-tab). The body below switches accordingly.
                    if let summary = activeReflectionSummary {
                        ParentReflectionStatusCard(
                            child: displayChild,
                            summary: summary,
                            layout: .profileHeader,
                            showingBackToOverview: profileTab == .reflection,
                            onViewReflection: {
                                withAnimation(.easeOut(duration: 0.22)) {
                                    profileTab = (profileTab == .reflection)
                                        ? .overview
                                        : .reflection
                                }
                            }
                        )

                        if profileTab == .reflection {
                            ReflectionAssignmentListing(
                                summary: summary,
                                showsSectionHeader: false,
                                onCancel: { showCancelReflectionAlert = true }
                            )
                        }
                    } else {
                        summaryCard
                    }

                    // Reflection sub-tab hides everything else (HTML lines
                    // 1613-1660 only render Devices / Rules / Tasks in the
                    // overview sub-tab when reflection is active).
                    if profileTab == .overview || activeReflectionSummary == nil {
                        // Current Tasks (HTML 1058-1063)
                        VStack(spacing: 0) {
                            SectionHead(title: "Current Tasks") {
                                tasksDonePill
                            }
                            VStack(spacing: 10) {
                                ForEach(tasks) { t in
                                    TaskRow(
                                        task: t,
                                        onApprove: { handleApprove(t) },
                                        onRedo: { handleRedo(t, reason: nil) },
                                        onOpen: { onOpenTaskDetail(t) }
                                    )
                                }
                            }
                            if let err = backendError {
                                Text("⚠︎ Couldn't refresh tasks: \(err)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }

                        // NOTE: "Today's Schedule" section was removed because the
                        // latest design HTML (Evlin Parent Dashboard (1).html) no
                        // longer includes it on the kid profile screen. Keeping
                        // the implementation commented in case we want to bring
                        // it back. To restore, uncomment `todaysScheduleSection`
                        // (defined below) and add it here between Tasks and
                        // Devices.
                        //
                        // todaysScheduleSection

                        // Enrolled Devices (collapsible — HTML 1064-1085)
                        devicesSection

                        // Active Rules (collapsible) — moved to bottom per HTML 1086-1121
                        activeRulesSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                // FAB is 56pt + 24pt bottom padding ≈ 80pt of permanent
                // overlap at the bottom-trailing. Reserve ~120pt of
                // scroll-content footroom so the last row (Active
                // Rules → Morning Chores edit icon, when expanded)
                // can scroll above the FAB instead of sitting under
                // it. 40pt was leaving the trailing pencil hidden.
                .padding(.bottom, 120)
            }
        }

            // Floating + FAB (HTML 1124-1130)
            Button {
                addMode = .menu
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.evPrimary))
                    .shadow(color: Color.evPrimary.opacity(0.32), radius: 24, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        .background(Color.evSurfaceContainerLow)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        // Task Detail is now a NavigationStack push handled by the parent
        // stack (see `appNavigationDestination`). Edit Task lives inside
        // TaskDetailView itself.
        //
        // Custom modal overlays — see EvlinSheetCard. We use these
        // instead of native `.sheet` because the system sheet inherits a
        // dark background under dark mode and this app explicitly stays
        // on the light palette.
        .overlay {
            EvlinSheetCardItem(item: $editingRule) { rule in
                EditRuleForm(
                    rule: rule,
                    onSave: { updated in
                        if let i = rules.firstIndex(where: { $0.id == updated.id }) {
                            rules[i] = updated
                        }
                        editingRule = nil
                    },
                    onDelete: {
                        rules.removeAll(where: { $0.id == rule.id })
                        editingRule = nil
                    },
                    onCancel: { editingRule = nil }
                )
            }
        }
        .alert("Cancel reflection?", isPresented: $showCancelReflectionAlert) {
            Button("Keep reflection", role: .cancel) {}
            Button("Cancel reflection", role: .destructive) {
                // Fire-and-forget the backend cancel BEFORE we clear
                // the local fixture. If we cleared first and skipped
                // the network call, the next 8s poll would re-sync
                // the still-active backend reflection right back in,
                // making the cancel look like it "reverted" — which
                // is the exact bug the parent reported.
                let rid = reflectionStore.summary(for: child)?.id
                if let rid {
                    Task {
                        try? await apiClient.cancelChildReflection(reflectionId: rid)
                    }
                }
                reflectionStore.clear(childId: child.id)
                withAnimation(.easeOut(duration: 0.22)) {
                    profileTab = .overview
                }
            }
        } message: {
            Text("\(displayChild.name)'s screen-time lock will be lifted and the reflection won't be saved.")
        }
        .onChange(of: activeReflectionSummary?.id) { _, newId in
            // If the reflection clears while the user is on the
            // reflection sub-tab (e.g. backend poll reports it's been
            // approved, or chat approve cleared the fixture), snap back
            // to the overview sub-tab so the empty state isn't shown.
            if newId == nil, profileTab == .reflection {
                profileTab = .overview
            }
        }
        .alert("Delete \(displayChild.name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onBack()
            }
        } message: {
            Text("This will remove the profile and all associated data.")
        }
        .fullScreenCover(isPresented: $showEditProfile) {
            ProfileEditSheet(
                name: $localName,
                age: $localAge,
                subtitle: $localSubtitle,
                avatarURL: $localAvatarURL,
                isNew: false,
                onClose: { showEditProfile = false },
                onSave: { showEditProfile = false }
            )
        }
        .overlay {
            EvlinSheetCardItem(item: $addMode) { _ in
                AddBottomSheet(
                    mode: $addMode,
                    child: child,
                    onCreateTask: { newTask in
                        handleCreateTask(newTask)
                        addMode = nil
                    },
                    onCreateRule: { newRule in
                        rules.append(newRule)
                        addMode = nil
                    },
                    onCreateCalendar: { event in
                        var todays = CalendarMockData.runtimeEventsByOffset[0] ?? []
                        todays.append(event)
                        CalendarMockData.runtimeEventsByOffset[0] = todays
                        addMode = nil
                    },
                    onCreateDevice: { newDevice in
                        devices.append(newDevice)
                        addMode = nil
                    }
                )
            }
        }
        .onAppear {
            rules = ProfileMockData.rules(for: child.id)
            events = ProfileMockData.events(for: child.id)
            // Enrolled Devices: prefer the live FamilyStore child's devices
            // (real GET /family data). Fall back to the mock only when this
            // child isn't in the store (preview / legacy fixtures).
            if let liveDevices = familyStore.child(byId: child.id)?.devices, !liveDevices.isEmpty {
                devices = liveDevices.map(DeviceItem.init(dto:))
            } else {
                devices = ProfileMockData.devices(for: child.id)
            }
            // Initialise local mutables from the source profile.
            localStatus = child.status
            if localName.isEmpty { localName = child.name }
            if localAge == 0    { localAge = child.age }
            if localSubtitle.isEmpty { localSubtitle = child.subtitle }
            if localAvatarURL == nil { localAvatarURL = child.avatarURL }

            // Tasks: backend if paired (Liam), otherwise mock.
            if backendChildID != nil {
                tasks = []   // wait for first refresh; avoids flashing seed copy
                Task { await refreshFromBackend() }
                startPollingBackend()
            } else {
                tasks = ProfileMockData.tasks(for: child.id)
            }

            // Deep-link from notifications: if a taskId was supplied,
            // jump straight to its detail screen.
            if let id = initialTaskId, let task = tasks.first(where: { $0.id == id }) {
                DispatchQueue.main.async { onOpenTaskDetail(task) }
            }
            // Deep-link from a "completed reflection" notification:
            // flip the profile sub-tab to .reflection so the parent
            // sees Step 1/2/3 inline immediately. Harmless if no
            // reflection summary is active — the conditional render
            // in the body simply falls back to the overview content.
            if initialReflectionSubTab {
                profileTab = .reflection
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: - Backend wiring (Phase 12)

    /// Pull `/parent/state/{childId}` and rebuild `tasks` from real backend
    /// data. No-op when not paired.
    ///
    /// When the kid-state snapshot reports an active reflection, this
    /// also fetches the richer `/parent/reflection/{rid}` payload so
    /// the parent-side fixture store gets each quiz question's
    /// correct-answer index (Step-2 highlighting). The kid endpoint
    /// strips correctIndex by design — only the parent fetch carries
    /// it.
    @MainActor
    private func refreshFromBackend() async {
        guard let cid = backendChildID, let client = bigKidParent else { return }
        do {
            let snapshot = try await client.fetchKidState(childId: cid)
            tasks = snapshot.tasks.enumerated().map { idx, t in
                TaskItem.from(backend: t, sequenceID: idx + 1)
            }

            if let req = snapshot.reflectionRequest {
                // Best-effort: try the parent endpoint first so we get
                // correct-answer indices. Fall back to the kid-state
                // request shape if the parent endpoint fails (older
                // backend, network blip, etc.) — the Step-2 UI will
                // still render but mark no option as correct.
                do {
                    let parentReq = try await apiClient.fetchReflectionForParent(reflectionId: req.id)
                    reflectionStore.syncBackendReflection(for: child, parentRequest: parentReq)
                } catch {
                    reflectionStore.syncBackendReflection(for: child, request: req)
                }
            } else {
                reflectionStore.syncBackendReflection(for: child, request: nil)
            }
            backendError = nil
        } catch {
            backendError = (error as? BigKidAPIError).map(\.detail) ?? error.localizedDescription
        }
    }

    /// Refresh every 8s while the screen is visible. Lightweight — JSON
    /// payload is small and the backend store is in-memory.
    private func startPollingBackend() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                await refreshFromBackend()
            }
        }
    }

    /// Approve handler. Backend-backed if `task.backendID` exists.
    /// For bypass-state rows we approve the bypass; for review-state rows
    /// we approve the task itself.
    private func handleApprove(_ task: TaskItem) {
        guard let backendID = task.backendID, let client = bigKidParent else {
            // Mock-only fallback (non-Liam children).
            if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[i].state = (task.state == .bypass) ? .bypassed : .done
            }
            return
        }
        // Optimistic update so the row flips immediately.
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i].state = (task.state == .bypass) ? .bypassed : .done
        }
        Task {
            do {
                if task.state == .bypass, let bid = task.backendBypassID {
                    _ = try await client.respondBypass(
                        bypassId: bid, decision: .approve, message: nil
                    )
                } else {
                    _ = try await client.reviewTask(taskId: backendID, decision: .approve)
                }
                await refreshFromBackend()
            } catch {
                await MainActor.run {
                    backendError = "approve failed: \(error.localizedDescription)"
                }
                await refreshFromBackend()  // pull authoritative state back
            }
        }
    }

    /// Redo handler. Same backend semantics as approve, but for the redo
    /// branch. `reason` is wired from TaskDetailSheet's redo flow; the
    /// inline row redo button passes nil.
    private func handleRedo(_ task: TaskItem, reason: String?) {
        guard let backendID = task.backendID, let client = bigKidParent else {
            if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[i].state = .pending
            }
            return
        }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i].state = .pending
        }
        Task {
            do {
                if task.state == .bypass, let bid = task.backendBypassID {
                    _ = try await client.respondBypass(
                        bypassId: bid, decision: .deny, message: reason
                    )
                } else {
                    _ = try await client.reviewTask(
                        taskId: backendID, decision: .redo, redoReason: reason
                    )
                }
                await refreshFromBackend()
            } catch {
                await MainActor.run {
                    backendError = "redo failed: \(error.localizedDescription)"
                }
                await refreshFromBackend()
            }
        }
    }

    /// Create-task handler. Uses backend if paired, mock list otherwise.
    private func handleCreateTask(_ newTask: TaskItem) {
        guard let cid = backendChildID, let client = bigKidParent else {
            tasks.append(newTask)
            return
        }
        // Map the parent-UI category strings back to backend enum.
        let category: BigKidTaskCategory = {
            switch (newTask.category ?? "Chore").lowercased() {
            case "homework": return .homework
            case "self-care", "routine", "reading": return .selfCare
            default: return .chores
            }
        }()
        Task {
            do {
                _ = try await client.createTask(
                    childId: cid, title: newTask.title,
                    description: newTask.description ?? "",
                    category: category, due: newTask.dueLabel
                )
                await refreshFromBackend()
            } catch {
                await MainActor.run {
                    backendError = "create failed: \(error.localizedDescription)"
                    // Show the new task locally too so the user sees something.
                    tasks.append(newTask)
                }
            }
        }
    }

    // MARK: - Subsections (broken out so the body type-checks fast)

    private var activeReflectionSummary: ParentReflectionSummary? {
        guard let summary = reflectionStore.summary(for: child), summary.state != .none else {
            return nil
        }
        return summary
    }

    private func openReflection(_ summary: ParentReflectionSummary) {
        switch summary.state {
        case .assignedPending:
            onOpenReflection(.reflectionPending(childId: child.id))
        case .completedReady:
            onOpenReflection(.reflectionArtifact(reflectionId: summary.id))
        case .none:
            break
        }
    }

    /// Green pill with `doneCount/total` per HTML 1059.
    private var tasksDonePill: some View {
        let done = tasks.filter { $0.state == .done }.count
        return Text("\(done)/\(tasks.count)")
            .font(.custom("Manrope", size: 11).weight(.heavy))
            .foregroundStyle(Color.evSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 24)
            .background(Capsule().fill(Color.evSecondaryContainer))
    }

    private var devicesSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    devicesExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Enrolled Devices")
                        .font(.custom("Manrope", size: 16).weight(.heavy))
                        .tracking(-0.16)
                        .foregroundStyle(Color.evOnSurface)
                    EvlinPill(
                        text: "\(devices.count) \(localStatus == .unlocked ? "active" : "locked")",
                        tone: localStatus == .unlocked ? .success : .danger,
                        size: .xs
                    )
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.evOutline)
                        .rotationEffect(.degrees(devicesExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                // Make the entire header row hit-test as one rectangle.
                // Without this the Spacer between the pill and the chevron
                // is "empty" and a tap there does nothing — the user would
                // have to land on the chevron itself to expand/collapse.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if devicesExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                        DeviceRow(
                            iconSystemName: d.iconSystemName,
                            name: d.name,
                            detail: d.detail,
                            locked: localStatus != .unlocked,
                            timeLeft: child.timeLeft,
                            timePct: child.timePct,
                            isLast: idx == devices.count - 1,
                            onPress: { onOpenDevice(d) }
                        )
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
    }

    // Keep this helper around (commented out) so we can flip the section
    // back on without rebuilding it. Mirror of pre-pixel-perfect-pass impl.
    //
    // private var todaysScheduleSection: some View {
    //     VStack(spacing: 0) {
    //         SectionHead(title: "Today's Schedule") {
    //             Button { onOpenCalendar() } label: {
    //                 Text("OPEN CALENDAR")
    //                     .font(.custom("Inter", size: 10).weight(.heavy))
    //                     .tracking(1.4)
    //                     .foregroundStyle(Color.evPrimary)
    //             }
    //         }
    //         VStack(spacing: 0) {
    //             ForEach(events) { e in
    //                 HStack(spacing: 14) {
    //                     Text(e.time)
    //                         .font(.custom("Inter", size: 11).weight(.bold))
    //                         .tracking(0.6)
    //                         .foregroundStyle(Color.evOnSurfaceVariant)
    //                         .frame(width: 72, alignment: .leading)
    //                     Circle().fill(child.accentColor).frame(width: 6, height: 6)
    //                     VStack(alignment: .leading, spacing: 1) {
    //                         Text(e.title)
    //                             .font(.custom("Manrope", size: 14).weight(.bold))
    //                             .foregroundStyle(Color.evPrimary)
    //                         if let loc = e.location {
    //                             Text(loc)
    //                                 .font(.custom("Inter", size: 11))
    //                                 .foregroundStyle(Color.evOnSurfaceVariant)
    //                         }
    //                     }
    //                     Spacer()
    //                 }
    //                 .padding(.vertical, 12)
    //                 .padding(.horizontal, 14)
    //                 .overlay(
    //                     Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
    //                     alignment: .bottom
    //                 )
    //             }
    //         }
    //         .background(
    //             RoundedRectangle(cornerRadius: 18, style: .continuous)
    //                 .fill(Color.evSurfaceContainerLowest)
    //         )
    //         .overlay(
    //             RoundedRectangle(cornerRadius: 18, style: .continuous)
    //                 .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
    //         )
    //     }
    // }

    private var activeRulesSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    rulesExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Active Rules")
                        .font(.custom("Manrope", size: 16).weight(.heavy))
                        .tracking(-0.16)
                        .foregroundStyle(Color.evOnSurface)
                    EvlinPill(
                        text: "\(rules.filter(\.on).count)/\(rules.count)",
                        tone: .success, size: .xs
                    )
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.evOutline)
                        .rotationEffect(.degrees(rulesExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                // Same reasoning as Enrolled Devices — Spacer hit-testing
                // requires an explicit content shape on the label.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if rulesExpanded {
                VStack(spacing: 0) {
                    ForEach($rules) { $rule in
                        RuleRow(iconSystemName: rule.iconSystemName,
                                title: rule.title, detail: rule.detail,
                                isOn: $rule.on, tone: rule.tone,
                                onEdit: { editingRule = rule })
                            .padding(.horizontal, 14)
                            .overlay(
                                Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1),
                                alignment: .bottom
                            )
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
    }

    private var summaryCard: some View {
        let isUnlocked = localStatus == .unlocked
        return VStack(spacing: 16) {
            HStack(spacing: 18) {
                EvlinAvatarView(
                    url: displayChild.avatarURL,
                    name: displayChild.name,
                    size: 64,
                    status: localStatus
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayChild.name)
                        .font(.custom("Manrope", size: 22).weight(.heavy))
                        .tracking(-0.22)
                        .foregroundStyle(Color.evPrimary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 4) {
                        Text(child.timeLeft)
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evSecondary)
                        Text("left today")
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }

            // Lock/Unlock big CTA — toggles localStatus. HTML 1036-1056.
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    localStatus = isUnlocked ? .locked : .unlocked
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isUnlocked ? "lock" : "lock.open")
                        .font(.system(size: 18, weight: .semibold))
                    Text(isUnlocked
                         ? "Lock \(displayChild.name)'s devices"
                         : "Unlock \(displayChild.name)'s devices")
                        .font(.custom("Manrope", size: 14).weight(.heavy))
                        .tracking(0.2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isUnlocked
                              ? AnyShapeStyle(Color.evSecondaryGradient)
                              : AnyShapeStyle(Color.evError))
                )
                .shadow(color: (isUnlocked ? Color.evSecondary : Color.evError).opacity(0.32),
                        radius: 14, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}

#Preview("Liam") {
    NavigationStack {
        ProfileView(child: .previewLiam)
    }
    .environmentObject(APIClient())
    .environment(ParentReflectionFixtureStore())
    .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}

#Preview("Maya") {
    NavigationStack {
        ProfileView(child: .previewMaya)
    }
    .environmentObject(APIClient())
    .environment(ParentReflectionFixtureStore())
    .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}

#Preview("Emma (locked)") {
    NavigationStack {
        ProfileView(child: .previewEmma)
    }
    .environmentObject(APIClient())
    .environment(ParentReflectionFixtureStore())
    .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}
