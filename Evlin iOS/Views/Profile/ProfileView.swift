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

    @State private var tasks: [TaskItem] = []
    @State private var devices: [DeviceItem] = []
    @State private var rules: [RuleItem] = []
    @State private var editingRule: RuleItem? = nil
    @State private var showDSTEditor = false
    @State private var dailyLimitMinutes: Int = 120
    @State private var showProfileMenu = false
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
    @State private var devicesExpanded = true
    @State private var rulesExpanded = true
    @State private var addMode: AddBottomMode? = nil
    @State private var showAddDevicePairing = false
    @State private var addedDeviceKidName = ""
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
    // Active when this child is the one the parent actually paired with —
    // resolved via `FamilyStore.ownsPairedDevice` (no more hardcoded
    // "liam" gate). When inactive, the screen shows honest empty states.
    @AppStorage("evlin.childDeviceID") private var pairedChildID: String = ""
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @Environment(FamilyStore.self) private var familyStore
    @EnvironmentObject private var apiClient: APIClient
    @State private var backendError: String? = nil
    @State private var deleteError: String? = nil
    @State private var addError: String? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    private var backendChildID: UUID? {
        // Prefer the locally-paired id when it belongs to THIS child (multi-child
        // disambiguation). Fall back to this child's device from the backend
        // family aggregate so a fresh login — where the local `evlin.childDeviceID`
        // is empty — still resolves the already-paired device instead of wrongly
        // prompting "pair the kid's device".
        if familyStore.ownsPairedDevice(childId: child.id, pairedDeviceID: pairedChildID),
           let id = UUID(uuidString: pairedChildID) {
            return id
        }
        if let dev = familyStore.child(byId: child.id)?.devices.first,
           let id = UUID(uuidString: dev.device_id) {
            return id
        }
        return nil
    }
    private var bigKidParent: BigKidParentClient? {
        guard backendChildID != nil else { return nil }
        return BigKidParentClient(baseURLString: apiClient.baseURL)
    }

    // Local mutable status so the Lock/Unlock button can flip the avatar
    // and pills without requiring a global mutation. See HTML 1029-1034.
    @State private var localStatus: ChildProfile.Status = .unlocked
    // Lock/Unlock-all CTA wiring (POST /parent/device/lock-all|unlock-all).
    @State private var lockBusy = false
    @State private var lockError: String? = nil
    // Neutral (non-error) status note, e.g. "queued — will apply when the
    // phone next checks in". Shown in muted text, distinct from lockError.
    @State private var lockNote: String? = nil
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

    /// Format minutes into a human-readable limit string (same logic as ProfileMockData).
    private func formatLimit(_ minutes: Int) -> String {
        ProfileMockData.formatLimit(minutes)
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
                            if tasks.isEmpty {
                                sectionEmptyState(
                                    icon: "checklist",
                                    text: backendChildID == nil
                                        ? "No tasks yet — pair \(displayChild.name)'s device to assign and review tasks."
                                        : "No tasks yet."
                                )
                            } else {
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
        //
        // NOTE: the per-rule edit modal was removed together with the
        // fixture rules — there is no rules backend yet (HP-3/HP-4).
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
                // HP-2: really delete (DELETE /family/children/{id}) and only
                // pop on success. A 409 (child still has a linked device) or
                // any other failure surfaces below and keeps the screen.
                Task { await performDelete() }
            }
        } message: {
            Text("This will remove the profile and all associated data.")
        }
        .alert("Couldn't delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) { addError = nil }
        } message: {
            Text(addError ?? "")
        }
        .fullScreenCover(isPresented: $showEditProfile) {
            ProfileEditSheet(
                name: $localName,
                age: $localAge,
                subtitle: $localSubtitle,
                avatarURL: $localAvatarURL,
                isNew: false,
                onClose: { showEditProfile = false },
                onSave: { showEditProfile = false },
                onDelete: {
                    // Route through the same real-delete confirm as the
                    // header menu (HP-2) instead of the old visual stub.
                    showEditProfile = false
                    showDeleteConfirm = true
                }
            )
        }
        .overlay {
            // Profile FAB sheet. Replaces the generic `AddBottomSheet`:
            //   • "Add Rule" was removed — rules have no backend (HP-3/HP-4).
            //   • "Enroll Device" was removed — it only appended a cosmetic
            //     local row; devices enroll via onboarding pairing (HP-6).
            //   • "Add to Calendar" now persists via POST /calendar/events
            //     instead of writing to dead mock state (HP-7/CAL-1).
            EvlinSheetCardItem(item: $addMode) { mode in
                Group {
                    switch mode {
                    case .menu:
                        ProfileAddMenu(
                            child: displayChild,
                            mode: $addMode,
                            onAddDevice: {
                                addMode = nil
                                addedDeviceKidName = displayChild.name
                                showAddDevicePairing = true
                            }
                        )
                    case .task:
                        AddTaskForm(
                            child: child,
                            onSave: { newTask in
                                handleCreateTask(newTask)
                                addMode = nil
                            },
                            onCancel: { addMode = nil }
                        )
                    case .calendar:
                        AddCalendarForm(
                            child: child,
                            onSave: { event in
                                handleCreateCalendar(event)
                                addMode = nil
                            },
                            onCancel: { addMode = nil }
                        )
                    case .rule:
                        // Restored entry. Rules have no backend yet — show an
                        // honest "coming soon" instead of the old local-only
                        // form that silently dropped the rule (HP-3/HP-4).
                        ProfileComingSoonSheet(
                            icon: "shield",
                            title: "Rules are coming soon",
                            message: "Screen-time and routine rules aren't ready yet. For now, use Add Task, the chat, or Lock devices to manage \(displayChild.name)'s phone.",
                            onClose: { addMode = nil }
                        )
                    case .device:
                        EmptyView()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showAddDevicePairing) {
            AddDevicePairingFlow(
                kidName: addedDeviceKidName.isEmpty ? displayChild.name : addedDeviceKidName,
                onPair: { code in await pairAdditionalDevice(code) },
                onDone: {
                    showAddDevicePairing = false
                },
                onCancel: {
                    showAddDevicePairing = false
                }
            )
        }
        .onAppear {
            // Enrolled Devices: live FamilyStore data is authoritative. The
            // mock fixtures render ONLY when the child isn't in the store at
            // all (pure #Preview). A live child with zero devices shows an
            // honest empty state instead of fake iPhone/iPad rows (HP-5).
            if let liveChild = familyStore.child(byId: child.id) {
                devices = liveChild.devices.map(DeviceItem.init(dto:))
            } else {
                devices = ProfileMockData.devices(for: child.id)
            }
            // Initialise local mutables from the source profile. `child.status`
            // already carries the live lock state when navigated from Home
            // (FamilyStore overlays it); refreshLockState then reconciles against
            // the device's REAL truth, so a stale snapshot can't leave the
            // button green after the kid is actually locked.
            localStatus = child.status
            Task { await refreshLockState() }
            if localName.isEmpty { localName = child.name }
            if localAge == 0    { localAge = child.age }
            if localSubtitle.isEmpty { localSubtitle = child.subtitle }
            if localAvatarURL == nil { localAvatarURL = child.avatarURL }

            // Per-child daily screen time limit — loaded from UserDefaults,
            // default 120 min (2h). Seeds the rules detail + summary "left today".
            let storedLimit = UserDefaults.standard.integer(forKey: "evlin.dailyLimitMin.\(child.id)")
            dailyLimitMinutes = storedLimit > 0 ? storedLimit : 120
            rules = ProfileMockData.rules(for: child.id, dailyLimitMinutes: dailyLimitMinutes)

            // Tasks: backend when this child owns the paired device;
            // otherwise an honest "No tasks yet" empty state (no more
            // ProfileMockData seeding in the runtime path).
            if backendChildID != nil {
                tasks = []   // wait for first refresh; avoids flashing seed copy
                Task { await refreshFromBackend() }
                startPollingBackend()
            } else {
                tasks = []
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

    @MainActor
    private func pairAdditionalDevice(_ code: String) async -> String? {
        let trimmed = code.filter(\.isNumber)
        guard trimmed.count == 6 else { return "Enter the 6-digit code." }
        do {
            let r = try await apiClient.pairFamily(
                code: trimmed,
                deviceLabel: UIDevice.current.name
            )
            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.parent_device_id.uuidString, forKey: "evlin.parentDeviceID")
            UserDefaults.standard.set(r.child_device_id.uuidString, forKey: "evlin.childDeviceID")
            await familyStore.refresh()
            if let matched = familyStore.children
                .first(where: { child in
                    child.devices.contains { UUID(uuidString: $0.device_id) == r.child_device_id }
                }) {
                addedDeviceKidName = matched.display_name
            }
            return nil
        } catch let APIError.serverError(status) {
            switch status {
            case 404: return "That code wasn't found. Double-check the 6 digits."
            case 400: return "That code has expired or was already used. Ask your kid for a fresh one."
            case 409: return "This account is already in a different family."
            default:  return "Couldn't pair (error \(status)). Try again."
            }
        } catch {
            return "Network error. Check your connection and try again."
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

    /// Create-task handler. Backend-only — without a paired device there is
    /// nowhere to persist the task, so say so instead of appending a
    /// session-local row that would vanish and dead-end in Task Detail.
    private func handleCreateTask(_ newTask: TaskItem) {
        guard let cid = backendChildID, let client = bigKidParent else {
            addError = "Pair \(displayChild.name)'s device to create tasks."
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

    /// HP-2: Delete Profile — really delete via DELETE /family/children/{id},
    /// refresh the family aggregate, then pop. On failure (409 = child still
    /// has a linked device, mapped through `ChildCRUDMapper` like the
    /// HomeSettingsSheet flow) show the error and do NOT pop.
    @MainActor
    /// Lock/Unlock-all CTA: queues the all-apps shield (or unshield_all) for
    /// the PAIRED kid device — the same lock the reflection lockdown applies.
    /// Optimistic flip; reverted with an inline error if the queue fails.
    private func toggleDeviceLock() async {
        guard let cid = backendChildID,
              let famRaw = UserDefaults.standard.string(forKey: "evlin.familyID"),
              let famID = UUID(uuidString: famRaw) else {
            lockError = "Pair \(displayChild.name)'s device first."
            return
        }
        let wantLocked = localStatus == .unlocked
        lockBusy = true
        lockError = nil
        lockNote = nil
        withAnimation(.easeOut(duration: 0.18)) {
            localStatus = wantLocked ? .locked : .unlocked
        }
        do {
            if wantLocked {
                _ = try await apiClient.lockAllApps(familyID: famID, childDeviceID: cid)
            } else {
                _ = try await apiClient.unlockAllApps(familyID: famID, childDeviceID: cid)
            }
        } catch {
            withAnimation(.easeOut(duration: 0.18)) {
                localStatus = wantLocked ? .unlocked : .locked
            }
            lockError = "Couldn't \(wantLocked ? "lock" : "unlock") — try again."
            lockBusy = false
            return
        }
        lockBusy = false
        // The queue accepted it, but "queued" ≠ "applied". Poll the kid device's
        // REAL state until it actually applies + acks (or time out), so the
        // parent gets a truthful receipt instead of a silent optimistic flip.
        let applied = await waitForLockState(wantLocked, cid: cid, famID: famID)
        lockNote = applied ? nil : (wantLocked
            ? "Queued — \(displayChild.name)'s phone will lock when it next checks in."
            : "Queued — \(displayChild.name)'s phone will unlock when it next checks in.")
        // Push the now-real state out to Home (FamilyStore.refresh re-reads
        // lock-state and re-renders the child card).
        await familyStore.refresh()
    }

    /// Set `localStatus` from the device's REAL all-apps lock state (instead of
    /// the always-`.unlocked` `child.status` default), so re-entering the screen
    /// shows the actual lock — not a stale green button.
    @MainActor
    private func refreshLockState() async {
        guard let cid = backendChildID,
              let famRaw = UserDefaults.standard.string(forKey: "evlin.familyID"),
              let famID = UUID(uuidString: famRaw),
              let state = try? await apiClient.fetchDeviceLockState(familyID: famID, childDeviceID: cid)
        else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            localStatus = state.locked ? .locked : .unlocked
        }
    }

    /// Poll `lock-state` until it matches `want` (the kid applied + acked) or a
    /// ~15s budget elapses. The kid's pollers run on a ~10s cadence, so this
    /// usually confirms within one or two ticks.
    private func waitForLockState(_ want: Bool, cid: UUID, famID: UUID) async -> Bool {
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let state = try? await apiClient.fetchDeviceLockState(familyID: famID, childDeviceID: cid),
               state.locked == want {
                return true
            }
        }
        return false
    }

    private func performDelete() async {
        do {
            try await apiClient.deleteChild(id: child.id)
            await familyStore.refresh()
            onBack()
        } catch {
            deleteError = ChildCRUDMapper.deleteErrorMessage(for: error)
        }
    }

    /// HP-7/CAL-1: "Add to Calendar" — persist a real event via
    /// POST /calendar/events (today's date + the form's wall-clock times in
    /// the device timezone; participant = this child profile). Replaces the
    /// old write into dead `CalendarMockData.runtimeEventsByOffset` state.
    private func handleCreateCalendar(_ event: CalendarEvent) {
        let tzID = TimeZone.current.identifier
        let today = Date()
        guard
            let startISO = CalendarTimeWire.utcISO(wallClock: event.start, onDay: today, timezoneID: tzID),
            let endISO = CalendarTimeWire.utcISO(wallClock: event.end, onDay: today, timezoneID: tzID)
        else {
            addError = "Couldn't read the event times. Use a format like 04:00 PM."
            return
        }
        // Child-profile participant when the id is a real backend UUID;
        // family-wide otherwise (preview fixtures like "liam").
        let participants: [CalendarEventParticipantDTO]
        if let uuid = UUID(uuidString: child.id) {
            participants = [CalendarEventParticipantDTO(participant_kind: "child", child_profile_id: uuid)]
        } else {
            participants = [CalendarEventParticipantDTO(participant_kind: "family", child_profile_id: nil)]
        }
        let body = CalendarEventCreateBody(
            title: event.title,
            emoji: event.emoji,
            category: event.category,
            location: event.location.isEmpty ? nil : event.location,
            note: event.note.isEmpty ? nil : event.note,
            all_day: false,
            start_at: startISO,
            end_at: endISO,
            timezone: tzID,
            recurrence_type: event.recurrence,
            recurrence_until: nil,
            participants: participants
        )
        Task {
            do {
                _ = try await apiClient.createCalendarEvent(body)
            } catch {
                await MainActor.run {
                    addError = "Couldn't add to calendar. \(error.localizedDescription)"
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

    /// Honest empty-state row used by the Current Tasks section (HP-9 /
    /// item 9): shown instead of the retired ProfileMockData fixtures.
    private func sectionEmptyState(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(text)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
        )
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
                if devices.isEmpty {
                    // HP-5: an empty LIVE device list is honest — no more
                    // fake iPhone/iPad/MacBook fixture rows at runtime.
                    Text("No devices enrolled yet — pair a device from onboarding.")
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                } else {
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
                        tone: .success,
                        size: .xs
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
                                onEdit: {
                                    if rule.id == "screen" {
                                        showDSTEditor = true
                                    }
                                    // Downtime/Bedtime: pencil is no-op for now
                                    // (no backend editor yet — only DST has a UI).
                                })
                            .padding(.horizontal, 14)
                            .overlay(
                                Rectangle()
                                    .fill(Color.evOutlineVariant.opacity(0.4))
                                    .frame(height: 1),
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
        .sheet(isPresented: $showDSTEditor) {
            DailyScreenTimeEditor(currentMinutes: dailyLimitMinutes) { newMinutes in
                dailyLimitMinutes = newMinutes
                UserDefaults.standard.set(newMinutes, forKey: "evlin.dailyLimitMin.\(child.id)")
                if let i = rules.firstIndex(where: { $0.id == "screen" }) {
                    rules[i].detail = "\(formatLimit(newMinutes)) limit per day"
                }
            }
        }
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
                                .frame(width: max(6, geo.size.width * 1.0), height: 5)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 4) {
                        Text(formatLimit(dailyLimitMinutes))
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evSecondary)
                        Text("left today")
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }

            // HP-1: the old Lock/Unlock CTA only flipped local @State — it
            // Locks EVERY registered device — for iOS that's the all-apps
            // shield, the same mechanism the reflection lockdown applies
            // (POST /parent/device/lock-all → kid CommandPoller → shield
            // tier=all; unlock queues unshield_all). Optimistic flip,
            // reverted with an inline error if the queue call fails.
            VStack(spacing: 6) {
                Button { Task { await toggleDeviceLock() } } label: {
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
                }
                .buttonStyle(.plain)
                .disabled(lockBusy || backendChildID == nil)
                .opacity(backendChildID == nil ? 0.45 : (lockBusy ? 0.7 : 1))

                // Caption only when something needs saying: a failure (red), a
                // neutral "queued" receipt, or why the button is disabled.
                if let lockError {
                    Text(lockError)
                        .font(.custom("Inter", size: 11).weight(.medium))
                        .foregroundStyle(Color.evError)
                        .frame(maxWidth: .infinity)
                } else if let lockNote {
                    Text(lockNote)
                        .font(.custom("Inter", size: 11).weight(.medium))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else if backendChildID == nil {
                    Text("Pair \(displayChild.name)'s device to lock")
                        .font(.custom("Inter", size: 11).weight(.medium))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            }
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

// MARK: - Paired-child resolution (shared by ProfileView + TaskDetailView)

extension FamilyStore {
    /// True when `childId` is the kid this parent app actually paired with —
    /// i.e. the stored kid DEVICE id (`@AppStorage "evlin.childDeviceID"`,
    /// minted during 6-digit pairing) belongs to this child per the live
    /// family aggregate. Replaces the old hardcoded `child.id == "liam"`
    /// gates so real UUID children get the real backend task path.
    ///
    /// Fallback: some aggregates carry empty `devices` arrays. When NO child
    /// has device data and the family has exactly one child, that child
    /// unambiguously owns the paired device.
    func ownsPairedDevice(childId: String, pairedDeviceID: String) -> Bool {
        guard !pairedDeviceID.isEmpty,
              let paired = UUID(uuidString: pairedDeviceID),
              let target = child(byId: childId) else { return false }
        if target.devices.contains(where: { UUID(uuidString: $0.device_id) == paired }) {
            return true
        }
        let noDeviceData = children.allSatisfy { $0.devices.isEmpty }
        return noDeviceData && children.count == 1
    }
}

// MARK: - Profile FAB menu

/// Profile FAB launcher. Mirrors the visual style of `AddMenu`
/// (AddBottomSheet.swift) but only offers entries that actually persist:
///   • Add Task        → BigKid backend (POST /parent/task)
///   • Add to Calendar → POST /calendar/events
/// "Add Rule" (no rules backend — HP-3/HP-4) and "Enroll Device" (cosmetic
/// local row; devices enroll via onboarding pairing — HP-6) were removed.
/// Honest placeholder shown for menu entries whose backend isn't built yet
/// (Add Rule, Add Device) — restores the option without faking a save.
private struct ProfileComingSoonSheet: View {
    let icon: String
    let title: String
    let message: String
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 64, height: 64)

            Text(title)
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onClose) {
                Text("Got it")
                    .font(.custom("Manrope", size: 15).weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.evPrimary))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
    }
}

private struct AddDevicePairingFlow: View {
    let kidName: String
    let onPair: (String) async -> String?
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var paired = false

    var body: some View {
        NavigationStack {
            Group {
                if paired {
                    AddDeviceSuccessStep(kidName: kidName, onDone: onDone)
                } else {
                    ParentPairScanStep(
                        onPaired: onPair,
                        pairedSucceeded: false,
                        onAdvance: { paired = true },
                        onBack: onCancel
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(paired ? "Done" : "Cancel") {
                        if paired {
                            onDone()
                        } else {
                            onCancel()
                        }
                    }
                }
            }
        }
    }
}

private struct AddDeviceSuccessStep: View {
    let kidName: String
    let onDone: () -> Void

    private var name: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "Device added",
            stepIndex: 1,
            stepTotal: 1,
            title: "Device added",
            subtitle: nil,
            dotsCount: 1,
            dotsCurrent: 0,
            content: {
                VStack(spacing: Spacing.xl) {
                    OnboardingV2SuccessCheck(role: .parent, size: 62)
                    Text("Connected to \(name)").onboardingV2TitleL()
                    Text("This device is now linked. You can return to \(name)'s profile.")
                        .onboardingV2Body()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                OnboardingV2PrimaryButton("Done", role: .parent) {
                    onDone()
                }
            }
        )
    }
}

private struct ProfileAddMenu: View {
    let child: ChildProfile
    @Binding var mode: AddBottomMode?
    var onAddDevice: () -> Void = {}

    private struct Option {
        let id: AddBottomMode
        let icon: String
        let label: String
        let sub: String
    }

    private var options: [Option] {
        [
            .init(id: .task, icon: "checkmark.circle", label: "Add Task",
                  sub: "New chore or homework for \(child.name)"),
            .init(id: .rule, icon: "shield", label: "Add Rule",
                  sub: "New screen-time or routine rule"),
            .init(id: .device, icon: "iphone", label: "Add Device",
                  sub: "Pair another phone or tablet"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add new")
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .tracking(-0.18)
                .foregroundStyle(Color.evPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { idx, o in
                    Button {
                        if o.id == .device {
                            onAddDevice()
                        } else {
                            mode = o.id
                        }
                    } label: {
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.evSurfaceContainerLow)
                                Image(systemName: o.icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(Color.evPrimary)
                            }
                            .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.label)
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .foregroundStyle(Color.evOnSurface)
                                Text(o.sub)
                                    .font(.custom("Inter", size: 12))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOutline)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if idx < options.count - 1 {
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .padding(.leading, 80)
                    }
                }
            }
            .padding(.bottom, 12)
        }
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
