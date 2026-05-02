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
    }

    @State private var taskNav: BigKidTask?
    @State private var bypassNav: BigKidTask?
    @State private var reflectionPath = NavigationPath()

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
                        onNudgeParent: {}
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
                                _ = try? await client.reflectionNudge(rid: rid)
                                await poller.refreshNow()
                            }
                        }
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
                Text("DailyComplete").bold()
            case .screenTimeFinished:
                Text("ScreenTimeFinished").bold()
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
        .sheet(item: $taskNav) { t in
            BigKidTaskDetailView(
                task: t,
                onBack: { taskNav = nil },
                onBypass: {
                    bypassNav = t
                    taskNav = nil
                },
                onSubmit: { data, note in
                    _ = try? await client.submitEvidence(taskId: t.id, photoData: data, note: note)
                    await poller.refreshNow()
                    taskNav = nil
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
                        await poller.refreshNow()
                        reflectionPath.removeLast()
                    },
                    onRetry: {}
                )
            }
        case .writing:
            if let r = state.reflectionRequest {
                BigKidWritingView(prompt: r.writingPrompt) { text in
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
