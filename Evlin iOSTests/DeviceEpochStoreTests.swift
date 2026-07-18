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

        io.failWriteAfterMutationCount = 1
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.activeEpochID = nil
        })
        XCTAssertEqual(io.data, priorBytes)
    }

    func testFailedInitialWriteRestoresAnAbsentRoot() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        io.failWriteAfterMutationCount = 1

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ownerChildDeviceID = owner
        })

        XCTAssertNil(io.data)
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

    func testReadbackReadFailureAfterSuccessfulWriteRestoresPriorBytes() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        try store.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        io.failNextReadback = true

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        })
        XCTAssertEqual(io.data, priorBytes)
        XCTAssertEqual(io.readbackFailureCount, 1)
    }

    func testRestorationFailurePropagatesDeterministicStoreError() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        try store.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        io.failWriteAfterMutationCount = 2

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        }) { error in
            XCTAssertEqual(String(describing: error), "restorationFailed")
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
        var currentOwner = owner
        var observedOwners: [UUID?] = []
        let store = makeStore(io: io, ownerProvider: {
            observedOwners.append(currentOwner)
            return currentOwner
        })
        try store.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        let initializationWriteCount = io.writeCount
        observedOwners.removeAll()
        var writeMutationObserved = false
        io.onWrite = {
            if io.data != priorBytes {
                writeMutationObserved = true
            }
            currentOwner = self.otherOwner
        }

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        }) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(observedOwners, [owner, owner, otherOwner])
        XCTAssertTrue(writeMutationObserved)
        XCTAssertEqual(io.data, priorBytes)
        XCTAssertGreaterThan(io.writeCount, initializationWriteCount)
    }

    func testOwnerChangeAfterReadbackRestoresPriorBytes() throws {
        let io = TestFileIO()
        let stableStore = makeStore(io: io)
        try stableStore.transaction(expectedOwner: owner) { $0 = makeState() }
        let priorBytes = io.data
        var currentOwner = owner
        let store = makeStore(io: io, ownerProvider: { currentOwner })
        io.onReadback = {
            currentOwner = self.otherOwner
        }

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.ratchets[owner]?.advertisedVersion = 2
        }) { error in
            XCTAssertEqual(error as? DeviceEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(io.data, priorBytes)
    }

    func testProcessRoleUsesThePlannedRawValue() {
        XCTAssertEqual(MeteringProcessRole.deviceActivityMonitor.rawValue, "deviceActivityMonitor")
    }

    func testMeasurementSelectionDigestMustMatchExactPersistedBytes() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let generationID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let selectionBytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: "digest-is-not-the-sha256",
            enforcementSetID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            measurementSelectionBytes: selectionBytes,
            createdAt: Date(timeIntervalSince1970: 100),
            retiredAt: nil
        )
        var invalid = DeviceEpochStoreState(ownerChildDeviceID: owner, generations: [generationID: generation], activeGenerationID: generationID)

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = invalid })
        XCTAssertEqual(MeteringEpochContract.selectionDigest(persistedBytes: selectionBytes), "c5dbae22661af6db18a1f676db82a7ef7de46d27c3a263a872f00478b0d99fc4")
    }

    func testRouteGenerationKeyMustMatchReferencedGeneration() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var invalid = makeState()
        let routeID = invalid.activeRouteID!
        let route = invalid.routes[routeID]!
        let mismatchedKey = MeteringGenerationKey(
            protocolVersion: route.generationKey.protocolVersion,
            childDeviceID: route.generationKey.childDeviceID,
            canonicalTimezone: route.generationKey.canonicalTimezone,
            policyRevision: route.generationKey.policyRevision,
            measurementSelectionDigest: "another-digest",
            enforcementSetID: route.generationKey.enforcementSetID
        )
        invalid.routes[routeID] = MeteringCallbackRoute(
            routeID: route.routeID,
            activityName: route.activityName,
            namespace: route.namespace,
            generationID: route.generationID,
            generationKey: mismatchedKey,
            ownerChildDeviceID: route.ownerChildDeviceID,
            usageDate: route.usageDate,
            epochID: route.epochID,
            plannedSchedule: route.plannedSchedule,
            installedSchedule: route.installedSchedule,
            plannedEvents: route.plannedEvents,
            installedEvents: route.installedEvents,
            lifecycle: route.lifecycle,
            createdAt: route.createdAt
        )

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = invalid })
    }

    func testRouteEpochMustReferenceExistingEpochWhenNoHandoffNamesIt() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var invalid = makeState()
        invalid.v2RouteHandoff = nil
        invalid.epochs.removeAll()
        invalid.activeEpochID = nil
        invalid.tombstones.removeAll()
        invalid.registrationWork.removeAll()
        invalid.activationWork.removeAll()
        invalid.sampleWork.removeAll()
        invalid.installWork.removeAll()
        invalid.shieldReferences.removeAll()
        invalid.identityCleanupWork = nil
        invalid.rolloverEffectsWork = nil
        invalid.ratchets.removeAll()

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = invalid })
    }

    func testReadRejectsInvalidPersistedRoot() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var invalid = makeState()
        let routeID = invalid.activeRouteID!
        let route = invalid.routes[routeID]!
        invalid.routes[routeID] = MeteringCallbackRoute(
            routeID: route.routeID,
            activityName: route.activityName,
            namespace: route.namespace,
            generationID: UUID(),
            generationKey: route.generationKey,
            ownerChildDeviceID: route.ownerChildDeviceID,
            usageDate: route.usageDate,
            epochID: route.epochID,
            plannedSchedule: route.plannedSchedule,
            installedSchedule: route.installedSchedule,
            plannedEvents: route.plannedEvents,
            installedEvents: route.installedEvents,
            lifecycle: route.lifecycle,
            createdAt: route.createdAt
        )
        io.data = try encode(invalid)

        XCTAssertThrowsError(try store.read())
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

    func testCommittedHandoffPersistsPendingStopBeforeAcknowledgedStop() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let state = makeState()
        try store.transaction(expectedOwner: owner) { $0 = state }

        let cutoverReady = makeCutoverReadyState(from: state)
        try store.transaction(expectedOwner: owner) { $0 = cutoverReady }

        let committed = makeCommittedPendingStopState(from: cutoverReady)
        var notActivated = committed
        let candidateInstallID = committed.installWork.first { $0.value.routeID == committed.v2RouteHandoff!.toRouteID }!.key
        notActivated.installWork[candidateInstallID]?.phase = .verified
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = notActivated })

        var missingClosure = committed
        missingClosure.v2RouteHandoff?.priorRouteInputClosedAt = nil
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = missingClosure })

        var pendingPriorWork = committed
        pendingPriorWork.sampleWork = pendingPriorWork.sampleWork.mapValues { work in
            var copy = work
            copy.retry.terminal = .pending
            return copy
        }
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = pendingPriorWork })

        try store.transaction(expectedOwner: owner) { $0 = committed }
        let persistedPendingStop = try store.read()
        let priorInstallID = try XCTUnwrap(persistedPendingStop.installWork.first {
            $0.value.routeID == persistedPendingStop.v2RouteHandoff?.fromRouteID
        }?.key)
        XCTAssertEqual(persistedPendingStop.installWork[priorInstallID]?.phase, .pendingStop)
        XCTAssertNil(persistedPendingStop.tombstones[persistedPendingStop.v2RouteHandoff!.fromRouteID]?.stopAcknowledgedAt)
        XCTAssertNil(persistedPendingStop.v2RouteHandoff?.priorStopAcknowledgedAt)

        let stopped = makeStoppedCommittedState(from: persistedPendingStop)
        try store.transaction(expectedOwner: owner) { $0 = stopped }
        let reopenedStore = makeStore(io: io)
        XCTAssertEqual(try reopenedStore.read(), stopped)
    }

    func testCutoverReadyCannotJumpDirectlyToStoppedOrUseAmbiguousInstalls() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let state = makeState()
        try store.transaction(expectedOwner: owner) { $0 = state }
        let cutoverReady = makeCutoverReadyState(from: state)
        try store.transaction(expectedOwner: owner) { $0 = cutoverReady }

        let directStopped = makeStoppedCommittedState(
            from: makeCommittedPendingStopState(from: cutoverReady)
        )
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = directStopped })

        var differentHandoff = directStopped
        let originalHandoff = try XCTUnwrap(differentHandoff.v2RouteHandoff)
        differentHandoff.v2RouteHandoff = V2RouteHandoff(
            handoffID: UUID(uuidString: "15151515-1515-1515-1515-151515151515")!,
            ownerChildDeviceID: originalHandoff.ownerChildDeviceID,
            fromGenerationID: originalHandoff.fromGenerationID,
            fromEpochID: originalHandoff.fromEpochID,
            fromRouteID: originalHandoff.fromRouteID,
            toGenerationID: originalHandoff.toGenerationID,
            toEpochID: originalHandoff.toEpochID,
            toRouteID: originalHandoff.toRouteID,
            phase: originalHandoff.phase,
            priorRouteInputClosedAt: originalHandoff.priorRouteInputClosedAt,
            registrationAcknowledgedAt: originalHandoff.registrationAcknowledgedAt,
            activationAcknowledgedAt: originalHandoff.activationAcknowledgedAt,
            priorStopAcknowledgedAt: originalHandoff.priorStopAcknowledgedAt,
            createdAt: originalHandoff.createdAt
        )
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = differentHandoff })

        let noHandoffStore = makeStore(io: TestFileIO())
        var noHandoff = state
        noHandoff.v2RouteHandoff = nil
        try noHandoffStore.transaction(expectedOwner: owner) { $0 = noHandoff }
        let directCommitted = makeCommittedPendingStopState(from: cutoverReady)
        XCTAssertThrowsError(try noHandoffStore.transaction(expectedOwner: owner) { $0 = directCommitted })

        var ambiguous = makeCommittedPendingStopState(from: cutoverReady)
        let priorRouteID = ambiguous.v2RouteHandoff!.fromRouteID
        let duplicateID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        ambiguous.installWork[duplicateID] = ActivityInstallWork(
            workID: duplicateID,
            ownerChildDeviceID: owner,
            routeID: priorRouteID,
            authorization: .registered,
            phase: .pendingStop,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: Date(timeIntervalSince1970: 300),
                lastErrorCode: nil,
                terminal: .succeeded
            ),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = ambiguous })

        var ambiguousCandidate = makeCommittedPendingStopState(from: cutoverReady)
        let candidateRouteID = ambiguousCandidate.v2RouteHandoff!.toRouteID
        let duplicateCandidateID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        ambiguousCandidate.installWork[duplicateCandidateID] = ActivityInstallWork(
            workID: duplicateCandidateID,
            ownerChildDeviceID: owner,
            routeID: candidateRouteID,
            authorization: .registered,
            phase: .active,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: Date(timeIntervalSince1970: 300),
                lastErrorCode: nil,
                terminal: .succeeded
            ),
            createdAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = ambiguousCandidate })
    }

    func testPersistedHandoffFreezesEntireTupleAndCannotBeRemovedBeforeStopAcknowledgement() throws {
        let mutations: [(String, (inout DeviceEpochStoreState) -> Void)] = [
            ("handoffID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    handoffID: UUID(uuidString: "16161616-1616-1616-1616-161616161616")!
                )
            }),
            ("ownerChildDeviceID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    ownerChildDeviceID: self.otherOwner
                )
            }),
            ("fromGenerationID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    fromGenerationID: UUID(uuidString: "17171717-1717-1717-1717-171717171717")!
                )
            }),
            ("fromEpochID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    fromEpochID: UUID(uuidString: "18181818-1818-1818-1818-181818181818")!
                )
            }),
            ("fromRouteID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    fromRouteID: UUID(uuidString: "19191919-1919-1919-1919-191919191919")!
                )
            }),
            ("toGenerationID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    toGenerationID: UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
                )
            }),
            ("toEpochID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    toEpochID: UUID(uuidString: "21212121-2121-2121-2121-212121212121")!
                )
            }),
            ("toRouteID", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    toRouteID: UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
                )
            }),
            ("coherent from/to lane swap", { state in
                let handoff = state.v2RouteHandoff!
                state.v2RouteHandoff = V2RouteHandoff(
                    handoffID: handoff.handoffID,
                    ownerChildDeviceID: handoff.ownerChildDeviceID,
                    fromGenerationID: handoff.toGenerationID,
                    fromEpochID: handoff.toEpochID,
                    fromRouteID: handoff.toRouteID,
                    toGenerationID: handoff.fromGenerationID,
                    toEpochID: handoff.fromEpochID,
                    toRouteID: handoff.fromRouteID,
                    phase: handoff.phase,
                    priorRouteInputClosedAt: handoff.priorRouteInputClosedAt,
                    registrationAcknowledgedAt: handoff.registrationAcknowledgedAt,
                    activationAcknowledgedAt: handoff.activationAcknowledgedAt,
                    priorStopAcknowledgedAt: handoff.priorStopAcknowledgedAt,
                    createdAt: handoff.createdAt
                )
                state.activeGenerationID = handoff.toGenerationID
                state.activeEpochID = handoff.toEpochID
                state.activeRouteID = handoff.toRouteID
            }),
            ("createdAt", { state in
                state.v2RouteHandoff = self.replacingImmutableHandoff(
                    state.v2RouteHandoff!,
                    createdAt: Date(timeIntervalSince1970: 999)
                )
            }),
            ("early removal", { state in
                state.v2RouteHandoff = nil
            })
        ]

        for (name, mutate) in mutations {
            let store = makeStore(io: TestFileIO())
            let persisted = makeState()
            try store.transaction(expectedOwner: owner) { $0 = persisted }

            var candidate = persisted
            mutate(&candidate)

            XCTAssertThrowsError(
                try store.transaction(expectedOwner: owner) { $0 = candidate },
                "immutable handoff mutation must fail closed: \(name)"
            )
        }
    }

    func testStoppedAcknowledgedHandoffMayBeCollected() throws {
        let store = makeStore(io: TestFileIO())
        let initial = makeState()
        try store.transaction(expectedOwner: owner) { $0 = initial }
        let cutoverReady = makeCutoverReadyState(from: initial)
        try store.transaction(expectedOwner: owner) { $0 = cutoverReady }
        let committed = makeCommittedPendingStopState(from: cutoverReady)
        try store.transaction(expectedOwner: owner) { $0 = committed }
        let stopped = makeStoppedCommittedState(from: committed)
        try store.transaction(expectedOwner: owner) { $0 = stopped }

        var collected = stopped
        collected.v2RouteHandoff = nil
        try store.transaction(expectedOwner: owner) { $0 = collected }

        XCTAssertNil(try store.read().v2RouteHandoff)
    }

    func testStoppedCommittedHandoffCannotReverseToPendingStop() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        let state = makeState()
        try store.transaction(expectedOwner: owner) { $0 = state }
        let cutoverReady = makeCutoverReadyState(from: state)
        try store.transaction(expectedOwner: owner) { $0 = cutoverReady }
        let committed = makeCommittedPendingStopState(from: cutoverReady)
        try store.transaction(expectedOwner: owner) { $0 = committed }
        let stopped = makeStoppedCommittedState(from: committed)
        try store.transaction(expectedOwner: owner) { $0 = stopped }

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = committed })
    }

    func testReadReopensCutoverReadyRootWithSucceededPreBarrierPriorSampleWork() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var state = makeState()
        try store.transaction(expectedOwner: owner) { $0 = state }

        state.v2RouteHandoff?.phase = .cutoverReady
        state.v2RouteHandoff?.priorRouteInputClosedAt = Date(timeIntervalSince1970: 150)
        state.sampleWork = state.sampleWork.mapValues { work in
            var copy = work
            copy.retry.terminal = .succeeded
            return copy
        }
        try store.transaction(expectedOwner: owner) { $0 = state }

        let reopenedStore = makeStore(io: io)
        XCTAssertEqual(try reopenedStore.read(), state)
    }

    func testCutoverBarrierRejectsPriorWorkCreatedBeforeOrAfterBarrier() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var state = makeState()
        try store.transaction(expectedOwner: owner) { $0 = state }
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

    func testCutoverBarrierRejectsBackdatedPriorSampleAddedInTheBarrierTransaction() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var invalid = makeState()
        invalid.sampleWork.removeAll()
        invalid.v2RouteHandoff?.phase = .cutoverReady
        invalid.v2RouteHandoff?.priorRouteInputClosedAt = Date(timeIntervalSince1970: 150)
        let sampleID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        invalid.sampleWork[sampleID] = makeSampleWork(
            workID: sampleID,
            routeID: invalid.v2RouteHandoff!.fromRouteID,
            epochID: invalid.v2RouteHandoff!.fromEpochID,
            createdAt: Date(timeIntervalSince1970: 101),
            terminal: .succeeded,
            activityName: invalid.routes[invalid.v2RouteHandoff!.fromRouteID]!.activityName
        )

        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { $0 = invalid })
    }

    func testClosedBarrierRejectsBackdatedPriorSampleAddedInLaterTransaction() throws {
        let io = TestFileIO()
        let store = makeStore(io: io)
        var closed = makeState()
        closed.sampleWork.removeAll()
        closed.v2RouteHandoff?.phase = .cutoverReady
        closed.v2RouteHandoff?.priorRouteInputClosedAt = Date(timeIntervalSince1970: 150)
        try store.transaction(expectedOwner: owner) { $0 = closed }

        let sampleID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        XCTAssertThrowsError(try store.transaction(expectedOwner: owner) { state in
            state.sampleWork[sampleID] = self.makeSampleWork(
                workID: sampleID,
                routeID: state.v2RouteHandoff!.fromRouteID,
                epochID: state.v2RouteHandoff!.fromEpochID,
                createdAt: Date(timeIntervalSince1970: 101),
                terminal: .succeeded,
                activityName: state.routes[state.v2RouteHandoff!.fromRouteID]!.activityName
            )
        })
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

    private func encode(_ state: DeviceEpochStoreState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private func makeSampleWork(
        workID: UUID,
        routeID: UUID,
        epochID: UUID,
        createdAt: Date,
        terminal: MeteringWorkTerminal,
        activityName: String = "evlin.earned.budget.prior"
    ) -> EpochSampleWork {
        EpochSampleWork(
            workID: workID,
            ownerChildDeviceID: owner,
            epochID: epochID,
            routeID: routeID,
            request: EpochSampleRequestDTO(
                deviceID: owner,
                usageDate: "2026-07-17",
                timezone: "America/New_York",
                activityName: activityName,
                eventName: "t5",
                thresholdMinutes: 5,
                estimatedMinutes: 5,
                observedAt: createdAt,
                clientSampleID: "earned:v2:prior:t5",
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
                terminal: terminal
            ),
            createdAt: createdAt
        )
    }

    private func makeCutoverReadyState(from state: DeviceEpochStoreState) -> DeviceEpochStoreState {
        var result = state
        result.v2RouteHandoff?.phase = .cutoverReady
        result.v2RouteHandoff?.priorRouteInputClosedAt = Date(timeIntervalSince1970: 150)
        result.sampleWork = result.sampleWork.mapValues { work in
            var copy = work
            copy.retry.terminal = .succeeded
            return copy
        }
        return result
    }

    private func makeCommittedPendingStopState(from state: DeviceEpochStoreState) -> DeviceEpochStoreState {
        var result = state
        let handoff = result.v2RouteHandoff!
        result.v2RouteHandoff?.phase = .committed
        result.v2RouteHandoff?.registrationAcknowledgedAt = Date(timeIntervalSince1970: 250)
        result.v2RouteHandoff?.activationAcknowledgedAt = Date(timeIntervalSince1970: 300)
        result.v2RouteHandoff?.priorStopAcknowledgedAt = nil
        result.activeRouteID = handoff.toRouteID
        result.activeEpochID = handoff.toEpochID
        result.activeGenerationID = handoff.toGenerationID
        result.epochs[handoff.fromEpochID]?.status = .retired
        result.epochs[handoff.fromEpochID]?.retiredAt = Date(timeIntervalSince1970: 300)
        result.epochs[handoff.fromEpochID]?.retireReason = .activationSuperseded
        result.epochs[handoff.toEpochID]?.registeredAt = Date(timeIntervalSince1970: 250)
        result.routes[handoff.fromRouteID]?.lifecycle = .tombstoned
        result.tombstones[handoff.fromRouteID] = MeteringRouteTombstone(
            routeID: handoff.fromRouteID,
            activityName: state.routes[handoff.fromRouteID]!.activityName,
            eventNames: state.routes[handoff.fromRouteID]!.plannedEvents.map(\.eventName),
            ownerChildDeviceID: owner,
            usageDate: state.routes[handoff.fromRouteID]!.usageDate,
            epochID: handoff.fromEpochID,
            generationID: handoff.fromGenerationID,
            canonicalDayEnd: Date(timeIntervalSince1970: 86_500),
            stopAcknowledgedAt: nil,
            referencedWorkIDs: [],
            retainedUntil: nil
        )
        result.registrationWork = result.registrationWork.mapValues { work in
            var copy = work
            copy.retry.terminal = .succeeded
            return copy
        }
        result.activationWork = result.activationWork.mapValues { work in
            var copy = work
            copy.retry.terminal = .succeeded
            return copy
        }
        let candidateInstallID = result.installWork.first { $0.value.routeID == handoff.toRouteID }!.key
        result.installWork[candidateInstallID]?.phase = .active
        let priorInstallID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        result.installWork[priorInstallID] = ActivityInstallWork(
            workID: priorInstallID,
            ownerChildDeviceID: owner,
            routeID: handoff.fromRouteID,
            authorization: .registered,
            phase: .pendingStop,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: Date(timeIntervalSince1970: 300),
                lastErrorCode: nil,
                terminal: .succeeded
            ),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        result.ratchets[owner] = MeteringOwnerRatchet(
            ownerChildDeviceID: owner,
            advertisedVersion: 2,
            localSelection: .v2,
            registeredV2At: Date(timeIntervalSince1970: 250),
            dualActiveAt: Date(timeIntervalSince1970: 200),
            activatedV2At: Date(timeIntervalSince1970: 300)
        )
        return result
    }

    private func makeStoppedCommittedState(from state: DeviceEpochStoreState) -> DeviceEpochStoreState {
        var result = state
        let handoff = result.v2RouteHandoff!
        let priorInstallID = result.installWork.first { $0.value.routeID == handoff.fromRouteID }!.key
        result.installWork[priorInstallID]?.phase = .stopped
        result.tombstones[handoff.fromRouteID]?.stopAcknowledgedAt = Date(timeIntervalSince1970: 301)
        result.v2RouteHandoff?.priorStopAcknowledgedAt = Date(timeIntervalSince1970: 301)
        return result
    }

    private func replacingImmutableHandoff(
        _ handoff: V2RouteHandoff,
        handoffID: UUID? = nil,
        ownerChildDeviceID: UUID? = nil,
        fromGenerationID: UUID? = nil,
        fromEpochID: UUID? = nil,
        fromRouteID: UUID? = nil,
        toGenerationID: UUID? = nil,
        toEpochID: UUID? = nil,
        toRouteID: UUID? = nil,
        createdAt: Date? = nil
    ) -> V2RouteHandoff {
        V2RouteHandoff(
            handoffID: handoffID ?? handoff.handoffID,
            ownerChildDeviceID: ownerChildDeviceID ?? handoff.ownerChildDeviceID,
            fromGenerationID: fromGenerationID ?? handoff.fromGenerationID,
            fromEpochID: fromEpochID ?? handoff.fromEpochID,
            fromRouteID: fromRouteID ?? handoff.fromRouteID,
            toGenerationID: toGenerationID ?? handoff.toGenerationID,
            toEpochID: toEpochID ?? handoff.toEpochID,
            toRouteID: toRouteID ?? handoff.toRouteID,
            phase: handoff.phase,
            priorRouteInputClosedAt: handoff.priorRouteInputClosedAt,
            registrationAcknowledgedAt: handoff.registrationAcknowledgedAt,
            activationAcknowledgedAt: handoff.activationAcknowledgedAt,
            priorStopAcknowledgedAt: handoff.priorStopAcknowledgedAt,
            createdAt: createdAt ?? handoff.createdAt
        )
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
        let selectionDigest = MeteringEpochContract.selectionDigest(persistedBytes: selectionBytes)
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: selectionDigest,
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
            measurementSelectionDigest: selectionDigest,
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
            measurementSelectionDigest: selectionDigest,
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
            measurementSelectionDigest: selectionDigest,
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
            tombstones: [:],
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
    var failWriteAfterMutationCount = 0
    var failNextReadback = false
    var readbackFailureCount = 0
    var onWrite: (() -> Void)?
    var onReadback: (() -> Void)?
    var writeCount = 0

    func read(from url: URL) throws -> Data? {
        if failRead { throw TestError.mutation }
        if readbackPending {
            readbackPending = false
            if failNextReadback {
                failNextReadback = false
                readbackFailureCount += 1
                throw TestError.mutation
            }
            onReadback?()
            onReadback = nil
            let result = readbackData ?? data
            readbackData = nil
            return result
        }
        return data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        writeCount += 1
        self.data = data
        readbackPending = true
        onWrite?()
        if failWriteAfterMutationCount > 0 {
            failWriteAfterMutationCount -= 1
            throw TestError.mutation
        }
    }

    func remove(at url: URL) throws {
        data = nil
        readbackPending = false
    }
}
