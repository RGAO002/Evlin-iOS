import SwiftUI

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

    var body: some View {
        Group {
            switch BigKidRouter.route(state) {
            case .home:
                BigKidHomeView { task in taskNav = task }
            case .homeReflectionA:
                BigKidHomeReflectionView(
                    subState: .a,
                    onStartReflection: { /* TODO Phase 7 nav to LockedScreen */ },
                    onTaskTap: { task in taskNav = task },
                    onNudgeParent: { /* not used in State A */ }
                )
            case .homeReflectionB:
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
            case .complete:
                Text("CompleteScreen").bold()
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
}


#if DEBUG
#Preview("Local backend") {
    BigKidRootView(
        baseURL: URL(string: "http://localhost:8000/api/v1")!,
        childId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
}
#endif
