import Foundation
import XCTest
@testable import Evlin_iOS

private final class DeliveryTestClock: MeteringClock, @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class DeliveryTestTransport: MeteringHTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var results: [(Data, URLResponse)] = []
    var errors: [Error] = []
    var onRequest: ((URLRequest) -> Void)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        onRequest?(request)
        if !errors.isEmpty { throw errors.removeFirst() }
        return results.removeFirst()
    }
}

private final class DeferredDeliveryTransport: MeteringHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private var continuation: CheckedContinuation<(Data, URLResponse), Never>?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: (Data, URLResponse)) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private final class SlowDeliveryTransport: MeteringHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let result: (Data, URLResponse)

    init(result: (Data, URLResponse)) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        try? await Task.sleep(nanoseconds: 50_000_000)
        return result
    }
}

private final class LegacyImportCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var hit = false

    func record() {
        lock.lock()
        hit = true
        lock.unlock()
    }
}

private final class DeliveryTestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class MeteringEpochDeliveryTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let epochID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let routeID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let baseURL = URL(string: "https://metering-epoch-delivery.test")!
    private let start = Date(timeIntervalSince1970: 1_784_179_200)

    func testV1MetadataVariantsAndLegacyFallbackSurviveProducerReopenWithIdenticalRequests() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let clock = DeliveryTestClock(now: start)
        let firstTransport = DeliveryTestTransport()
        let first = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: firstTransport, clock: clock)

        let metadataFree = makeV1(threshold: 10)
        let metadataBearing = makeV1(threshold: 20, armedAt: start, offset: 5)
        try first.enqueueV1(metadataFree, owner: owner)
        try first.enqueueV1(metadataBearing, owner: owner)

        let legacySuite = "MeteringEpochDeliveryTests.\(UUID().uuidString)"
        defer {
            EarnedSampleReporter.clearRetryQueue(suiteName: legacySuite)
            UserDefaults.standard.removePersistentDomain(forName: legacySuite)
        }
        let legacy = EarnedSampleReporter.makeRetryEntry(
            deviceID: owner,
            usageDate: "2026-07-16",
            timezone: "America/New_York",
            thresholdMinutes: 30,
            estimatedMinutes: 30,
            observedAt: "2026-07-16T12:00:00Z",
            generationArmedAt: start,
            generationOffsetMinutes: 5
        )
        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(legacy, suiteName: legacySuite))

        let reopenedTransport = DeliveryTestTransport()
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        reopenedTransport.results = [
            (try encoded(makeSnapshot(counted: true, warning: nil)), response),
            (try encoded(makeSnapshot(counted: true, warning: nil)), response),
            (try encoded(makeSnapshot(counted: true, warning: nil)), response)
        ]
        let reopened = MeteringEpochDelivery(
            baseURL: baseURL,
            store: makeStore(fileURL: fileURL),
            transport: reopenedTransport,
            clock: clock,
            legacySuiteName: legacySuite
        )
        await reopened.drain(owner: owner)

        let actualBodies = reopenedTransport.requests.compactMap(\.httpBody).sorted { $0.lexicographicallyPrecedes($1) }
        let expectedBodies = [
            try encoded(metadataFree),
            try encoded(metadataBearing),
            try encoded(try XCTUnwrap(EarnedSampleReporter.makeEpochSampleRequest(from: legacy)))
        ].sorted { $0.lexicographicallyPrecedes($1) }
        XCTAssertEqual(actualBodies, expectedBodies)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: legacySuite).isEmpty)
    }

    func testDueOrderingUsesAllSevenWorkKindPriorities() {
        let identityID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let rolloverID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let registrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let installID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let activationID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let shieldID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        var state = DeviceEpochStoreState(ownerChildDeviceID: owner)
        let retry = MeteringRetryState(
            attemptCount: 0,
            nextAttemptAt: start,
            lastErrorCode: nil,
            terminal: .pending
        )
        state.identityCleanupWork = IdentityCleanupWork(
            workID: identityID,
            oldOwnerChildDeviceID: owner,
            newOwnerChildDeviceID: nil,
            oldEpochIDs: [],
            oldRouteIDs: [],
            oldActivityNames: [],
            oldRegistrationWorkIDs: [],
            oldActivationWorkIDs: [],
            oldSampleWorkIDs: [],
            oldInstallWorkIDs: [],
            oldFallbackKeys: [],
            oldShieldOperationIDs: [],
            oldUsageDates: [],
            retry: retry,
            terminalizedWorkIDs: [],
            purgedFallbackKeys: [],
            releasedShieldOperationIDs: [],
            stopAcknowledgedActivityNames: [],
            clearedUsageDates: [],
            ownerMirrorTransitionAcknowledged: false,
            createdAt: start
        )
        state.rolloverEffectsWork = RolloverEffectsWork(
            workID: rolloverID,
            ownerChildDeviceID: owner,
            fromUsageDate: "2026-07-15",
            toUsageDate: "2026-07-16",
            oldEpochID: epochID,
            newEpochID: UUID(),
            oldRouteID: routeID,
            newRouteID: UUID(),
            retry: retry,
            earnedSourceResetAcknowledged: false,
            perAppResetAcknowledged: false,
            taskStateResetAcknowledged: false,
            bypassExpiryAcknowledged: false,
            registrationAcknowledged: false,
            installAcknowledged: false,
            activationAcknowledged: false,
            oldStopAcknowledged: false,
            createdAt: start
        )
        state.registrationWork[registrationID] = makeRegistrationWork(workID: registrationID, createdAt: start)
        let install = ActivityInstallWork(
            workID: installID,
            ownerChildDeviceID: owner,
            routeID: routeID,
            authorization: .registrationRequired,
            phase: .pendingStart,
            claim: nil,
            retry: retry,
            createdAt: start
        )
        state.installWork[installID] = install
        state.activationWork[activationID] = makeActivationWork(workID: activationID, createdAt: start)
        state.sampleWork[sampleID] = makeSampleWork(workID: sampleID, createdAt: start)
        state.shieldReferences[shieldID] = EarnedShieldReference(
            operationID: shieldID,
            ownerChildDeviceID: owner,
            generationID: UUID(),
            epochID: epochID,
            routeID: routeID,
            recordKey: "earned",
            expectedRecordBytes: Data(),
            retry: retry,
            createdAt: start
        )

        XCTAssertEqual(
            state.dueWork(now: start).map(\.kind),
            [.identityCleanup, .rollover, .registration, .install, .activation, .sample, .shield]
        )
    }

    func testDueOrderingUsesPinnedPriorityAndLowercaseWorkIDTieBreak() throws {
        let now = start
        let registrationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let activationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let sampleID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        var state = DeviceEpochStoreState(ownerChildDeviceID: owner)
        state.registrationWork[registrationID] = makeRegistrationWork(workID: registrationID, createdAt: now)
        state.activationWork[activationID] = makeActivationWork(workID: activationID, createdAt: now)
        state.sampleWork[sampleID] = makeSampleWork(workID: sampleID, createdAt: now)
        let laterSampleID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        state.sampleWork[laterSampleID] = makeSampleWork(workID: laterSampleID, createdAt: now)

        let due = state.dueWork(now: now)
        XCTAssertEqual(due.map(\.kind), [.registration, .activation, .sample, .sample])
        XCTAssertEqual(due.map(\.workID), [registrationID, activationID, sampleID, laterSampleID])
    }

    func testRetryScheduleUsesVirtualTimesThroughTenMinutes() async throws {
        let fileURL = temporaryStoreURL()
        let store = makeStore(fileURL: fileURL)
        defer { removeTemporaryStore(fileURL) }
        let transport = DeliveryTestTransport()
        transport.errors = [DeliveryTestError.offline]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)
        await delivery.drain(owner: owner)

        let retry = try store.read().sampleWork.values.first?.retry
        XCTAssertEqual(retry?.attemptCount, 1)
        XCTAssertEqual(retry?.nextAttemptAt, start.addingTimeInterval(5))
    }

    func testRetryDeadlinesAdvanceThroughTenMinutes() async throws {
        let fileURL = temporaryStoreURL()
        let store = makeStore(fileURL: fileURL)
        defer { removeTemporaryStore(fileURL) }
        let transport = DeliveryTestTransport()
        transport.errors = Array(repeating: DeliveryTestError.offline, count: 5)
        let clock = DeliveryTestClock(now: start)
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: clock
        )
        try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.nextAttemptAt, start)

        let deadlines: [TimeInterval] = [5, 15, 60, 300, 600]
        for offset in deadlines {
            await delivery.drain(owner: owner)
            XCTAssertEqual(
                try store.read().sampleWork.values.first?.retry.nextAttemptAt,
                start.addingTimeInterval(offset)
            )
            clock.now = start.addingTimeInterval(offset)
        }
    }

    func testRegistrationDispatchesBeforeActivationAndLeavesLocalSelectionV1() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let clock = DeliveryTestClock(now: start)
        let transport = DeliveryTestTransport()
        let snapshot = makeSnapshot(counted: true, warning: nil)
        let registration = makeValidRegistrationRequest()
        let activation = EpochActivationRequestDTO(
            protocolVersion: 2,
            deviceID: owner,
            routeID: routeID,
            verifiedAt: start
        )
        let registrationResponse = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot,
            epochStatus: .active
        )
        let activationResponse = EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: snapshot
        )
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
            (try encoded(registrationResponse), response),
            (try encoded(activationResponse), response)
        ]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: clock)

        try delivery.enqueueRegistration(registration, owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(activation, owner: owner, epochID: epochID, routeID: routeID)
        XCTAssertEqual(try store.read().ratchets[owner]?.localSelection, .v1)

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/child/earned-time/epochs",
            "/child/earned-time/epochs/\(epochID.uuidString.lowercased())/activation"
        ])
        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertNotNil(final.ratchets[owner]?.registeredV2At)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testRegistration200PromotesPlannedRouteInstallWithoutActivatingRoute() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let installID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.activeRouteID = nil
            state.routes[routeID]?.lifecycle = .planned
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: self.owner,
                routeID: self.routeID,
                authorization: .registrationRequired,
                phase: .pendingStart,
                claim: nil,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: self.start, lastErrorCode: nil, terminal: .pending),
                createdAt: self.start
            )
        }
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil),
            epochStatus: .active
        )), response)]
        let clock = DeliveryTestClock(now: start)
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: clock)

        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.epochs[epochID]?.registeredAt, start)
        XCTAssertEqual(final.installWork[installID]?.authorization, .registered)
        XCTAssertEqual(final.routes[routeID]?.lifecycle, .planned)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testPlannedRegistrationConflictRetryAndTerminalResponsesClearClaims() async throws {
        let conflict = EpochRegistrationConflictDTO(
            code: .authoritativeBaseMismatch,
            authoritativeSnapshot: makeSnapshot(counted: true, warning: nil)
        )
        try await assertPlannedRegistrationOutcome(
            data: encoded(conflict),
            statusCode: 409,
            expectedTerminal: .superseded,
            expectedError: "authoritative_base_mismatch",
            expectsConflict: true
        )
        try await assertPlannedRegistrationOutcome(
            data: Data("not-json".utf8),
            statusCode: 200,
            expectedTerminal: .rejected,
            expectedError: "malformed_response"
        )
        try await assertPlannedRegistrationOutcome(
            data: Data(#"{"code":"registration_rejected"}"#.utf8),
            statusCode: 422,
            expectedTerminal: .rejected,
            expectedError: "registration_rejected"
        )
        try await assertPlannedRegistrationOutcome(
            data: Data(#"{"code":"server_busy"}"#.utf8),
            statusCode: 500,
            expectedTerminal: .pending,
            expectedError: "server_busy"
        )
        try await assertPlannedRegistrationOutcome(
            error: DeliveryTestError.offline,
            expectedTerminal: .pending,
            expectedError: "network_error"
        )
    }

    func testRegistration200DoesNotPromoteInstallForRetiredOrTombstonedRoute() async throws {
        try await assertRegistration200DoesNotPromoteInstall(lifecycle: .retired)
        try await assertRegistration200DoesNotPromoteInstall(lifecycle: .tombstoned)
    }

    func testRegistrationResponseSupersedesMissingOrMismatchedRouteProvenance() throws {
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: makeStore(fileURL: temporaryStoreURL()),
            transport: DeliveryTestTransport(),
            clock: DeliveryTestClock(now: start)
        )
        for (routeID, workEpochID) in [(UUID(), epochID), (self.routeID, UUID())] {
            let workID = UUID()
            let claim = MeteringNetworkClaim(token: UUID(), claimedAt: start, expiresAt: start.addingTimeInterval(60))
            var work = EpochRegistrationWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: workEpochID,
                routeID: routeID,
                request: EpochRegistrationRequestDTO(
                    protocolVersion: 2,
                    epochID: workEpochID,
                    deviceID: owner,
                    usageDate: "2026-07-16",
                    timezone: "America/New_York",
                    policyRevision: "policy-1",
                    measurementSelectionDigest: "digest",
                    enforcementSetID: UUID(),
                    startedAt: start,
                    baseAcceptedMinutes: 0,
                    reason: .initial
                ),
                claim: claim,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
                createdAt: start
            )
            var state = makeBaseState()
            state.registrationWork[workID] = work

            XCTAssertTrue(delivery.supersedeStaleRegistrationWork(&state, key: workID, work: &work, owner: owner, claim: claim))
            XCTAssertEqual(state.registrationWork[workID]?.retry.terminal, .superseded)
            XCTAssertEqual(state.registrationWork[workID]?.retry.lastErrorCode, "route_superseded")
            XCTAssertNil(state.registrationWork[workID]?.claim)
        }
    }

    func testConcurrentDrainsAtomicallyClaimOneNetworkDispatch() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let firstStore = DeviceEpochStore(
            fileURL: fileURL,
            lock: ActiveLockPersistenceLock.shared,
            fileIO: SystemDeviceEpochFileIO(),
            ownerProvider: { self.owner }
        )
        let secondStore = DeviceEpochStore(
            fileURL: fileURL,
            lock: ActiveLockPersistenceLock.shared,
            fileIO: SystemDeviceEpochFileIO(),
            ownerProvider: { self.owner }
        )
        let response = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        let transport = SlowDeliveryTransport(result: (Data(#"{"code":"duplicate"}"#.utf8), response))
        let firstDelivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: firstStore,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        let secondDelivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: secondStore,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try firstDelivery.enqueueV1(makeV1(threshold: 10), owner: owner)

        async let first: Void = firstDelivery.drain(owner: owner)
        async let second: Void = secondDelivery.drain(owner: owner)
        _ = await (first, second)

        XCTAssertEqual(transport.requests.count, 1)
        let work = try XCTUnwrap(try firstStore.read().sampleWork.values.first)
        XCTAssertEqual(work.retry.terminal, .succeeded)
        XCTAssertNil(work.claim)
    }

    func testExpiredClaimIsRecoveredAndStaleResponseCannotMutateNewerRetry() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let clock = DeliveryTestClock(now: start)
        let store = makeStore(fileURL: fileURL)
        let firstTransport = DeferredDeliveryTransport()
        let first = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: firstTransport, clock: clock)
        try first.enqueueV1(makeV1(threshold: 10), owner: owner)

        let firstDrain = Task { await first.drain(owner: owner) }
        while firstTransport.requests.isEmpty { await Task.yield() }
        let oldClaim = try XCTUnwrap(try store.read().sampleWork.values.first?.claim)

        clock.now = start.addingTimeInterval(59.999)
        let duplicateResponse = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        let secondTransport = DeliveryTestTransport()
        var recoveredClaim: MeteringNetworkClaim?
        secondTransport.onRequest = { _ in
            recoveredClaim = try? store.read().sampleWork.values.first?.claim
        }
        secondTransport.results = [(Data(#"{"code":"duplicate"}"#.utf8), duplicateResponse)]
        let second = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: secondTransport, clock: clock)
        await second.drain(owner: owner)

        XCTAssertTrue(secondTransport.requests.isEmpty)
        XCTAssertNil(recoveredClaim)

        clock.now = start.addingTimeInterval(60)
        await second.drain(owner: owner)

        let afterRecovery = try XCTUnwrap(try store.read().sampleWork.values.first)
        let newClaim = try XCTUnwrap(recoveredClaim)
        XCTAssertNotEqual(oldClaim.token, newClaim.token)
        XCTAssertEqual(afterRecovery.retry.terminal, .succeeded)
        XCTAssertNil(afterRecovery.claim)

        let accepted = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        firstTransport.resume(with: (try encoded(makeSnapshot(counted: true, warning: nil)), accepted))
        await firstDrain.value

        let final = try XCTUnwrap(try store.read().sampleWork.values.first)
        XCTAssertEqual(final.retry.terminal, .succeeded)
        XCTAssertNil(final.claim)
    }

    func testFirstUnsupportedPriorityBlocksLowerNetworkWork() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = DeviceEpochStoreState(ownerChildDeviceID: owner)
            state.identityCleanupWork = IdentityCleanupWork(
                workID: UUID(), oldOwnerChildDeviceID: owner, newOwnerChildDeviceID: nil,
                oldEpochIDs: [], oldRouteIDs: [], oldActivityNames: [], oldRegistrationWorkIDs: [],
                oldActivationWorkIDs: [], oldSampleWorkIDs: [], oldInstallWorkIDs: [], oldFallbackKeys: [],
                oldShieldOperationIDs: [], oldUsageDates: [],
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
                terminalizedWorkIDs: [], purgedFallbackKeys: [], releasedShieldOperationIDs: [],
                stopAcknowledgedActivityNames: [], clearedUsageDates: [], ownerMirrorTransitionAcknowledged: false,
                createdAt: start
            )
            let sampleID = UUID()
            state.sampleWork[sampleID] = makeSampleWork(workID: sampleID, createdAt: start)
        }
        let transport = DeliveryTestTransport()
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .pending)
    }

    func testSuppressedCandidateBlocksLowerV1NetworkWork() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.epochs[epochID]?.authoritativeBaseConflict = EpochRegistrationConflictDTO(
                code: .authoritativeBaseMismatch,
                authoritativeSnapshot: makeSnapshot(counted: true, warning: nil)
            )
            let v2ID = UUID()
            let route = state.routes[routeID]!
            state.sampleWork[v2ID] = EpochSampleWork(
                workID: v2ID, ownerChildDeviceID: owner, epochID: epochID, routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner, usageDate: route.usageDate, timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: route.activityName, eventName: "evlin.earned.t10", thresholdMinutes: 10,
                    estimatedMinutes: 10, observedAt: start, clientSampleID: "v2-suppressed",
                    protocolVersion: 2, epochID: epochID, generationArmedAt: nil, generationOffsetMinutes: nil
                ), authorization: .v2Deliverable,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start.addingTimeInterval(-1), lastErrorCode: nil, terminal: .pending),
                createdAt: start
            )
            let v1ID = UUID()
            state.sampleWork[v1ID] = makeSampleWork(workID: v1ID, createdAt: start)
        }
        let transport = DeliveryTestTransport()
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testReadyInstallAtGlobalDueHeadBlocksLowerNetworkWork() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            var install = makeVerifiedInstallWork(createdAt: start.addingTimeInterval(-2))
            install.retry.nextAttemptAt = start.addingTimeInterval(-1)
            install.retry.terminal = .pending
            state.installWork[install.workID] = install
            let sampleID = UUID()
            state.sampleWork[sampleID] = makeSampleWork(workID: sampleID, createdAt: start)
        }
        let transport = DeliveryTestTransport()
        transport.results = [
            (Data(#"{\"code\":\"duplicate\"}"#.utf8), HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        ]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testWaitingForRegistrationSampleAtDueHeadBlocksLowerLegacySample() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let route = try XCTUnwrap(state.routes[routeID])
            let waitingID = UUID()
            state.sampleWork[waitingID] = EpochSampleWork(
                workID: waitingID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: route.activityName,
                    eventName: "evlin.earned.t10",
                    thresholdMinutes: 10,
                    estimatedMinutes: 10,
                    observedAt: start,
                    clientSampleID: "waiting-for-registration",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .waitingForRegistration,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start.addingTimeInterval(-1), lastErrorCode: nil, terminal: .pending),
                createdAt: start
            )
            let legacyID = UUID()
            state.sampleWork[legacyID] = makeSampleWork(workID: legacyID, createdAt: start)
        }
        let transport = DeliveryTestTransport()
        transport.results = [
            (Data(#"{\"code\":\"duplicate\"}"#.utf8), HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        ]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testActivationRequiresExactRegistrationRouteAndInstallPhaseBeforeAndAtResponse() async throws {
        let disallowed: [ActivityInstallPhase] = [.pendingStart, .starting, .installed, .pendingStop, .stopped]
        for phase in disallowed {
            let fileURL = temporaryStoreURL()
            defer { removeTemporaryStore(fileURL) }
            let store = makeStore(fileURL: fileURL)
            try store.transaction(expectedOwner: owner) { state in
                state = makeBaseState()
                let registrationID = UUID()
                var registration = makeRegistrationWork(workID: registrationID, createdAt: start)
                registration.retry.terminal = .succeeded
                state.registrationWork[registrationID] = registration
                state.installWork[UUID()] = ActivityInstallWork(
                    workID: UUID(), ownerChildDeviceID: owner, routeID: routeID, authorization: .registered,
                    phase: phase, claim: nil,
                    retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
                    createdAt: start
                )
            }
            let transport = DeliveryTestTransport()
            let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
            try delivery.enqueueActivation(
                EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
                owner: owner, epochID: epochID, routeID: routeID
            )
            await delivery.drain(owner: owner)
            XCTAssertTrue(transport.requests.isEmpty, "phase \(phase) must block activation")
        }

        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let registrationID = UUID()
            var registration = makeRegistrationWork(workID: registrationID, createdAt: start)
            registration.retry.terminal = .succeeded
            state.registrationWork[registrationID] = registration
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(EpochActivationResponseDTO(
            status: .activated, epochID: epochID, epochStatus: .active, meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil)
        )), response)]
        transport.onRequest = { _ in
            try? store.transaction(expectedOwner: self.owner) { state in
                state.installWork[state.installWork.keys.first!]?.phase = .pendingStop
            }
        }
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner, epochID: epochID, routeID: routeID
        )
        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().activationWork.values.first?.retry.terminal, .pending)
    }

    func testResponseSnapshotsMustMatchClaimedOwnerAndDate() async throws {
        let mismatchedOwner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let cases: [(String, DeviceDaySnapshotDTO)] = [
            ("wrong_device", DeviceDaySnapshotDTO(childDeviceID: mismatchedOwner, usageDate: "2026-07-16", estimatedMinutes: 10, capMinutes: 60, childDayState: "active", usedMinutes: 10, remainingMinutes: 50, counted: true, warning: nil)),
            ("wrong_date", DeviceDaySnapshotDTO(childDeviceID: owner, usageDate: "2026-07-17", estimatedMinutes: 10, capMinutes: 60, childDayState: "active", usedMinutes: 10, remainingMinutes: 50, counted: true, warning: nil))
        ]
        for (code, snapshot) in cases {
            let fileURL = temporaryStoreURL()
            defer { removeTemporaryStore(fileURL) }
            let store = makeStore(fileURL: fileURL)
            let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let transport = DeliveryTestTransport()
            transport.results = [(try encoded(snapshot), response)]
            let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
            try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)
            await delivery.drain(owner: owner)
            let work = try XCTUnwrap(try store.read().sampleWork.values.first)
            XCTAssertNotEqual(work.retry.terminal, .succeeded, code)
            XCTAssertEqual(work.retry.lastErrorCode, "snapshot_mismatch", code)
        }
    }

    func testRegistrationSnapshotMustMatchClaimedOwnerAndDate() async throws {
        let mismatchedOwner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let snapshots = [
            DeviceDaySnapshotDTO(childDeviceID: mismatchedOwner, usageDate: "2026-07-16", estimatedMinutes: 0, capMinutes: 60, childDayState: "active", usedMinutes: 0, remainingMinutes: 60, counted: true, warning: nil),
            DeviceDaySnapshotDTO(childDeviceID: owner, usageDate: "2026-07-17", estimatedMinutes: 0, capMinutes: 60, childDayState: "active", usedMinutes: 0, remainingMinutes: 60, counted: true, warning: nil)
        ]
        for snapshot in snapshots {
            let fileURL = temporaryStoreURL()
            defer { removeTemporaryStore(fileURL) }
            let store = makeStore(fileURL: fileURL)
            try store.transaction(expectedOwner: owner) { state in
                state = makeBaseState()
            }
            let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let transport = DeliveryTestTransport()
            transport.results = [(try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: snapshot,
                epochStatus: .active
            )), response)]
            let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
            try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
            await delivery.drain(owner: owner)

            let final = try store.read()
            XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "snapshot_mismatch")
            XCTAssertNotEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
            XCTAssertNil(final.ratchets[owner]?.registeredV2At)
        }
    }

    func testRegistrationRequestUsageDateMustMatchReferencedRouteAndEpoch() throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { $0 = makeBaseState() }
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: DeliveryTestTransport(),
            clock: DeliveryTestClock(now: start)
        )
        let request = EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: epochID,
            deviceID: owner,
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: Data([0x01, 0x02])),
            enforcementSetID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            startedAt: start,
            baseAcceptedMinutes: 0,
            reason: .initial
        )

        XCTAssertThrowsError(
            try delivery.enqueueRegistration(request, owner: owner, epochID: epochID, routeID: routeID)
        )
    }

    func testAuthoritativeConflictSnapshotMustMatchClaimedRouteAndEpoch() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { $0 = makeBaseState() }
        let conflict = EpochRegistrationConflictDTO(
            code: .authoritativeBaseMismatch,
            authoritativeSnapshot: DeviceDaySnapshotDTO(
                childDeviceID: UUID(),
                usageDate: "2026-07-17",
                estimatedMinutes: 0,
                capMinutes: 60,
                childDayState: "active",
                usedMinutes: 0,
                remainingMinutes: 60,
                counted: true,
                warning: nil
            )
        )
        let response = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(conflict), response)]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)

        await delivery.drain(owner: owner)

        XCTAssertNil(try store.read().epochs[epochID]?.authoritativeBaseConflict)
        XCTAssertEqual(try store.read().registrationWork.values.first?.retry.terminal, .pending)
    }

    func testLegacySampleAuthorizationCannotReferenceV2Route() throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let route = try XCTUnwrap(state.routes[routeID])
            let workID = UUID()
            state.sampleWork[workID] = EpochSampleWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: route.activityName,
                    eventName: "evlin.earned.t10",
                    thresholdMinutes: 10,
                    estimatedMinutes: 10,
                    observedAt: start,
                    clientSampleID: "legacy-with-v2-route",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .legacyDeliverable,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
                createdAt: start
            )
        })
    }

    func testTerminalSampleSnapshotMustMatchClaimedOwnerAndDate() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 400, httpVersion: nil, headerFields: nil)!
        transport.results = [(try encoded(DeviceDaySnapshotDTO(
            childDeviceID: UUID(),
            usageDate: "2026-07-17",
            estimatedMinutes: 10,
            capMinutes: 60,
            childDayState: "paused",
            usedMinutes: 10,
            remainingMinutes: 50,
            counted: false,
            warning: "accounting_paused"
        )), response)]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
        try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)

        await delivery.drain(owner: owner)

        let work = try XCTUnwrap(try store.read().sampleWork.values.first)
        XCTAssertEqual(work.retry.terminal, .rejected)
        XCTAssertEqual(work.retry.lastErrorCode, "snapshot_mismatch")
    }

    func testActivationSnapshotMustMatchClaimedOwnerAndDate() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let registrationID = UUID()
            var registration = makeRegistrationWork(workID: registrationID, createdAt: start)
            registration.retry.terminal = .succeeded
            state.registrationWork[registrationID] = registration
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: DeviceDaySnapshotDTO(childDeviceID: owner, usageDate: "2026-07-17", estimatedMinutes: 0, capMinutes: 60, childDayState: "active", usedMinutes: 0, remainingMinutes: 60, counted: true, warning: nil)
        )), response)]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner, epochID: epochID, routeID: routeID
        )
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.activationWork.values.first?.retry.lastErrorCode, "snapshot_mismatch")
        XCTAssertNotEqual(final.activationWork.values.first?.retry.terminal, .succeeded)
    }

    func testRouteChangeBeforeSendAndConflictChangeBeforeResponseLeaveClaimedWorkUncommitted() async throws {
        let routeFileURL = temporaryStoreURL()
        defer { removeTemporaryStore(routeFileURL) }
        let routeStore = makeStore(fileURL: routeFileURL)
        try routeStore.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.routes[routeID]?.lifecycle = .retired
            state.activeRouteID = nil
            let registrationID = UUID()
            var registration = makeRegistrationWork(workID: registrationID, createdAt: start)
            registration.retry.terminal = .succeeded
            state.registrationWork[registrationID] = registration
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let routeTransport = DeliveryTestTransport()
        let routeDelivery = MeteringEpochDelivery(baseURL: baseURL, store: routeStore, transport: routeTransport, clock: DeliveryTestClock(now: start))
        try routeDelivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner, epochID: epochID, routeID: routeID
        )
        await routeDelivery.drain(owner: owner)
        XCTAssertTrue(routeTransport.requests.isEmpty)
        XCTAssertEqual(try routeStore.read().activationWork.values.first?.retry.terminal, .pending)

        let conflictFileURL = temporaryStoreURL()
        defer { removeTemporaryStore(conflictFileURL) }
        let conflictStore = makeStore(fileURL: conflictFileURL)
        try conflictStore.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
        }
        let conflict = EpochRegistrationConflictDTO(code: .authoritativeBaseMismatch, authoritativeSnapshot: makeSnapshot(counted: true, warning: nil))
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let conflictTransport = DeliveryTestTransport()
        conflictTransport.results = [(try encoded(EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil),
            epochStatus: .active
        )), response)]
        conflictTransport.onRequest = { _ in
            try? conflictStore.transaction(expectedOwner: self.owner) { state in
                state.epochs[self.epochID]?.authoritativeBaseConflict = conflict
            }
        }
        let conflictDelivery = MeteringEpochDelivery(baseURL: baseURL, store: conflictStore, transport: conflictTransport, clock: DeliveryTestClock(now: start))
        try conflictDelivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        await conflictDelivery.drain(owner: owner)

        let final = try conflictStore.read()
        XCTAssertEqual(conflictTransport.requests.count, 1)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .pending)
        XCTAssertNotNil(final.registrationWork.values.first?.claim)
        XCTAssertEqual(final.epochs[epochID]?.authoritativeBaseConflict, conflict)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
    }

#if DEBUG
    func testLegacyImportCheckpointRestartWindowIsIdempotent() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let suite = "MeteringEpochDeliveryTests.checkpoint.\(UUID().uuidString)"
        defer {
            EarnedSampleReporter.clearRetryQueue(suiteName: suite)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let entry = EarnedSampleReporter.makeRetryEntry(
            deviceID: owner, usageDate: "2026-07-16", timezone: "America/New_York",
            thresholdMinutes: 25, estimatedMinutes: 25, observedAt: "2026-07-16T12:00:00Z"
        )
        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(entry, suiteName: suite, faultInjection: .lockUnavailable))
        let checkpoint = LegacyImportCheckpoint()
        let firstTransport = DeliveryTestTransport()
        let first = MeteringEpochDelivery(
            baseURL: baseURL, store: makeStore(fileURL: fileURL), transport: firstTransport,
            clock: DeliveryTestClock(now: start), legacySuiteName: suite,
            debugAfterLegacyImportReadback: { checkpoint.record() }
        )
        await first.drain(owner: owner)
        XCTAssertTrue(checkpoint.hit)
        XCTAssertEqual(try makeStore(fileURL: fileURL).read().sampleWork.count, 1)
        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: suite), [entry])

        let response = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        let reopenedTransport = DeliveryTestTransport()
        reopenedTransport.results = [(Data(#"{"code":"duplicate"}"#.utf8), response)]
        let reopened = MeteringEpochDelivery(
            baseURL: baseURL, store: makeStore(fileURL: fileURL), transport: reopenedTransport,
            clock: DeliveryTestClock(now: start), legacySuiteName: suite
        )
        await reopened.drain(owner: owner)
        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: suite).isEmpty)
        XCTAssertEqual(reopenedTransport.requests.count, 1)
    }
#endif

    func testOwnerChangeDuringSampleResponseLeavesPendingWorkAndV1() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        var currentOwner: UUID? = owner
        let store = DeviceEpochStore(
            fileURL: fileURL,
            lock: DeliveryTestLock(),
            fileIO: SystemDeviceEpochFileIO(),
            ownerProvider: { currentOwner }
        )
        let transport = DeliveryTestTransport()
        transport.onRequest = { _ in currentOwner = UUID(uuidString: "99999999-9999-9999-9999-999999999999") }
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [(try encoded(makeSnapshot(counted: true, warning: nil)), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)

        await delivery.drain(owner: owner)

        let work = try store.read().sampleWork.values.first
        XCTAssertEqual(work?.retry.terminal, .pending)
        XCTAssertEqual(work?.retry.attemptCount, 0)
        XCTAssertEqual(try store.read().ratchets[owner]?.localSelection, nil)
    }

    func testAcceptedSampleRemainsTerminalWorkUntilRetentionCanProveReferencesTerminal() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [(try encoded(makeSnapshot(counted: true, warning: nil)), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)

        await delivery.drain(owner: owner)

        let work = try store.read().sampleWork.values.first
        XCTAssertEqual(work?.retry.terminal, .succeeded)
        XCTAssertEqual(work?.request.clientSampleID, makeV1(threshold: 10).clientSampleID)
    }

    func testResponsesTerminalizeExpectedLanesAndNeverSwitchLocalSelection() throws {
        let snapshot = makeSnapshot(counted: false, warning: "accounting_paused")
        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: try encoded(snapshot), statusCode: 200),
            .terminal(code: "accounting_paused", snapshot: snapshot)
        )
        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: Data(#"{"code":"identity_changed"}"#.utf8), statusCode: 409),
            .terminal(code: "identity_changed", snapshot: nil)
        )
        let legacyAfterV2 = makeSnapshot(counted: false, warning: "legacy_after_v2")
        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: try encoded(legacyAfterV2), statusCode: 200),
            .terminal(code: "legacy_after_v2", snapshot: legacyAfterV2)
        )
        let duplicateSnapshot = makeSnapshot(counted: true, warning: nil)
        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: try encoded(duplicateSnapshot), statusCode: 409),
            .accepted(duplicateSnapshot)
        )
        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: Data(), statusCode: 503),
            .retry(code: "http_503")
        )
        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: Data(), statusCode: 429),
            .retry(code: "http_429")
        )
    }

    func testNonBaseRegistrationConflictIsTerminalAndPreservesV1() throws {
        let conflict = Data(#"{"code":"policy_revision_mismatch"}"#.utf8)
        XCTAssertEqual(
            MeteringEpochDelivery.registrationDisposition(data: conflict, statusCode: 409),
            .terminal(code: "policy_revision_mismatch")
        )
    }

    func testRegistration2xxRequiresV2ProtocolAndActiveEpoch() throws {
        let snapshot = makeSnapshot(counted: true, warning: nil)
        let responses = [
            EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 1,
                snapshot: snapshot,
                epochStatus: .active
            ),
            EpochRegistrationResponseDTO(
                status: .alreadyRegistered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: snapshot,
                epochStatus: .paused
            ),
            EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: snapshot,
                epochStatus: nil
            )
        ]

        for response in responses {
            let disposition = MeteringEpochDelivery.registrationDisposition(
                data: try encoded(response),
                statusCode: 200
            )
            guard case .terminal = disposition else {
                return XCTFail("unsafe registration response was treated as success: \(response)")
            }
        }
    }

    func testActivation2xxRequiresV2ProtocolActiveEpochAndActivatedStatus() throws {
        let snapshot = makeSnapshot(counted: true, warning: nil)
        let responses = [
            EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .active,
                meteringProtocolVersion: 1,
                snapshot: snapshot
            ),
            EpochActivationResponseDTO(
                status: .paused,
                epochID: epochID,
                epochStatus: .paused,
                meteringProtocolVersion: 2,
                snapshot: snapshot
            ),
            EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .active,
                meteringProtocolVersion: 2,
                snapshot: snapshot
            )
        ]

        for response in responses {
            let disposition = MeteringEpochDelivery.activationDisposition(
                data: try encoded(response),
                statusCode: 200
            )
            if case .acknowledged = disposition, response.meteringProtocolVersion != 2 {
                return XCTFail("protocol-v1 activation response was acknowledged")
            }
            if case .acknowledged = disposition, response.status == .paused {
                return XCTFail("paused activation response was acknowledged")
            }
        }
    }

    func testInvalidRegistrationResponseCannotUnlockActivation() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
            (try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .paused
            )), response),
            (try encoded(EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .active,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil)
            )), response)
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .pending)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testMismatchedRegistrationEpochCannotUnlockActivation() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
            (try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .active
            )), response),
            (try encoded(EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .active,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil)
            )), response)
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "epoch_mismatch")
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .pending)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testMismatchedActivationEpochCannotSucceed() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
            (try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .active
            )), response),
            (try encoded(EpochActivationResponseDTO(
                status: .activated,
                epochID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                epochStatus: .active,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil)
            )), response)
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.activationWork.values.first?.retry.lastErrorCode, "epoch_mismatch")
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testActivationWaitsForVerifiedInstall() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
            (try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .active
            )), response),
            (try encoded(EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .active,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil)
            )), response)
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .pending)
    }

    func testAuthoritativeConflictIsPersistedAndSuppressesCandidateWorkWithoutCreatingCorrection() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let before = makeBaseState()
        try store.transaction(expectedOwner: owner) { state in
            state = before
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
            let route = state.routes[routeID]!
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: "America/New_York",
                    activityName: route.activityName,
                    eventName: "evlin.earned.t10",
                    thresholdMinutes: 10,
                    estimatedMinutes: 10,
                    observedAt: start,
                    clientSampleID: "earned:v2:\(routeID.uuidString.lowercased()):t10",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
                createdAt: start
            )
        }
        let conflict = EpochRegistrationConflictDTO(
            code: .authoritativeBaseMismatch,
            authoritativeSnapshot: makeSnapshot(counted: true, warning: nil)
        )
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        transport.results = [(try encoded(conflict), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.epochs[epochID]?.authoritativeBaseConflict, conflict)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .superseded)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .pending)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .pending)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(Set(final.epochs.keys), Set(before.epochs.keys))
        XCTAssertEqual(Set(final.routes.keys), Set(before.routes.keys))
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testCodeOnlyDuplicate409IsAcceptedSampleSuccess() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        transport.results = [(Data(#"{"code":"duplicate"}"#.utf8), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueV1(makeV1(threshold: 10), owner: owner)

        await delivery.drain(owner: owner)

        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .succeeded)
    }

    func testLegacyImportReopenAfterCrashBeforeFallbackDeletionIsIdempotent() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let suite = "MeteringEpochDeliveryTests.\(UUID().uuidString)"
        defer {
            EarnedSampleReporter.clearRetryQueue(suiteName: suite)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let entry = EarnedSampleReporter.makeRetryEntry(
            deviceID: owner,
            usageDate: "2026-07-16",
            timezone: "America/New_York",
            thresholdMinutes: 25,
            estimatedMinutes: 25,
            observedAt: "2026-07-16T12:00:00Z"
        )
        XCTAssertTrue(EarnedSampleReporter.enqueueRetry(entry, suiteName: suite, faultInjection: .lockUnavailable))

        let firstTransport = DeliveryTestTransport()
        let first = MeteringEpochDelivery(
            baseURL: baseURL,
            store: makeStore(fileURL: fileURL),
            transport: firstTransport,
            clock: DeliveryTestClock(now: start),
            legacySuiteName: suite,
            debugAfterLegacyImportReadback: {}
        )
        await first.drain(owner: owner)
        XCTAssertEqual(try makeStore(fileURL: fileURL).read().sampleWork.count, 1)
        XCTAssertEqual(EarnedSampleReporter.loadRetryQueue(suiteName: suite), [entry])
        XCTAssertTrue(firstTransport.requests.isEmpty)

        let secondTransport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
        secondTransport.results = [(Data(#"{"code":"duplicate"}"#.utf8), response)]
        let reopened = MeteringEpochDelivery(
            baseURL: baseURL,
            store: makeStore(fileURL: fileURL),
            transport: secondTransport,
            clock: DeliveryTestClock(now: start),
            legacySuiteName: suite
        )
        await reopened.drain(owner: owner)

        XCTAssertTrue(EarnedSampleReporter.loadRetryQueue(suiteName: suite).isEmpty)
        XCTAssertEqual(secondTransport.requests.count, 1)
        XCTAssertEqual(try makeStore(fileURL: fileURL).read().sampleWork.count, 1)
    }

    func testMalformedV1MetadataIsRejectedBeforeDurableWrite() {
        let fileURL = temporaryStoreURL()
        let store = makeStore(fileURL: fileURL)
        defer { removeTemporaryStore(fileURL) }
        let transport = DeliveryTestTransport()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        let malformed = makeV1(threshold: 10, armedAt: start)
        XCTAssertThrowsError(try delivery.enqueueV1(malformed, owner: owner))
        XCTAssertTrue((try? store.read().sampleWork.isEmpty) == true)
    }

    func testDispatchSelectionAndClaimAreOneStoreTransaction() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Evlin iOS/Services/MeteringEpochDelivery.swift")
        )
        XCTAssertFalse(source.contains("nextDispatchable(owner:"))
        XCTAssertFalse(source.contains("claimNetworkWork(workID:"))
        XCTAssertTrue(source.contains("claimFirstNetworkWork"))
    }

    func testNetworkLeaseIsAnExactNonOverridableSixtySecondInvariant() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Evlin iOS/Services/DeviceEpochStore.swift")
        )
        XCTAssertFalse(source.contains("leaseDuration: TimeInterval = MeteringNetworkClaim"))
        XCTAssertTrue(source.contains("now.addingTimeInterval(MeteringNetworkClaim.leaseDuration)"))
    }

    private func makeStore(fileURL: URL) -> DeviceEpochStore {
        DeviceEpochStore(
            fileURL: fileURL,
            lock: DeliveryTestLock(),
            fileIO: SystemDeviceEpochFileIO(),
            ownerProvider: { self.owner }
        )
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("metering-delivery-\(UUID().uuidString).json")
    }

    private func removeTemporaryStore(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let nsError = error as NSError
            guard nsError.domain != NSCocoaErrorDomain || nsError.code != CocoaError.fileNoSuchFile.rawValue else { return }
            XCTFail("temporary store cleanup failed: \(error)")
        }
    }

    private func makeV1(threshold: Int, armedAt: Date? = nil, offset: Int? = nil) -> EpochSampleRequestDTO {
        EpochSampleRequestDTO(
            deviceID: owner,
            usageDate: "2026-07-16",
            timezone: "America/New_York",
            activityName: "evlin.earned.budget",
            eventName: "evlin.earned.t\(threshold)",
            thresholdMinutes: threshold,
            estimatedMinutes: threshold,
            observedAt: start,
            clientSampleID: "earned:\(owner.uuidString.lowercased()):2026-07-16:t\(threshold)",
            protocolVersion: nil,
            epochID: nil,
            generationArmedAt: armedAt,
            generationOffsetMinutes: offset
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func makeSnapshot(counted: Bool, warning: String?) -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-16",
            estimatedMinutes: 30,
            capMinutes: 60,
            childDayState: "active",
            usedMinutes: 30,
            remainingMinutes: 30,
            counted: counted,
            warning: warning
        )
    }

    private func makeRegistrationWork(workID: UUID, createdAt: Date) -> EpochRegistrationWork {
        EpochRegistrationWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: epochID,
            routeID: routeID,
            request: EpochRegistrationRequestDTO(
                protocolVersion: 2,
                epochID: epochID,
                deviceID: owner,
                usageDate: "2026-07-16",
                timezone: "America/New_York",
                policyRevision: "policy-1",
                measurementSelectionDigest: "digest",
                enforcementSetID: UUID(),
                startedAt: createdAt,
                baseAcceptedMinutes: 0,
                reason: .initial
            ),
            retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: createdAt, lastErrorCode: nil, terminal: .pending),
            createdAt: createdAt
        )
    }

    private func makeActivationWork(workID: UUID, createdAt: Date) -> EpochActivationWork {
        EpochActivationWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: epochID,
            routeID: routeID,
            request: EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: createdAt),
            retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: createdAt, lastErrorCode: nil, terminal: .pending),
            createdAt: createdAt
        )
    }

    private func makeVerifiedInstallWork(createdAt: Date) -> ActivityInstallWork {
        ActivityInstallWork(
            workID: UUID(),
            ownerChildDeviceID: owner,
            routeID: routeID,
            authorization: .registered,
            phase: .verified,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: createdAt,
                lastErrorCode: nil,
                terminal: .succeeded
            ),
            createdAt: createdAt
        )
    }

    private func makeSampleWork(workID: UUID, createdAt: Date) -> EpochSampleWork {
        EpochSampleWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: nil,
            routeID: nil,
            request: makeV1(threshold: 10),
            authorization: .legacyDeliverable,
            retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: createdAt, lastErrorCode: nil, terminal: .pending),
            createdAt: createdAt
        )
    }

    private func makeValidRegistrationRequest() -> EpochRegistrationRequestDTO {
        EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: epochID,
            deviceID: owner,
            usageDate: "2026-07-16",
            timezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: Data([0x01, 0x02])),
            enforcementSetID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            startedAt: start,
            baseAcceptedMinutes: 0,
            reason: .initial
        )
    }

    private func makeBaseState() -> DeviceEpochStoreState {
        let generationID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let selectionBytes = Data([0x01, 0x02])
        let selectionDigest = MeteringEpochContract.selectionDigest(persistedBytes: selectionBytes)
        let enforcementSetID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: selectionDigest,
            enforcementSetID: enforcementSetID
        )
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: selectionDigest,
            enforcementSetID: enforcementSetID,
            measurementSelectionBytes: selectionBytes,
            createdAt: start,
            retiredAt: nil
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: "2026-07-16",
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: selectionDigest,
            enforcementSetID: enforcementSetID,
            startedAt: start,
            registeredAt: nil,
            baseAcceptedMinutes: 0,
            baseSource: .registration200,
            lastRawThresholdMinutes: 0,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        let schedule = DatedSchedulePlan(
            usageDate: "2026-07-16",
            timezoneIdentifier: "America/New_York",
            calendarIdentifier: "gregorian"
        )
        let route = MeteringCallbackRoute(
            routeID: routeID,
            activityName: "evlin.earned.budget.(routeID.uuidString.lowercased())",
            namespace: "earned",
            generationID: generationID,
            generationKey: generationKey,
            ownerChildDeviceID: owner,
            usageDate: "2026-07-16",
            epochID: epochID,
            plannedSchedule: schedule,
            installedSchedule: nil,
            plannedEvents: [MeteringEventPlan(eventName: "evlin.earned.t10", thresholdMinutes: 10)],
            installedEvents: nil,
            lifecycle: .active,
            createdAt: start
        )
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [generationID: generation],
            activeGenerationID: generationID,
            epochs: [epochID: epoch],
            activeEpochID: epochID,
            routes: [routeID: route],
            activeRouteID: routeID,
            ratchets: [owner: MeteringOwnerRatchet(
                ownerChildDeviceID: owner,
                advertisedVersion: 1,
                localSelection: .v1,
                registeredV2At: nil,
                dualActiveAt: nil,
                activatedV2At: nil
            )]
        )
    }

    private func assertRegistration200DoesNotPromoteInstall(lifecycle: MeteringRouteLifecycle) async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let installID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.activeRouteID = nil
            state.routes[routeID]?.lifecycle = lifecycle
            if case .tombstoned = lifecycle, let route = state.routes[routeID] {
                state.tombstones[routeID] = MeteringRouteTombstone(
                    routeID: route.routeID,
                    activityName: route.activityName,
                    eventNames: route.plannedEvents.map(\.eventName),
                    ownerChildDeviceID: owner,
                    usageDate: route.usageDate,
                    epochID: route.epochID,
                    generationID: route.generationID,
                    canonicalDayEnd: start.addingTimeInterval(86_400),
                    stopAcknowledgedAt: nil,
                    referencedWorkIDs: [],
                    retainedUntil: nil
                )
            }
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registrationRequired,
                phase: .pendingStart,
                claim: nil,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
                createdAt: start
            )
        }
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil),
            epochStatus: .active
        )), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .superseded)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "route_superseded")
        XCTAssertNil(final.registrationWork.values.first?.claim)
        XCTAssertNil(final.epochs[epochID]?.registeredAt)
        XCTAssertEqual(final.installWork[installID]?.authorization, .registrationRequired)
        XCTAssertEqual(final.routes[routeID]?.lifecycle.rawValue, lifecycle.rawValue)
    }

    private func assertPlannedRegistrationOutcome(
        data: Data = Data(),
        statusCode: Int = 0,
        error: Error? = nil,
        expectedTerminal: MeteringWorkTerminal,
        expectedError: String,
        expectsConflict: Bool = false
    ) async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.activeRouteID = nil
            state.routes[routeID]?.lifecycle = .planned
        }
        let transport = DeliveryTestTransport()
        if let error {
            transport.errors = [error]
        } else {
            transport.results = [(data, HTTPURLResponse(url: baseURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)]
        }
        let clock = DeliveryTestClock(now: start)
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: clock)

        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        await delivery.drain(owner: owner)

        let final = try store.read()
        let work = try XCTUnwrap(final.registrationWork.values.first)
        XCTAssertEqual(work.retry.terminal, expectedTerminal)
        XCTAssertEqual(work.retry.lastErrorCode, expectedError)
        XCTAssertNil(work.claim)
        XCTAssertEqual(final.routes[routeID]?.lifecycle, .planned)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
        XCTAssertEqual(final.epochs[epochID]?.authoritativeBaseConflict != nil, expectsConflict)
    }
}

private enum DeliveryTestError: Error { case offline }
