import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

/// Regression, iPhone 2026-07-25 — sixteen hours without a single metered
/// minute, reproduced from the device's own black box.
///
/// The device held two mutually blocking legs:
///
///  1. **The midnight leg was nailed to a dead policy revision.** Canonical
///     rollover picks the next planned route *inside the same generation*, so
///     it targeted yesterday's generation whose `policyRevision` the backend had
///     already replaced. Every registration attempt came back
///     `409 policy_revision_mismatch`, the registration work went terminal, and
///     `enqueueRolloverRegistrationIfNeeded` immediately minted another one —
///     a hot loop that could never converge. The handoff parked on
///     `cutoverReady` forever.
///  2. **The replacement leg could never run.** `performRecovery` returns early
///     whenever `recoverCanonicalRolloverIfPresent` reports an unfinished
///     rollover, so `prepareReplacementIfNeeded` was never reached — and it
///     additionally requires `v2RouteHandoff == nil`, which the wedged rollover
///     handoff violated.
///
/// Net effect: the day could not finish and the new policy could not take over.
/// The device stayed on yesterday forever. This is the mechanism behind the
/// long-standing "fine in the morning, dead the moment a parent changes
/// anything" report.
@MainActor
final class MeteringSupersededRolloverRecoveryTests: XCTestCase {
    private let owner = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let timezone = "America/New_York"
    private let staleRevision = "rev-yesterday-74894ea0"
    private let currentRevision = "rev-today-f8ab2929"
    /// 2026-07-17 20:00 EDT — canonical usage date "2026-07-17".
    private let yesterdayInstant = Date(timeIntervalSince1970: 1_784_332_800)
    /// 2026-07-18 20:30 EDT — canonical usage date "2026-07-18".
    private let todayInstant = Date(timeIntervalSince1970: 1_784_332_800 + 86_400 + 1_800)
    private let yesterday = "2026-07-17"
    private let today = "2026-07-18"

    private var storeURL: URL!
    private var store: DeviceEpochStore!
    private var enforcementSetID: UUID!
    private var selectionBytes: Data!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-superseded-rollover-\(UUID().uuidString).json")
        store = DeviceEpochStore(
            fileURL: storeURL,
            ownerProvider: { self.owner },
            legacyDefaults: nil
        )
        enforcementSetID = UUID()
        selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
        store = nil
        storeURL = nil
    }


    // MARK: - Terminal replacement activation (2026-08-11 iPad wedge)

    /// A cutoverReady handoff whose candidate activation went terminal with a
    /// RECOVERABLE code had no way forward: the conservative and superseded
    /// abandon paths require their own shapes, and a plain rollover matched
    /// neither — the handoff squatted in cutoverReady while the watchdog filed
    /// `handoff_stuck_cutoverReady` for hours. The reopen leg puts the same
    /// candidate back to pending; once the backend answers, the cutover
    /// completes with no fresh identity minted.
    func testTerminalReplacementActivationReopensAndCompletes() async throws {
        center = RecordingCenter()
        let inner = RevisionAwareTransport(
            acceptedRevision: staleRevision,
            owner: owner,
            usageDate: today
        )
        let failing = FailingActivationTransport(inner: inner, failures: 1)
        transport = inner

        let plan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: yesterday,
            generationKey: generationKey(revision: staleRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: yesterdayInstant
        ))
        let yesterdayRouteID = try XCTUnwrap(plan.routeIDsByUsageDate[yesterday])
        let todayRouteID = try XCTUnwrap(plan.routeIDsByUsageDate[today])
        let seeded = try store.read()
        let yesterdayEpochID = try XCTUnwrap(seeded.routes[yesterdayRouteID]?.epochID)
        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = plan.generationID
            state.activeEpochID = yesterdayEpochID
            state.activeRouteID = yesterdayRouteID
            state.routes[yesterdayRouteID]?.lifecycle = .active
            state.epochs[yesterdayEpochID]?.registeredAt = self.yesterdayInstant
            let activeInstallID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == yesterdayRouteID })?.key
            )
            state.installWork[activeInstallID]?.authorization = .registered
            state.installWork[activeInstallID]?.phase = .active
            state.installWork[activeInstallID]?.retry.terminal = .succeeded
            let activeRegistrationID = try XCTUnwrap(
                state.registrationWork.first(where: { $0.value.routeID == yesterdayRouteID })?.key
            )
            state.registrationWork[activeRegistrationID]?.retry.terminal = .succeeded
            let futureInstallID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == todayRouteID })?.key
            )
            var installedRoute = try XCTUnwrap(state.routes[todayRouteID])
            installedRoute.installedSchedule = installedRoute.plannedSchedule
            installedRoute.installedEvents = installedRoute.plannedEvents
            state.routes[todayRouteID] = installedRoute
            state.installWork[futureInstallID]?.phase = .verified
            state.installWork[futureInstallID]?.retry.terminal = .succeeded
            state.ratchets[self.owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: self.owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: self.yesterdayInstant,
                dualActiveAt: self.yesterdayInstant,
                activatedV2At: self.yesterdayInstant
            )
        }
        center.seed(DeviceActivityName(try XCTUnwrap(seeded.routes[yesterdayRouteID]?.activityName)))
        center.seed(DeviceActivityName(try XCTUnwrap(seeded.routes[todayRouteID]?.activityName)))

        // Drive the rollover into the wedge: registration succeeds (same
        // revision), the single poisoned activation goes terminal.
        var wedged = false
        for _ in 1...4 {
            try await makeDriver(transport: failing).recover(ownerChildDeviceID: owner)
            let state = try store.read()
            if let handoff = state.v2RouteHandoff,
               handoff.phase == .cutoverReady,
               state.activationWork.values.contains(where: {
                   $0.routeID == handoff.toRouteID
                       && $0.retry.terminal != .pending
                       && $0.retry.terminal != .succeeded
                       && $0.retry.lastErrorCode == "epoch_not_active"
               }) {
                wedged = true
                break
            }
            if state.activeRouteID == todayRouteID {
                break
            }
        }
        // The reopen leg runs INSIDE the recovery pass, so observing the
        // wedge mid-flight is timing-dependent; what must hold is the end
        // state below. But if we never even saw a terminal activation and
        // never completed, the fixture failed to reproduce the disease.
        _ = wedged

        for pass in 1...6 {
            // The reopened activation carries a real backoff; a frozen clock
            // would skip it forever, so completion passes run later.
            try await makeDriver(
                now: todayInstant.addingTimeInterval(TimeInterval(600 * pass)),
                transport: failing
            ).recover(ownerChildDeviceID: owner)
            let st = try store.read()
            if st.activeRouteID == todayRouteID { break }
            XCTAssertLessThan(pass, 6, "recovery never completed the cutover")
        }
        // One settling pass: the committed handoff is collected at the TOP of
        // a pass, so the cutover and its bookkeeping never land in the same one.
        try await makeDriver(
            now: todayInstant.addingTimeInterval(4_200),
            transport: failing
        ).recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertEqual(
            state.activeRouteID, todayRouteID,
            "the reopened activation must carry the SAME candidate through — "
                + "no fresh identity, no abandoned day"
        )
        XCTAssertNil(state.v2RouteHandoff)
        XCTAssertEqual(state.routes[yesterdayRouteID]?.lifecycle, .tombstoned)
        XCTAssertGreaterThan(
            failing.failed, 0,
            "the poisoned activation never fired — the wedge was not exercised"
        )
    }

    // MARK: - The deadlock

    /// The exact wedge, end to end: yesterday still active, an unfinished
    /// rollover pinned to a superseded revision, and a live generation carrying
    /// the backend's current revision plus today's planned route.
    ///
    /// Before the fix this loops forever on yesterday. After the fix the device
    /// reaches today, on the *current* revision's generation, in a bounded
    /// number of recovery passes.
    func testSupersededRolloverYieldsSoTodayCanArmOnTheCurrentRevision() async throws {
        let fixture = try await seedSupersededRolloverDeadlock()

        // The wedge is real before we touch anything: the rollover is pending,
        // its registration was rejected for the revision, and the handoff is
        // parked on cutoverReady with yesterday still live.
        var state = try store.read()
        XCTAssertEqual(state.activeRouteID, fixture.yesterdayRouteID)
        XCTAssertEqual(state.rolloverEffectsWork?.retry.terminal, .pending)
        XCTAssertEqual(state.v2RouteHandoff?.phase, .cutoverReady)
        XCTAssertTrue(
            state.registrationWork.values.contains {
                $0.routeID == fixture.staleTodayRouteID
                    && $0.retry.lastErrorCode == "policy_revision_mismatch"
            },
            "the wedge must be caused by the backend rejecting the dead revision"
        )

        for pass in 1...6 {
            try await makeDriver().recover(ownerChildDeviceID: owner)
            state = try store.read()
            if state.activeRouteID == fixture.currentTodayRouteID { break }
            XCTAssertLessThan(pass, 6, "recovery never reached today")
        }
        // One settling pass: the committed handoff is collected at the TOP of a
        // pass, so the cutover and its bookkeeping never land in the same one.
        try await makeDriver().recover(ownerChildDeviceID: owner)

        state = try store.read()
        XCTAssertEqual(
            state.activeRouteID,
            fixture.currentTodayRouteID,
            "the device must end up on today's route; " + Self.dump(state)
        )
        XCTAssertEqual(state.activeGenerationID, fixture.currentGenerationID)
        XCTAssertEqual(
            state.generations[try XCTUnwrap(state.activeGenerationID)]?.policyRevision,
            currentRevision,
            "today must be armed on the generation the backend actually accepts"
        )
        XCTAssertEqual(state.routes[fixture.currentTodayRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.epochs[fixture.currentTodayEpochID]?.usageDate, today)

        // The superseded midnight leg is closed, not left pending, and its
        // handoff is gone.
        XCTAssertNotEqual(state.rolloverEffectsWork?.retry.terminal, .pending)
        XCTAssertNil(state.v2RouteHandoff)

        // Yesterday's lane is terminal. Compaction may already have removed its
        // acknowledged tombstone and retired epoch from the local root.
        XCTAssertTrue(
            state.routes[fixture.yesterdayRouteID].map { $0.lifecycle == .tombstoned } ?? true
        )
        XCTAssertTrue(
            state.epochs[fixture.yesterdayEpochID].map { $0.status == .retired } ?? true
        )

        // The dead generation's today route was reclaimed rather than left
        // planned (leaving it planned re-creates the same doomed rollover on
        // the next pass).
        XCTAssertNotEqual(state.routes[fixture.staleTodayRouteID]?.lifecycle, .planned)
        XCTAssertNotEqual(state.routes[fixture.staleTodayRouteID]?.lifecycle, .active)
    }

    func testStaleDayRescueAdoptsTodayWhenPriorDaemonInstallAlreadyFailed() async throws {
        let fixture = try seedStalePhysicalPrior()
        let yesterdayActivity = DeviceActivityName(
            try XCTUnwrap(try store.read().routes[fixture.yesterdayRouteID]?.activityName)
        )

        // Match the physical iPhone state: the logical authority is still
        // yesterday, Apple's daemon has lost that activity, and unrelated old
        // registration-required installs are ahead of today's activation.
        center.stopMonitoring([yesterdayActivity])
        center.startFailures.insert(yesterdayActivity)
        try store.transaction(expectedOwner: owner) { state in
            let installID = try XCTUnwrap(
                state.installWork.first(where: {
                    $0.value.routeID == fixture.yesterdayRouteID
                })?.key
            )
            var priorRoute = try XCTUnwrap(state.routes[fixture.yesterdayRouteID])
            priorRoute.installedSchedule = priorRoute.plannedSchedule
            priorRoute.installedEvents = priorRoute.plannedEvents
            state.routes[fixture.yesterdayRouteID] = priorRoute
            state.installWork[installID]?.phase = .pendingStart
            state.installWork[installID]?.claim = nil
            state.installWork[installID]?.retry = MeteringRetryState(
                attemptCount: 9,
                nextAttemptAt: todayInstant,
                lastErrorCode: "startFailed",
                terminal: .pending
            )
        }
        center.startCalls.removeAll()
        center.stopCalls.removeAll()

        for pass in 1...8 {
            try await makeDriver().recover(ownerChildDeviceID: owner)
            let passState = try store.read()
            if passState.activeRouteID == fixture.currentTodayRouteID { break }
            XCTAssertLessThan(pass, 8, "stale physical prior prevented today's rescue")
        }
        for _ in 0..<2 {
            try await makeDriver().recover(ownerChildDeviceID: owner)
        }

        let state = try store.read()
        XCTAssertEqual(state.activeRouteID, fixture.currentTodayRouteID, Self.dump(state))
        XCTAssertEqual(state.routes[fixture.currentTodayRouteID]?.lifecycle, .active)
        XCTAssertTrue(
            state.routes[fixture.yesterdayRouteID].map { $0.lifecycle == .tombstoned } ?? true
        )
        XCTAssertNil(state.v2RouteHandoff)
        let priorInstalls = state.installWork.values.filter {
            $0.routeID == fixture.yesterdayRouteID
        }
        XCTAssertTrue(priorInstalls.allSatisfy { $0.phase == .stopped })
        XCTAssertTrue(priorInstalls.allSatisfy { $0.retry.terminal != .pending })
        if let priorInstall = priorInstalls.first {
            XCTAssertEqual(priorInstall.retry.lastErrorCode, "stale_day_prior_absent")
        }
        if let tombstone = state.tombstones[fixture.yesterdayRouteID] {
            XCTAssertNotNil(tombstone.stopAcknowledgedAt)
        }
        XCTAssertFalse(
            state.installWork.values.contains {
                $0.routeID == fixture.staleTodayRouteID
                    && $0.phase == .pendingStart
                    && $0.retry.terminal == .pending
            },
            "the superseded generation's old install must not remain due"
        )
        XCTAssertTrue(
            center.activities.contains(
                DeviceActivityName(
                    try XCTUnwrap(state.routes[fixture.currentTodayRouteID]?.activityName)
                )
            )
        )
        XCTAssertFalse(
            center.startCalls.contains(yesterdayActivity.rawValue),
            "an elapsed prior route must never be re-armed during stale-day rescue"
        )

        let startCount = center.startCalls.count
        let stopCount = center.stopCalls.count
        let settledState = try store.read()
        let settledGenerationID = settledState.activeGenerationID
        let settledEpochID = settledState.activeEpochID
        let settledRouteID = settledState.activeRouteID
        for tick in 1...36 {
            try await makeDriver(
                now: todayInstant.addingTimeInterval(Double(tick * 10))
            ).recover(ownerChildDeviceID: owner)
        }
        XCTAssertEqual(center.startCalls.count, startCount, "settled recovery must not churn starts")
        XCTAssertEqual(center.stopCalls.count, stopCount, "settled recovery must not churn stops")
        let afterPolling = try store.read()
        XCTAssertEqual(afterPolling.activeGenerationID, settledGenerationID)
        XCTAssertEqual(afterPolling.activeEpochID, settledEpochID)
        XCTAssertEqual(afterPolling.activeRouteID, settledRouteID)
        XCTAssertFalse(center.startCalls.contains(yesterdayActivity.rawValue))
    }

    // Regression (iPhone, 2026-08-02 23:59:38 EDT): a clean v2 onboarding
    // registered the initial epoch seconds before midnight, but Apple rejected
    // that day's physical activity as intervalTooShort. At midnight the horizon
    // correctly verified the next day's reserved route while activeRouteID was
    // still nil. Ordinary rollover requires an active old route and initial
    // activation requires the route to belong to activeEpochID, so neither
    // state machine could ever adopt the verified current-day route.
    func testInitialActivationCrossingMidnightAdoptsVerifiedCurrentDayRoute() async throws {
        center = RecordingCenter()
        transport = RevisionAwareTransport(
            acceptedRevision: currentRevision,
            owner: owner,
            usageDate: today
        )
        let plan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: yesterday,
            generationKey: generationKey(revision: currentRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: yesterdayInstant
        ))
        let yesterdayRouteID = try XCTUnwrap(plan.routeIDsByUsageDate[yesterday])
        let todayRouteID = try XCTUnwrap(plan.routeIDsByUsageDate[today])
        let initial = try store.read()
        let yesterdayEpochID = try XCTUnwrap(initial.routes[yesterdayRouteID]?.epochID)
        let todayEpochID = try XCTUnwrap(initial.routes[todayRouteID]?.epochID)

        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = plan.generationID
            state.activeEpochID = yesterdayEpochID
            state.activeRouteID = nil
            state.epochs[yesterdayEpochID]?.registeredAt = self.yesterdayInstant
            let yesterdayInstallID = try XCTUnwrap(
                state.installWork.first { $0.value.routeID == yesterdayRouteID }?.key
            )
            state.installWork[yesterdayInstallID]?.authorization = .registered
            state.installWork[yesterdayInstallID]?.phase = .pendingStart
            state.installWork[yesterdayInstallID]?.claim = nil
            state.installWork[yesterdayInstallID]?.retry = MeteringRetryState(
                attemptCount: 2,
                nextAttemptAt: self.todayInstant,
                lastErrorCode: "route_superseded",
                terminal: .superseded
            )
            let yesterdayRegistrationID = try XCTUnwrap(
                state.registrationWork.first { $0.value.routeID == yesterdayRouteID }?.key
            )
            state.registrationWork[yesterdayRegistrationID]?.retry.terminal = .succeeded

            let todayInstallID = try XCTUnwrap(
                state.installWork.first { $0.value.routeID == todayRouteID }?.key
            )
            var todayRoute = try XCTUnwrap(state.routes[todayRouteID])
            todayRoute.installedSchedule = todayRoute.plannedSchedule
            todayRoute.installedEvents = todayRoute.plannedEvents
            state.routes[todayRouteID] = todayRoute
            state.installWork[todayInstallID]?.authorization = .futurePlanned
            state.installWork[todayInstallID]?.phase = .verified
            state.installWork[todayInstallID]?.claim = nil
            state.installWork[todayInstallID]?.retry = MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: self.todayInstant,
                lastErrorCode: nil,
                terminal: .pending
            )
            state.ratchets[self.owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: self.owner,
                advertisedVersion: 2,
                localSelection: .v2Pending,
                registeredV2At: self.yesterdayInstant,
                dualActiveAt: nil,
                activatedV2At: nil
            )
        }
        center.seed(
            DeviceActivityName(
                try XCTUnwrap(try store.read().routes[todayRouteID]?.activityName)
            )
        )

        try await makeDriver().recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertEqual(state.activeGenerationID, plan.generationID)
        XCTAssertEqual(state.activeEpochID, todayEpochID)
        XCTAssertEqual(state.activeRouteID, todayRouteID, Self.dump(state))
        XCTAssertEqual(state.routes[todayRouteID]?.lifecycle, .active)
        XCTAssertEqual(state.ratchets[owner]?.localSelection, .v2)
        XCTAssertTrue(
            state.registrationWork.values.contains {
                $0.routeID == todayRouteID
                    && $0.request.reason == .dayRollover
                    && $0.retry.terminal == .succeeded
            }
        )
        XCTAssertTrue(
            state.activationWork.values.contains {
                $0.routeID == todayRouteID && $0.retry.terminal == .succeeded
            }
        )
        XCTAssertEqual(state.routes[yesterdayRouteID]?.lifecycle, .retired)
        XCTAssertEqual(state.epochs[yesterdayEpochID]?.status, .retired)
        XCTAssertEqual(state.epochs[yesterdayEpochID]?.retireReason, .dayRollover)
    }

    func testStaleDayRescueDoesNotNormalizePausedOrNeverInstalledPrior() async throws {
        for scenario in ["paused", "never_installed"] {
            let fixture = try seedStalePhysicalPrior()
            let yesterdayActivity = DeviceActivityName(
                try XCTUnwrap(try store.read().routes[fixture.yesterdayRouteID]?.activityName)
            )
            center.stopMonitoring([yesterdayActivity])
            center.startFailures.insert(yesterdayActivity)
            try store.transaction(expectedOwner: owner) { state in
                let installID = try XCTUnwrap(
                    state.installWork.first(where: {
                        $0.value.routeID == fixture.yesterdayRouteID
                    })?.key
                )
                if scenario == "paused" {
                    state.epochs[fixture.yesterdayEpochID]?.status = .paused
                    var route = try XCTUnwrap(state.routes[fixture.yesterdayRouteID])
                    route.installedSchedule = route.plannedSchedule
                    route.installedEvents = route.plannedEvents
                    state.routes[fixture.yesterdayRouteID] = route
                } else {
                    state.routes[fixture.yesterdayRouteID]?.installedSchedule = nil
                    state.routes[fixture.yesterdayRouteID]?.installedEvents = []
                }
                state.installWork[installID]?.phase = .pendingStart
                state.installWork[installID]?.claim = nil
                state.installWork[installID]?.retry = MeteringRetryState(
                    attemptCount: 1,
                    nextAttemptAt: self.todayInstant,
                    lastErrorCode: "startFailed",
                    terminal: .pending
                )
            }

            try await makeDriver().recover(ownerChildDeviceID: owner)

            let state = try store.read()
            XCTAssertNil(state.v2RouteHandoff, scenario)
            let priorInstall = try XCTUnwrap(
                state.installWork.values.first(where: { $0.routeID == fixture.yesterdayRouteID })
            )
            XCTAssertNotEqual(priorInstall.retry.lastErrorCode, "stale_day_prior_absent", scenario)

            // Give the next scenario a clean store while retaining the same
            // XCTest instance and dependency setup.
            try? FileManager.default.removeItem(at: storeURL)
            store = DeviceEpochStore(
                fileURL: storeURL,
                ownerProvider: { self.owner },
                legacyDefaults: nil
            )
        }
    }

    func testSupersedingRegistrationRequiredWorkPreservesAuthorizedCandidates() throws {
        for scenario in ["desired_revision", "active_generation", "handoff_provenance"] {
            let fixture = try seedStalePhysicalPrior()
            let protectedRouteID: UUID

            switch scenario {
            case "desired_revision":
                protectedRouteID = fixture.currentTodayRouteID
            case "active_generation":
                protectedRouteID = fixture.staleTodayRouteID
                let activeWorkID = try elapsedInstallWorkID(protectedRouteID)
                try store.transaction(expectedOwner: owner) { state in
                    state.installWork[activeWorkID]?.authorization = .registrationRequired
                }
            case "handoff_provenance":
                protectedRouteID = fixture.currentTodayRouteID
                let currentState = try store.read()
                let currentRoute = try XCTUnwrap(currentState.routes[fixture.currentTodayRouteID])
                _ = try store.ingestDesiredPolicy(MeteringDesiredPolicy(
                    commandID: UUID(),
                    ownerChildDeviceID: owner,
                    orderingToken: 43,
                    policyRevision: "rev-after-handoff",
                    usageDate: today,
                    canonicalTimezone: timezone,
                    dailyPoolMinutes: 120,
                    deviceCapMinutes: 60,
                    remainingMinutes: 60,
                    enforcementSetID: enforcementSetID,
                    receivedAt: todayInstant,
                    appliedAt: nil,
                    ackedAt: nil
                ))
                try store.transaction(expectedOwner: owner) { state in
                    state.v2RouteHandoff = V2RouteHandoff(
                        handoffID: UUID(),
                        ownerChildDeviceID: owner,
                        fromGenerationID: try XCTUnwrap(
                            state.routes[fixture.yesterdayRouteID]?.generationID
                        ),
                        fromEpochID: fixture.yesterdayEpochID,
                        fromRouteID: fixture.yesterdayRouteID,
                        toGenerationID: currentRoute.generationID,
                        toEpochID: currentRoute.epochID,
                        toRouteID: currentRoute.routeID,
                        phase: .preparing,
                        priorRouteInputClosedAt: nil,
                        registrationAcknowledgedAt: nil,
                        activationAcknowledgedAt: nil,
                        priorStopAcknowledgedAt: nil,
                        createdAt: self.todayInstant
                    )
                }
            default:
                XCTFail("unknown scenario")
                return
            }

            let workID = try elapsedInstallWorkID(protectedRouteID)
            let before = try XCTUnwrap(try store.read().installWork[workID])
            XCTAssertEqual(before.authorization, .registrationRequired, scenario)
            XCTAssertEqual(before.phase, .pendingStart, scenario)
            XCTAssertEqual(before.retry.terminal, .pending, scenario)

            XCTAssertFalse(
                try store.supersedeUnprovenRegistrationRequiredInstall(
                    workID: workID,
                    owner: owner,
                    now: todayInstant
                ),
                scenario
            )
            XCTAssertEqual(try store.read().installWork[workID], before, scenario)

            try? FileManager.default.removeItem(at: storeURL)
            store = DeviceEpochStore(
                fileURL: storeURL,
                ownerProvider: { self.owner },
                legacyDefaults: nil
            )
        }
    }

    func testSupersededRolloverReplansWhenCurrentRevisionTodayRouteWasTombstoned() async throws {
        let fixture = try await seedSupersededRolloverDeadlock()
        try store.transaction(expectedOwner: owner) { state in
            var route = try XCTUnwrap(state.routes[fixture.currentTodayRouteID])
            var epoch = try XCTUnwrap(state.epochs[route.epochID])
            let relatedWorkIDs = Set(
                state.installWork.values.filter { $0.routeID == route.routeID }.map(\.workID)
                    + state.registrationWork.values.filter { $0.routeID == route.routeID }.map(\.workID)
            )

            route.lifecycle = .tombstoned
            state.routes[route.routeID] = route
            epoch.status = .retired
            epoch.retiredAt = todayInstant.addingTimeInterval(60)
            epoch.retireReason = .activationSuperseded
            state.epochs[epoch.epochID] = epoch
            state.tombstones[route.routeID] = MeteringRouteTombstone(
                routeID: route.routeID,
                activityName: route.activityName,
                eventNames: route.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: route.usageDate,
                epochID: route.epochID,
                generationID: route.generationID,
                canonicalDayEnd: todayInstant.addingTimeInterval(86_400),
                stopAcknowledgedAt: nil,
                referencedWorkIDs: relatedWorkIDs,
                retainedUntil: nil
            )
            for (workID, var work) in state.installWork where work.routeID == route.routeID {
                work.phase = .pendingStop
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "test_tombstoned"
                state.installWork[workID] = work
            }
            for (workID, var work) in state.registrationWork where work.routeID == route.routeID {
                work.retry.terminal = .superseded
                work.retry.lastErrorCode = "test_tombstoned"
                state.registrationWork[workID] = work
            }
        }

        let replanned = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: today,
            generationKey: generationKey(revision: currentRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: todayInstant
        ))
        let replacementRouteID = try XCTUnwrap(replanned.routeIDsByUsageDate[today])
        XCTAssertNotEqual(replacementRouteID, fixture.currentTodayRouteID)
        XCTAssertEqual(replanned.generationID, fixture.currentGenerationID)

        for pass in 1...6 {
            try await makeDriver().recover(ownerChildDeviceID: owner)
            if try store.read().activeRouteID == replacementRouteID { break }
            XCTAssertLessThan(pass, 6, "recovery never adopted the replanned current route")
        }
        try await makeDriver().recover(ownerChildDeviceID: owner)

        let state = try store.read()
        XCTAssertEqual(state.activeRouteID, replacementRouteID)
        XCTAssertEqual(state.routes[replacementRouteID]?.lifecycle, .active)
        XCTAssertTrue(
            state.routes[fixture.currentTodayRouteID].map { $0.lifecycle == .tombstoned } ?? true
        )
        XCTAssertTrue(
            state.epochs[fixture.currentTodayEpochID].map { $0.status == .retired } ?? true
        )
        XCTAssertNil(state.v2RouteHandoff)
    }

    /// The four local new-day effects (earned source, per-app, task state,
    /// bypass expiry) happened exactly once for this day change and must not be
    /// replayed or undone by the yield: locally, the day really did turn over.
    func testYieldNeitherReplaysNorUndoesTheLocalNewDayEffects() async throws {
        let recorder = EffectRecorder()
        let fixture = try await seedSupersededRolloverDeadlock(
            resetRolloverEffect: { effect, _ in recorder.append(effect) }
        )
        XCTAssertEqual(
            Set(recorder.effects),
            Set(MeteringRolloverLocalEffect.allCases),
            "seeding must have already turned the day over locally"
        )
        let resetsAfterSeed = recorder.effects.count

        for _ in 1...6 {
            try await makeDriver(resetRolloverEffect: { effect, _ in recorder.append(effect) })
                .recover(ownerChildDeviceID: owner)
            if try store.read().activeRouteID == fixture.currentTodayRouteID { break }
        }

        XCTAssertEqual(
            recorder.effects.count,
            resetsAfterSeed,
            "yielding must not replay the day's local effects"
        )
        let work = try XCTUnwrap(try store.read().rolloverEffectsWork)
        XCTAssertTrue(work.earnedSourceResetAcknowledged)
        XCTAssertTrue(work.perAppResetAcknowledged)
        XCTAssertTrue(work.taskStateResetAcknowledged)
        XCTAssertTrue(work.bypassExpiryAcknowledged)
    }

    /// The yield is one-shot. A recovery pass that runs after the device has
    /// settled on today must not re-open a rollover, re-create a handoff, or
    /// stop/start anything — otherwise the fix trades one wedge for a battery
    /// -burning churn loop.
    func testYieldIsOneShotAndSettlesWithoutChurn() async throws {
        let fixture = try await seedSupersededRolloverDeadlock()
        for _ in 1...6 {
            try await makeDriver().recover(ownerChildDeviceID: owner)
            if try store.read().activeRouteID == fixture.currentTodayRouteID { break }
        }
        try await makeDriver().recover(ownerChildDeviceID: owner)
        XCTAssertEqual(try store.read().activeRouteID, fixture.currentTodayRouteID)

        let settledState = try store.read()
        let todayActivity = try XCTUnwrap(settledState.routes[fixture.currentTodayRouteID]?.activityName)
        center.stopCalls.removeAll()
        center.startCalls.removeAll()

        try await makeDriver().recover(ownerChildDeviceID: owner)
        try await makeDriver().recover(ownerChildDeviceID: owner)

        let after = try store.read()
        XCTAssertEqual(after.activeRouteID, settledState.activeRouteID)
        XCTAssertNil(after.v2RouteHandoff)
        XCTAssertNotEqual(after.rolloverEffectsWork?.retry.terminal, .pending)
        XCTAssertTrue(center.stopCalls.isEmpty, "a settled device must not stop monitors")
        XCTAssertFalse(
            center.startCalls.contains(todayActivity),
            "a settled device must not re-arm today's route"
        )
    }

    /// Candidate selection must follow the backend's revision, not the newest
    /// row. The device carried several never-retired stale generations, each
    /// with a full week of planned routes — one of them created *after* the
    /// current-revision generation, so "newest wins" picks the wrong one.
    func testStaleNeverRetiredGenerationsDoNotWinCandidateSelection() async throws {
        let fixture = try await seedSupersededRolloverDeadlock()
        XCTAssertFalse(fixture.decoyTodayRouteIDs.isEmpty, "the decoys are the point of this test")

        for _ in 1...6 {
            try await makeDriver().recover(ownerChildDeviceID: owner)
            if try store.read().activeRouteID == fixture.currentTodayRouteID { break }
        }

        let state = try store.read()
        XCTAssertEqual(state.activeRouteID, fixture.currentTodayRouteID)
        for decoy in fixture.decoyTodayRouteIDs {
            XCTAssertNotEqual(
                state.activeRouteID,
                decoy,
                "a stale-revision generation must never be adopted"
            )
        }
    }

    // MARK: - Never arm a day that is already over

    /// Apple throws `invalidDateComponents` for a `startMonitoring` whose
    /// interval has already ended — the device's watchdog hit exactly this while
    /// trying to re-kick yesterday's route. A re-arm must never attempt it: by
    /// then `absorbCreditedProgressForRearm` has already moved the ledger and
    /// the monitor Apple was holding is gone for good.
    func testInstallerRefusesToReArmAnAlreadyElapsedUsageDate() throws {
        let plan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: yesterday,
            generationKey: generationKey(revision: staleRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: yesterdayInstant
        ))
        let elapsedRouteID = try XCTUnwrap(plan.routeIDsByUsageDate[yesterday])
        try store.transaction(expectedOwner: owner) { state in
            let installID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == elapsedRouteID })?.key
            )
            state.installWork[installID]?.authorization = .offlinePending
            // Already armed once — this is the re-arm the daemon would refuse.
            state.installWork[installID]?.phase = .installed
            var route = try XCTUnwrap(state.routes[elapsedRouteID])
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[elapsedRouteID] = route
        }

        // Two full days later: yesterday's interval is long gone.
        let laterCenter = RecordingCenter()
        let installer = DatedRouteInstaller(
            store: store,
            center: laterCenter,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: FixedClock(now: yesterdayInstant.addingTimeInterval(2 * 86_400))
        )

        let results = try installer.reconcile(ownerChildDeviceID: owner)

        let elapsedActivity = try XCTUnwrap(
            try store.read().routes[elapsedRouteID]?.activityName
        )
        XCTAssertFalse(
            laterCenter.startCalls.contains(elapsedActivity),
            "startMonitoring for an elapsed interval always throws invalidDateComponents"
        )
        let persisted = try store.read()
        let retiredRoute = try XCTUnwrap(persisted.routes[elapsedRouteID])
        XCTAssertEqual(retiredRoute.lifecycle, .tombstoned)
        XCTAssertEqual(persisted.epochs[retiredRoute.epochID]?.status, .retired)
        XCTAssertTrue(
            persisted.installWork.values.contains {
                $0.routeID == elapsedRouteID && $0.phase == .pendingStop
            },
            "an elapsed installed route must become bounded cleanup debt, not an immortal deferred re-arm; results=\(results)"
        )
        // Days that have NOT elapsed are still armed — the guard is surgical.
        XCTAssertFalse(laterCenter.startCalls.isEmpty)
    }

    func testUsageDateElapsedIsExactAboutTheCanonicalDayBoundary() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: timezone))
        // 2026-07-17 23:59:59 EDT — still inside the day.
        let lastSecond = try MeteringDatedSchedule.canonicalStart(usageDate: yesterday, timeZone: zone)
            .addingTimeInterval(86_400 - 1)
        XCTAssertFalse(MeteringDatedSchedule.hasElapsed(
            usageDate: yesterday, timeZone: zone, now: lastSecond
        ))
        XCTAssertTrue(MeteringDatedSchedule.hasElapsed(
            usageDate: yesterday, timeZone: zone, now: lastSecond.addingTimeInterval(1)
        ))
        XCTAssertFalse(MeteringDatedSchedule.hasElapsed(
            usageDate: today, timeZone: zone, now: lastSecond.addingTimeInterval(1)
        ))
        // A malformed date is not a licence to arm anything.
        XCTAssertTrue(MeteringDatedSchedule.hasElapsed(
            usageDate: "not-a-date", timeZone: zone, now: lastSecond
        ))
    }

    // MARK: - Fixture

    private struct Fixture {
        let staleGenerationID: UUID
        let yesterdayRouteID: UUID
        let yesterdayEpochID: UUID
        let staleTodayRouteID: UUID
        let staleTodayEpochID: UUID
        let currentGenerationID: UUID
        let currentTodayRouteID: UUID
        let currentTodayEpochID: UUID
        let decoyTodayRouteIDs: [UUID]
    }

    private struct StalePriorFixture {
        let yesterdayRouteID: UUID
        let yesterdayEpochID: UUID
        let staleTodayRouteID: UUID
        let currentTodayRouteID: UUID
    }

    private var center = RecordingCenter()
    private lazy var transport = RevisionAwareTransport(
        acceptedRevision: currentRevision,
        owner: owner,
        usageDate: today
    )

    private func seedStalePhysicalPrior() throws -> StalePriorFixture {
        center = RecordingCenter()
        transport = RevisionAwareTransport(
            acceptedRevision: currentRevision,
            owner: owner,
            usageDate: today
        )

        let priorPlan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: yesterday,
            generationKey: generationKey(revision: staleRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: yesterdayInstant
        ))
        let yesterdayRouteID = try XCTUnwrap(priorPlan.routeIDsByUsageDate[yesterday])
        let staleTodayRouteID = try XCTUnwrap(priorPlan.routeIDsByUsageDate[today])
        let yesterdayEpochID = try XCTUnwrap(
            try store.read().routes[yesterdayRouteID]?.epochID
        )
        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = priorPlan.generationID
            state.activeEpochID = yesterdayEpochID
            state.activeRouteID = yesterdayRouteID
            state.routes[yesterdayRouteID]?.lifecycle = .active
            state.epochs[yesterdayEpochID]?.registeredAt = self.yesterdayInstant
            let installID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == yesterdayRouteID })?.key
            )
            var route = try XCTUnwrap(state.routes[yesterdayRouteID])
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[yesterdayRouteID] = route
            state.installWork[installID]?.authorization = .registered
            state.installWork[installID]?.phase = .active
            state.installWork[installID]?.retry.terminal = .succeeded
            let registrationID = try XCTUnwrap(
                state.registrationWork.first(where: { $0.value.routeID == yesterdayRouteID })?.key
            )
            state.registrationWork[registrationID]?.retry.terminal = .succeeded
            state.ratchets[self.owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: self.owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: self.yesterdayInstant,
                dualActiveAt: self.yesterdayInstant,
                activatedV2At: self.yesterdayInstant
            )
        }
        center.seed(
            DeviceActivityName(
                try XCTUnwrap(try store.read().routes[yesterdayRouteID]?.activityName)
            )
        )

        _ = try store.ingestDesiredPolicy(MeteringDesiredPolicy(
            commandID: UUID(),
            ownerChildDeviceID: owner,
            orderingToken: 42,
            policyRevision: currentRevision,
            usageDate: today,
            canonicalTimezone: timezone,
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 60,
            enforcementSetID: enforcementSetID,
            receivedAt: todayInstant,
            appliedAt: nil,
            ackedAt: nil
        ))
        let currentPlan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: today,
            generationKey: generationKey(revision: currentRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: todayInstant
        ))
        return StalePriorFixture(
            yesterdayRouteID: yesterdayRouteID,
            yesterdayEpochID: yesterdayEpochID,
            staleTodayRouteID: staleTodayRouteID,
            currentTodayRouteID: try XCTUnwrap(currentPlan.routeIDsByUsageDate[today])
        )
    }

    /// Builds the device's actual state by driving the real code paths:
    ///   * yesterday armed and active on the stale generation,
    ///   * a canonical rollover prepared and then wedged by a real
    ///     `409 policy_revision_mismatch` from the transport,
    ///   * the new policy arriving and minting the current-revision generation
    ///     with today's planned route,
    ///   * plus never-retired decoy generations carrying their own week of
    ///     planned routes.
    private func seedSupersededRolloverDeadlock(
        resetRolloverEffect: @escaping (MeteringRolloverLocalEffect, RolloverEffectsWork) throws -> Void = { _, _ in }
    ) async throws -> Fixture {
        center = RecordingCenter()
        transport = RevisionAwareTransport(
            acceptedRevision: currentRevision,
            owner: owner,
            usageDate: today
        )

        let stalePlan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: yesterday,
            generationKey: generationKey(revision: staleRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: yesterdayInstant
        ))
        let yesterdayRouteID = try XCTUnwrap(stalePlan.routeIDsByUsageDate[yesterday])
        let staleTodayRouteID = try XCTUnwrap(stalePlan.routeIDsByUsageDate[today])
        let seeded = try store.read()
        let yesterdayEpochID = try XCTUnwrap(seeded.routes[yesterdayRouteID]?.epochID)
        let staleTodayEpochID = try XCTUnwrap(seeded.routes[staleTodayRouteID]?.epochID)

        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = stalePlan.generationID
            state.activeEpochID = yesterdayEpochID
            state.activeRouteID = yesterdayRouteID
            state.routes[yesterdayRouteID]?.lifecycle = .active
            state.epochs[yesterdayEpochID]?.registeredAt = self.yesterdayInstant
            let activeInstallID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == yesterdayRouteID })?.key
            )
            state.installWork[activeInstallID]?.authorization = .registered
            state.installWork[activeInstallID]?.phase = .active
            state.installWork[activeInstallID]?.retry.terminal = .succeeded
            let activeRegistrationID = try XCTUnwrap(
                state.registrationWork.first(where: { $0.value.routeID == yesterdayRouteID })?.key
            )
            state.registrationWork[activeRegistrationID]?.retry.terminal = .succeeded
            // Tomorrow's route was armed ahead of time, exactly as the horizon
            // installer does — this is what let the rollover reach cutoverReady.
            let futureInstallID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == staleTodayRouteID })?.key
            )
            var installedRoute = try XCTUnwrap(state.routes[staleTodayRouteID])
            installedRoute.installedSchedule = installedRoute.plannedSchedule
            installedRoute.installedEvents = installedRoute.plannedEvents
            state.routes[staleTodayRouteID] = installedRoute
            state.installWork[futureInstallID]?.phase = .verified
            state.installWork[futureInstallID]?.retry.terminal = .succeeded
            state.ratchets[self.owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: self.owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: self.yesterdayInstant,
                dualActiveAt: self.yesterdayInstant,
                activatedV2At: self.yesterdayInstant
            )
        }
        center.seed(DeviceActivityName(try XCTUnwrap(seeded.routes[yesterdayRouteID]?.activityName)))
        center.seed(DeviceActivityName(try XCTUnwrap(seeded.routes[staleTodayRouteID]?.activityName)))

        // Midnight: the driver prepares and then wedges the rollover, because
        // the backend has already moved past this generation's revision.
        try await makeDriver(resetRolloverEffect: resetRolloverEffect)
            .recover(ownerChildDeviceID: owner)

        // 06:19 — the new policy lands and mints the generation that carries the
        // revision the backend will actually accept.
        _ = try store.ingestDesiredPolicy(MeteringDesiredPolicy(
            commandID: UUID(),
            ownerChildDeviceID: owner,
            orderingToken: 42,
            policyRevision: currentRevision,
            usageDate: today,
            canonicalTimezone: timezone,
            dailyPoolMinutes: 120,
            deviceCapMinutes: 60,
            remainingMinutes: 60,
            enforcementSetID: enforcementSetID,
            receivedAt: todayInstant,
            appliedAt: nil,
            ackedAt: nil
        ))
        let currentPlan = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: today,
            generationKey: generationKey(revision: currentRevision),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 60,
            authoritativeBaseAcceptedMinutes: 0,
            now: todayInstant
        ))
        let currentTodayRouteID = try XCTUnwrap(currentPlan.routeIDsByUsageDate[today])

        // Decoys: never-retired generations on dead revisions, each with its own
        // week of planned routes. One is created LAST, so a "newest planned
        // route wins" candidate rule would pick it.
        var decoyTodayRouteIDs: [UUID] = []
        for (index, revision) in ["rev-decoy-0340f26b", "rev-decoy-0bf353a3"].enumerated() {
            let decoy = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: today,
                generationKey: generationKey(revision: revision),
                persistedSelectionBytes: selectionBytes,
                poolMinutes: 120,
                deviceCapMinutes: 60,
                authoritativeBaseAcceptedMinutes: 0,
                now: todayInstant.addingTimeInterval(Double(index + 1) * 60)
            ))
            decoyTodayRouteIDs.append(try XCTUnwrap(decoy.routeIDsByUsageDate[today]))
        }

        let state = try store.read()
        return Fixture(
            staleGenerationID: stalePlan.generationID,
            yesterdayRouteID: yesterdayRouteID,
            yesterdayEpochID: yesterdayEpochID,
            staleTodayRouteID: staleTodayRouteID,
            staleTodayEpochID: staleTodayEpochID,
            currentGenerationID: currentPlan.generationID,
            currentTodayRouteID: currentTodayRouteID,
            currentTodayEpochID: try XCTUnwrap(state.routes[currentTodayRouteID]?.epochID),
            decoyTodayRouteIDs: decoyTodayRouteIDs
        )
    }

    /// Compact "why did this pass not converge" dump for assertion messages.
    private static func dump(_ state: DeviceEpochStoreState) -> String {
        var lines: [String] = []
        for work in state.registrationWork.values {
            let route: String = String(work.routeID.uuidString.prefix(8))
            let reason: String = work.request.reason.rawValue
            let terminal: String = work.retry.terminal.rawValue
            let code: String = work.retry.lastErrorCode ?? "-"
            lines.append("reg \(route) \(reason) \(terminal) \(code)")
        }
        for work in state.activationWork.values {
            let route: String = String(work.routeID.uuidString.prefix(8))
            let terminal: String = work.retry.terminal.rawValue
            let code: String = work.retry.lastErrorCode ?? "-"
            lines.append("act \(route) \(terminal) \(code)")
        }
        for work in state.installWork.values {
            let route: String = String(work.routeID.uuidString.prefix(8))
            let phase: String = work.phase.rawValue
            let auth: String = work.authorization.rawValue
            let terminal: String = work.retry.terminal.rawValue
            lines.append("ins \(route) \(phase) \(auth) \(terminal)")
        }
        return lines.sorted().joined(separator: " | ")
    }

    private func elapsedInstallWorkID(_ routeID: UUID) throws -> UUID {
        try XCTUnwrap(
            try store.read().installWork.values.first { $0.routeID == routeID }?.workID
        )
    }

    private func generationKey(revision: String) -> MeteringGenerationKey {
        MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: timezone,
            policyRevision: revision,
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: enforcementSetID
        )
    }

    private func makeDriver(
        now: Date? = nil,
        transport transportOverride: (any MeteringHTTPTransport)? = nil,
        resetRolloverEffect: @escaping (MeteringRolloverLocalEffect, RolloverEffectsWork) throws -> Void = { _, _ in }
    ) -> EarnedMeteringRecoveryDriver {
        let clock = FixedClock(now: now ?? todayInstant)
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            transport: transportOverride ?? transport,
            clock: clock,
            legacySuiteName: "superseded-rollover-tests-\(UUID().uuidString)"
        )
        let installer = DatedRouteInstaller(
            store: store,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock
        )
        return EarnedMeteringRecoveryDriver(
            store: store,
            delivery: delivery,
            installer: installer,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock,
            resetRolloverEffect: resetRolloverEffect
        )
    }
}

private struct FixedClock: MeteringClock { let now: Date }

/// The reset adapter is invoked from the driver's detached recovery task, so the
/// tally cannot live in a `var` captured by a `@MainActor` test method.
private final class EffectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeteringRolloverLocalEffect] = []

    var effects: [MeteringRolloverLocalEffect] { lock.withLock { storage } }

    func append(_ effect: MeteringRolloverLocalEffect) {
        lock.withLock { storage.append(effect) }
    }
}

/// Speaks the backend's actual rule: a registration whose `policy_revision` is
/// not the current one is a `409 policy_revision_mismatch`
/// (`Evlin-Backend/app/services/metering_epoch_registry.py`).
/// Poisons the first N `/activation` responses with a shape the delivery layer
/// classifies as terminal `epoch_not_active`, then delegates. Everything else
/// passes straight through.
private final class FailingActivationTransport: MeteringHTTPTransport, @unchecked Sendable {
    private let inner: RevisionAwareTransport
    private var failuresRemaining: Int
    private(set) var failed = 0

    init(inner: RevisionAwareTransport, failures: Int) {
        self.inner = inner
        self.failuresRemaining = failures
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/activation"), failuresRemaining > 0 {
            failuresRemaining -= 1
            failed += 1
            let epochID = UUID(
                uuidString: path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            ) ?? UUID()
            return (
                try JSONEncoder().encode(EpochActivationResponseDTO(
                    status: .activated,
                    epochID: epochID,
                    epochStatus: .retired,
                    meteringProtocolVersion: 2,
                    snapshot: inner.exposedSnapshot()
                )),
                RevisionAwareTransport.response(status: 200)
            )
        }
        return try await inner.data(for: request)
    }
}


private final class RevisionAwareTransport: MeteringHTTPTransport, @unchecked Sendable {
    let acceptedRevision: String
    let owner: UUID
    let usageDate: String
    var requests: [URLRequest] = []
    var rejectedRevisions: [String] = []

    init(acceptedRevision: String, owner: UUID, usageDate: String) {
        self.acceptedRevision = acceptedRevision
        self.owner = owner
        self.usageDate = usageDate
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        if path.hasSuffix("/activation") {
            let epochID = UUID(
                uuidString: path
                    .split(separator: "/")
                    .dropLast()
                    .last
                    .map(String.init) ?? ""
            ) ?? UUID()
            return (
                try JSONEncoder().encode(EpochActivationResponseDTO(
                    status: .activated,
                    epochID: epochID,
                    epochStatus: .active,
                    meteringProtocolVersion: 2,
                    snapshot: snapshot()
                )),
                Self.response(status: 200)
            )
        }
        if path.hasSuffix("/epochs") {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let body = try decoder.decode(
                EpochRegistrationRequestDTO.self,
                from: request.httpBody ?? Data()
            )
            guard body.policyRevision == acceptedRevision else {
                rejectedRevisions.append(body.policyRevision)
                return (
                    Data(#"{"detail":"policy_revision_mismatch"}"#.utf8),
                    Self.response(status: 409)
                )
            }
            return (
                try JSONEncoder().encode(EpochRegistrationResponseDTO(
                    status: .registered,
                    epochID: body.epochID,
                    meteringProtocolVersion: 2,
                    snapshot: snapshot(usageDate: body.usageDate),
                    epochStatus: .active
                )),
                Self.response(status: 200)
            )
        }
        return (
            try JSONEncoder().encode(snapshot()),
            Self.response(status: 200)
        )
    }

    func exposedSnapshot() -> DeviceDaySnapshotDTO { snapshot() }

    private func snapshot(usageDate: String? = nil) -> DeviceDaySnapshotDTO {
        DeviceDaySnapshotDTO(
            childDeviceID: owner,
            usageDate: usageDate ?? self.usageDate,
            estimatedMinutes: 0,
            capMinutes: 60,
            childDayState: "available",
            usedMinutes: 0,
            remainingMinutes: 60,
            counted: true,
            warning: nil
        )
    }

    static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid/api/v1")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private nonisolated final class RecordingCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    var records: Set<DeviceActivityName> = []
    var schedules: [DeviceActivityName: DeviceActivitySchedule] = [:]
    var eventMaps: [DeviceActivityName: [DeviceActivityEvent.Name: DeviceActivityEvent]] = [:]
    var stopCalls: [[DeviceActivityName]] = []
    var startCalls: [String] = []
    var startFailures: Set<DeviceActivityName> = []
    var activities: [DeviceActivityName] { Array(records) }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { schedules[activity] }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        eventMaps[activity] ?? [:]
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startCalls.append(activity.rawValue)
        if startFailures.contains(activity) {
            throw NSError(
                domain: "MeteringSupersededRolloverRecoveryTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalidDateComponents"]
            )
        }
        records.insert(activity)
        schedules[activity] = schedule
        eventMaps[activity] = events
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        activities.forEach {
            records.remove($0)
            schedules.removeValue(forKey: $0)
            eventMaps.removeValue(forKey: $0)
        }
    }

    func seed(_ activity: DeviceActivityName) { records.insert(activity) }
}
