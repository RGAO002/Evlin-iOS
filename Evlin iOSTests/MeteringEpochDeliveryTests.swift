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

    func testRejectedPhysicalNamespaceSampleIsRewrittenAndRetriedForExactActiveRoute() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        let invalidSampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.ratchets[owner]?.localSelection = .v2
            let physicalActivity = MeteringRouteNamespace.activityName(routeID: routeID)
            let physicalEvent = MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 10)
            let original = try XCTUnwrap(state.routes[routeID])
            state.routes[routeID] = MeteringCallbackRoute(
                routeID: original.routeID,
                activityName: physicalActivity,
                namespace: MeteringRouteNamespace.prefix,
                generationID: original.generationID,
                generationKey: original.generationKey,
                ownerChildDeviceID: original.ownerChildDeviceID,
                usageDate: original.usageDate,
                epochID: original.epochID,
                plannedSchedule: original.plannedSchedule,
                installedSchedule: original.installedSchedule,
                plannedEvents: [MeteringEventPlan(eventName: physicalEvent, thresholdMinutes: 10)],
                installedEvents: original.installedEvents,
                lifecycle: original.lifecycle,
                createdAt: original.createdAt
            )
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: "2026-07-16",
                    timezone: "America/New_York",
                    activityName: physicalActivity,
                    eventName: physicalEvent,
                    thresholdMinutes: 10,
                    estimatedMinutes: 50,
                    observedAt: start,
                    clientSampleID: MeteringSampleWireAliases.clientSampleID(
                        lane: .v2,
                        routeID: routeID,
                        thresholdMinutes: 10
                    ),
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: "event_namespace_mismatch",
                    terminal: .rejected
                ),
                createdAt: start
            )
            state.sampleWork[invalidSampleID] = EpochSampleWork(
                workID: invalidSampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: "2026-07-16",
                    timezone: "America/New_York",
                    activityName: physicalActivity,
                    eventName: physicalEvent,
                    thresholdMinutes: 10,
                    estimatedMinutes: 50,
                    observedAt: start,
                    clientSampleID: "not-the-route-sample-id",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: "event_namespace_mismatch",
                    terminal: .rejected
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(makeSnapshot(counted: true, warning: nil)),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            json["activity_name"] as? String,
            MeteringSampleWireAliases.activityName(routeID: routeID)
        )
        XCTAssertEqual(json["event_name"] as? String, MeteringSampleWireAliases.eventName(thresholdMinutes: 10))
        let final = try XCTUnwrap(try store.read().sampleWork[sampleID])
        XCTAssertEqual(final.retry.terminal, .succeeded)
        XCTAssertEqual(final.request.activityName, MeteringSampleWireAliases.activityName(routeID: routeID))
        let invalid = try XCTUnwrap(try store.read().sampleWork[invalidSampleID])
        XCTAssertEqual(invalid.retry.terminal, .rejected)
        XCTAssertEqual(invalid.request.activityName, MeteringRouteNamespace.activityName(routeID: routeID))
    }

    func testVerifiedLocalInstallCannotBlockLegacySampleDelivery() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let installID = UUID()
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .futurePlanned,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-1),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-1)
            )
        }

        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(makeSnapshot(counted: true, warning: nil)),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueV1(makeV1(threshold: 5), owner: owner)

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .succeeded)
    }

    func testVerifiedLocalInstallCannotBlockAuthorizedV2SampleDelivery() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let installID = UUID()
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-1),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-1)
            )
            let route = try XCTUnwrap(state.routes[routeID])
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                    eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 5),
                    thresholdMinutes: 5,
                    estimatedMinutes: 5,
                    observedAt: start,
                    clientSampleID: "v2-ready-install",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(makeSnapshot(counted: true, warning: nil)),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().sampleWork[sampleID]?.retry.terminal, .succeeded)
    }

    /// P0-1 (2026-08-19): a bounded drain pass reserves BEFORE claiming, so an
    /// exhausted budget leaves the work unclaimed (no lease to wait out) and
    /// a request it does start is clamped to what is left of the pass.
    func testExhaustedDrainBudgetLeavesWorkUnclaimedAndClampsRequestTimeouts() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let route = try XCTUnwrap(state.routes[routeID])
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                    eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 5),
                    thresholdMinutes: 5,
                    estimatedMinutes: 5,
                    observedAt: start,
                    clientSampleID: "v2-budget",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(makeSnapshot(counted: true, warning: nil)),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        // Exhausted: nothing is sent AND nothing is claimed.
        await delivery.drain(
            owner: owner,
            importLegacyWork: false,
            budget: MeteringDrainBudget(maxRequests: 0, deadline: .distantFuture)
        )
        XCTAssertEqual(transport.requests.count, 0)
        let untouched = try XCTUnwrap(try store.read().sampleWork[sampleID])
        XCTAssertNil(untouched.claim, "an exhausted pass must not take a claim it will not deliver")
        XCTAssertEqual(untouched.retry.terminal, .pending)

        // Bounded with ~2s left: the one request it starts is clamped to ≤2s.
        await delivery.drain(
            owner: owner,
            importLegacyWork: false,
            budget: MeteringDrainBudget(maxRequests: 8, deadline: Date().addingTimeInterval(2))
        )
        XCTAssertEqual(transport.requests.count, 1)
        let timeout = try XCTUnwrap(transport.requests.first?.timeoutInterval)
        XCTAssertLessThanOrEqual(timeout, 2)
        XCTAssertGreaterThanOrEqual(timeout, MeteringDrainBudget.minimumRequestSeconds)
        XCTAssertEqual(try store.read().sampleWork[sampleID]?.retry.terminal, .succeeded)
    }

    // Regression (iPad, 2026-07-25): an earned-cap shield reference was emitted
    // into dueWork as permanently-pending `.shield` work that NOTHING claims —
    // not claimFirstDispatchable, not dueInstallWork, not
    // settleLeadingInvalidRegistration — and whose retry is never terminalized.
    // Sorted by its past nextAttemptAt it sat at the head of the queue and
    // starved every registration/activation/sample created after it: one cap hit
    // froze the device's metering pipeline permanently (the 02:43 reference
    // blocked the 04:42 rollover registration, attemptCount stuck at 0).
    func testShieldReferenceCannotStarveTheNetworkQueue() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let route = try XCTUnwrap(state.routes[routeID])
            // A cap shield applied BEFORE the sample exists — the exact ordering
            // that wedged the device.
            let operationID = UUID()
            state.shieldReferences[operationID] = EarnedShieldReference(
                operationID: operationID,
                ownerChildDeviceID: owner,
                generationID: route.generationID,
                epochID: epochID,
                routeID: routeID,
                recordKey: "earned-cap",
                expectedRecordBytes: Data([1]),
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-600),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-600)
            )
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                    eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 10),
                    thresholdMinutes: 10,
                    estimatedMinutes: 10,
                    observedAt: start,
                    clientSampleID: "v2-after-shield",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(makeSnapshot(counted: true, warning: nil)),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1, "the shield reference must not block delivery")
        XCTAssertEqual(try store.read().sampleWork[sampleID]?.retry.terminal, .succeeded)
    }

    func testStoppedInstallHuskCannotBlockAuthorizedV2SampleDelivery() async throws {
        // Regression (2026-07-24 device): after a replacement, retired routes
        // leave installWork entries with phase == .stopped but terminal still
        // .pending. Those husks sat ahead of a due v2 sample in the network
        // queue and the install-envelope bypass treated .stopped as blocking —
        // the t10/485 sample starved at attemptCount=0 for hours. A stopped
        // install performs no further daemon or network work, so it must count
        // as a ready envelope.
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let stoppedID = UUID()
            state.installWork[stoppedID] = ActivityInstallWork(
                workID: stoppedID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .stopped,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-2),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-2)
            )
            let verifiedID = UUID()
            state.installWork[verifiedID] = ActivityInstallWork(
                workID: verifiedID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-1),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-1)
            )
            let route = try XCTUnwrap(state.routes[routeID])
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                    eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 10),
                    thresholdMinutes: 10,
                    estimatedMinutes: 485,
                    observedAt: start,
                    clientSampleID: "v2-stopped-husk",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(makeSnapshot(counted: true, warning: nil)),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().sampleWork[sampleID]?.retry.terminal, .succeeded)
    }

    func testVerifiedLocalInstallCannotBlockRegistrationRecovery() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let registrationID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let installID = UUID()
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .futurePlanned,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-60),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-60)
            )
            var registration = makeRegistrationWork(
                workID: registrationID,
                createdAt: start.addingTimeInterval(-30)
            )
            registration.retry = MeteringRetryState(
                attemptCount: 1,
                nextAttemptAt: start.addingTimeInterval(-30),
                lastErrorCode: "legacy_http_409_recheck",
                terminal: .pending
            )
            state.registrationWork[registrationID] = registration
        }

        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(EpochRegistrationResponseDTO(
                status: .alreadyRegistered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .active
            )),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().registrationWork[registrationID]?.retry.terminal, .succeeded)
    }

    func testTransientEnforcementSetConflictRetriesThenRegisters() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { $0 = makeBaseState() }
        let clock = DeliveryTestClock(now: start)
        let transport = DeliveryTestTransport()
        transport.results = [
            (
                Data(#"{"detail":"enforcement_set_mismatch"}"#.utf8),
                HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!
            ),
            (
                try encoded(EpochRegistrationResponseDTO(
                    status: .registered,
                    epochID: epochID,
                    meteringProtocolVersion: 2,
                    snapshot: makeSnapshot(counted: true, warning: nil),
                    epochStatus: .active
                )),
                HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: clock
        )
        try delivery.enqueueRegistration(
            makeValidRegistrationRequest(),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)
        var registration = try XCTUnwrap(try store.read().registrationWork.values.first)
        XCTAssertEqual(registration.retry.terminal, .pending)
        XCTAssertEqual(registration.retry.lastErrorCode, "enforcement_set_mismatch")

        clock.now = start.addingTimeInterval(5)
        await delivery.drain(owner: owner)

        registration = try XCTUnwrap(try store.read().registrationWork.values.first)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(registration.retry.terminal, .succeeded)
    }

    func testLegacyOpaque409IsRecheckedAfterUpgrade() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let workID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            var work = makeRegistrationWork(workID: workID, createdAt: start)
            work.retry = MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: start,
                lastErrorCode: "http_409",
                terminal: .rejected
            )
            state.registrationWork[workID] = work
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            try encoded(EpochRegistrationResponseDTO(
                status: .alreadyRegistered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .active
            )),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start.addingTimeInterval(60))
        )

        await delivery.drain(owner: owner)

        let final = try XCTUnwrap(try store.read().registrationWork[workID])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.retry.terminal, .succeeded)
        XCTAssertNil(final.retry.lastErrorCode)
    }

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

    func testDueOrderingUsesAllDispatchableWorkKindPriorities() {
        let identityID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let rolloverID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let registrationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let installID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let activationID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let shieldID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        var state = makeBaseState()
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
            [.identityCleanup, .rollover, .registration, .install, .activation, .sample]
        )
    }

    func testDueOrderingUsesPinnedPriorityAndLowercaseWorkIDTieBreak() throws {
        let now = start
        let registrationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let activationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let sampleID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        var state = makeBaseState()
        state.registrationWork[registrationID] = makeRegistrationWork(workID: registrationID, createdAt: now)
        state.activationWork[activationID] = makeActivationWork(workID: activationID, createdAt: now)
        state.sampleWork[sampleID] = makeSampleWork(workID: sampleID, createdAt: now)
        let laterSampleID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        state.sampleWork[laterSampleID] = makeSampleWork(workID: laterSampleID, createdAt: now)

        let due = state.dueWork(now: now)
        XCTAssertEqual(due.map(\.kind), [.registration, .activation, .sample, .sample])
        XCTAssertEqual(due.map(\.workID), [registrationID, activationID, sampleID, laterSampleID])
    }

    func testCompletedInstallPhasesDoNotBlockDueNetworkSamples() throws {
        var state = makeBaseState()
        state.installWork.removeAll()
        state.sampleWork.removeAll()
        let nonActionablePhases: [ActivityInstallPhase] = [
            .verified, .dualActive, .active, .pendingStop, .stopped
        ]
        for (index, phase) in nonActionablePhases.enumerated() {
            let workID = UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index + 1))!
            state.installWork[workID] = ActivityInstallWork(
                workID: workID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: phase,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: "historical_install_state",
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(TimeInterval(index))
            )
        }
        let sampleID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        state.sampleWork[sampleID] = makeSampleWork(
            workID: sampleID,
            createdAt: start.addingTimeInterval(10)
        )

        let due = state.dueWork(now: start.addingTimeInterval(10))

        XCTAssertEqual(due.map(\.workID), [sampleID])
        XCTAssertEqual(due.map(\.kind), [.sample])
    }

    func testWaitingForRegistrationSampleIsNotNetworkDueUntilPromoted() throws {
        var state = makeBaseState()
        state.installWork.removeAll()
        state.sampleWork.removeAll()
        let sampleID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        var sample = makeSampleWork(workID: sampleID, createdAt: start)
        sample.authorization = .waitingForRegistration
        state.sampleWork[sampleID] = sample

        XCTAssertTrue(state.dueWork(now: start).isEmpty)

        state.sampleWork[sampleID]?.authorization = .v2Deliverable
        XCTAssertEqual(state.dueWork(now: start).map(\.workID), [sampleID])
    }

    func testTombstonedActivationDoesNotBlockNewRegistration() throws {
        var state = makeBaseState()
        state.registrationWork.removeAll()
        state.activationWork.removeAll()

        let staleActivationID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        state.activationWork[staleActivationID] = makeActivationWork(
            workID: staleActivationID,
            createdAt: start
        )
        state.routes[routeID]?.lifecycle = .tombstoned

        let freshRegistrationID = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
        state.registrationWork[freshRegistrationID] = makeRegistrationWork(
            workID: freshRegistrationID,
            createdAt: start.addingTimeInterval(1)
        )

        let due = state.dueWork(now: start.addingTimeInterval(1))

        XCTAssertEqual(due.map(\.workID), [freshRegistrationID])
        XCTAssertEqual(due.map(\.kind), [.registration])
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

    func testRegistrationDispatchesBeforeActivationAndLeavesActivationPendingUntilDualActive() async throws {
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
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
            (try encoded(registrationResponse), response)
        ]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: clock)

        try delivery.enqueueRegistration(registration, owner: owner, epochID: epochID, routeID: routeID)
        try delivery.enqueueActivation(activation, owner: owner, epochID: epochID, routeID: routeID)
        XCTAssertEqual(try store.read().ratchets[owner]?.localSelection, .v1)

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/child/earned-time/epochs"])
        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .pending)
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

    func testDelayedRegistration200SupersedesRetiredOrNoLongerCandidateGeneration() async throws {
        for retired in [true, false] {
            let fileURL = temporaryStoreURL()
            defer { removeTemporaryStore(fileURL) }
            let store = makeStore(fileURL: fileURL)
            try store.transaction(expectedOwner: owner) { state in
                state = makeBaseState()
                let route = try XCTUnwrap(state.routes[routeID])
                if retired {
                    state.generations[route.generationID]?.retiredAt = self.start
                } else {
                    let generation = try XCTUnwrap(state.generations[route.generationID])
                    let replacementID = UUID()
                    state.generations[replacementID] = MeteringPolicyGeneration(
                        generationID: replacementID,
                        protocolVersion: generation.protocolVersion,
                        childDeviceID: generation.childDeviceID,
                        canonicalTimezone: generation.canonicalTimezone,
                        policyRevision: generation.policyRevision,
                        measurementSelectionDigest: generation.measurementSelectionDigest,
                        enforcementSetID: generation.enforcementSetID,
                        measurementSelectionBytes: generation.measurementSelectionBytes,
                        createdAt: generation.createdAt,
                        retiredAt: nil
                    )
                    state.activeGenerationID = replacementID
                    state.activeRouteID = nil
                }
            }
            let installID = UUID()
            try store.transaction(expectedOwner: owner) { state in
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
            let transport = DeliveryTestTransport()
            transport.results = [(try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil),
                epochStatus: .active
            )), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)]
            let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

            try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
            await delivery.drain(owner: owner)

            let final = try store.read()
            XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .superseded)
            XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "route_superseded")
            XCTAssertNil(final.registrationWork.values.first?.claim)
            XCTAssertNil(final.epochs[epochID]?.registeredAt)
            XCTAssertNil(final.ratchets[owner]?.registeredV2At)
            XCTAssertEqual(final.installWork[installID]?.authorization, .registrationRequired)
        }
    }

    func testDelayedRegistration200SupersedesRetiredEpoch() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { $0 = makeBaseState() }
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(EpochRegistrationResponseDTO(
            status: .registered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil),
            epochStatus: .active
        )), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)]
        transport.onRequest = { _ in
            try? store.transaction(expectedOwner: self.owner) { state in
                state.epochs[self.epochID]?.status = .retired
                state.epochs[self.epochID]?.retiredAt = self.start
            }
        }
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .superseded)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "route_superseded")
        XCTAssertNil(final.registrationWork.values.first?.claim)
        XCTAssertNil(final.epochs[epochID]?.registeredAt)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
    }

    func testReplacementRegistrationWaitsForExactCutoverReadyBarrier() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let candidateGenerationID = UUID()
        let candidateEpochID = UUID()
        let candidateRouteID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let generation = try XCTUnwrap(state.generations[state.activeGenerationID!])
            let epoch = try XCTUnwrap(state.epochs[epochID])
            let route = try XCTUnwrap(state.routes[routeID])
            state.generations[candidateGenerationID] = MeteringPolicyGeneration(
                generationID: candidateGenerationID,
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                measurementSelectionBytes: generation.measurementSelectionBytes,
                createdAt: generation.createdAt,
                retiredAt: nil
            )
            state.epochs[candidateEpochID] = DeviceDailyEpoch(
                epochID: candidateEpochID,
                protocolVersion: epoch.protocolVersion,
                childDeviceID: epoch.childDeviceID,
                usageDate: epoch.usageDate,
                canonicalTimezone: epoch.canonicalTimezone,
                policyRevision: epoch.policyRevision,
                measurementSelectionDigest: epoch.measurementSelectionDigest,
                enforcementSetID: epoch.enforcementSetID,
                startedAt: epoch.startedAt,
                registeredAt: nil,
                baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                baseSource: epoch.baseSource,
                lastRawThresholdMinutes: epoch.lastRawThresholdMinutes,
                excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
                status: .active,
                resumeBoundaryPending: epoch.resumeBoundaryPending,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            state.routes[candidateRouteID] = MeteringCallbackRoute(
                routeID: candidateRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: candidateRouteID),
                namespace: route.namespace,
                generationID: candidateGenerationID,
                generationKey: route.generationKey,
                ownerChildDeviceID: self.owner,
                usageDate: route.usageDate,
                epochID: candidateEpochID,
                plannedSchedule: route.plannedSchedule,
                installedSchedule: nil,
                plannedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: candidateRouteID, thresholdMinutes: 10), thresholdMinutes: 10)],
                installedEvents: nil,
                lifecycle: .planned,
                createdAt: self.start
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: self.owner,
                fromGenerationID: route.generationID,
                fromEpochID: route.epochID,
                fromRouteID: route.routeID,
                toGenerationID: candidateGenerationID,
                toEpochID: candidateEpochID,
                toRouteID: candidateRouteID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: self.start
            )
        }
        let request = EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: candidateEpochID,
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
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(EpochRegistrationResponseDTO(
            status: .registered,
            epochID: candidateEpochID,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil),
            epochStatus: .active
        )), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        try delivery.enqueueRegistration(request, owner: owner, epochID: candidateEpochID, routeID: candidateRouteID)
        await delivery.drain(owner: owner)

        var waiting = try store.read()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(waiting.registrationWork.values.first?.retry.terminal, .pending)

        try store.transaction(expectedOwner: owner) { state in
            state.v2RouteHandoff?.phase = .dualV2
        }
        await delivery.drain(owner: owner)

        waiting = try store.read()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(waiting.registrationWork.values.first?.retry.terminal, .pending)

        try store.transaction(expectedOwner: owner) { state in
            state.v2RouteHandoff?.phase = .cutoverReady
            state.v2RouteHandoff?.priorRouteInputClosedAt = self.start
        }
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.epochs[candidateEpochID]?.registeredAt, start)
        XCTAssertNotNil(final.ratchets[owner]?.registeredV2At)
        XCTAssertEqual(final.activeRouteID, routeID)
        XCTAssertEqual(final.routes[routeID]?.lifecycle, .active)
    }

    func testAuthoritativeBaseMismatchWithMismatchedSnapshotTerminalizesImmediately() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let before = makeBaseState()
        try store.transaction(expectedOwner: owner) { $0 = before }
        let conflict = EpochRegistrationConflictDTO(
            code: .authoritativeBaseMismatch,
            authoritativeSnapshot: DeviceDaySnapshotDTO(
                childDeviceID: UUID(),
                usageDate: "2026-07-15",
                estimatedMinutes: 30,
                capMinutes: 60,
                childDayState: "active",
                usedMinutes: 30,
                remainingMinutes: 30,
                counted: true,
                warning: nil
            )
        )
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(conflict), HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!)]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        try delivery.enqueueRegistration(makeValidRegistrationRequest(), owner: owner, epochID: epochID, routeID: routeID)
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "snapshot_mismatch")
        XCTAssertNil(final.registrationWork.values.first?.claim)
        XCTAssertEqual(final.epochs, before.epochs)
        XCTAssertEqual(final.ratchets, before.ratchets)
        XCTAssertTrue(final.installWork.isEmpty)
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

    func testDrainSettlesUnclaimedStaleRegistrationHeadThenDispatchesLaterNetworkWork() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let staleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sampleID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.routes[routeID]?.lifecycle = .retired
            state.activeRouteID = nil
            state.registrationWork[staleID] = makeRegistrationWork(workID: staleID, createdAt: start)
            var sample = makeSampleWork(workID: sampleID, createdAt: start.addingTimeInterval(1))
            sample.retry.nextAttemptAt = start
            state.sampleWork[sampleID] = sample
            XCTAssertEqual(state.dueWork(now: start).first?.workID, staleID)
        }
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(makeSnapshot(counted: true, warning: nil)), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.path, "/child/earned-time/sample")
        XCTAssertEqual(final.registrationWork[staleID]?.retry.terminal, .superseded)
        XCTAssertEqual(final.registrationWork[staleID]?.retry.lastErrorCode, "route_superseded")
        XCTAssertNil(final.registrationWork[staleID]?.claim)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .succeeded)
        XCTAssertNil(final.sampleWork[sampleID]?.claim)
        XCTAssertNil(final.epochs[epochID]?.registeredAt)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
    }

    func testDrainSettlesUnauthorizedActivationHeadThenDispatchesLaterNetworkWork() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let staleActivationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sampleID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let currentGenerationID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
            let selectionBytes = Data([0x03, 0x04])
            let selectionDigest = MeteringEpochContract.selectionDigest(persistedBytes: selectionBytes)
            state.generations[currentGenerationID] = MeteringPolicyGeneration(
                generationID: currentGenerationID,
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: "America/New_York",
                policyRevision: "policy-2",
                measurementSelectionDigest: selectionDigest,
                enforcementSetID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                measurementSelectionBytes: selectionBytes,
                createdAt: start,
                retiredAt: nil
            )
            state.activeGenerationID = currentGenerationID
            state.activeRouteID = nil
            state.ratchets[owner]?.localSelection = .v2
            state.activationWork[staleActivationID] = makeActivationWork(
                workID: staleActivationID,
                createdAt: start.addingTimeInterval(-1)
            )
            state.sampleWork[sampleID] = makeSampleWork(
                workID: sampleID,
                createdAt: start
            )
            XCTAssertEqual(state.dueWork(now: start).first?.workID, staleActivationID)
        }
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let transport = DeliveryTestTransport()
        transport.results = [(try encoded(makeSnapshot(counted: true, warning: nil)), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.path, "/child/earned-time/sample")
        XCTAssertEqual(final.activationWork[staleActivationID]?.retry.terminal, .superseded)
        XCTAssertEqual(
            final.activationWork[staleActivationID]?.retry.lastErrorCode,
            "route_superseded"
        )
        XCTAssertNil(final.activationWork[staleActivationID]?.claim)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .succeeded)
    }

    func testDrainDoesNotSettleStaleRegistrationWithLiveForeignClaimButSettlesItAfterExpiry() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let staleID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let sampleID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let foreignClaim = MeteringNetworkClaim(
            token: UUID(),
            claimedAt: start,
            expiresAt: start.addingTimeInterval(MeteringNetworkClaim.leaseDuration)
        )
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.routes[routeID]?.lifecycle = .retired
            state.activeRouteID = nil
            var stale = makeRegistrationWork(workID: staleID, createdAt: start)
            stale.claim = foreignClaim
            state.registrationWork[staleID] = stale
            var sample = makeSampleWork(workID: sampleID, createdAt: start.addingTimeInterval(1))
            sample.retry.nextAttemptAt = start
            state.sampleWork[sampleID] = sample
        }
        let transport = DeliveryTestTransport()
        let clock = DeliveryTestClock(now: start)
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: clock)

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try store.read().registrationWork[staleID]?.retry.terminal, .pending)
        XCTAssertEqual(try store.read().registrationWork[staleID]?.claim, foreignClaim)

        clock.now = foreignClaim.expiresAt
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [(try encoded(makeSnapshot(counted: true, warning: nil)), response)]
        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.registrationWork[staleID]?.retry.terminal, .superseded)
        XCTAssertNil(final.registrationWork[staleID]?.claim)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .succeeded)
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

    func testAcceptedSampleResponseSettlesAfterEpochPausesInFlight() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.sampleWork[sampleID] = makeV2SampleWork(workID: sampleID, createdAt: start)
        }
        let transport = DeferredDeliveryTransport()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        let drain = Task { await delivery.drain(owner: owner) }
        while transport.requests.isEmpty { await Task.yield() }
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[epochID]?.status = .paused
        }
        let accepted = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        transport.resume(with: (try encoded(makeSnapshot(counted: true, warning: nil)), accepted))
        await drain.value

        let final = try XCTUnwrap(try store.read().sampleWork[sampleID])
        XCTAssertEqual(final.retry.terminal, .succeeded)
        XCTAssertNil(final.claim)
    }

    func testRetryableSampleResponseTerminalizesWhenEpochPausesInFlight() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.sampleWork[sampleID] = makeV2SampleWork(workID: sampleID, createdAt: start)
        }
        let transport = DeferredDeliveryTransport()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        let drain = Task { await delivery.drain(owner: owner) }
        while transport.requests.isEmpty { await Task.yield() }
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[epochID]?.status = .paused
        }
        let unavailable = HTTPURLResponse(
            url: baseURL,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        )!
        transport.resume(with: (Data(#"{"code":"temporarily_unavailable"}"#.utf8), unavailable))
        await drain.value

        let final = try XCTUnwrap(try store.read().sampleWork[sampleID])
        XCTAssertEqual(final.retry.terminal, .rejected)
        XCTAssertEqual(final.retry.lastErrorCode, "accounting_paused")
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

    func testReadyInstallAtGlobalDueHeadDoesNotBlockLegacySample() async throws {
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
            (Data(#"{"code":"duplicate"}"#.utf8), HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        ]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().sampleWork.values.first?.retry.terminal, .succeeded)
    }

    func testWaitingForRegistrationSampleDoesNotBlockDeliverableLegacySample() async throws {
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
            (Data(#"{"code":"duplicate"}"#.utf8), HTTPURLResponse(url: baseURL, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        ]
        let delivery = MeteringEpochDelivery(baseURL: baseURL, store: store, transport: transport, clock: DeliveryTestClock(now: start))

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(
            final.sampleWork.values.first(where: {
                $0.request.clientSampleID == "waiting-for-registration"
            })?.retry.terminal,
            .pending
        )
        XCTAssertEqual(
            final.sampleWork.values.first(where: {
                $0.request.clientSampleID != "waiting-for-registration"
            })?.retry.terminal,
            .succeeded
        )
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
                authorizeInitialDualActiveActivation(&state)
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
            authorizeInitialDualActiveActivation(&state)
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
        let before = makeBaseState()
        try store.transaction(expectedOwner: owner) { $0 = before }
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

        let final = try store.read()
        XCTAssertNil(final.epochs[epochID]?.authoritativeBaseConflict)
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "snapshot_mismatch")
        XCTAssertNil(final.registrationWork.values.first?.claim)
        XCTAssertEqual(final.epochs, before.epochs)
        XCTAssertEqual(final.ratchets, before.ratchets)
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
            authorizeInitialDualActiveActivation(&state)
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

    func testActivationAcknowledgementReleasesWaitingCandidateSample() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.epochs[epochID]?.registeredAt = start
            let registrationID = UUID()
            var registration = makeRegistrationWork(workID: registrationID, createdAt: start)
            registration.retry.terminal = .succeeded
            state.registrationWork[registrationID] = registration
            state.installWork[UUID()] = makeVerifiedInstallWork(createdAt: start)
            authorizeInitialDualActiveActivation(&state)
            let route = try XCTUnwrap(state.routes[routeID])
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: route.usageDate,
                    timezone: route.plannedSchedule.timezoneIdentifier,
                    activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                    eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 10),
                    thresholdMinutes: 10,
                    estimatedMinutes: 10,
                    observedAt: start,
                    clientSampleID: "wait-for-activation",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .waitingForRegistration,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let transport = DeliveryTestTransport()
        transport.results = [
            (try encoded(EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .active,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil)
            )), response),
            (try encoded(makeSnapshot(counted: true, warning: nil)), response),
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(
                protocolVersion: 2,
                deviceID: owner,
                routeID: routeID,
                verifiedAt: start
            ),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/child/earned-time/epochs/\(epochID.uuidString.lowercased())/activation",
            "/child/earned-time/sample",
        ])
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.sampleWork[sampleID]?.authorization, .v2Deliverable)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .succeeded)
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
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "authoritative_base_conflict")
        XCTAssertNil(final.registrationWork.values.first?.claim)
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

    func testDeviceIdentityChangedRetriesAllV2NetworkLanes() {
        let response = Data(#"{"code":"device_identity_changed"}"#.utf8)

        XCTAssertEqual(
            MeteringEpochDelivery.sampleDisposition(data: response, statusCode: 409),
            .retry(code: "device_identity_changed")
        )
        XCTAssertEqual(
            MeteringEpochDelivery.registrationDisposition(data: response, statusCode: 409),
            .retry(code: "device_identity_changed")
        )
        XCTAssertEqual(
            MeteringEpochDelivery.activationDisposition(data: response, statusCode: 409),
            .retry(code: "device_identity_changed")
        )
    }

    func testRegistration2xxRequiresV2ProtocolAndKnownEpochLifecycle() throws {
        let snapshot = makeSnapshot(counted: true, warning: nil)
        let paused = EpochRegistrationResponseDTO(
            status: .alreadyRegistered,
            epochID: epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot,
            epochStatus: .paused
        )
        XCTAssertEqual(
            MeteringEpochDelivery.registrationDisposition(
                data: try encoded(paused),
                statusCode: 200
            ),
            .registered(paused),
            "a paused epoch is still the exact v2 identity the backend registered"
        )

        for response in [
            EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 1,
                snapshot: snapshot,
                epochStatus: .active
            ),
            EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: snapshot,
                epochStatus: nil
            )
        ] {
            guard case .terminal = MeteringEpochDelivery.registrationDisposition(
                data: try encoded(response),
                statusCode: 200
            ) else {
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

    func testPausedActivationPreservesV2IdentityAndReportsPausedLifecycle() throws {
        let response = EpochActivationResponseDTO(
            status: .paused,
            epochID: epochID,
            epochStatus: .paused,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: false, warning: nil)
        )

        XCTAssertEqual(
            MeteringEpochDelivery.activationDisposition(
                data: try encoded(response),
                statusCode: 200
            ),
            .retry(code: "epoch_paused")
        )
    }

    func testFirstActivationAcknowledgesExhaustedEpoch() throws {
        let response = EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .exhausted,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil)
        )

        let disposition = MeteringEpochDelivery.activationDisposition(
            data: try encoded(response),
            statusCode: 200
        )

        guard case let .acknowledged(acknowledged) = disposition else {
            return XCTFail("an installed epoch that exhausted before activation must still commit")
        }
        XCTAssertEqual(acknowledged.epochStatus, .exhausted)
    }

    func testClockSkewActivationRejectionIsRetryable() {
        let disposition = MeteringEpochDelivery.activationDisposition(
            data: Data(#"{"detail":"activation_verified_at_invalid"}"#.utf8),
            statusCode: 409
        )

        XCTAssertEqual(
            disposition,
            .retry(code: "activation_verified_at_invalid")
        )
    }

    func testColdReopenRetriesPreviouslyRejectedClockSkewActivation() async throws {
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
            authorizeInitialDualActiveActivation(&state)
        }

        let transport = DeliveryTestTransport()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(
                protocolVersion: 2,
                deviceID: owner,
                routeID: routeID,
                verifiedAt: start
            ),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )
        try store.transaction(expectedOwner: owner) { state in
            let key = try XCTUnwrap(state.activationWork.keys.first)
            state.activationWork[key]?.retry = MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: start,
                lastErrorCode: "activation_verified_at_invalid",
                terminal: .rejected
            )
        }

        let response = EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil)
        )
        transport.results = [(
            try encoded(response),
            HTTPURLResponse(
                url: baseURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )]

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(
            try store.read().activationWork.values.first?.retry.terminal,
            .succeeded
        )
    }

    func testColdReopenNormalizesSharedPoolExhaustionBelowDeviceCap() async throws {
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
            authorizeInitialDualActiveActivation(&state)
        }

        let transport = DeliveryTestTransport()
        let response409 = HTTPURLResponse(
            url: baseURL,
            statusCode: 409,
            httpVersion: nil,
            headerFields: nil
        )!
        transport.results = [
            (Data(#"{"detail":"activation_epoch_not_current"}"#.utf8), response409)
        ]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(
                protocolVersion: 2,
                deviceID: owner,
                routeID: routeID,
                verifiedAt: start
            ),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)
        XCTAssertEqual(try store.read().activationWork.values.first?.retry.terminal, .rejected)

        let response200 = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        transport.results = [
            (try encoded(EpochActivationResponseDTO(
                status: .activated,
                epochID: epochID,
                epochStatus: .exhausted,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: true, warning: nil)
            )), response200)
        ]

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.epochs[epochID]?.status, .active)
    }

    func testUpgradeRepairsSucceededActivationExhaustedBelowDeviceCap() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.epochs[epochID]?.status = .exhausted
            if let generationID = state.activeGenerationID {
                state.generations[generationID]?.configuredPoolMinutes = 120
                state.generations[generationID]?.configuredDeviceCapMinutes = 60
            }
            state.ratchets[owner]?.localSelection = .v2
            var activation = makeActivationWork(workID: UUID(), createdAt: start)
            activation.retry.terminal = .succeeded
            state.activationWork[activation.workID] = activation
        }
        let transport = DeliveryTestTransport()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try store.read().epochs[epochID]?.status, .active)
    }

    func testUpgradeDoesNotReopenEpochAtDeviceCap() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            state.epochs[epochID]?.status = .exhausted
            state.routes[routeID]?.ladderBaseMinutes = 60
            if let generationID = state.activeGenerationID {
                state.generations[generationID]?.configuredPoolMinutes = 120
                state.generations[generationID]?.configuredDeviceCapMinutes = 60
            }
            state.ratchets[owner]?.localSelection = .v2
            var activation = makeActivationWork(workID: UUID(), createdAt: start)
            activation.retry.terminal = .succeeded
            state.activationWork[activation.workID] = activation
        }
        let transport = DeliveryTestTransport()
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )

        await delivery.drain(owner: owner)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try store.read().epochs[epochID]?.status, .exhausted)
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
                epochStatus: .retired
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
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .superseded)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testPausedRegistrationTerminalizesWaitingSamplesWithoutCreditingThem() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let route = try XCTUnwrap(state.routes[routeID])
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
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
                    clientSampleID: "paused-registration-sample",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .waitingForRegistration,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        transport.results = [(
            try encoded(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epochID,
                meteringProtocolVersion: 2,
                snapshot: makeSnapshot(counted: false, warning: nil),
                epochStatus: .paused
            )),
            response
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(
            makeValidRegistrationRequest(),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(final.epochs[epochID]?.status, .paused)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .rejected)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.lastErrorCode, "accounting_paused")
        XCTAssertEqual(final.sampleWork[sampleID]?.authorization, .waitingForRegistration)
    }

    func testTerminalRegistrationReapsWaitingSampleForRejectedRoute() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        let sampleID = UUID()
        let activationID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let route = try XCTUnwrap(state.routes[routeID])
            state.activationWork[activationID] = EpochActivationWork(
                workID: activationID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: owner,
                    routeID: routeID,
                    verifiedAt: start
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(1)
            )
            state.sampleWork[sampleID] = EpochSampleWork(
                workID: sampleID,
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
                    clientSampleID: "terminal-registration-sample",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .waitingForRegistration,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
        }
        let transport = DeliveryTestTransport()
        transport.results = [(
            Data(#"{"code":"policy_revision_mismatch"}"#.utf8),
            HTTPURLResponse(
                url: baseURL,
                statusCode: 409,
                httpVersion: nil,
                headerFields: nil
            )!
        )]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueRegistration(
            makeValidRegistrationRequest(),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(final.registrationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.registrationWork.values.first?.retry.lastErrorCode, "policy_revision_mismatch")
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .superseded)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.lastErrorCode, "registration_policy_revision_mismatch")
        XCTAssertNil(final.sampleWork[sampleID]?.claim)
        XCTAssertEqual(final.activationWork[activationID]?.retry.terminal, .superseded)
        XCTAssertEqual(
            final.activationWork[activationID]?.retry.lastErrorCode,
            "registration_policy_revision_mismatch"
        )
        XCTAssertNil(final.activationWork[activationID]?.claim)
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
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .superseded)
        XCTAssertNil(final.ratchets[owner]?.registeredV2At)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .v1)
    }

    func testMismatchedActivationEpochCannotSucceed() async throws {
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
            authorizeInitialDualActiveActivation(&state)
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
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
        XCTAssertEqual(final.activationWork.values.first?.retry.lastErrorCode, "epoch_mismatch")
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .rejected)
        XCTAssertEqual(final.ratchets[owner]?.localSelection, .dualActive)
    }

    func testFuturePendingInstallCannotBlockActivationOnceCandidateInstallIsDualActive() async throws {
        let fileURL = temporaryStoreURL()
        defer { removeTemporaryStore(fileURL) }
        let store = makeStore(fileURL: fileURL)
        try store.transaction(expectedOwner: owner) { state in
            state = makeBaseState()
            let plannedRouteID = UUID()
            let currentRoute = try XCTUnwrap(state.routes[routeID])
            state.routes[plannedRouteID] = MeteringCallbackRoute(
                routeID: plannedRouteID,
                activityName: "evlin.earned.budget.\(plannedRouteID.uuidString.lowercased())",
                namespace: currentRoute.namespace,
                generationID: currentRoute.generationID,
                generationKey: currentRoute.generationKey,
                ownerChildDeviceID: owner,
                usageDate: currentRoute.usageDate,
                epochID: epochID,
                plannedSchedule: currentRoute.plannedSchedule,
                installedSchedule: currentRoute.plannedSchedule,
                plannedEvents: currentRoute.plannedEvents,
                installedEvents: currentRoute.plannedEvents,
                lifecycle: .planned,
                createdAt: start.addingTimeInterval(-1)
            )
            let plannedInstallID = UUID()
            state.installWork[plannedInstallID] = ActivityInstallWork(
                workID: plannedInstallID,
                ownerChildDeviceID: owner,
                routeID: plannedRouteID,
                authorization: .futurePlanned,
                phase: .pendingStart,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start.addingTimeInterval(-1),
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-1)
            )
            let registrationID = UUID()
            var registration = makeRegistrationWork(workID: registrationID, createdAt: start)
            registration.retry.terminal = .succeeded
            state.registrationWork[registrationID] = registration
            state.installWork[UUID()] = ActivityInstallWork(
                workID: UUID(),
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .dualActive,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
            authorizeInitialDualActiveActivation(&state)
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.results = [
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
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: routeID, verifiedAt: start),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        let final = try store.read()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .succeeded)
    }

    func testInitialActivationDoesNotDeadlockWhenNoLegacyMonitorStateExists() async throws {
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
                workID: UUID(),
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .dualActive,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start
            )
            authorizeInitialDualActiveActivation(&state)
            state.legacy = nil
        }
        let transport = DeliveryTestTransport()
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        transport.results = [(try encoded(EpochActivationResponseDTO(
            status: .activated,
            epochID: epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: makeSnapshot(counted: true, warning: nil)
        )), response)]
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: store,
            transport: transport,
            clock: DeliveryTestClock(now: start)
        )
        try delivery.enqueueActivation(
            EpochActivationRequestDTO(
                protocolVersion: 2,
                deviceID: owner,
                routeID: routeID,
                verifiedAt: start
            ),
            owner: owner,
            epochID: epochID,
            routeID: routeID
        )

        await delivery.drain(owner: owner)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.read().activationWork.values.first?.retry.terminal, .succeeded)
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
        XCTAssertEqual(final.activationWork.values.first?.retry.terminal, .superseded)
        XCTAssertEqual(final.sampleWork[sampleID]?.retry.terminal, .superseded)
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

    private func makeV2SampleWork(workID: UUID, createdAt: Date) -> EpochSampleWork {
        EpochSampleWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: epochID,
            routeID: routeID,
            request: EpochSampleRequestDTO(
                deviceID: owner,
                usageDate: "2026-07-16",
                timezone: "America/New_York",
                activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                eventName: MeteringSampleWireAliases.eventName(thresholdMinutes: 10),
                thresholdMinutes: 10,
                estimatedMinutes: 10,
                observedAt: start,
                clientSampleID: MeteringSampleWireAliases.clientSampleID(
                    lane: .v2,
                    routeID: routeID,
                    thresholdMinutes: 10
                ),
                protocolVersion: 2,
                epochID: epochID,
                generationArmedAt: nil,
                generationOffsetMinutes: nil
            ),
            authorization: .v2Deliverable,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: createdAt,
                lastErrorCode: nil,
                terminal: .pending
            ),
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

    private func authorizeInitialDualActiveActivation(_ state: inout DeviceEpochStoreState) {
        state.activeRouteID = nil
        state.routes[routeID]?.lifecycle = .active
        state.ratchets[owner] = MeteringOwnerRatchet(
            ownerChildDeviceID: owner,
            advertisedVersion: 1,
            localSelection: .dualActive,
            registeredV2At: start,
            dualActiveAt: start,
            activatedV2At: nil
        )
        state.legacy = LegacyCompatibilityMonitorState(
            ownerChildDeviceID: owner,
            lifecycleVersion: 1,
            active: LegacyGenerationProvenance(
                activityName: "evlin.earned.legacy",
                deviceID: owner.uuidString,
                offsetMinutes: 0,
                usageDate: "2026-07-16",
                timezoneIdentifier: "America/New_York",
                armedAt: start
            ),
            pending: nil,
            retiringActivityNames: [],
            breadcrumbActivityNames: [],
            scalarActiveActivityName: "evlin.earned.legacy",
            isStopped: false,
            phase: .activeV1,
            stopAcknowledgedAt: nil
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
