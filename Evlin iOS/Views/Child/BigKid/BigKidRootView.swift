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
    @State private var state: BigKidState
    @StateObject private var client: BigKidAPIClient
    @StateObject private var poller: BigKidStatePoller
    @Environment(\.scenePhase) private var scenePhase

    init(baseURL: URL, childId: UUID) {
        let client = BigKidAPIClient(baseURL: baseURL, childId: childId)
        #if DEBUG
        let initialState = BigKidState(snapshot: .fixture())
        #else
        let initialState = BigKidState(snapshot: ChildStateResponse(
            childName: "", minutesLeft: 0, minutesMax: 0,
            tasks: [], reflectionRequest: nil,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false
        ))
        #endif
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

    #if DEBUG
    @State private var debugScenario: BigKidDebugScenario = .live
    #endif

    var body: some View {
        Group {
            switch BigKidRouter.route(state) {
            case .home:
                BigKidHomeView { task in taskNav = task }
            case .homeReflectionA:
                NavigationStack(path: $reflectionPath) {
                    BigKidHomeReflectionView(
                        subState: .a,
                        onStartReflection: { reflectionPath.append(ReflectionNav.locked) },
                        onTaskTap: { _ in },
                        onNudgeParent: {},
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
                        onNudgeParent: {
                            Task {
                                guard let rid = state.reflectionRequest?.id else { return }
                                // Optimistic local cooldown — flip the button
                                // into "Just sent — try again in m:ss" the
                                // moment it's pressed. Server's authoritative
                                // endsAt overwrites if the response lands.
                                state.notifyParentCooldownEndsAt =
                                    Date().addingTimeInterval(5 * 60)
                                if let outcome = try? await client.reflectionNudge(rid: rid) {
                                    state.notifyParentCooldownEndsAt = outcome.endsAt
                                }
                                await poller.refreshNow()
                            }
                        },
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
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                Task { await poller.refreshNow() }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottom) {
            if let err = poller.lastError {
                Text("⚠︎ poller: \(err)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        #endif
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            BigKidDebugScenarioMenu(
                current: $debugScenario,
                onSelect: { selected in applyDebugScenario(selected) },
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
    }

    /// Optimistically mark a reflection sub-step as completed in the local
    /// `BigKidState`. This makes the LockedScreen progress bar / step rows
    /// update immediately when the kid finishes a step, regardless of whether
    /// the backend `step-complete` round-trip has landed yet (or, in DEBUG
    /// scenario mode, whether the poller is even running). The next live
    /// `state` snapshot from the poller will overwrite this with the
    /// authoritative server value.
    private func applyLocalStepCompletion(_ step: BigKidReflectionStep) {
        guard let req = state.reflectionRequest else { return }
        guard !req.stepsCompleted.contains(step) else { return }
        let merged = ReflectionRequest(
            id: req.id, reason: req.reason, displayReason: req.displayReason,
            videoId: req.videoId, videoTitle: req.videoTitle,
            writingPrompt: req.writingPrompt, quiz: req.quiz,
            stepsCompleted: req.stepsCompleted + [step],
            quizScore: req.quizScore, essayText: req.essayText,
            status: req.status, parentNote: req.parentNote,
            submittedAt: req.submittedAt, approvedAt: req.approvedAt
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
                BigKidVideoView(videoId: r.videoId, videoTitle: r.videoTitle) {
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
                BigKidWritingView(prompt: r.writingPrompt) { text in
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
}
#endif
