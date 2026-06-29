import XCTest
@testable import Evlin_iOS

@MainActor
final class BigKidStatePollerTests: XCTestCase {
    override func tearDown() {
        EarnedTimeStore.shared.removeAll()
        CommandDeliveryDiagnostics.remove(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
        super.tearDown()
    }

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

    func test_refresh_disablesUsageCountingWhenAnyTaskIsNotDone() async {
        EarnedTimeStore.shared.usageCountingAllowed = true
        let initial = ChildStateResponse.fixture(tasks: [])
        let pending = ChildStateResponse.fixture(tasks: [
            .fixture(status: .done, phase: .input),
            .fixture(status: .submitted, phase: .submitted),
        ])
        let state = BigKidState(snapshot: initial)
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { pending },
            reconcileReflectionLock: { _ in }
        )

        await poller.refreshNow()

        XCTAssertFalse(EarnedTimeStore.shared.usageCountingAllowed)
    }

    func test_refresh_enablesUsageCountingWhenTasksAreDoneOrBypassed() async {
        EarnedTimeStore.shared.usageCountingAllowed = false
        let approvedBypass = BypassRequest.fixture(status: .approved)
        let complete = ChildStateResponse.fixture(tasks: [
            .fixture(status: .done, phase: .input),
            .fixture(status: .todo, phase: .input, bypass: approvedBypass),
        ])
        let state = BigKidState(snapshot: ChildStateResponse.fixture(tasks: []))
        var rearmCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { complete },
            reconcileReflectionLock: { _ in },
            rearmUsageCounters: { rearmCount += 1 }
        )

        await poller.refreshNow()

        XCTAssertTrue(EarnedTimeStore.shared.usageCountingAllowed)
        XCTAssertEqual(rearmCount, 1)
    }

    func test_refresh_rearmsUsageCountersWhenDoneAfterSkippedUnfinishedUsageEvenIfGateAlreadyTrue() async {
        EarnedTimeStore.shared.usageCountingAllowed = true
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyUsageCountingLastSkipped,
            "skipped usage event=evlin.earned.t10 unfinished_tasks=true"
        )
        let complete = ChildStateResponse.fixture(tasks: [
            .fixture(status: .done, phase: .input),
        ])
        let state = BigKidState(snapshot: ChildStateResponse.fixture(tasks: []))
        var rearmCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { complete },
            reconcileReflectionLock: { _ in },
            rearmUsageCounters: { rearmCount += 1 }
        )

        await poller.refreshNow()

        XCTAssertTrue(EarnedTimeStore.shared.usageCountingAllowed)
        XCTAssertEqual(rearmCount, 1)
        XCTAssertEqual(
            CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped),
            "(none)"
        )
    }

    func test_refresh_reportsEffectiveStateAfterSuccessfulFetch() async {
        let snapshot = ChildStateResponse.fixture(tasks: [])
        let state = BigKidState(snapshot: snapshot)
        var reportCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { snapshot },
            reconcileReflectionLock: { _ in },
            reportEffectiveState: {
                reportCount += 1
            }
        )

        await poller.refreshNow()

        XCTAssertEqual(reportCount, 1)
    }
}
