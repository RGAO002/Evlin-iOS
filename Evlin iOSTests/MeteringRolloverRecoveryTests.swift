import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringRolloverRecoveryTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let start = Date(timeIntervalSince1970: 1_784_332_800)
    private var storeURL: URL!
    private var store: DeviceEpochStore!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-rollover-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { self.owner })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
        store = nil
        storeURL = nil
    }

    func testConcurrentRolloverTriggersAdoptOneExactOldNewTuple() throws {
        let fixture = try seedActiveAndReservedRoutes()

        let first = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        let firstBytes = try Data(contentsOf: storeURL)
        let second = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_430)
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: storeURL), firstBytes)
        let state = try store.read()
        let work = try XCTUnwrap(state.rolloverEffectsWork)
        XCTAssertEqual(work.workID, first)
        XCTAssertEqual(work.ownerChildDeviceID, owner)
        XCTAssertEqual(work.fromUsageDate, "2026-07-17")
        XCTAssertEqual(work.toUsageDate, "2026-07-18")
        XCTAssertEqual(work.oldEpochID, fixture.oldEpochID)
        XCTAssertEqual(work.newEpochID, fixture.newEpochID)
        XCTAssertEqual(work.oldRouteID, fixture.oldRouteID)
        XCTAssertEqual(work.newRouteID, fixture.newRouteID)
        XCTAssertEqual(state.activeEpochID, fixture.oldEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.routes[fixture.newRouteID]?.lifecycle, .planned)
    }

    func testElapsedTombstonedRolloverCannotBlockLaterRecovery() async throws {
        // iPad 2026-08-28: the 08-27 candidate had already been retired with
        // candidate_day_elapsed, but its parent rollover work remained pending.
        // Every recovery pass returned at that dead work and never reached the
        // current-day task-gate candidate.
        let fixture = try seedActiveAndReservedRoutes()
        let workID = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        try store.transaction(expectedOwner: owner) { state in
            var work = try XCTUnwrap(state.rolloverEffectsWork)
            work.earnedSourceResetAcknowledged = true
            work.perAppResetAcknowledged = true
            work.taskStateResetAcknowledged = true
            work.bypassExpiryAcknowledged = true
            work.installAcknowledged = true
            work.registrationAcknowledged = true
            state.rolloverEffectsWork = work
            state.v2RouteHandoff = nil
            state.routes[fixture.newRouteID]?.lifecycle = .tombstoned
            let retiredRoute = try XCTUnwrap(state.routes[fixture.newRouteID])
            state.epochs[fixture.newEpochID]?.status = .retired
            state.epochs[fixture.newEpochID]?.retiredAt = self.start.addingTimeInterval(2 * 86_400)
            state.epochs[fixture.newEpochID]?.retireReason = .activationSuperseded
            state.tombstones[fixture.newRouteID] = MeteringRouteTombstone(
                routeID: retiredRoute.routeID,
                activityName: retiredRoute.activityName,
                eventNames: retiredRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: retiredRoute.usageDate,
                epochID: retiredRoute.epochID,
                generationID: retiredRoute.generationID,
                canonicalDayEnd: self.start.addingTimeInterval(2 * 86_400),
                stopAcknowledgedAt: nil,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            let activationID = UUID()
            state.activationWork[activationID] = EpochActivationWork(
                workID: activationID,
                ownerChildDeviceID: owner,
                epochID: fixture.newEpochID,
                routeID: fixture.newRouteID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: owner,
                    routeID: fixture.newRouteID,
                    verifiedAt: self.start.addingTimeInterval(86_405)
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 2,
                    nextAttemptAt: self.start,
                    lastErrorCode: "candidate_day_elapsed",
                    terminal: .superseded
                ),
                createdAt: self.start.addingTimeInterval(86_405)
            )
        }

        let center = RolloverCenter()
        let transport = RolloverTransport(results: [])
        try await makeDriver(
            center: center,
            transport: transport,
            clock: RolloverClock(now: start.addingTimeInterval(2 * 86_400))
        ).recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertNotEqual(state.rolloverEffectsWork?.workID, workID)
        XCTAssertNotEqual(state.rolloverEffectsWork?.newRouteID, fixture.newRouteID)
        XCTAssertNotEqual(state.rolloverEffectsWork?.newEpochID, fixture.newEpochID)
    }

    func testCanonicalRolloverDoesNotCarryPriorRoutePhysicalOffset() throws {
        let fixture = try seedActiveAndReservedRoutes()
        try store.transaction(expectedOwner: owner) { state in
            state.routes[fixture.oldRouteID]?.physicalGenerationOffsetMinutes = 25
        }

        _ = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )

        let nextRoute = try XCTUnwrap(try store.read().routes[fixture.newRouteID])
        XCTAssertEqual(nextRoute.physicalGenerationOffsetMinutes ?? 0, 0)
    }

    // Regression (iPad, 2026-07-25): after a day rolled over, ANY later policy
    // change / per-app limit edit / reset replaces the active route. The next
    // midnight then found a completed rollover whose product was no longer the
    // live route and threw "completed rollover cannot advance to the next day"
    // — every 10s, silently — so the device stayed on the old, already
    // exhausted day forever. A finished rollover is history and must never
    // block the following day.
    func testCompletedRolloverDoesNotBlockNextDayAfterActiveRouteWasReplaced() throws {
        let fixture = try seedActiveAndReservedRoutes()
        let firstWorkID = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        // Complete it, then simulate the churn: the rollover's product is no
        // longer the active route/epoch and its handoff is long gone.
        try store.transaction(expectedOwner: owner) { state in
            var work = try XCTUnwrap(state.rolloverEffectsWork)
            work.retry = MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: self.start,
                lastErrorCode: nil,
                terminal: .succeeded
            )
            work.oldStopAcknowledged = true
            state.rolloverEffectsWork = work
            state.v2RouteHandoff = nil
            state.routes[fixture.oldRouteID]?.lifecycle = .retired
            state.routes[fixture.newRouteID]?.lifecycle = .active
            state.activeRouteID = fixture.newRouteID
            state.activeEpochID = fixture.newEpochID
        }

        let secondWorkID = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-19",
            now: start.addingTimeInterval(2 * 86_400)
        )

        XCTAssertNotEqual(secondWorkID, firstWorkID, "a new day needs a new rollover")
        let work = try XCTUnwrap(try store.read().rolloverEffectsWork)
        XCTAssertEqual(work.workID, secondWorkID)
        XCTAssertEqual(work.fromUsageDate, "2026-07-18")
        XCTAssertEqual(work.toUsageDate, "2026-07-19")
    }

    func testCommittedReplacementWithPendingPriorStopDoesNotBlockNextDayRollover() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        let initial = try store.read()
        let oldRoute = try XCTUnwrap(initial.routes[fixture.oldRouteID])
        let activeRoute = try XCTUnwrap(initial.routes[fixture.newRouteID])
        let tomorrowRoute = try XCTUnwrap(initial.routes.values.first {
            $0.generationID == activeRoute.generationID
                && $0.usageDate == "2026-07-19"
        })
        let oldInstallID = try XCTUnwrap(
            initial.installWork.first {
                $0.value.routeID == oldRoute.routeID
            }?.key
        )
        let activeInstallID = try XCTUnwrap(
            initial.installWork.first {
                $0.value.routeID == activeRoute.routeID
            }?.key
        )
        let handoffID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state.routes[activeRoute.routeID]?.lifecycle = .active
            state.installWork[activeInstallID]?.authorization = .registered
            state.installWork[activeInstallID]?.phase = .dualActive
            state.installWork[activeInstallID]?.retry.terminal = .succeeded
            for (key, var work) in state.registrationWork
            where work.routeID == activeRoute.routeID {
                work.retry.terminal = .succeeded
                state.registrationWork[key] = work
            }
            let activationID = UUID()
            state.activationWork[activationID] = EpochActivationWork(
                workID: activationID,
                ownerChildDeviceID: owner,
                epochID: activeRoute.epochID,
                routeID: activeRoute.routeID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: owner,
                    routeID: activeRoute.routeID,
                    verifiedAt: start.addingTimeInterval(86_405)
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 1,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .succeeded
                ),
                createdAt: start.addingTimeInterval(86_405)
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: handoffID,
                ownerChildDeviceID: owner,
                fromGenerationID: oldRoute.generationID,
                fromEpochID: oldRoute.epochID,
                fromRouteID: oldRoute.routeID,
                toGenerationID: activeRoute.generationID,
                toEpochID: activeRoute.epochID,
                toRouteID: activeRoute.routeID,
                phase: .cutoverReady,
                priorRouteInputClosedAt: start.addingTimeInterval(86_400),
                registrationAcknowledgedAt: start.addingTimeInterval(86_405),
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: start.addingTimeInterval(86_400)
            )
        }
        try store.transaction(expectedOwner: owner) { state in
            state.activeEpochID = activeRoute.epochID
            state.activeRouteID = activeRoute.routeID
            state.routes[oldRoute.routeID]?.lifecycle = .tombstoned
            state.routes[activeRoute.routeID]?.lifecycle = .active
            state.epochs[oldRoute.epochID]?.status = .retired
            state.epochs[oldRoute.epochID]?.retiredAt = start.addingTimeInterval(86_410)
            state.epochs[oldRoute.epochID]?.retireReason = .policyChange
            state.epochs[activeRoute.epochID]?.status = .active
            state.epochs[activeRoute.epochID]?.registeredAt = start.addingTimeInterval(86_405)
            state.installWork[oldInstallID]?.phase = .pendingStop
            state.installWork[activeInstallID]?.authorization = .registered
            state.installWork[activeInstallID]?.phase = .active
            state.installWork[activeInstallID]?.retry.terminal = .succeeded
            state.tombstones[oldRoute.routeID] = MeteringRouteTombstone(
                routeID: oldRoute.routeID,
                activityName: oldRoute.activityName,
                eventNames: oldRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: oldRoute.usageDate,
                epochID: oldRoute.epochID,
                generationID: oldRoute.generationID,
                canonicalDayEnd: start.addingTimeInterval(86_400),
                stopAcknowledgedAt: nil,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            var handoff = try XCTUnwrap(state.v2RouteHandoff)
            handoff.phase = .committed
            handoff.activationAcknowledgedAt = start.addingTimeInterval(86_405)
            state.v2RouteHandoff = handoff
        }

        let center = RolloverCenter()
        center.preserveActivitiesWhenStopped = true
        center.seed(DeviceActivityName(oldRoute.activityName))
        center.seed(DeviceActivityName(activeRoute.activityName))
        center.seed(DeviceActivityName(tomorrowRoute.activityName))
        let transport = RolloverTransport(results: [])

        try await makeDriver(
            center: center,
            transport: transport,
            clock: RolloverClock(now: start.addingTimeInterval(2 * 86_400 + 30))
        ).recover(ownerChildDeviceID: owner)
        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertEqual(try store.read().rolloverEffectsWork?.retry.terminal, .pending)
        XCTAssertTrue(
            center.stopCalls.contains([DeviceActivityName(oldRoute.activityName)]),
            "network failure must not starve detached predecessor cleanup"
        )

        center.stopCalls.removeAll()
        transport.results = [
            registrationResult(
                epochID: tomorrowRoute.epochID,
                usageDate: tomorrowRoute.usageDate
            ),
            activationResult(
                epochID: tomorrowRoute.epochID,
                usageDate: tomorrowRoute.usageDate
            )
        ]
        try await makeDriver(
            center: center,
            transport: transport,
            clock: RolloverClock(now: start.addingTimeInterval(2 * 86_400 + 35))
        ).recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertEqual(
            state.activeRouteID,
            tomorrowRoute.routeID,
            "handoff=\(String(describing: state.v2RouteHandoff)) "
                + "rollover=\(String(describing: state.rolloverEffectsWork)) "
                + "requests=\(transport.requests.map(\.url?.path))"
        )
        XCTAssertEqual(state.routes[tomorrowRoute.routeID]?.lifecycle, .active)
        XCTAssertNotEqual(state.v2RouteHandoff?.handoffID, handoffID)
        XCTAssertEqual(state.installWork[oldInstallID]?.phase, .pendingStop)
        XCTAssertNil(state.tombstones[oldRoute.routeID]?.stopAcknowledgedAt)
        XCTAssertTrue(
            center.stopCalls.contains([DeviceActivityName(oldRoute.activityName)]),
            "old committed predecessor cleanup must run independently of rollover"
        )
    }

    func testRolloverRejectsSkippingAReservedCanonicalDayByteIdentically() throws {
        _ = try seedActiveAndReservedRoutes()
        let before = try Data(contentsOf: storeURL)

        XCTAssertThrowsError(try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-19",
            now: start.addingTimeInterval(86_400)
        ))
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }

    func testColdReopenAfterCanonicalMidnightPreparesAndCompletesRollover() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        let initial = try store.read()
        let center = RolloverCenter()
        center.seed(DeviceActivityName(try XCTUnwrap(initial.routes[fixture.oldRouteID]?.activityName)))
        center.seed(DeviceActivityName(try XCTUnwrap(initial.routes[fixture.newRouteID]?.activityName)))
        let transport = RolloverTransport(results: [
            registrationResult(epochID: fixture.newEpochID),
            activationResult(epochID: fixture.newEpochID)
        ])
        let clock = RolloverClock(now: start.addingTimeInterval(86_430))
        let driver = makeDriver(center: center, transport: transport, clock: clock)

        try await driver.recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertEqual(state.rolloverEffectsWork?.fromUsageDate, "2026-07-17")
        XCTAssertEqual(state.rolloverEffectsWork?.toUsageDate, "2026-07-18")
        XCTAssertEqual(state.rolloverEffectsWork?.retry.terminal, .succeeded)
        XCTAssertEqual(state.activeEpochID, fixture.newEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
    }

    func testPausedEpochStillRegistersCurrentDayAndActivatesAfterGateReopens() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        let initial = try store.read()
        let oldName = DeviceActivityName(
            try XCTUnwrap(initial.routes[fixture.oldRouteID]?.activityName)
        )
        let newName = DeviceActivityName(
            try XCTUnwrap(initial.routes[fixture.newRouteID]?.activityName)
        )
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[fixture.oldEpochID]?.status = .paused
        }
        let center = RolloverCenter()
        center.seed(oldName)
        center.seed(newName)
        let pausedRegistration = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: fixture.newEpochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot(),
            epochStatus: .paused
        )
        let pausedActivation = EpochActivationResponseDTO(
            status: .paused,
            epochID: fixture.newEpochID,
            epochStatus: .paused,
            meteringProtocolVersion: 2,
            snapshot: snapshot()
        )
        let transport = RolloverTransport(results: [
            (try JSONEncoder().encode(pausedRegistration), httpResponse(status: 200)),
            (try JSONEncoder().encode(pausedActivation), httpResponse(status: 200)),
        ])
        let clock = RolloverClock(now: start.addingTimeInterval(86_430))

        try await makeDriver(center: center, transport: transport, clock: clock)
            .recover(ownerChildDeviceID: owner)

        var state = try store.read()
        let work = try XCTUnwrap(state.rolloverEffectsWork)
        XCTAssertEqual(work.fromUsageDate, "2026-07-17")
        XCTAssertEqual(work.toUsageDate, "2026-07-18")
        XCTAssertTrue(
            state.registrationWork.values.contains {
                $0.epochID == fixture.newEpochID
                    && $0.routeID == fixture.newRouteID
                    && $0.request.reason == .dayRollover
                    && $0.retry.terminal == .succeeded
            },
            "a closed gate may pause today's epoch, but must not leave the day without a registered identity"
        )
        XCTAssertTrue(
            state.activationWork.values.contains {
                $0.epochID == fixture.newEpochID
                    && $0.routeID == fixture.newRouteID
                    && $0.retry.terminal == .pending
                    && $0.retry.lastErrorCode == "epoch_paused"
            },
            "activations=\(state.activationWork.values.map { ($0.epochID, $0.routeID, $0.retry) })"
        )
        XCTAssertEqual(state.activeEpochID, fixture.oldEpochID)

        transport.results = [
            activationResult(epochID: fixture.newEpochID),
        ]
        try await makeDriver(
            center: center,
            transport: transport,
            clock: RolloverClock(now: clock.now.addingTimeInterval(5))
        ).recover(ownerChildDeviceID: owner)

        state = try store.read()
        XCTAssertEqual(state.activeEpochID, fixture.newEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
        XCTAssertEqual(state.rolloverEffectsWork?.retry.terminal, .succeeded)
    }

    func testRolloverActivationKeepsExactPriorAuthorityAfterHorizonAdvances() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        let seeded = try store.read()
        let generation = try XCTUnwrap(seeded.generations[seeded.activeGenerationID!])
        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-18",
            generationKey: MeteringGenerationKey(
                protocolVersion: generation.protocolVersion,
                childDeviceID: owner,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID
            ),
            persistedSelectionBytes: generation.measurementSelectionBytes,
            poolMinutes: try XCTUnwrap(generation.configuredPoolMinutes),
            deviceCapMinutes: try XCTUnwrap(generation.configuredDeviceCapMinutes),
            authoritativeBaseAcceptedMinutes: 0,
            now: start.addingTimeInterval(86_430)
        ))
        let expanded = try store.read()
        XCTAssertEqual(
            Set(expanded.routes.values.filter {
                $0.generationID == generation.generationID
            }.map(\.usageDate)).count,
            MeteringHorizonPlanner.dateCount + 1
        )
        let center = RolloverCenter()
        center.seed(DeviceActivityName(try XCTUnwrap(expanded.routes[fixture.oldRouteID]?.activityName)))
        center.seed(DeviceActivityName(try XCTUnwrap(expanded.routes[fixture.newRouteID]?.activityName)))
        let transport = RolloverTransport(results: [
            registrationResult(epochID: fixture.newEpochID),
            activationResult(epochID: fixture.newEpochID)
        ])

        try await makeDriver(
            center: center,
            transport: transport,
            clock: RolloverClock(now: start.addingTimeInterval(86_430))
        ).recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
        XCTAssertEqual(state.rolloverEffectsWork?.retry.terminal, .succeeded)
    }

    func testMidnightAbandonsFailedSameDayCandidateBeforeStartingRollover() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        let initial = try store.read()
        let priorRoute = try XCTUnwrap(initial.routes[fixture.oldRouteID])
        let priorGeneration = try XCTUnwrap(initial.generations[priorRoute.generationID])
        let candidateKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: priorGeneration.canonicalTimezone,
            policyRevision: "stale-same-day-candidate",
            measurementSelectionDigest: priorGeneration.measurementSelectionDigest,
            enforcementSetID: priorGeneration.enforcementSetID
        )
        let candidatePlan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: candidateKey,
            persistedSelectionBytes: priorGeneration.measurementSelectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: start.addingTimeInterval(3_600)
        ))
        let candidateRouteID = try XCTUnwrap(
            candidatePlan.routeIDsByUsageDate["2026-07-17"]
        )
        let candidateState = try store.read()
        let candidateRoute = try XCTUnwrap(candidateState.routes[candidateRouteID])
        let candidateEpochID = candidateRoute.epochID
        let candidateInstallID = try XCTUnwrap(
            candidateState.installWork.first {
                $0.value.routeID == candidateRouteID
            }?.key
        )
        let candidateRegistrationID = try XCTUnwrap(
            candidateState.registrationWork.first {
                $0.value.routeID == candidateRouteID
            }?.key
        )
        let staleHandoffID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            var installed = try XCTUnwrap(state.routes[candidateRouteID])
            installed.lifecycle = .active
            installed.installedSchedule = installed.plannedSchedule
            installed.installedEvents = installed.plannedEvents
            state.routes[candidateRouteID] = installed
            state.epochs[candidateEpochID]?.registeredAt = start.addingTimeInterval(3_605)
            state.installWork[candidateInstallID]?.authorization = .registered
            state.installWork[candidateInstallID]?.phase = .dualActive
            state.installWork[candidateInstallID]?.retry.terminal = .succeeded
            state.registrationWork[candidateRegistrationID]?.retry.terminal = .succeeded
            let activationID = UUID()
            state.activationWork[activationID] = EpochActivationWork(
                workID: activationID,
                ownerChildDeviceID: owner,
                epochID: candidateEpochID,
                routeID: candidateRouteID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: owner,
                    routeID: candidateRouteID,
                    verifiedAt: start.addingTimeInterval(3_606)
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(3_606),
                    lastErrorCode: "route_superseded",
                    terminal: .superseded
                ),
                createdAt: start.addingTimeInterval(3_606)
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: staleHandoffID,
                ownerChildDeviceID: owner,
                fromGenerationID: priorRoute.generationID,
                fromEpochID: fixture.oldEpochID,
                fromRouteID: fixture.oldRouteID,
                toGenerationID: candidatePlan.generationID,
                toEpochID: candidateEpochID,
                toRouteID: candidateRouteID,
                phase: .cutoverReady,
                priorRouteInputClosedAt: start.addingTimeInterval(3_606),
                registrationAcknowledgedAt: start.addingTimeInterval(3_605),
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: start.addingTimeInterval(3_600)
            )
        }

        let center = RolloverCenter()
        center.seed(DeviceActivityName(priorRoute.activityName))
        center.seed(DeviceActivityName(candidateRoute.activityName))
        let transport = RolloverTransport(results: [
            registrationResult(epochID: fixture.newEpochID),
            activationResult(epochID: fixture.newEpochID)
        ])

        try await makeDriver(
            center: center,
            transport: transport,
            clock: RolloverClock(now: start.addingTimeInterval(86_430))
        ).recover(ownerChildDeviceID: owner)

        let final = try store.read()
        XCTAssertEqual(final.activeRouteID, fixture.newRouteID)
        XCTAssertEqual(final.rolloverEffectsWork?.retry.terminal, .succeeded)
        XCTAssertNotEqual(final.routes[candidateRouteID]?.lifecycle, .active)
        XCTAssertFalse(center.activities.contains(DeviceActivityName(candidateRoute.activityName)))
        XCTAssertFalse(final.registrationWork.values.contains {
            $0.routeID == candidateRouteID && $0.retry.terminal == .pending
        })
        XCTAssertFalse(final.activationWork.values.contains {
            $0.routeID == candidateRouteID && $0.retry.terminal == .pending
        })
        XCTAssertFalse(final.sampleWork.values.contains {
            $0.routeID == candidateRouteID && $0.retry.terminal == .pending
        })
        XCTAssertNotEqual(final.v2RouteHandoff?.handoffID, staleHandoffID)
    }

    func testColdReopenRepairsLegacySupersededNewDayInstallBeforeRollover() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        try store.transaction(expectedOwner: owner) { state in
            let installID = try XCTUnwrap(
                state.installWork.first(where: {
                    $0.value.routeID == fixture.newRouteID
                })?.key
            )
            state.installWork[installID]?.phase = .pendingStart
            state.installWork[installID]?.claim = nil
            state.installWork[installID]?.retry.terminal = .superseded
            state.installWork[installID]?.retry.lastErrorCode = "route_superseded"
        }
        let initial = try store.read()
        let center = RolloverCenter()
        center.seed(DeviceActivityName(try XCTUnwrap(initial.routes[fixture.oldRouteID]?.activityName)))
        let transport = RolloverTransport(results: [
            registrationResult(epochID: fixture.newEpochID),
            activationResult(epochID: fixture.newEpochID)
        ])
        let clock = RolloverClock(now: start.addingTimeInterval(86_430))

        try await makeDriver(center: center, transport: transport, clock: clock)
            .recover(ownerChildDeviceID: owner)

        let state = try store.read()
        let install = try XCTUnwrap(
            state.installWork.values.first { $0.routeID == fixture.newRouteID }
        )
        XCTAssertEqual(install.retry.terminal, .pending)
        XCTAssertNil(install.retry.lastErrorCode)
        XCTAssertEqual(state.rolloverEffectsWork?.retry.terminal, .succeeded)
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
    }

    func testRecoveryActivatesNewDayBeforeRetiringAndStoppingOldRoute() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        try store.transaction(expectedOwner: owner) { state in
            let epoch = try XCTUnwrap(state.epochs[fixture.newEpochID])
            state.epochs[fixture.newEpochID] = epochReplacingStartedAt(epoch, with: start)
        }
        _ = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        let center = RolloverCenter()
        let initial = try store.read()
        center.seed(DeviceActivityName(try XCTUnwrap(initial.routes[fixture.oldRouteID]?.activityName)))
        center.seed(DeviceActivityName(try XCTUnwrap(initial.routes[fixture.newRouteID]?.activityName)))
        let transport = RolloverTransport(results: [
            registrationResult(epochID: fixture.newEpochID),
            activationResult(epochID: fixture.newEpochID)
        ])
        var resetEffects: [MeteringRolloverLocalEffect] = []
        let clock = RolloverClock(now: start.addingTimeInterval(86_430))
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            transport: transport,
            clock: clock,
            legacySuiteName: "rollover-tests-\(UUID().uuidString)"
        )
        let installer = DatedRouteInstaller(
            store: store,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock
        )
        let driver = EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: installer,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock,
            resetRolloverEffect: { effect, _ in resetEffects.append(effect) }
        )

        try await driver.recover(ownerChildDeviceID: owner)

        let state = try store.read()
        let work = try XCTUnwrap(state.rolloverEffectsWork)
        XCTAssertEqual(Set(resetEffects), Set(MeteringRolloverLocalEffect.allCases))
        XCTAssertTrue(work.earnedSourceResetAcknowledged)
        XCTAssertTrue(work.perAppResetAcknowledged)
        XCTAssertTrue(work.taskStateResetAcknowledged)
        XCTAssertTrue(work.bypassExpiryAcknowledged)
        XCTAssertTrue(
            work.registrationAcknowledged,
            "requests=\(transport.requests.map(\.url?.path)) registrations=\(state.registrationWork.mapValues { $0.retry.terminal }) handoff=\(String(describing: state.v2RouteHandoff))"
        )
        XCTAssertTrue(work.installAcknowledged)
        XCTAssertTrue(work.activationAcknowledged)
        XCTAssertTrue(work.oldStopAcknowledged)
        XCTAssertEqual(work.retry.terminal, .succeeded)
        XCTAssertEqual(state.activeEpochID, fixture.newEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
        XCTAssertEqual(state.routes[fixture.newRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.retireReason, .dayRollover)
        XCTAssertEqual(center.stopCalls, [[DeviceActivityName(try XCTUnwrap(initial.routes[fixture.oldRouteID]?.activityName))]])
        let tombstone = try XCTUnwrap(state.tombstones[fixture.oldRouteID])
        let stopAt = try XCTUnwrap(tombstone.stopAcknowledgedAt)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(tombstone.retainedUntil),
            max(tombstone.canonicalDayEnd.addingTimeInterval(48 * 3_600), stopAt.addingTimeInterval(24 * 3_600))
        )
        XCTAssertEqual(transport.requests.map(\.url?.path), [
            "/api/v1/child/earned-time/epochs",
            "/api/v1/child/earned-time/epochs/\(fixture.newEpochID.uuidString.lowercased())/activation"
        ])
        let registrationBody = try XCTUnwrap(transport.requests.first?.httpBody)
        let registrationDecoder = JSONDecoder()
        registrationDecoder.dateDecodingStrategy = .iso8601
        let registration = try registrationDecoder.decode(
            EpochRegistrationRequestDTO.self,
            from: registrationBody
        )
        XCTAssertEqual(registration.usageDate, "2026-07-18")
        XCTAssertEqual(
            MeteringEpochContract.canonicalUsageDate(
                at: registration.startedAt,
                timezoneIdentifier: registration.timezone
            ),
            registration.usageDate,
            "day-rollover registration must not reuse the prior day's horizon-planning timestamp"
        )
        XCTAssertEqual(
            state.epochs[fixture.newEpochID]?.startedAt,
            registration.startedAt,
            "a successful registration must repair the local epoch start used for physical validation"
        )

        let nextWorkID = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-19",
            now: start.addingTimeInterval(2 * 86_400)
        )
        let nextState = try store.read()
        XCTAssertNotEqual(nextWorkID, work.workID)
        XCTAssertEqual(nextState.rolloverEffectsWork?.oldEpochID, fixture.newEpochID)
        XCTAssertEqual(nextState.rolloverEffectsWork?.oldRouteID, fixture.newRouteID)
        XCTAssertEqual(nextState.rolloverEffectsWork?.toUsageDate, "2026-07-19")
        XCTAssertNil(nextState.v2RouteHandoff)
    }

    func testColdRecoveryRepairsPersistedEpochStartFromSucceededRegistration() throws {
        let fixture = try seedActiveAndReservedRoutes()
        let stateBefore = try store.read()
        let registration = try XCTUnwrap(
            stateBefore.registrationWork.values.first {
                $0.routeID == fixture.oldRouteID && $0.retry.terminal == .succeeded
            }
        )
        try store.transaction(expectedOwner: owner) { state in
            let epoch = try XCTUnwrap(state.epochs[fixture.oldEpochID])
            state.epochs[fixture.oldEpochID] = epochReplacingStartedAt(
                epoch,
                with: registration.request.startedAt.addingTimeInterval(-3_600)
            )
        }

        XCTAssertTrue(
            try store.reconcileEpochStartsFromSuccessfulRegistrations(owner: owner)
        )
        XCTAssertEqual(
            try store.read().epochs[fixture.oldEpochID]?.startedAt,
            registration.request.startedAt
        )
        XCTAssertFalse(
            try store.reconcileEpochStartsFromSuccessfulRegistrations(owner: owner),
            "the cold-start repair must be idempotent"
        )
    }

    func testOldAndNewCallbacksStayDateIsolatedAcrossRolloverBarrier() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        _ = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        let initial = try store.read()
        let oldRoute = try XCTUnwrap(initial.routes[fixture.oldRouteID])
        let newRoute = try XCTUnwrap(initial.routes[fixture.newRouteID])
        let center = RolloverCenter()
        center.seed(DeviceActivityName(oldRoute.activityName))
        center.seed(DeviceActivityName(newRoute.activityName))
        let transport = RolloverTransport(results: [sampleResult(usageDate: "2026-07-17")])
        let clock = RolloverClock(now: start.addingTimeInterval(86_430))
        let callback = EarnedMeteringCallback(store: store, clock: clock)
        let oldEvent = try XCTUnwrap(oldRoute.plannedEvents.first)

        let oldOutcome = try callback.handle(
            MeteringAppleCallback(
                activityName: oldRoute.activityName,
                eventName: oldEvent.eventName,
                observedAt: start.addingTimeInterval(3_600)
            ),
            expectedOwnerChildDeviceID: owner
        )
        guard case .queued = oldOutcome else { return XCTFail("old callback was not queued") }

        try await makeDriver(center: center, transport: transport, clock: clock)
            .recover(ownerChildDeviceID: owner)

        var state = try store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .dualV2)
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(
            state.sampleWork.values.first(where: { $0.routeID == fixture.oldRouteID })?.request.usageDate,
            "2026-07-17"
        )
        XCTAssertFalse(state.sampleWork.values.contains {
            $0.routeID == fixture.oldRouteID && $0.retry.terminal == .pending
        })

        let newEvent = try XCTUnwrap(newRoute.plannedEvents.first)
        let newOutcome = try callback.handle(
            MeteringAppleCallback(
                activityName: newRoute.activityName,
                eventName: newEvent.eventName,
                observedAt: start.addingTimeInterval(90_000)
            ),
            expectedOwnerChildDeviceID: owner
        )
        guard case .queued = newOutcome else { return XCTFail("new callback was not queued") }
        transport.results = [
            registrationResult(epochID: fixture.newEpochID),
            activationResult(epochID: fixture.newEpochID),
            sampleResult(usageDate: "2026-07-18")
        ]

        try await makeDriver(center: center, transport: transport, clock: clock)
            .recover(ownerChildDeviceID: owner)

        state = try store.read()
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
        XCTAssertEqual(
            state.sampleWork.values.first(where: { $0.routeID == fixture.newRouteID })?.request.usageDate,
            "2026-07-18"
        )
        XCTAssertFalse(state.sampleWork.values.contains { $0.retry.terminal == .pending })
        XCTAssertEqual(
            try callback.handle(
                MeteringAppleCallback(
                    activityName: oldRoute.activityName,
                    eventName: oldEvent.eventName,
                    observedAt: start.addingTimeInterval(90_100)
                ),
                expectedOwnerChildDeviceID: owner
            ),
            .discarded(reason: "tombstoned_route")
        )
    }

    func testLostActivationResponseResumesSameRolloverWithoutEarlyOldStop() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        let workID = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        let stateBefore = try store.read()
        let oldName = DeviceActivityName(try XCTUnwrap(stateBefore.routes[fixture.oldRouteID]?.activityName))
        let newName = DeviceActivityName(try XCTUnwrap(stateBefore.routes[fixture.newRouteID]?.activityName))
        let center = RolloverCenter()
        center.seed(oldName)
        center.seed(newName)
        let transport = RolloverTransport(results: [registrationResult(epochID: fixture.newEpochID)])
        var resetEffects: [MeteringRolloverLocalEffect] = []
        let firstClock = RolloverClock(now: start.addingTimeInterval(86_430))

        try await makeDriver(
            center: center,
            transport: transport,
            clock: firstClock,
            resetRolloverEffect: { effect, _ in resetEffects.append(effect) }
        ).recover(ownerChildDeviceID: owner)

        var state = try store.read()
        XCTAssertEqual(state.rolloverEffectsWork?.workID, workID)
        XCTAssertTrue(state.rolloverEffectsWork?.registrationAcknowledged == true)
        XCTAssertFalse(state.rolloverEffectsWork?.activationAcknowledged == true)
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .active)
        XCTAssertTrue(center.stopCalls.isEmpty)
        XCTAssertEqual(
            try store.prepareCanonicalRollover(
                owner: owner,
                toUsageDate: "2026-07-18",
                now: firstClock.now.addingTimeInterval(1)
            ),
            workID
        )

        transport.results = [activationResult(epochID: fixture.newEpochID)]
        let retryClock = RolloverClock(now: firstClock.now.addingTimeInterval(5))
        try await makeDriver(
            center: center,
            transport: transport,
            clock: retryClock,
            resetRolloverEffect: { effect, _ in resetEffects.append(effect) }
        ).recover(ownerChildDeviceID: owner)

        state = try store.read()
        XCTAssertEqual(state.rolloverEffectsWork?.workID, workID)
        XCTAssertEqual(state.rolloverEffectsWork?.retry.terminal, .succeeded)
        XCTAssertEqual(state.activeRouteID, fixture.newRouteID)
        XCTAssertEqual(center.stopCalls, [[oldName]])
        XCTAssertEqual(resetEffects.count, MeteringRolloverLocalEffect.allCases.count)
    }

    func testTerminalRolloverRegistrationIsNotRemintedOnEveryRecoveryPass() async throws {
        let fixture = try seedActiveAndReservedRoutes()
        _ = try store.prepareCanonicalRollover(
            owner: owner,
            toUsageDate: "2026-07-18",
            now: start.addingTimeInterval(86_400)
        )
        let initial = try store.read()
        let center = RolloverCenter()
        center.seed(DeviceActivityName(
            try XCTUnwrap(initial.routes[fixture.oldRouteID]?.activityName)
        ))
        center.seed(DeviceActivityName(
            try XCTUnwrap(initial.routes[fixture.newRouteID]?.activityName)
        ))
        let transport = RolloverTransport(results: [
            (
                Data(#"{"detail":"policy_revision_mismatch"}"#.utf8),
                httpResponse(status: 409)
            ),
        ])
        let clock = RolloverClock(now: start.addingTimeInterval(86_430))
        let driver = makeDriver(
            center: center,
            transport: transport,
            clock: clock
        )

        try await driver.recover(ownerChildDeviceID: owner)
        let afterRejection = try store.read()
        let firstRegistrations = afterRejection.registrationWork.values.filter {
            $0.epochID == fixture.newEpochID && $0.routeID == fixture.newRouteID
        }
        XCTAssertEqual(firstRegistrations.count, 1)
        XCTAssertTrue(firstRegistrations.allSatisfy { $0.retry.terminal != .pending })

        try await driver.recover(ownerChildDeviceID: owner)
        let afterRetryPass = try store.read()
        XCTAssertEqual(
            afterRetryPass.registrationWork.values.filter {
                $0.epochID == fixture.newEpochID && $0.routeID == fixture.newRouteID
            }.count,
            1,
            "a terminal registration is immutable history; minting a new work ID for the same rollover tuple creates a 10-second hot loop"
        )
    }

    private func seedActiveAndReservedRoutes() throws -> (
        oldEpochID: UUID,
        oldRouteID: UUID,
        newEpochID: UUID,
        newRouteID: UUID
    ) {
        let selection = try JSONEncoder().encode(FamilyActivitySelection())
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "rollover",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selection
            ),
            enforcementSetID: UUID()
        )
        let plan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: generationKey,
            persistedSelectionBytes: selection,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: start
        ))
        let oldRouteID = try XCTUnwrap(plan.routeIDsByUsageDate["2026-07-17"])
        let newRouteID = try XCTUnwrap(plan.routeIDsByUsageDate["2026-07-18"])
        let initial = try store.read()
        let oldEpochID = try XCTUnwrap(initial.routes[oldRouteID]?.epochID)
        let newEpochID = try XCTUnwrap(initial.routes[newRouteID]?.epochID)
        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = plan.generationID
            state.activeEpochID = oldEpochID
            state.activeRouteID = oldRouteID
            state.routes[oldRouteID]?.lifecycle = .active
            state.epochs[oldEpochID]?.registeredAt = start
            let oldInstallID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == oldRouteID })?.key
            )
            state.installWork[oldInstallID]?.authorization = .registered
            state.installWork[oldInstallID]?.phase = .active
            state.installWork[oldInstallID]?.retry.terminal = .succeeded
            let oldRegistrationID = try XCTUnwrap(
                state.registrationWork.first(where: { $0.value.routeID == oldRouteID })?.key
            )
            state.registrationWork[oldRegistrationID]?.retry.terminal = .succeeded
            let newInstallID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == newRouteID })?.key
            )
            var installedRoute = try XCTUnwrap(state.routes[newRouteID])
            installedRoute.installedSchedule = installedRoute.plannedSchedule
            installedRoute.installedEvents = installedRoute.plannedEvents
            state.routes[newRouteID] = installedRoute
            state.installWork[newInstallID]?.phase = .verified
            state.installWork[newInstallID]?.retry.terminal = .succeeded
            state.ratchets[owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: start,
                dualActiveAt: start,
                activatedV2At: start
            )
        }
        return (oldEpochID, oldRouteID, newEpochID, newRouteID)
    }

    private func registrationResult(
        epochID: UUID,
        usageDate: String = "2026-07-18"
    ) -> (Data, URLResponse) {
        let response = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot(usageDate: usageDate),
            epochStatus: .active
        )
        return (try! JSONEncoder().encode(response), httpResponse(status: 200))
    }

    private func sampleResult(usageDate: String) -> (Data, URLResponse) {
        var value = snapshot()
        value = DeviceDaySnapshotDTO(
            childDeviceID: value.childDeviceID,
            usageDate: usageDate,
            estimatedMinutes: value.estimatedMinutes,
            capMinutes: value.capMinutes,
            childDayState: value.childDayState,
            usedMinutes: value.usedMinutes,
            remainingMinutes: value.remainingMinutes,
            counted: value.counted,
            warning: value.warning
        )
        return (try! JSONEncoder().encode(value), httpResponse(status: 200))
    }

    private func makeDriver(
        center: RolloverCenter,
        transport: RolloverTransport,
        clock: RolloverClock,
        resetRolloverEffect: @escaping (MeteringRolloverLocalEffect, RolloverEffectsWork) throws -> Void = { _, _ in }
    ) -> EarnedMeteringRecoveryDriver {
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            transport: transport,
            clock: clock,
            legacySuiteName: "rollover-tests-\(UUID().uuidString)"
        )
        let installer = DatedRouteInstaller(
            store: store,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock
        )
        return EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: installer,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock,
            resetRolloverEffect: resetRolloverEffect
        )
    }

    private func activationResult(
        epochID: UUID,
        usageDate: String = "2026-07-18"
    ) -> (Data, URLResponse) {
        let response = EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: snapshot(usageDate: usageDate)
        )
        return (try! JSONEncoder().encode(response), httpResponse(status: 200))
    }

    private func snapshot(usageDate: String = "2026-07-18") -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: usageDate,
            estimatedMinutes: 0,
            capMinutes: 60,
            childDayState: "available",
            usedMinutes: 0,
            remainingMinutes: 60,
            counted: true,
            warning: nil
        )
    }

    private func epochReplacingStartedAt(
        _ epoch: DeviceDailyEpoch,
        with startedAt: Date
    ) -> DeviceDailyEpoch {
        DeviceDailyEpoch(
            epochID: epoch.epochID,
            protocolVersion: epoch.protocolVersion,
            childDeviceID: epoch.childDeviceID,
            usageDate: epoch.usageDate,
            canonicalTimezone: epoch.canonicalTimezone,
            policyRevision: epoch.policyRevision,
            measurementSelectionDigest: epoch.measurementSelectionDigest,
            enforcementSetID: epoch.enforcementSetID,
            startedAt: startedAt,
            registeredAt: epoch.registeredAt,
            baseAcceptedMinutes: epoch.baseAcceptedMinutes,
            baseSource: epoch.baseSource,
            lastRawThresholdMinutes: epoch.lastRawThresholdMinutes,
            excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
            status: epoch.status,
            resumeBoundaryPending: epoch.resumeBoundaryPending,
            retiredAt: epoch.retiredAt,
            retireReason: epoch.retireReason,
            exhaustedAt: epoch.exhaustedAt,
            baseCorrectionState: epoch.baseCorrectionState,
            authoritativeBaseConflict: epoch.authoritativeBaseConflict
        )
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid/api/v1")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private struct RolloverClock: MeteringClock { let now: Date }

private final class RolloverTransport: MeteringHTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var results: [(Data, URLResponse)]

    init(results: [(Data, URLResponse)]) { self.results = results }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else { throw URLError(.cannotConnectToHost) }
        return results.removeFirst()
    }
}

private nonisolated final class RolloverCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    var records: Set<DeviceActivityName> = []
    var schedules: [DeviceActivityName: DeviceActivitySchedule] = [:]
    var eventMaps: [DeviceActivityName: [DeviceActivityEvent.Name: DeviceActivityEvent]] = [:]
    var stopCalls: [[DeviceActivityName]] = []
    var preserveActivitiesWhenStopped = false
    var activities: [DeviceActivityName] { Array(records) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        schedules[activity]
    }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        eventMaps[activity] ?? [:]
    }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        records.insert(activity)
        schedules[activity] = schedule
        eventMaps[activity] = events
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        guard !preserveActivitiesWhenStopped else { return }
        activities.forEach {
            records.remove($0)
            schedules.removeValue(forKey: $0)
            eventMaps.removeValue(forKey: $0)
        }
    }
    func seed(_ activity: DeviceActivityName) { records.insert(activity) }
}
