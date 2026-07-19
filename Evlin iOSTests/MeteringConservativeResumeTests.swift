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
        XCTAssertEqual(state.routes[candidate.routeID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.epochs[candidate.epochID]?.retireReason, .gateResumeConservative)
        XCTAssertNil(state.v2RouteHandoff)

        try makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(10)))
            .reconcileUsageGate(ownerChildDeviceID: owner, allowed: true, runtime: runtime)
        state = try fixture.store.read()
        let fresh = try XCTUnwrap(state.routes.values.first {
            $0.routeID != fixture.oldRouteID
                && $0.routeID != candidate.routeID
                && state.epochs[$0.epochID]?.resumeBoundaryPending == true
        })
        XCTAssertNotEqual(fresh.epochID, candidate.epochID)
    }

    func testActivationObservesClosedGateAndPreservesPriorRouteForFreshResume() async throws {
        let fixture = try ResumeFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let runtime = resumeRuntime()
        let clock = ResumeClock(now: start.addingTimeInterval(3_600))
        let candidate = try prepareCandidate(fixture, runtime: runtime, clock: clock)
        fixture.transport.results = [
            registrationResult(epochID: candidate.epochID),
            (Data("{\"code\":\"epoch_paused\"}".utf8), httpResponse(statusCode: 409))
        ]

        try await makeDriver(fixture, clock: ResumeClock(now: clock.now.addingTimeInterval(5)))
            .recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.oldRouteID)
        XCTAssertEqual(state.routes[fixture.oldRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.epochs[fixture.oldEpochID]?.status, .paused)
        XCTAssertEqual(state.routes[candidate.routeID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.epochs[candidate.epochID]?.retireReason, .gateResumeConservative)
        XCTAssertNil(state.v2RouteHandoff)
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
            clock: clock
        )
    }

    private func registrationResult(
        epochID: UUID,
        status: EpochStatusDTO = .active
    ) -> (Data, URLResponse) {
        let response = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot(),
            epochStatus: status
        )
        return (try! JSONEncoder().encode(response), httpResponse())
    }

    private func activationResult(
        epochID: UUID,
        status: EpochActivationStatusDTO = .activated
    ) -> (Data, URLResponse) {
        let response = EpochActivationResponseDTO(
            status: status,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: snapshot()
        )
        return (try! JSONEncoder().encode(response), httpResponse())
    }

    private func snapshot() -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-17",
            estimatedMinutes: 17,
            capMinutes: 60,
            childDayState: "available",
            usedMinutes: 17,
            remainingMinutes: 43,
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

@MainActor
private final class ResumeCenter: MeteringDeviceActivityCenter {
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

    func cleanup() { try? FileManager.default.removeItem(at: storeURL) }
}
