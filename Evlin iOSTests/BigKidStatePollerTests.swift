import XCTest
@testable import Evlin_iOS

@MainActor
final class BigKidStatePollerTests: XCTestCase {
    func test_refresh_reconciles_reflection_lock_before_applying_snapshot() async {
        let initial = ChildStateResponse(
            childName: "",
            minutesLeft: 0,
            minutesMax: 0,
            tasks: [],
            reflectionRequest: nil,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil
        )
        let snapshot = ChildStateResponse(
            childName: "Liam",
            minutesLeft: 0,
            minutesMax: 120,
            tasks: [],
            reflectionRequest: ReflectionRequest.fixture(),
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil
        )
        let state = BigKidState(snapshot: initial)
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            fetchState: {
                events.append("fetch")
                return snapshot
            },
            reconcileReflectionLock: { _ in
                events.append("reconcile")
            },
            applySnapshot: { snapshot, state in
                events.append("apply")
                state.apply(snapshot)
            }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["fetch", "reconcile", "apply"])
        XCTAssertEqual(state.childName, "Liam")
    }
}
