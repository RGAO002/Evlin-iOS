import Foundation
import XCTest
@testable import Evlin_iOS

final class DeviceEpochStoreTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherOwner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUp() {
        super.setUp()
        clearLegacyDefaults()
    }

    override func tearDown() {
        clearLegacyDefaults()
        super.tearDown()
    }

    func testAbsentRootBootstrapsCurrentEmptyState() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)

        let state = try store.read()

        XCTAssertEqual(state.schemaVersion, DeviceEpochStoreState.currentSchemaVersion)
        XCTAssertNil(state.ownerChildDeviceID)
        XCTAssertTrue(state.generations.isEmpty)
        XCTAssertTrue(state.epochs.isEmpty)
        XCTAssertTrue(state.routes.isEmpty)
        XCTAssertNil(io.data)
    }

    func testOneTransactionRoundTripsEveryPersistedFieldAndExactSelectionBytes() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let expected = makeState()

        try store.transaction(expectedOwner: owner) { state in
            state = expected
        }

        XCTAssertEqual(try store.read(), expected)
        XCTAssertEqual(expected.generations[expected.activeGenerationID!]?.measurementSelectionBytes,
                       Data([0x00, 0x01, 0xFE, 0xFF]))
        XCTAssertEqual(io.writeCount, 1)
    }

    func testFutureSchemaIsRefusedWithoutWriting() throws {
        let io = TestFileIO()
        io.data = Data(#"{"schemaVersion":5}"#.utf8)
        let store = makeStore(io: io)
        let original = io.data

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .unsupportedSchema(5))
        }
        XCTAssertEqual(io.data, original)
        XCTAssertEqual(io.writeCount, 0)
    }

    func testTransactionKeepsPriorBytesWhenMutationOrWriteFails() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let expected = makeState()
        try store.transaction(expectedOwner: owner) { $0 = expected }
        let priorBytes = io.data

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.activeEpochID = UUID()
            throw TestError.mutation
        })
        XCTAssertEqual(io.data, priorBytes)

        io.failWrite = true
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.activeEpochID = nil
        })
        XCTAssertEqual(io.data, priorBytes)
    }

    func testInjectedLockAndReadFailuresAreReturnedWithoutMutation() throws {
        let io = TestFileIO()
        let lock = TestLock()
        let store = makeStore(io: io, lock: lock)

        lock.available = false
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .lockUnavailable)
        }
        lock.available = true

        io.failRead = true
        XCTAssertThrowsError(try store.read())
        XCTAssertNil(io.data)
    }

    func testReadbackMismatchRestoresPriorBytes() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        try store.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        io.readbackData = Data(#"{"schemaVersion":4}"#.utf8)

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        }) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .readbackMismatch)
        }
        XCTAssertEqual(io.data, priorBytes)
    }

    func testOwnerMismatchBeforeMutationDoesNotInvokeMutation() throws {
        let io = TestFileIO()
        let store = makeStore(io: io, ownerProvider: { self.otherOwner })
        var didMutate = false

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { _ in
            didMutate = true
        }) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertFalse(didMutate)
        XCTAssertNil(io.data)
    }

    func testOwnerChangeBeforeWriteLeavesPriorBytesUnchanged() throws {
        let io = TestFileIO()
        var calls = 0
        var initializing = true
        let store = makeStore(io: io, ownerProvider: {
            calls += 1
            return initializing ? (calls <= 3 ? self.owner : self.otherOwner) : (calls == 1 ? self.owner : self.otherOwner)
        })
        try store.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        initializing = false
        calls = 0

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        }) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(io.data, priorBytes)
        XCTAssertEqual(io.writeCount, 1)
    }

    func testOwnerChangeAfterReadbackRestoresPriorBytes() throws {
        let io = TestFileIO()
        let stableStore = makeStore(io: io)
        try stableStore.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        var calls = 0
        let store = makeStore(io: io, ownerProvider: {
            calls += 1
            return calls < 3 ? self.owner : self.otherOwner
        })

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        }) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(io.data, priorBytes)
    }

    func testDualV2ReferencesSameOwnerRoutesAndKeepsPriorRouteActiveUntilCommit() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let state = makeState()

        try store.transaction(expectedOwner: owner) { $0 = state }
        XCTAssertEqual(try store.read().activeRouteID, state.v2RouteHandoff?.fromRouteID)

        var invalid = state
        invalid.v2RouteHandoff?.phase = .cutoverReady
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = invalid })
    }

    func testCommittedHandoffRequiresCandidateActivationAndPriorStopAcknowledgements() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let state = makeState()
        try store.transaction(expectedOwner: owner) { $0 = state }

        var committed = state
        committed.v2RouteHandoff?.phase = .committed
        committed.activeRouteID = committed.v2RouteHandoff?.toRouteID
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = committed })

        committed.v2RouteHandoff?.activationAcknowledgedAt = Date(timeIntervalSince1970: 300)
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = committed })

        committed.v2RouteHandoff?.priorStopAcknowledgedAt = Date(timeIntervalSince1970: 301)
        try store.transaction(expectedOwner: owner) { $0 = committed }
        XCTAssertEqual(try store.read().activeRouteID, committed.v2RouteHandoff?.toRouteID)
    }

    func testCutoverBarrierRejectsPriorWorkCreatedBeforeOrAfterBarrier() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var state = makeState()
        let barrier = Date(timeIntervalSince1970: 150)
        state.v2RouteHandoff?.phase = .cutoverReady
        state.v2RouteHandoff?.priorRouteInputClosedAt = barrier

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = state })

        state.sampleWork = state.sampleWork.mapValues { work in
            var copy = work
            copy.retry.terminal = .succeeded
            return copy
        }
        try store.transaction(expectedOwner: owner) { $0 = state }

        var afterBarrier = state
        let priorWorkID = afterBarrier.sampleWork.keys.first!
        let priorWork = afterBarrier.sampleWork[priorWorkID]!
        afterBarrier.sampleWork[priorWorkID] = EpochSampleWork(
            workID: priorWork.workID,
            ownerChildDeviceID: priorWork.ownerChildDeviceID,
            epochID: priorWork.epochID,
            routeID: priorWork.routeID,
            request: priorWork.request,
            authorization: priorWork.authorization,
            retry: MeteringRetryState(
                attemptCount: priorWork.retry.attemptCount,
                nextAttemptAt: priorWork.retry.nextAttemptAt,
                lastErrorCode: priorWork.retry.lastErrorCode,
                terminal: .pending
            ),
            createdAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = afterBarrier })
    }

    func testRetryPolicyUsesImmediateThenFiveFifteenSixtyAndThreeHundredSeconds() {
        let now = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(MeteringRetryPolicy.nextAttempt(after: 0, now: now), now.addingTimeInterval(5))
        XCTAssertEqual(MeteringRetryPolicy.nextAttempt(after: 1, now: now), now.addingTimeInterval(5))
        XCTAssertEqual(MeteringRetryPolicy.nextAttempt(after: 2, now: now), now.addingTimeInterval(15))
        XCTAssertEqual(MeteringRetryPolicy.nextAttempt(after: 3, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(MeteringRetryPolicy.nextAttempt(after: 4, now: now), now.addingTimeInterval(300))
        XCTAssertEqual(MeteringRetryPolicy.nextAttempt(after: 99, now: now), now.addingTimeInterval(300))
    }

    private func makeStore(
        io: TestFileIO,
        lock: TestLock = TestLock(),
        ownerProvider: @escaping @Sendable () -> UUID? = { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
    ) -> DeviceEpochStore {
        DeviceEpochStore(
            fileURL: URL(fileURLWithPath: "/tmp/evlin-device-epoch-store-test.json"),
            lock: lock,
            fileIO: io,
            ownerProvider: ownerProvider
        )
    }

    private func clearLegacyDefaults() {
        let defaults = UserDefaults(suiteName: MeteringOwnerMirror.suiteName)
        [
            EarnedActivityGeneration.lifecycleKey,
            EarnedActivityGeneration.lifecycleBreadcrumbsKey,
            EarnedActivityGeneration.activeActivityNameKey,
        ].forEach { defaults?.removeObject(forKey: $0) }
    }

    private func makeState() -> DeviceEpochStoreState {
        let startedAt = Date(timeIntervalSince1970: 100)
        let candidateStartedAt = Date(timeIntervalSince1970: 200)
        let generationID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let priorEpochID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let candidateEpochID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let priorRouteID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let candidateRouteID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let selectionBytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: "digest-r1",
            enforcementSetID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: generationKey.measurementSelectionDigest,
            enforcementSetID: generationKey.enforcementSetID,
            measurementSelectionBytes: selectionBytes,
            createdAt: startedAt,
            retiredAt: nil
        )
        let priorEpoch = DeviceDailyEpoch(
            epochID: priorEpochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: "2026-07-17",
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: "digest-r1",
            enforcementSetID: generationKey.enforcementSetID,
            startedAt: startedAt,
            registeredAt: startedAt,
            baseAcceptedMinutes: 0,
            baseSource: .childState200,
            lastRawThresholdMinutes: 5,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        let candidateEpoch = DeviceDailyEpoch(
            epochID: candidateEpochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: "2026-07-17",
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: "digest-r1",
            enforcementSetID: generationKey.enforcementSetID,
            startedAt: candidateStartedAt,
            registeredAt: nil,
            baseAcceptedMinutes: 5,
            baseSource: .registration200,
            lastRawThresholdMinutes: 5,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        let schedule = DatedSchedulePlan(usageDate: "2026-07-17", timezoneIdentifier: "America/New_York", calendarIdentifier: "gregorian")
        let events = [MeteringEventPlan(eventName: "t5", thresholdMinutes: 5)]
        let priorRoute = MeteringCallbackRoute(
            routeID: priorRouteID,
            activityName: "evlin.earned.budget.(priorRouteID.uuidString.lowercased())",
            namespace: "earned",
            generationID: generationID,
            generationKey: generationKey,
            ownerChildDeviceID: owner,
            usageDate: "2026-07-17",
            epochID: priorEpochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: events,
            installedEvents: events,
            lifecycle: .active,
            createdAt: startedAt
        )
        let candidateRoute = MeteringCallbackRoute(
            routeID: candidateRouteID,
            activityName: "evlin.earned.budget.(candidateRouteID.uuidString.lowercased())",
            namespace: "earned",
            generationID: generationID,
            generationKey: generationKey,
            ownerChildDeviceID: owner,
            usageDate: "2026-07-17",
            epochID: candidateEpochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: events,
            installedEvents: events,
            lifecycle: .active,
            createdAt: candidateStartedAt
        )
        let retry = MeteringRetryState(attemptCount: 0, nextAttemptAt: startedAt, lastErrorCode: nil, terminal: .pending)
        let registration = EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: candidateEpochID,
            deviceID: owner,
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: "digest-r1",
            enforcementSetID: generationKey.enforcementSetID,
            startedAt: candidateStartedAt,
            baseAcceptedMinutes: 5,
            reason: .initial
        )
        let activation = EpochActivationRequestDTO(protocolVersion: 2, deviceID: owner, routeID: candidateRouteID, verifiedAt: candidateStartedAt)
        let sample = EpochSampleRequestDTO(
            deviceID: owner,
            usageDate: "2026-07-17",
            timezone: "America/New_York",
            activityName: priorRoute.activityName,
            eventName: "t5",
            thresholdMinutes: 5,
            estimatedMinutes: 5,
            observedAt: candidateStartedAt,
            clientSampleID: "earned:v2:(priorRouteID.uuidString.lowercased()):t5",
            protocolVersion: 2,
            epochID: priorEpochID,
            generationArmedAt: nil,
            generationOffsetMinutes: nil
        )
        let claim = ActivityInstallClaim(token: UUID(), process: .app, instanceID: UUID(), claimedAt: startedAt, expiresAt: startedAt.addingTimeInterval(60))
        let legacy = LegacyCompatibilityMonitorState(
            ownerChildDeviceID: owner,
            lifecycleVersion: 2,
            active: nil,
            pending: nil,
            retiringActivityNames: [],
            breadcrumbActivityNames: [],
            scalarActiveActivityName: nil,
            isStopped: false,
            phase: .activeV1,
            stopAcknowledgedAt: nil
        )
        let coverage = MonitorCoverageState(ownerChildDeviceID: owner, requiredFromUsageDate: "2026-07-17", requiredThroughUsageDate: "2026-07-24", readyThroughUsageDate: "2026-07-24", status: .ready, refreshedAt: startedAt, errorCode: nil)
        let tombstone = MeteringRouteTombstone(routeID: priorRouteID, activityName: priorRoute.activityName, eventNames: ["t5"], ownerChildDeviceID: owner, usageDate: "2026-07-17", epochID: priorEpochID, generationID: generationID, canonicalDayEnd: startedAt.addingTimeInterval(86_400), stopAcknowledgedAt: nil, referencedWorkIDs: [], retainedUntil: nil)
        let handoff = V2RouteHandoff(handoffID: UUID(), ownerChildDeviceID: owner, fromGenerationID: generationID, fromEpochID: priorEpochID, fromRouteID: priorRouteID, toGenerationID: generationID, toEpochID: candidateEpochID, toRouteID: candidateRouteID, phase: .dualV2, priorRouteInputClosedAt: nil, registrationAcknowledgedAt: nil, activationAcknowledgedAt: nil, priorStopAcknowledgedAt: nil, createdAt: candidateStartedAt)
        let ratchet = MeteringOwnerRatchet(ownerChildDeviceID: owner, advertisedVersion: 1, localSelection: .dualActive, registeredV2At: nil, dualActiveAt: nil, activatedV2At: nil)
        return DeviceEpochStoreState(
            schemaVersion: DeviceEpochStoreState.currentSchemaVersion,
            ownerChildDeviceID: owner,
            generations: [generationID: generation],
            activeGenerationID: generationID,
            epochs: [priorEpochID: priorEpoch, candidateEpochID: candidateEpoch],
            activeEpochID: priorEpochID,
            routes: [priorRouteID: priorRoute, candidateRouteID: candidateRoute],
            activeRouteID: priorRouteID,
            tombstones: [priorRouteID: tombstone],
            v2RouteHandoff: handoff,
            legacy: legacy,
            registrationWork: [UUID(): EpochRegistrationWork(workID: UUID(), ownerChildDeviceID: owner, epochID: candidateEpochID, routeID: candidateRouteID, request: registration, retry: retry, createdAt: candidateStartedAt)],
            activationWork: [UUID(): EpochActivationWork(workID: UUID(), ownerChildDeviceID: owner, epochID: candidateEpochID, routeID: candidateRouteID, request: activation, retry: retry, createdAt: candidateStartedAt)],
            sampleWork: [UUID(): EpochSampleWork(workID: UUID(), ownerChildDeviceID: owner, epochID: priorEpochID, routeID: priorRouteID, request: sample, authorization: .v2Deliverable, retry: retry, createdAt: startedAt)],
            installWork: [UUID(): ActivityInstallWork(workID: UUID(), ownerChildDeviceID: owner, routeID: candidateRouteID, authorization: .registered, phase: .verified, claim: claim, retry: retry, createdAt: candidateStartedAt)],
            shieldReferences: [UUID(): EarnedShieldReference(operationID: UUID(), ownerChildDeviceID: owner, generationID: generationID, epochID: priorEpochID, routeID: priorRouteID, recordKey: "record", expectedRecordBytes: Data([1, 2]), retry: retry, createdAt: startedAt)],
            identityCleanupWork: IdentityCleanupWork(workID: UUID(), oldOwnerChildDeviceID: owner, newOwnerChildDeviceID: otherOwner, oldEpochIDs: [priorEpochID], oldRouteIDs: [priorRouteID], oldActivityNames: [priorRoute.activityName], oldRegistrationWorkIDs: [], oldActivationWorkIDs: [], oldSampleWorkIDs: [], oldInstallWorkIDs: [], oldFallbackKeys: ["fallback"], oldShieldOperationIDs: [], oldUsageDates: ["2026-07-17"], retry: retry, terminalizedWorkIDs: [], purgedFallbackKeys: [], releasedShieldOperationIDs: [], stopAcknowledgedActivityNames: [], clearedUsageDates: [], ownerMirrorTransitionAcknowledged: false, createdAt: startedAt),
            rolloverEffectsWork: RolloverEffectsWork(workID: UUID(), ownerChildDeviceID: owner, fromUsageDate: "2026-07-16", toUsageDate: "2026-07-17", oldEpochID: priorEpochID, newEpochID: candidateEpochID, oldRouteID: priorRouteID, newRouteID: candidateRouteID, retry: retry, earnedSourceResetAcknowledged: false, perAppResetAcknowledged: false, taskStateResetAcknowledged: false, bypassExpiryAcknowledged: false, registrationAcknowledged: false, installAcknowledged: false, activationAcknowledged: false, oldStopAcknowledged: false, createdAt: candidateStartedAt),
            coverage: coverage,
            ratchets: [owner: ratchet]
        )
    }
}

private enum TestError: Error { case mutation }

private final class TestLock: DeviceEpochStoreLocking, @unchecked Sendable {
    var available = true

    func withLock<T>(_ body: () -> T) -> T? {
        available ? body() : nil
    }
}

private final class TestFileIO: DeviceEpochFileIO, @unchecked Sendable {
    var data: Data?
    var readbackData: Data?
    var readbackPending = false
    var failRead = false
    var failWrite = false
    var writeCount = 0

    func read(from url: URL) throws -> Data? {
        if failRead { throw TestError.mutation }
        if readbackPending {
            readbackPending = false
            return readbackData ?? data
        }
        return data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        if failWrite { throw TestError.mutation }
        writeCount += 1
        self.data = data
        readbackPending = true
    }
}
