import Foundation
import XCTest
@testable import Evlin_iOS

final class EarnedMeteringCallbackTests: XCTestCase {
    func testFileBackedJournalIgnoresStaleSharedDefaultsAndSurvivesRestart() throws {
        let fileIO = CountingCallbackFileIO()
        let fixture = try CallbackFixture.active(fileIO: fileIO)
        defer { fixture.cleanup() }
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-v2-callback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let suiteName = "earned-v2-callback-stale-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("[]".utf8), forKey: EarnedV2CallbackJournal.storageKey)

        let firstJournal = EarnedV2CallbackJournal(
            fileURL: journalURL,
            legacyDefaults: defaults,
            lock: CallbackFixtureLock()
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: CallbackClock(now: fixture.start.addingTimeInterval(5 * 60)),
            journal: firstJournal
        )

        _ = try callback.handleDurably(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        // Simulate another process retaining a stale CFPreferences snapshot.
        defaults.set(Data("[]".utf8), forKey: EarnedV2CallbackJournal.storageKey)
        let restartedJournal = EarnedV2CallbackJournal(
            fileURL: journalURL,
            legacyDefaults: defaults,
            lock: CallbackFixtureLock()
        )
        XCTAssertEqual(try restartedJournal.pending(owner: fixture.owner).count, 1)
        XCTAssertEqual(
            try restartedJournal.replay(into: fixture.store, owner: fixture.owner),
            1
        )
        XCTAssertTrue(try restartedJournal.pending(owner: fixture.owner).isEmpty)
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
    }

    func testDurableNonterminalCallbackQueuesSidecarWithoutRewritingEpochRoot() throws {
        let fileIO = CountingCallbackFileIO()
        let fixture = try CallbackFixture.active(fileIO: fileIO)
        defer { fixture.cleanup() }
        let suiteName = "earned-v2-callback-journal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let journal = EarnedV2CallbackJournal(
            defaults: defaults,
            lock: CallbackFixtureLock()
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: CallbackClock(now: fixture.start.addingTimeInterval(5 * 60)),
            journal: journal
        )
        fileIO.resetCounts()

        let outcome = try callback.handleDurably(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case let .queued(workID) = outcome else {
            return XCTFail("Expected a durable queued callback, got \(outcome)")
        }
        XCTAssertEqual(fileIO.writeCount, 0)
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty)
        let pending = try journal.pending(owner: fixture.owner)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].work.workID, workID)
        XCTAssertEqual(pending[0].work.request.thresholdMinutes, 5)
    }

    func testV2CallbackSidecarReplayImportsExactlyOnceAfterRestart() throws {
        let fileIO = CountingCallbackFileIO()
        let fixture = try CallbackFixture.active(fileIO: fileIO)
        defer { fixture.cleanup() }
        let suiteName = "earned-v2-callback-journal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let journal = EarnedV2CallbackJournal(
            defaults: defaults,
            lock: CallbackFixtureLock()
        )
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: CallbackClock(now: fixture.start.addingTimeInterval(5 * 60)),
            journal: journal
        )
        _ = try callback.handleDurably(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        let first = try journal.replay(into: fixture.store, owner: fixture.owner)
        let afterFirst = try fixture.store.read()
        let second = try journal.replay(into: fixture.store, owner: fixture.owner)
        let afterSecond = try fixture.store.read()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(afterFirst.sampleWork.count, 1)
        XCTAssertEqual(afterSecond.sampleWork, afterFirst.sampleWork)
        XCTAssertTrue(try journal.pending(owner: fixture.owner).isEmpty)
    }

    func testRejectedConsumedCallbackUsesOneDecodeAndOneCommittedReadback() throws {
        let fileIO = CountingCallbackFileIO()
        let fixture = try CallbackFixture.active(fileIO: fileIO)
        defer { fixture.cleanup() }
        fileIO.resetReadCount()

        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.authorizedInput(observedAt: fixture.start),
            owner: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "too_early"))
        XCTAssertEqual(
            fileIO.readCount,
            2,
            "Persisting the consumed-route marker requires exactly one transactional readback."
        )
    }

    func testPersistedOwnerMismatchIsOneReadByteIdenticalDiscard() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let currentOwner = UUID()
        let fileIO = CountingCallbackFileIO()
        let store = DeviceEpochStore(
            fileURL: fixture.storeURL,
            lock: CallbackFixtureLock(),
            fileIO: fileIO,
            ownerProvider: { currentOwner }
        )
        let before = try Data(contentsOf: fixture.storeURL)

        let outcome = try store.enqueueAuthorizedV2Callback(
            fixture.authorizedInput(),
            owner: currentOwner
        )

        XCTAssertEqual(outcome, .discarded(reason: "owner_mismatch"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), before)
        XCTAssertEqual(fileIO.readCount, 1)
    }

    func testCompactionCollapsesDuplicateTerminalRegistrationFailures() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            guard let generation = state.generations[fixture.generationID],
                  let epoch = state.epochs[fixture.epochID]
            else { return }
            for offset in 0..<100 {
                let workID = UUID()
                state.registrationWork[workID] = EpochRegistrationWork(
                    workID: workID,
                    ownerChildDeviceID: fixture.owner,
                    epochID: fixture.epochID,
                    routeID: fixture.routeID,
                    request: EpochRegistrationRequestDTO(
                        protocolVersion: 2,
                        epochID: fixture.epochID,
                        deviceID: fixture.owner,
                        usageDate: epoch.usageDate,
                        timezone: generation.canonicalTimezone,
                        policyRevision: generation.policyRevision,
                        measurementSelectionDigest: generation.measurementSelectionDigest,
                        enforcementSetID: generation.enforcementSetID,
                        startedAt: fixture.start,
                        baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                        reason: .initial
                    ),
                    claim: nil,
                    retry: MeteringRetryState(
                        attemptCount: 1,
                        nextAttemptAt: fixture.start,
                        lastErrorCode: "policy_revision_mismatch",
                        terminal: .rejected
                    ),
                    createdAt: fixture.start.addingTimeInterval(TimeInterval(offset))
                )
            }
            let divergentWorkID = UUID()
            state.registrationWork[divergentWorkID] = EpochRegistrationWork(
                workID: divergentWorkID,
                ownerChildDeviceID: fixture.owner,
                epochID: fixture.epochID,
                routeID: fixture.routeID,
                request: EpochRegistrationRequestDTO(
                    protocolVersion: 2,
                    epochID: fixture.epochID,
                    deviceID: fixture.owner,
                    usageDate: epoch.usageDate,
                    timezone: generation.canonicalTimezone,
                    policyRevision: generation.policyRevision,
                    measurementSelectionDigest: generation.measurementSelectionDigest,
                    enforcementSetID: generation.enforcementSetID,
                    startedAt: fixture.start,
                    baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                    reason: .policyChange
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 1,
                    nextAttemptAt: fixture.start,
                    lastErrorCode: "policy_revision_mismatch",
                    terminal: .rejected
                ),
                createdAt: fixture.start.addingTimeInterval(200)
            )
            for terminal in [MeteringWorkTerminal.pending, .succeeded] {
                let workID = UUID()
                state.registrationWork[workID] = EpochRegistrationWork(
                    workID: workID,
                    ownerChildDeviceID: fixture.owner,
                    epochID: fixture.epochID,
                    routeID: fixture.routeID,
                    request: EpochRegistrationRequestDTO(
                        protocolVersion: 2,
                        epochID: fixture.epochID,
                        deviceID: fixture.owner,
                        usageDate: epoch.usageDate,
                        timezone: generation.canonicalTimezone,
                        policyRevision: generation.policyRevision,
                        measurementSelectionDigest: generation.measurementSelectionDigest,
                        enforcementSetID: generation.enforcementSetID,
                        startedAt: fixture.start,
                        baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                        reason: .initial
                    ),
                    claim: nil,
                    retry: MeteringRetryState(
                        attemptCount: 1,
                        nextAttemptAt: fixture.start,
                        lastErrorCode: nil,
                        terminal: terminal
                    ),
                    createdAt: fixture.start.addingTimeInterval(300)
                )
            }
        }

        let removed = try fixture.store.compactTerminalRegistrationHistory(owner: fixture.owner)
        let state = try fixture.store.read()

        XCTAssertEqual(removed, 99)
        XCTAssertEqual(state.registrationWork.count, 4)
        XCTAssertEqual(
            state.registrationWork.values
                .first(where: { $0.request.reason == .initial && $0.retry.terminal == .rejected })?
                .createdAt,
            fixture.start.addingTimeInterval(99)
        )
        XCTAssertTrue(state.registrationWork.values.contains {
            $0.request.reason == .policyChange && $0.retry.terminal == .rejected
        })
        XCTAssertTrue(state.registrationWork.values.contains { $0.retry.terminal == .pending })
        XCTAssertTrue(state.registrationWork.values.contains { $0.retry.terminal == .succeeded })
    }

    func testCompactionCollectsStoppedSupersededRouteFromActiveGeneration() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let stale = try fixture.addStoppedSupersededRoute(
            stoppedAt: fixture.start,
            installTerminal: .pending
        )

        let removed = try fixture.store.compactPhysicallyAbsentRetiredHistory(
            owner: fixture.owner,
            physicallyInstalledActivityNames: [
                MeteringRouteNamespace.activityName(routeID: fixture.routeID)
            ],
            now: fixture.start.addingTimeInterval(20 * 60)
        )
        let state = try fixture.store.read()

        XCTAssertEqual(removed, 3)
        XCTAssertNil(state.routes[stale.routeID])
        XCTAssertNil(state.epochs[stale.epochID])
        XCTAssertNil(state.tombstones[stale.routeID])
        XCTAssertNil(state.installWork[stale.installID])
        XCTAssertNil(state.registrationWork[stale.registrationID])
        XCTAssertNotNil(state.generations[fixture.generationID])
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
    }

    func testCompactionRetainsStoppedSupersededRouteDuringLateCallbackGrace() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let stale = try fixture.addStoppedSupersededRoute(
            stoppedAt: fixture.start
        )

        let removed = try fixture.store.compactPhysicallyAbsentRetiredHistory(
            owner: fixture.owner,
            physicallyInstalledActivityNames: [
                MeteringRouteNamespace.activityName(routeID: fixture.routeID)
            ],
            now: fixture.start.addingTimeInterval((20 * 60) - 1)
        )
        let state = try fixture.store.read()

        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(state.routes[stale.routeID])
        XCTAssertNotNil(state.epochs[stale.epochID])
        XCTAssertNotNil(state.tombstones[stale.routeID])
    }

    func testCompactionRetainsStoppedSupersededRouteStillInstalledInDaemon() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let stale = try fixture.addStoppedSupersededRoute(
            stoppedAt: fixture.start
        )

        let removed = try fixture.store.compactPhysicallyAbsentRetiredHistory(
            owner: fixture.owner,
            physicallyInstalledActivityNames: [
                MeteringRouteNamespace.activityName(routeID: fixture.routeID),
                MeteringRouteNamespace.activityName(routeID: stale.routeID),
            ],
            now: fixture.start.addingTimeInterval(20 * 60)
        )
        let state = try fixture.store.read()

        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(state.routes[stale.routeID])
        XCTAssertNotNil(state.epochs[stale.epochID])
        XCTAssertNotNil(state.tombstones[stale.routeID])
    }

    func testCompactionRetainsStoppedSupersededRouteWithPendingWork() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let stale = try fixture.addStoppedSupersededRoute(
            stoppedAt: fixture.start,
            registrationTerminal: .pending
        )

        let removed = try fixture.store.compactPhysicallyAbsentRetiredHistory(
            owner: fixture.owner,
            physicallyInstalledActivityNames: [
                MeteringRouteNamespace.activityName(routeID: fixture.routeID)
            ],
            now: fixture.start.addingTimeInterval(20 * 60)
        )
        let state = try fixture.store.read()

        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(state.routes[stale.routeID])
        XCTAssertEqual(
            state.registrationWork[stale.registrationID]?.retry.terminal,
            .pending
        )
    }

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
        XCTAssertEqual(
            work?.request.activityName,
            MeteringSampleWireAliases.activityName(routeID: fixture.routeID)
        )
        XCTAssertEqual(
            work?.request.eventName,
            MeteringSampleWireAliases.eventName(thresholdMinutes: 5)
        )
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

    func testThirtyOneSecondsEarlyMarksConsumedRouteAndQueuesNothing() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let callback = fixture.callback(threshold: 5, observedAt: fixture.start.addingTimeInterval(269))

        let outcome = try fixture.callbackHandler().handle(callback, expectedOwnerChildDeviceID: fixture.owner)

        XCTAssertEqual(outcome, .discarded(reason: "too_early"))
        let state = try fixture.store.read()
        XCTAssertTrue(state.sampleWork.isEmpty)
        XCTAssertEqual(state.epochs[fixture.epochID]?.lastRawThresholdMinutes, 0)
        XCTAssertEqual(
            state.installWork[fixture.installID]?.retry.lastErrorCode,
            "physical_events_consumed_too_early"
        )
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

    // A retired route is finished: its callback is a zero-effect discard. A PLANNED
    // route is the opposite case — it is still activating, so its callback is
    // parked for replay (FIX-A) rather than dropped. Both credit nothing now;
    // only the planned one leaves a durable trace.
    func testRetiredRouteDiscardsWithoutEffectWhilePlannedRouteParksForReplay() throws {
        let retired = try CallbackFixture.active()
        defer { retired.cleanup() }
        try retired.mutate { state in
            state.routes[retired.routeID]?.lifecycle = .retired
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
        }
        let retiredBefore = try Data(contentsOf: retired.storeURL)

        let retiredOutcome = try retired.callbackHandler().handle(
            retired.callback(threshold: 5),
            expectedOwnerChildDeviceID: retired.owner
        )

        guard case .discarded = retiredOutcome else { return XCTFail("retired must reject") }
        XCTAssertEqual(try Data(contentsOf: retired.storeURL), retiredBefore,
                       "a retired route must leave the store byte-identical")

        let planned = try CallbackFixture.active()
        defer { planned.cleanup() }
        try planned.mutate { state in
            state.routes[planned.routeID]?.lifecycle = .planned
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
        }

        let plannedOutcome = try planned.callbackHandler().handle(
            planned.callback(threshold: 5),
            expectedOwnerChildDeviceID: planned.owner
        )

        XCTAssertEqual(plannedOutcome, .discarded(reason: "deferred_pending_activation"))
        let plannedState = try planned.store.read()
        XCTAssertEqual(plannedState.deferredCallbacks.count, 1,
                       "a still-activating route must park its callback")
        XCTAssertTrue(plannedState.sampleWork.isEmpty,
                      "parking must credit nothing until the route activates")
    }

    // P3 late-callback grace: Apple delivers threshold callbacks 5-15 min late. A
    // policy change that retires the route mid-flight must NOT silently drop a
    // genuine, already-earned callback (the year-long "bars frozen" root cause).
    // The lost minutes are queued against the CURRENT active epoch without
    // raising its base until the backend accepts the sample.
    func testLateCallbackForRouteRetiredWithinGraceCreditsCurrentEpoch() throws {
        let fixture = try CallbackFixture.active()  // original epoch base = 12
        defer { fixture.cleanup() }
        let successorEpoch = try fixture.retireOriginalAndActivateSuccessor(
            retiredAt: fixture.start.addingTimeInterval(4 * 60)  // retired 1 min before the callback
        )

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),  // late callback for the RETIRED route
            expectedOwnerChildDeviceID: fixture.owner
        )

        let state = try fixture.store.read()
        XCTAssertEqual(
            state.epochs[successorEpoch]?.baseAcceptedMinutes,
            12,
            "a raw late callback cannot raise the base before backend acceptance"
        )
        XCTAssertEqual(
            state.sampleWork.values.first?.request.estimatedMinutes,
            17,
            "the recovered minutes still have to be offered to the backend"
        )
        guard case .queued = outcome else {
            return XCTFail("late retired callback within grace must be credited, got \(outcome)")
        }
    }

    // Bound the grace: a callback for a route retired LONG before it arrives
    // (beyond the grace window) is still discarded — no stale-replay credit.
    func testLateCallbackForRouteRetiredBeforeGraceIsStillDiscarded() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let successorEpoch = try fixture.retireOriginalAndActivateSuccessor(
            retiredAt: fixture.start.addingTimeInterval(-3600)  // retired an hour before now
        )
        let baseBefore = try fixture.store.read().epochs[successorEpoch]?.baseAcceptedMinutes

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .discarded = outcome else {
            return XCTFail("callback beyond grace must be discarded, got \(outcome)")
        }
        XCTAssertEqual(try fixture.store.read().epochs[successorEpoch]?.baseAcceptedMinutes, baseBefore,
                       "beyond-grace callback must not touch the current epoch base")
    }

    // FIX-A birth race: Apple back-delivers already-met thresholds ~1s after
    // startMonitoring, while the route needs two network round trips to reach
    // .active. Those callbacks used to hit the strict provenance guard and were
    // dropped for good (Apple never re-sends), so every mid-day re-arm silently
    // lost the day's minutes. They must be parked and credited on activation.
    func testCallbackForRouteStillActivatingIsParkedThenCreditedOnActivation() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        // A still-activating route is by definition not the active one yet — the
        // store's coherence check rejects an activeRouteID pointing at a planned
        // route, so model the real pre-activation shape.
        try fixture.mutate { state in
            state.routes[fixture.routeID]?.lifecycle = .planned
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
        }

        let parkOutcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(parkOutcome, .discarded(reason: "deferred_pending_activation"))
        XCTAssertEqual(try fixture.store.read().deferredCallbacks.count, 1,
                       "a provenance-valid callback must be parked, not dropped")
        XCTAssertTrue(try fixture.store.read().sampleWork.isEmpty,
                      "parking must not credit anything before the route activates")

        // Activation completes: the route becomes active and adopts the pointers.
        try fixture.mutate { state in
            state.routes[fixture.routeID]?.lifecycle = .active
            state.activeRouteID = fixture.routeID
            state.activeEpochID = fixture.epochID
            state.activeGenerationID = fixture.generationID
        }
        let results = try fixture.store.replayDeferredCallbacks(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(6 * 60)
        )

        XCTAssertEqual(results.count, 1)
        guard case .queued = results[0] else {
            return XCTFail("activated route must credit its parked callback, got \(results[0])")
        }
        let state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork.count, 1, "credited callback must enqueue one sample")
        XCTAssertTrue(state.deferredCallbacks.isEmpty, "replayed entry must be cleared")
    }

    // Bound the parking area: a route that never activates must not keep its
    // callbacks forever (they would credit stale minutes if it activated hours
    // later), and the entry must not leak.
    func testParkedCallbackExpiresWhenRouteNeverActivates() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.routes[fixture.routeID]?.lifecycle = .planned
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
        }
        _ = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        XCTAssertEqual(try fixture.store.read().deferredCallbacks.count, 1)

        let results = try fixture.store.replayDeferredCallbacks(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(
                DeviceEpochStore.deferredCallbackGraceSeconds + 600
            )
        )

        XCTAssertTrue(results.isEmpty, "an unactivated route must credit nothing")
        XCTAssertTrue(try fixture.store.read().deferredCallbacks.isEmpty,
                      "expired parked entry must be pruned")
    }

    func testActivatingRouteFoldsBurstIntoOneMonotonicDeferredHighWater() throws {
        let fixture = try CallbackFixture.active()
        defer { fixture.cleanup() }
        let thresholds = stride(from: 5, through: 180, by: 5).map { $0 }
        try fixture.mutate { state in
            state.routes[fixture.routeID]?.lifecycle = .planned
            state.routes[fixture.routeID]?.plannedEvents = thresholds.map {
                MeteringEventPlan(
                    eventName: MeteringRouteNamespace.eventName(
                        routeID: fixture.routeID,
                        thresholdMinutes: $0
                    ),
                    thresholdMinutes: $0
                )
            }
            state.activeRouteID = nil
            state.activeEpochID = nil
            state.activeGenerationID = nil
        }

        for threshold in thresholds {
            XCTAssertEqual(
                try fixture.callbackHandler().handle(
                    fixture.callback(threshold: threshold),
                    expectedOwnerChildDeviceID: fixture.owner
                ),
                .discarded(reason: "deferred_pending_activation")
            )
        }

        let parked = try XCTUnwrap(fixture.store.read().deferredCallbacks.values.first)
        XCTAssertEqual(try fixture.store.read().deferredCallbacks.count, 1)
        XCTAssertEqual(parked.thresholdMinutes, 180)
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

    func testPreparingHandoffKeepsExactPriorAuthorityCountable() throws {
        let fixture = try CallbackFixture.dualV2(phase: .preparing)
        defer { fixture.cleanup() }

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .queued = outcome else {
            return XCTFail("make-before-break requires the exact prior route to remain authoritative")
        }
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
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

    func testResumeBoundaryRejectsPreparingAndClosedPriorRoutesByteIdentically() throws {
        let cases: [(String, V2RouteHandoffPhase, Bool)] = [
            ("preparing-prior", .preparing, false),
            ("closed-prior", .cutoverReady, false)
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
        let rejectedOutcome = try rejected.callbackHandler(jitterSeconds: 0).handle(
            rejected.callback(threshold: 5, observedAt: rejected.start.addingTimeInterval(299)),
            expectedOwnerChildDeviceID: rejected.owner
        )
        XCTAssertEqual(rejectedOutcome, .discarded(reason: "too_early"))
        XCTAssertEqual(
            try rejected.store.read().installWork[rejected.installID]?.retry.lastErrorCode,
            "physical_events_consumed_too_early"
        )
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
        let rejectedOutcome = try rejected.callbackHandler(jitterSeconds: 60).handle(
            rejected.callback(threshold: 5, observedAt: rejected.start.addingTimeInterval(239)),
            expectedOwnerChildDeviceID: rejected.owner
        )
        XCTAssertEqual(rejectedOutcome, .discarded(reason: "too_early"))
        XCTAssertEqual(
            try rejected.store.read().installWork[rejected.installID]?.retry.lastErrorCode,
            "physical_events_consumed_too_early"
        )
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

    func testCutoverReadyAcceptsPriorCallbackObservedBeforeInputClosure() throws {
        let fixture = try CallbackFixture.dualV2(phase: .cutoverReady)
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.v2RouteHandoff?.priorRouteInputClosedAt =
                fixture.start.addingTimeInterval(600)
        }

        let outcome = try fixture.callbackHandler().handle(
            fixture.callback(
                threshold: 5,
                observedAt: fixture.start.addingTimeInterval(300)
            ),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .queued = outcome else {
            return XCTFail("delivery time cannot invalidate usage observed before the durable barrier")
        }
        let state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertEqual(state.sampleWork.values.first?.routeID, fixture.candidateRouteID)
        XCTAssertEqual(
            state.sampleWork.values.first?.authorization,
            .waitingForRegistration
        )
    }

    func testExactDualV2CandidateCallbackOverridesStaleCoverageSnapshot() throws {
        let fixture = try CallbackFixture.dualV2()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.coverage = MonitorCoverageState(
                ownerChildDeviceID: fixture.owner,
                requiredFromUsageDate: "2026-07-18",
                requiredThroughUsageDate: "2026-07-18",
                readyThroughUsageDate: nil,
                status: .coverageExhausted,
                refreshedAt: fixture.start,
                errorCode: "stale_test_snapshot"
            )
        }

        let outcome = try fixture.callbackHandler().handle(
            fixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        guard case .queued = outcome else {
            return XCTFail("the daemon callback itself proves this exact candidate is physically armed")
        }
    }

    func testResumeBoundaryBeforeRegistrationPersistsHighWaterExactlyOnce() throws {
        let fixture = try CallbackFixture.dualV2()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.epochs[fixture.candidateEpochID]?.resumeBoundaryPending = true
        }

        let first = try fixture.callbackHandler().handle(
            fixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )
        let second = try fixture.callbackHandler().handle(
            fixture.candidateCallback(threshold: 5),
            expectedOwnerChildDeviceID: fixture.owner
        )

        XCTAssertEqual(first, .discarded(reason: "resume_boundary"))
        XCTAssertNotEqual(second, .discarded(reason: "resume_boundary_unregistered"))
        let epoch = try fixture.store.read().epochs[fixture.candidateEpochID]
        XCTAssertEqual(epoch?.lastRawThresholdMinutes, 5)
        XCTAssertEqual(epoch?.excludedWhilePausedMinutes, 5)
        XCTAssertEqual(epoch?.resumeBoundaryPending, false)
    }

    func testDualV2ConsumedCandidateIsReplacedWithoutDroppingPriorAuthority() throws {
        let fixture = try CallbackFixture.dualV2()
        defer { fixture.cleanup() }
        let originalHandoffID = try XCTUnwrap(
            fixture.store.read().v2RouteHandoff?.handoffID
        )
        try fixture.mutate { state in
            state.installWork[fixture.candidateInstallID]?.retry.lastErrorCode =
                "physical_events_consumed_too_early"
        }

        XCTAssertTrue(
            try fixture.store.repairLadderBaseInvariantIfNeeded(
                owner: fixture.owner,
                now: fixture.start.addingTimeInterval(60)
            )
        )

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
        XCTAssertEqual(handoff.fromRouteID, fixture.routeID)
        XCTAssertNotEqual(handoff.toRouteID, fixture.candidateRouteID)
        XCTAssertNotEqual(handoff.handoffID, originalHandoffID)
        XCTAssertEqual(handoff.phase, .preparing)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(
            state.installWork.values.first(where: {
                $0.routeID == handoff.toRouteID
            })?.phase,
            .pendingStart
        )
    }

    func testConsumedCandidateReplacementIsStableAcrossRecoveryRestart() throws {
        let fixture = try CallbackFixture.dualV2()
        defer { fixture.cleanup() }
        try fixture.mutate { state in
            state.installWork[fixture.candidateInstallID]?.retry.lastErrorCode =
                "physical_events_consumed_too_early"
        }

        XCTAssertTrue(
            try fixture.store.repairLadderBaseInvariantIfNeeded(
                owner: fixture.owner,
                now: fixture.start.addingTimeInterval(60)
            )
        )
        let replaced = try fixture.store.read()
        let replacement = try XCTUnwrap(replaced.v2RouteHandoff)

        XCTAssertFalse(
            try fixture.store.repairLadderBaseInvariantIfNeeded(
                owner: fixture.owner,
                now: fixture.start.addingTimeInterval(120)
            )
        )
        let replayed = try fixture.store.read()
        XCTAssertEqual(replayed.v2RouteHandoff, replacement)
        XCTAssertEqual(
            replayed.routes.values.filter {
                $0.lifecycle == .planned
                    && $0.routeID != fixture.candidateRouteID
                    && $0.routeID != fixture.routeID
            }.map(\.routeID),
            [replacement.toRouteID]
        )
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

        lock.pauseNextAcquisition()
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

    init(
        owner: UUID,
        lock: any DeviceEpochStoreLocking = CallbackFixture.defaultLock,
        fileIO: any DeviceEpochFileIO = SystemDeviceEpochFileIO()
    ) {
        self.owner = owner
        start = Date(timeIntervalSince1970: 1_784_937_600)
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earned-metering-callback-\(UUID().uuidString).json")
        store = DeviceEpochStore(
            fileURL: storeURL,
            lock: lock,
            fileIO: fileIO,
            ownerProvider: { owner }
        )
    }

    private static let defaultLock = CallbackFixtureLock()

    static func active(
        usageDate: String = "2026-07-18",
        lock: any DeviceEpochStoreLocking = CallbackFixture.defaultLock,
        fileIO: any DeviceEpochFileIO = SystemDeviceEpochFileIO()
    ) throws -> CallbackFixture {
        let fixture = CallbackFixture(owner: UUID(), lock: lock, fileIO: fileIO)
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

    func addStoppedSupersededRoute(
        stoppedAt: Date,
        installTerminal: MeteringWorkTerminal = .superseded,
        registrationTerminal: MeteringWorkTerminal = .superseded
    ) throws -> (routeID: UUID, epochID: UUID, installID: UUID, registrationID: UUID) {
        let staleRouteID = UUID()
        let staleEpochID = UUID()
        let staleInstallID = UUID()
        let staleRegistrationID = UUID()
        try mutate { state in
            guard let generation = state.generations[generationID],
                  let activeEpoch = state.epochs[epochID]
            else { return }
            let staleEpoch = DeviceDailyEpoch(
                epochID: staleEpochID,
                protocolVersion: 2,
                childDeviceID: owner,
                usageDate: activeEpoch.usageDate,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                startedAt: stoppedAt.addingTimeInterval(-300),
                registeredAt: nil,
                baseAcceptedMinutes: activeEpoch.baseAcceptedMinutes,
                baseSource: .childState200,
                lastRawThresholdMinutes: 0,
                excludedWhilePausedMinutes: 0,
                status: .retired,
                resumeBoundaryPending: false,
                retiredAt: stoppedAt,
                retireReason: .activationSuperseded,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            let event = MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(
                    routeID: staleRouteID,
                    thresholdMinutes: 5
                ),
                thresholdMinutes: 5
            )
            let schedule = DatedSchedulePlan(
                usageDate: staleEpoch.usageDate,
                timezoneIdentifier: generation.canonicalTimezone,
                calendarIdentifier: "gregorian"
            )
            let staleRoute = MeteringCallbackRoute(
                routeID: staleRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: staleRouteID),
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
                usageDate: staleEpoch.usageDate,
                epochID: staleEpochID,
                plannedSchedule: schedule,
                installedSchedule: schedule,
                plannedEvents: [event],
                installedEvents: [event],
                lifecycle: .tombstoned,
                createdAt: stoppedAt.addingTimeInterval(-300)
            )
            let retry = MeteringRetryState(
                attemptCount: 1,
                nextAttemptAt: stoppedAt,
                lastErrorCode: "activation_superseded",
                terminal: .superseded
            )
            state.epochs[staleEpochID] = staleEpoch
            state.routes[staleRouteID] = staleRoute
            state.tombstones[staleRouteID] = MeteringRouteTombstone(
                routeID: staleRouteID,
                activityName: staleRoute.activityName,
                eventNames: [event.eventName],
                ownerChildDeviceID: owner,
                usageDate: staleEpoch.usageDate,
                epochID: staleEpochID,
                generationID: generationID,
                canonicalDayEnd: stoppedAt.addingTimeInterval(86_400),
                stopAcknowledgedAt: stoppedAt,
                referencedWorkIDs: [staleInstallID, staleRegistrationID],
                retainedUntil: stoppedAt.addingTimeInterval(86_400)
            )
            state.installWork[staleInstallID] = ActivityInstallWork(
                workID: staleInstallID,
                ownerChildDeviceID: owner,
                routeID: staleRouteID,
                authorization: .offlinePending,
                phase: .stopped,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: retry.attemptCount,
                    nextAttemptAt: retry.nextAttemptAt,
                    lastErrorCode: retry.lastErrorCode,
                    terminal: installTerminal
                ),
                createdAt: staleRoute.createdAt
            )
            state.registrationWork[staleRegistrationID] = EpochRegistrationWork(
                workID: staleRegistrationID,
                ownerChildDeviceID: owner,
                epochID: staleEpochID,
                routeID: staleRouteID,
                request: EpochRegistrationRequestDTO(
                    protocolVersion: 2,
                    epochID: staleEpochID,
                    deviceID: owner,
                    usageDate: staleEpoch.usageDate,
                    timezone: staleEpoch.canonicalTimezone,
                    policyRevision: staleEpoch.policyRevision,
                    measurementSelectionDigest: staleEpoch.measurementSelectionDigest,
                    enforcementSetID: staleEpoch.enforcementSetID,
                    startedAt: staleEpoch.startedAt,
                    baseAcceptedMinutes: staleEpoch.baseAcceptedMinutes,
                    reason: .identityRecovery
                ),
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: retry.attemptCount,
                    nextAttemptAt: retry.nextAttemptAt,
                    lastErrorCode: retry.lastErrorCode,
                    terminal: registrationTerminal
                ),
                createdAt: staleRoute.createdAt
            )
        }
        return (staleRouteID, staleEpochID, staleInstallID, staleRegistrationID)
    }

    /// Simulates a mid-flight policy replacement: retires the original
    /// generation/epoch/route and activates a fresh successor in a NEW generation
    /// (same day / owner / selection-digest / enforcement-set). The successor's
    /// base carries the original's ALREADY-ACCEPTED minutes but NOT any in-flight
    /// threshold — modelling a late callback whose minutes never reached the
    /// successor. Returns the successor epoch id.
    @discardableResult
    func retireOriginalAndActivateSuccessor(retiredAt: Date) throws -> UUID {
        let successorGen = UUID()
        let successorEpoch = UUID()
        let successorRoute = UUID()
        let successorInstall = UUID()
        try mutate { state in
            guard let oldGen = state.generations[generationID],
                  let oldEpoch = state.epochs[epochID] else { return }
            state.generations[generationID]?.retiredAt = retiredAt
            state.epochs[epochID]?.status = .retired
            state.epochs[epochID]?.retiredAt = retiredAt
            state.epochs[epochID]?.retireReason = .policyChange
            state.routes[routeID]?.lifecycle = .retired

            let gen = MeteringPolicyGeneration(
                generationID: successorGen,
                protocolVersion: 2,
                childDeviceID: owner,
                canonicalTimezone: oldGen.canonicalTimezone,
                policyRevision: "policy-2",
                measurementSelectionDigest: oldGen.measurementSelectionDigest,
                enforcementSetID: oldGen.enforcementSetID,
                measurementSelectionBytes: oldGen.measurementSelectionBytes,
                createdAt: retiredAt,
                retiredAt: nil
            )
            let epoch = DeviceDailyEpoch(
                epochID: successorEpoch,
                protocolVersion: 2,
                childDeviceID: owner,
                usageDate: oldEpoch.usageDate,
                canonicalTimezone: gen.canonicalTimezone,
                policyRevision: gen.policyRevision,
                measurementSelectionDigest: gen.measurementSelectionDigest,
                enforcementSetID: gen.enforcementSetID,
                startedAt: retiredAt,
                registeredAt: retiredAt,
                baseAcceptedMinutes: oldEpoch.baseAcceptedMinutes,
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
            let schedule = DatedSchedulePlan(
                usageDate: epoch.usageDate,
                timezoneIdentifier: gen.canonicalTimezone,
                calendarIdentifier: "gregorian"
            )
            let event = MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(routeID: successorRoute, thresholdMinutes: 5),
                thresholdMinutes: 5
            )
            state.generations[successorGen] = gen
            state.epochs[successorEpoch] = epoch
            state.routes[successorRoute] = MeteringCallbackRoute(
                routeID: successorRoute,
                activityName: MeteringRouteNamespace.activityName(routeID: successorRoute),
                namespace: MeteringRouteNamespace.prefix,
                generationID: successorGen,
                generationKey: MeteringGenerationKey(
                    protocolVersion: 2,
                    childDeviceID: owner,
                    canonicalTimezone: gen.canonicalTimezone,
                    policyRevision: gen.policyRevision,
                    measurementSelectionDigest: gen.measurementSelectionDigest,
                    enforcementSetID: gen.enforcementSetID
                ),
                ownerChildDeviceID: owner,
                usageDate: epoch.usageDate,
                epochID: successorEpoch,
                plannedSchedule: schedule,
                installedSchedule: schedule,
                plannedEvents: [event],
                installedEvents: [event],
                lifecycle: .active,
                createdAt: retiredAt
            )
            state.installWork[successorInstall] = ActivityInstallWork(
                workID: successorInstall,
                ownerChildDeviceID: owner,
                routeID: successorRoute,
                authorization: .registered,
                phase: .active,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: retiredAt,
                    lastErrorCode: nil,
                    terminal: .succeeded
                ),
                createdAt: retiredAt
            )
            state.activeGenerationID = successorGen
            state.activeEpochID = successorEpoch
            state.activeRouteID = successorRoute
        }
        return successorEpoch
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
        namespace: String? = nil,
        observedAt: Date? = nil
    ) -> MeteringAuthorizedCallbackInput {
        let observedAt = observedAt ?? start.addingTimeInterval(5 * 60)
        return MeteringAuthorizedCallbackInput(
            routeID: routeID,
            activityName: activityName ?? MeteringRouteNamespace.activityName(routeID: routeID),
            eventName: eventName ?? MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
            namespace: namespace ?? MeteringRouteNamespace.prefix,
            thresholdMinutes: 5,
            observedAt: observedAt,
            now: observedAt,
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

private final class CountingCallbackFileIO: DeviceEpochFileIO, @unchecked Sendable {
    private let backing = SystemDeviceEpochFileIO()
    private(set) var readCount = 0
    private(set) var writeCount = 0

    func resetCounts() {
        readCount = 0
        writeCount = 0
    }

    func resetReadCount() {
        resetCounts()
    }

    func read(from url: URL) throws -> Data? {
        readCount += 1
        return try backing.read(from: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        writeCount += 1
        try backing.writeAtomically(data, to: url)
    }

    func remove(at url: URL) throws {
        try backing.remove(at: url)
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
