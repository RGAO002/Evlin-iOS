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

    func testAbsorbRecutsTheLadderForTheCarriedBaseInTheSameTransaction() throws {
        let fixture = try LadderFixture.healthy(epochBase: 20, poolMinutes: 180)
        defer { fixture.cleanup() }
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 125
        }

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
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 125
        }
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
        try fixture.store.transaction(expectedOwner: fixture.owner) { state in
            state.epochs[fixture.epochID]?.lastRawThresholdMinutes = 160
        }

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
    /// 160. A device in this state cannot recover on its own — nothing re-cuts a
    /// planned ladder — so the recovery pass has to.
    func testCorruptedLadderIsRecutAndRearmedOnTheNextRecoveryPass() throws {
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
        let route = try XCTUnwrap(state.routes[fixture.routeID])
        let topRung = try XCTUnwrap(route.plannedEvents.map(\.thresholdMinutes).max())
        XCTAssertEqual(route.ladderBaseMinutes, 145)
        XCTAssertEqual(topRung, 35)
        XCTAssertEqual(route.ladderBaseMinutes! + topRung, 180)
        XCTAssertEqual(
            state.installWork[fixture.installID]?.phase, .pendingStart,
            "the corrected ladder has to actually reach Apple"
        )
        XCTAssertEqual(
            state.installWork[fixture.installID]?.retry.lastErrorCode,
            "ladder_base_repaired"
        )
        let repair = try XCTUnwrap(captured.first { $0.kind == .meteringRepair })
        XCTAssertEqual(repair.reason, "recut_overrun")
        XCTAssertEqual(repair.transition?.before, "base:145+raw:0/ladder:145+160")

        // And the rungs Apple still holds from the old ladder are now refused
        // outright rather than credited at 295 minutes.
        XCTAssertEqual(
            try fixture.store.enqueueAuthorizedV2Callback(
                fixture.input(threshold: 150, minutesAfterStart: 150),
                owner: fixture.owner
            ),
            .discarded(reason: "route_provenance_mismatch")
        )
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
        poolMinutes: Int
    ) throws -> LadderFixture {
        try make(
            epochBase: epochBase,
            ladderBase: ladderBase,
            poolMinutes: poolMinutes,
            ladderCutFor: 20
        )
    }

    private static func make(
        epochBase: Int,
        ladderBase: Int?,
        poolMinutes: Int,
        ladderCutFor: Int? = nil
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

    /// The `estimatedMinutes` the one queued sample will send to the backend.
    func reportedMinutes() throws -> Int? {
        try store.read().sampleWork.values.first?.request.estimatedMinutes
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
