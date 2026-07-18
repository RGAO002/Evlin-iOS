import DeviceActivity
import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringV2ActivationTests: XCTestCase {
    private let owner = UUID(uuidString: "C0123456-789A-4BCD-8EFA-0123456789AB")!
    private let start = Date(timeIntervalSince1970: 1_784_000_000)
    private let baseURL = URL(string: "https://example.invalid/api/v1")!

    func testInitialActivationKeepsLegacyUntilBackendAcknowledgesThenSelectsV2() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [activationResult(epochID: fixture.candidateEpochID)]

        let driver = makeDriver(fixture)
        try await driver.recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let activation = try XCTUnwrap(state.activationWork.values.first)
        XCTAssertEqual(fixture.transport.requests.map(\.url?.path), [
            "/api/v1/child/earned-time/epochs/\(fixture.candidateEpochID.uuidString.lowercased())/activation"
        ])
        XCTAssertEqual(activation.retry.terminal, .succeeded)
        XCTAssertNil(activation.retry.lastErrorCode)
        XCTAssertNil(activation.claim)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
        XCTAssertEqual(state.ratchets[owner]?.advertisedVersion, 2)
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.installWork[fixture.candidateInstallID]?.phase, .active)
        XCTAssertEqual(state.legacy?.phase, .stoppedV1)
        XCTAssertEqual(fixture.center.stopCalls, [[DeviceActivityName("evlin.earned.legacy")]])
    }

    func testActivationFailureDoesNotRatchetOrStopLegacyLane() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            (Data("{\"code\":\"epoch_paused\"}".utf8), httpResponse(status: 409))
        ]

        let driver = makeDriver(fixture)
        try await driver.recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let activation = try XCTUnwrap(state.activationWork.values.first)
        XCTAssertEqual(fixture.transport.requests.count, 1)
        XCTAssertEqual(activation.retry.terminal, .rejected)
        XCTAssertEqual(activation.retry.lastErrorCode, "epoch_paused")
        XCTAssertNil(activation.claim)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v1)
        XCTAssertEqual(state.ratchets[owner]?.advertisedVersion, 1)
        XCTAssertEqual(state.legacy?.phase, .activeV1)
        XCTAssertEqual(state.epochs[fixture.candidateEpochID]?.status, .paused)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .planned)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testInitialDualActiveRequiresVerifiedInstallAndKeepsLegacyCountable() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        try fixture.setCandidateInstallPhase(.installed)

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v1)
        XCTAssertEqual(state.legacy?.phase, .activeV1)
        XCTAssertTrue(state.activationWork.isEmpty)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testLostActivationResponseSurvivesRestartAndOnlyThenStopsLegacy() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .dualActive)
        XCTAssertEqual(state.legacy?.phase, .activeV1)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)

        fixture.transport.results = [activationResult(epochID: fixture.candidateEpochID)]
        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
        XCTAssertEqual(state.legacy?.phase, .stoppedV1)
        XCTAssertEqual(fixture.center.stopCalls.count, 1)
    }

    func testAlreadyActivatedAcknowledgesImmutableRatchetDespitePausedStatusDrift() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            activationResult(epochID: fixture.candidateEpochID, status: .alreadyActivated, epochStatus: .paused)
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
        XCTAssertEqual(state.ratchets[owner]?.advertisedVersion, 2)
        XCTAssertEqual(state.legacy?.phase, .stoppedV1)
    }

    func testReplacementKeepsPriorRouteUntilCandidateActivationThenStopsPrior() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]

        let driver = makeDriver(fixture)
        try await driver.recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(state.routes[fixture.priorRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .stopped)
        XCTAssertEqual(fixture.center.stopCalls, [[DeviceActivityName("evlin.earned.prior")]])
    }

    func testReplacementDoesNotRegisterCandidateBeforePriorInputBarrier() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPendingPriorSample()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .dualV2)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertTrue(state.registrationWork.isEmpty)
        XCTAssertEqual(fixture.transport.requests.count, 1)
        XCTAssertEqual(fixture.transport.requests.first?.url?.path, "/api/v1/child/earned-time/sample")
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testFinalPriorSampleWinningBarrierRaceDefersCandidateRegistrationUntilTheNextRecovery() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPendingPriorSample()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .dualV2)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertTrue(state.registrationWork.isEmpty)

        try fixture.completePriorSample()
        fixture.transport.errors = [.noResponse]
        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(state.registrationWork.values.filter { $0.routeID == fixture.candidateRouteID }.count, 1)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testReplacementRecoveryIsIdempotentAfterLostRegistrationAndActivationResponses() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
        var state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)

        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]
        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .stopped)
    }

    func testReplacementCreatesFreshBarrierRegistrationAfterDeferredCandidateRegistration() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPendingCandidateRegistration()
        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let candidateRegistrations = state.registrationWork.values.filter {
            $0.routeID == fixture.candidateRouteID && $0.epochID == fixture.candidateEpochID
        }
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(candidateRegistrations.filter { $0.retry.terminal == .superseded }.count, 1)
        XCTAssertEqual(candidateRegistrations.filter { $0.retry.terminal == .succeeded }.count, 1)
    }

    func testReplacementRestartAfterLocalCutoverStopsPriorOnlyAfterCandidateIsActive() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.center.preserveActivitiesWhenStopped = true
        fixture.center.seedActivity(DeviceActivityName("evlin.earned.prior"))
        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .pendingStop)
        XCTAssertNil(state.v2RouteHandoff?.priorStopAcknowledgedAt)

        fixture.center.preserveActivitiesWhenStopped = false
        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .stopped)
        XCTAssertNotNil(state.v2RouteHandoff?.priorStopAcknowledgedAt)
        XCTAssertEqual(fixture.center.stopCalls.count, 2)
    }

    private func makeDriver(_ fixture: ActivationFixture, at date: Date? = nil) -> EarnedMeteringRecoveryDriver {
        let clock = ActivationClock(now: date ?? start)
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: fixture.store,
            transport: fixture.transport,
            clock: clock,
            legacySuiteName: "activation-tests-\(UUID().uuidString)"
        )
        let installer = DatedRouteInstaller(
            store: fixture.store,
            center: fixture.center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock
        )
        return EarnedMeteringRecoveryDriver(
            store: fixture.store,
            delivery: delivery,
            installer: installer,
            center: fixture.center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock
        )
    }

    private func makeInitialFixture() throws -> ActivationFixture {
        let fixture = ActivationFixture(owner: owner, start: start)
        try fixture.store.transaction(expectedOwner: owner) { state in
            state = fixture.initialState()
        }
        return fixture
    }

    private func makeReplacementFixture() throws -> ActivationFixture {
        let fixture = ActivationFixture(owner: owner, start: start)
        try fixture.store.transaction(expectedOwner: owner) { state in
            state = fixture.replacementState()
        }
        return fixture
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

    private func activationResult(
        epochID: UUID,
        status: EpochActivationStatusDTO = .activated,
        epochStatus: EpochStatusDTO = .active
    ) -> (Data, URLResponse) {
        let response = EpochActivationResponseDTO(
            status: status,
            epochID: epochID,
            epochStatus: epochStatus,
            meteringProtocolVersion: 2,
            snapshot: snapshot()
        )
        return (try! JSONEncoder().encode(response), httpResponse(status: 200))
    }

    private func snapshot() -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-17",
            estimatedMinutes: 0,
            capMinutes: 120,
            childDayState: "available",
            usedMinutes: 0,
            remainingMinutes: 120,
            counted: true,
            warning: nil
        )
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private struct ActivationClock: MeteringClock {
    let now: Date
}

private final class ActivationTransport: MeteringHTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var results: [(Data, URLResponse)] = []
    var errors: [ActivationTransportError] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if !errors.isEmpty { throw errors.removeFirst() }
        guard !results.isEmpty else { throw ActivationTransportError.noResponse }
        return results.removeFirst()
    }
}

private enum ActivationTransportError: Error { case noResponse }

@MainActor
private final class ActivationCenter: MeteringDeviceActivityCenter {
    var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent])] = [:]
    var stopCalls: [[DeviceActivityName]] = []
    var preserveActivitiesWhenStopped = false

    var activities: [DeviceActivityName] { Array(records.keys) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { records[activity]?.0 }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] { records[activity]?.1 ?? [:] }
    func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) throws {
        records[activity] = (schedule, events)
    }

    func seedActivity(_ activity: DeviceActivityName) {
        records[activity] = (
            DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0),
                intervalEnd: DateComponents(hour: 1),
                repeats: false
            ),
            [:]
        )
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        guard !preserveActivitiesWhenStopped else { return }
        activities.forEach { records.removeValue(forKey: $0) }
    }
}

@MainActor
private final class ActivationFixture {
    let owner: UUID
    let start: Date
    let storeURL: URL
    let store: DeviceEpochStore
    let center = ActivationCenter()
    let transport = ActivationTransport()
    let priorGenerationID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    let priorEpochID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    let priorRouteID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    let candidateGenerationID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    let candidateEpochID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    let candidateRouteID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    let candidateInstallID = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
    let priorInstallID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!

    init(owner: UUID, start: Date) {
        self.owner = owner
        self.start = start
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("metering-v2-activation-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
    }

    func cleanup() { try? FileManager.default.removeItem(at: storeURL) }

    func initialState() -> DeviceEpochStoreState {
        let generation = makeGeneration(id: candidateGenerationID, policy: "initial")
        let epoch = makeEpoch(id: candidateEpochID, generation: generation, registeredAt: start)
        let route = makeRoute(id: candidateRouteID, epoch: epoch, generation: generation, name: "evlin.earned.candidate", lifecycle: .planned)
        let install = ActivityInstallWork(
            workID: candidateInstallID, ownerChildDeviceID: owner, routeID: candidateRouteID,
            authorization: .registered, phase: .verified, claim: nil,
            retry: retry(.succeeded), createdAt: start
        )
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [candidateGenerationID: generation], activeGenerationID: candidateGenerationID,
            epochs: [candidateEpochID: epoch], activeEpochID: candidateEpochID,
            routes: [candidateRouteID: route], activeRouteID: nil,
            legacy: legacy(),
            registrationWork: [UUID(): registration(route: route, epoch: epoch, terminal: .succeeded)],
            installWork: [candidateInstallID: install],
            ratchets: [owner: ratchet(selection: .v1)]
        )
    }

    func replacementState() -> DeviceEpochStoreState {
        let priorGeneration = makeGeneration(id: priorGenerationID, policy: "prior")
        let candidateGeneration = makeGeneration(id: candidateGenerationID, policy: "candidate")
        let priorEpoch = makeEpoch(id: priorEpochID, generation: priorGeneration, registeredAt: start)
        let candidateEpoch = makeEpoch(id: candidateEpochID, generation: candidateGeneration, registeredAt: nil)
        let priorRoute = makeRoute(id: priorRouteID, epoch: priorEpoch, generation: priorGeneration, name: "evlin.earned.prior", lifecycle: .active)
        let candidateRoute = makeRoute(id: candidateRouteID, epoch: candidateEpoch, generation: candidateGeneration, name: "evlin.earned.candidate", lifecycle: .planned)
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [priorGenerationID: priorGeneration, candidateGenerationID: candidateGeneration],
            activeGenerationID: priorGenerationID,
            epochs: [priorEpochID: priorEpoch, candidateEpochID: candidateEpoch], activeEpochID: priorEpochID,
            routes: [priorRouteID: priorRoute, candidateRouteID: candidateRoute], activeRouteID: priorRouteID,
            installWork: [
                priorInstallID: ActivityInstallWork(workID: priorInstallID, ownerChildDeviceID: owner, routeID: priorRouteID, authorization: .registered, phase: .active, claim: nil, retry: retry(.succeeded), createdAt: start),
                candidateInstallID: ActivityInstallWork(workID: candidateInstallID, ownerChildDeviceID: owner, routeID: candidateRouteID, authorization: .offlinePending, phase: .verified, claim: nil, retry: retry(.succeeded), createdAt: start)
            ],
            ratchets: [owner: ratchet(selection: .v2)]
        )
    }

    func addPendingPriorSample() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[priorRouteID], let epoch = state.epochs[priorEpochID] else { return }
            let request = EpochSampleRequestDTO(
                deviceID: owner,
                usageDate: epoch.usageDate,
                timezone: epoch.canonicalTimezone,
                activityName: route.activityName,
                eventName: route.plannedEvents[0].eventName,
                thresholdMinutes: 5,
                estimatedMinutes: 5,
                observedAt: start,
                clientSampleID: "v2-prior-\(UUID().uuidString)",
                protocolVersion: 2,
                epochID: epoch.epochID,
                generationArmedAt: nil,
                generationOffsetMinutes: nil
            )
            let workID = UUID()
            state.sampleWork[workID] = EpochSampleWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epoch.epochID,
                routeID: route.routeID,
                request: request,
                authorization: .v2Deliverable,
                claim: nil,
                retry: retry(.pending),
                createdAt: start
            )
        }
    }

    func addPendingCandidateRegistration() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[candidateRouteID], let epoch = state.epochs[candidateEpochID] else { return }
            let workID = UUID()
            state.registrationWork[workID] = EpochRegistrationWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epoch.epochID,
                routeID: route.routeID,
                request: registrationRequest(route: route, epoch: epoch),
                claim: nil,
                retry: retry(.pending),
                createdAt: start
            )
        }
    }

    func completePriorSample() throws {
        try store.transaction(expectedOwner: owner) { state in
            for (key, var work) in state.sampleWork where work.routeID == priorRouteID {
                work.retry = retry(.succeeded)
                work.claim = nil
                state.sampleWork[key] = work
            }
        }
    }

    func setCandidateInstallPhase(_ phase: ActivityInstallPhase) throws {
        try store.transaction(expectedOwner: owner) { state in
            state.installWork[candidateInstallID]?.phase = phase
        }
    }

    private func makeGeneration(id: UUID, policy: String) -> MeteringPolicyGeneration {
        MeteringPolicyGeneration(
            generationID: id, protocolVersion: 2, childDeviceID: owner,
            canonicalTimezone: "America/New_York", policyRevision: policy,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: Data()),
            enforcementSetID: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
            measurementSelectionBytes: Data(), createdAt: start, retiredAt: nil
        )
    }

    private func makeEpoch(id: UUID, generation: MeteringPolicyGeneration, registeredAt: Date?) -> DeviceDailyEpoch {
        DeviceDailyEpoch(
            epochID: id, protocolVersion: 2, childDeviceID: owner, usageDate: "2026-07-17",
            canonicalTimezone: generation.canonicalTimezone, policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest, enforcementSetID: generation.enforcementSetID,
            startedAt: start, registeredAt: registeredAt, baseAcceptedMinutes: 0, baseSource: .childState200,
            lastRawThresholdMinutes: 0, excludedWhilePausedMinutes: 0, status: .active,
            resumeBoundaryPending: false, retiredAt: nil, retireReason: nil, exhaustedAt: nil,
            baseCorrectionState: .available
        )
    }

    private func makeRoute(id: UUID, epoch: DeviceDailyEpoch, generation: MeteringPolicyGeneration, name: String, lifecycle: MeteringRouteLifecycle) -> MeteringCallbackRoute {
        MeteringCallbackRoute(
            routeID: id, activityName: name, namespace: MeteringRouteNamespace.prefix,
            generationID: generation.generationID,
            generationKey: MeteringGenerationKey(protocolVersion: 2, childDeviceID: owner, canonicalTimezone: generation.canonicalTimezone, policyRevision: generation.policyRevision, measurementSelectionDigest: generation.measurementSelectionDigest, enforcementSetID: generation.enforcementSetID),
            ownerChildDeviceID: owner, usageDate: epoch.usageDate, epochID: epoch.epochID,
            plannedSchedule: DatedSchedulePlan(usageDate: epoch.usageDate, timezoneIdentifier: generation.canonicalTimezone, calendarIdentifier: "gregorian"),
            installedSchedule: DatedSchedulePlan(usageDate: epoch.usageDate, timezoneIdentifier: generation.canonicalTimezone, calendarIdentifier: "gregorian"),
            plannedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: id, thresholdMinutes: 5), thresholdMinutes: 5)],
            installedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: id, thresholdMinutes: 5), thresholdMinutes: 5)],
            lifecycle: lifecycle, createdAt: start
        )
    }

    private func registration(route: MeteringCallbackRoute, epoch: DeviceDailyEpoch, terminal: MeteringWorkTerminal) -> EpochRegistrationWork {
        EpochRegistrationWork(
            workID: UUID(), ownerChildDeviceID: owner, epochID: epoch.epochID, routeID: route.routeID,
            request: registrationRequest(route: route, epoch: epoch), claim: nil, retry: retry(terminal), createdAt: start
        )
    }

    private func registrationRequest(route: MeteringCallbackRoute, epoch: DeviceDailyEpoch) -> EpochRegistrationRequestDTO {
        EpochRegistrationRequestDTO(protocolVersion: 2, epochID: epoch.epochID, deviceID: owner, usageDate: epoch.usageDate, timezone: epoch.canonicalTimezone, policyRevision: epoch.policyRevision, measurementSelectionDigest: epoch.measurementSelectionDigest, enforcementSetID: epoch.enforcementSetID, startedAt: start, baseAcceptedMinutes: epoch.baseAcceptedMinutes, reason: .initial)
    }

    private func retry(_ terminal: MeteringWorkTerminal) -> MeteringRetryState {
        MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: terminal)
    }

    private func ratchet(selection: MeteringLocalProtocolSelection) -> MeteringOwnerRatchet {
        MeteringOwnerRatchet(ownerChildDeviceID: owner, advertisedVersion: selection == .v2 ? 2 : 1, localSelection: selection, registeredV2At: selection == .v2 ? start : nil, dualActiveAt: nil, activatedV2At: selection == .v2 ? start : nil)
    }

    private func legacy() -> LegacyCompatibilityMonitorState {
        LegacyCompatibilityMonitorState(ownerChildDeviceID: owner, lifecycleVersion: 1,
            active: LegacyGenerationProvenance(activityName: "evlin.earned.legacy", deviceID: owner.uuidString, offsetMinutes: 0, armSignature: "legacy", usageDate: "2026-07-17", timezoneIdentifier: "America/New_York", armedAt: start),
            pending: nil, retiringActivityNames: [], breadcrumbActivityNames: [], scalarActiveActivityName: "evlin.earned.legacy", isStopped: false, phase: .activeV1, stopAcknowledgedAt: nil)
    }
}
