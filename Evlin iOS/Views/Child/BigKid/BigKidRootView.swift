import SwiftUI

enum ReflectionNav: Hashable {
    case locked
    case video
    case quiz
    case writing
}

/// Top-level view for big-kid mode. Picks one of the eleven screens based on
/// the current `BigKidState` per spec §5.
struct BigKidRootView: View {
    @EnvironmentObject private var apiClient: APIClient
    @State private var state: BigKidState
    @StateObject private var client: BigKidAPIClient
    @StateObject private var poller: BigKidStatePoller
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("evlin.familyID") private var familyID: String = ""

    private let childDeviceID: UUID

    init(baseURL: URL, childId: UUID) {
        self.childDeviceID = childId
        let client = BigKidAPIClient(baseURL: baseURL, childId: childId)
        // Always start empty — `BigKidStatePoller` paints the real snapshot ASAP.
        // DEBUG `.fixture()` here caused a visible flicker (default tasks swapped for server tasks).
        let initialState = BigKidState(snapshot: ChildStateResponse(
            childName: "", minutesLeft: 0, minutesMax: 0,
            tasks: [], reflectionRequest: nil,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil
        ))
        let poller = BigKidStatePoller(client: client, state: initialState)
        _client = StateObject(wrappedValue: client)
        _state = State(initialValue: initialState)
        _poller = StateObject(wrappedValue: poller)

        // Mirror baseURL + childId into the App Group so the
        // EvlinDeviceActivityMonitor extension can hit /child/time-consumption
        // when DeviceActivityEvent thresholds fire (Phase 10).
        if let groupDefaults = UserDefaults(suiteName: "group.com.evlin.ios") {
            groupDefaults.set(baseURL.absoluteString, forKey: "evlin.baseURL")
            groupDefaults.set(childId.uuidString, forKey: "evlin.childId")
        }
    }

    @State private var taskNav: BigKidTask?
    @State private var bypassNav: BigKidTask?
    @State private var reflectionPath = NavigationPath()
    @State private var showLockListGate = false
    @State private var showLockListManager = false

    #if DEBUG
    @State private var debugScenario: BigKidDebugScenario = .live
    @State private var showCatalogDebug: Bool = false
    #endif

    var body: some View {
        Group {
            switch BigKidRouter.route(state) {
            case .home:
                BigKidHomeView(
                    onTaskTap: { task in taskNav = task },
                    onManageApps: { showLockListGate = true }
                )
            case .homeReflectionA:
                NavigationStack(path: $reflectionPath) {
                    BigKidHomeReflectionView(
                        subState: .a,
                        onStartReflection: {
                            // Rework path skips the locked step-picker
                            // and drops the kid straight onto Step 3
                            // (writing). Video + quiz are still in
                            // `stepsCompleted` from the original
                            // attempt, so the kid doesn't redo them.
                            let isRework = state.reflectionRequest?
                                .parentRedoNote?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty == false
                            reflectionPath.append(
                                isRework ? ReflectionNav.writing : ReflectionNav.locked
                            )
                        },
                        onTaskTap: { _ in },
                        onNudgeParent: { nudgeParent() },
                        onRefresh: { await poller.refreshNow() }
                    )
                    .navigationDestination(for: ReflectionNav.self) { dest in
                        destinationView(for: dest)
                    }
                }
            case .homeReflectionB:
                NavigationStack(path: $reflectionPath) {
                    BigKidHomeReflectionView(
                        subState: .b,
                        onStartReflection: {},
                        onTaskTap: { task in taskNav = task },
                        onNudgeParent: { nudgeParent() },
                        onRefresh: { await poller.refreshNow() }
                    )
                    .navigationDestination(for: ReflectionNav.self) { dest in
                        destinationView(for: dest)
                    }
                }
            case .complete:
                if let r = state.reflectionRequest {
                    BigKidCompleteView(request: r) {
                        _ = try? await client.reflectionAck(rid: r.id)
                        await poller.refreshNow()
                    }
                }
            case .dailyComplete:
                BigKidDailyCompleteView(onContinue: {
                    _ = try? await client.ackDailyComplete()
                    await poller.refreshNow()
                })
            case .screenTimeFinished:
                BigKidScreenTimeFinishedView(onAck: {
                    _ = try? await client.ackScreenTimeFinished()
                    await poller.refreshNow()
                })
            }
        }
        .environment(state)
        .environmentObject(client)
        .environmentObject(poller)
        .onAppear {
            poller.start()
            // Belt and suspenders: explicitly refresh on every appearance.
            // SwiftUI doesn't always re-fire onAppear in a clean lifecycle
            // (sheets, mode toggles), and `poller.start()`'s "fetch once
            // immediately" path is guarded by `task == nil` — if the
            // poller's still running from a previous appearance, no fresh
            // fetch happens. Calling refreshNow here is idempotent and
            // costs one /child/state request per appearance.
            Task { await poller.refreshNow() }
        }
        .onDisappear { poller.stop() }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                Task { await poller.refreshNow() }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottom) {
            if let err = poller.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                    Text(err)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(EvlinKidColors.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.92), in: Capsule())
                .overlay(
                    Capsule().stroke(EvlinKidColors.line, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, 58)
            }
        }
        #endif
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            BigKidDebugScenarioMenu(
                current: $debugScenario,
                onSelect: { selected in applyDebugScenario(selected) },
                onCatalog: { showCatalogDebug = true },
                onReset: {
                    Task {
                        do { try await client.debugResetState() } catch {
                            print("[BigKid] reset failed: \(error)")
                        }
                        // Drop any open detail sheet so it doesn't keep
                        // showing the now-deleted task. Then re-poll.
                        await MainActor.run {
                            taskNav = nil
                            bypassNav = nil
                            reflectionPath = NavigationPath()
                            debugScenario = .live
                        }
                        poller.start()
                        await poller.refreshNow()
                    }
                }
            )
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
        #endif
        .sheet(item: $taskNav) { t in
            BigKidTaskDetailView(
                task: t,
                onBack: { taskNav = nil },
                onBypass: {
                    bypassNav = t
                    taskNav = nil
                },
                onSubmit: { (photos: [Data], note: String?) in
                    do {
                        _ = try await client.submitEvidence(taskId: t.id, photos: photos, note: note)
                    } catch {
                        // Surface in console so we know when the kid's
                        // upload silently fails (photo too large / network /
                        // 5xx). Phase 13 follow-up: render an inline banner
                        // and keep the sheet open on failure.
                        print("[BigKid] submitEvidence failed for task \(t.id): \(error)")
                    }
                    await poller.refreshNow()
                    // Rebind taskNav to the refreshed task so the sheet
                    // re-renders with phase=.submitted (otherwise it keeps
                    // showing the .input UI from the originally-captured
                    // value). SwiftUI's .sheet(item:) only re-evaluates
                    // its content when the bound Identifiable changes —
                    // same id with new fields counts.
                    if let fresh = state.tasks.first(where: { $0.id == t.id }) {
                        await MainActor.run { taskNav = fresh }
                    }
                    // Kid stays on the screen and now sees their own photo
                    // + "Sent just now" banner. Taps "Back to today"
                    // themselves to dismiss.
                }
            )
        }
        .sheet(item: $bypassNav) { t in
            BigKidBypassView(
                task: t,
                onBack: { bypassNav = nil },
                onSend: { reason in
                    _ = try? await client.submitBypass(taskId: t.id, reason: reason)
                    await poller.refreshNow()
                }
            )
        }
        #if DEBUG
        .sheet(isPresented: $showCatalogDebug) {
            NavigationStack { ChildAppCatalogDebugView() }
        }
        #endif
        .sheet(isPresented: $showLockListGate) {
            EvlinPINGateView(
                store: .shared,
                onUnlocked: {
                    showLockListGate = false
                    showLockListManager = true
                },
                onCancel: {
                    showLockListGate = false
                }
            )
        }
        .sheet(isPresented: $showLockListManager) {
            if let familyUUID = UUID(uuidString: familyID) {
                NavigationStack {
                    LockListManagerView(
                        familyID: familyUUID,
                        childDeviceID: childDeviceID
                    )
                    .environmentObject(apiClient)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pair this device first")
                        .font(.headline)
                    Text("Evlin needs a family id before it can sync the lock list.")
                        .foregroundStyle(.secondary)
                    Button("Close") {
                        showLockListManager = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }

    /// Optimistically mark a reflection sub-step as completed in the local
    /// `BigKidState`. This makes the LockedScreen progress bar / step rows
    /// update immediately when the kid finishes a step, regardless of whether
    /// the backend `step-complete` round-trip has landed yet (or, in DEBUG
    /// scenario mode, whether the poller is even running). The next live
    /// `state` snapshot from the poller will overwrite this with the
    /// authoritative server value.
    /// Ping the parent for the current reflection. Shared by the locked
    /// state-A "I'm stuck" affordance and the state-B "nudge to approve"
    /// button. Optimistically arms the 5-min cooldown for instant feedback;
    /// the server's authoritative endsAt overwrites when the response lands.
    private func nudgeParent() {
        Task {
            guard let rid = state.reflectionRequest?.id else { return }
            state.notifyParentCooldownEndsAt = Date().addingTimeInterval(5 * 60)
            if let outcome = try? await client.reflectionNudge(rid: rid) {
                state.notifyParentCooldownEndsAt = outcome.endsAt
            }
            await poller.refreshNow()
        }
    }

    private func applyLocalStepCompletion(_ step: BigKidReflectionStep) {
        guard let req = state.reflectionRequest else { return }
        guard !req.stepsCompleted.contains(step) else { return }
        let merged = ReflectionRequest(
            id: req.id, reason: req.reason, displayReason: req.displayReason,
            topicLabel: req.topicLabel,
            videoId: req.videoId, videoTitle: req.videoTitle,
            writingPrompt: req.writingPrompt, quiz: req.quiz,
            stepsCompleted: req.stepsCompleted + [step],
            quizScore: req.quizScore, essayText: req.essayText,
            status: req.status, parentNote: req.parentNote,
            submittedAt: req.submittedAt, approvedAt: req.approvedAt,
            parentRedoNote: req.parentRedoNote, lastNudgeAt: req.lastNudgeAt,
            reflectionLockCapExpiresAt: req.reflectionLockCapExpiresAt,
            lockAppliedAt: req.lockAppliedAt
        )
        state.reflectionRequest = merged
    }

    #if DEBUG
    private func applyDebugScenario(_ scenario: BigKidDebugScenario) {
        if let snapshot = scenario.snapshot() {
            poller.stop()
            state.apply(snapshot)
            // Reset any active navigation so the route switch picks up the
            // new state cleanly (otherwise sheets could remain open over
            // the wrong root).
            taskNav = nil
            bypassNav = nil
            reflectionPath = NavigationPath()
        } else {
            // .live → resume polling.
            poller.start()
            Task { await poller.refreshNow() }
        }
    }
    #endif

    @ViewBuilder
    private func destinationView(for dest: ReflectionNav) -> some View {
        switch dest {
        case .locked:
            BigKidLockedView(
                onTapStep: { step in
                    switch step {
                    case .video:   reflectionPath.append(ReflectionNav.video)
                    case .quiz:    reflectionPath.append(ReflectionNav.quiz)
                    case .writing: reflectionPath.append(ReflectionNav.writing)
                    }
                },
                onUnlock: {
                    // 3/3 done → return to State B (HomeReflection waiting)
                    reflectionPath = NavigationPath()
                }
            )
            .navigationBarBackButtonHidden(true)
        case .video:
            if let r = state.reflectionRequest {
                BigKidVideoView(
                    videoId: r.videoId,
                    videoTitle: ReflectionVideoDisplay.cardTitle(for: r)
                ) {
                    applyLocalStepCompletion(.video)
                    _ = try? await client.reflectionStepComplete(rid: r.id, step: .video)
                    await poller.refreshNow()
                    reflectionPath.removeLast()
                }
            }
        case .quiz:
            if let r = state.reflectionRequest {
                BigKidQuizView(
                    request: r,
                    onAnswer: { idx, sel in
                        (try? await client.reflectionQuizAnswer(rid: r.id,
                                                                 questionIndex: idx,
                                                                 selectedIndex: sel))
                        ?? QuizAnswerOutcome(correct: false, allCorrect: false, score: 0)
                    },
                    onComplete: {
                        applyLocalStepCompletion(.quiz)
                        await poller.refreshNow()
                        reflectionPath.removeLast()
                    },
                    onRetry: {}
                )
            }
        case .writing:
            if let r = state.reflectionRequest {
                BigKidWritingView(
                    prompt: r.writingPrompt,
                    parentRedoNote: r.parentRedoNote
                ) { text in
                    applyLocalStepCompletion(.writing)
                    _ = try? await client.reflectionEssay(rid: r.id, text: text)
                    await poller.refreshNow()
                    reflectionPath = NavigationPath()
                }
            }
        }
    }
}


#if DEBUG
#Preview("Local backend") {
    BigKidRootView(
        baseURL: URL(string: "http://localhost:8000/api/v1")!,
        childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    .environmentObject(APIClient(baseURL: "http://localhost:8000/api/v1"))
}
#endif
