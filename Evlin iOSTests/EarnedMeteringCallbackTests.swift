import Foundation
import XCTest
@testable import Evlin_iOS

final class EarnedMeteringCallbackTests: XCTestCase {
    func testMalformedCallbackIsDiscardedWithoutBootstrappingAnOwner() throws {
        let owner = UUID()
        let fixture = CallbackFixture(owner: owner)
        defer { fixture.cleanup() }

        let outcome = try EarnedMeteringCallback(
            store: fixture.store,
            clock: CallbackClock(now: fixture.start)
        ).handle(
            MeteringAppleCallback(
                activityName: "not-evlin",
                eventName: "not-evlin.t5",
                observedAt: fixture.start
            ),
            expectedOwnerChildDeviceID: owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "malformed_route"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }

    func testExactActiveRouteQueuesOneV2SampleWithCumulativeEstimate() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }

        let outcome = try EarnedMeteringCallback(
            store: fixture.store,
            clock: CallbackClock(now: fixture.start.addingTimeInterval(5 * 60))
        ).handle(fixture.callback(threshold: 5), expectedOwnerChildDeviceID: fixture.owner)

        guard case let .queued(sampleWorkID) = outcome else {
            return XCTFail("expected queued sample, got \(outcome)")
        }
        let state = try fixture.store.read()
        let work = state.sampleWork[sampleWorkID]
        XCTAssertEqual(work?.authorization, .v2Deliverable)
        XCTAssertEqual(work?.request.estimatedMinutes, 17)
        XCTAssertEqual(work?.request.lane, .v2)
    }

    func testTerminalCallbackCommitsPreparedShieldReferenceWithSampleButEarlyCallbackCommitsNeither() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let reference = EarnedShieldReference(
            operationID: fixture.routeID,
            ownerChildDeviceID: fixture.owner,
            generationID: fixture.generationID,
            epochID: fixture.epochID,
            routeID: fixture.routeID,
            recordKey: "savedList:terminal",
            expectedRecordBytes: Data([0x01]),
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: fixture.start,
                lastErrorCode: nil,
                terminal: .pending
            ),
            createdAt: fixture.start
        )

        let accepted = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner,
            preparedShieldReference: reference
        )

        guard case .queued = accepted else { return XCTFail("terminal callback must queue") }
        let acceptedState = try fixture.store.read()
        XCTAssertEqual(acceptedState.sampleWork.count, 1)
        XCTAssertEqual(acceptedState.shieldReferences[fixture.routeID], reference)

        let early = try CallbackFixture.active()
        defer { early.cleanup() }
        let earlyReference = EarnedShieldReference(
            operationID: early.routeID,
            ownerChildDeviceID: early.owner,
            generationID: early.generationID,
            epochID: early.epochID,
            routeID: early.routeID,
            recordKey: reference.recordKey,
            expectedRecordBytes: reference.expectedRecordBytes,
            retry: reference.retry,
            createdAt: reference.createdAt
        )
        let rejected = try early.callbackHandler().handle(
            early.callback(threshold: 5, observedAt: early.start.addingTimeInterval(269)),
            expectedOwnerChildDeviceID: early.owner,
            preparedShieldReference: earlyReference
        )

        XCTAssertEqual(rejected, .discarded(reason: "too_early"))
        XCTAssertTrue(try early.store.read().sampleWork.isEmpty)
        XCTAssertTrue(try early.store.read().shieldReferences.isEmpty)
    }

    func testThirtyOneSecondsEarlyIsByteIdenticalAndQueuesNothing() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.storeURL)
        let callback = fixture.callback(threshold: 5, observedAt: fixture.start.addingTimeInterval(269))

        let outcome = try fixture.callbackHandler().handle(callback, expectedOwnerChildDeviceID: fixture.owner)

        XCTAssertEqual(outcome, .discarded(reason: "too_early"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
    }

    func testInvalidJitterIsFailClosedWithoutAnyRootMutation() throws {
        let fixture = CallbackFixture(owner: UUID())
        defer { fixture.cleanup() }

        let outcome = try EarnedMeteringCallback(
            store: fixture.store,
            clock: CallbackClock(now: fixture.start),
            jitterSeconds: 61
        ).handle(fixture.callback(threshold: 5), expectedOwnerChildDeviceID: fixture.owner)

        XCTAssertEqual(outcome, .discarded(reason: "invalid_jitter"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }

    func testMalformedMismatchedAndUnknownNamesAreByteIdenticalWithoutEffects() throws {
        let owner = UUID()
        let fixture = CallbackFixture(owner: owner)
        defer { fixture.cleanup() }
        let unknownRouteID = UUID()
        let cases = [
            MeteringAppleCallback(activityName: "bad", eventName: "bad.t5", observedAt: fixture.start),
            MeteringAppleCallback(
                activityName: MeteringRouteNamespace.activityName(routeID: unknownRouteID),
                eventName: MeteringRouteNamespace.eventName(routeID: UUID(), thresholdMinutes: 5),
                observedAt: fixture.start
            ),
            MeteringAppleCallback(
                activityName: MeteringRouteNamespace.activityName(routeID: unknownRouteID),
                eventName: MeteringRouteNamespace.eventName(routeID: unknownRouteID, thresholdMinutes: 5),
                observedAt: fixture.start
            )
        ]

        for callback in cases {
            let outcome = try fixture.callbackHandler().handle(
                callback,
                expectedOwnerChildDeviceID: owner
            )
            guard case .discarded = outcome else { return XCTFail("invalid name must discard") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.path))
        }
    }

    func testResolvedRouteRejectsWrongActivityEventAndNamespaceWithoutEffects() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let input = fixture.authorizedInput()
        let cases: [(String, MeteringAuthorizedCallbackInput)] = [
            ("activity", fixture.authorizedInput(activityName: "evlin.earned.v2.bad")),
            ("event", fixture.authorizedInput(eventName: "evlin.earned.v2.bad.t5")),
            ("namespace", fixture.authorizedInput(namespace: "evlin.earned.v1."))
        ]

        for (label, malformed) in cases {
            let before = try Data(contentsOf: fixture.storeURL)
            let outcome = try fixture.store.enqueueAuthorizedV2Callback(malformed, owner: fixture.owner)
            XCTAssertEqual(outcome, .discarded(reason: "route_provenance_mismatch"), label)
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, label)
        }
        XCTAssertNotEqual(input, cases[0].1)
    }

    func testWrongOwnerCoverageExhaustionAndV1SelectionAreByteIdenticalDiscards() throws {
        let wrongOwnerFixture = try CallbackFixture.active()
        defer { wrongOwnerFixture.cleanup() }
        let wrongOwnerBefore = try Data(contentsOf: wrongOwnerFixture.storeURL)
        let wrongOwnerOutcome = try wrongOwnerFixture.callbackHandler().handle(
            wrongOwnerFixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: UUID()
        )
        XCTAssertEqual(wrongOwnerOutcome, .discarded(reason: "owner_mismatch"))
        XCTAssertEqual(try Data(contentsOf: wrongOwnerFixture.storeURL), wrongOwnerBefore)

        let coverageFixture = try CallbackFixture.active()
        defer { coverageFixture.cleanup() }
        try coverageFixture.mutate { state in
            state.coverage = MonitorCoverageState(
                ownerChildDeviceID: coverageFixture.owner,
                requiredFromUsageDate: "2026-07-18",
                requiredThroughUsageDate: "2026-07-25",
                readyThroughUsageDate: nil,
                status: .coverageExhausted,
                refreshedAt: coverageFixture.start,
                errorCode: "coverage_exhausted"
            )
        }
        let coverageBefore = try Data(contentsOf: coverageFixture.storeURL)
        let coverageOutcome = try coverageFixture.callbackHandler().handle(
            coverageFixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: coverageFixture.owner
        )
        XCTAssertEqual(coverageOutcome, .discarded(reason: "epoch_not_active"))
        XCTAssertEqual(try Data(contentsOf: coverageFixture.storeURL), coverageBefore)

        let v1Fixture = try CallbackFixture.active()
        defer { v1Fixture.cleanup() }
        try v1Fixture.mutate { state in
            state.ratchets[v1Fixture.owner]?.localSelection = .v1
        }
        let v1Before = try Data(contentsOf: v1Fixture.storeURL)
        let v1Outcome = try v1Fixture.callbackHandler().handle(
            v1Fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: v1Fixture.owner
        )
        XCTAssertEqual(v1Outcome, .discarded(reason: "epoch_not_active"))
        XCTAssertEqual(try Data(contentsOf: v1Fixture.storeURL), v1Before)
    }

    func testOnlyDualActiveAndActiveInstallPhasesAcceptCallbacks() throws {
        let rejected: [ActivityInstallPhase] = [
            .pendingStart, .starting, .installed, .verified, .pendingStop, .stopped
        ]
        for phase in rejected {
            let fixture = try CallbackFixture.active()
            defer { fixture.cleanup() }
            try fixture.mutate { state in state.installWork[fixture.installID]?.phase = phase }
            let before = try Data(contentsOf: fixture.storeURL)
            let outcome = try fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )
            guard case .discarded = outcome else { return XCTFail("\(phase) must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, "\(phase)")
        }
    }

    func testPlannedAndRetiredRoutesAreByteIdenticalDiscards() throws {
        for lifecycle in [MeteringRouteLifecycle.planned, .retired] {
            let fixture = try CallbackFixture.active()
            defer { fixture.cleanup() }
            try fixture.mutate { state in
                state.routes[fixture.routeID]?.lifecycle = lifecycle
                state.activeRouteID = nil
                state.activeEpochID = nil
                state.activeGenerationID = nil
            }
            let before = try Data(contentsOf: fixture.storeURL)

            let outcome = try fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )

            guard case .discarded = outcome else { return XCTFail("\(lifecycle) must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, "\(lifecycle)")
            XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
        }
    }

    func testPriorDayTombstoneIsResolvedAndHasZeroEffects() throws {
        let fixture = try CallbackFixture.active(usageDate: "2026-07-17")
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            guard let route = state.routes[fixture.routeID] else { return }
            state.routes[fixture.routeID]?.lifecycle = .tombstoned
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
            state.tombstones[fixture.routeID] = MeteringRouteTombstone(
                routeID: route.routeID,
                activityName: route.activityName,
                eventNames: route.plannedEvents.map(\.eventName),
                ownerChildDeviceID: route.ownerChildDeviceID,
                usageDate: route.usageDate,
                epochID: route.epochID,
                generationID: route.generationID,
                canonicalDayEnd: fixture.start.addingTimeInterval(86_400),
                stopAcknowledgedAt: fixture.start,
                referencedWorkIDs: [],
                retainedUntil: fixture.start.addingTimeInterval(7 * 86_400)
            )
        }
        let before = try Data(contentsOf: fixture.storeURL)

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5, observedAt: fixture.start.addingTimeInterval(86_400 + 300)),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "tombstoned_route"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
    }

    func testTerminalEpochsAndPreparingHandoffAreByteIdenticalDiscards() throws {
        for status in [DeviceDailyEpochStatus.exhausted, .retired] {
            let fixture = try CallbackFixture.active()
            defer { fixture.cleanup() }
            try fixture.mutate { state in
                state.epochs[fixture.epochID]?.status = status
                if status == .retired {
                    state.epochs[fixture.epochID]?.retiredAt = fixture.start
                    state.epochs[fixture.epochID]?.retireReason = .dayRollover
                } else {
                    state.epochs[fixture.epochID]?.exhaustedAt = fixture.start
                }
            }
            let before = try Data(contentsOf: fixture.storeURL)
            let outcome = try fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )
            guard case .discarded = outcome else { return XCTFail("\(status) must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, "\(status)")
        }

        let handoffFixture = try CallbackFixture.dualV2(phase: .preparing)
        defer { handoffFixture.cleanup() }
        let before = try Data(contentsOf: handoffFixture.storeURL)
        let outcome = try handoffFixture.callbackHandler().handle(
            handoffFixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: handoffFixture.owner
        )
        XCTAssertEqual(outcome, .discarded(reason: "unregistered_route_not_candidate"))
        XCTAssertEqual(try Data(contentsOf: handoffFixture.storeURL), before)
    }

    func testReopenedPausedOldRouteIsByteIdenticalAndQueuesNothing() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.epochs[fixture.epochID]?.status = .paused
        }
        _ = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        try fixture.mutate { state in
            state.routes[fixture.routeID]?.lifecycle = .retired
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
        }
        let before = try Data(contentsOf: fixture.storeURL)

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "route_provenance_mismatch"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
    }

    func testOfflineRegisteredRouteQueuesExactlyOnceWithoutTransport() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }

        let first = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        let second = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case let .queued(firstID) = first, case let .queued(secondID) = second else {
            return XCTFail("registered offline callbacks must queue")
        }
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
    }

    func testOneDayDelayedActiveCallbackSurvivesMutableUsageState() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 4
            state.epochs[fixture.epochID]?.excludedWhilePausedMinutes = 1
        }

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5, observedAt: fixture.start.addingTimeInterval(86_400 + 300)),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .queued = outcome else { return XCTFail("delayed callbacks have no maximum age") }
        XCTAssertEqual(try fixture.store.read().epochs[fixture.epochID]?.lastRawThresholdMinutes, 5)
    }

    func testPolicyReplacementMakesDelayedPriorRouteCallbackByteIdentical() throws {
        let fixture = try CallbackFixture.dualV2(phase: .cutoverReady)
        defer { fixture.cleanup() }
        let activationWorkID = UUID()
        try fixture.mutate { state in
            state.activeGenerationID = fixture.candidateGenerationID
            state.activeEpochID = fixture.candidateEpochID
            state.activeRouteID = fixture.candidateRouteID
            state.routes[fixture.candidateRouteID]?.lifecycle = .active
            state.epochs[fixture.candidateEpochID]?.registeredAt = fixture.start
            state.installWork[fixture.candidateInstallID]?.authorization = .registered
            state.installWork[fixture.candidateInstallID]?.phase = .active
            if let priorInstallID = state.installWork.first(where: { $0.value.routeID == fixture.routeID })?.key {
                state.installWork[priorInstallID]?.phase = .pendingStop
            }
            state.routes[fixture.routeID]?.lifecycle = .tombstoned
            state.epochs[fixture.epochID]?.status = .retired
            state.epochs[fixture.epochID]?.retiredAt = fixture.start
            state.epochs[fixture.epochID]?.retireReason = .policyChange
            state.generations[fixture.generationID]?.retiredAt = fixture.start
            state.tombstones[fixture.routeID] = MeteringRouteTombstone(
                routeID: fixture.routeID,
                activityName: MeteringRouteNamespace.activityName(routeID: fixture.routeID),
                eventNames: [MeteringRouteNamespace.eventName(routeID: fixture.routeID, thresholdMinutes: 5)],
                ownerChildDeviceID: fixture.owner,
                usageDate: "2026-07-18",
                epochID: fixture.epochID,
                generationID: fixture.generationID,
                canonicalDayEnd: fixture.start.addingTimeInterval(86_400),
                stopAcknowledgedAt: nil,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            state.activationWork[activationWorkID] = EpochActivationWork(
                workID: activationWorkID,
                ownerChildDeviceID: fixture.owner,
                epochID: fixture.candidateEpochID,
                routeID: fixture.candidateRouteID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: fixture.owner,
                    routeID: fixture.candidateRouteID,
                    verifiedAt: fixture.start
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 1,
                    nextAttemptAt: fixture.start,
                    lastErrorCode: nil,
                    terminal: .succeeded
                ),
                createdAt: fixture.start
            )
            state.v2RouteHandoff?.phase = .committed
            state.v2RouteHandoff?.priorRouteInputClosedAt = fixture.start
            state.v2RouteHandoff?.registrationAcknowledgedAt = fixture.start
            state.v2RouteHandoff?.activationAcknowledgedAt = fixture.start
        }
        let replaced = try fixture.store.read()
        XCTAssertNotEqual(
            replaced.generations[fixture.generationID]?.policyRevision,
            replaced.generations[fixture.candidateGenerationID]?.policyRevision
        )
        let before = try Data(contentsOf: fixture.storeURL)

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5, observedAt: fixture.start.addingTimeInterval(86_400 + 300)),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "tombstoned_route"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
    }

    func testPausedCallbackOnlyAdvancesRegisteredPausedMetadata() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.epochs[fixture.epochID]?.status = .paused
        }

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "paused"))
        let state = try fixture.store.read()
        XCTAssertEqual(state.epochs[fixture.epochID]?.lastRawThresholdMinutes, 5)
        XCTAssertEqual(state.epochs[fixture.epochID]?.excludedWhilePausedMinutes, 5)
        XCTAssertTrue(state.sampleWork.isEmpty)
    }

    func testPausedCallbackRejectsInvalidRatchetRegistrationAndCoverageByteIdentically() throws {
        enum InvalidPausedState: String, CaseIterable {
            case v1Ratchet, unregistered, coverageExhausted
        }

        for invalidState in InvalidPausedState.allCases {
            let fixture = try CallbackFixture.active()
            defer { fixture.cleanup() }
            try fixture.mutate { state in
                state.epochs[fixture.epochID]?.status = .paused
                switch invalidState {
                case .v1Ratchet:
                    state.ratchets[fixture.owner]?.localSelection = .v1
                case .unregistered:
                    state.epochs[fixture.epochID]?.registeredAt = nil
                case .coverageExhausted:
                    state.coverage = fixture.exhaustedCoverage()
                }
            }
            let before = try Data(contentsOf: fixture.storeURL)

            let outcome = try fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )

            guard case .discarded = outcome else { return XCTFail("\(invalidState) must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, invalidState.rawValue)
            XCTAssertEqual(try fixture.store.read().epochs[fixture.epochID]?.lastRawThresholdMinutes, 0)
        }
    }

    func testPausedCallbackRejectsPreparingClosedAndUnregisteredCandidateRoutesByteIdentically() throws {
        let cases: [(String, V2RouteHandoffPhase, Bool)] = [
            ("preparing-prior", .preparing, false),
            ("dual-v2-prior", .dualV2, false),
            ("closed-prior", .cutoverReady, false),
            ("unregistered-candidate", .dualV2, true)
        ]
        for (label, phase, useCandidate) in cases {
            let fixture = try CallbackFixture.dualV2(phase: phase)
            defer { fixture.cleanup() }
            let targetEpochID = useCandidate ? fixture.candidateEpochID : fixture.epochID
            try fixture.mutate { state in state.epochs[targetEpochID]?.status = .paused }
            let before = try Data(contentsOf: fixture.storeURL)
            let callback = useCandidate ? fixture.candidateCallback(threshold: 5) : fixture.callback(threshold: 5)

            let outcome = try fixture.callbackHandler().handle(
                callback,
                expectedOwnerChildDeviceID: fixture.owner
            )

            guard case .discarded = outcome else { return XCTFail("\(label) must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, label)
            XCTAssertEqual(try fixture.store.read().epochs[targetEpochID]?.lastRawThresholdMinutes, 0)
        }
    }

    func testResumeBoundaryRejectsUnregisteredPreparingAndClosedRoutesByteIdentically() throws {
        let cases: [(String, V2RouteHandoffPhase, Bool)] = [
            ("preparing-prior", .preparing, false),
            ("closed-prior", .cutoverReady, false),
            ("unregistered-candidate", .dualV2, true)
        ]
        for (label, phase, useCandidate) in cases {
            let fixture = try CallbackFixture.dualV2(phase: phase)
            defer { fixture.cleanup() }
            let targetEpochID = useCandidate ? fixture.candidateEpochID : fixture.epochID
            try fixture.mutate { state in state.epochs[targetEpochID]?.resumeBoundaryPending = true }
            let before = try Data(contentsOf: fixture.storeURL)
            let callback = useCandidate ? fixture.candidateCallback(threshold: 5) : fixture.callback(threshold: 5)

            let outcome = try fixture.callbackHandler().handle(
                callback,
                expectedOwnerChildDeviceID: fixture.owner
            )

            guard case .discarded = outcome else { return XCTFail("\(label) must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, label)
            XCTAssertTrue(try fixture.store.read().epochs[targetEpochID]?.resumeBoundaryPending ?? false)
        }
    }

    func testPausedAndResumeCallbacksOutsideExactHandoffAreByteIdentical() throws {
        for status in [DeviceDailyEpochStatus.paused, .active] {
            let fixture = try CallbackFixture.dualV2()
            defer { fixture.cleanup() }
            let extra = try fixture.addRouteOutsideHandoff(
                status: status,
                resumeBoundaryPending: status == .active
            )
            let before = try Data(contentsOf: fixture.storeURL)

            let outcome = try fixture.callbackHandler().handle(
                extra.callback,
                expectedOwnerChildDeviceID: fixture.owner
            )

            guard case .discarded = outcome else { return XCTFail("wrong handoff route must reject") }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, status.rawValue)
            let epoch = try fixture.store.read().epochs[extra.epochID]
            XCTAssertEqual(epoch?.lastRawThresholdMinutes, 0)
            XCTAssertEqual(epoch?.resumeBoundaryPending, status == .active)
        }
    }

    func testResumeBoundaryConsumesFirstCallbackWithoutSampleWork() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.epochs[fixture.epochID]?.resumeBoundaryPending = true
        }

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "resume_boundary"))
        let state = try fixture.store.read()
        XCTAssertFalse(state.epochs[fixture.epochID]?.resumeBoundaryPending ?? true)
        XCTAssertEqual(state.epochs[fixture.epochID]?.lastRawThresholdMinutes, 5)
        XCTAssertEqual(state.epochs[fixture.epochID]?.excludedWhilePausedMinutes, 5)
        XCTAssertTrue(state.sampleWork.isEmpty)
    }

    func testInitialDualActiveQueuesBeforeBackendRatchetTwo() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.activeRouteID = nil
            state.ratchets[fixture.owner]?.localSelection = .dualActive
            state.ratchets[fixture.owner]?.advertisedVersion = 1
            state.installWork[fixture.installID]?.phase = .dualActive
        }

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .queued = outcome else { return XCTFail("expected initial v2 callback to queue") }
        XCTAssertEqual(try fixture.store.read().sampleWork.values.first?.authorization, .v2Deliverable)
    }

    func testRegisteredEpochRequiresSoleRegisteredInstallAuthorization() throws {
        let authorizations: [MeteringInstallAuthorization] = [
            .registrationRequired, .registered, .futurePlanned, .offlinePending
        ]
        for authorization in authorizations {
            let fixture = try CallbackFixture.active()
            defer { fixture.cleanup() }
            try fixture.mutate { state in state.installWork[fixture.installID]?.authorization = authorization }
            let before = try Data(contentsOf: fixture.storeURL)

            let outcome = try fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )

            if authorization == .registered {
                guard case .queued = outcome else { return XCTFail("registered install must queue") }
            } else {
                guard case .discarded = outcome else { return XCTFail("\(authorization) must reject") }
                XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, authorization.rawValue)
            }
        }
    }

    func testUnregisteredCandidateRequiresOfflinePendingInstallAuthorization() throws {
        let authorizations: [MeteringInstallAuthorization] = [
            .registrationRequired, .registered, .futurePlanned, .offlinePending
        ]
        for authorization in authorizations {
            let fixture = try CallbackFixture.dualV2()
            defer { fixture.cleanup() }
            try fixture.mutate { state in
                state.installWork[fixture.candidateInstallID]?.authorization = authorization
            }
            let before = try Data(contentsOf: fixture.storeURL)

            let outcome = try fixture.callbackHandler().handle(
                fixture.candidateCallback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )

            if authorization == .offlinePending {
                guard case let .queued(workID) = outcome else { return XCTFail("offline candidate must queue") }
                XCTAssertEqual(try fixture.store.read().sampleWork[workID]?.authorization, .waitingForRegistration)
            } else {
                guard case .discarded = outcome else { return XCTFail("\(authorization) must reject") }
                XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, authorization.rawValue)
            }
        }
    }

    func testUnregisteredActiveRouteOutsideExactCandidateHandoffIsByteIdentical() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.epochs[fixture.epochID]?.registeredAt = nil
            state.installWork[fixture.installID]?.authorization = .offlinePending
        }
        let before = try Data(contentsOf: fixture.storeURL)

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .discarded = outcome else { return XCTFail("only an exact candidate may queue before registration") }
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
    }

    func testDuplicateMixedPhaseInstallsFailClosedByteIdentically() throws {
        let duplicatePhases: [ActivityInstallPhase] = [
            .pendingStart, .starting, .installed, .verified,
            .dualActive, .active, .pendingStop, .stopped
        ]
        for duplicatePhase in duplicatePhases {
            let fixture = try CallbackFixture.active()
            defer { fixture.cleanup() }
            let duplicateID = UUID()
            try fixture.mutate { state in
                state.installWork[duplicateID] = ActivityInstallWork(
                    workID: duplicateID,
                    ownerChildDeviceID: fixture.owner,
                    routeID: fixture.routeID,
                    authorization: .registered,
                    phase: duplicatePhase,
                    claim: nil,
                    retry: MeteringRetryState(
                        attemptCount: 0,
                        nextAttemptAt: fixture.start,
                        lastErrorCode: nil,
                        terminal: .pending
                    ),
                    createdAt: fixture.start
                )
            }
            let before = try Data(contentsOf: fixture.storeURL)

            let outcome = try fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )

            guard case .discarded = outcome else {
                return XCTFail("duplicate \(duplicatePhase) install must fail closed")
            }
            XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before, duplicatePhase.rawValue)
        }
    }

    func testJitterZeroAcceptsExactBoundaryAndRejectsOneSecondEarly() throws {
        let accepted = try CallbackFixture.active()
        defer { accepted.cleanup() }
        let acceptedOutcome = try accepted.callbackHandler(jitterSeconds: 0).handle(
            accepted.callback(threshold: 5, observedAt: accepted.start.addingTimeInterval(300)),
            expectedOwnerChildDeviceID: accepted.owner
        )
        guard case .queued = acceptedOutcome else { return XCTFail("exact zero-jitter boundary must queue") }

        let rejected = try CallbackFixture.active()
        defer { rejected.cleanup() }
        let before = try Data(contentsOf: rejected.storeURL)
        let rejectedOutcome = try rejected.callbackHandler(jitterSeconds: 0).handle(
            rejected.callback(threshold: 5, observedAt: rejected.start.addingTimeInterval(299)),
            expectedOwnerChildDeviceID: rejected.owner
        )
        XCTAssertEqual(rejectedOutcome, .discarded(reason: "too_early"))
        XCTAssertEqual(try Data(contentsOf: rejected.storeURL), before)
    }

    func testJitterSixtyAcceptsExactAllowanceAndRejectsSixtyOneSecondsEarly() throws {
        let accepted = try CallbackFixture.active()
        defer { accepted.cleanup() }
        let acceptedOutcome = try accepted.callbackHandler(jitterSeconds: 60).handle(
            accepted.callback(threshold: 5, observedAt: accepted.start.addingTimeInterval(240)),
            expectedOwnerChildDeviceID: accepted.owner
        )
        guard case .queued = acceptedOutcome else { return XCTFail("exact maximum-jitter boundary must queue") }

        let rejected = try CallbackFixture.active()
        defer { rejected.cleanup() }
        let before = try Data(contentsOf: rejected.storeURL)
        let rejectedOutcome = try rejected.callbackHandler(jitterSeconds: 60).handle(
            rejected.callback(threshold: 5, observedAt: rejected.start.addingTimeInterval(239)),
            expectedOwnerChildDeviceID: rejected.owner
        )
        XCTAssertEqual(rejectedOutcome, .discarded(reason: "too_early"))
        XCTAssertEqual(try Data(contentsOf: rejected.storeURL), before)
    }

    func testDualV2CandidateQueuesWaitingForRegistrationWithoutSummingRouteUsage() throws {
        let fixture = try CallbackFixture.dualV2()
        defer { fixture.cleanup() }

        let priorOutcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        let candidateOutcome = try fixture.callbackHandler().handle(
            fixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case let .queued(priorID) = priorOutcome,
              case let .queued(candidateID) = candidateOutcome
        else { return XCTFail("both exact dual-v2 routes must queue") }
        let state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork[priorID]?.request.estimatedMinutes, 17)
        XCTAssertEqual(state.sampleWork[candidateID]?.request.estimatedMinutes, 17)
        XCTAssertEqual(state.sampleWork[candidateID]?.authorization, .waitingForRegistration)
    }

    func testCutoverReadyPriorCallbackIsByteIdenticalDiscardWhileCandidateQueues() throws {
        let fixture = try CallbackFixture.dualV2(phase: .cutoverReady)
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.storeURL)

        let priorOutcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        XCTAssertEqual(priorOutcome, .discarded(reason: "handoff_prior_input_closed"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
        let candidateOutcome = try fixture.callbackHandler().handle(
            fixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .queued = candidateOutcome else { return XCTFail("candidate must remain countable") }
    }

    func testPriorCallbackLosingRealRootLockBarrierIsDiscardedWithoutWork() throws {
        let lock = CallbackRaceLock()
        let fixture = try CallbackFixture.dualV2(lock: lock)
        defer { fixture.cleanup() }
        let barrierFinished = expectation(description: "cutover barrier committed")
        let callbackFinished = expectation(description: "prior callback returned")
        let outcome = CallbackOutcomeBox()

        lock.pauseNextAcquisition()
        DispatchQueue.global().async {
            defer { barrierFinished.fulfill() }
            try? fixture.store.transaction(expectedOwner: fixture.owner) { state in
                guard var handoff = state.v2RouteHandoff,
                      handoff.phase == .dualV2,
                      !state.sampleWork.values.contains(where: {
                          $0.routeID == handoff.fromRouteID && $0.retry.terminal == .pending
                      })
                else { return }
                handoff.phase = .cutoverReady
                handoff.priorRouteInputClosedAt = fixture.start
                state.v2RouteHandoff = handoff
            }
        }
        XCTAssertEqual(lock.waitUntilPaused(timeout: 1), .success)
        DispatchQueue.global().async {
            outcome.value = try? fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )
            callbackFinished.fulfill()
        }

        lock.resume()
        wait(for: [barrierFinished, callbackFinished], timeout: 2)

        XCTAssertEqual(outcome.value, .discarded(reason: "handoff_prior_input_closed"))
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
        XCTAssertEqual(try fixture.store.read().v2RouteHandoff?.phase, .cutoverReady)
    }

    func testPriorCallbackWinningRealRootLockBarrierQueuesAndMakesBarrierFail() throws {
        let lock = CallbackRaceLock()
        let fixture = try CallbackFixture.dualV2(lock: lock)
        defer { fixture.cleanup() }
        let callbackFinished = expectation(description: "callback queued before barrier")
        let barrierFinished = expectation(description: "barrier observed queued prior work")
        let outcome = CallbackOutcomeBox()
        let barrierSucceeded = BoolBox()

        lock.pauseAfterNextTwoAcquisitions()
        DispatchQueue.global().async {
            outcome.value = try? fixture.callbackHandler().handle(
                fixture.callback(threshold: 5),
                expectedOwnerChildDeviceID: fixture.owner
            )
            callbackFinished.fulfill()
        }
        XCTAssertEqual(lock.waitUntilPaused(timeout: 1), .success)
        DispatchQueue.global().async {
            let committed = (try? fixture.store.transaction(expectedOwner: fixture.owner) { state -> Bool in
                guard var handoff = state.v2RouteHandoff,
                      handoff.phase == .dualV2,
                      !state.sampleWork.values.contains(where: {
                          $0.routeID == handoff.fromRouteID && $0.retry.terminal == .pending
                      })
                else { return false }
                handoff.phase = .cutoverReady
                handoff.priorRouteInputClosedAt = fixture.start
                state.v2RouteHandoff = handoff
                return true
            }) ?? false
            barrierSucceeded.value = committed
            barrierFinished.fulfill()
        }

        lock.resume()
        wait(for: [callbackFinished, barrierFinished], timeout: 2)

        guard case .queued = outcome.value else { return XCTFail("callback must win the shared root lock") }
        XCTAssertFalse(barrierSucceeded.value)
        XCTAssertEqual(try fixture.store.read().v2RouteHandoff?.phase, .dualV2)
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
    }

    func testExactRegistrationAcknowledgementPromotesWaitingCandidateSample() async throws {
        let fixture = try CallbackFixture.dualV2(phase: .cutoverReady)
        defer { fixture.cleanup() }
        let outcome = try fixture.callbackHandler().handle(
            fixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        guard case let .queued(workID) = outcome else { return XCTFail("candidate callback must queue") }
        XCTAssertEqual(try fixture.store.read().sampleWork[workID]?.authorization, .waitingForRegistration)

        let transport = CallbackTransport(response: fixture.registrationResponse())
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: fixture.store,
            transport: transport,
            clock: CallbackClock(now: fixture.start)
        )
        try delivery.enqueueRegistration(
            fixture.candidateRegistrationRequest(),
            owner: fixture.owner,
            epochID: fixture.candidateEpochID,
            routeID: fixture.candidateRouteID
        )
        await delivery.drain(owner: fixture.owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork[workID]?.authorization, .v2Deliverable)
        XCTAssertEqual(state.installWork[fixture.candidateInstallID]?.authorization, .registered)
        XCTAssertEqual(transport.requests.count, 1)
    }
}

private struct CallbackClock: MeteringClock {
    let now: Date
}

private struct ExtraCallbackRoute {
    let epochID: UUID
    let callback: MeteringAppleCallback
}

private final class CallbackFixture {
    let owner: UUID
    let start: Date
    let storeURL: URL
    let store: DeviceEpochStore
    let generationID = UUID()
    let epochID = UUID()
    let routeID = UUID()
    let installID = UUID()

    init(owner: UUID, lock: any DeviceEpochStoreLocking = CallbackFixture.defaultLock) {
        self.owner = owner
        start = Date(timeIntervalSince1970: 1_784_937_600)
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-metering-callback-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, lock: lock, ownerProvider: { owner })
    }

    private static let defaultLock = CallbackFixtureLock()

    static func active(
        usageDate: String = "2026-07-18",
        lock: any DeviceEpochStoreLocking = CallbackFixture.defaultLock
    ) throws -> CallbackFixture {
        let fixture = CallbackFixture(owner: UUID(), lock: lock)
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state = fixture.activeState(usageDate: usageDate)
        }
        return fixture
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func callbackHandler(
        jitterSeconds: Int = EarnedMeteringCallback.defaultJitterSeconds
    ) -> EarnedMeteringCallback {
        EarnedMeteringCallback(
            store: store,
            clock: CallbackClock(now: start.addingTimeInterval(5 * 60)),
            jitterSeconds: jitterSeconds
        )
    }

    func exhaustedCoverage() -> MonitorCoverageState {
        MonitorCoverageState(
            ownerChildDeviceID: owner,
            requiredFromUsageDate: "2026-07-18",
            requiredThroughUsageDate: "2026-07-25",
            readyThroughUsageDate: nil,
            status: .coverageExhausted,
            refreshedAt: start,
            errorCode: "coverage_exhausted"
        )
    }

    func addRouteOutsideHandoff(
        status: DeviceDailyEpochStatus,
        resumeBoundaryPending: Bool
    ) throws -> ExtraCallbackRoute {
        let extraEpochID = UUID()
        let extraRouteID = UUID()
        let extraInstallID = UUID()
        try mutate { state in
            guard let generation = state.generations[generationID],
                  let priorEpoch = state.epochs[epochID]
            else { return }
            let extraEpoch = DeviceDailyEpoch(
                epochID: extraEpochID,
                protocolVersion: 2,
                childDeviceID: owner,
                usageDate: priorEpoch.usageDate,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                startedAt: start,
                registeredAt: start,
                baseAcceptedMinutes: priorEpoch.baseAcceptedMinutes,
                baseSource: .childState200,
                lastRawThresholdMinutes: 0,
                excludedWhilePausedMinutes: 0,
                status: status,
                resumeBoundaryPending: resumeBoundaryPending,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            let activityName = MeteringRouteNamespace.activityName(routeID: extraRouteID)
            let event = MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(routeID: extraRouteID, thresholdMinutes: 5),
                thresholdMinutes: 5
            )
            let schedule = DatedSchedulePlan(
                usageDate: extraEpoch.usageDate,
                timezoneIdentifier: generation.canonicalTimezone,
                calendarIdentifier: "gregorian"
            )
            state.epochs[extraEpochID] = extraEpoch
            state.routes[extraRouteID] = MeteringCallbackRoute(
                routeID: extraRouteID,
                activityName: activityName,
                namespace: MeteringRouteNamespace.prefix,
                generationID: generationID,
                generationKey: MeteringGenerationKey(
                    protocolVersion: 2,
                    childDeviceID: owner,
                    canonicalTimezone: generation.canonicalTimezone,
                    policyRevision: generation.policyRevision,
                    measurementSelectionDigest: generation.measurementSelectionDigest,
                    enforcementSetID: generation.enforcementSetID
                ),
                ownerChildDeviceID: owner,
                usageDate: extraEpoch.usageDate,
                epochID: extraEpochID,
                plannedSchedule: schedule,
                installedSchedule: schedule,
                plannedEvents: [event],
                installedEvents: [event],
                lifecycle: .active,
                createdAt: start
            )
            state.installWork[extraInstallID] = ActivityInstallWork(
                workID: extraInstallID,
                ownerChildDeviceID: owner,
                routeID: extraRouteID,
                authorization: .registered,
                phase: .active,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .succeeded
                ),
                createdAt: start
            )
        }
        return ExtraCallbackRoute(
            epochID: extraEpochID,
            callback: MeteringAppleCallback(
                activityName: MeteringRouteNamespace.activityName(routeID: extraRouteID),
                eventName: MeteringRouteNamespace.eventName(routeID: extraRouteID, thresholdMinutes: 5),
                observedAt: start.addingTimeInterval(5 * 60)
            )
        )
    }

    func mutate(_ body: (inout DeviceEpochStoreState) -> Void) throws {
        try store.transaction(expectedOwner: owner, body)
    }

    func callback(threshold: Int, observedAt: Date? = nil) -> MeteringAppleCallback {
        MeteringAppleCallback(
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: threshold),
            observedAt: observedAt ?? start.addingTimeInterval(TimeInterval(threshold * 60))
        )
    }

    func authorizedInput(
        activityName: String? = nil,
        eventName: String? = nil,
        namespace: String? = nil
    ) -> MeteringAuthorizedCallbackInput {
        MeteringAuthorizedCallbackInput(
            routeID: routeID,
            activityName: activityName ?? MeteringRouteNamespace.activityName(routeID: routeID),
            eventName: eventName ?? MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
            namespace: namespace ?? MeteringRouteNamespace.prefix,
            thresholdMinutes: 5,
            observedAt: start.addingTimeInterval(5 * 60),
            now: start.addingTimeInterval(5 * 60),
            jitterSeconds: EarnedMeteringCallback.defaultJitterSeconds
        )
    }

    func candidateCallback(threshold: Int) -> MeteringAppleCallback {
        MeteringAppleCallback(
            activityName: MeteringRouteNamespace.activityName(routeID: candidateRouteID),
            eventName: MeteringRouteNamespace.eventName(routeID: candidateRouteID, thresholdMinutes: threshold),
            observedAt: start.addingTimeInterval(TimeInterval(threshold * 60))
        )
    }

    func candidateRegistrationRequest() -> EpochRegistrationRequestDTO {
        let state = try! store.read()
        let epoch = state.epochs[candidateEpochID]!
        return EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: candidateEpochID,
            deviceID: owner,
            usageDate: epoch.usageDate,
            timezone: epoch.canonicalTimezone,
            policyRevision: epoch.policyRevision,
            measurementSelectionDigest: epoch.measurementSelectionDigest,
            enforcementSetID: epoch.enforcementSetID,
            startedAt: epoch.startedAt,
            baseAcceptedMinutes: epoch.baseAcceptedMinutes,
            reason: .policyChange
        )
    }

    func registrationResponse() -> (Data, URLResponse) {
        let state = try! store.read()
        let epoch = state.epochs[candidateEpochID]!
        let snapshot = DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: epoch.usageDate,
            estimatedMinutes: epoch.baseAcceptedMinutes,
            capMinutes: 120,
            childDayState: "available",
            usedMinutes: epoch.baseAcceptedMinutes,
            remainingMinutes: 120 - epoch.baseAcceptedMinutes,
            counted: true,
            warning: nil
        )
        let response = EpochRegistrationResponseDTO(
            status: .registered,
            epochID: candidateEpochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot,
            epochStatus: .active
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (
            try! encoder.encode(response),
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/api/v1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    let candidateGenerationID = UUID()
    let candidateEpochID = UUID()
    let candidateRouteID = UUID()
    let candidateInstallID = UUID()

    static func dualV2(
        phase: V2RouteHandoffPhase = .dualV2,
        lock: any DeviceEpochStoreLocking = CallbackFixture.defaultLock
    ) throws -> CallbackFixture {
        let fixture = try active(lock: lock)
        try fixture.mutate { state in
            guard let priorGeneration = state.generations[fixture.generationID],
                  let priorEpoch = state.epochs[fixture.epochID]
            else { return }
            let candidateGeneration = MeteringPolicyGeneration(
                generationID: fixture.candidateGenerationID,
                protocolVersion: 2,
                childDeviceID: fixture.owner,
                canonicalTimezone: priorGeneration.canonicalTimezone,
                policyRevision: "policy-2",
                measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: Data([2])),
                enforcementSetID: UUID(),
                measurementSelectionBytes: Data([2]),
                createdAt: fixture.start,
                retiredAt: nil
            )
            let candidateEpoch = DeviceDailyEpoch(
                epochID: fixture.candidateEpochID,
                protocolVersion: 2,
                childDeviceID: fixture.owner,
                usageDate: priorEpoch.usageDate,
                canonicalTimezone: candidateGeneration.canonicalTimezone,
                policyRevision: candidateGeneration.policyRevision,
                measurementSelectionDigest: candidateGeneration.measurementSelectionDigest,
                enforcementSetID: candidateGeneration.enforcementSetID,
                startedAt: fixture.start,
                registeredAt: nil,
                baseAcceptedMinutes: priorEpoch.baseAcceptedMinutes,
                baseSource: .childState200,
                lastRawThresholdMinutes: 0,
                excludedWhilePausedMinutes: 0,
                status: .active,
                resumeBoundaryPending: false,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            let candidateRoute = MeteringCallbackRoute(
                routeID: fixture.candidateRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: fixture.candidateRouteID),
                namespace: MeteringRouteNamespace.prefix,
                generationID: candidateGeneration.generationID,
                generationKey: MeteringGenerationKey(
                    protocolVersion: 2,
                    childDeviceID: fixture.owner,
                    canonicalTimezone: candidateGeneration.canonicalTimezone,
                    policyRevision: candidateGeneration.policyRevision,
                    measurementSelectionDigest: candidateGeneration.measurementSelectionDigest,
                    enforcementSetID: candidateGeneration.enforcementSetID
                ),
                ownerChildDeviceID: fixture.owner,
                usageDate: candidateEpoch.usageDate,
                epochID: candidateEpoch.epochID,
                plannedSchedule: DatedSchedulePlan(
                    usageDate: candidateEpoch.usageDate,
                    timezoneIdentifier: candidateGeneration.canonicalTimezone,
                    calendarIdentifier: "gregorian"
                ),
                installedSchedule: DatedSchedulePlan(
                    usageDate: candidateEpoch.usageDate,
                    timezoneIdentifier: candidateGeneration.canonicalTimezone,
                    calendarIdentifier: "gregorian"
                ),
                plannedEvents: [MeteringEventPlan(
                    eventName: MeteringRouteNamespace.eventName(routeID: fixture.candidateRouteID, thresholdMinutes: 5),
                    thresholdMinutes: 5
                )],
                installedEvents: [MeteringEventPlan(
                    eventName: MeteringRouteNamespace.eventName(routeID: fixture.candidateRouteID, thresholdMinutes: 5),
                    thresholdMinutes: 5
                )],
                lifecycle: .active,
                createdAt: fixture.start
            )
            state.generations[candidateGeneration.generationID] = candidateGeneration
            state.epochs[candidateEpoch.epochID] = candidateEpoch
            state.routes[candidateRoute.routeID] = candidateRoute
            state.installWork[fixture.candidateInstallID] = ActivityInstallWork(
                workID: fixture.candidateInstallID,
                ownerChildDeviceID: fixture.owner,
                routeID: candidateRoute.routeID,
                authorization: .offlinePending,
                phase: .dualActive,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: fixture.start,
                    lastErrorCode: nil,
                    terminal: .succeeded
                ),
                createdAt: fixture.start
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: fixture.owner,
                fromGenerationID: fixture.generationID,
                fromEpochID: fixture.epochID,
                fromRouteID: fixture.routeID,
                toGenerationID: fixture.candidateGenerationID,
                toEpochID: fixture.candidateEpochID,
                toRouteID: fixture.candidateRouteID,
                phase: phase,
                priorRouteInputClosedAt: phase == .cutoverReady ? fixture.start : nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: fixture.start
            )
        }
        return fixture
    }

    private func activeState(usageDate: String) -> DeviceEpochStoreState {
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: Data([1])),
            enforcementSetID: UUID(),
            measurementSelectionBytes: Data([1]),
            createdAt: start,
            retiredAt: nil
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: usageDate,
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest,
            enforcementSetID: generation.enforcementSetID,
            startedAt: start,
            registeredAt: start,
            baseAcceptedMinutes: 12,
            baseSource: .childState200,
            lastRawThresholdMinutes: 0,
            excludedWhilePausedMinutes: 0,
            status: .active,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        let route = MeteringCallbackRoute(
            routeID: routeID,
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            namespace: MeteringRouteNamespace.prefix,
            generationID: generationID,
            generationKey: MeteringGenerationKey(
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID
            ),
            ownerChildDeviceID: owner,
            usageDate: epoch.usageDate,
            epochID: epochID,
            plannedSchedule: DatedSchedulePlan(
                usageDate: epoch.usageDate,
                timezoneIdentifier: generation.canonicalTimezone,
                calendarIdentifier: "gregorian"
            ),
            installedSchedule: DatedSchedulePlan(
                usageDate: epoch.usageDate,
                timezoneIdentifier: generation.canonicalTimezone,
                calendarIdentifier: "gregorian"
            ),
            plannedEvents: [MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
                thresholdMinutes: 5
            )],
            installedEvents: [MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
                thresholdMinutes: 5
            )],
            lifecycle: .active,
            createdAt: start
        )
        let install = ActivityInstallWork(
            workID: installID,
            ownerChildDeviceID: owner,
            routeID: routeID,
            authorization: .registered,
            phase: .active,
            claim: nil,
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: start,
                lastErrorCode: nil,
                terminal: .succeeded
            ),
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
            registrationWork: [:],
            installWork: [installID: install],
            ratchets: [owner: MeteringOwnerRatchet(
                ownerChildDeviceID: owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: start,
                dualActiveAt: start,
                activatedV2At: start
            )]
        )
    }
}

private final class CallbackFixtureLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CallbackRaceLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    private let paused = DispatchSemaphore(value: 0)
    private let resumeGate = DispatchSemaphore(value: 0)
    private var acquisitionCount = 0
    private var pauseAtAcquisition: Int?

    func pauseNextAcquisition() {
        lock.lock()
        pauseAtAcquisition = acquisitionCount + 1
        lock.unlock()
    }

    func pauseAfterNextTwoAcquisitions() {
        lock.lock()
        pauseAtAcquisition = acquisitionCount + 2
        lock.unlock()
    }

    func waitUntilPaused(timeout: TimeInterval) -> DispatchTimeoutResult {
        paused.wait(timeout: .now() + timeout)
    }

    func resume() {
        resumeGate.signal()
    }

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        acquisitionCount += 1
        let shouldPause = pauseAtAcquisition == acquisitionCount
        if shouldPause { pauseAtAcquisition = nil }
        if shouldPause {
            paused.signal()
            _ = resumeGate.wait(timeout: .now() + 2)
        }
        defer { lock.unlock() }
        return body()
    }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class CallbackOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EarnedMeteringCallbackOutcome?

    var value: EarnedMeteringCallbackOutcome? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class CallbackTransport: MeteringHTTPTransport, @unchecked Sendable {
    private let response: (Data, URLResponse)
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(response: (Data, URLResponse)) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return response
    }
}
