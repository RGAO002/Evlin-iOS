import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import Evlin_iOS

@MainActor
final class MeteringCoverageIntegrationTests: XCTestCase {
    private let owner = UUID(uuidString: "20000000-0000-4000-8000-000000000020")!
    private let start = ISO8601DateFormatter().date(from: "2026-07-18T16:00:00Z")!

    func testAuthoritativeRefreshAppendsOneTailAndKeepsExistingSevenRoutes() throws {
        let fixture = try makeFixture()
        try fixture.installAll()

        let firstCoverage = try fixture.installer.refreshCoverage(ownerChildDeviceID: owner)
        let firstState = try fixture.store.read()
        let firstIDs = Dictionary(uniqueKeysWithValues: firstState.routes.values.map {
            ($0.usageDate, $0.routeID)
        })

        XCTAssertEqual(firstCoverage?.status, .ready)
        XCTAssertEqual(firstCoverage?.requiredFromUsageDate, "2026-07-18")
        XCTAssertEqual(firstCoverage?.requiredThroughUsageDate, "2026-07-25")
        XCTAssertEqual(firstCoverage?.readyThroughUsageDate, "2026-07-25")
        XCTAssertEqual(fixture.center.startCalls.count, 8)

        fixture.clock.date = ISO8601DateFormatter().date(from: "2026-07-19T16:00:00Z")!
        _ = try fixture.plan(today: "2026-07-19")
        try fixture.authorizeCurrentDate("2026-07-19")
        _ = try fixture.installer.reconcile(ownerChildDeviceID: owner)
        let secondCoverage = try fixture.installer.refreshCoverage(ownerChildDeviceID: owner)
        let secondState = try fixture.store.read()

        XCTAssertEqual(secondCoverage?.status, .ready)
        XCTAssertEqual(secondCoverage?.requiredFromUsageDate, "2026-07-19")
        XCTAssertEqual(secondCoverage?.requiredThroughUsageDate, "2026-07-26")
        XCTAssertEqual(secondCoverage?.readyThroughUsageDate, "2026-07-26")
        XCTAssertEqual(fixture.center.startCalls.count, 9)
        for usageDate in try MeteringHorizonPlanner.requiredUsageDates(
            today: "2026-07-19",
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        ).dropLast() {
            XCTAssertEqual(secondState.routes.values.first { $0.usageDate == usageDate }?.routeID, firstIDs[usageDate])
        }
    }

    func testExpiredCoverageRejectsPreviouslyValidCallbackWithoutStoppingRoutes() throws {
        let fixture = try makeFixture()
        try fixture.installAll()
        try fixture.activateRoute(on: "2026-07-18")
        _ = try fixture.installer.refreshCoverage(ownerChildDeviceID: owner)

        fixture.clock.date = ISO8601DateFormatter().date(from: "2026-07-26T16:00:00Z")!
        let exhausted = try fixture.installer.refreshCoverage(ownerChildDeviceID: owner)
        let before = try fixture.store.read()
        let route = try XCTUnwrap(before.routes.values.first { $0.usageDate == "2026-07-18" })
        let event = try XCTUnwrap(route.plannedEvents.first)

        let outcome = try EarnedMeteringCallback(
            store: fixture.store,
            clock: fixture.clock
        ).handle(
            MeteringAppleCallback(
                activityName: route.activityName,
                eventName: event.eventName,
                observedAt: fixture.clock.now
            ),
            expectedOwnerChildDeviceID: owner
        )

        XCTAssertEqual(exhausted?.status, .coverageExhausted)
        XCTAssertEqual(outcome, .discarded(reason: "epoch_not_active"))
        XCTAssertEqual(try fixture.store.read(), before)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testInstallLimitedStillAcceptsCallbacksForVerifiedCoveredDate() throws {
        let fixture = try makeFixture()
        try fixture.installFirstFourDates()
        fixture.center.rejectStarts = true
        _ = try fixture.installer.reconcile(ownerChildDeviceID: owner)
        try fixture.activateRoute(on: "2026-07-18")
        let coverage = try fixture.installer.refreshCoverage(ownerChildDeviceID: owner)
        let state = try fixture.store.read()
        let route = try XCTUnwrap(state.routes.values.first { $0.usageDate == "2026-07-18" })
        let event = try XCTUnwrap(route.plannedEvents.first)
        fixture.clock.date = start.addingTimeInterval(TimeInterval(event.thresholdMinutes * 60))

        let outcome = try EarnedMeteringCallback(
            store: fixture.store,
            clock: fixture.clock
        ).handle(
            MeteringAppleCallback(
                activityName: route.activityName,
                eventName: event.eventName,
                observedAt: fixture.clock.now
            ),
            expectedOwnerChildDeviceID: owner
        )

        XCTAssertEqual(coverage?.status, .installLimited)
        XCTAssertEqual(coverage?.readyThroughUsageDate, "2026-07-21")
        guard case .queued = outcome else {
            return XCTFail("expected covered callback to queue, got \(outcome)")
        }
        XCTAssertEqual(try fixture.store.read().sampleWork.count, 1)
        XCTAssertTrue(fixture.center.stopCalls.isEmpty)
    }

    func testCoverageExhaustionAuthorizesOnlyTheExactExpiredEarnedShieldReference() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-coverage-release-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DeviceEpochStore(fileURL: url, ownerProvider: { self.owner })
        let selectionBytes = try JSONEncoder().encode(FamilyActivitySelection())
        let generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "coverage-r1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: UUID(uuidString: "20000000-0000-4000-8000-000000000021")!
        )
        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-18",
            generationKey: generationKey,
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 40,
            deviceCapMinutes: 40,
            authoritativeBaseAcceptedMinutes: 0,
            now: start
        ))
        let planned = try store.read()
        let plannedRoute = try XCTUnwrap(planned.routes.values.first { $0.usageDate == "2026-07-18" })
        try store.transaction(expectedOwner: owner) { state in
            state.routes[plannedRoute.routeID]?.lifecycle = .active
            state.epochs[plannedRoute.epochID]?.status = .active
            state.activeGenerationID = plannedRoute.generationID
            state.activeEpochID = plannedRoute.epochID
            state.activeRouteID = plannedRoute.routeID
        }
        let active = try store.read()
        let route = try XCTUnwrap(active.routes.values.first { $0.usageDate == "2026-07-18" })
        let reference = EarnedShieldReference(
            operationID: UUID(),
            ownerChildDeviceID: owner,
            generationID: route.generationID,
            epochID: route.epochID,
            routeID: route.routeID,
            recordKey: "earned-time",
            expectedRecordBytes: Data([1, 2, 3]),
            retry: MeteringRetryState(
                attemptCount: 0,
                nextAttemptAt: start,
                lastErrorCode: nil,
                terminal: .pending
            ),
            createdAt: start
        )

        XCTAssertTrue(try store.createOrVerifyEarnedShieldReference(reference))
        XCTAssertFalse(try store.canReleaseEarnedShieldReference(reference))

        try store.transaction(expectedOwner: owner) { state in
            state.coverage = MonitorCoverageState(
                ownerChildDeviceID: self.owner,
                requiredFromUsageDate: "2026-07-19",
                requiredThroughUsageDate: "2026-07-26",
                readyThroughUsageDate: nil,
                status: .coverageExhausted,
                refreshedAt: self.start,
                errorCode: "horizon_expired"
            )
        }

        let wrongReference = EarnedShieldReference(
            operationID: reference.operationID,
            ownerChildDeviceID: reference.ownerChildDeviceID,
            generationID: reference.generationID,
            epochID: reference.epochID,
            routeID: reference.routeID,
            recordKey: reference.recordKey,
            expectedRecordBytes: Data([9, 9, 9]),
            retry: reference.retry,
            createdAt: reference.createdAt
        )
        XCTAssertFalse(try store.canReleaseEarnedShieldReference(wrongReference))
        XCTAssertTrue(try store.canReleaseEarnedShieldReference(reference))
    }

    private func makeFixture() throws -> CoverageFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-coverage-\(UUID().uuidString).json")
        let store = DeviceEpochStore(fileURL: url, ownerProvider: { self.owner })
        let clock = CoverageClock(date: start)
        let center = CoverageCenter()
        let installer = DatedRouteInstaller(
            store: store,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: clock
        )
        let fixture = CoverageFixture(
            owner: owner,
            storeURL: url,
            store: store,
            center: center,
            installer: installer,
            clock: clock
        )
        _ = try fixture.plan(today: "2026-07-18")
        try fixture.authorizeCurrentDate("2026-07-18")
        return fixture
    }
}

@MainActor
private final class CoverageFixture {
    let owner: UUID
    let storeURL: URL
    let store: DeviceEpochStore
    let center: CoverageCenter
    let installer: DatedRouteInstaller
    let clock: CoverageClock
    private let selectionBytes: Data
    private let generationKey: MeteringGenerationKey

    init(
        owner: UUID,
        storeURL: URL,
        store: DeviceEpochStore,
        center: CoverageCenter,
        installer: DatedRouteInstaller,
        clock: CoverageClock
    ) {
        self.owner = owner
        self.storeURL = storeURL
        self.store = store
        self.center = center
        self.installer = installer
        self.clock = clock
        selectionBytes = try! JSONEncoder().encode(FamilyActivitySelection())
        generationKey = MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "coverage-r1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: selectionBytes
            ),
            enforcementSetID: UUID(uuidString: "20000000-0000-4000-8000-000000000021")!
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: storeURL)
    }

    func plan(today: String) throws -> MeteringHorizonPlan {
        try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: today,
            generationKey: generationKey,
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 40,
            deviceCapMinutes: 40,
            authoritativeBaseAcceptedMinutes: 0,
            now: clock.now
        ))
    }

    func authorizeCurrentDate(_ usageDate: String) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes.values.first(where: { $0.usageDate == usageDate }) else { return }
            for workID in state.installWork.keys where state.installWork[workID]?.routeID == route.routeID {
                state.installWork[workID]?.authorization = .registered
            }
            state.epochs[route.epochID]?.registeredAt = self.clock.now
        }
    }

    func installAll() throws {
        _ = try installer.reconcile(ownerChildDeviceID: owner)
    }

    func installFirstFourDates() throws {
        let state = try store.read()
        let routes = state.routes.values.sorted { $0.usageDate < $1.usageDate }
        for route in routes.prefix(4) {
            center.install(route: route, selectionBytes: selectionBytes)
            try store.transaction(expectedOwner: owner) { state in
                guard let workID = state.installWork.first(where: { $0.value.routeID == route.routeID })?.key else { return }
                state.installWork[workID]?.phase = .verified
                state.routes[route.routeID]?.installedSchedule = route.plannedSchedule
                state.routes[route.routeID]?.installedEvents = route.plannedEvents
            }
        }
    }

    func activateRoute(on usageDate: String) throws {
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes.values.first(where: { $0.usageDate == usageDate }),
                  let installID = state.installWork.first(where: { $0.value.routeID == route.routeID })?.key
            else { return }
            state.routes[route.routeID]?.lifecycle = .active
            state.installWork[installID]?.authorization = .registered
            state.installWork[installID]?.phase = .active
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = route.routeID
            state.epochs[route.epochID]?.registeredAt = self.clock.now
            state.ratchets[self.owner] = MeteringOwnerRatchet(
                ownerChildDeviceID: self.owner,
                advertisedVersion: 2,
                localSelection: .v2,
                registeredV2At: self.clock.now,
                dualActiveAt: nil,
                activatedV2At: self.clock.now
            )
        }
    }
}

private final class CoverageClock: MeteringClock, @unchecked Sendable {
    var date: Date
    init(date: Date) { self.date = date }
    var now: Date { date }
}

@MainActor
private final class CoverageCenter: MeteringDeviceActivityCenter {
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

        func value() -> DeviceActivityEvent {
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
    var startCalls: [DeviceActivityName] = []
    var stopCalls: [[DeviceActivityName]] = []
    var rejectStarts = false

    var activities: [DeviceActivityName] { Array(records.keys) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { records[activity]?.0 }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        records[activity]?.1.mapValues { $0.value() } ?? [:]
    }
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startCalls.append(activity)
        if rejectStarts {
            throw DeviceActivityCenter.MonitoringError.excessiveActivities
        }
        records[activity] = (schedule, events.mapValues(EventRecord.init))
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities)
        for activity in activities { records.removeValue(forKey: activity) }
    }

    func install(route: MeteringCallbackRoute, selectionBytes: Data) {
        let timeZone = TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)!
        let schedule = try! MeteringDatedSchedule.datedSchedule(
            usageDate: route.usageDate,
            timeZone: timeZone
        )
        let selection = try! JSONDecoder().decode(FamilyActivitySelection.self, from: selectionBytes)
        let events = Dictionary(uniqueKeysWithValues: route.plannedEvents.map { plan in
            (
                DeviceActivityEvent.Name(plan.eventName),
                MeteringDatedSchedule.makeEvent(
                    selection: selection,
                    thresholdMinutes: plan.thresholdMinutes
                )
            )
        })
        records[DeviceActivityName(route.activityName)] = (
            schedule,
            events.mapValues(EventRecord.init)
        )
    }
}
