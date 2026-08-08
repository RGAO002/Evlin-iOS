import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringAuthoritativeBaseCorrectionTests: XCTestCase {
    private let owner = UUID(uuidString: "C0123456-789A-4BCD-8EFA-0123456789AB")!
    // 2026-07-18T16:00:00Z = 12:00 in America/New_York, i.e. INSIDE the
    // candidate's own usage date. It used to be 2026-07-25, a week after the
    // routes these fixtures build, which was harmless until the elapsed-day
    // sweep landed: a candidate whose day ended a week ago can never cut over,
    // so recovery correctly reclaimed the handoff and every repair assertion
    // below lost its subject.
    private let start = Date(timeIntervalSince1970: 1_784_390_400)
    private let baseURL = URL(string: "https://example.invalid/api/v1")!

    func testInitialV1ToV2RegistrationBaseMismatchMintsCorrectedBootstrapCandidate() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start, initialBootstrap: true)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 40)]

        await fixture.delivery.drain(owner: owner)

        let state = try fixture.store.read()
        let corrected = try XCTUnwrap(state.epochs.values.first {
            $0.epochID != fixture.rejectedEpochID && $0.baseAcceptedMinutes == 40
        })
        let correctedRoute = try XCTUnwrap(state.routes.values.first { $0.epochID == corrected.epochID })
        XCTAssertEqual(state.generations.count, 2)
        XCTAssertEqual(state.epochs[fixture.rejectedEpochID]?.status, .retired)
        XCTAssertEqual(
            state.epochs[fixture.rejectedEpochID]?.retireReason,
            .authoritativeBaseMismatch
        )
        XCTAssertEqual(corrected.baseSource, .registrationConflict409)
        XCTAssertEqual(corrected.baseCorrectionState, .used)
        XCTAssertEqual(state.activeGenerationID, correctedRoute.generationID)
        XCTAssertEqual(state.activeEpochID, corrected.epochID)
        XCTAssertNil(state.activeRouteID)
        XCTAssertNil(state.v2RouteHandoff)
        XCTAssertTrue(state.ratchets.isEmpty)
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.epochID == corrected.epochID && $0.routeID == correctedRoute.routeID
            }?.retry.terminal,
            .pending
        )
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.epochID == corrected.epochID && $0.routeID == correctedRoute.routeID
            }?.request.reason,
            .initial
        )
        XCTAssertEqual(
            state.installWork.values.first { $0.routeID == correctedRoute.routeID }?.authorization,
            .registrationRequired
        )
    }

    func testColdReopenRecoversPersistedInitialBaseMismatch() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start, initialBootstrap: true)
        defer { fixture.cleanup() }
        try fixture.seedPersistedInitialConflict(estimatedMinutes: 40)

        try await fixture.driver(at: start.addingTimeInterval(1)).recover(ownerChildDeviceID: owner)

        let state = try fixture.reopenedStore().read()
        let corrected = try XCTUnwrap(state.epochs.values.first {
            $0.epochID != fixture.rejectedEpochID && $0.baseAcceptedMinutes == 40
        })
        XCTAssertEqual(state.activeEpochID, corrected.epochID)
        XCTAssertEqual(corrected.baseSource, .registrationConflict409)
        XCTAssertNil(
            state.epochs[fixture.rejectedEpochID],
            "cold recovery should collect the physically absent rejected candidate"
        )
        XCTAssertNil(state.routes[fixture.rejectedRouteID])
        XCTAssertTrue(state.registrationWork.values.contains {
            $0.epochID == corrected.epochID && $0.retry.terminal == .pending
        })
    }

    func testColdReopenRepairsLegacyRetiredPriorCorrectionDeadEnd() async throws {
        let fixture = try CorrectionFixture(
            owner: owner,
            start: start,
            sameGenerationCandidate: true
        )
        defer { fixture.cleanup() }
        try fixture.replaceDirectly(estimatedMinutes: 37)
        try fixture.seedLegacyRetiredPriorCorrectionDeadEnd()
        fixture.transport.results = [
            fixture.registrationResponse(),
            fixture.activationResponse(),
        ]

        try await fixture.driver(at: start.addingTimeInterval(1))
            .recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let correctedRouteID = try XCTUnwrap(state.v2RouteHandoff?.toRouteID)
        XCTAssertEqual(state.activeRouteID, correctedRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.routeID == correctedRouteID
            }?.retry.terminal,
            .succeeded
        )
        XCTAssertEqual(
            state.activationWork.values.first {
                $0.routeID == correctedRouteID
            }?.retry.terminal,
            .succeeded
        )
    }

    func testColdReopenRepairsLegacySameKeyCorrectionReasonMismatch() async throws {
        let fixture = try CorrectionFixture(
            owner: owner,
            start: start,
            sameGenerationCandidate: true
        )
        defer { fixture.cleanup() }
        try fixture.replaceDirectly(estimatedMinutes: 37)
        try fixture.openCorrectedCandidateForRegistration()
        try fixture.poisonCutoverCorrectionWithLegacyReason()
        fixture.transport.results = [
            fixture.registrationResponse(),
            fixture.activationResponse(),
        ]

        try await fixture.driver(at: start.addingTimeInterval(1))
            .recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(handoff.phase, .committed)
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(state.activeRouteID, handoff.toRouteID)
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.routeID == handoff.toRouteID
            }?.retry.terminal,
            .succeeded
        )
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.routeID == handoff.toRouteID
            }?.request.reason,
            .identityRecovery
        )
        XCTAssertEqual(
            state.activationWork.values.first {
                $0.routeID == handoff.toRouteID
            }?.retry.terminal,
            .succeeded
        )
        XCTAssertEqual(
            state.routes.values.filter {
                $0.ownerChildDeviceID == owner && $0.lifecycle == .active
            }.count,
            1,
            "cold recovery must reuse the persisted corrected route, not mint another candidate"
        )
    }

    func testColdReopenRetriesLegacyInitialCorrectionWithInitialReason() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start, initialBootstrap: true)
        defer { fixture.cleanup() }
        try fixture.replaceDirectly(estimatedMinutes: 40)
        try fixture.poisonInitialCorrectionWithLegacyReason()
        fixture.transport.errors = [.notConnectedToInternet]

        try await fixture.driver(at: start.addingTimeInterval(1)).recover(ownerChildDeviceID: owner)

        XCTAssertEqual(fixture.transport.requests.count, 1)
        let body = try XCTUnwrap(fixture.transport.requests.first?.httpBody)
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(request["reason"] as? String, EpochRegistrationReasonDTO.initial.rawValue)
        let state = try fixture.reopenedStore().read()
        let correctedEpochID = try XCTUnwrap(state.activeEpochID)
        XCTAssertTrue(state.registrationWork.values.contains {
            $0.epochID == correctedEpochID
                && $0.request.reason == .initial
                && $0.retry.terminal == .pending
        })
    }

    func testAuthoritativeBaseMismatchAtomicallyReplacesOnlyRejectedCandidate() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]

        await fixture.delivery.drain(owner: owner)

        let state = try fixture.store.read()
        let replacement = try XCTUnwrap(state.v2RouteHandoff)
        let rejectedEpoch = try XCTUnwrap(state.epochs[fixture.rejectedEpochID])
        let rejectedRegistration = try XCTUnwrap(state.registrationWork[fixture.rejectedRegistrationID])
        let correctedEpoch = try XCTUnwrap(state.epochs[replacement.toEpochID])
        let correctedRoute = try XCTUnwrap(state.routes[replacement.toRouteID])

        XCTAssertEqual(replacement.fromGenerationID, fixture.priorGenerationID)
        XCTAssertEqual(replacement.fromEpochID, fixture.priorEpochID)
        XCTAssertEqual(replacement.fromRouteID, fixture.priorRouteID)
        XCTAssertEqual(replacement.phase, .preparing)
        XCTAssertEqual(
            replacement.consumedCandidateReplacementCount ?? 0,
            0,
            "a backend base correction must not spend the physical-event recovery budget"
        )
        XCTAssertNotEqual(replacement.toGenerationID, fixture.rejectedGenerationID)
        XCTAssertNotEqual(replacement.toEpochID, fixture.rejectedEpochID)
        XCTAssertNotEqual(replacement.toRouteID, fixture.rejectedRouteID)
        XCTAssertEqual(correctedEpoch.baseAcceptedMinutes, 37)
        XCTAssertEqual(correctedEpoch.baseSource, .registrationConflict409)
        XCTAssertEqual(correctedEpoch.baseCorrectionState, .used)
        XCTAssertEqual(correctedRoute.generationKey, fixture.rejectedGenerationKey)
        XCTAssertEqual(state.routes[fixture.rejectedRouteID]?.lifecycle, .tombstoned)
        let rejectedTombstone = try XCTUnwrap(state.tombstones[fixture.rejectedRouteID])
        XCTAssertEqual(
            rejectedTombstone.canonicalDayEnd,
            ISO8601DateFormatter().date(from: "2026-07-19T04:00:00Z")
        )
        XCTAssertEqual(rejectedEpoch.status, .retired)
        XCTAssertEqual(rejectedEpoch.retireReason, .authoritativeBaseMismatch)
        XCTAssertEqual(rejectedEpoch.baseCorrectionState, .used)
        XCTAssertEqual(rejectedRegistration.retry.terminal, .superseded)
        XCTAssertEqual(rejectedRegistration.retry.lastErrorCode, "authoritative_base_mismatch")
        XCTAssertEqual(state.activeGenerationID, fixture.priorGenerationID)
        XCTAssertEqual(state.activeEpochID, fixture.priorEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .active)
        XCTAssertEqual(state.installWork.values.filter { $0.routeID == correctedRoute.routeID }.count, 1)
        XCTAssertEqual(state.installWork.values.first { $0.routeID == correctedRoute.routeID }?.authorization, .offlinePending)
        XCTAssertEqual(state.registrationWork.values.filter { $0.routeID == correctedRoute.routeID }.count, 1)
        XCTAssertEqual(state.registrationWork.values.first {
            $0.epochID == correctedEpoch.epochID && $0.routeID == correctedRoute.routeID
        }?.request.baseAcceptedMinutes, 37)
        XCTAssertNotEqual(correctedEpoch.baseAcceptedMinutes, 91)
        XCTAssertNotEqual(correctedEpoch.baseAcceptedMinutes, 3)
        XCTAssertNotEqual(correctedEpoch.baseAcceptedMinutes, 120)
    }

    func testAuthoritativeBaseMismatchPersistenceFailureIsRecorded() async throws {
        let lock = CorrectionToggleLock()
        let fixture = try CorrectionFixture(owner: owner, start: start, lock: lock)
        defer { fixture.cleanup() }
        var events: [ScreenTimeEvent] = []
        MeteringFlightRecorder.testSink = { events.append($0) }
        defer { MeteringFlightRecorder.testSink = nil }
        fixture.transport.onRequest = { lock.setAvailable(false) }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]

        await fixture.delivery.drain(owner: owner)

        let failure = try XCTUnwrap(events.first { event in
            event.kind == .meteringError
                && event.app?.hasPrefix("delivery.baseCorrection") == true
        })
        XCTAssertEqual(failure.reason, "error")
        XCTAssertEqual(failure.corrID, fixture.rejectedRegistrationID.uuidString)
        XCTAssertTrue(failure.app?.contains("lockUnavailable") == true)
    }

    func testSameGenerationBaseMismatchKeepsPriorRouteAuthoritativeForCorrection() async throws {
        let fixture = try CorrectionFixture(
            owner: owner,
            start: start,
            sameGenerationCandidate: true
        )
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]

        await fixture.delivery.drain(owner: owner)

        let state = try fixture.store.read()
        let replacement = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertNil(
            state.generations[fixture.priorGenerationID]?.retiredAt,
            "rejecting a same-generation candidate must not retire the generation that still owns the active prior route"
        )
        XCTAssertEqual(state.activeGenerationID, fixture.priorGenerationID)
        XCTAssertEqual(state.activeEpochID, fixture.priorEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertTrue(
            state.hasCurrentRegistrationProvenance(
                owner: owner,
                epochID: replacement.toEpochID,
                routeID: replacement.toRouteID
            ),
            "the corrected candidate must remain deliverable through the still-live prior-route handoff"
        )
        XCTAssertEqual(
            state.registrationWork.values.first {
                $0.epochID == replacement.toEpochID && $0.routeID == replacement.toRouteID
            }?.retry.terminal,
            .pending
        )
    }

    func testSecondAuthoritativeBaseMismatchRetiresOnlyCorrectedCandidate() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]
        await fixture.delivery.drain(owner: owner)
        try fixture.openCorrectedCandidateForRegistration()
        let before = try fixture.store.read()
        let correctedRouteID = try XCTUnwrap(before.v2RouteHandoff?.toRouteID)
        let correctedEpochID = try XCTUnwrap(before.v2RouteHandoff?.toEpochID)
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 41)]

        await fixture.delivery.drain(owner: owner)

        let final = try fixture.store.read()
        XCTAssertNil(final.v2RouteHandoff)
        XCTAssertEqual(final.generations.count, 3)
        XCTAssertEqual(final.epochs.count, 3)
        XCTAssertEqual(final.routes.count, 3)
        XCTAssertEqual(final.epochs[correctedEpochID]?.status, .retired)
        XCTAssertEqual(final.epochs[correctedEpochID]?.retireReason, .authoritativeBaseMismatch)
        XCTAssertEqual(final.routes[correctedRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(final.activeGenerationID, fixture.priorGenerationID)
        XCTAssertEqual(final.activeEpochID, fixture.priorEpochID)
        XCTAssertEqual(final.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(final.installWork[fixture.priorInstallID]?.phase, .active)
        XCTAssertFalse(final.registrationWork.values.contains {
            $0.routeID == correctedRouteID && $0.retry.terminal == .pending
        })
    }

    func testPriorAndCorrectedCallbacksUseCumulativeMaximumNotSum() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]
        await fixture.delivery.drain(owner: owner)
        try fixture.openCorrectedCandidateForDualV2Callbacks()

        let handler = EarnedMeteringCallback(
            store: fixture.store,
            clock: CorrectionClock(now: start.addingTimeInterval(5 * 60))
        )
        guard case .queued = try handler.handle(
            fixture.callback(routeID: fixture.priorRouteID, threshold: 5),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("prior route must remain countable during dualV2") }
        guard case .queued = try handler.handle(
            fixture.correctedCallback(threshold: 5),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("corrected route must be countable during dualV2") }

        let estimates = try fixture.store.read().sampleWork.values.map(\.request.estimatedMinutes).sorted()
        XCTAssertEqual(estimates, [5, 42])
        XCTAssertEqual(estimates.max(), 42)
        XCTAssertFalse(estimates.contains(47))
    }

    func testLostRegistrationAndActivationResponsesRecoverSameCorrection() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]
        await fixture.delivery.drain(owner: owner)
        try fixture.markCorrectedInstallVerified()
        fixture.transport.errors = [.notConnectedToInternet]

        try await fixture.driver(at: start).recover(ownerChildDeviceID: owner)
        let afterLostRegistration = try fixture.store.read()
        let correctedRouteID = try XCTUnwrap(afterLostRegistration.v2RouteHandoff?.toRouteID)
        let correctedEpochID = try XCTUnwrap(afterLostRegistration.v2RouteHandoff?.toEpochID)
        XCTAssertEqual(afterLostRegistration.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertEqual(afterLostRegistration.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(afterLostRegistration.registrationWork.values.first {
            $0.routeID == correctedRouteID
        }?.retry.terminal, .pending)

        fixture.transport.results = [fixture.registrationResponse(), fixture.activationResponse()]
        try await fixture.driver(at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        let final = try fixture.store.read()
        XCTAssertEqual(final.activeRouteID, correctedRouteID)
        XCTAssertEqual(final.activeEpochID, correctedEpochID)
        XCTAssertEqual(final.v2RouteHandoff?.phase, .committed)
        XCTAssertNotNil(final.epochs[fixture.priorEpochID])
        XCTAssertNotNil(final.routes[fixture.priorRouteID])
        XCTAssertNotNil(final.epochs[correctedEpochID])
        XCTAssertNotNil(final.routes[correctedRouteID])
        XCTAssertNil(final.epochs[fixture.rejectedEpochID])
        XCTAssertNil(final.routes[fixture.rejectedRouteID])
        XCTAssertEqual(final.registrationWork.values.filter { $0.routeID == correctedRouteID }.count, 1)
        XCTAssertEqual(final.activationWork.values.filter { $0.routeID == correctedRouteID }.count, 1)
    }

    func testAlreadyRegisteredReplayPersistsRegistrationAndExactActivationAtomically() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]
        await fixture.delivery.drain(owner: owner)
        try fixture.openCorrectedCandidateForRegistration()
        let ids = try fixture.correctedIDs()
        fixture.transport.results = [fixture.registrationResponse(status: .alreadyRegistered)]

        await fixture.delivery.drain(owner: owner)

        let state = try fixture.store.read()
        let registrations = state.registrationWork.values.filter {
            $0.epochID == ids.epochID && $0.routeID == ids.routeID
        }
        let activations = state.activationWork.values.filter {
            $0.epochID == ids.epochID && $0.routeID == ids.routeID
        }
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(registrations.first?.retry.terminal, .succeeded)
        XCTAssertNotNil(state.epochs[ids.epochID]?.registeredAt)
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?.retry.terminal, .pending)
        XCTAssertEqual(activations.first?.retry.lastErrorCode, "network_error")
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
    }

    func testLostActivationResponseReopensAndRetriesSameActivationWork() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]
        await fixture.delivery.drain(owner: owner)
        try fixture.openCorrectedCandidateForRegistration()
        let ids = try fixture.correctedIDs()
        fixture.transport.results = [fixture.registrationResponse(status: .alreadyRegistered)]
        await fixture.delivery.drain(owner: owner)

        var state = try fixture.store.read()
        let activationID = try XCTUnwrap(state.activationWork.first(where: {
            $0.value.epochID == ids.epochID && $0.value.routeID == ids.routeID
        })?.key)
        let retryAt = try XCTUnwrap(state.activationWork[activationID]?.retry.nextAttemptAt)
        XCTAssertEqual(state.activationWork[activationID]?.retry.terminal, .pending)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)

        fixture.transport.results = [fixture.activationResponse(status: .alreadyActivated)]
        let reopened = fixture.reopenedStore()
        try await fixture.driver(at: retryAt, store: reopened).recover(ownerChildDeviceID: owner)

        state = try reopened.read()
        XCTAssertEqual(state.activationWork[activationID]?.retry.terminal, .succeeded)
        XCTAssertEqual(state.activationWork.values.filter {
            $0.epochID == ids.epochID && $0.routeID == ids.routeID
        }.count, 1)
        XCTAssertEqual(state.activeGenerationID, ids.generationID)
        XCTAssertEqual(state.activeEpochID, ids.epochID)
        XCTAssertEqual(state.activeRouteID, ids.routeID)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
    }

    func testEveryCorrectionBoundaryReopensWithStableIDsAndConverges() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]
        await fixture.delivery.drain(owner: owner)
        let ids = try fixture.correctedIDs()

        func reopenAndAssertPriorContinuity(_ label: String) throws -> DeviceEpochStore {
            let reopened = fixture.reopenedStore()
            let state = try reopened.read()
            XCTAssertEqual(state.v2RouteHandoff?.toGenerationID, ids.generationID, label)
            XCTAssertEqual(state.v2RouteHandoff?.toEpochID, ids.epochID, label)
            XCTAssertEqual(state.v2RouteHandoff?.toRouteID, ids.routeID, label)
            XCTAssertNotNil(state.generations[fixture.priorGenerationID], label)
            XCTAssertNotNil(state.epochs[fixture.priorEpochID], label)
            XCTAssertNotNil(state.routes[fixture.priorRouteID], label)
            XCTAssertNotNil(state.generations[ids.generationID], label)
            XCTAssertNotNil(state.epochs[ids.epochID], label)
            XCTAssertNotNil(state.routes[ids.routeID], label)
            if let rejectedRoute = state.routes[fixture.rejectedRouteID] {
                XCTAssertEqual(rejectedRoute.lifecycle, .tombstoned, label)
                XCTAssertEqual(
                    state.epochs[fixture.rejectedEpochID]?.status,
                    .retired,
                    label
                )
                XCTAssertNotNil(
                    state.generations[fixture.rejectedGenerationID]?.retiredAt,
                    label
                )
            } else {
                XCTAssertNil(state.epochs[fixture.rejectedEpochID], label)
                XCTAssertNil(state.generations[fixture.rejectedGenerationID], label)
            }
            XCTAssertEqual(state.activeGenerationID, fixture.priorGenerationID, label)
            XCTAssertEqual(state.activeEpochID, fixture.priorEpochID, label)
            XCTAssertEqual(state.activeRouteID, fixture.priorRouteID, label)
            XCTAssertEqual(state.routes[fixture.priorRouteID]?.lifecycle, .active, label)
            XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .active, label)
            return reopened
        }

        var reopened = try reopenAndAssertPriorContinuity("corrected candidate created")
        let installID = try XCTUnwrap(try reopened.read().installWork.first(where: {
            $0.value.routeID == ids.routeID
        })?.key)
        let process = MeteringProcessIdentity(role: .app, instanceID: UUID())
        let claimed = try XCTUnwrap(try reopened.claimInstallWork(
            workID: installID,
            owner: owner,
            processIdentity: process,
            now: start.addingTimeInterval(1)
        ))

        reopened = try reopenAndAssertPriorContinuity("install claimed")
        try fixture.startMonitor(routeID: ids.routeID, store: reopened)
        reopened = try reopenAndAssertPriorContinuity("Apple start returned")
        XCTAssertTrue(try reopened.recordInstalledRoute(
            workID: installID,
            token: claimed.claim.token,
            owner: owner,
            now: start.addingTimeInterval(2)
        ))
        reopened = try reopenAndAssertPriorContinuity("installed metadata committed")
        XCTAssertTrue(try reopened.recordVerifiedRoute(
            workID: installID,
            token: claimed.claim.token,
            owner: owner,
            now: start.addingTimeInterval(3)
        ))
        reopened = try reopenAndAssertPriorContinuity("daemon verification committed")

        try fixture.openCorrectedCandidateForDualV2Callbacks()
        reopened = try reopenAndAssertPriorContinuity("dualV2 committed")
        XCTAssertEqual(try reopened.read().v2RouteHandoff?.phase, .dualV2)

        let callback = EarnedMeteringCallback(
            store: reopened,
            clock: CorrectionClock(now: start.addingTimeInterval(5 * 60))
        )
        guard case let .queued(priorSampleID) = try callback.handle(
            fixture.callback(routeID: fixture.priorRouteID, threshold: 5),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("prior callback must queue before the barrier") }
        try reopened.transaction(expectedOwner: owner) { state in
            state.sampleWork[priorSampleID]?.retry.nextAttemptAt = start.addingTimeInterval(3_600)
        }
        reopened = try reopenAndAssertPriorContinuity("prior work queued")

        try reopened.transaction(expectedOwner: owner) { state in
            state.sampleWork[priorSampleID]?.retry.terminal = .succeeded
            state.sampleWork[priorSampleID]?.retry.lastErrorCode = nil
            for (key, work) in state.registrationWork where
                work.epochID == ids.epochID && work.routeID == ids.routeID {
                state.registrationWork[key]?.retry.nextAttemptAt = start.addingTimeInterval(301)
            }
        }
        reopened = try reopenAndAssertPriorContinuity("prior work settled")

        fixture.transport.errors = [.notConnectedToInternet]
        try await fixture.driver(at: start.addingTimeInterval(301), store: reopened)
            .recover(ownerChildDeviceID: owner)
        reopened = try reopenAndAssertPriorContinuity("registration response lost")
        var state = try reopened.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        let registrationID = try XCTUnwrap(state.registrationWork.first(where: {
            $0.value.epochID == ids.epochID && $0.value.routeID == ids.routeID
        })?.key)
        XCTAssertEqual(state.registrationWork[registrationID]?.retry.terminal, .pending)

        let registrationRetryAt = try XCTUnwrap(state.registrationWork[registrationID]?.retry.nextAttemptAt)
        fixture.transport.results = [fixture.registrationResponse(status: .alreadyRegistered, store: reopened)]
        await fixture.delivery(at: registrationRetryAt, store: reopened).drain(owner: owner)
        reopened = try reopenAndAssertPriorContinuity("registration replay settled")
        state = try reopened.read()
        XCTAssertEqual(state.registrationWork[registrationID]?.retry.terminal, .succeeded)
        XCTAssertNotNil(state.epochs[ids.epochID]?.registeredAt)
        let activationID = try XCTUnwrap(state.activationWork.first(where: {
            $0.value.epochID == ids.epochID && $0.value.routeID == ids.routeID
        })?.key)
        XCTAssertEqual(state.activationWork[activationID]?.retry.terminal, .pending)

        let activationRetryAt = try XCTUnwrap(state.activationWork[activationID]?.retry.nextAttemptAt)
        fixture.transport.results = [fixture.activationResponse(status: .alreadyActivated, store: reopened)]
        await fixture.delivery(at: activationRetryAt, store: reopened).drain(owner: owner)
        reopened = try reopenAndAssertPriorContinuity("activation replay settled")
        XCTAssertEqual(try reopened.read().activationWork[activationID]?.retry.terminal, .succeeded)

        fixture.center.preventStops = true
        try await fixture.driver(at: activationRetryAt.addingTimeInterval(1), store: reopened)
            .recover(ownerChildDeviceID: owner)
        reopened = fixture.reopenedStore()
        state = try reopened.read()
        XCTAssertEqual(state.activeGenerationID, ids.generationID)
        XCTAssertEqual(state.activeEpochID, ids.epochID)
        XCTAssertEqual(state.activeRouteID, ids.routeID)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .committed)
        XCTAssertEqual(state.routes[fixture.priorRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(
            state.tombstones[fixture.priorRouteID]?.canonicalDayEnd,
            ISO8601DateFormatter().date(from: "2026-07-19T04:00:00Z")
        )
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .pendingStop)
        XCTAssertNil(state.v2RouteHandoff?.priorStopAcknowledgedAt)

        fixture.center.preventStops = false
        fixture.center.stopMonitoring([DeviceActivityName(try XCTUnwrap(state.routes[fixture.priorRouteID]?.activityName))])
        reopened = fixture.reopenedStore()
        XCTAssertEqual(try reopened.read().installWork[fixture.priorInstallID]?.phase, .pendingStop)
        try await fixture.driver(at: activationRetryAt.addingTimeInterval(2), store: reopened)
            .recover(ownerChildDeviceID: owner)

        state = try fixture.reopenedStore().read()
        XCTAssertEqual(state.activeGenerationID, ids.generationID)
        XCTAssertEqual(state.activeEpochID, ids.epochID)
        XCTAssertEqual(state.activeRouteID, ids.routeID)
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .stopped)
        XCTAssertNotNil(state.v2RouteHandoff?.priorStopAcknowledgedAt)
        XCTAssertNotNil(state.generations[fixture.priorGenerationID])
        XCTAssertNotNil(state.epochs[fixture.priorEpochID])
        XCTAssertNotNil(state.routes[fixture.priorRouteID])
        XCTAssertNotNil(state.generations[ids.generationID])
        XCTAssertNotNil(state.epochs[ids.epochID])
        XCTAssertNotNil(state.routes[ids.routeID])
        XCTAssertNil(state.generations[fixture.rejectedGenerationID])
        XCTAssertNil(state.epochs[fixture.rejectedEpochID])
        XCTAssertNil(state.routes[fixture.rejectedRouteID])

        let correctedCallback = EarnedMeteringCallback(
            store: reopened,
            clock: CorrectionClock(now: start.addingTimeInterval(10 * 60))
        )
        guard case let .queued(correctedSampleID) = try correctedCallback.handle(
            fixture.callback(routeID: ids.routeID, threshold: 5),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("locally active corrected route must remain countable") }
        XCTAssertEqual(try reopened.read().sampleWork[correctedSampleID]?.authorization, .v2Deliverable)
    }

    func testRejectedCandidateQueuedSampleAndLateCallbackHaveZeroEffects() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: CorrectionClock(now: start.addingTimeInterval(5 * 60))
        )
        guard case let .queued(sampleID) = try callback.handle(
            fixture.callback(routeID: fixture.rejectedRouteID, threshold: 5),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("candidate callback must queue while registration is pending") }
        fixture.transport.results = [fixture.authoritativeConflict(estimatedMinutes: 37)]

        await fixture.delivery.drain(owner: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork[sampleID]?.retry.terminal, .superseded)
        XCTAssertEqual(state.sampleWork[sampleID]?.retry.lastErrorCode, "authoritative_base_mismatch")
        let beforeLateCallback = try Data(contentsOf: fixture.storeURL)
        let late = try callback.handle(
            fixture.callback(routeID: fixture.rejectedRouteID, threshold: 5),
            expectedOwnerChildDeviceID: owner
        )
        XCTAssertEqual(late, .discarded(reason: "tombstoned_route"))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), beforeLateCallback)

        await fixture.delivery.drain(owner: owner)
        state = try fixture.store.read()
        XCTAssertEqual(fixture.transport.requests.count, 1)
        XCTAssertEqual(state.sampleWork[sampleID]?.retry.terminal, .superseded)
    }

    func testInFlightRejectedCandidateSampleResponseCannotMutateCorrection() async throws {
        let fixture = try CorrectionFixture(owner: owner, start: start)
        defer { fixture.cleanup() }
        let callback = EarnedMeteringCallback(
            store: fixture.store,
            clock: CorrectionClock(now: start.addingTimeInterval(5 * 60))
        )
        guard case let .queued(sampleID) = try callback.handle(
            fixture.callback(routeID: fixture.rejectedRouteID, threshold: 5),
            expectedOwnerChildDeviceID: owner
        ) else { return XCTFail("candidate callback must queue") }
        try fixture.store.transaction(expectedOwner: owner) { state in
            state.sampleWork[sampleID]?.authorization = .v2Deliverable
            state.sampleWork[sampleID]?.retry.nextAttemptAt = start
            state.registrationWork[fixture.rejectedRegistrationID]?.retry.nextAttemptAt = start.addingTimeInterval(600)
            for (key, var install) in state.installWork {
                switch install.phase {
                case .verified, .dualActive, .active:
                    install.retry.terminal = .succeeded
                    install.retry.lastErrorCode = nil
                    state.installWork[key] = install
                case .pendingStart, .starting, .installed, .pendingStop, .stopped:
                    break
                }
            }
            // A candidate the backend has not acknowledged may not dispatch
            // samples at all, so the in-flight race this test exists for is
            // unreachable until its activation has succeeded. Acknowledge it
            // here; the race being pinned is the correction arriving while
            // that sample is on the wire, not the activation ordering.
            for (key, var activation) in state.activationWork
            where activation.routeID == fixture.rejectedRouteID {
                activation.retry.terminal = .succeeded
                activation.retry.lastErrorCode = nil
                state.activationWork[key] = activation
            }
        }
        let requestStarted = expectation(description: "rejected candidate sample dispatched")
        let suspended = CorrectionSuspendingTransport(
            response: fixture.sampleAcceptedResponse(estimatedMinutes: 99),
            onRequest: { requestStarted.fulfill() }
        )
        let delivery = MeteringEpochDelivery(
            baseURL: baseURL,
            store: fixture.store,
            transport: suspended,
            clock: CorrectionClock(now: start),
            legacySuiteName: "base-correction-suspended-\(UUID().uuidString)"
        )
        let expectedOwner = owner
        let drain = Task { await delivery.drain(owner: expectedOwner) }
        await fulfillment(of: [requestStarted], timeout: 1)

        let conflict = fixture.authoritativeConflictDTO(estimatedMinutes: 37)
        try fixture.store.transaction(expectedOwner: owner) { state in
            XCTAssertTrue(state.replaceAuthoritativeBaseMismatchCandidate(
                owner: owner,
                rejectedEpochID: fixture.rejectedEpochID,
                rejectedRouteID: fixture.rejectedRouteID,
                conflict: conflict,
                now: start
            ))
        }
        let correctedIDs = try fixture.correctedIDs()
        await suspended.resume()
        await drain.value

        let state = try fixture.store.read()
        XCTAssertEqual(state.sampleWork[sampleID]?.retry.terminal, .superseded)
        XCTAssertEqual(state.sampleWork[sampleID]?.retry.lastErrorCode, "authoritative_base_mismatch")
        XCTAssertEqual(state.v2RouteHandoff?.toGenerationID, correctedIDs.generationID)
        XCTAssertEqual(state.v2RouteHandoff?.toEpochID, correctedIDs.epochID)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, correctedIDs.routeID)
        XCTAssertEqual(state.epochs[correctedIDs.epochID]?.baseAcceptedMinutes, 37)
        XCTAssertEqual(suspended.requestCount, 1)
    }

    func testPriorCallbackLosingCorrectionBarrierIsDiscarded() throws {
        let lock = CorrectionRaceLock()
        let fixture = try CorrectionFixture(owner: owner, start: start, lock: lock)
        defer { fixture.cleanup() }
        try fixture.replaceDirectly(estimatedMinutes: 37)
        try fixture.openCorrectedCandidateForDualV2Callbacks()
        let ids = try fixture.correctedIDs()
        let barrierFinished = expectation(description: "correction barrier committed")
        let callbackFinished = expectation(description: "prior callback returned")
        let outcome = CorrectionOutcomeBox()
        let callbackHandler = EarnedMeteringCallback(
            store: fixture.store,
            clock: CorrectionClock(now: fixture.start.addingTimeInterval(5 * 60))
        )
        let priorCallback = fixture.callback(routeID: fixture.priorRouteID, threshold: 5)

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
            outcome.value = try? callbackHandler.handle(
                priorCallback,
                expectedOwnerChildDeviceID: fixture.owner
            )
            callbackFinished.fulfill()
        }
        lock.resume()
        wait(for: [barrierFinished, callbackFinished], timeout: 2)

        XCTAssertEqual(outcome.value, .discarded(reason: "handoff_prior_input_closed"))
        let state = try fixture.store.read()
        XCTAssertTrue(state.sampleWork.isEmpty)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, ids.routeID)
    }

    func testPriorCallbackWinningCorrectionBarrierQueuesAndDefersBarrier() throws {
        let lock = CorrectionRaceLock()
        let fixture = try CorrectionFixture(owner: owner, start: start, lock: lock)
        defer { fixture.cleanup() }
        try fixture.replaceDirectly(estimatedMinutes: 37)
        try fixture.openCorrectedCandidateForDualV2Callbacks()
        let ids = try fixture.correctedIDs()
        let callbackFinished = expectation(description: "prior callback queued")
        let barrierFinished = expectation(description: "barrier observed pending prior work")
        let outcome = CorrectionOutcomeBox()
        let barrierSucceeded = CorrectionBoolBox()
        let callbackHandler = EarnedMeteringCallback(
            store: fixture.store,
            clock: CorrectionClock(now: fixture.start.addingTimeInterval(5 * 60))
        )
        let priorCallback = fixture.callback(routeID: fixture.priorRouteID, threshold: 5)

        lock.pauseNextAcquisition()
        DispatchQueue.global().async {
            outcome.value = try? callbackHandler.handle(
                priorCallback,
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
        let state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .dualV2)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, ids.routeID)
        XCTAssertEqual(state.sampleWork.values.filter { $0.routeID == fixture.priorRouteID }.count, 1)
    }
}

@MainActor
private final class CorrectionFixture {
    let owner: UUID
    let start: Date
    let storeURL: URL
    let store: DeviceEpochStore
    let transport = CorrectionTransport()
    let center = CorrectionCenter()
    let priorGenerationID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    let priorEpochID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    let priorRouteID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    let priorInstallID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    let rejectedGenerationID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    let rejectedEpochID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    let rejectedRouteID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    let rejectedInstallID = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
    let rejectedRegistrationID = UUID(uuidString: "20000000-0000-4000-8000-000000000005")!
    let delivery: MeteringEpochDelivery
    private let clock: CorrectionClock
    private let selectionBytes: Data

    init(
        owner: UUID,
        start: Date,
        lock: any DeviceEpochStoreLocking = ActiveLockPersistenceLock.shared,
        initialBootstrap: Bool = false,
        sameGenerationCandidate: Bool = false
    ) throws {
        self.owner = owner
        self.start = start
        selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-base-correction-\(UUID().uuidString).json")
        store = DeviceEpochStore(fileURL: storeURL, lock: lock, ownerProvider: { owner })
        clock = CorrectionClock(now: start)
        delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            transport: transport,
            clock: clock
        )
        try store.transaction(expectedOwner: owner) { state in
            state = makeState(
                initialBootstrap: initialBootstrap,
                sameGenerationCandidate: sameGenerationCandidate
            )
        }
        if !initialBootstrap {
            try startMonitor(routeID: priorRouteID, store: store)
            try startMonitor(routeID: rejectedRouteID, store: store)
        }
    }

    var rejectedGenerationKey: MeteringGenerationKey {
        MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selectionBytes),
            enforcementSetID: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func reopenedStore() -> DeviceEpochStore {
        let expectedOwner = owner
        return DeviceEpochStore(fileURL: storeURL, ownerProvider: { expectedOwner })
    }

    func correctedIDs(store source: DeviceEpochStore? = nil) throws -> CorrectionIDs {
        let state = try (source ?? store).read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        return CorrectionIDs(
            generationID: handoff.toGenerationID,
            epochID: handoff.toEpochID,
            routeID: handoff.toRouteID
        )
    }

    func replaceDirectly(estimatedMinutes: Int) throws {
        let conflict = authoritativeConflictDTO(estimatedMinutes: estimatedMinutes)
        try store.transaction(expectedOwner: owner) { state in
            guard state.replaceAuthoritativeBaseMismatchCandidate(
                owner: owner,
                rejectedEpochID: rejectedEpochID,
                rejectedRouteID: rejectedRouteID,
                conflict: conflict,
                now: start
            ) else { throw CorrectionFixtureError.replacementRejected }
        }
    }

    func seedPersistedInitialConflict(estimatedMinutes: Int) throws {
        let conflict = authoritativeConflictDTO(estimatedMinutes: estimatedMinutes)
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[rejectedEpochID]?.authoritativeBaseConflict = conflict
            state.registrationWork[rejectedRegistrationID]?.claim = nil
            state.registrationWork[rejectedRegistrationID]?.retry.terminal = .superseded
            state.registrationWork[rejectedRegistrationID]?.retry.lastErrorCode =
                "authoritative_base_mismatch"
        }
    }

    func seedLegacyRetiredPriorCorrectionDeadEnd() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  handoff.phase == .preparing
            else { throw CorrectionFixtureError.replacementRejected }
            state.generations[handoff.fromGenerationID]?.retiredAt = start
            for key in state.installWork.keys where
                state.installWork[key]?.routeID == handoff.toRouteID {
                state.installWork[key]?.claim = nil
                state.installWork[key]?.phase = .pendingStart
                state.installWork[key]?.retry.terminal = .superseded
                state.installWork[key]?.retry.lastErrorCode = "route_superseded"
            }
            for key in state.registrationWork.keys where
                state.registrationWork[key]?.routeID == handoff.toRouteID {
                state.registrationWork[key]?.claim = nil
                state.registrationWork[key]?.retry.terminal = .superseded
                state.registrationWork[key]?.retry.lastErrorCode = "route_superseded"
            }
        }
    }

    func poisonInitialCorrectionWithLegacyReason() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let correctedEpochID = state.activeEpochID,
                  let registrationKey = state.registrationWork.first(where: {
                      $0.value.epochID == correctedEpochID
                  })?.key,
                  let registration = state.registrationWork[registrationKey]
            else { throw CorrectionFixtureError.replacementRejected }
            let request = registration.request
            let legacyRequest = EpochRegistrationRequestDTO(
                protocolVersion: request.protocolVersion,
                epochID: request.epochID,
                deviceID: request.deviceID,
                usageDate: request.usageDate,
                timezone: request.timezone,
                policyRevision: request.policyRevision,
                measurementSelectionDigest: request.measurementSelectionDigest,
                enforcementSetID: request.enforcementSetID,
                startedAt: request.startedAt,
                baseAcceptedMinutes: request.baseAcceptedMinutes,
                reason: .policyChange
            )
            var retry = registration.retry
            retry.terminal = .rejected
            retry.lastErrorCode = "replacement_reason_mismatch"
            state.registrationWork[registrationKey] = EpochRegistrationWork(
                workID: registration.workID,
                ownerChildDeviceID: registration.ownerChildDeviceID,
                epochID: registration.epochID,
                routeID: registration.routeID,
                request: legacyRequest,
                claim: nil,
                retry: retry,
                createdAt: registration.createdAt
            )
        }
    }

    func poisonCutoverCorrectionWithLegacyReason() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff,
                  handoff.phase == .cutoverReady,
                  let registrationKey = state.registrationWork.first(where: {
                      $0.value.epochID == handoff.toEpochID
                          && $0.value.routeID == handoff.toRouteID
                  })?.key,
                  let registration = state.registrationWork[registrationKey]
            else { throw CorrectionFixtureError.replacementRejected }
            handoff.explicitRecovery = nil
            state.v2RouteHandoff = handoff
            var retry = registration.retry
            retry.terminal = .rejected
            retry.lastErrorCode = "replacement_reason_mismatch"
            state.registrationWork[registrationKey] = EpochRegistrationWork(
                workID: registration.workID,
                ownerChildDeviceID: registration.ownerChildDeviceID,
                epochID: registration.epochID,
                routeID: registration.routeID,
                request: registration.request,
                claim: nil,
                retry: retry,
                createdAt: registration.createdAt
            )
        }
    }

    func openCorrectedCandidateForRegistration() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff,
                  handoff.phase == .preparing,
                  var route = state.routes[handoff.toRouteID],
                  let installID = state.installWork.first(where: { $0.value.routeID == route.routeID })?.key
            else { return }
            route.lifecycle = .active
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[route.routeID] = route
            state.installWork[installID]?.phase = .dualActive
            handoff.phase = .dualV2
            state.v2RouteHandoff = handoff
        }
        try store.transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff, handoff.phase == .dualV2 else { return }
            handoff.phase = .cutoverReady
            handoff.priorRouteInputClosedAt = start
            state.v2RouteHandoff = handoff
        }
    }

    func openCorrectedCandidateForDualV2Callbacks() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard var handoff = state.v2RouteHandoff,
                  handoff.phase == .preparing,
                  var route = state.routes[handoff.toRouteID],
                  let installID = state.installWork.first(where: { $0.value.routeID == route.routeID })?.key
            else { return }
            route.lifecycle = .active
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[route.routeID] = route
            state.installWork[installID]?.phase = .dualActive
            handoff.phase = .dualV2
            state.v2RouteHandoff = handoff
        }
    }

    func markCorrectedInstallVerified() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let handoff = state.v2RouteHandoff,
                  var route = state.routes[handoff.toRouteID],
                  let installID = state.installWork.first(where: { $0.value.routeID == route.routeID })?.key
            else { return }
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[route.routeID] = route
            state.installWork[installID]?.phase = .verified
        }
    }

    func driver(at date: Date, store source: DeviceEpochStore? = nil) -> EarnedMeteringRecoveryDriver {
        let source = source ?? store
        let clock = CorrectionClock(now: date)
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: source,
            transport: transport,
            clock: clock,
            legacySuiteName: "base-correction-\(UUID().uuidString)"
        )
        let process = MeteringProcessIdentity(role: .app, instanceID: UUID())
        return EarnedMeteringRecoveryDriver(
            store: source,
            delivery: delivery,
            installer: DatedRouteInstaller(store: source, center: center, processIdentity: process, clock: clock),
            center: center,
            processIdentity: process,
            clock: clock
        )
    }

    func delivery(at date: Date, store source: DeviceEpochStore? = nil) -> MeteringEpochDelivery {
        MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: source ?? store,
            transport: transport,
            clock: CorrectionClock(now: date),
            legacySuiteName: "base-correction-\(UUID().uuidString)"
        )
    }

    func startMonitor(routeID: UUID, store source: DeviceEpochStore) throws {
        let state = try source.read()
        let route = try XCTUnwrap(state.routes[routeID])
        let timezone = try XCTUnwrap(TimeZone(identifier: route.plannedSchedule.timezoneIdentifier))
        let schedule = try MeteringDatedSchedule.datedSchedule(
            usageDate: route.usageDate,
            timeZone: timezone
        )
        let selection = try JSONDecoder().decode(
            FamilyActivitySelection.self,
            from: try XCTUnwrap(state.generations[route.generationID]?.measurementSelectionBytes)
        )
        let events = Dictionary(uniqueKeysWithValues: route.plannedEvents.map { event in
            (
                DeviceActivityEvent.Name(event.eventName),
                MeteringDatedSchedule.makeEvent(
                    selection: selection,
                    thresholdMinutes: event.thresholdMinutes
                )
            )
        })
        try center.startMonitoring(DeviceActivityName(route.activityName), during: schedule, events: events)
    }

    func callback(routeID: UUID, threshold: Int) -> MeteringAppleCallback {
        MeteringAppleCallback(
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: threshold),
            observedAt: start.addingTimeInterval(TimeInterval(threshold * 60))
        )
    }

    func correctedCallback(threshold: Int) -> MeteringAppleCallback {
        callback(routeID: try! store.read().v2RouteHandoff!.toRouteID, threshold: threshold)
    }

    func authoritativeConflictDTO(estimatedMinutes: Int) -> EpochRegistrationConflictDTO {
        let snapshot = DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-18",
            estimatedMinutes: estimatedMinutes,
            capMinutes: 120,
            childDayState: "available",
            usedMinutes: 91,
            remainingMinutes: 3,
            counted: true,
            warning: nil
        )
        return EpochRegistrationConflictDTO(
            code: .authoritativeBaseMismatch,
            authoritativeSnapshot: snapshot
        )
    }

    func authoritativeConflict(estimatedMinutes: Int) -> (Data, URLResponse) {
        let conflict = authoritativeConflictDTO(estimatedMinutes: estimatedMinutes)
        return (
            try! JSONEncoder().encode(conflict),
            HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        )
    }

    func registrationResponse(
        status: EpochRegistrationStatusDTO = .registered,
        store source: DeviceEpochStore? = nil
    ) -> (Data, URLResponse) {
        let source = source ?? store
        let handoff = try! source.read().v2RouteHandoff!
        let epoch = try! source.read().epochs[handoff.toEpochID]!
        let response = EpochRegistrationResponseDTO(
            status: status,
            epochID: epoch.epochID,
            meteringProtocolVersion: 2,
            snapshot: snapshot(for: epoch),
            epochStatus: .active
        )
        return (try! JSONEncoder().encode(response), httpResponse(status: 200))
    }

    func activationResponse(
        status: EpochActivationStatusDTO = .activated,
        store source: DeviceEpochStore? = nil
    ) -> (Data, URLResponse) {
        let source = source ?? store
        let handoff = try! source.read().v2RouteHandoff!
        let epoch = try! source.read().epochs[handoff.toEpochID]!
        let response = EpochActivationResponseDTO(
            status: status,
            epochID: epoch.epochID,
            epochStatus: .active,
            meteringProtocolVersion: 2,
            snapshot: snapshot(for: epoch)
        )
        return (try! JSONEncoder().encode(response), httpResponse(status: 200))
    }

    func sampleAcceptedResponse(estimatedMinutes: Int) -> (Data, URLResponse) {
        let snapshot = DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: "2026-07-18",
            estimatedMinutes: estimatedMinutes,
            capMinutes: 120,
            childDayState: "available",
            usedMinutes: estimatedMinutes,
            remainingMinutes: max(0, 120 - estimatedMinutes),
            counted: true,
            warning: nil
        )
        return (try! JSONEncoder().encode(snapshot), httpResponse(status: 200))
    }

    private func snapshot(for epoch: DeviceDailyEpoch) -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
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
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func makeState(
        initialBootstrap: Bool,
        sameGenerationCandidate: Bool
    ) -> DeviceEpochStoreState {
        let priorGeneration = generation(id: priorGenerationID)
        let rejectedGeneration = sameGenerationCandidate
            ? priorGeneration
            : generation(id: rejectedGenerationID)
        let priorEpoch = epoch(id: priorEpochID, generation: priorGeneration, registeredAt: start)
        let rejectedEpoch = epoch(id: rejectedEpochID, generation: rejectedGeneration, registeredAt: nil)
        let priorRoute = route(id: priorRouteID, epoch: priorEpoch, generation: priorGeneration, lifecycle: .active)
        var rejectedRoute = route(id: rejectedRouteID, epoch: rejectedEpoch, generation: rejectedGeneration, lifecycle: .active)
        let retry = MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending)
        let registration = EpochRegistrationWork(
            workID: rejectedRegistrationID,
            ownerChildDeviceID: owner,
            epochID: rejectedEpochID,
            routeID: rejectedRouteID,
            request: registrationRequest(for: rejectedEpoch),
            claim: nil,
            retry: retry,
            createdAt: start
        )
        if initialBootstrap {
            rejectedRoute.lifecycle = .planned
            rejectedRoute.installedSchedule = nil
            rejectedRoute.installedEvents = nil
            return DeviceEpochStoreState(
                ownerChildDeviceID: owner,
                generations: [rejectedGenerationID: rejectedGeneration],
                activeGenerationID: rejectedGenerationID,
                epochs: [rejectedEpochID: rejectedEpoch],
                activeEpochID: rejectedEpochID,
                routes: [rejectedRouteID: rejectedRoute],
                activeRouteID: nil,
                registrationWork: [rejectedRegistrationID: registration],
                installWork: [
                    rejectedInstallID: install(
                        id: rejectedInstallID,
                        routeID: rejectedRouteID,
                        authorization: .registrationRequired,
                        phase: .pendingStart
                    )
                ]
            )
        }
        let generations = sameGenerationCandidate
            ? [priorGenerationID: priorGeneration]
            : [
                priorGenerationID: priorGeneration,
                rejectedGenerationID: rejectedGeneration,
            ]
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: generations,
            activeGenerationID: priorGenerationID,
            epochs: [priorEpochID: priorEpoch, rejectedEpochID: rejectedEpoch],
            activeEpochID: priorEpochID,
            routes: [priorRouteID: priorRoute, rejectedRouteID: rejectedRoute],
            activeRouteID: priorRouteID,
            v2RouteHandoff: V2RouteHandoff(
                handoffID: UUID(uuidString: "30000000-0000-4000-8000-000000000006")!,
                ownerChildDeviceID: owner,
                fromGenerationID: priorGenerationID,
                fromEpochID: priorEpochID,
                fromRouteID: priorRouteID,
                toGenerationID: rejectedGeneration.generationID,
                toEpochID: rejectedEpochID,
                toRouteID: rejectedRouteID,
                phase: .cutoverReady,
                priorRouteInputClosedAt: start,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: start
            ),
            registrationWork: [rejectedRegistrationID: registration],
            installWork: [
                priorInstallID: install(id: priorInstallID, routeID: priorRouteID, authorization: .registered, phase: .active),
                rejectedInstallID: install(id: rejectedInstallID, routeID: rejectedRouteID, authorization: .offlinePending, phase: .dualActive)
            ],
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

    private func generation(id: UUID) -> MeteringPolicyGeneration {
        MeteringPolicyGeneration(
            generationID: id,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: rejectedGenerationKey.measurementSelectionDigest,
            enforcementSetID: rejectedGenerationKey.enforcementSetID,
            measurementSelectionBytes: selectionBytes,
            createdAt: start,
            retiredAt: nil
        )
    }

    private func epoch(id: UUID, generation: MeteringPolicyGeneration, registeredAt: Date?) -> DeviceDailyEpoch {
        DeviceDailyEpoch(
            epochID: id,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: "2026-07-18",
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest,
            enforcementSetID: generation.enforcementSetID,
            startedAt: start,
            registeredAt: registeredAt,
            baseAcceptedMinutes: 0,
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
    }

    private func route(
        id: UUID,
        epoch: DeviceDailyEpoch,
        generation: MeteringPolicyGeneration,
        lifecycle: MeteringRouteLifecycle
    ) -> MeteringCallbackRoute {
        let schedule = DatedSchedulePlan(
            usageDate: epoch.usageDate,
            timezoneIdentifier: generation.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let event = MeteringEventPlan(
            eventName: MeteringRouteNamespace.eventName(routeID: id, thresholdMinutes: 5),
            thresholdMinutes: 5
        )
        return MeteringCallbackRoute(
            routeID: id,
            activityName: MeteringRouteNamespace.activityName(routeID: id),
            namespace: MeteringRouteNamespace.prefix,
            generationID: generation.generationID,
            generationKey: rejectedGenerationKey,
            ownerChildDeviceID: owner,
            usageDate: epoch.usageDate,
            epochID: epoch.epochID,
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: [event],
            installedEvents: [event],
            lifecycle: lifecycle,
            createdAt: start
        )
    }

    private func install(
        id: UUID,
        routeID: UUID,
        authorization: MeteringInstallAuthorization,
        phase: ActivityInstallPhase
    ) -> ActivityInstallWork {
        ActivityInstallWork(
            workID: id,
            ownerChildDeviceID: owner,
            routeID: routeID,
            authorization: authorization,
            phase: phase,
            claim: nil,
            retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .pending),
            createdAt: start
        )
    }

    private func registrationRequest(for epoch: DeviceDailyEpoch) -> EpochRegistrationRequestDTO {
        EpochRegistrationRequestDTO(
            protocolVersion: 2,
            epochID: epoch.epochID,
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
}

private struct CorrectionClock: MeteringClock {
    let now: Date
}

private struct CorrectionIDs: Equatable {
    let generationID: UUID
    let epochID: UUID
    let routeID: UUID
}

private enum CorrectionFixtureError: Error {
    case replacementRejected
}

private final class CorrectionTransport: MeteringHTTPTransport, @unchecked Sendable {
    var results: [(Data, URLResponse)] = []
    var errors: [URLError.Code] = []
    var requests: [URLRequest] = []
    var onRequest: (@Sendable () -> Void)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        onRequest?()
        if !errors.isEmpty {
            throw URLError(errors.removeFirst())
        }
        guard !results.isEmpty else { throw URLError(.badServerResponse) }
        return results.removeFirst()
    }
}

private final class CorrectionToggleLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let stateLock = NSLock()
    private var available = true

    func setAvailable(_ available: Bool) {
        stateLock.withLock { self.available = available }
    }

    func withLock<T>(_ body: () -> T) -> T? {
        let canAcquire = stateLock.withLock { available }
        return canAcquire ? body() : nil
    }
}

private final class CorrectionSuspendingTransport: MeteringHTTPTransport, @unchecked Sendable {
    private let response: (Data, URLResponse)
    private let onRequest: @Sendable () -> Void
    private let release = CorrectionAsyncGate()
    private let lock = NSLock()
    private var requests = 0

    init(response: (Data, URLResponse), onRequest: @escaping @Sendable () -> Void) {
        self.response = response
        self.onRequest = onRequest
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requests += 1 }
        onRequest()
        await release.wait()
        return response
    }

    func resume() async {
        await release.resume()
    }
}

private actor CorrectionAsyncGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CorrectionRaceLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()
    private let paused = DispatchSemaphore(value: 0)
    private let resumeGate = DispatchSemaphore(value: 0)
    private var acquisitionCount = 0
    private var pauseAtAcquisition: Int?

    func pauseNextAcquisition() {
        lock.withLock { pauseAtAcquisition = acquisitionCount + 1 }
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

private final class CorrectionBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class CorrectionOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EarnedMeteringCallbackOutcome?

    var value: EarnedMeteringCallbackOutcome? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private nonisolated final class CorrectionCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent])] = [:]
    var preventStops = false
    private(set) var stopCalls: [[DeviceActivityName]] = []

    var activities: [DeviceActivityName] { Array(records.keys) }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        records[activity]?.0
    }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        records[activity]?.1 ?? [:]
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        records[activity] = (schedule, events)
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        guard !preventStops else { return }
        activities.forEach { records.removeValue(forKey: $0) }
    }
}
