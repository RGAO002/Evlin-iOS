import SwiftUI

enum ProfilePresentation {
    static let kidSpaceEditProfileLabel = "Edit Profile"
    static let kidSpaceDeleteProfileLabel = "Delete Profile"
    static let kidSpaceOverflowMenuLabels = [
        kidSpaceEditProfileLabel,
        kidSpaceDeleteProfileLabel,
    ]
}

// MARK: - B9: Pool cascade state (defined outside ProfileView so @State can use it)

/// Carries the pending cascade confirmation context for a pool reduction.
/// Used as `@State private var pendingPoolCascade: PoolCascadeState?` in ProfileView.
struct PoolCascadeState: Identifiable {
    let id = UUID()
    let decision: EarnedCascadeDecision.Result
    let newMinutes: Int
}

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
    /// When non-nil the pool editor persists via the backend (B9).
    /// Nil = no UUID child id → fall back to UserDefaults (legacy path).
    @State private var childProfileUUID: UUID? = nil
    /// Saving indicator shown while putEarnedConfig is in-flight.
    @State private var poolSaving = false
    /// Pending pool reduction that needs cascade confirmation. Non-nil shows the
    /// cascade-confirm sheet; the confirmed save proceeds with the stored value.
    @State private var pendingPoolCascade: PoolCascadeState? = nil
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
    @State private var earnedSummaryPollTask: Task<Void, Never>? = nil
    private var backendChildID: UUID? {
        familyStore.childDeviceID(forChildId: child.id, preferredDeviceID: pairedChildID)
    }
    private var bigKidParent: BigKidParentClient? {
        guard backendChildID != nil else { return nil }
        return BigKidParentClient(baseURLString: apiClient.baseURL)
    }

    // Local mutable status so the Lock/Unlock button can flip the avatar
    // and pills without requiring a global mutation. See HTML 1029-1034.
    @State private var localStatus: ChildProfile.Status = .unlocked
    // B8: acked lock-button state derived from covering_sources/exhausted
    // (NOT optimistic). Drives red/green coloring of the green button.
    @State private var ackedLockButtonState: LockButtonState = .pending
    // B10: whether the last fetched lock-state had exhausted==true (earned-time ran out).
    // Used in toggleDeviceLock to route the unlock via unlockOverride (not unlockSelected).
    @State private var lastFetchedExhausted: Bool = false
    // B11: earned-time summary from A3 backend endpoint.
    // Nil until the first fetch completes; progress bar / countdown uses static
    // config values until then (graceful degradation).
    @State private var earnedSummary: APIClient.EarnedSummaryDTO? = nil
    @State private var summaryFetchedAt: Date? = nil
    // Lock-selected CTA wiring (POST /parent/device/lock-selected|unlock-selected).
    @State private var lockBusy = false
    @State private var lockError: String? = nil
    // Neutral (non-error) status note, e.g. "queued — will apply when the
    // phone next checks in". Shown in muted text, distinct from lockError.
    @State private var lockNote: String? = nil
    // B6 carry: once the backend list_id is first learned, remember it so
    // we only call saveLockedSetID + reKeyShieldRecord once per session.
    @State private var knownBackendListID: String? = nil
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

    /// True when the Daily Screen Time rule is toggled ON.
    private var dailyLimitOn: Bool {
        rules.first(where: { $0.id == "screen" })?.on ?? true
    }

    /// The "screen time remaining" text used in both the summary card and the
    /// Enrolled Devices row.
    ///
    /// B11 priority chain:
    ///   1. Backend `countdown_label` when present (server pre-formats copy).
    ///   2. Compute a countdown label from `remaining_minutes` via EarnedDisplayFormatters.
    ///   3. Fall back to static config (daily limit / "∞") when no summary yet.
    private var screenTimeRemainingText: String {
        guard dailyLimitOn else { return "∞" }
        if let label = earnedSummary?.countdown_label, !label.isEmpty {
            return label
        }
        if let remaining = earnedSummary?.remaining_minutes {
            return EarnedDisplayFormatters.coarseCountdownLabel(remainingMinutes: remaining)
        }
        // Pre-fetch fallback shows the static limit; keep the "left" suffix so
        // the copy reads the same before and after the first summary arrives.
        return "\(formatLimit(dailyLimitMinutes)) left"
    }

    /// Freshness string shown below the countdown ("updated ~Xm ago").
    /// Returns nil when no summary has been fetched yet (nothing to show).
    private var summaryFreshnessText: String? {
        guard let fetchedAt = summaryFetchedAt else { return nil }
        let ago = Int(Date().timeIntervalSince(fetchedAt))
        return EarnedDisplayFormatters.freshnessLabel(secondsAgo: ago)
    }

    /// Progress-bar fraction: remaining_minutes / daily_pool_minutes.
    /// Falls back to 1.0 (full bar) before first fetch so the bar doesn't flash empty.
    private var summaryProgressFraction: Double {
        EarnedDisplayFormatters.remainingFraction(
            remainingMinutes: earnedSummary?.remaining_minutes,
            dailyPoolMinutes: earnedSummary?.daily_pool_minutes
        )
    }

    /// Per-device estimate for a given device id.
    /// `estimated_minutes` is reported usage, not time left; prefer
    /// `remaining_to_cap_minutes`, or compute cap - used when both values exist.
    private func deviceEstimate(for deviceID: UUID?) -> APIClient.EarnedDeviceEstimateDTO? {
        guard let deviceID, let estimates = earnedSummary?.device_estimates else { return nil }
        return estimates.first(where: { $0.child_device_id == deviceID })
    }

    private func deviceRemainingToCapMinutes(for deviceID: UUID?) -> Int? {
        guard let estimate = deviceEstimate(for: deviceID) else { return nil }
        if let remaining = estimate.remaining_to_cap_minutes {
            return remaining
        }
        if let cap = estimate.cap_minutes,
           let used = estimate.estimated_minutes {
            return max(0, cap - used)
        }
        return nil
    }

    private func deviceRemainingText(for deviceID: UUID?) -> String {
        EarnedDisplayFormatters.deviceRemainingLabel(
            remainingToCapMinutes: deviceRemainingToCapMinutes(for: deviceID),
            overallRemainingMinutes: earnedSummary?.remaining_minutes,
            fallbackOverallLabel: screenTimeRemainingText
        )
    }

    private func deviceRemainingFraction(for deviceID: UUID?) -> Double {
        let estimate = deviceEstimate(for: deviceID)
        return EarnedDisplayFormatters.deviceRemainingFraction(
            remainingToCapMinutes: deviceRemainingToCapMinutes(for: deviceID),
            capMinutes: estimate?.cap_minutes,
            overallRemainingMinutes: earnedSummary?.remaining_minutes,
            dailyPoolMinutes: earnedSummary?.daily_pool_minutes
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
                        Label(ProfilePresentation.kidSpaceEditProfileLabel, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(ProfilePresentation.kidSpaceDeleteProfileLabel, systemImage: "trash")
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

            // B9: pool-cascade sheet host — zero-size ZStack sibling so the
            // sheet modifier doesn't inflate the main VStack modifier chain.
            PoolCascadeSheetHost(pending: $pendingPoolCascade) { confirmPoolSave($0) }
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
        .overlay { fabOverlay }
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

            // Per-child daily screen time limit.
            // B9: prefer the backend pool value (fetchEarnedSummary) when the
            // child has a UUID id; fall back to UserDefaults for legacy / offline.
            let childUUID = UUID(uuidString: child.id)
            childProfileUUID = childUUID
            if let uuid = childUUID {
                if let cachedSummary = familyStore.earnedSummary(forChildID: child.id) {
                    earnedSummary = cachedSummary
                }
                Task {
                    // B9: load pool from the backend policy.
                    // fetchEarnedPolicy().pool_minutes is the daily earned-time pool.
                    // This Task runs async; it overwrites dailyLimitMinutes ONLY when
                    // the backend actually returns a value (takes precedence over the
                    // UserDefaults seed loaded below).
                    if let policy = try? await apiClient.fetchEarnedPolicy(childProfileID: uuid),
                       let pool = policy.pool_minutes,
                       pool > 0 {
                        dailyLimitMinutes = pool
                        rules = ProfileMockData.rules(for: child.id, dailyLimitMinutes: pool)
                    }
                }
                Task { await refreshEarnedSummary() }
                startEarnedSummaryPolling()
                // For UUID children the backend pool is authoritative, but we must
                // ALWAYS render the Active Rules immediately. Seed them synchronously
                // from UserDefaults/default; the async policy Task refreshes the pool
                // detail when (and only when) the backend responds. REGRESSION FIX:
                // previously `rules` was set ONLY inside the async policy Task, so when
                // the backend was unreachable the 3 Active Rules vanished entirely.
                let storedLimit = UserDefaults.standard.integer(forKey: "evlin.dailyLimitMin.\(child.id)")
                dailyLimitMinutes = storedLimit > 0 ? storedLimit : 120
                rules = ProfileMockData.rules(for: child.id, dailyLimitMinutes: dailyLimitMinutes)
            } else {
                // Legacy / offline path: no backend UUID, use UserDefaults directly.
                let storedLimit = UserDefaults.standard.integer(forKey: "evlin.dailyLimitMin.\(child.id)")
                dailyLimitMinutes = storedLimit > 0 ? storedLimit : 120
                rules = ProfileMockData.rules(for: child.id, dailyLimitMinutes: dailyLimitMinutes)
            }

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
            earnedSummaryPollTask?.cancel()
            earnedSummaryPollTask = nil
        }
    }

    @MainActor
    private func refreshEarnedSummary() async {
        // B11: load the earned-time summary (countdown_label, used_minutes,
        // daily_pool_minutes, device_estimates). Failure is non-fatal — the UI
        // keeps the shared cached summary or degrades to the static config copy.
        if let summary = await familyStore.refreshEarnedSummary(forChildID: child.id) {
            earnedSummary = summary
            summaryFetchedAt = Date()
        }
    }

    private func startEarnedSummaryPolling() {
        earnedSummaryPollTask?.cancel()
        earnedSummaryPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await refreshEarnedSummary()
            }
        }
    }

    @MainActor
    private func pairAdditionalDevice(_ code: String) async -> String? {
        let trimmed = code.filter(\.isNumber)
        guard trimmed.count == 6 else { return "Enter the 6-digit code." }
        do {
            let r = try await apiClient.pairFamily(
                code: trimmed,
                deviceLabel: UIDevice.current.name,
                targetChildProfileID: child.id
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
    /// B8: Selected-set lock CTA. Locks/unlocks the CONFIGURED LOCKED SET (not
    /// all apps). Red/green is driven by the ACKED `covering_sources` field from
    /// the backend response — never optimistic.
    ///
    /// Keeps the "locking…/pending" queued-copy pattern: queue the command, then
    /// poll until the kid acks or we time out, then show the real result.
    @MainActor
    private func toggleDeviceLock() async {
        guard let cid = backendChildID,
              let pid = UUID(uuidString: child.id),
              let famRaw = UserDefaults.standard.string(forKey: "evlin.familyID"),
              let famID = UUID(uuidString: famRaw) else {
            lockError = "Pair \(displayChild.name)'s device first."
            return
        }
        let wantLocked = !ackedLockButtonState.isShielded
        // B10: detect exhausted-unlock path — when the parent unlocks an exhausted day,
        // we must call unlockOverride (not unlockSelected) AND write the local App Group
        // flag so the Monitor extension suppresses immediately, offline, without waiting
        // for the backend command to round-trip to the kid's device.
        let isExhaustedUnlock = !wantLocked && lastFetchedExhausted
        lockBusy = true
        lockError = nil
        lockNote = nil
        if isExhaustedUnlock {
            // B10: exhausted-day override — write the local App Group flag first so the
            // Monitor extension suppresses the earned-time shield immediately, offline,
            // without waiting for the backend command to reach the kid's device.
            // Then call unlockOverride (A8/B8 backend endpoint) to persist server-side.
            let overrideUsageDate = todayUsageDate()
            EarnedTimeStore.shared.setOverride(true, forUsageDate: overrideUsageDate)
            do {
                // child.id is a UUID string (backend child profile ID). Send the
                // SAME usage_date we wrote to the App Group so server + device agree.
                if let childProfileUUID = UUID(uuidString: child.id) {
                    _ = try await apiClient.unlockOverride(
                        childProfileID: childProfileUUID, usageDate: overrideUsageDate)
                }
            } catch {
                lockError = "Couldn't unlock — try again."
                lockBusy = false
                return
            }
            lockBusy = false
            await refreshLockState()
            lockNote = nil
            await familyStore.refresh()
            return
        }
        do {
            let resp: APIClient.LockSelectedResponse
            if wantLocked {
                resp = try await apiClient.lockSelected(familyID: famID, childProfileID: pid, childDeviceID: cid)
            } else {
                resp = try await apiClient.unlockSelected(familyID: famID, childProfileID: pid, childDeviceID: cid)
            }
            // Apply B6 carry from command response if it surfaced a list_id.
            applyListIDIfNeeded(resp.list_id.uuidString)
        } catch {
            // Detect "no Locked set configured" specifically (backend returns a 4xx
            // with a code in 400-422 when the selected set is missing or empty —
            // e.g. `selected_set_missing_or_empty`). Show a friendly, actionable
            // message that guides the parent to the app-controls / lock-list UI
            // (which uploads the Locked set via POST /child/catalog-list).
            // All other failures (404 route not found, 500, network) get the raw
            // error so they remain diagnosable.
            if ProfileView.isNoLockedSetError(error) {
                lockError = "Select which apps to lock first — tap \"App Controls\" (the lock list) to set up the Locked set, then try again."
            } else {
                lockError = "Couldn't \(wantLocked ? "lock" : "unlock"): \(String(describing: error))"
            }
            lockBusy = false
            return
        }
        lockBusy = false
        // Queue accepted → poll until the kid acks the REAL state change.
        let applied = await waitForLockStateAcked(wantLocked: wantLocked, cid: cid, famID: famID)
        lockNote = applied ? nil : (wantLocked
            ? "Queued — \(displayChild.name)'s phone will lock when it next checks in."
            : "Queued — \(displayChild.name)'s phone will unlock when it next checks in.")
        // Push the now-real state to Home.
        await familyStore.refresh()
    }

    /// Refresh `ackedLockButtonState` from the device's REAL lock-state ack.
    /// Derives from `covering_sources` (not `locked` bool). `exhausted`
    /// is tracked separately for override routing only.
    /// Also applies the B6 carry: persists list_id once when first learned.
    @MainActor
    private func refreshLockState() async {
        guard let cid = backendChildID,
              let famRaw = UserDefaults.standard.string(forKey: "evlin.familyID"),
              let famID = UUID(uuidString: famRaw),
              let state = try? await apiClient.fetchDeviceLockState(familyID: famID, childDeviceID: cid)
        else { return }
        // B6 carry: persist list_id and re-key any local-id record.
        applyListIDIfNeeded(state.list_id)
        let buttonState = LockButtonState.from(
            coveringSources: state.covering_sources,
            exhausted: state.exhausted)
        withAnimation(.easeOut(duration: 0.18)) {
            ackedLockButtonState = buttonState
            localStatus = buttonState.isShielded ? .locked : .unlocked
            // B10: track exhausted separately so toggleDeviceLock can route correctly.
            lastFetchedExhausted = state.exhausted == true
        }
    }

    /// Poll `lock-state` until the acked button state matches `wantLocked`
    /// (covering_sources non-empty ↔ locked) or ~15s elapses.
    private func waitForLockStateAcked(wantLocked: Bool, cid: UUID, famID: UUID) async -> Bool {
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let state = try? await apiClient.fetchDeviceLockState(familyID: famID, childDeviceID: cid) else {
                continue
            }
            applyListIDIfNeeded(state.list_id)
            let buttonState = LockButtonState.from(
                coveringSources: state.covering_sources,
                exhausted: state.exhausted)
            let isExhausted = state.exhausted == true
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    ackedLockButtonState = buttonState
                    localStatus = buttonState.isShielded ? .locked : .unlocked
                    // B10: track exhausted separately so toggleDeviceLock can route correctly.
                    lastFetchedExhausted = isExhausted
                }
            }
            if buttonState.isShielded == wantLocked { return true }
        }
        return false
    }

    /// B6 carry: when a lock-state or policy fetch surfaces the backend
    /// `list_id`, persist it via EarnedTimeStore once and kick the
    /// ActiveLockStore re-key migration so any local-id shield record unifies.
    /// Idempotent — only runs on first learn (knownBackendListID guard).
    @MainActor
    private func applyListIDIfNeeded(_ newID: String?) {
        guard let id = newID, !id.isEmpty, id != knownBackendListID else { return }
        let previousID = knownBackendListID ?? ""
        knownBackendListID = id
        EarnedTimeStore.shared.saveLockedSetID(id, tokenData: nil)
        // Re-key any shield record that was stored under the local/provisional id.
        Task {
            await ActiveLockStore.shared.reKeyShieldRecord(
                fromLocalID: previousID,
                toBackendID: id)
        }
    }

    /// Returns true when `error` indicates the backend has no "Locked set"
    /// configured for this child (a 4xx response in the 400–422 range from
    /// the lock-selected endpoint). 400-range means "client error / bad request"
    /// — the most likely root cause at runtime is `selected_set_missing_or_empty`.
    /// 404 (route-not-found) and 5xx are NOT in this bucket; they fall through
    /// to the generic raw-error display so they remain diagnosable.
    ///
    /// Exposed as `internal` (not private) so the unit test can call it directly
    /// without going through the full async `toggleDeviceLock()` path.
    static func isNoLockedSetError(_ error: Error) -> Bool {
        if case .serverError(let code) = error as? APIError {
            // 400: selected_set_missing_or_empty or similar validation failure.
            // 409: Conflict — empty-set or set-not-found conflict from backend.
            // 422: Unprocessable entity — malformed/empty set.
            // Exclude 404 (route not yet deployed — diagnosable infra gap, not a
            // missing locked-set) and 5xx (server/infra failures) so those errors
            // still surface their raw code for triage.
            switch code {
            case 400, 409, 422: return true
            default:            return false
            }
        }
        return false
    }

    /// B10: ISO-8601 date string for today in the device's local timezone.
    /// Matches the `usage_date` key format that `EarnedTimeStore` and the
    /// Monitor extension both use for the override flag.
    private func todayUsageDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date())
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
                            // B11: per-device estimates are clamped by the overall pool,
                            // so stale device data cannot look fuller than the summary.
                            let deviceTimeLeft = deviceRemainingText(for: d.deviceUUID)
                            DeviceRow(
                                iconSystemName: d.iconSystemName,
                                name: d.name,
                                detail: d.detail,
                                locked: localStatus != .unlocked,
                                timeLeft: deviceTimeLeft,
                                timePct: deviceRemainingFraction(for: d.deviceUUID),
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
                savePool(newMinutes: newMinutes, confirmedCascade: false)
            }
        }
    }

    // MARK: - FAB overlay (extracted to reduce body type-checker complexity)

    /// Profile FAB sheet. Replaces the generic `AddBottomSheet`:
    ///   • "Add Rule" was removed — rules have no backend (HP-3/HP-4).
    ///   • "Enroll Device" was removed — it only appended a cosmetic local row;
    ///     devices enroll via onboarding pairing (HP-6).
    ///   • "Add to Calendar" now persists via POST /calendar/events
    ///     instead of writing to dead mock state (HP-7/CAL-1).
    private var fabOverlay: some View {
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

    private var summaryCard: some View {
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
                    // B11: progress bar fraction = remaining / pool from earned summary.
                    // Falls back to 1.0 (full bar) until first backend fetch.
                    GeometryReader { geo in
                        let fillWidth = summaryProgressFraction <= 0
                            ? 0
                            : max(6, geo.size.width * summaryProgressFraction)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evTimeRemaining(summaryProgressFraction))
                                .frame(width: fillWidth, height: 5)
                        }
                    }
                    .frame(height: 5)
                    // B11: countdown label with freshness.
                    VStack(alignment: .leading, spacing: 2) {
                        // Daily Screen Time toggle ON → earned-time label;
                        // OFF → unlimited, shown as the infinity symbol.
                        // Label color tracks the bar's remaining-time tier
                        // (green/yellow/red) so text and bar never disagree.
                        Text(screenTimeRemainingText)
                            .font(.custom("Inter", size: 11).weight(.heavy))
                            .foregroundStyle(Color.evTimeRemaining(summaryProgressFraction))
                        // Freshness: shown only when we have a timestamp.
                        if let freshness = summaryFreshnessText {
                            Text(freshness)
                                .font(.custom("Inter", size: 10))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }
                }
            }

            // B8: Selected-set lock CTA.
            // Red/green derives from ACKED state (ackedLockButtonState), NOT
            // optimistic local flip. Green = selected set is clear (sources=[]).
            // Red = covering_sources non-empty.
            // Pending (sources=nil) = neutral/disabled until first ack.
            VStack(spacing: 6) {
                Button { Task { await toggleDeviceLock() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ackedLockButtonState.isShielded ? "lock.open" : "lock")
                            .font(.system(size: 18, weight: .semibold))
                        Text(ackedLockButtonState.isShielded
                             ? "Unlock \(displayChild.name)'s devices"
                             : "Lock \(displayChild.name)'s devices")
                            .font(.custom("Manrope", size: 14).weight(.heavy))
                            .tracking(0.2)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(ackedLockButtonState.isShielded
                                  ? AnyShapeStyle(Color.evError)
                                  : AnyShapeStyle(Color.evSecondaryGradient))
                    )
                }
                .buttonStyle(.plain)
                .disabled(lockBusy || backendChildID == nil || ackedLockButtonState.isPending)
                .opacity(backendChildID == nil ? 0.45 : (lockBusy || ackedLockButtonState.isPending ? 0.7 : 1))

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

    // MARK: - B9: Pool save with cascade gate

    /// Called by PoolCascadeSheetHost when the user taps "Apply Tomorrow".
    /// Clears the pending state and proceeds with the confirmed save.
    private func confirmPoolSave(_ newMinutes: Int) {
        pendingPoolCascade = nil
        savePool(newMinutes: newMinutes, confirmedCascade: true)
    }

    /// Save the daily pool (earned-time budget) via putEarnedConfig.
    /// When the new value is lower than the current pool AND confirmation has not
    /// yet been given, gate behind the cascade-confirm sheet (R10/R11/R12).
    ///
    /// - Parameters:
    ///   - newMinutes:       The requested new pool value in minutes.
    ///   - confirmedCascade: Pass `true` when re-calling after the user confirms.
    private func savePool(newMinutes: Int, confirmedCascade: Bool) {
        // Gate: if lowering the pool without confirmation, show the confirm sheet.
        // ProfileView doesn't hold per-device cap data, so we construct a
        // "generic reduction" decision that always triggers confirmation.
        if !confirmedCascade && newMinutes < dailyLimitMinutes {
            let decision = EarnedCascadeDecision.Result(
                needsConfirmation: true,
                affectedDevices: [],
                affectedApps: [],
                defaultAction: .applyTomorrow)
            pendingPoolCascade = PoolCascadeState(decision: decision, newMinutes: newMinutes)
            return   // DO NOT call putEarnedConfig — wait for confirmation
        }

        // Optimistic local update.
        dailyLimitMinutes = newMinutes
        if let i = rules.firstIndex(where: { $0.id == "screen" }) {
            rules[i].detail = "\(formatLimit(newMinutes)) limit per day"
        }
        // B9: persist via backend when we have a UUID child id;
        // fall back to UserDefaults for legacy / offline path.
        if let uuid = childProfileUUID {
            poolSaving = true
            Task {
                defer { poolSaving = false }
                _ = try? await apiClient.putEarnedConfig(
                    childProfileID: uuid,
                    poolMinutes: newMinutes)
            }
        } else {
            UserDefaults.standard.set(newMinutes, forKey: "evlin.dailyLimitMin.\(child.id)")
        }
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

    /// Resolve the backend child-device UUID for a child profile. Prefer the
    /// locally stored paired id when it belongs to that child; otherwise fall
    /// back to the device listed in the live family aggregate.
    func childDeviceID(forChildId childId: String, preferredDeviceID: String) -> UUID? {
        if ownsPairedDevice(childId: childId, pairedDeviceID: preferredDeviceID),
           let id = UUID(uuidString: preferredDeviceID) {
            return id
        }
        if let dev = child(byId: childId)?.devices.first,
           let id = UUID(uuidString: dev.device_id) {
            return id
        }
        return nil
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

// MARK: - B9: Pool cascade confirm sheet

/// Presented when lowering the earned-time pool requires cascade confirmation.
/// Mirrors `CascadeConfirmSheet` in DeviceAppsSheet but lives at the profile level.
private struct PoolCascadeConfirmSheet: View {
    let result: EarnedCascadeDecision.Result
    var onApplyTomorrow: () -> Void = {}
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if result.affectedDevices.isEmpty && result.affectedApps.isEmpty {
                        Text("Lowering the daily pool may reduce device and app limits.")
                            .font(.custom("Inter", size: 14))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                    ForEach(result.affectedDevices, id: \.deviceID) { dev in
                        Text(dev.description)
                            .font(.custom("Inter", size: 14))
                    }
                    ForEach(result.affectedApps, id: \.bundleID) { app in
                        Text(app.description)
                            .font(.custom("Inter", size: 14))
                    }
                } header: {
                    Text("These limits will change")
                        .font(.custom("Inter", size: 12).weight(.semibold))
                }

                Section {
                    Text("The changes take effect at midnight so today's sessions aren't cut short.")
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .navigationTitle("Confirm Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .foregroundStyle(Color.evPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply Tomorrow") {
                        onApplyTomorrow()
                        dismiss()
                    }
                    .font(.custom("Inter", size: 17).weight(.semibold))
                    .foregroundStyle(Color.evPrimary)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - B9: Pool cascade sheet host
//
// A zero-size anchor view carrying the sheet modifier for pool-reduction
// confirmation. Placed as a ZStack child in ProfileView's body rather than
// as a modifier on the main VStack, so it doesn't inflate the body's type-
// checker expression beyond Swift's limit.

private struct PoolCascadeSheetHost: View {
    @Binding var pending: PoolCascadeState?
    /// Called with confirmed newMinutes when the parent taps "Apply Tomorrow".
    /// Also dismisses the sheet by setting pending = nil BEFORE calling back.
    var onSave: (Int) -> Void = { _ in }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .sheet(item: $pending) { state in
                PoolCascadeConfirmSheet(
                    result: state.decision,
                    onApplyTomorrow: { onSave(state.newMinutes) },
                    onCancel: { pending = nil }
                )
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
