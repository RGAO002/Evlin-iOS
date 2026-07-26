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

    private func registrationResult(epochID: UUID) -> (Data, URLResponse) {
        let response = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot(),
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

    private func activationResult(epochID: UUID) -> (Data, URLResponse) {
        let response = EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: snapshot()
        )
        return (try! JSONEncoder().encode(response), httpResponse(status: 200))
    }

    private func snapshot() -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-18",
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
        activities.forEach {
            records.remove($0)
            schedules.removeValue(forKey: $0)
            eventMaps.removeValue(forKey: $0)
        }
    }
    func seed(_ activity: DeviceActivityName) { records.insert(activity) }
}
