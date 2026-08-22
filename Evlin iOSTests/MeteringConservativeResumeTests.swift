import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringConservativeResumeTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let start = Date(timeIntervalSince1970: 1_784_332_800)
    private let baseURL = URL(string: "https://example.invalid/api/v1")!

    func testPausedRouteStaysInstalledAndResumeUsesAuthoritativeBaseWithOneDiscard() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let runtime = EarnedTimeRuntime(
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            policyRevision: "resume",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 43,
            estimatedMinutes: 17
        )
        let firstClock = ResumeClock(now: start.addingTimeInterval(3_600))
        let driver = makeDriver(fixture, clock: firstClock)

        try driver.reconcileUsageGate(
            ownerChildDeviceID: owner,
            allowed: false,
            runtime: runtime
        )

        var state = try fixture.store.read()
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.status, .paused)
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
        let oldRoute = try XCTUnwrap(state.routes[fixture.oldRouteID])
        let oldEvent = try XCTUnwrap(oldRoute.plannedEvents.first)
        let callback = EarnedMeteringCallback(store: fixture.store, clock: firstClock)
        XCTAssertEqual(
            try callback.handle(
                MeteringAppleCallback(
                    activityName: oldRoute.activityName,
                    eventName: oldEvent.eventName,
                    observedAt: firstClock.now
                ),
                expectedOwnerChildDeviceID: owner
            ),
            .discarded(reason: "paused")
        )
        let pausedBytes = try Data(contentsOf: fixture.storeURL)
        XCTAssertEqual(
            try callback.handle(
                MeteringAppleCallback(
                    activityName: oldRoute.activityName,
                    eventName: oldEvent.eventName,
                    observedAt: firstClock.now
                ),
                expectedOwnerChildDeviceID: owner
            ),
            .discarded(reason: "paused")
        )
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), pausedBytes)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)

        try driver.reconcileUsageGate(
            ownerChildDeviceID: owner,
            allowed: true,
            runtime: runtime
        )
        state = try fixture.store.read()
        let candidate = try XCTUnwrap(state.routes.values.first {
            $0.routeID != fixture.oldRouteID && state.epochs[$0.epochID]?.resumeBoundaryPending == true
        })
        XCTAssertEqual(state.epochs[candidate.epochID]?.baseAcceptedMinutes, 17)
        XCTAssertEqual(state.epochs[candidate.epochID]?.status, .active)
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .active)
        let openedBytes = try Data(contentsOf: fixture.storeURL)
        let laterOldEvent = try XCTUnwrap(oldRoute.plannedEvents.dropFirst().first)
        XCTAssertEqual(
            try callback.handle(
                MeteringAppleCallback(
                    activityName: oldRoute.activityName,
                    eventName: laterOldEvent.eventName,
                    observedAt: firstClock.now
                ),
                expectedOwnerChildDeviceID: owner
            ),
            .discarded(reason: "paused_replacement_pending")
        )
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), openedBytes)

        fixture.transport.results = [
            registrationResult(epochID: candidate.epochID),
            activationResult(epochID: candidate.epochID)
        ]
        try await makeDriver(fixture, clock: ResumeClock(now: firstClock.now.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(
            state.installWork.values.first(where: { $0.routeID == candidate.routeID })?.phase,
            .active
        )
        XCTAssertEqual(
            state.registrationWork.values.first(where: { $0.routeID == candidate.routeID })?.retry.terminal,
            .succeeded
        )
        XCTAssertEqual(
            state.activationWork.values.first(where: { $0.routeID == candidate.routeID })?.retry.terminal,
            .succeeded
        )
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.retireReason, .gateResumeConservative)
        XCTAssertEqual(fixture.center.stopCalls, [[DeviceActivityName(oldRoute.activityName)]])
        XCTAssertEqual(
            state.registrationWork.values.first(where: { $0.routeID == candidate.routeID })?.request.reason,
            .gateResumeConservative
        )

        let activeRoute = try XCTUnwrap(state.routes[candidate.routeID])
        let events = activeRoute.plannedEvents
        XCTAssertGreaterThanOrEqual(events.count, 2)
        let activeCallback = EarnedMeteringCallback(
            store: fixture.store,
            clock: ResumeClock(now: start.addingTimeInterval(7_200))
        )
        XCTAssertEqual(
            try activeCallback.handle(
                MeteringAppleCallback(
                    activityName: activeRoute.activityName,
                    eventName: events[0].eventName,
                    observedAt: start.addingTimeInterval(7_200)
                ),
                expectedOwnerChildDeviceID: owner
            ),
            .discarded(reason: "resume_boundary")
        )
        state = try fixture.store.read()
        XCTAssertFalse(try XCTUnwrap(state.epochs[candidate.epochID]).resumeBoundaryPending)
        XCTAssertEqual(state.epochs[candidate.epochID]?.excludedWhilePausedMinutes, events[0].thresholdMinutes)
        XCTAssertTrue(state.sampleWork.isEmpty)

        guard case .queued(let sampleID) = try activeCallback.handle(
            MeteringAppleCallback(
                activityName: activeRoute.activityName,
                eventName: events[1].eventName,
                observedAt: start.addingTimeInterval(7_500)
            ),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("second callback did not queue") }
        let sample = try XCTUnwrap(try fixture.store.read().sampleWork[sampleID])
        XCTAssertEqual(sample.request.estimatedMinutes, 17 + events[1].thresholdMinutes - events[0].thresholdMinutes)
        XCTAssertEqual(sample.request.usageDate, "2026-07-17")
        XCTAssertEqual(sample.authorization, .v2Deliverable)

        let pausedSnapshot = DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-17",
            estimatedMinutes: sample.request.estimatedMinutes,
            capMinutes: 60,
            childDayState: "paused",
            usedMinutes: 17,
            remainingMinutes: 43,
            counted: false,
            warning: "accounting_paused"
        )
        fixture.transport.results = [
            (try JSONEncoder().encode(pausedSnapshot), httpResponse())
        ]
        let deliveryClock = ResumeClock(now: start.addingTimeInterval(7_501))
        // Future horizon installs precede network samples globally. This focused
        // response test retires only unrelated pending fixture work after the
        // conservative replacement itself has been fully activated.
        try fixture.store.transaction(expectedOwner: owner) { state in
            for (key, var work) in state.installWork where work.retry.terminal == .pending {
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "test_fixture_horizon_pruned"
                state.installWork[key] = work
            }
        }
        XCTAssertEqual(try fixture.store.read().dueWork(now: deliveryClock.now).first?.kind, .sample)
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: fixture.store,
            transport: fixture.transport,
            clock: deliveryClock
        )
        await delivery.drain(owner: owner, importLegacyWork: false)

        state = try fixture.store.read()
        let terminal = try XCTUnwrap(state.sampleWork[sampleID])
        XCTAssertEqual(terminal.retry.terminal, .rejected)
        XCTAssertEqual(terminal.retry.lastErrorCode, "accounting_paused")
        XCTAssertFalse(state.sampleWork.values.contains { $0.retry.terminal == .pending })
    }

    func testSameDayResumeSettlesStrandedPausedSampleAndCompletesHandoff() async throws {
        // #84 (P1-1), iPad 2026-08-05 02:28: a sample queued while the epoch
        // was still active becomes permanently undeliverable once the gate
        // closes — the dispatcher only claims samples on active epochs, so the
        // delivery-settle terminalizer never runs — and the pending work then
        // wedges the same-day resume replacement barrier until midnight.
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let runtime = resumeRuntime()
        let pausedAt = start.addingTimeInterval(3_600)

        let oldRoute = try XCTUnwrap(try fixture.store.read().routes[fixture.oldRouteID])
        let oldEvent = try XCTUnwrap(oldRoute.plannedEvents.first)
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: ResumeClock(now: pausedAt.addingTimeInterval(-1))
        )
        guard case .queued(let strandedSampleID) = try callback.handle(
            MeteringAppleCallback(
                activityName: oldRoute.activityName,
                eventName: oldEvent.eventName,
                observedAt: pausedAt.addingTimeInterval(-1)
            ),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("pre-pause sample did not queue") }

        try makeDriver(fixture, clock: ResumeClock(now: pausedAt))
            .reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: false,
                runtime: runtime
            )

        let resumedAt = pausedAt.addingTimeInterval(420)
        try makeDriver(fixture, clock: ResumeClock(now: resumedAt))
            .reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: true,
                runtime: runtime
            )

        var state = try fixture.store.read()
        let candidate = try XCTUnwrap(state.routes.values.first {
            $0.routeID != fixture.oldRouteID
                && state.epochs[$0.epochID]?.resumeBoundaryPending == true
        })

        fixture.transport.results = [
            registrationResult(epochID: candidate.epochID),
            activationResult(epochID: candidate.epochID)
        ]
        try await makeDriver(fixture, clock: ResumeClock(now: resumedAt.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork[strandedSampleID]?.retry.terminal, .rejected)
        XCTAssertEqual(
            state.sampleWork[strandedSampleID]?.retry.lastErrorCode,
            "accounting_paused"
        )
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(
            state.registrationWork.values.first(where: { $0.routeID == candidate.routeID })?.retry.terminal,
            .succeeded
        )
        XCTAssertEqual(
            state.registrationWork.values.first(where: { $0.routeID == candidate.routeID })?.request.reason,
            .gateResumeConservative
        )
    }

    func testPausedPriorDayResumesIntoAuthoritativeCurrentDayGeneration() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let pausedAt = start.addingTimeInterval(3_600)
        let nextDay = start.addingTimeInterval(86_400)
        let pausedRuntime = resumeRuntime()
        let currentRuntime = EarnedTimeRuntime(
            usageDate: "2026-07-18",
            timezone: "America/New_York",
            policyRevision: "current-day",
            dailyPoolMinutes: 180,
            deviceCapMinutes: 120,
            remainingMinutes: 120,
            estimatedMinutes: 0
        )
        let driver = makeDriver(fixture, clock: ResumeClock(now: pausedAt))
        let oldRoute = try XCTUnwrap(try fixture.store.read().routes[fixture.oldRouteID])
        let oldEvent = try XCTUnwrap(oldRoute.plannedEvents.first)
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: ResumeClock(now: pausedAt.addingTimeInterval(-1))
        )
        guard case .queued(let priorSampleID) = try callback.handle(
            MeteringAppleCallback(
                activityName: oldRoute.activityName,
                eventName: oldEvent.eventName,
                observedAt: pausedAt.addingTimeInterval(-1)
            ),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("prior-day sample did not queue") }

        try driver.reconcileUsageGate(
            ownerChildDeviceID: owner,
            allowed: false,
            runtime: pausedRuntime
        )
        let currentGenerationID = try fixture.seedDesiredGeneration(
            usageDate: currentRuntime.usageDate,
            policyRevision: currentRuntime.policyRevision,
            poolMinutes: currentRuntime.dailyPoolMinutes,
            capMinutes: currentRuntime.deviceCapMinutes,
            now: nextDay
        )

        let resumedAt = nextDay.addingTimeInterval(1)
        try makeDriver(fixture, clock: ResumeClock(now: resumedAt))
            .reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: true,
                runtime: currentRuntime
            )

        var state = try fixture.store.read()
        let candidate = try XCTUnwrap(state.routes.values.first {
            $0.routeID != fixture.oldRouteID
                && $0.generationID == currentGenerationID
                && $0.usageDate == currentRuntime.usageDate
                && state.epochs[$0.epochID]?.resumeBoundaryPending == true
        })
        XCTAssertEqual(state.epochs[candidate.epochID]?.baseAcceptedMinutes, 0)
        XCTAssertEqual(state.epochs[candidate.epochID]?.baseSource, .childState200)
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.sampleWork[priorSampleID]?.retry.terminal, .rejected)
        XCTAssertEqual(state.sampleWork[priorSampleID]?.retry.lastErrorCode, "paused_day_closed")
        try fixture.store.transaction(expectedOwner: owner) { state in
            for (key, var work) in state.installWork
                where work.routeID != fixture.oldRouteID && work.routeID != candidate.routeID {
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "test_fixture_horizon_pruned"
                state.installWork[key] = work
            }
            for (key, var work) in state.registrationWork
                where work.routeID != fixture.oldRouteID && work.routeID != candidate.routeID {
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "test_fixture_horizon_pruned"
                state.registrationWork[key] = work
            }
        }

        fixture.transport.results = [
            registrationResult(
                epochID: candidate.epochID,
                usageDate: currentRuntime.usageDate,
                estimatedMinutes: currentRuntime.estimatedMinutes,
                capMinutes: currentRuntime.deviceCapMinutes
            ),
            activationResult(
                epochID: candidate.epochID,
                usageDate: currentRuntime.usageDate,
                estimatedMinutes: currentRuntime.estimatedMinutes,
                capMinutes: currentRuntime.deviceCapMinutes
            )
        ]
        try await makeDriver(fixture, clock: ResumeClock(now: resumedAt.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.activeGenerationID, currentGenerationID)
        XCTAssertEqual(state.activeEpochID, candidate.epochID)
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.retireReason, .gateResumeConservative)
        XCTAssertEqual(
            state.registrationWork.values.first(where: { $0.routeID == candidate.routeID })?.request.reason,
            .gateResumeConservative
        )
    }

    func testElapsedNeverRegisteredCandidateHandoffIsAbandonedSoNextDayResumes() async throws {
        // #53 (FIX-0c), iPad 2026-08-05: a same-day gate-resume candidate that
        // never managed to register is stranded when midnight passes — the
        // handoff slot it owns blocks the cross-day resume mint, the rollover
        // effect leg refuses a slot holding someone else's handoffID, and the
        // abandon sweeps demand a terminal rejection it never earned. The
        // device stays pinned on yesterday until manual rescue.
        for phase in [V2RouteHandoffPhase.preparing, .dualV2] {
            let fixture = try ResumeFixture(owner: owner, start: start)
            defer { fixture.cleanup() }
            let pausedAt = start.addingTimeInterval(3_600)
            let resumedAt = pausedAt.addingTimeInterval(420)

            try makeDriver(fixture, clock: ResumeClock(now: pausedAt))
                .reconcileUsageGate(
                    ownerChildDeviceID: owner,
                    allowed: false,
                    runtime: resumeRuntime()
                )
            try makeDriver(fixture, clock: ResumeClock(now: resumedAt))
                .reconcileUsageGate(
                    ownerChildDeviceID: owner,
                    allowed: true,
                    runtime: resumeRuntime()
                )

            var state = try fixture.store.read()
            let staleCandidate = try XCTUnwrap(state.routes.values.first {
                $0.routeID != fixture.oldRouteID
                    && state.epochs[$0.epochID]?.resumeBoundaryPending == true
            })
            let staleHandoffID = UUID()
            try fixture.store.transaction(expectedOwner: owner) { state in
                let installKey = try XCTUnwrap(
                    state.installWork.first {
                        $0.value.routeID == staleCandidate.routeID
                    }?.key
                )
                // Installed at the daemon (tonight's device had callbacks
                // arriving on the candidate) but never verified/registered.
                var installed = try XCTUnwrap(state.routes[staleCandidate.routeID])
                installed.installedSchedule = installed.plannedSchedule
                installed.installedEvents = installed.plannedEvents
                if phase == .dualV2 {
                    installed.lifecycle = .active
                    state.installWork[installKey]?.phase = .dualActive
                } else {
                    state.installWork[installKey]?.phase = .installed
                }
                state.routes[staleCandidate.routeID] = installed
                state.v2RouteHandoff = V2RouteHandoff(
                    handoffID: staleHandoffID,
                    ownerChildDeviceID: owner,
                    fromGenerationID: try XCTUnwrap(state.activeGenerationID),
                    fromEpochID: fixture.oldEpochID,
                    fromRouteID: fixture.oldRouteID,
                    toGenerationID: staleCandidate.generationID,
                    toEpochID: staleCandidate.epochID,
                    toRouteID: staleCandidate.routeID,
                    phase: phase,
                    priorRouteInputClosedAt: nil,
                    registrationAcknowledgedAt: nil,
                    activationAcknowledgedAt: nil,
                    priorStopAcknowledgedAt: nil,
                    createdAt: resumedAt
                )
                state.v2RouteHandoff?.explicitRecovery = .gateResumeConservative
            }
            fixture.center.records[DeviceActivityName(staleCandidate.activityName)] = (
                try MeteringDatedSchedule.datedSchedule(
                    usageDate: staleCandidate.usageDate,
                    timeZone: TimeZone(identifier: "America/New_York")!
                ),
                [:]
            )

            // Midnight passes; the parent's policy for the new day exists.
            let nextDay = start.addingTimeInterval(86_400)
            let currentRuntime = EarnedTimeRuntime(
                usageDate: "2026-07-18",
                timezone: "America/New_York",
                policyRevision: "current-day",
                dailyPoolMinutes: 180,
                deviceCapMinutes: 120,
                remainingMinutes: 120,
                estimatedMinutes: 0
            )
            let currentGenerationID = try fixture.seedDesiredGeneration(
                usageDate: currentRuntime.usageDate,
                policyRevision: currentRuntime.policyRevision,
                poolMinutes: currentRuntime.dailyPoolMinutes,
                capMinutes: currentRuntime.deviceCapMinutes,
                now: nextDay
            )

            // Production pass 1: gate reconcile (slot still occupied), then the
            // recovery pass — where the elapsed candidate must be abandoned.
            try makeDriver(fixture, clock: ResumeClock(now: nextDay.addingTimeInterval(1)))
                .reconcileUsageGate(
                    ownerChildDeviceID: owner,
                    allowed: true,
                    runtime: currentRuntime
                )
            try await makeDriver(fixture, clock: ResumeClock(now: nextDay.addingTimeInterval(2)))
                .recover(ownerChildDeviceID: owner)

            // Production pass 2: with the slot free, the cross-day resume mints
            // the current-day candidate and drives it to committed.
            try makeDriver(fixture, clock: ResumeClock(now: nextDay.addingTimeInterval(10)))
                .reconcileUsageGate(
                    ownerChildDeviceID: owner,
                    allowed: true,
                    runtime: currentRuntime
                )
            state = try fixture.store.read()
            let todayCandidate = try XCTUnwrap(
                state.routes.values.first {
                    $0.generationID == currentGenerationID
                        && $0.usageDate == currentRuntime.usageDate
                        && state.epochs[$0.epochID]?.resumeBoundaryPending == true
                },
                "phase \(phase): no current-day candidate was minted — slot still wedged"
            )
            try fixture.store.transaction(expectedOwner: owner) { state in
                for (key, var work) in state.installWork
                    where work.routeID != fixture.oldRouteID
                        && work.routeID != todayCandidate.routeID
                        && work.routeID != staleCandidate.routeID
                        && work.retry.terminal == .pending {
                    work.retry.terminal = .superseded
                    work.retry.lastErrorCode = "test_fixture_horizon_pruned"
                    state.installWork[key] = work
                }
                for (key, var work) in state.registrationWork
                    where work.routeID != fixture.oldRouteID
                        && work.routeID != todayCandidate.routeID
                        && work.retry.terminal == .pending {
                    work.retry.terminal = .superseded
                    work.retry.lastErrorCode = "test_fixture_horizon_pruned"
                    state.registrationWork[key] = work
                }
            }
            fixture.transport.results = [
                registrationResult(
                    epochID: todayCandidate.epochID,
                    usageDate: currentRuntime.usageDate,
                    estimatedMinutes: currentRuntime.estimatedMinutes,
                    capMinutes: currentRuntime.deviceCapMinutes
                ),
                activationResult(
                    epochID: todayCandidate.epochID,
                    usageDate: currentRuntime.usageDate,
                    estimatedMinutes: currentRuntime.estimatedMinutes,
                    capMinutes: currentRuntime.deviceCapMinutes
                )
            ]
            try await makeDriver(fixture, clock: ResumeClock(now: nextDay.addingTimeInterval(15)))
                .recover(ownerChildDeviceID: owner)

            state = try fixture.store.read()
            XCTAssertEqual(state.activeEpochID, todayCandidate.epochID, "phase \(phase)")
            XCTAssertEqual(state.activeRouteID, todayCandidate.routeID, "phase \(phase)")
            // The abandoned candidate is tombstoned; later sweeps may garbage-
            // collect the tombstone entirely. Either way it must be gone.
            let staleLifecycle = state.routes[staleCandidate.routeID]?.lifecycle
            XCTAssertTrue(
                staleLifecycle == nil || staleLifecycle == .tombstoned,
                "phase \(phase): stale candidate still \(String(describing: staleLifecycle))"
            )
            let staleStatus = state.epochs[staleCandidate.epochID]?.status
            XCTAssertTrue(
                staleStatus == nil || staleStatus == .retired,
                "phase \(phase): stale epoch still \(String(describing: staleStatus))"
            )
            XCTAssertNotEqual(
                state.v2RouteHandoff?.handoffID, staleHandoffID, "phase \(phase)"
            )
            XCTAssertFalse(
                fixture.center.activities.contains(
                    DeviceActivityName(staleCandidate.activityName)
                ),
                "phase \(phase): stale candidate still armed at the daemon"
            )
            XCTAssertEqual(
                state.registrationWork.values.first {
                    $0.routeID == todayCandidate.routeID
                }?.request.reason,
                .gateResumeConservative,
                "phase \(phase)"
            )
        }
    }

    func testLadderRepairStormDetectorTripsOnFreshCorpsesOnly() throws {
        // #85 (P1-3): the repair-storm breaker. Five tombstoned routes born
        // within twenty minutes parks the ladder repair; fewer, or older,
        // corpses must not (a healthy day produces one or two, hours apart).
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        var state = try fixture.store.read()
        let template = try XCTUnwrap(state.routes[fixture.oldRouteID])
        let now = start.addingTimeInterval(7_200)
        func addCorpse(bornSecondsAgo: TimeInterval) {
            let routeID = UUID()
            state.routes[routeID] = MeteringCallbackRoute(
                routeID: routeID,
                activityName: MeteringRouteNamespace.activityName(routeID: routeID),
                namespace: MeteringRouteNamespace.prefix,
                generationID: template.generationID,
                generationKey: template.generationKey,
                ownerChildDeviceID: owner,
                usageDate: template.usageDate,
                epochID: template.epochID,
                plannedSchedule: template.plannedSchedule,
                installedSchedule: nil,
                plannedEvents: template.plannedEvents,
                installedEvents: nil,
                lifecycle: .tombstoned,
                createdAt: now.addingTimeInterval(-bornSecondsAgo)
            )
        }

        // A storm is repeated mint->kill->mint cycles, so each corpse must
        // carry its OWN mint instant. One batch retired at a single instant is
        // an ordinary policy change, not a storm: a parent lowering the device
        // limit produced eight same-second tombstones and parked the repair
        // forever (2026-08-08 00:05, real device).
        for i in 0..<4 { addCorpse(bornSecondsAgo: 300 - Double(i) * 20) }
        XCTAssertFalse(
            EarnedMeteringRecoveryDriver.isLadderRepairStorming(state: state, now: now),
            "four fresh mint cycles must not trip the breaker"
        )
        for _ in 0..<4 { addCorpse(bornSecondsAgo: 300) }
        XCTAssertFalse(
            EarnedMeteringRecoveryDriver.isLadderRepairStorming(state: state, now: now),
            "one batch retired at a single instant is a policy change, not a storm"
        )
        addCorpse(bornSecondsAgo: 200)
        XCTAssertTrue(
            EarnedMeteringRecoveryDriver.isLadderRepairStorming(state: state, now: now),
            "five fresh mint cycles must trip the breaker"
        )

        var staleState = try fixture.store.read()
        let freshRoutes = state.routes
        for (routeID, route) in freshRoutes where route.lifecycle == .tombstoned {
            staleState.routes[routeID] = MeteringCallbackRoute(
                routeID: route.routeID,
                activityName: route.activityName,
                namespace: route.namespace,
                generationID: route.generationID,
                generationKey: route.generationKey,
                ownerChildDeviceID: route.ownerChildDeviceID,
                usageDate: route.usageDate,
                epochID: route.epochID,
                plannedSchedule: route.plannedSchedule,
                installedSchedule: nil,
                plannedEvents: route.plannedEvents,
                installedEvents: nil,
                lifecycle: .tombstoned,
                createdAt: now.addingTimeInterval(-3_600)
            )
        }
        XCTAssertFalse(
            EarnedMeteringRecoveryDriver.isLadderRepairStorming(state: staleState, now: now),
            "old corpses must not trip the breaker"
        )
    }

    func testPausedPriorDayReplacesSupersededPreparingHandoffBeforeResume() throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let pausedAt = start.addingTimeInterval(3_600)
        let nextDay = start.addingTimeInterval(86_400)
        let currentRuntime = EarnedTimeRuntime(
            usageDate: "2026-07-18",
            timezone: "America/New_York",
            policyRevision: "current-day",
            dailyPoolMinutes: 180,
            deviceCapMinutes: 120,
            remainingMinutes: 120,
            estimatedMinutes: 0
        )
        try makeDriver(fixture, clock: ResumeClock(now: pausedAt))
            .reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: false,
                runtime: resumeRuntime()
            )
        let currentGenerationID = try fixture.seedDesiredGeneration(
            usageDate: currentRuntime.usageDate,
            policyRevision: currentRuntime.policyRevision,
            poolMinutes: currentRuntime.dailyPoolMinutes,
            capMinutes: currentRuntime.deviceCapMinutes,
            now: nextDay
        )

        let staleRoute = try XCTUnwrap(try fixture.store.read().routes.values.first {
            $0.generationID == currentGenerationID
                && $0.usageDate == currentRuntime.usageDate
                && $0.lifecycle == .planned
        })
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: owner,
                fromGenerationID: try XCTUnwrap(state.activeGenerationID),
                fromEpochID: fixture.oldEpochID,
                fromRouteID: fixture.oldRouteID,
                toGenerationID: currentGenerationID,
                toEpochID: staleRoute.epochID,
                toRouteID: staleRoute.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: nextDay
            )
            let installKey = try XCTUnwrap(
                state.installWork.first { $0.value.routeID == staleRoute.routeID }?.key
            )
            state.installWork[installKey]?.authorization = .offlinePending
            state.installWork[installKey]?.retry.terminal = .superseded
            state.installWork[installKey]?.retry.lastErrorCode = "route_superseded"
            for (key, var work) in state.registrationWork where work.routeID == staleRoute.routeID {
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "replacement_registration_deferred"
                state.registrationWork[key] = work
            }
        }

        try makeDriver(fixture, clock: ResumeClock(now: nextDay.addingTimeInterval(1)))
            .reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: true,
                runtime: currentRuntime
            )

        let state = try fixture.store.read()
        XCTAssertNil(state.v2RouteHandoff)
        XCTAssertEqual(state.routes[staleRoute.routeID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.epochs[staleRoute.epochID]?.retireReason, .activationSuperseded)
        XCTAssertNotNil(state.routes.values.first {
            $0.routeID != staleRoute.routeID
                && $0.generationID == currentGenerationID
                && $0.usageDate == currentRuntime.usageDate
                && $0.lifecycle == .planned
                && state.epochs[$0.epochID]?.resumeBoundaryPending == true
        })
    }

    func testPausedPriorDayReplacesUncommittedActiveCandidateBeforeResume() throws {
        for phase in [V2RouteHandoffPhase.dualV2, .cutoverReady] {
            let fixture = try ResumeFixture(owner: owner, start: start)
            defer { fixture.cleanup() }
            let pausedAt = start.addingTimeInterval(3_600)
            let nextDay = start.addingTimeInterval(86_400)
            let currentRuntime = EarnedTimeRuntime(
                usageDate: "2026-07-18",
                timezone: "America/New_York",
                policyRevision: "current-day",
                dailyPoolMinutes: 180,
                deviceCapMinutes: 120,
                remainingMinutes: 120,
                estimatedMinutes: 0
            )
            try makeDriver(fixture, clock: ResumeClock(now: pausedAt))
                .reconcileUsageGate(
                    ownerChildDeviceID: owner,
                    allowed: false,
                    runtime: resumeRuntime()
                )
            let generationID = try fixture.seedDesiredGeneration(
                usageDate: currentRuntime.usageDate,
                policyRevision: currentRuntime.policyRevision,
                poolMinutes: currentRuntime.dailyPoolMinutes,
                capMinutes: currentRuntime.deviceCapMinutes,
                now: nextDay
            )
            let staleRoute = try XCTUnwrap(
                try fixture.store.read().routes.values.first {
                    $0.generationID == generationID
                        && $0.usageDate == currentRuntime.usageDate
                        && $0.lifecycle == .planned
                }
            )
            try fixture.store.transaction(expectedOwner: owner) { state in
                state.routes[staleRoute.routeID]?.lifecycle = .active
                let installKey = try XCTUnwrap(
                    state.installWork.first {
                        $0.value.routeID == staleRoute.routeID
                    }?.key
                )
                state.installWork[installKey]?.phase = .dualActive
                state.installWork[installKey]?.retry.terminal = .succeeded
                for (key, var work) in state.registrationWork
                where work.routeID == staleRoute.routeID {
                    work.retry.terminal = .succeeded
                    state.registrationWork[key] = work
                }
                state.v2RouteHandoff = V2RouteHandoff(
                    handoffID: UUID(),
                    ownerChildDeviceID: owner,
                    fromGenerationID: try XCTUnwrap(state.activeGenerationID),
                    fromEpochID: fixture.oldEpochID,
                    fromRouteID: fixture.oldRouteID,
                    toGenerationID: generationID,
                    toEpochID: staleRoute.epochID,
                    toRouteID: staleRoute.routeID,
                    phase: phase,
                    priorRouteInputClosedAt:
                        phase == .cutoverReady ? nextDay : nil,
                    registrationAcknowledgedAt:
                        phase == .cutoverReady ? nextDay : nil,
                    activationAcknowledgedAt: nil,
                    priorStopAcknowledgedAt: nil,
                    createdAt: nextDay
                )
            }

            try makeDriver(
                fixture,
                clock: ResumeClock(now: nextDay.addingTimeInterval(1))
            ).reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: true,
                runtime: currentRuntime
            )

            let state = try fixture.store.read()
            XCTAssertNil(state.v2RouteHandoff, "phase \(phase)")
            XCTAssertEqual(
                state.routes[staleRoute.routeID]?.lifecycle,
                .tombstoned,
                "phase \(phase)"
            )
            XCTAssertEqual(
                state.epochs[staleRoute.epochID]?.retireReason,
                .activationSuperseded,
                "phase \(phase)"
            )
            XCTAssertNotNil(
                state.routes.values.first {
                    $0.routeID != staleRoute.routeID
                        && $0.generationID == generationID
                        && $0.usageDate == currentRuntime.usageDate
                        && $0.lifecycle == .planned
                        && state.epochs[$0.epochID]?.resumeBoundaryPending
                            == true
                },
                "phase \(phase)"
            )
        }
    }

    func testPausedPriorDayPreservesCutoverCandidateWhenActivationResponseMayBeLost() throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let pausedAt = start.addingTimeInterval(3_600)
        let nextDay = start.addingTimeInterval(86_400)
        let currentRuntime = EarnedTimeRuntime(
            usageDate: "2026-07-18",
            timezone: "America/New_York",
            policyRevision: "current-day",
            dailyPoolMinutes: 180,
            deviceCapMinutes: 120,
            remainingMinutes: 120,
            estimatedMinutes: 0
        )
        try makeDriver(fixture, clock: ResumeClock(now: pausedAt))
            .reconcileUsageGate(
                ownerChildDeviceID: owner,
                allowed: false,
                runtime: resumeRuntime()
            )
        let generationID = try fixture.seedDesiredGeneration(
            usageDate: currentRuntime.usageDate,
            policyRevision: currentRuntime.policyRevision,
            poolMinutes: currentRuntime.dailyPoolMinutes,
            capMinutes: currentRuntime.deviceCapMinutes,
            now: nextDay
        )
        let candidate = try XCTUnwrap(
            try fixture.store.read().routes.values.first {
                $0.generationID == generationID
                    && $0.usageDate == currentRuntime.usageDate
                    && $0.lifecycle == .planned
            }
        )
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.routes[candidate.routeID]?.lifecycle = .active
            let installKey = try XCTUnwrap(
                state.installWork.first {
                    $0.value.routeID == candidate.routeID
                }?.key
            )
            state.installWork[installKey]?.phase = .dualActive
            state.installWork[installKey]?.retry.terminal = .succeeded
            for (key, var work) in state.registrationWork
            where work.routeID == candidate.routeID {
                work.retry.terminal = .succeeded
                state.registrationWork[key] = work
            }
            let activationID = UUID()
            state.activationWork[activationID] = EpochActivationWork(
                workID: activationID,
                ownerChildDeviceID: owner,
                epochID: candidate.epochID,
                routeID: candidate.routeID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: owner,
                    routeID: candidate.routeID,
                    verifiedAt: nextDay
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 1,
                    nextAttemptAt: nextDay.addingTimeInterval(5),
                    lastErrorCode: "network_connection_lost",
                    terminal: .pending
                ),
                createdAt: nextDay
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: owner,
                fromGenerationID: try XCTUnwrap(state.activeGenerationID),
                fromEpochID: fixture.oldEpochID,
                fromRouteID: fixture.oldRouteID,
                toGenerationID: generationID,
                toEpochID: candidate.epochID,
                toRouteID: candidate.routeID,
                phase: .cutoverReady,
                priorRouteInputClosedAt: nextDay,
                registrationAcknowledgedAt: nextDay,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: nextDay
            )
        }

        try makeDriver(
            fixture,
            clock: ResumeClock(now: nextDay.addingTimeInterval(1))
        ).reconcileUsageGate(
            ownerChildDeviceID: owner,
            allowed: true,
            runtime: currentRuntime
        )

        let state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, candidate.routeID)
        XCTAssertEqual(state.routes[candidate.routeID]?.lifecycle, .active)
        XCTAssertNil(state.epochs[candidate.epochID]?.retiredAt)
        XCTAssertEqual(
            state.activationWork.values.first {
                $0.routeID == candidate.routeID
            }?.retry.terminal,
            .pending
        )
    }

    func testRegistrationObservesClosedGateAndPreservesPriorRouteForFreshResume() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let runtime = resumeRuntime()
        let clock = ResumeClock(now: start.addingTimeInterval(3_600))
        let candidate = try prepareCandidate(fixture, runtime: runtime, clock: clock)
        fixture.transport.results = [registrationResult(epochID: candidate.epochID, status: .paused)]

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.status, .paused)
        XCTAssertEqual(state.routes[candidate.routeID]?.lifecycle, .active)
        XCTAssertEqual(state.epochs[candidate.epochID]?.status, .paused)
        XCTAssertNil(state.epochs[candidate.epochID]?.retiredAt)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, candidate.routeID)
        XCTAssertEqual(
            state.registrationWork.values.filter {
                $0.routeID == candidate.routeID
            }.count,
            1
        )
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.routeID == candidate.routeID
            }?.retry.terminal,
            .succeeded
        )
        XCTAssertFalse(
            state.activationWork.values.contains {
                $0.routeID == candidate.routeID
            }
        )

        try makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(10)))
            .reconcileUsageGate(ownerChildDeviceID: owner, allowed: true, runtime: runtime)
        fixture.transport.results = [activationResult(epochID: candidate.epochID)]
        try await makeDriver(
            fixture,
            clock: ResumeClock(now: clock.now.addingTimeInterval(11))
        ).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(state.activeEpochID, candidate.epochID)
        XCTAssertEqual(state.routes[candidate.routeID]?.lifecycle, .active)
        XCTAssertEqual(state.epochs[candidate.epochID]?.status, .active)
        XCTAssertEqual(
            state.routes.values.filter {
                $0.ownerChildDeviceID == owner
                    && $0.usageDate == runtime.usageDate
                    && $0.routeID != fixture.oldRouteID
            }.map(\.routeID),
            [candidate.routeID]
        )
    }

    func testActivationObservesClosedGateAndPreservesPriorRouteForFreshResume() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let runtime = resumeRuntime()
        let clock = ResumeClock(now: start.addingTimeInterval(3_600))
        let candidate = try prepareCandidate(fixture, runtime: runtime, clock: clock)
        fixture.transport.results = [
            registrationResult(epochID: candidate.epochID),
            activationResult(
                epochID: candidate.epochID,
                status: .paused,
                epochStatus: .paused
            )
        ]

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.status, .paused)
        XCTAssertEqual(state.routes[candidate.routeID]?.lifecycle, .active)
        XCTAssertNil(state.epochs[candidate.epochID]?.retiredAt)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, candidate.routeID)
        XCTAssertEqual(
            state.activationWork.values.first {
                $0.routeID == candidate.routeID
            }?.retry.terminal,
            .pending
        )

        try makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(10)))
            .reconcileUsageGate(ownerChildDeviceID: owner, allowed: true, runtime: runtime)
        fixture.transport.results = [activationResult(epochID: candidate.epochID)]
        try await makeDriver(
            fixture,
            clock: ResumeClock(now: clock.now.addingTimeInterval(20))
        ).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(state.activeEpochID, candidate.epochID)
        XCTAssertEqual(
            state.registrationWork.values.filter {
                $0.routeID == candidate.routeID
            }.count,
            1
        )
        XCTAssertEqual(
            state.activationWork.values.filter {
                $0.routeID == candidate.routeID
            }.count,
            1
        )
    }

    func testLostRegistrationResponseRetriesSameConservativeCandidate() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let clock = ResumeClock(now: start.addingTimeInterval(3_600))
        let candidate = try prepareCandidate(fixture, runtime: resumeRuntime(), clock: clock)
        fixture.transport.failOnCalls = [1]
        fixture.transport.results = [
            registrationResult(epochID: candidate.epochID),
            activationResult(epochID: candidate.epochID)
        ]

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)
        var state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, candidate.routeID)
        XCTAssertEqual(
            state.registrationWork.values.first(where: { $0.routeID == candidate.routeID })?.retry.terminal,
            .pending
        )

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(11)))
            .recover(ownerChildDeviceID: owner)
        state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(state.registrationWork.values.filter { $0.routeID == candidate.routeID }.count, 1)
        XCTAssertEqual(state.activationWork.values.filter { $0.routeID == candidate.routeID }.count, 1)
    }

    func testLostActivationResponseAdoptsAlreadyActivatedConservativeCandidate() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let clock = ResumeClock(now: start.addingTimeInterval(3_600))
        let candidate = try prepareCandidate(fixture, runtime: resumeRuntime(), clock: clock)
        fixture.transport.failOnCalls = [2]
        fixture.transport.results = [
            registrationResult(epochID: candidate.epochID),
            activationResult(epochID: candidate.epochID, status: .alreadyActivated)
        ]

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)
        var state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, candidate.routeID)
        XCTAssertEqual(
            state.activationWork.values.first(where: { $0.routeID == candidate.routeID })?.retry.terminal,
            .pending
        )

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(11)))
            .recover(ownerChildDeviceID: owner)
        state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertEqual(state.activationWork.values.filter { $0.routeID == candidate.routeID }.count, 1)
    }

    private func prepareCandidate(
        _ fixture: ResumeFixture,
        runtime: EarnedTimeRuntime,
        clock: ResumeClock
    ) throws -> MeteringCallbackRoute {
        let driver = makeDriver(fixture, clock: clock)
        try driver.reconcileUsageGate(ownerChildDeviceID: owner, allowed: false, runtime: runtime)
        try driver.reconcileUsageGate(ownerChildDeviceID: owner, allowed: true, runtime: runtime)
        let state = try fixture.store.read()
        return try XCTUnwrap(state.routes.values.first {
            $0.routeID != fixture.oldRouteID && state.epochs[$0.epochID]?.resumeBoundaryPending == true
        })
    }

    private func resumeRuntime() -> EarnedTimeRuntime {
        EarnedTimeRuntime(
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            policyRevision: "resume",
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 43,
            estimatedMinutes: 17
        )
    }

    private func makeDriver(_ fixture: ResumeFixture, clock: ResumeClock) -> EarnedMeteringRecoveryDriver {
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: fixture.store,
            transport: fixture.transport,
            clock: clock,
            legacySuiteName: "resume-tests-\(UUID().uuidString)"
        )
        let identity = MeteringProcessIdentity(role: .app, instanceID: UUID())
        return EarnedMeteringRecoveryDriver(
            store: fixture.store,
            delivery: delivery,
            installer: DatedRouteInstaller(
                store: fixture.store,
                center: fixture.center,
                processIdentity: identity,
                clock: clock
            ),
            center: fixture.center,
            processIdentity: identity,
            clock: clock,
            resetRolloverEffect: { _, _ in }
        )
    }

    private func registrationResult(
        epochID: UUID,
        status: EpochStatusDTO = .active,
        usageDate: String = "2026-07-17",
        estimatedMinutes: Int = 17,
        capMinutes: Int = 60
    ) -> (Data, URLResponse) {
        let response = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot(
                usageDate: usageDate,
                estimatedMinutes: estimatedMinutes,
                capMinutes: capMinutes
            ),
            epochStatus: status
        )
        return (try! JSONEncoder().encode(response), httpResponse())
    }

    private func activationResult(
        epochID: UUID,
        status: EpochActivationStatusDTO = .activated,
        epochStatus: EpochStatusDTO = .active,
        usageDate: String = "2026-07-17",
        estimatedMinutes: Int = 17,
        capMinutes: Int = 60
    ) -> (Data, URLResponse) {
        let response = EpochActivationResponseDTO(
            status: status,
            epochID: epochID,
            epochStatus: epochStatus,
            meteringProtocolVersion: 2,
            snapshot: snapshot(
                usageDate: usageDate,
                estimatedMinutes: estimatedMinutes,
                capMinutes: capMinutes
            )
        )
        return (try! JSONEncoder().encode(response), httpResponse())
    }

    private func snapshot(
        usageDate: String = "2026-07-17",
        estimatedMinutes: Int = 17,
        capMinutes: Int = 60
    ) -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: usageDate,
            estimatedMinutes: estimatedMinutes,
            capMinutes: capMinutes,
            childDayState: "available",
            usedMinutes: estimatedMinutes,
            remainingMinutes: max(0, capMinutes - estimatedMinutes),
            counted: true,
            warning: nil
        )
    }

    private func httpResponse(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: baseURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

private struct ResumeClock: MeteringClock { let now: Date }

private final class ResumeTransport: MeteringHTTPTransport, @unchecked Sendable {
    var results: [(Data, URLResponse)] = []
    var failOnCalls: Set<Int> = []
    private var callCount = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        if failOnCalls.contains(callCount) { throw URLError(.networkConnectionLost) }
        guard !results.isEmpty else { throw URLError(.cannotConnectToHost) }
        return results.removeFirst()
    }
}

private nonisolated final class ResumeCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent])] = [:]
    var stopCalls: [[DeviceActivityName]] = []
    var activities: [DeviceActivityName] { Array(records.keys) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { records[activity]?.0 }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { records[activity]?.1 ?? [:] }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws { records[activity] = (schedule, events) }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        activities.forEach { records.removeValue(forKey: $0) }
    }
}

@MainActor
private final class ResumeFixture {
    let owner: UUID
    let start: Date
    let storeURL: URL
    let store: DeviceEpochStore
    let center = ResumeCenter()
    let transport = ResumeTransport()
    let oldEpochID: UUID
    let oldRouteID: UUID

    init(owner: UUID, start: Date) throws {
        self.owner = owner
        self.start = start
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-resume-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let selection = try JSONEncoder().encode(FamilyActivitySelection())
        let key = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "resume",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: UUID()
        )
        let plan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: key,
            persistedSelectionBytes: selection,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: start
        ))
        oldRouteID = try XCTUnwrap(plan.routeIDsByUsageDate["2026-07-17"])
        oldEpochID = try XCTUnwrap(try store.read().routes[oldRouteID]?.epochID)
        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = plan.generationID
            state.activeEpochID = oldEpochID
            state.activeRouteID = oldRouteID
            var route = try XCTUnwrap(state.routes[oldRouteID])
            route.lifecycle = .active
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[oldRouteID] = route
            state.epochs[oldEpochID]?.registeredAt = start
            let installID = try XCTUnwrap(state.installWork.first { $0.value.routeID == oldRouteID }?.key)
            state.installWork[installID]?.authorization = .registered
            state.installWork[installID]?.phase = .active
            state.installWork[installID]?.retry.terminal = .succeeded
            let registrationID = try XCTUnwrap(state.registrationWork.first { $0.value.routeID == oldRouteID }?.key)
            state.registrationWork[registrationID]?.retry.terminal = .succeeded
            state.ratchets[owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: start,
                dualActiveAt: start,
                activatedV2At: start
            )
        }
        let state = try store.read()
        let route = try XCTUnwrap(state.routes[oldRouteID])
        let schedule = try MeteringDatedSchedule.datedSchedule(
            usageDate: route.usageDate,
            timeZone: TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)!
        )
        let events = Dictionary(uniqueKeysWithValues: route.plannedEvents.map {
            (DeviceActivityEvent.Name($0.eventName), MeteringDatedSchedule.makeEvent(
                selection: FamilyActivitySelection(),
                thresholdMinutes: $0.thresholdMinutes
            ))
        })
        center.records[DeviceActivityName(route.activityName)] = (schedule, events)
    }

    func seedDesiredGeneration(
        usageDate: String,
        policyRevision: String,
        poolMinutes: Int,
        capMinutes: Int,
        now: Date
    ) throws -> UUID {
        let selection = try JSONEncoder().encode(FamilyActivitySelection())
        let enforcementSetID = UUID()
        let key = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: policyRevision,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: enforcementSetID
        )
        let plan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: usageDate,
            generationKey: key,
            persistedSelectionBytes: selection,
            poolMinutes: poolMinutes,
            deviceCapMinutes: capMinutes,
            authoritativeBaseAcceptedMinutes: 0,
            now: now
        ))
        _ = try store.ingestDesiredPolicy(MeteringDesiredPolicy(
            commandID: UUID(),
            ownerChildDeviceID: owner,
            orderingToken: 1,
            policyRevision: policyRevision,
            usageDate: usageDate,
            canonicalTimezone: "America/New_York",
            dailyPoolMinutes: poolMinutes,
            deviceCapMinutes: capMinutes,
            remainingMinutes: min(poolMinutes, capMinutes),
            enforcementSetID: enforcementSetID,
            receivedAt: now,
            appliedAt: nil,
            ackedAt: nil
        ))
        return plan.generationID
    }

    func cleanup() { try? FileManager.default.removeItem(at: storeURL) }
}
