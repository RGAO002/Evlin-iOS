import Foundation
import XCTest
@testable import Evlin_iOS

/// BUG 1 — the epoch base and the ladder its rungs were cut from must stay one
/// fact.
///
/// Field evidence (iPad, 2026-07-25 13:37): the epoch read `base=145 raw=160`
/// while Apple still held a 32-rung ladder topping out at 160 — a ladder cut
/// when the base was 20. `base + threshold` then reported 295 and 305 minutes
/// into a 180-minute pool, and every further re-arm folded the stale rung back
/// into the base again: 145 → 305 → 425 → 445 → 460.
final class MeteringLadderBaseInvariantTests: XCTestCase {

    private var captured: [ScreenTimeEvent] = []

    override func setUp() {
        super.setUp()
        captured = []
        MeteringFlightRecorder.testSink = { [weak self] event in
            self?.captured.append(event)
        }
    }

    override func tearDown() {
        MeteringFlightRecorder.testSink = nil
        captured = []
        super.tearDown()
    }

    // MARK: - The over-report itself

    /// The exact iPad shape: Apple re-delivers a rung of a ladder the store has
    /// already moved past. The rung must resolve against the base it was cut
    /// for, not the base that grew underneath it.
    func testStaleLadderRungReportsAgainstItsOwnLadderBase() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 145,
            ladderBase: 20,
            poolMinutes: 180
        )
        defer { fixture.cleanup() }
        // Pre-fix arithmetic: 145 + 150 = 295 against a 180-minute pool.
        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 150, minutesAfterStart: 150),
            owner: fixture.owner
        )
        guard case .queued = outcome else { return XCTFail("expected queued, got \(outcome)") }

        let reported = try XCTUnwrap(fixture.reportedMinutes())
        XCTAssertEqual(reported, 170, "ladder base 20 + rung 150")
        XCTAssertLessThanOrEqual(reported, 180)
    }

    /// A route persisted before `ladderBaseMinutes` existed has no ladder base to
    /// resolve against. The clamp is the whole defence, and it must leave a
    /// record — a silently clamped sample is a lie with no paper trail.
    func testLegacyRouteWithoutALadderBaseIsClampedToThePoolAndRecorded() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 145,
            ladderBase: nil,
            poolMinutes: 180
        )
        defer { fixture.cleanup() }

        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 160, minutesAfterStart: 160),
            owner: fixture.owner
        )
        guard case .queued = outcome else { return XCTFail("expected queued, got \(outcome)") }

        XCTAssertEqual(try fixture.reportedMinutes(), 180, "clamped from 145 + 160 = 305")
        let clamp = try XCTUnwrap(
            captured.first { $0.reason == "clamped_over_ceiling" },
            "a clamped sample must be recorded"
        )
        XCTAssertEqual(clamp.transition?.before, "305")
        XCTAssertEqual(clamp.transition?.after, "180")
        XCTAssertEqual(clamp.nums?.used, 180)
    }

    /// The clamp is deliberately independent of the ladder-base invariant: even
    /// a route whose recorded ladder base is itself absurd cannot bill more than
    /// the day's pool.
    func testNoSampleMayEverExceedThePoolCeiling() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 460,
            ladderBase: 460,
            poolMinutes: 180
        )
        defer { fixture.cleanup() }

        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 5, minutesAfterStart: 5),
            owner: fixture.owner
        )
        guard case .queued = outcome else { return XCTFail("expected queued, got \(outcome)") }
        XCTAssertEqual(try fixture.reportedMinutes(), 180)
    }

    // MARK: - Absorb keeps base and ladder together

    func testAbsorbCarriesOnlyBackendAcceptedProgressAndDropsRejectedRawHighWater() throws {
        let fixture = try LadderFixture.healthy(epochBase: 0, poolMinutes: 240)
        defer { fixture.cleanup() }
        try fixture.recordThreshold(100, terminal: .succeeded)
        try fixture.recordThreshold(230, terminal: .rejected)

        XCTAssertTrue(try fixture.store.absorbCreditedProgressForRearm(
            routeID: fixture.routeID,
            owner: fixture.owner,
            trigger: "watchdog"
        ))

        let state = try fixture.store.read()
        let epoch = try XCTUnwrap(state.epochs[fixture.epochID])
        let route = try XCTUnwrap(state.routes[fixture.routeID])
        XCTAssertEqual(epoch.baseAcceptedMinutes, 100)
        XCTAssertEqual(epoch.lastRawThresholdMinutes, 0)
        XCTAssertEqual(route.ladderBaseMinutes, 100)
        XCTAssertEqual(route.plannedEvents.map(\.thresholdMinutes).max(), 140)
    }

    func testAbsorbRecutsTheLadderForTheCarriedBaseInTheSameTransaction() throws {
        let fixture = try LadderFixture.healthy(epochBase: 20, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.recordThreshold(125, terminal: .succeeded)

        XCTAssertTrue(try fixture.store.absorbCreditedProgressForRearm(
            routeID: fixture.routeID,
            owner: fixture.owner,
            trigger: "test"
        ))

        let state = try fixture.store.read()
        let epoch = try XCTUnwrap(state.epochs[fixture.epochID])
        let route = try XCTUnwrap(state.routes[fixture.routeID])
        XCTAssertEqual(epoch.baseAcceptedMinutes, 145, "20 + 125 carried")
        XCTAssertEqual(epoch.lastRawThresholdMinutes, 0)
        XCTAssertEqual(route.ladderBaseMinutes, 145, "the ladder now belongs to the new base")
        let topRung = try XCTUnwrap(route.plannedEvents.map(\.thresholdMinutes).max())
        XCTAssertEqual(topRung, 35, "180 - 145 minutes remain")
        XCTAssertEqual(
            route.ladderBaseMinutes! + topRung, 180,
            "the invariant: base + top rung == the pool"
        )
    }

    /// The dead-zone fix this absorb exists for must survive: the first rung
    /// after a re-arm has to advance the ledger, not repeat it.
    func testAbsorbStillRemovesTheDeadZoneAfterARearm() throws {
        let fixture = try LadderFixture.healthy(epochBase: 20, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.recordThreshold(125, terminal: .succeeded)
        try fixture.store.absorbCreditedProgressForRearm(
            routeID: fixture.routeID,
            owner: fixture.owner,
            trigger: "test"
        )

        // Apple's counter restarted at zero; the first new rung is t5.
        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 5, minutesAfterStart: 5),
            owner: fixture.owner
        )
        guard case .queued = outcome else { return XCTFail("expected queued, got \(outcome)") }
        XCTAssertEqual(
            try fixture.reportedMinutes(), 150,
            "five real minutes after a 145-minute ledger must report 150, not 145"
        )
    }

    /// Repeated absorbs must not compound. On the iPad each re-arm folded the
    /// stale rung in again and drove the base to 460 against a 180 pool.
    func testRepeatedAbsorbsCannotCompoundTheBasePastThePool() throws {
        let fixture = try LadderFixture.healthy(epochBase: 20, poolMinutes: 180)
        defer { fixture.cleanup() }

        for _ in 0..<12 {
            // Each round simulates a stale rung landing on the high-water mark
            // and a re-arm folding it in — the observed compounding loop.
            try fixture.store.transaction(expectedOwner: fixture.owner) { state in
                state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 160
            }
            _ = try fixture.store.absorbCreditedProgressForRearm(
                routeID: fixture.routeID,
                owner: fixture.owner,
                trigger: "test"
            )
            let base = try XCTUnwrap(
                fixture.store.read().epochs[fixture.epochID]?.baseAcceptedMinutes
            )
            XCTAssertLessThanOrEqual(base, 180, "the base may never pass the pool")
        }
    }

    /// With nothing left above the carried base there is no ladder to cut, so the
    /// absorb must decline rather than raise a base under rungs it cannot
    /// replace — the precise state that produced the 305-minute sample.
    func testAbsorbDeclinesWhenNoRemainingLadderCanBeCut() throws {
        let fixture = try LadderFixture.healthy(epochBase: 20, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.recordThreshold(160, terminal: .succeeded)

        XCTAssertFalse(try fixture.store.absorbCreditedProgressForRearm(
            routeID: fixture.routeID,
            owner: fixture.owner,
            trigger: "test"
        ))
        let state = try fixture.store.read()
        XCTAssertEqual(state.epochs[fixture.epochID]?.baseAcceptedMinutes, 20)
        XCTAssertEqual(state.routes[fixture.routeID]?.ladderBaseMinutes, 20)
        XCTAssertEqual(
            captured.first { $0.kind == .meteringRearm }?.reason, "no_remaining"
        )
    }

    // MARK: - Self-heal for devices already broken

    /// The iPad's live state: base 145 under a ladder cut at 20 topping out at
    /// 160. Repair must prepare a fresh physical route; in-place re-arm reuses
    /// one-shot event names that Apple already delivered.
    func testCorruptedLadderPreparesFreshRouteOnTheNextRecoveryPass() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 145,
            ladderBase: nil,
            poolMinutes: 180
        )
        defer { fixture.cleanup() }

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let route = try XCTUnwrap(state.routes[handoff.toRouteID])
        let topRung = try XCTUnwrap(route.plannedEvents.map(\.thresholdMinutes).max())
        XCTAssertEqual(route.ladderBaseMinutes, 145)
        XCTAssertEqual(topRung, 35)
        XCTAssertEqual(route.ladderBaseMinutes! + topRung, 180)
        XCTAssertEqual(
            state.installWork.values.first(where: {
                $0.routeID == handoff.toRouteID
            })?.phase,
            .pendingStart,
            "the fresh ladder has to actually reach Apple"
        )
        XCTAssertEqual(
            state.installWork.values.first(where: {
                $0.routeID == handoff.toRouteID
            })?.retry.lastErrorCode,
            "physical_identity_repaired"
        )
        let repair = try XCTUnwrap(captured.first { $0.kind == .meteringRepair })
        XCTAssertEqual(repair.reason, "replacement_overrun")
        XCTAssertEqual(repair.transition?.before, "base:145+raw:0/ladder:145+160")
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
        XCTAssertEqual(state.installWork[fixture.installID]?.phase, .active)
    }

    func testRepairUsesDurableAcceptedEvidenceInsteadOfRejectedRawOrPoisonedBase() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 225,
            ladderBase: 225,
            poolMinutes: 240,
            authoritativeBase: 0,
            ladderCutFor: 225
        )
        defer { fixture.cleanup() }
        try fixture.recordEvidence(estimatedMinutes: 100, terminal: .succeeded)
        try fixture.recordEvidence(estimatedMinutes: 225, terminal: .rejected)

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let epoch = try XCTUnwrap(state.epochs[handoff.toEpochID])
        let route = try XCTUnwrap(state.routes[handoff.toRouteID])
        XCTAssertEqual(epoch.baseAcceptedMinutes, 100)
        XCTAssertEqual(epoch.lastRawThresholdMinutes, 0)
        XCTAssertEqual(route.ladderBaseMinutes, 100)
        XCTAssertEqual(route.plannedEvents.map(\.thresholdMinutes).max(), 140)
    }

    /// DeviceActivity threshold events are one-shot under their physical
    /// activity/event names. Re-cutting t5...t140 onto a route that already
    /// delivered those names leaves a daemon-perfect route that never fires.
    /// Physical repair therefore has to mint a fresh route and epoch while the
    /// old route remains authoritative until make-before-break completes.
    func testRepairMintsFreshPhysicalIdentityAndIsRestartIdempotent() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 225,
            ladderBase: 225,
            poolMinutes: 240,
            authoritativeBase: 0,
            ladderCutFor: 225
        )
        defer { fixture.cleanup() }
        try fixture.recordEvidence(estimatedMinutes: 100, terminal: .succeeded)
        try fixture.recordEvidence(estimatedMinutes: 225, terminal: .rejected)
        let repairAt = fixture.start.addingTimeInterval(4 * 60 * 60)

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: repairAt
        ))

        let first = try fixture.store.read()
        let handoff = try XCTUnwrap(first.v2RouteHandoff)
        XCTAssertEqual(first.activeEpochID, fixture.epochID)
        XCTAssertEqual(first.activeRouteID, fixture.routeID)
        XCTAssertEqual(handoff.fromEpochID, fixture.epochID)
        XCTAssertEqual(handoff.fromRouteID, fixture.routeID)
        XCTAssertNotEqual(handoff.toEpochID, fixture.epochID)
        XCTAssertNotEqual(handoff.toRouteID, fixture.routeID)
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)

        let candidateEpoch = try XCTUnwrap(first.epochs[handoff.toEpochID])
        let candidateRoute = try XCTUnwrap(first.routes[handoff.toRouteID])
        XCTAssertEqual(candidateEpoch.baseAcceptedMinutes, 100)
        XCTAssertEqual(candidateEpoch.startedAt, repairAt)
        XCTAssertEqual(candidateRoute.generationID, fixture.generationID)
        XCTAssertEqual(candidateRoute.ladderBaseMinutes, 100)
        XCTAssertEqual(candidateRoute.plannedEvents.map(\.thresholdMinutes).max(), 140)
        XCTAssertNotEqual(
            candidateRoute.activityName,
            first.routes[fixture.routeID]?.activityName
        )
        XCTAssertTrue(candidateRoute.plannedEvents.allSatisfy {
            $0.eventName.contains(handoff.toRouteID.uuidString.lowercased())
        })
        XCTAssertEqual(
            first.installWork.values.first(where: {
                $0.routeID == handoff.toRouteID
            })?.phase,
            .pendingStart
        )
        XCTAssertEqual(
            first.installWork.values.first(where: {
                $0.routeID == fixture.routeID
            })?.phase,
            .active,
            "the prior physical route stays live until the candidate verifies"
        )

        XCTAssertFalse(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: repairAt.addingTimeInterval(10)
        ))
        let replay = try fixture.store.read()
        XCTAssertEqual(replay.v2RouteHandoff?.toEpochID, handoff.toEpochID)
        XCTAssertEqual(replay.v2RouteHandoff?.toRouteID, handoff.toRouteID)
    }

    /// A watchdog repair must never restart a route whose deterministic sample
    /// IDs have already been accepted. The iPad re-kicked the same t20 identity
    /// after carrying 65 minutes into the base, so the callback was correctly
    /// deduplicated and the bar stayed frozen.
    func testMissingDaemonRouteRecoveryMintsFreshPhysicalIdentity() throws {
        let fixture = try LadderFixture.healthy(epochBase: 0, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.recordThreshold(65, terminal: .succeeded)
        let repairAt = fixture.start.addingTimeInterval(2 * 60 * 60)

        XCTAssertTrue(try fixture.store.replaceMissingActiveRouteIfNeeded(
            owner: fixture.owner,
            missingRouteID: fixture.routeID,
            now: repairAt
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let candidateEpoch = try XCTUnwrap(state.epochs[handoff.toEpochID])
        let candidateRoute = try XCTUnwrap(state.routes[handoff.toRouteID])
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
        XCTAssertNotEqual(candidateRoute.routeID, fixture.routeID)
        XCTAssertNotEqual(
            candidateRoute.activityName,
            state.routes[fixture.routeID]?.activityName
        )
        XCTAssertEqual(candidateEpoch.baseAcceptedMinutes, 65)
        XCTAssertEqual(candidateRoute.ladderBaseMinutes, 65)
        XCTAssertEqual(candidateRoute.plannedSchedule.intervalStartAt, repairAt)
        XCTAssertTrue(candidateRoute.plannedEvents.allSatisfy {
            $0.eventName.contains(candidateRoute.routeID.uuidString.lowercased())
        })
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)
    }

    func testMissingDaemonRouteRecoveryDoesNotMintAgainWhileHandoffIsInFlight() throws {
        let fixture = try LadderFixture.healthy(epochBase: 0, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.recordThreshold(65, terminal: .succeeded)

        XCTAssertTrue(try fixture.store.replaceMissingActiveRouteIfNeeded(
            owner: fixture.owner,
            missingRouteID: fixture.routeID,
            now: fixture.start.addingTimeInterval(60)
        ))
        let first = try XCTUnwrap(fixture.store.read().v2RouteHandoff)

        XCTAssertFalse(try fixture.store.replaceMissingActiveRouteIfNeeded(
            owner: fixture.owner,
            missingRouteID: fixture.routeID,
            now: fixture.start.addingTimeInterval(120)
        ))
        let replay = try XCTUnwrap(fixture.store.read().v2RouteHandoff)
        XCTAssertEqual(replay.toEpochID, first.toEpochID)
        XCTAssertEqual(replay.toRouteID, first.toRouteID)
    }

    func testMissingDaemonRouteRecoveryRejectsAStaleRouteObservation() throws {
        let fixture = try LadderFixture.healthy(epochBase: 0, poolMinutes: 180)
        defer { fixture.cleanup() }

        XCTAssertFalse(try fixture.store.replaceMissingActiveRouteIfNeeded(
            owner: fixture.owner,
            missingRouteID: UUID(),
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        XCTAssertNil(state.v2RouteHandoff)
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
        XCTAssertEqual(state.routes.count, 1)
    }

    func testRepairNormalizesVerifiedInstallForLogicallyActivePriorRoute() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 225,
            ladderBase: 225,
            poolMinutes: 240,
            authoritativeBase: 100,
            ladderCutFor: 225,
            installPhase: .verified
        )
        defer { fixture.cleanup() }
        try fixture.recordEvidence(estimatedMinutes: 100, terminal: .succeeded)

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
        XCTAssertEqual(state.routes[fixture.routeID]?.lifecycle, .active)
        XCTAssertEqual(
            state.installWork[fixture.installID]?.phase,
            .active,
            "a logically active prior must be eligible for make-before-break cutover"
        )
    }

    /// Exact persisted iPad shape after the old in-place ladder repair:
    /// base and ladder are numerically consistent, but the install row records
    /// `ladder_base_repaired` and this same route already has accepted samples.
    /// Its one-shot event names have therefore been consumed.
    func testInPlaceLadderRepairMintsFreshPhysicalIdentityEvenWhenLadderIsConsistent() throws {
        let fixture = try LadderFixture.healthy(epochBase: 100, poolMinutes: 240)
        defer { fixture.cleanup() }
        try fixture.recordEvidence(estimatedMinutes: 100, terminal: .succeeded)
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.installWork[fixture.installID]?.phase = .verified
            state.installWork[fixture.installID]?.retry.lastErrorCode = "ladder_base_repaired"
        }
        let repairAt = fixture.start.addingTimeInterval(3 * 60 * 60)

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: repairAt
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let candidate = try XCTUnwrap(state.routes[handoff.toRouteID])
        XCTAssertNotEqual(handoff.toRouteID, fixture.routeID)
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(candidate.ladderBaseMinutes, 100)
        XCTAssertEqual(
            candidate.plannedSchedule.intervalStartAt,
            repairAt,
            "the fresh activity counts only usage after its own physical birth"
        )
        XCTAssertEqual(state.activeRouteID, fixture.routeID)
    }

    /// A base that has already compounded past the whole pool (iPad reached 460
    /// of 180) must be pulled back to a self-consistent value, not left alone
    /// because no ladder can be cut above it.
    func testInflatedBaseIsPulledBackToThePoolEvenWhenNoLadderRemains() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 460,
            ladderBase: nil,
            poolMinutes: 180
        )
        defer { fixture.cleanup() }

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start
        ))

        let state = try fixture.store.read()
        XCTAssertEqual(
            state.epochs[fixture.epochID]?.baseAcceptedMinutes, 180,
            "460 minutes of a 180-minute pool is not a number the store may keep"
        )
        XCTAssertEqual(state.routes[fixture.routeID]?.ladderBaseMinutes, 180)
        XCTAssertEqual(
            captured.first { $0.kind == .meteringRepair }?.reason, "clamped_exhausted"
        )
    }

    /// The clamp deliberately leaves the stale rungs armed, so it cannot clear
    /// its own trigger. Without an explicit "already clamped" exit the next
    /// recovery pass repairs the identical state forever — measured on the iPad
    /// 2026-07-25 as 45 records in three minutes, every one `before == after`.
    func testClampedExhaustedStateIsRepairedOnlyOnce() throws {
        let fixture = try LadderFixture.corrupted(
            epochBase: 460,
            ladderBase: nil,
            poolMinutes: 180
        )
        defer { fixture.cleanup() }

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start
        ))
        let afterFirst = try fixture.store.read()
        let recordsAfterFirst = captured.filter { $0.kind == .meteringRepair }.count

        for _ in 0..<5 {
            XCTAssertFalse(
                try fixture.store.repairLadderBaseInvariantIfNeeded(
                    owner: fixture.owner,
                    now: fixture.start
                ),
                "an already-clamped route must report nothing left to repair"
            )
        }

        XCTAssertEqual(
            captured.filter { $0.kind == .meteringRepair }.count, recordsAfterFirst,
            "a no-op repair must not keep writing to the flight recorder"
        )
        let afterRepeats = try fixture.store.read()
        XCTAssertEqual(
            afterRepeats.epochs[fixture.epochID]?.baseAcceptedMinutes,
            afterFirst.epochs[fixture.epochID]?.baseAcceptedMinutes
        )
        XCTAssertEqual(
            afterRepeats.routes[fixture.routeID]?.ladderBaseMinutes,
            afterFirst.routes[fixture.routeID]?.ladderBaseMinutes
        )
    }

    func testAConsistentLadderIsLeftAloneAndRecordsNothing() throws {
        let fixture = try LadderFixture.healthy(epochBase: 20, poolMinutes: 180)
        defer { fixture.cleanup() }
        let before = try fixture.store.read()

        XCTAssertFalse(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start
        ))
        XCTAssertEqual(try fixture.store.read().routes, before.routes)
        XCTAssertTrue(captured.filter { $0.kind == .meteringRepair }.isEmpty)
    }

    /// A successful rung advances the durable estimate without changing the
    /// ladder base. The repair pass must compare that evidence with
    /// `base + raw`, not with the base alone; otherwise every accepted rung
    /// mints a new physical identity and resets Apple's counter.
    func testAcceptedRungDoesNotTriggerLadderIdentityRepair() throws {
        let fixture = try LadderFixture.healthy(epochBase: 195, poolMinutes: 240)
        defer { fixture.cleanup() }
        try fixture.recordEvidence(
            estimatedMinutes: 200,
            rawThresholdMinutes: 5,
            terminal: .succeeded
        )
        let before = try fixture.store.read()

        XCTAssertFalse(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(5 * 60)
        ))

        let after = try fixture.store.read()
        XCTAssertEqual(after.activeEpochID, before.activeEpochID)
        XCTAssertEqual(after.activeRouteID, before.activeRouteID)
        XCTAssertNil(after.v2RouteHandoff)
        XCTAssertTrue(captured.filter { $0.kind == .meteringRepair }.isEmpty)
    }

    /// Recovery checks the ladder before it drains network work. A callback
    /// queued while offline is not rejected evidence, so it must keep the
    /// current physical identity until the backend reaches a terminal verdict.
    func testPendingRungDoesNotTriggerLadderIdentityRepair() throws {
        let fixture = try LadderFixture.healthy(epochBase: 195, poolMinutes: 240)
        defer { fixture.cleanup() }
        try fixture.recordEvidence(
            estimatedMinutes: 200,
            rawThresholdMinutes: 5,
            terminal: .pending
        )
        let before = try fixture.store.read()

        XCTAssertFalse(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(5 * 60)
        ))

        let after = try fixture.store.read()
        XCTAssertEqual(after.activeEpochID, before.activeEpochID)
        XCTAssertEqual(after.activeRouteID, before.activeRouteID)
        XCTAssertNil(after.v2RouteHandoff)
        XCTAssertTrue(captured.filter { $0.kind == .meteringRepair }.isEmpty)
    }

    func testTooEarlyCallbackMarksPhysicalRouteConsumedWithoutCreditingUsage() throws {
        let fixture = try LadderFixture.healthy(epochBase: 215, poolMinutes: 240)
        defer { fixture.cleanup() }

        // 2 minutes after arm: outside the FIX-Q calibration grace (90s), but
        // still earlier than the 5-minute rung's physical-time bound — the
        // anti-cheat death stamp must survive for this case.
        let outcome = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 5, minutesAfterStart: 2),
            owner: fixture.owner
        )

        XCTAssertEqual(outcome, .discarded(reason: "too_early"))
        let state = try fixture.store.read()
        XCTAssertEqual(state.epochs[fixture.epochID]?.baseAcceptedMinutes, 215)
        XCTAssertEqual(state.epochs[fixture.epochID]?.lastRawThresholdMinutes, 0)
        XCTAssertTrue(state.sampleWork.isEmpty)
        XCTAssertEqual(
            state.installWork[fixture.installID]?.retry.lastErrorCode,
            "physical_events_consumed_too_early"
        )
    }

    func testConsumedPhysicalRouteMintsFreshIdentityRecovery() throws {
        let fixture = try LadderFixture.healthy(epochBase: 215, poolMinutes: 240)
        defer { fixture.cleanup() }
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.installWork[fixture.installID]?.retry.lastErrorCode =
                "physical_events_consumed_too_early"
        }

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(handoff.fromRouteID, fixture.routeID)
        XCTAssertNotEqual(handoff.toRouteID, fixture.routeID)
        XCTAssertEqual(handoff.explicitRecovery, .identityRecovery)
        XCTAssertEqual(state.routes[handoff.toRouteID]?.ladderBaseMinutes, 215)
        XCTAssertEqual(
            state.installWork.values.first(where: {
                $0.routeID == handoff.toRouteID
            })?.phase,
            .pendingStart
        )
    }

    /// FIX-Q's arm-grace absorption swallows burst bells into the exclusion
    /// high-water without a death stamp. When the burst reaches the TOP rung
    /// every one-shot has fired and no future bell can credit — the deaf
    /// ladder must trigger the same fresh-identity re-cut the death stamp
    /// used to (iPad 2026-08-06 00:03: 21 bells absorbed up to the terminal
    /// t40, bar dead until the next manual re-arm).
    func testGraceAbsorbedWholeLadderMintsFreshIdentityRecovery() throws {
        let fixture = try LadderFixture.healthy(epochBase: 25, poolMinutes: 65)
        defer { fixture.cleanup() }
        let topRung = try XCTUnwrap(
            try fixture.store.read().routes[fixture.routeID]?
                .plannedEvents.map(\.thresholdMinutes).max()
        )
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            guard var epoch = state.epochs[fixture.epochID] else { return }
            epoch.lastRawThresholdMinutes = topRung
            epoch.excludedWhilePausedMinutes = topRung
            state.epochs[fixture.epochID] = epoch
        }

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        XCTAssertEqual(handoff.fromRouteID, fixture.routeID)
        XCTAssertNotEqual(handoff.toRouteID, fixture.routeID)
        XCTAssertEqual(state.routes[handoff.toRouteID]?.ladderBaseMinutes, 25)
    }

    /// A partial arm-time burst leaves later bells alive, but it also consumes
    /// part of the physical distance to the terminal event. Keeping that route
    /// would fire its terminal N minutes before the logical ledger reaches the
    /// pool ceiling (iPad 2026-08-21: base 65, t115, excluded 25 => 155/180).
    /// Re-cut on a fresh identity with every physical threshold shifted by N.
    func testPartialGraceAbsorptionOffsetsFreshPhysicalRouteTerminal() throws {
        let fixture = try LadderFixture.healthy(epochBase: 65, poolMinutes: 180)
        defer { fixture.cleanup() }

        XCTAssertEqual(
            try fixture.store.enqueueAuthorizedV2Callback(
                fixture.input(threshold: 25, minutesAfterStart: 0),
                owner: fixture.owner
            ),
            .discarded(reason: "arm_grace_calibration")
        )
        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        let handoff = try XCTUnwrap(state.v2RouteHandoff)
        let candidateEpoch = try XCTUnwrap(state.epochs[handoff.toEpochID])
        let candidateRoute = try XCTUnwrap(state.routes[handoff.toRouteID])
        XCTAssertEqual(candidateEpoch.baseAcceptedMinutes, 65)
        XCTAssertEqual(candidateEpoch.excludedWhilePausedMinutes, 25)
        XCTAssertEqual(candidateEpoch.lastRawThresholdMinutes, 25)
        XCTAssertEqual(candidateRoute.physicalGenerationOffsetMinutes, 25)
        XCTAssertEqual(candidateRoute.plannedEvents.map(\.thresholdMinutes).max(), 140)
    }

    func testRepeatedArmCalibrationAccumulatesRoutePhysicalOffset() throws {
        let fixture = try LadderFixture.healthy(epochBase: 65, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.routes[fixture.routeID]?.physicalGenerationOffsetMinutes = 25
            state.routes[fixture.routeID]?.plannedEvents = try XCTUnwrap(
                MeteringLadderMath.plannedEvents(
                    routeID: fixture.routeID,
                    ladderBaseMinutes: 65,
                    ceilingMinutes: 180,
                    physicalGenerationOffsetMinutes: 25
                )
            )
            state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 30
            state.epochs[fixture.epochID]?.excludedWhilePausedMinutes = 30
            let installID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == fixture.routeID })?.key
            )
            state.installWork[installID]?.retry.lastErrorCode =
                "arm_grace_calibration_requires_offset_recut"
        }

        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        let candidateID = try XCTUnwrap(state.v2RouteHandoff?.toRouteID)
        let candidate = try XCTUnwrap(state.routes[candidateID])
        XCTAssertEqual(candidate.physicalGenerationOffsetMinutes, 30)
        XCTAssertEqual(candidate.plannedEvents.map(\.thresholdMinutes).max(), 145)
    }

    func testLatePriorRouteCallbackDoesNotUseCandidatePhysicalOffset() throws {
        let fixture = try LadderFixture.healthy(epochBase: 65, poolMinutes: 180)
        defer { fixture.cleanup() }
        _ = try fixture.store.enqueueAuthorizedV2Callback(
            fixture.input(threshold: 25, minutesAfterStart: 0),
            owner: fixture.owner
        )
        XCTAssertTrue(try fixture.store.repairLadderBaseInvariantIfNeeded(
            owner: fixture.owner,
            now: fixture.start.addingTimeInterval(60)
        ))

        let state = try fixture.store.read()
        let candidateID = try XCTUnwrap(state.v2RouteHandoff?.toRouteID)
        XCTAssertNil(state.routes[fixture.routeID]?.physicalGenerationOffsetMinutes)
        XCTAssertEqual(state.routes[candidateID]?.physicalGenerationOffsetMinutes, 25)
        XCTAssertEqual(
            try fixture.store.enqueueAuthorizedV2Callback(
                fixture.input(threshold: 30, minutesAfterStart: 5),
                owner: fixture.owner
            ),
            .discarded(reason: "too_early")
        )
    }

    // MARK: - Ladder shape (#94)

    func testLadderLeadsWithOneSacrificialMinuteRungThenFiveMinuteSteps() {
        XCTAssertEqual(
            MeteringLadderMath.thresholds(remainingMinutes: 40),
            [1, 5, 10, 15, 20, 25, 30, 35, 40]
        )
    }

    func testLadderKeepsFineLeadWithinTheGuardEventBudget() {
        let cut = MeteringLadderMath.thresholds(remainingMinutes: 240)
        XCTAssertEqual(cut.first, 1)
        XCTAssertLessThanOrEqual(cut.count, MeteringLadderMath.guardEventCount)
        XCTAssertEqual(cut.last, 240)
    }

    func testPhysicalOffsetMovesEventsWithoutChangingLogicalLadder() throws {
        let events = try XCTUnwrap(MeteringLadderMath.plannedEvents(
            routeID: UUID(),
            ladderBaseMinutes: 65,
            ceilingMinutes: 180,
            physicalGenerationOffsetMinutes: 25
        ))
        XCTAssertEqual(events.first?.thresholdMinutes, 26)
        XCTAssertEqual(events.last?.thresholdMinutes, 140)
        XCTAssertEqual(
            events.map { $0.thresholdMinutes - 25 },
            MeteringLadderMath.thresholds(remainingMinutes: 115)
        )
    }
}

// MARK: - Fixture

private final class LadderFixture {
    let owner = UUID()
    let generationID = UUID()
    let epochID = UUID()
    let routeID = UUID()
    let installID = UUID()
    let start = Date(timeIntervalSince1970: 1_784_937_600)
    let storeURL: URL
    let store: DeviceEpochStore

    private init() {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladder-invariant-\(UUID().uuidString).json")
        let owner = self.owner
        store = DeviceEpochStore(
            fileURL: storeURL,
            lock: LadderLock(),
            ownerProvider: { owner }
        )
    }

    /// A route whose ladder was cut for its own epoch base — the shape every
    /// route should have.
    static func healthy(epochBase: Int, poolMinutes: Int) throws -> LadderFixture {
        try make(epochBase: epochBase, ladderBase: epochBase, poolMinutes: poolMinutes)
    }

    /// A route carrying a ladder cut for base 20 (rungs 5…160) under an epoch
    /// whose base has since moved — the iPad's live state.
    static func corrupted(
        epochBase: Int,
        ladderBase: Int?,
        poolMinutes: Int,
        authoritativeBase: Int? = nil,
        ladderCutFor: Int = 20,
        installPhase: ActivityInstallPhase = .active
    ) throws -> LadderFixture {
        try make(
            epochBase: epochBase,
            ladderBase: ladderBase,
            poolMinutes: poolMinutes,
            ladderCutFor: ladderCutFor,
            authoritativeBase: authoritativeBase,
            installPhase: installPhase
        )
    }

    private static func make(
        epochBase: Int,
        ladderBase: Int?,
        poolMinutes: Int,
        ladderCutFor: Int? = nil,
        authoritativeBase: Int? = nil,
        installPhase: ActivityInstallPhase = .active
    ) throws -> LadderFixture {
        let fixture = LadderFixture()
        let cutFor = ladderCutFor ?? epochBase
        let thresholds = MeteringLadderMath.thresholds(remainingMinutes: poolMinutes - cutFor)
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state = fixture.state(
                epochBase: epochBase,
                ladderBase: ladderBase,
                poolMinutes: poolMinutes,
                thresholds: thresholds
            )
            state.installWork[fixture.installID]?.phase = installPhase
            let registrationID = UUID()
            state.registrationWork[registrationID] = EpochRegistrationWork(
                workID: registrationID,
                ownerChildDeviceID: fixture.owner,
                epochID: fixture.epochID,
                routeID: fixture.routeID,
                request: EpochRegistrationRequestDTO(
                    protocolVersion: 2,
                    epochID: fixture.epochID,
                    deviceID: fixture.owner,
                    usageDate: "2026-07-18",
                    timezone: "America/New_York",
                    policyRevision: "policy-1",
                    measurementSelectionDigest: state.generations[fixture.generationID]!.measurementSelectionDigest,
                    enforcementSetID: state.generations[fixture.generationID]!.enforcementSetID,
                    startedAt: fixture.start,
                    baseAcceptedMinutes: authoritativeBase ?? min(epochBase, poolMinutes),
                    reason: .initial
                ),
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: fixture.start,
                    lastErrorCode: nil,
                    terminal: .succeeded
                ),
                createdAt: fixture.start
            )
        }
        return fixture
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func input(threshold: Int, minutesAfterStart: Int) -> MeteringAuthorizedCallbackInput {
        let observedAt = start.addingTimeInterval(TimeInterval(minutesAfterStart * 60))
        return MeteringAuthorizedCallbackInput(
            routeID: routeID,
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            eventName: MeteringRouteNamespace.eventName(
                routeID: routeID,
                thresholdMinutes: threshold
            ),
            namespace: MeteringRouteNamespace.prefix,
            thresholdMinutes: threshold,
            observedAt: observedAt,
            now: observedAt,
            jitterSeconds: EarnedMeteringCallback.defaultJitterSeconds
        )
    }

    /// The `estimatedMinutes` the currently pending sample will send to the
    /// backend. Fixtures may also retain succeeded evidence used to seed the
    /// authoritative base.
    func reportedMinutes() throws -> Int? {
        try store.read().sampleWork.values.first(where: {
            $0.retry.terminal == .pending
        })?.request.estimatedMinutes
    }

    func recordThreshold(
        _ threshold: Int,
        terminal: MeteringWorkTerminal
    ) throws {
        let outcome = try store.enqueueAuthorizedV2Callback(
            input(threshold: threshold, minutesAfterStart: threshold),
            owner: owner
        )
        guard case let .queued(workID) = outcome else {
            throw NSError(
                domain: "MeteringLadderBaseInvariantTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "expected queued threshold \(threshold), got \(outcome)",
                ]
            )
        }
        try store.transaction(expectedOwner: owner) { state in
            state.sampleWork[workID]?.retry.terminal = terminal
        }
    }

    func recordEvidence(
        estimatedMinutes: Int,
        rawThresholdMinutes: Int? = nil,
        terminal: MeteringWorkTerminal
    ) throws {
        try store.transaction(expectedOwner: owner) { state in
            let workID = UUID()
            let rawThreshold = rawThresholdMinutes ?? estimatedMinutes
            state.sampleWork[workID] = EpochSampleWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: EpochSampleRequestDTO(
                    deviceID: owner,
                    usageDate: "2026-07-18",
                    timezone: "America/New_York",
                    activityName: MeteringRouteNamespace.activityName(routeID: routeID),
                    eventName: MeteringRouteNamespace.eventName(
                        routeID: routeID,
                        thresholdMinutes: rawThreshold
                    ),
                    thresholdMinutes: rawThreshold,
                    estimatedMinutes: estimatedMinutes,
                    observedAt: start.addingTimeInterval(TimeInterval(rawThreshold * 60)),
                    clientSampleID: "evidence:\(workID.uuidString.lowercased())",
                    protocolVersion: 2,
                    epochID: epochID,
                    generationArmedAt: nil,
                    generationOffsetMinutes: nil
                ),
                authorization: .v2Deliverable,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: terminal == .rejected ? "implausible_threshold" : nil,
                    terminal: terminal
                ),
                createdAt: start
            )
            let currentRaw = state.epochs[epochID]?.lastRawThresholdMinutes ?? 0
            state.epochs[epochID]?.lastRawThresholdMinutes = max(currentRaw, rawThreshold)
        }
    }

    private func state(
        epochBase: Int,
        ladderBase: Int?,
        poolMinutes: Int,
        thresholds: [Int]
    ) -> DeviceEpochStoreState {
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: Data([1])
            ),
            enforcementSetID: UUID(),
            measurementSelectionBytes: Data([1]),
            createdAt: start,
            retiredAt: nil,
            configuredPoolMinutes: poolMinutes,
            configuredDeviceCapMinutes: poolMinutes
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: 2,
            childDeviceID: owner,
            usageDate: "2026-07-18",
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: generation.measurementSelectionDigest,
            enforcementSetID: generation.enforcementSetID,
            startedAt: start,
            registeredAt: start,
            baseAcceptedMinutes: epochBase,
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
            timezoneIdentifier: generation.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let plans = thresholds.map { threshold in
            MeteringEventPlan(
                eventName: MeteringRouteNamespace.eventName(
                    routeID: routeID,
                    thresholdMinutes: threshold
                ),
                thresholdMinutes: threshold
            )
        }
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
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: plans,
            installedEvents: plans,
            lifecycle: .active,
            createdAt: start,
            ladderBaseMinutes: ladderBase
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

private final class LadderLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
