import DeviceActivity
import FamilyControls
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
        XCTAssertEqual(fixture.center.stopCalls, [[
            DeviceActivityName(LegacyMeteringActivity.legacyActivityName),
            DeviceActivityName("evlin.earned.legacy"),
        ]])
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

    func testInitialActivationFailsClosedForDuplicateSuccessfulRegistration() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        try fixture.addDuplicateCandidateRegistration()

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertTrue(fixture.transport.requests.isEmpty)
        XCTAssertTrue(state.activationWork.isEmpty)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v1)
        XCTAssertEqual(state.legacy?.phase, .activeV1)
        XCTAssertEqual(state.installWork[fixture.candidateInstallID]?.phase, .verified)
    }

    func testInitialActivationSelectsExactCurrentEpochAcrossEightRouteHorizon() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        try fixture.addFutureHorizonRoutes()
        fixture.transport.results = [activationResult(epochID: fixture.candidateEpochID)]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.routes.count, 8)
        XCTAssertEqual(fixture.transport.requests.map(\.url?.path), [
            "/api/v1/child/earned-time/epochs/\(fixture.candidateEpochID.uuidString.lowercased())/activation"
        ])
        XCTAssertEqual(state.activeEpochID, fixture.candidateEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
    }

    func testInitialActivationFailsClosedWhenCurrentEpochRouteIsAmbiguous() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        try fixture.addAmbiguousCurrentRoute()
        fixture.transport.results = [activationResult(epochID: fixture.candidateEpochID)]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertTrue(fixture.transport.requests.isEmpty)
        XCTAssertTrue(state.activationWork.isEmpty)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v1)
        XCTAssertEqual(state.legacy?.phase, .activeV1)
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

    func testAlreadyActivatedPersistsMutableStatusWhileAcknowledgingImmutableRatchet() async throws {
        let cases: [(EpochStatusDTO, DeviceDailyEpochStatus)] = [
            (.paused, .paused),
            (.exhausted, .exhausted),
            (.retired, .retired)
        ]

        for (responseStatus, expectedStatus) in cases {
            let fixture = try makeInitialFixture()
            defer { fixture.cleanup() }
            fixture.transport.results = [
                activationResult(
                    epochID: fixture.candidateEpochID,
                    status: .alreadyActivated,
                    epochStatus: responseStatus
                )
            ]

            try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

            let state = try fixture.store.read()
            XCTAssertEqual(state.epochs[fixture.candidateEpochID]?.status, expectedStatus, "status \(responseStatus)")
            XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2, "status \(responseStatus)")
            XCTAssertEqual(state.ratchets[owner]?.advertisedVersion, 2, "status \(responseStatus)")
            XCTAssertEqual(state.legacy?.phase, .stoppedV1, "status \(responseStatus)")
            XCTAssertEqual(fixture.center.stopCalls.count, 1, "status \(responseStatus)")
        }
    }

    func testRetiredAlreadyActivatedSchedulesExactPreplannedReplacementAfterV2Commit() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        try fixture.addPreplannedReplacement()
        fixture.transport.results = [
            activationResult(
                epochID: fixture.candidateEpochID,
                status: .alreadyActivated,
                epochStatus: .retired
            )
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(state.epochs[fixture.candidateEpochID]?.status, .retired)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.legacy?.phase, .stoppedV1)
        XCTAssertEqual(handoff.phase, .preparing)
        XCTAssertEqual(handoff.fromGenerationID, fixture.candidateGenerationID)
        XCTAssertEqual(handoff.fromEpochID, fixture.candidateEpochID)
        XCTAssertEqual(handoff.fromRouteID, fixture.candidateRouteID)
        XCTAssertEqual(handoff.toGenerationID, fixture.recoveryGenerationID)
        XCTAssertEqual(handoff.toEpochID, fixture.recoveryEpochID)
        XCTAssertEqual(handoff.toRouteID, fixture.recoveryRouteID)
        XCTAssertEqual(state.routes[fixture.recoveryRouteID]?.lifecycle, .planned)
        XCTAssertEqual(state.installWork[fixture.recoveryInstallID]?.phase, .verified)
    }

    func testRetiredAlreadyActivatedReplacementRegistersAndCommitsOnNextRecovery() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        try fixture.addPreplannedReplacement()
        fixture.transport.results = [
            activationResult(
                epochID: fixture.candidateEpochID,
                status: .alreadyActivated,
                epochStatus: .retired
            )
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        fixture.transport.results = [
            registrationResult(epochID: fixture.recoveryEpochID),
            activationResult(epochID: fixture.recoveryEpochID)
        ]
        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(handoff.phase, .committed)
        XCTAssertEqual(state.activeGenerationID, fixture.recoveryGenerationID)
        XCTAssertEqual(state.activeEpochID, fixture.recoveryEpochID)
        XCTAssertEqual(state.activeRouteID, fixture.recoveryRouteID)
        XCTAssertEqual(state.epochs[fixture.recoveryEpochID]?.status, .active)
        XCTAssertEqual(state.installWork[fixture.recoveryInstallID]?.phase, .active)
        XCTAssertEqual(state.installWork[fixture.candidateInstallID]?.phase, .stopped)
        XCTAssertEqual(
            fixture.transport.requests.map(\.url?.path),
            [
                "/api/v1/child/earned-time/epochs/\(fixture.candidateEpochID.uuidString.lowercased())/activation",
                "/api/v1/child/earned-time/epochs",
                "/api/v1/child/earned-time/epochs/\(fixture.recoveryEpochID.uuidString.lowercased())/activation"
            ]
        )
        XCTAssertFalse(state.registrationWork.values.contains { $0.retry.terminal == .pending })
        XCTAssertFalse(state.activationWork.values.contains { $0.retry.terminal == .pending })
    }

    func testLostActivationResponseRetriesExactNonActiveInitialCandidate() async throws {
        for responseStatus in [EpochStatusDTO.paused, .exhausted, .retired] {
            let fixture = try makeInitialFixture()
            defer { fixture.cleanup() }
            fixture.transport.errors = [.noResponse]

            try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
            try fixture.setCandidateEpochStatus(DeviceDailyEpochStatus(rawValue: responseStatus.rawValue)!)
            fixture.transport.results = [
                activationResult(
                    epochID: fixture.candidateEpochID,
                    status: .alreadyActivated,
                    epochStatus: responseStatus
                )
            ]

            try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

            let state = try fixture.store.read()
            XCTAssertEqual(fixture.transport.requests.count, 2, "status \(responseStatus)")
            XCTAssertEqual(state.activationWork.values.first?.retry.terminal, .succeeded, "status \(responseStatus)")
            XCTAssertEqual(state.epochs[fixture.candidateEpochID]?.status.rawValue, responseStatus.rawValue)
            XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2, "status \(responseStatus)")
            XCTAssertEqual(state.legacy?.phase, .stoppedV1, "status \(responseStatus)")
        }
    }

    func testNonActiveActivationRetryRejectsWrongEpochDifferentRouteAndRetiredRoute() async throws {
        let mutations: [(String, (ActivationFixture) throws -> Void)] = [
            ("wrong active epoch", { try $0.pointActiveEpochAtDifferentEpoch() }),
            ("different route", { try $0.replacePendingActivationWithUnrelatedRoute(lifecycle: .active) }),
            ("retired route", { try $0.replacePendingActivationWithUnrelatedRoute(lifecycle: .retired) })
        ]

        for (name, mutate) in mutations {
            let fixture = try makeInitialFixture()
            defer { fixture.cleanup() }
            fixture.transport.errors = [.noResponse]
            try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
            try fixture.setCandidateEpochStatus(.retired)
            try mutate(fixture)
            fixture.transport.results = [
                activationResult(
                    epochID: fixture.candidateEpochID,
                    status: .alreadyActivated,
                    epochStatus: .retired
                )
            ]

            try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

            let state = try fixture.store.read()
            XCTAssertEqual(fixture.transport.requests.count, 1, name)
            XCTAssertEqual(state.activationWork.values.first?.retry.terminal, .pending, name)
            XCTAssertEqual(state.ratchets[owner]?.localSelection, .dualActive, name)
            XCTAssertEqual(state.legacy?.phase, .activeV1, name)
        }
    }

    func testActiveStaleHorizonActivationCannotBypassExactTupleAuthorization() async throws {
        let fixture = try makeInitialFixture()
        defer { fixture.cleanup() }
        fixture.transport.errors = [.noResponse]
        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
        try fixture.replacePendingActivationWithUnrelatedRoute(
            lifecycle: .active,
            epochStatus: .active
        )
        fixture.transport.results = [activationResult(epochID: fixture.unrelatedEpochID)]

        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(fixture.transport.requests.count, 1)
        XCTAssertEqual(state.activationWork.values.first?.retry.terminal, .pending)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .dualActive)
        XCTAssertEqual(state.legacy?.phase, .activeV1)
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

    func testPolicyReplacementRegistersCandidateWithPolicyChangeReason() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let request = try XCTUnwrap(fixture.transport.requests.first {
            $0.url?.path == "/api/v1/child/earned-time/epochs"
        })
        let body = try XCTUnwrap(request.httpBody)
        let registration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(registration["reason"] as? String, "policy_change")
    }

    func testPhysicalLadderRepairRegistersIdentityRecoveryAndCommitsFreshRoute() async throws {
        let fixture = try makePhysicalRepairFixture()
        defer { fixture.cleanup() }
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture, at: start.addingTimeInterval(60))
            .recover(ownerChildDeviceID: owner)

        let prepared = try fixture.store.read()
        let preparedHandoff = try XCTUnwrap(prepared.v2RouteHandoff)
        XCTAssertEqual(prepared.activeRouteID, fixture.priorRouteID)
        XCTAssertNotEqual(preparedHandoff.toRouteID, fixture.priorRouteID)
        fixture.transport.results = [
            registrationResult(epochID: preparedHandoff.toEpochID),
            activationResult(epochID: preparedHandoff.toEpochID)
        ]

        try await makeDriver(fixture, at: start.addingTimeInterval(3_600))
            .recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let candidate = try XCTUnwrap(state.routes[handoff.toRouteID])
        let candidateEpoch = try XCTUnwrap(state.epochs[handoff.toEpochID])
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(handoff.phase, .committed)
        XCTAssertEqual(state.activeRouteID, candidate.routeID)
        XCTAssertNotEqual(candidate.routeID, fixture.priorRouteID)
        XCTAssertNotEqual(candidate.activityName, "evlin.earned.prior")
        XCTAssertEqual(candidateEpoch.baseAcceptedMinutes, 100)
        XCTAssertEqual(candidate.ladderBaseMinutes, 100)
        XCTAssertNil(
            state.generations[fixture.priorGenerationID]?.retiredAt,
            "physical identity recovery stays inside the live policy generation"
        )
        XCTAssertEqual(state.routes[fixture.priorRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .stopped)
        XCTAssertEqual(fixture.center.stopCalls, [[DeviceActivityName("evlin.earned.prior")]])

        let request = try XCTUnwrap(fixture.transport.requests.first {
            $0.url?.path == "/api/v1/child/earned-time/epochs"
        })
        let body = try XCTUnwrap(request.httpBody)
        let registration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(registration["reason"] as? String, "identity_recovery")
        XCTAssertEqual(registration["base_accepted_minutes"] as? Int, 100)
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

    func testLostReplacementActivationResponseRetriesExactNonActiveCutoverCandidate() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [registrationResult(epochID: fixture.candidateEpochID)]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        var state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertEqual(state.activationWork.values.first?.retry.terminal, .pending)
        XCTAssertEqual(fixture.transport.requests.count, 2)

        try fixture.setCandidateEpochStatus(.exhausted)
        fixture.transport.results = [
            activationResult(
                epochID: fixture.candidateEpochID,
                status: .alreadyActivated,
                epochStatus: .exhausted
            )
        ]
        try await makeDriver(fixture, at: start.addingTimeInterval(5)).recover(ownerChildDeviceID: owner)

        state = try fixture.store.read()
        XCTAssertEqual(fixture.transport.requests.count, 3)
        XCTAssertEqual(state.activationWork.values.first?.retry.terminal, .succeeded)
        XCTAssertEqual(state.epochs[fixture.candidateEpochID]?.status, .exhausted)
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

    func testReplacementStopPersistsOneExactAcknowledgementTimestamp() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]
        let clock = AdvancingActivationClock(now: start, step: 0.001)

        try await makeDriver(fixture, clock: clock).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let tombstone = try XCTUnwrap(state.tombstones[handoff.fromRouteID])
        XCTAssertEqual(state.installWork[fixture.priorInstallID]?.phase, .stopped)
        XCTAssertEqual(tombstone.stopAcknowledgedAt, handoff.priorStopAcknowledgedAt)
    }

    func testCompletedReplacementHandoffIsCollectedOnNextRecovery() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
        XCTAssertNotNil(try fixture.store.read().v2RouteHandoff?.priorStopAcknowledgedAt)

        try await makeDriver(fixture, at: start.addingTimeInterval(5))
            .recover(ownerChildDeviceID: owner)

        XCTAssertNil(try fixture.store.read().v2RouteHandoff)
    }

    func testTerminalRejectedReplacementYieldsToNewerPolicyCandidate() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPreplannedReplacement()
        try fixture.addPendingCandidateRegistration()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
        try fixture.rejectCandidateRegistration(code: "replacement_reason_mismatch")

        try await makeDriver(fixture, at: start.addingTimeInterval(5))
            .recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.fromRouteID, fixture.priorRouteID)
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, fixture.recoveryRouteID)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .tombstoned)
        XCTAssertEqual(state.epochs[fixture.candidateEpochID]?.retireReason, .activationSuperseded)
        XCTAssertEqual(state.installWork[fixture.candidateInstallID]?.phase, .stopped)
    }

    func testSupersededAuditDoesNotAbandonSuccessfullyRegisteredCandidate() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPreplannedReplacement()
        try fixture.addPendingCandidateRegistration()
        fixture.transport.results = [registrationResult(epochID: fixture.candidateEpochID)]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(
            state.registrationWork.values
                .filter { $0.routeID == fixture.candidateRouteID }
                .map { $0.retry.terminal.rawValue }
                .sorted(),
            [MeteringWorkTerminal.succeeded.rawValue, MeteringWorkTerminal.superseded.rawValue]
        )
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .active)
        XCTAssertNil(state.epochs[fixture.candidateEpochID]?.retireReason)
    }

    func testSupersededAuditDoesNotAbandonCandidateWhileRetryIsPending() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPreplannedReplacement()
        try fixture.addSupersededCandidateRegistration()
        try fixture.addPendingCandidateRegistration()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertTrue(state.registrationWork.values.contains {
            $0.routeID == fixture.candidateRouteID
                && $0.retry.terminal == .pending
        })
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .active)
        XCTAssertNil(state.epochs[fixture.candidateEpochID]?.retireReason)
    }

    func testUnactivatedSameKeyConflictRecoversPhysicalIdentityInPlace() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            registrationConflict(code: "physical_identity_recovery_required"),
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(handoff.toRouteID, fixture.candidateRouteID)
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(handoff.phase, .committed)
        XCTAssertEqual(state.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .active)
        XCTAssertEqual(
            state.registrationWork.values
                .filter { $0.routeID == fixture.candidateRouteID }
                .map(\.request.reason),
            [.identityRecovery]
        )
        XCTAssertEqual(
            fixture.transport.requests.filter {
                $0.url?.path == "/api/v1/child/earned-time/epochs"
            }.count,
            2
        )
    }

    func testPhysicalIdentityRecoverySurvivesRestartAfterRecoveryDirective() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        fixture.transport.results = [
            registrationConflict(code: "physical_identity_recovery_required")
        ]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let interrupted = try fixture.store.read()
        let interruptedHandoff = try XCTUnwrap(interrupted.v2RouteHandoff)
        XCTAssertEqual(interruptedHandoff.toRouteID, fixture.candidateRouteID)
        XCTAssertEqual(interruptedHandoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(interruptedHandoff.phase, .cutoverReady)
        XCTAssertTrue(interrupted.registrationWork.values.contains {
            $0.routeID == fixture.candidateRouteID
                && $0.request.reason == .identityRecovery
                && $0.retry.terminal == .pending
        })

        fixture.transport.results = [
            registrationResult(epochID: fixture.candidateEpochID),
            activationResult(epochID: fixture.candidateEpochID)
        ]
        try await makeDriver(fixture, at: start.addingTimeInterval(3_600))
            .recover(ownerChildDeviceID: owner)

        let recovered = try fixture.store.read()
        let recoveredHandoff = try XCTUnwrap(recovered.v2RouteHandoff)
        XCTAssertEqual(recoveredHandoff.toRouteID, fixture.candidateRouteID)
        XCTAssertEqual(recoveredHandoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(recoveredHandoff.phase, .committed)
        XCTAssertEqual(recovered.activeRouteID, fixture.candidateRouteID)
        XCTAssertEqual(recovered.routes[fixture.candidateRouteID]?.lifecycle, .active)
        XCTAssertEqual(
            fixture.transport.requests.filter {
                $0.url?.path == "/api/v1/child/earned-time/epochs"
            }.count,
            3
        )
    }

    func testDuplicatePhysicalIdentityRejectionsConvergeToOneRecoveryRegistration() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addRejectedPhysicalIdentityRegistrations(count: 2)
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let matching = try fixture.store.read().registrationWork.values
            .filter {
                $0.ownerChildDeviceID == owner
                    && $0.epochID == fixture.candidateEpochID
                    && $0.routeID == fixture.candidateRouteID
            }
        XCTAssertEqual(
            matching.filter {
                $0.retry.terminal == .pending
                    && $0.request.reason == .identityRecovery
            }.count,
            1
        )
        XCTAssertEqual(
            matching.filter {
                $0.retry.terminal == .superseded
                    && $0.retry.lastErrorCode
                        == "duplicate_physical_identity_recovery_superseded"
            }.count,
            1
        )
        XCTAssertEqual(matching.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.read().v2RouteHandoff).explicitRecovery,
            .identityRecovery
        )
    }

    func testWaitingCandidateSampleDoesNotBlockItsRegistration() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addPendingCandidateRegistration()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)
        try fixture.addWaitingCandidateSample(createdAt: start.addingTimeInterval(1))
        fixture.transport.results = [registrationResult(epochID: fixture.candidateEpochID)]

        try await makeDriver(fixture, at: start.addingTimeInterval(5))
            .recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertTrue(state.registrationWork.values.contains {
            $0.routeID == fixture.candidateRouteID
                && $0.retry.terminal == .succeeded
        })
        XCTAssertEqual(
            state.sampleWork.values.first(where: { $0.routeID == fixture.candidateRouteID })?.authorization,
            .v2Deliverable
        )
    }

    func testFutureHorizonRouteDoesNotSupersedeCurrentPolicyCandidate() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        try fixture.addFutureHorizonRoutes()
        try fixture.addPendingCandidateRegistration()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, fixture.candidateRouteID)
        XCTAssertEqual(state.routes[fixture.candidateRouteID]?.lifecycle, .active)
        XCTAssertNil(state.epochs[fixture.candidateEpochID]?.retireReason)
    }

    func testHistoricalPlannedRouteCannotRollActivePolicyBackward() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        let historicalRouteID = try fixture.addHistoricalPlannedReplacement()
        try fixture.addPendingCandidateRegistration()
        fixture.transport.errors = [.noResponse]

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertNotEqual(state.v2RouteHandoff?.toRouteID, historicalRouteID)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
    }

    func testPersistedPreparingHandoffToHistoricalRouteIsCancelled() async throws {
        let fixture = try makeReplacementFixture()
        defer { fixture.cleanup() }
        let historicalRouteID = try fixture.addHistoricalPlannedReplacement()
        try fixture.setPreparingHandoff(to: historicalRouteID)

        try await makeDriver(fixture).recover(ownerChildDeviceID: owner)

        let state = try fixture.store.read()
        XCTAssertEqual(state.v2RouteHandoff?.toRouteID, fixture.candidateRouteID)
        XCTAssertNotEqual(state.v2RouteHandoff?.toRouteID, historicalRouteID)
        XCTAssertEqual(state.activeRouteID, fixture.priorRouteID)
        XCTAssertEqual(state.routes[historicalRouteID]?.lifecycle, .planned)
    }

    private func makeDriver(
        _ fixture: ActivationFixture,
        at date: Date? = nil,
        clock injectedClock: (any MeteringClock)? = nil
    ) -> EarnedMeteringRecoveryDriver {
        let clock: any MeteringClock = injectedClock ?? ActivationClock(now: date ?? start)
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

    private func makePhysicalRepairFixture() throws -> ActivationFixture {
        let fixture = ActivationFixture(owner: owner, start: start)
        try fixture.store.transaction(expectedOwner: owner) { state in
            state = fixture.physicalRepairState()
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

    private func registrationConflict(code: String) -> (Data, URLResponse) {
        (
            try! JSONSerialization.data(withJSONObject: ["detail": code]),
            httpResponse(status: 409)
        )
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

private final class AdvancingActivationClock: MeteringClock, @unchecked Sendable {
    private var value: Date
    private let step: TimeInterval

    init(now: Date, step: TimeInterval) {
        value = now
        self.step = step
    }

    var now: Date {
        defer { value = value.addingTimeInterval(step) }
        return value
    }
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

private nonisolated final class ActivationCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
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
    let unrelatedEpochID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    let unrelatedRouteID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    let recoveryGenerationID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
    let recoveryEpochID = UUID(uuidString: "50000000-0000-4000-8000-000000000002")!
    let recoveryRouteID = UUID(uuidString: "50000000-0000-4000-8000-000000000003")!
    let recoveryInstallID = UUID(uuidString: "50000000-0000-4000-8000-000000000004")!

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

    func addFutureHorizonRoutes() throws {
        let futureDates = [
            "2026-07-18", "2026-07-19", "2026-07-20", "2026-07-21",
            "2026-07-22", "2026-07-23", "2026-07-24"
        ]
        try store.transaction(expectedOwner: owner) { state in
            guard let generation = state.generations[candidateGenerationID] else { return }
            for (index, usageDate) in futureDates.enumerated() {
                let suffix = String(format: "%012d", index + 1)
                let epochID = UUID(uuidString: "01000000-0000-4000-8000-\(suffix)")!
                let routeID = UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
                let epoch = makeEpoch(
                    id: epochID,
                    generation: generation,
                    registeredAt: nil,
                    usageDate: usageDate
                )
                let route = makeRoute(
                    id: routeID,
                    epoch: epoch,
                    generation: generation,
                    name: "evlin.earned.future.\(index + 1)",
                    lifecycle: .planned
                )
                state.epochs[epochID] = epoch
                state.routes[routeID] = route
            }
        }
    }

    func addDuplicateCandidateRegistration() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[candidateRouteID],
                  let epoch = state.epochs[candidateEpochID]
            else { return }
            let duplicate = registration(route: route, epoch: epoch, terminal: .succeeded)
            state.registrationWork[duplicate.workID] = duplicate
        }
    }

    func addAmbiguousCurrentRoute() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let generation = state.generations[candidateGenerationID],
                  let epoch = state.epochs[candidateEpochID]
            else { return }
            let routeID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
            let installID = UUID(uuidString: "00000000-0000-4000-8000-000000000098")!
            let route = makeRoute(
                id: routeID,
                epoch: epoch,
                generation: generation,
                name: "evlin.earned.ambiguous",
                lifecycle: .planned
            )
            state.routes[routeID] = route
            state.registrationWork[UUID()] = registration(route: route, epoch: epoch, terminal: .succeeded)
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: retry(.succeeded),
                createdAt: start
            )
        }
    }

    func addPreplannedReplacement() throws {
        try store.transaction(expectedOwner: owner) { state in
            let generation = makeGeneration(id: recoveryGenerationID, policy: "recovery")
            let epoch = makeEpoch(id: recoveryEpochID, generation: generation, registeredAt: nil)
            let route = makeRoute(
                id: recoveryRouteID,
                epoch: epoch,
                generation: generation,
                name: "evlin.earned.recovery",
                lifecycle: .planned
            )
            state.generations[generation.generationID] = generation
            state.epochs[epoch.epochID] = epoch
            state.routes[route.routeID] = route
            state.installWork[recoveryInstallID] = ActivityInstallWork(
                workID: recoveryInstallID,
                ownerChildDeviceID: owner,
                routeID: route.routeID,
                authorization: .offlinePending,
                phase: .verified,
                claim: nil,
                retry: retry(.succeeded),
                createdAt: start
            )
        }
    }

    func addHistoricalPlannedReplacement() throws -> UUID {
        let generationID = UUID(uuidString: "05000000-0000-4000-8000-000000000001")!
        let epochID = UUID(uuidString: "05000000-0000-4000-8000-000000000002")!
        let routeID = UUID(uuidString: "05000000-0000-4000-8000-000000000003")!
        let installID = UUID(uuidString: "05000000-0000-4000-8000-000000000004")!
        let historicalStart = start.addingTimeInterval(-100)
        try store.transaction(expectedOwner: owner) { state in
            let generation = makeGeneration(
                id: generationID,
                policy: "historical",
                createdAt: historicalStart
            )
            let epoch = makeEpoch(id: epochID, generation: generation, registeredAt: nil)
            let route = makeRoute(
                id: routeID,
                epoch: epoch,
                generation: generation,
                name: "evlin.earned.historical",
                lifecycle: .planned,
                createdAt: historicalStart
            )
            state.generations[generationID] = generation
            state.epochs[epochID] = epoch
            state.routes[routeID] = route
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .offlinePending,
                phase: .verified,
                claim: nil,
                retry: retry(.succeeded),
                createdAt: historicalStart
            )
        }
        return routeID
    }

    func setPreparingHandoff(to routeID: UUID) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let fromRoute = state.routes[priorRouteID],
                  let toRoute = state.routes[routeID]
            else { return }
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: owner,
                fromGenerationID: fromRoute.generationID,
                fromEpochID: fromRoute.epochID,
                fromRouteID: fromRoute.routeID,
                toGenerationID: toRoute.generationID,
                toEpochID: toRoute.epochID,
                toRouteID: toRoute.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: start
            )
        }
    }

    func rejectCandidateRegistration(code: String) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: {
                $0.value.routeID == candidateRouteID
                    && $0.value.epochID == candidateEpochID
                    && $0.value.retry.terminal == .pending
            })?.key else { return }
            state.registrationWork[key]?.claim = nil
            state.registrationWork[key]?.retry.terminal = .rejected
            state.registrationWork[key]?.retry.lastErrorCode = code
        }
    }

    func setCandidateEpochStatus(_ status: DeviceDailyEpochStatus) throws {
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[candidateEpochID]?.status = status
        }
    }

    func pointActiveEpochAtDifferentEpoch() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let generation = state.generations[candidateGenerationID] else { return }
            let epochID = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
            state.epochs[epochID] = makeEpoch(
                id: epochID,
                generation: generation,
                registeredAt: start
            )
            state.activeEpochID = epochID
        }
    }

    func replacePendingActivationWithUnrelatedRoute(
        lifecycle: MeteringRouteLifecycle,
        epochStatus: DeviceDailyEpochStatus = .retired
    ) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let generation = state.generations[candidateGenerationID],
                  let activationKey = state.activationWork.keys.first,
                  let prior = state.activationWork[activationKey]
            else { return }
            let epochID = unrelatedEpochID
            let routeID = unrelatedRouteID
            var epoch = makeEpoch(id: epochID, generation: generation, registeredAt: start)
            epoch.status = epochStatus
            let route = makeRoute(
                id: routeID,
                epoch: epoch,
                generation: generation,
                name: "evlin.earned.unrelated",
                lifecycle: lifecycle
            )
            state.epochs[epochID] = epoch
            state.routes[routeID] = route
            state.registrationWork[UUID()] = registration(route: route, epoch: epoch, terminal: .succeeded)
            let installID = UUID(uuidString: "30000000-0000-4000-8000-000000000004")!
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .dualActive,
                claim: nil,
                retry: retry(.succeeded),
                createdAt: start
            )
            state.activationWork[activationKey] = EpochActivationWork(
                workID: prior.workID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochActivationRequestDTO(
                    protocolVersion: 2,
                    deviceID: owner,
                    routeID: routeID,
                    verifiedAt: prior.request.verifiedAt
                ),
                claim: nil,
                retry: prior.retry,
                createdAt: prior.createdAt
            )
        }
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

    func physicalRepairState() -> DeviceEpochStoreState {
        let selectionBytes = try! JSONEncoder().encode(FamilyActivitySelection())
        let generation = makeGeneration(
            id: priorGenerationID,
            policy: "physical-repair",
            poolMinutes: 240,
            selectionBytes: selectionBytes
        )
        var epoch = makeEpoch(
            id: priorEpochID,
            generation: generation,
            registeredAt: start
        )
        epoch = DeviceDailyEpoch(
            epochID: epoch.epochID,
            protocolVersion: epoch.protocolVersion,
            childDeviceID: epoch.childDeviceID,
            usageDate: epoch.usageDate,
            canonicalTimezone: epoch.canonicalTimezone,
            policyRevision: epoch.policyRevision,
            measurementSelectionDigest: epoch.measurementSelectionDigest,
            enforcementSetID: epoch.enforcementSetID,
            startedAt: epoch.startedAt,
            registeredAt: epoch.registeredAt,
            baseAcceptedMinutes: 225,
            baseSource: epoch.baseSource,
            lastRawThresholdMinutes: 225,
            excludedWhilePausedMinutes: 0,
            status: epoch.status,
            resumeBoundaryPending: false,
            retiredAt: nil,
            retireReason: nil,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        var route = makeRoute(
            id: priorRouteID,
            epoch: epoch,
            generation: generation,
            name: "evlin.earned.prior",
            lifecycle: .active
        )
        route.ladderBaseMinutes = 225
        let registrationID = UUID()
        let acceptedRegistration = EpochRegistrationWork(
            workID: registrationID,
            ownerChildDeviceID: owner,
            epochID: priorEpochID,
            routeID: priorRouteID,
            request: EpochRegistrationRequestDTO(
                protocolVersion: 2,
                epochID: priorEpochID,
                deviceID: owner,
                usageDate: epoch.usageDate,
                timezone: epoch.canonicalTimezone,
                policyRevision: epoch.policyRevision,
                measurementSelectionDigest: epoch.measurementSelectionDigest,
                enforcementSetID: epoch.enforcementSetID,
                startedAt: start,
                baseAcceptedMinutes: 100,
                reason: .initial
            ),
            claim: nil,
            retry: retry(.succeeded),
            createdAt: start
        )
        return DeviceEpochStoreState(
            ownerChildDeviceID: owner,
            generations: [priorGenerationID: generation],
            activeGenerationID: priorGenerationID,
            epochs: [priorEpochID: epoch],
            activeEpochID: priorEpochID,
            routes: [priorRouteID: route],
            activeRouteID: priorRouteID,
            registrationWork: [registrationID: acceptedRegistration],
            installWork: [
                priorInstallID: ActivityInstallWork(
                    workID: priorInstallID,
                    ownerChildDeviceID: owner,
                    routeID: priorRouteID,
                    authorization: .registered,
                    phase: .verified,
                    claim: nil,
                    retry: retry(.pending),
                    createdAt: start
                )
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

    func addSupersededCandidateRegistration() throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[candidateRouteID],
                  let epoch = state.epochs[candidateEpochID]
            else { return }
            var work = registration(route: route, epoch: epoch, terminal: .superseded)
            work.retry.lastErrorCode = "replacement_registration_deferred"
            state.registrationWork[work.workID] = work
        }
    }

    func addRejectedPhysicalIdentityRegistrations(count: Int) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[candidateRouteID],
                  let epoch = state.epochs[candidateEpochID]
            else { return }
            for index in 0..<count {
                let workID = UUID()
                state.registrationWork[workID] = EpochRegistrationWork(
                    workID: workID,
                    ownerChildDeviceID: owner,
                    epochID: epoch.epochID,
                    routeID: route.routeID,
                    request: registrationRequest(route: route, epoch: epoch),
                    claim: nil,
                    retry: MeteringRetryState(
                        attemptCount: 1,
                        nextAttemptAt: start,
                        lastErrorCode:
                            "physical_identity_recovery_required",
                        terminal: .rejected
                    ),
                    createdAt: start.addingTimeInterval(TimeInterval(index))
                )
            }
        }
    }

    func addWaitingCandidateSample(createdAt: Date) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[candidateRouteID],
                  let epoch = state.epochs[candidateEpochID],
                  let event = route.plannedEvents.first
            else { return }
            let workID = UUID()
            state.sampleWork[workID] = EpochSampleWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epoch.epochID,
                routeID: route.routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: epoch.usageDate,
                    timezone: epoch.canonicalTimezone,
                    activityName: route.activityName,
                    eventName: event.eventName,
                    thresholdMinutes: event.thresholdMinutes,
                    estimatedMinutes: event.thresholdMinutes,
                    observedAt: createdAt,
                    clientSampleID: "waiting-registration-\(workID.uuidString.lowercased())",
                    protocolVersion: 2,
                    epochID: epoch.epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .waitingForRegistration,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: createdAt,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: createdAt
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

    private func makeGeneration(
        id: UUID,
        policy: String,
        createdAt: Date? = nil,
        poolMinutes: Int? = nil,
        selectionBytes: Data = Data()
    ) -> MeteringPolicyGeneration {
        return MeteringPolicyGeneration(
            generationID: id, protocolVersion: 2, childDeviceID: owner,
            canonicalTimezone: "America/New_York", policyRevision: policy,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
            measurementSelectionBytes: selectionBytes,
            createdAt: createdAt ?? start,
            retiredAt: nil,
            configuredPoolMinutes: poolMinutes,
            configuredDeviceCapMinutes: poolMinutes
        )
    }

    private func makeEpoch(
        id: UUID,
        generation: MeteringPolicyGeneration,
        registeredAt: Date?,
        usageDate: String = "2026-07-17"
    ) -> DeviceDailyEpoch {
        DeviceDailyEpoch(
            epochID: id, protocolVersion: 2, childDeviceID: owner, usageDate: usageDate,
            canonicalTimezone: generation.canonicalTimezone, policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest, enforcementSetID: generation.enforcementSetID,
            startedAt: start, registeredAt: registeredAt, baseAcceptedMinutes: 0, baseSource: .childState200,
            lastRawThresholdMinutes: 0, excludedWhilePausedMinutes: 0, status: .active,
            resumeBoundaryPending: false, retiredAt: nil, retireReason: nil, exhaustedAt: nil,
            baseCorrectionState: .available
        )
    }

    private func makeRoute(
        id: UUID,
        epoch: DeviceDailyEpoch,
        generation: MeteringPolicyGeneration,
        name: String,
        lifecycle: MeteringRouteLifecycle,
        createdAt: Date? = nil
    ) -> MeteringCallbackRoute {
        MeteringCallbackRoute(
            routeID: id, activityName: name, namespace: MeteringRouteNamespace.prefix,
            generationID: generation.generationID,
            generationKey: MeteringGenerationKey(protocolVersion: 2, childDeviceID: owner, canonicalTimezone: generation.canonicalTimezone, policyRevision: generation.policyRevision, measurementSelectionDigest: generation.measurementSelectionDigest, enforcementSetID: generation.enforcementSetID),
            ownerChildDeviceID: owner, usageDate: epoch.usageDate, epochID: epoch.epochID,
            plannedSchedule: DatedSchedulePlan(usageDate: epoch.usageDate, timezoneIdentifier: generation.canonicalTimezone, calendarIdentifier: "gregorian"),
            installedSchedule: DatedSchedulePlan(usageDate: epoch.usageDate, timezoneIdentifier: generation.canonicalTimezone, calendarIdentifier: "gregorian"),
            plannedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: id, thresholdMinutes: 5), thresholdMinutes: 5)],
            installedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: id, thresholdMinutes: 5), thresholdMinutes: 5)],
            lifecycle: lifecycle, createdAt: createdAt ?? start
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
            active: LegacyGenerationProvenance(activityName: "evlin.earned.legacy", deviceID: owner.uuidString, offsetMinutes: 0, usageDate: "2026-07-17", timezoneIdentifier: "America/New_York", armedAt: start),
            pending: nil, retiringActivityNames: [], breadcrumbActivityNames: [], scalarActiveActivityName: "evlin.earned.legacy", isStopped: false, phase: .activeV1, stopAcknowledgedAt: nil)
    }
}
