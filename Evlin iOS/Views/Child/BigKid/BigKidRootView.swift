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

    var body: some View {
        Group {
            switch BigKidRouter.route(state) {
            case .home:
                BigKidHomeView { task in /* TODO Phase 6 task detail nav */ }
            case .homeReflectionA:
                Text("HomeReflection A").bold()
            case .homeReflectionB:
                Text("HomeReflection B").bold()
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
