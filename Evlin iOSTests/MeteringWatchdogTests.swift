import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import Evlin_iOS

/// A3 watchdog — self-check, self-heal, and the two throttles that keep the
/// heal from becoming a re-arm loop.
final class MeteringWatchdogTests: XCTestCase {

    private var captured: [ScreenTimeEvent] = []

    override func setUp() {
        super.setUp()
        captured = []
        EarnedTimeStore.shared.usageCountingAllowed = true
        MeteringFlightRecorder.testSink = { [weak self] event in
            self?.captured.append(event)
        }
    }

    override func tearDown() {
        EarnedTimeStore.shared.usageCountingAllowed = true
        MeteringFlightRecorder.testSink = nil
        captured = []
        super.tearDown()
    }

    private func events(kind: ScreenTimeEvent.Kind) -> [ScreenTimeEvent] {
        captured.filter { $0.kind == kind }
    }

    // MARK: - Pure coverage decision

    func testCoverageRedNamesEachUnhealthyCoverageShape() {
        let owner = UUID()
        func coverage(
            status: MonitorCoverageStatus,
            readyThrough: String?,
            owner ownerID: UUID = owner
        ) -> MonitorCoverageState {
            MonitorCoverageState(
                ownerChildDeviceID: ownerID,
                requiredFromUsageDate: "2026-07-18",
                requiredThroughUsageDate: "2026-07-25",
                readyThroughUsageDate: readyThrough,
                status: status,
                refreshedAt: Date(),
                errorCode: nil
            )
        }

        XCTAssertEqual(
            MeteringWatchdog.coverageRed(coverage: nil, owner: owner, usageDate: "2026-07-18"),
            "coverage_missing"
        )
        XCTAssertEqual(
            MeteringWatchdog.coverageRed(
                coverage: coverage(status: .ready, readyThrough: "2026-07-25", owner: UUID()),
                owner: owner,
                usageDate: "2026-07-18"
            ),
            "coverage_foreign"
        )
        XCTAssertEqual(
            MeteringWatchdog.coverageRed(
                coverage: coverage(status: .coverageExhausted, readyThrough: nil),
                owner: owner,
                usageDate: "2026-07-18"
            ),
            "coverage_exhausted"
        )
        XCTAssertEqual(
            MeteringWatchdog.coverageRed(
                coverage: coverage(status: .installLimited, readyThrough: "2026-07-17"),
                owner: owner,
                usageDate: "2026-07-18"
            ),
            "coverage_behind"
        )
        // Green: today is inside the ready horizon.
        XCTAssertNil(
            MeteringWatchdog.coverageRed(
                coverage: coverage(status: .ready, readyThrough: "2026-07-25"),
                owner: owner,
                usageDate: "2026-07-18"
            )
        )
    }

    func testHandoffRedTripsOnlyForStuckNonCommittedHandoffs() {
        // #95: a handoff is a transition, not a state. Stuck past the grace →
        // report-only red. Committed, fresh, or foreign handoffs stay silent.
        let owner = UUID()
        let now = Date(timeIntervalSince1970: 1_784_332_800)
        func handoff(
            phase: V2RouteHandoffPhase,
            ageSeconds: TimeInterval,
            ownerID: UUID = owner
        ) -> V2RouteHandoff {
            V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: ownerID,
                fromGenerationID: UUID(),
                fromEpochID: UUID(),
                fromRouteID: UUID(),
                toGenerationID: UUID(),
                toEpochID: UUID(),
                toRouteID: UUID(),
                phase: phase,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: now.addingTimeInterval(-ageSeconds)
            )
        }

        XCTAssertNil(MeteringWatchdog.handoffRed(handoff: nil, owner: owner, now: now))
        XCTAssertNil(
            MeteringWatchdog.handoffRed(
                handoff: handoff(phase: .preparing, ageSeconds: 60),
                owner: owner,
                now: now
            ),
            "a fresh handoff is a healthy transition"
        )
        XCTAssertNil(
            MeteringWatchdog.handoffRed(
                handoff: handoff(phase: .committed, ageSeconds: 7_200),
                owner: owner,
                now: now
            ),
            "committed is history awaiting cleanup debt, never stuck"
        )
        XCTAssertNil(
            MeteringWatchdog.handoffRed(
                handoff: handoff(phase: .dualV2, ageSeconds: 7_200, ownerID: UUID()),
                owner: owner,
                now: now
            ),
            "a foreign owner's handoff is not ours to judge"
        )
        XCTAssertEqual(
            MeteringWatchdog.handoffRed(
                handoff: handoff(phase: .preparing, ageSeconds: 31 * 60),
                owner: owner,
                now: now
            ),
            "handoff_stuck_preparing"
        )
        XCTAssertEqual(
            MeteringWatchdog.handoffRed(
                handoff: handoff(phase: .cutoverReady, ageSeconds: 7_200),
                owner: owner,
                now: now
            ),
            "handoff_stuck_cutoverReady"
        )
    }

    // MARK: - Red → heal

    func testMissingDaemonRegistrationTriggersFreshRouteRecovery() async throws {
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        // The daemon holds nothing — the route was armed and then lost.
        let watchdog = fixture.makeWatchdog()

        await watchdog.run(trigger: "test")

        let watchEvents = events(kind: .meteringWatch)
        let red = try XCTUnwrap(watchEvents.first)
        XCTAssertEqual(red.reason?.hasPrefix("red:"), true)
        XCTAssertEqual(red.reason?.contains("daemon_registration"), true)
        XCTAssertEqual(red.app?.contains("heal=fresh_route"), true)
        XCTAssertEqual(fixture.missingRouteHealCalls, 1)
        XCTAssertEqual(fixture.healCalls, 0)

        // The heal report is itself an event, so an auto-repair that did not
        // repair anything is visible.
        let healEvent = try XCTUnwrap(watchEvents.last)
        XCTAssertEqual(healEvent.reason, "fresh_route")
        XCTAssertEqual(healEvent.app?.contains("report=rekick-report"), true)
    }

    func testSecondRedInsideCooldownReportsButDoesNotRekickAgain() async throws {
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        let watchdog = fixture.makeWatchdog()

        await watchdog.run(trigger: "first")
        XCTAssertEqual(fixture.missingRouteHealCalls, 1)

        // 9 minutes later — still inside the 10-minute heal cooldown.
        fixture.now = fixture.start.addingTimeInterval(9 * 60)
        await watchdog.run(trigger: "second")
        XCTAssertEqual(
            fixture.missingRouteHealCalls,
            1,
            "cooldown must suppress the second recovery"
        )
        let cooling = try XCTUnwrap(events(kind: .meteringWatch).last)
        XCTAssertEqual(cooling.app?.contains("heal=cooling_down"), true)
        XCTAssertEqual(cooling.reason?.hasPrefix("red:"), true, "a suppressed heal is still a red")

        // 11 minutes later — the cooldown has expired, healing resumes.
        fixture.now = fixture.start.addingTimeInterval(11 * 60)
        await watchdog.run(trigger: "third")
        XCTAssertEqual(fixture.missingRouteHealCalls, 2)
    }

    func testStuckHandoffTriggersTheRecoveryPassNotARekick() async throws {
        // 2026-08-11 iPad: a cutoverReady handoff sat wedged for 7.5 hours
        // while this watchdog filed `handoff_stuck_cutoverReady` as
        // report-only every 5 minutes — reporting a fire hourly is not the
        // same as fetching water. A stuck handoff now runs the FULL recovery
        // pass; a same-route re-kick would re-arm the wrong side of the
        // cutover, so the plain heal must NOT fire for it.
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        try fixture.armDaemon()
        try fixture.setReadyCoverage()
        try fixture.installStuckHandoff(ageSeconds: 2 * 60 * 60)
        let watchdog = fixture.makeWatchdog()

        await watchdog.run(trigger: "test")

        XCTAssertEqual(fixture.handoffHealCalls, 1)
        XCTAssertEqual(fixture.healCalls, 0, "a handoff wedge is not a re-kickable red")
        let red = try XCTUnwrap(events(kind: .meteringWatch).first)
        XCTAssertEqual(red.reason?.contains("handoff_stuck_cutoverReady"), true)
    }

    func testAuthorizationRevokedAloneNeverHeals() async throws {
        // Revocation is a user-action-blocked state: no re-kick, no recovery
        // pass — either would churn forever against a condition only the
        // parent can change.
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        try fixture.armDaemon()
        try fixture.setReadyCoverage()
        fixture.screenTimeAuthorized = false
        let watchdog = fixture.makeWatchdog()

        await watchdog.run(trigger: "test")

        XCTAssertEqual(fixture.healCalls, 0)
        XCTAssertEqual(fixture.handoffHealCalls, 0)
        let red = try XCTUnwrap(events(kind: .meteringWatch).first)
        XCTAssertEqual(red.reason?.contains("authorization_revoked"), true)
    }

    func testExpectedCoverageExhaustionWhileAccountingPausedDoesNotRekick() async throws {
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        try fixture.armDaemon()
        try fixture.setAccountingPausedWithExhaustedCoverage()
        EarnedTimeStore.shared.usageCountingAllowed = false

        await fixture.makeWatchdog().run(trigger: "task_pause")

        XCTAssertEqual(fixture.healCalls, 0)
        XCTAssertEqual(events(kind: .meteringWatch).last?.reason, "green")
    }

    func testSelfCheckIntervalThrottlesRunIfDue() async throws {
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        let watchdog = fixture.makeWatchdog()

        await watchdog.runIfDue(trigger: "poll")
        let afterFirst = events(kind: .meteringWatch).count
        XCTAssertGreaterThan(afterFirst, 0)

        // A second poll tick 10 seconds later must not re-check at all.
        fixture.now = fixture.start.addingTimeInterval(10)
        await watchdog.runIfDue(trigger: "poll")
        XCTAssertEqual(events(kind: .meteringWatch).count, afterFirst)

        // Past the 5-minute self-check interval it runs again.
        fixture.now = fixture.start.addingTimeInterval(MeteringWatchdog.selfCheckInterval + 1)
        await watchdog.runIfDue(trigger: "poll")
        XCTAssertGreaterThan(events(kind: .meteringWatch).count, afterFirst)
    }

    // MARK: - Green

    func testHealthyDaemonAndCoverageEmitOneGreenHeartbeatAndNeverHeals() async throws {
        let fixture = try WatchdogFixture()
        defer { fixture.cleanup() }
        try fixture.armDaemon()
        try fixture.setReadyCoverage()
        let watchdog = fixture.makeWatchdog()

        await watchdog.run(trigger: "test")
        XCTAssertEqual(fixture.healCalls, 0)
        let green = try XCTUnwrap(events(kind: .meteringWatch).first)
        XCTAssertEqual(green.reason, "green")

        // A green heartbeat is rate-limited to one per hour.
        fixture.now = fixture.start.addingTimeInterval(60)
        await watchdog.run(trigger: "test")
        XCTAssertEqual(events(kind: .meteringWatch).count, 1)

        fixture.now = fixture.start.addingTimeInterval(MeteringWatchdog.greenHeartbeatInterval + 1)
        await watchdog.run(trigger: "test")
        XCTAssertEqual(events(kind: .meteringWatch).count, 2)
    }

    func testNoActiveRouteIsInconclusiveNotRed() throws {
        let fixture = try WatchdogFixture(active: false)
        defer { fixture.cleanup() }
        let verdict = fixture.makeWatchdog().check()
        XCTAssertTrue(verdict.inconclusive)
        XCTAssertTrue(verdict.reds.isEmpty)
        XCTAssertFalse(verdict.isGreen)
    }
}

// MARK: - Fixture

private final class WatchdogFixture: @unchecked Sendable {
    let owner = UUID()
    let generationID = UUID()
    let epochID = UUID()
    let routeID = UUID()
    let installID = UUID()
    let start = Date(timeIntervalSince1970: 1_784_937_600)
    let storeURL: URL
    let store: DeviceEpochStore
    let center = WatchdogCenter()
    var now: Date
    var healCalls = 0
    var missingRouteHealCalls = 0

    init(active: Bool = true) throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-watchdog-\(UUID().uuidString).json")
        let owner = self.owner
        store = DeviceEpochStore(
            fileURL: storeURL,
            lock: WatchdogLock(),
            ownerProvider: { owner }
        )
        now = start
        if active {
            try store.transaction(expectedOwner: owner) { state in
                state = self.activeState()
            }
        } else {
            try store.transaction(expectedOwner: owner) { state in
                state.ownerChildDeviceID = owner
            }
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Off-device there is no FamilyControls grant, so the authorization probe
    /// is stubbed; `screenTimeAuthorized: false` exercises the revocation red.
    var screenTimeAuthorized = true
    var handoffHealCalls = 0

    func makeWatchdog() -> MeteringWatchdog {
        MeteringWatchdog(
            store: store,
            center: center,
            now: { [unowned self] in self.now },
            heal: { [unowned self] in
                self.healCalls += 1
                return "rekick-report"
            },
            missingRouteHeal: { [unowned self] in
                self.missingRouteHealCalls += 1
                return "rekick-report"
            },
            handoffHeal: { [unowned self] in
                self.handoffHealCalls += 1
                return "recovery-pass-report"
            },
            screenTimeAuthorized: { [unowned self] in self.screenTimeAuthorized }
        )
    }

    /// Puts into the fake daemon exactly what the store expects, so the probe
    /// reports healthy.
    /// A cutoverReady handoff old enough to be judged stuck: from-side is the
    /// fixture's active identity, to-side is a real (seeded) candidate epoch +
    /// route — the store validates every handoff reference against state.
    func installStuckHandoff(ageSeconds: TimeInterval) throws {
        let owner = self.owner
        let toEpochID = UUID()
        let toRouteID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            guard let fromEpoch = state.activeEpochID.flatMap({ state.epochs[$0] }),
                  let fromRoute = state.activeRouteID.flatMap({ state.routes[$0] })
            else { return }
            state.epochs[toEpochID] = DeviceDailyEpoch(
                epochID: toEpochID,
                protocolVersion: fromEpoch.protocolVersion,
                childDeviceID: owner,
                usageDate: fromEpoch.usageDate,
                canonicalTimezone: fromEpoch.canonicalTimezone,
                policyRevision: fromEpoch.policyRevision,
                measurementSelectionDigest: fromEpoch.measurementSelectionDigest,
                enforcementSetID: fromEpoch.enforcementSetID,
                startedAt: fromEpoch.startedAt,
                registeredAt: fromEpoch.registeredAt,
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
            state.routes[toRouteID] = MeteringCallbackRoute(
                routeID: toRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: toRouteID),
                namespace: MeteringRouteNamespace.prefix,
                generationID: fromRoute.generationID,
                generationKey: fromRoute.generationKey,
                ownerChildDeviceID: owner,
                usageDate: fromRoute.usageDate,
                epochID: toEpochID,
                plannedSchedule: fromRoute.plannedSchedule,
                installedSchedule: fromRoute.installedSchedule,
                plannedEvents: fromRoute.plannedEvents,
                installedEvents: fromRoute.installedEvents,
                lifecycle: .planned,
                createdAt: fromRoute.createdAt
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: owner,
                fromGenerationID: fromRoute.generationID,
                fromEpochID: fromEpoch.epochID,
                fromRouteID: fromRoute.routeID,
                toGenerationID: fromRoute.generationID,
                toEpochID: toEpochID,
                toRouteID: toRouteID,
                phase: .cutoverReady,
                priorRouteInputClosedAt: self.now.addingTimeInterval(-ageSeconds),
                registrationAcknowledgedAt: self.now.addingTimeInterval(-ageSeconds),
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: self.now.addingTimeInterval(-ageSeconds)
            )
        }
    }

    func armDaemon() throws {
        let state = try store.read()
        let route = try XCTUnwrap(state.routes[routeID])
        let generation = try XCTUnwrap(state.generations[route.generationID])
        let timeZone = try XCTUnwrap(TimeZone(identifier: route.plannedSchedule.timezoneIdentifier))
        let expected = try MeteringWatchdog.expectedConfiguration(
            route: route,
            generation: generation,
            timeZone: timeZone
        )
        try center.startMonitoring(
            DeviceActivityName(route.activityName),
            during: expected.schedule,
            events: expected.events
        )
    }

    func setReadyCoverage() throws {
        try store.transaction(expectedOwner: owner) { state in
            state.coverage = MonitorCoverageState(
                ownerChildDeviceID: self.owner,
                requiredFromUsageDate: "2026-07-18",
                requiredThroughUsageDate: "2026-07-25",
                readyThroughUsageDate: "2026-07-25",
                status: .ready,
                refreshedAt: self.start,
                errorCode: nil
            )
        }
    }

    func setAccountingPausedWithExhaustedCoverage() throws {
        try store.transaction(expectedOwner: owner) { state in
            state.epochs[self.epochID]?.status = .paused
            state.coverage = MonitorCoverageState(
                ownerChildDeviceID: self.owner,
                requiredFromUsageDate: "2026-07-18",
                requiredThroughUsageDate: "2026-07-25",
                readyThroughUsageDate: nil,
                status: .coverageExhausted,
                refreshedAt: self.start,
                errorCode: nil
            )
        }
    }

    private func activeState() -> DeviceEpochStoreState {
        let selection = FamilyActivitySelection()
        let selectionBytes = (try? JSONEncoder().encode(selection)) ?? Data([1])
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: UUID(),
            measurementSelectionBytes: selectionBytes,
            createdAt: start,
            retiredAt: nil
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
        let schedule = DatedSchedulePlan(
            usageDate: epoch.usageDate,
            timezoneIdentifier: generation.canonicalTimezone,
            calendarIdentifier: "gregorian"
        )
        let plan = MeteringEventPlan(
            eventName: MeteringRouteNamespace.eventName(routeID: routeID, thresholdMinutes: 5),
            thresholdMinutes: 5
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
            plannedSchedule: schedule,
            installedSchedule: schedule,
            plannedEvents: [plan],
            installedEvents: [plan],
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

private nonisolated final class WatchdogCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
    private struct EventRecord {
        let applications: Set<ApplicationToken>
        let categories: Set<ActivityCategoryToken>
        let webDomains: Set<WebDomainToken>
        let threshold: DateComponents
        let includesPastActivity: Bool

        init(_ event: DeviceActivityEvent) {
            applications = event.applications
            categories = event.categories
            webDomains = event.webDomains
            threshold = event.threshold
            includesPastActivity = event.includesPastActivity
        }

        func event() -> DeviceActivityEvent {
            DeviceActivityEvent(
                applications: applications,
                categories: categories,
                webDomains: webDomains,
                threshold: threshold,
                includesPastActivity: includesPastActivity
            )
        }
    }

    private var records: [DeviceActivityName: (DeviceActivitySchedule, [DeviceActivityEvent.Name: EventRecord])] = [:]

    var activities: [DeviceActivityName] { Array(records.keys) }

    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? {
        records[activity]?.0
    }

    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        records[activity]?.1.mapValues { $0.event() } ?? [:]
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        records[activity] = (schedule, events.mapValues(EventRecord.init))
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        activities.forEach { records.removeValue(forKey: $0) }
    }
}

private final class WatchdogLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
