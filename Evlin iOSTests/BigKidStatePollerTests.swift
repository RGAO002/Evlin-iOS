import XCTest
@testable import Evlin_iOS

@MainActor
final class BigKidStatePollerTests: XCTestCase {
    private func authoritativeRuntime() -> EarnedTimeRuntime {
        EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            policyRevision: "policy-r17",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 90,
            remainingMinutes: 75,
            estimatedMinutes: 15
        )
    }

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

    func test_refresh_pausesUsageCountingWithoutStoppingMonitorsWhenAnyTaskIsNotDone() async {
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
            rearmUsageCounters: { rearmCount += 1; return true }
        )

        await poller.refreshNow()

        XCTAssertTrue(EarnedTimeStore.shared.usageCountingAllowed)
        XCTAssertEqual(rearmCount, 1)
    }

    func test_refresh_pausesAppLimitArmsWhenAuthoritativeGateCloses() async {
        let response = snapshot(usageCountingAllowed: false, runtime: authoritativeRuntime())
        let state = BigKidState(snapshot: response)
        var pauses = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            syncEarnedRuntime: { _ in .reconciled(0) },
            pauseAppLimitArms: { pauses += 1 }
        )

        await poller.refreshNow()

        XCTAssertEqual(pauses, 1)
    }

    func test_refresh_rearmsWhenPersistedSuccessorStartIsPendingAfterRestart() async {
        let response = snapshot(usageCountingAllowed: true, runtime: authoritativeRuntime())
        let state = BigKidState(snapshot: response)
        var rearmCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            syncEarnedRuntime: { _ in .reconciled(0) },
            setUsageCountingAllowed: { _ in true },
            hasPausedAppLimitArms: { true },
            rearmUsageCounters: { rearmCount += 1; return true }
        )

        await poller.refreshNow()

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
            rearmUsageCounters: { rearmCount += 1; return true }
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
            policyRevision: "policy-r17",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 90,
            remainingMinutes: 75,
            estimatedMinutes: 15
        )
        let response = snapshot(usageCountingAllowed: true, runtime: runtime)
        let state = BigKidState(snapshot: response)
        let deviceID = UUID()
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            expectedChildID: deviceID,
            currentChildID: { deviceID },
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            applySnapshot: { _, _ in events.append("apply") },
            mirrorChildIdentity: { _ in events.append("mirror") },
            replayMeteringCallbacks: { events.append("callback-replay") },
            syncEarnedRuntime: { _ in
                events.append("runtime")
                return .reconciled(15)
            },
            setUsageCountingAllowed: { allowed in
                events.append("gate")
                return allowed
            },
            reconcileMeteringRuntime: { allowed, receivedRuntime in
                XCTAssertTrue(allowed)
                XCTAssertEqual(receivedRuntime, runtime)
                events.append("epoch")
            },
            syncMeteringCoverage: { events.append("coverage") },
            markAuthoritativeReady: { _ in events.append("ready") },
            ensureEarnedArmed: { events.append("arm") }
        )

        await poller.refreshNow()

        XCTAssertEqual(
            events,
            [
                "mirror",
                "callback-replay",
                "apply",
                "runtime",
                "gate",
                "epoch",
                "coverage",
                "ready",
                "arm",
            ]
        )
    }

    func test_refresh_identityTransitionDoesNotArmBeforeRuntimeAndGate() async {
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            policyRevision: "policy-r17",
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
            fetchState: {
                events.append("fetch")
                return response
            },
            reconcileReflectionLock: { _ in },
            reconcileIdentityTransition: {
                events.append("identity")
                return true
            },
            applySnapshot: { _, _ in events.append("apply") },
            syncEarnedRuntime: { _ in
                events.append("runtime")
                return .reconciled(15)
            },
            setUsageCountingAllowed: { _ in
                events.append("gate")
                return false
            },
            ensureEarnedArmed: { events.append("arm") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["identity", "fetch", "apply", "runtime", "gate", "arm"])
    }

    func test_refresh_lockUnavailableStopsBeforeGateArmAndHeartbeat() async {
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            policyRevision: "policy-r17",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 90,
            remainingMinutes: 75,
            estimatedMinutes: 15
        )
        let response = snapshot(usageCountingAllowed: true, runtime: runtime)
        let state = BigKidState(snapshot: response)
        let deviceID = UUID()
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            expectedChildID: deviceID,
            currentChildID: { deviceID },
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            applySnapshot: { _, _ in events.append("apply") },
            mirrorChildIdentity: { _ in events.append("mirror") },
            syncEarnedRuntime: { _ in
                events.append("runtime")
                return .lockUnavailable
            },
            setUsageCountingAllowed: { _ in events.append("gate"); return true },
            clearAuthoritativeReadiness: { events.append("clear-ready") },
            ensureEarnedArmed: { events.append("arm") },
            reportEffectiveState: { events.append("heartbeat") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["mirror", "apply", "runtime", "clear-ready"])
        XCTAssertEqual(poller.lastError, "Screen time sync deferred")
    }

    func test_refresh_invalidRuntimeFailsClosedBeforeGateReadinessAndArm() async {
        let deviceID = UUID()
        let response = snapshot(usageCountingAllowed: true)
        let state = BigKidState(snapshot: response)
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            expectedChildID: deviceID,
            currentChildID: { deviceID },
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            applySnapshot: { _, _ in events.append("apply") },
            mirrorChildIdentity: { _ in events.append("mirror") },
            syncEarnedRuntime: { _ in events.append("runtime"); return .invalid },
            setUsageCountingAllowed: { _ in events.append("gate"); return true },
            markAuthoritativeReady: { _ in events.append("ready") },
            clearAuthoritativeReadiness: { events.append("clear-ready") },
            ensureEarnedArmed: { events.append("arm") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["mirror", "apply", "runtime", "clear-ready"])
    }

    func test_refresh_successAfterTransientLockFailureKeepsInstalledCountersAndRetriesRuntime() async {
        EarnedTimeStore.shared.usageCountingAllowed = true
        let response = snapshot(usageCountingAllowed: true)
        let state = BigKidState(snapshot: response)
        var reconciliations: [EarnedTimeStore.RuntimePolicyReconciliation] = [
            .lockUnavailable,
            .reconciled(0),
        ]
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            syncEarnedRuntime: { _ in reconciliations.removeFirst() },
            setUsageCountingAllowed: { allowed in
                let previous = EarnedTimeStore.shared.usageCountingAllowed
                EarnedTimeStore.shared.usageCountingAllowed = allowed
                return previous
            },
            ensureEarnedArmed: { events.append("earned-arm") },
            rearmUsageCounters: { events.append("other-arm"); return true }
        )

        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(events, ["earned-arm"])
        XCTAssertTrue(EarnedTimeStore.shared.usageCountingAllowed)
    }

    func test_refresh_discardsSuspendedFetchWhenGlobalChildIdentityChanges() async {
        let oldID = UUID(uuidString: "B21411CB-63A5-4489-BC68-BF8AC26EE15B")!
        let newID = UUID(uuidString: "0D45589A-722C-4E43-A06E-7501F484A46C")!
        let response = snapshot(usageCountingAllowed: true)
        let state = BigKidState(snapshot: response)
        var currentID = oldID
        var resumeFetch: CheckedContinuation<ChildStateResponse, Never>?
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            expectedChildID: oldID,
            currentChildID: { currentID },
            fetchState: {
                await withCheckedContinuation { continuation in
                    resumeFetch = continuation
                }
            },
            reconcileReflectionLock: { _ in events.append("reflection") },
            applySnapshot: { _, _ in events.append("apply") },
            mirrorChildIdentity: { _ in events.append("mirror") },
            syncEarnedRuntime: { _ in events.append("runtime"); return .reconciled(0) },
            setUsageCountingAllowed: { _ in events.append("gate"); return true },
            markAuthoritativeReady: { _ in events.append("ready") },
            ensureEarnedArmed: { events.append("arm") },
            requestFreshPoll: { events.append("fresh-poll") }
        )

        let refresh = Task { await poller.refreshNow() }
        while resumeFetch == nil { await Task.yield() }
        currentID = newID
        resumeFetch?.resume(returning: response)
        await refresh.value

        XCTAssertEqual(events, ["fresh-poll"])
        XCTAssertNil(poller.lastFetchedAt)
    }

    func test_refresh_discardsThrown410WhenChildIdentityChangesDuringFetch() async {
        let oldID = UUID(uuidString: "B21411CB-63A5-4489-BC68-BF8AC26EE15B")!
        let newID = UUID(uuidString: "0D45589A-722C-4E43-A06E-7501F484A46C")!
        let state = BigKidState(snapshot: snapshot(usageCountingAllowed: true))
        var currentID = oldID
        var resumeFetch: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            expectedChildID: oldID,
            currentChildID: { currentID },
            fetchState: {
                await withCheckedContinuation { resumeFetch = $0 }
                throw BigKidAPIError(status: 410, detail: "family_removed")
            },
            reconcileReflectionLock: { _ in },
            failOpenFamily: { events.append("fail-open") },
            requestFreshPoll: { events.append("fresh-poll") }
        )

        let refresh = Task { await poller.refreshNow() }
        while resumeFetch == nil { await Task.yield() }
        currentID = newID
        resumeFetch?.resume()
        await refresh.value

        XCTAssertEqual(events, ["fresh-poll"])
        XCTAssertFalse(poller.familyRemoved)
        XCTAssertNil(poller.lastError)
    }

    func test_nilRuntimeProbesLockAndAllowsCompatibilityReadiness() {
        let suiteName = "BigKidStatePollerTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(suiteName: suiteName)

        XCTAssertEqual(
            BigKidStatePoller.reconcileEarnedRuntime(nil, store: store),
            .runtimeUnavailable
        )
    }

    func test_nilRuntimeClearsEarnedReadinessWithoutSuppressingAuthoritativeGate() async {
        let deviceID = UUID()
        let response = snapshot(usageCountingAllowed: true, runtime: nil)
        let state = BigKidState(snapshot: response)
        var events: [String] = []
        let poller = BigKidStatePoller(
            state: state,
            expectedChildID: deviceID,
            currentChildID: { deviceID },
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            syncEarnedRuntime: { _ in .runtimeUnavailable },
            setUsageCountingAllowed: { _ in events.append("gate"); return true },
            markAuthoritativeReady: { _ in events.append("ready") },
            clearAuthoritativeReadiness: { events.append("clear") },
            ensureEarnedArmed: { events.append("arm") }
        )

        await poller.refreshNow()

        XCTAssertEqual(events, ["clear", "gate"])
        XCTAssertNil(poller.lastError)
    }

    func test_skippedDiagnosticSurvivesPollerRecreationUntilRearmSucceeds() async {
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyUsageCountingLastSkipped,
            "skipped usage event=evlin.earned.t10 unfinished_tasks=true"
        )
        let deviceID = UUID()
        let response = snapshot(usageCountingAllowed: true)
        let state = BigKidState(snapshot: response)
        var attempts: [Bool] = []

        func makePoller(result: Bool) -> BigKidStatePoller {
            BigKidStatePoller(
                state: state,
                expectedChildID: deviceID,
                currentChildID: { deviceID },
                fetchState: { response },
                reconcileReflectionLock: { _ in },
                syncEarnedRuntime: { _ in .reconciled(0) },
                setUsageCountingAllowed: { _ in true },
                rearmUsageCounters: {
                    attempts.append(result)
                    return result
                }
            )
        }

        await makePoller(result: false).refreshNow()
        XCTAssertTrue(
            CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped)
                .contains("unfinished_tasks=true")
        )

        await makePoller(result: true).refreshNow()
        XCTAssertEqual(
            CommandDeliveryDiagnostics.read(CommandDeliveryDiagnostics.keyUsageCountingLastSkipped),
            "(none)"
        )
        XCTAssertEqual(attempts, [false, true])
    }

    func test_usageCounterRearmRequiresDeviceTotalAndPerAppSuccess() {
        XCTAssertFalse(
            BigKidStatePoller.usageCounterRearmSucceeded(
                deviceTotalArmed: false,
                perAppResult: .armed(activityCount: 1, eventCount: 2)
            )
        )
        XCTAssertFalse(
            BigKidStatePoller.usageCounterRearmSucceeded(
                deviceTotalArmed: true,
                perAppResult: .partiallyArmed(armed: 1, failed: 1)
            )
        )
        XCTAssertTrue(
            BigKidStatePoller.usageCounterRearmSucceeded(
                deviceTotalArmed: true,
                perAppResult: .armed(activityCount: 1, eventCount: 2)
            )
        )
    }

    func test_nilRuntimeFailsClosedWhenCompatibilityLockProbeIsUnavailable() {
        let suiteName = "BigKidStatePollerTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = EarnedTimeStore(
            suiteName: suiteName,
            lockSelection: .unavailable("test_lock_unavailable")
        )

        XCTAssertEqual(
            BigKidStatePoller.reconcileEarnedRuntime(nil, store: store),
            .lockUnavailable
        )
    }

    func test_refresh_coalescesMultipleOverlapsIntoOneFollowUpFetch() async {
        let response = snapshot(usageCountingAllowed: true)
        let state = BigKidState(snapshot: response)
        var fetchCount = 0
        var resumeFetch: CheckedContinuation<ChildStateResponse, Never>?
        let poller = BigKidStatePoller(
            state: state,
            fetchState: {
                fetchCount += 1
                if fetchCount == 1 {
                    return await withCheckedContinuation { continuation in
                        resumeFetch = continuation
                    }
                }
                return response
            },
            reconcileReflectionLock: { _ in }
        )

        let firstRefresh = Task { await poller.refreshNow() }
        while resumeFetch == nil {
            await Task.yield()
        }

        await poller.refreshNow()
        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(fetchCount, 1)
        resumeFetch?.resume(returning: response)
        await firstRefresh.value
        XCTAssertEqual(fetchCount, 2)
    }

    func test_refresh_persistsValidRuntimeAndMonotonicAcceptedEstimate() async {
        let store = EarnedTimeStore.shared
        store.removeAll()
        _ = store.reconcileAcceptedUsage(
            usageDate: "2026-07-11",
            serverEstimatedMinutes: 20
        )
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-11",
            timezone: "America/New_York",
            policyRevision: "policy-r17",
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
            policyRevision: "policy-r17",
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
        let response = snapshot(
            usageCountingAllowed: true,
            runtime: authoritativeRuntime(),
            tasks: [pendingTask]
        )
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
        let response = snapshot(
            usageCountingAllowed: true,
            runtime: authoritativeRuntime()
        )
        let state = BigKidState(snapshot: response)
        var earnedArmCount = 0
        var otherRearmCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            ensureEarnedArmed: { earnedArmCount += 1 },
            rearmUsageCounters: { otherRearmCount += 1; return true }
        )

        await poller.refreshNow()
        await poller.refreshNow()

        XCTAssertEqual(earnedArmCount, 2)
        XCTAssertEqual(otherRearmCount, 0)
    }

    func test_refresh_transitionArmsEarnedOnceAndRecoversOtherCountersOnce() async {
        EarnedTimeStore.shared.usageCountingAllowed = false
        let response = snapshot(
            usageCountingAllowed: true,
            runtime: authoritativeRuntime()
        )
        let state = BigKidState(snapshot: response)
        var earnedArmCount = 0
        var otherRearmCount = 0
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in },
            ensureEarnedArmed: { earnedArmCount += 1 },
            rearmUsageCounters: { otherRearmCount += 1; return true }
        )

        await poller.refreshNow()

        XCTAssertEqual(earnedArmCount, 1)
        XCTAssertEqual(otherRearmCount, 1)
    }

    func test_earnedRearmInputs_useAcceptedBaselineAndIgnoreRawLatestEstimate() {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.poolMinutes = 120
        store.capMinutes = 100
        store.latestDeviceEstimate = 25
        store.acceptedEstimateMinutes = 7
        store.earnedUsageOffsetMinutes = 5

        let inputs = BigKidStatePoller.earnedRearmInputs(store: store)

        XCTAssertEqual(inputs.poolMinutes, 120)
        XCTAssertEqual(inputs.capMinutes, 100)
        XCTAssertEqual(inputs.offset, 7)
    }

    func test_earnedRearmInputs_preserveStoredOffsetWhenAcceptedBaselineIsMissing() {
        let store = EarnedTimeStore.shared
        store.removeAll()
        store.latestDeviceEstimate = 25
        store.acceptedEstimateMinutes = nil
        store.earnedUsageOffsetMinutes = 3

        XCTAssertEqual(BigKidStatePoller.earnedRearmInputs(store: store).offset, 3)
    }

    func test_refresh_keepsCountersInstalledOnEveryStableFalsePoll() async {
        EarnedTimeStore.shared.usageCountingAllowed = false
        let response = snapshot(usageCountingAllowed: false)
        let state = BigKidState(snapshot: response)
        let poller = BigKidStatePoller(
            state: state,
            fetchState: { response },
            reconcileReflectionLock: { _ in }
        )

        await poller.refreshNow()
        await poller.refreshNow()

    }
}
