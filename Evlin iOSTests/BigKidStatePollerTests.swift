import XCTest
@testable import Evlin_iOS

@MainActor
final class BigKidStatePollerTests: XCTestCase {
    private func snapshot(
        usageCountingAllowed: Bool,
        runtime: EarnedTimeRuntime? = nil,
        tasks: [BigKidTask] = []
    ) -> ChildStateResponse {
        ChildStateResponse(
            childName: "Liam",
            minutesLeft: 0,
            minutesMax: 120,
            tasks: tasks,
            reflectionRequest: nil,
            notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false,
            screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil,
            usageCountingAllowed: usageCountingAllowed,
            earnedTimeRuntime: runtime
        )
    }

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
        var stopCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { pending },
            reconcileReflectionLock: { _ in },
            stopUsageCounters: { stopCount += 1 }
        )

        await poller.refreshNow()

        XCTAssertFalse(EarnedTimeStore.shared.usageCountingAllowed)
        XCTAssertEqual(stopCount, 1)
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

    func test_refresh_appliesRuntimeBeforeAuthoritativeGateAndEarnedArm() async {
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 90,
            remainingMinutes: 75,
            estimatedMinutes: 15
        )
        let response = snapshot(usageCountingAllowed: true, runtime: runtime)
        let state = BigKidState(snapshot: response)
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            applySnapshot: { _, _ in events.append("apply") },
            syncEarnedRuntime: { _ in events.append("runtime") },
            setUsageCountingAllowed: {
                events.append("gate")
                return $0
            },
            ensureEarnedArmed: { events.append("arm") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["apply", "runtime", "gate", "arm"])
    }

    func test_refresh_persistsValidRuntimeAndMonotonicAcceptedEstimate() async {
        let store = EarnedTimeStore.shared
        store.removeAll()
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-11",
            serverEstimatedMinutes: 20,
            allowSameDayDecrease: false
        )
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            dailyPoolMinutes: 100,
            deviceCapMinutes: 80,
            remainingMinutes: 63,
            estimatedMinutes: 15
        )
        let response = snapshot(usageCountingAllowed: true, runtime: runtime)
        let state = BigKidState(snapshot: response)
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in }
        )

        await poller.refreshNow()

        XCTAssertEqual(store.poolMinutes, 100)
        XCTAssertEqual(store.capMinutes, 80)
        XCTAssertEqual(store.backendRemainingAtLastSync, 63)
        XCTAssertNotNil(store.lastBackendSyncAt)
        XCTAssertEqual(store.acceptedUsageDate, "2026-07-11")
        XCTAssertEqual(store.acceptedEstimateMinutes, 20)
    }

    func test_refresh_ignoresZeroPoolRuntimeAndPreservesStoredPolicy() async {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.poolMinutes = 90
        store.capMinutes = 60
        store.backendRemainingAtLastSync = 42
        let previousSync = Date(timeIntervalSince1970: 1_700_000_000)
        store.lastBackendSyncAt = previousSync
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            dailyPoolMinutes: 0,
            deviceCapMinutes: 60,
            remainingMinutes: 0,
            estimatedMinutes: 0
        )
        let response = snapshot(usageCountingAllowed: true, runtime: runtime)
        let state = BigKidState(snapshot: response)
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in }
        )

        await poller.refreshNow()

        XCTAssertEqual(store.poolMinutes, 90)
        XCTAssertEqual(store.capMinutes, 60)
        XCTAssertEqual(store.backendRemainingAtLastSync, 42)
        XCTAssertEqual(store.lastBackendSyncAt, previousSync)
    }

    func test_refresh_usesAuthoritativeGateInsteadOfDerivedTaskState() async {
        EarnedTimeStore.shared.usageCountingAllowed = false
        let pendingTask = BigKidTask.fixture(status: .submitted, phase: .submitted)
        let response = snapshot(usageCountingAllowed: true, tasks: [pendingTask])
        let state = BigKidState(snapshot: response)
        var armed = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            ensureEarnedArmed: { armed += 1 }
        )

        await poller.refreshNow()

        XCTAssertTrue(EarnedTimeStore.shared.usageCountingAllowed)
        XCTAssertEqual(armed, 1)
    }

    func test_refresh_retriesEarnedArmOnEveryStableAllowedPoll() async {
        EarnedTimeStore.shared.usageCountingAllowed = true
        let response = snapshot(usageCountingAllowed: true)
        let state = BigKidState(snapshot: response)
        var earnedArmCount = 0
        var otherRearmCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            ensureEarnedArmed: { earnedArmCount += 1 },
            rearmUsageCounters: { otherRearmCount += 1 }
        )

        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(earnedArmCount, 2)
        XCTAssertEqual(otherRearmCount, 0)
    }

    func test_refresh_stopsCountersOnEveryStableFalsePoll() async {
        EarnedTimeStore.shared.usageCountingAllowed = false
        let response = snapshot(usageCountingAllowed: false)
        let state = BigKidState(snapshot: response)
        var stopCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            stopUsageCounters: { stopCount += 1 }
        )

        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(stopCount, 2)
    }

    func test_stopUsageCountersForTaskPause_stopsAllThreeCounterSystems() {
        var stoppedSystems: [String] = []

        BigKidStatePoller.stopUsageCounters(
            stopEarned: { stoppedSystems.append("earned") },
            stopDeviceTotal: { stoppedSystems.append("deviceTotal") },
            stopPerApp: { stoppedSystems.append("perApp") }
        )

        XCTAssertEqual(stoppedSystems, ["earned", "deviceTotal", "perApp"])
    }
}
