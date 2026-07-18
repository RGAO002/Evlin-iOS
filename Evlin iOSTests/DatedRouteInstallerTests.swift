import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import Evlin_iOS

@MainActor
final class DatedRouteInstallerTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let start = Date(timeIntervalSince1970: 1_784_889_600)

    func testTwoProcessesClaimOnlyOnceAndLoserHasNoCenterOrStoreSideEffects() throws {
        let fixture = try makeFixture()
        let work = try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart }!
        let appCenter = DatedCenter()
        let monitorCenter = DatedCenter()
        let monitor = DatedRouteInstaller(
            store: fixture.secondStore,
            center: monitorCenter,
            processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()),
            clock: fixture.clock
        )

        let appClaim = try fixture.firstStore.claimInstallWork(
            workID: work.workID,
            owner: owner,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            now: start
        )
        XCTAssertNotNil(appClaim)
        let writesBeforeLoser = fixture.io.writeCount
        XCTAssertNil(try fixture.secondStore.claimInstallWork(
            workID: work.workID,
            owner: owner,
            processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()),
            now: start
        ))
        let second = try monitor.reconcile(ownerChildDeviceID: owner)

        XCTAssertEqual(second, [])
        XCTAssertEqual(appCenter.startCalls.count, 0)
        XCTAssertEqual(monitorCenter.startCalls.count, 0)
        XCTAssertEqual(monitorCenter.inspectionCalls, 0)
        XCTAssertEqual(fixture.io.writeCount, writesBeforeLoser)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.claim?.token, appClaim?.claim.token)
    }

    func testInstallCASRefusesStaleClaim() throws {
        let fixture = try makeFixture()
        let work = try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart }!
        let claim = try fixture.firstStore.claimInstallWork(
            workID: work.workID, owner: owner,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()), now: start
        )!

        XCTAssertFalse(try fixture.firstStore.recordInstalledRoute(workID: work.workID, token: UUID(), owner: owner, now: start))
        XCTAssertFalse(try fixture.firstStore.recordVerifiedRoute(workID: work.workID, token: UUID(), owner: owner, now: start))
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .starting)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.claim, claim.claim)
    }

    func testInstallCASRefusesExpiredClaim() throws {
        let fixture = try makeFixture()
        let work = try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart }!
        let claim = try fixture.firstStore.claimInstallWork(
            workID: work.workID, owner: owner,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()), now: start
        )!

        XCTAssertFalse(try fixture.firstStore.recordInstalledRoute(
            workID: work.workID,
            token: claim.claim.token,
            owner: owner,
            now: start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        ))
        XCTAssertFalse(try fixture.firstStore.recordVerifiedRoute(
            workID: work.workID,
            token: claim.claim.token,
            owner: owner,
            now: start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        ))
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .starting)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.claim, claim.claim)
    }

    func testRegistrationRequiredWaitsForRegistrationButFutureAndOfflineWorkStart() throws {
        let fixture = try makeFixture(leaveAllPending: true)
        let state = try fixture.firstStore.read()
        let work = state.installWork.values.sorted { $0.createdAt < $1.createdAt }
        let today = work.first { $0.authorization == .registrationRequired }!
        let future = work.first { $0.authorization == .futurePlanned }!
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[today.workID]?.authorization = .registrationRequired
            state.installWork[future.workID]?.authorization = .offlinePending
        }
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        let results = try installer.reconcile(ownerChildDeviceID: owner)

        XCTAssertTrue(results.contains(.deferred(workID: today.workID, code: "registrationRequired")))
        XCTAssertFalse(center.startCalls.contains { $0.rawValue == state.routes[today.routeID]!.activityName })
        XCTAssertEqual(center.startCalls.count, 7)
    }

    func testRegistration200ForPlannedTodayRouteAllowsInstallerStartWithoutAuthorizationMutation() async throws {
        let fixture = try makeFixture(leaveAllPending: true)
        let initial = try fixture.firstStore.read()
        let todayWork = try XCTUnwrap(initial.installWork.values.first { $0.authorization == .registrationRequired })
        let todayRoute = try XCTUnwrap(initial.routes[todayWork.routeID])
        let registrationWork = try XCTUnwrap(initial.registrationWork.values.first { $0.routeID == todayRoute.routeID })
        let epoch = try XCTUnwrap(initial.epochs[todayRoute.epochID])
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            for (workID, work) in state.installWork where work.workID != todayWork.workID {
                state.installWork[workID]?.phase = .verified
            }
        }

        let response = HTTPURLResponse(url: URL(string: "https://dated-installer.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let transport = DatedRegistrationTransport(result: (
            try JSONEncoder().encode(EpochRegistrationResponseDTO(
                status: .registered,
                epochID: epoch.epochID,
                meteringProtocolVersion: 2,
                snapshot: DeviceDaySnapshotDTO(
                    childDeviceID: owner,
                    usageDate: todayRoute.usageDate,
                    estimatedMinutes: 0,
                    capMinutes: 40,
                    childDayState: "active",
                    usedMinutes: 0,
                    remainingMinutes: 40,
                    counted: true,
                    warning: nil
                ),
                epochStatus: .active
            )),
            response
        ))
        let delivery = MeteringEpochDelivery(
            baseURL: URL(string: "https://dated-installer.test")!,
            store: fixture.firstStore,
            transport: transport,
            clock: fixture.clock
        )

        await delivery.drain(owner: owner)

        let registered = try fixture.firstStore.read()
        XCTAssertEqual(registered.registrationWork[registrationWork.workID]?.retry.terminal, .succeeded)
        XCTAssertEqual(registered.epochs[epoch.epochID]?.registeredAt, start)
        XCTAssertEqual(registered.installWork[todayWork.workID]?.authorization, .registered)
        XCTAssertEqual(registered.routes[todayRoute.routeID]?.lifecycle, .planned)

        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.secondStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )
        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: todayWork.workID)])
        XCTAssertEqual(center.startCalls, [DeviceActivityName(todayRoute.activityName)])
    }

    func testExpiredLeaseAdoptsExactDaemonRouteWithoutAnotherStart() throws {
        let fixture = try makeFixture()
        let state = try fixture.firstStore.read()
        let work = state.installWork.values.first { $0.phase == .pendingStart }!
        let route = state.routes[work.routeID]!
        let center = DatedCenter()
        center.install(route: route)
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[work.workID]?.phase = .starting
            state.installWork[work.workID]?.claim = ActivityInstallClaim(
                token: UUID(),
                process: .app,
                instanceID: UUID(),
                claimedAt: self.start,
                expiresAt: self.start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
            )
        }
        let installer = DatedRouteInstaller(
            store: fixture.secondStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()),
            clock: fixture.clock
        )

        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds - 0.001)
        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [])
        XCTAssertEqual(center.inspectionCalls, 0)
        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.adopted(workID: work.workID)])
        XCTAssertEqual(center.startCalls.count, 0)
        XCTAssertEqual(center.inspectionCalls, 3)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .verified)
    }

    func testExpiredLeaseReplacesOnlyMismatchedCandidateAndNeverStopsPriorMonitor() throws {
        let fixture = try makeFixture()
        let state = try fixture.firstStore.read()
        let work = state.installWork.values.first { $0.phase == .pendingStart }!
        let route = state.routes[work.routeID]!
        let priorRoute = state.routes.values.first { $0.routeID != route.routeID }!
        let priorWork = state.installWork.values.first { $0.routeID == priorRoute.routeID }!
        let center = DatedCenter()
        center.install(route: priorRoute)
        center.install(route: route, thresholdOverride: 999)
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[priorWork.workID]?.phase = .verified
            state.routes[priorRoute.routeID]?.installedSchedule = priorRoute.plannedSchedule
            state.routes[priorRoute.routeID]?.installedEvents = priorRoute.plannedEvents
            state.installWork[work.workID]?.phase = .starting
            state.installWork[work.workID]?.claim = ActivityInstallClaim(
                token: UUID(), process: .app, instanceID: UUID(), claimedAt: self.start,
                expiresAt: self.start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
            )
        }
        XCTAssertEqual(try fixture.firstStore.read().installWork[priorWork.workID]?.phase, .verified)
        XCTAssertTrue(center.activities.contains(DeviceActivityName(priorRoute.activityName)))
        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        let installer = DatedRouteInstaller(
            store: fixture.secondStore, center: center,
            processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()), clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: work.workID)])
        XCTAssertEqual(center.startCalls, [DeviceActivityName(route.activityName)])
        XCTAssertTrue(center.stopCalls.isEmpty)
        XCTAssertTrue(center.activities.contains(DeviceActivityName(priorRoute.activityName)))
    }

    func testExcessiveActivitiesKeepsVerifiedWorkAndMarksCoverageInstallLimited() throws {
        let fixture = try makeFixture(leaveAllPending: true)
        let state = try fixture.firstStore.read()
        XCTAssertNil(state.coverage)
        let first = try work(forUsageDate: "2026-07-18", in: state)
        let nonContiguousVerified = try work(forUsageDate: "2026-07-20", in: state)
        let verifiedRoute = state.routes[first.routeID]!
        let laterVerifiedRoute = state.routes[nonContiguousVerified.routeID]!
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[first.workID]?.phase = .verified
            state.installWork[nonContiguousVerified.workID]?.phase = .verified
            guard var route = state.routes[first.routeID] else { return }
            route.installedSchedule = route.plannedSchedule
            route.installedEvents = route.plannedEvents
            state.routes[first.routeID] = route
            guard var laterRoute = state.routes[nonContiguousVerified.routeID] else { return }
            laterRoute.installedSchedule = laterRoute.plannedSchedule
            laterRoute.installedEvents = laterRoute.plannedEvents
            state.routes[nonContiguousVerified.routeID] = laterRoute
        }
        let center = DatedCenter()
        center.install(route: verifiedRoute)
        center.install(route: laterVerifiedRoute)
        center.startError = DeviceActivityCenter.MonitoringError.excessiveActivities
        let installer = DatedRouteInstaller(
            store: fixture.firstStore, center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()), clock: fixture.clock
        )

        _ = try installer.reconcile(ownerChildDeviceID: owner)

        let persisted = try fixture.firstStore.read()
        XCTAssertEqual(persisted.installWork[first.workID]?.phase, .verified)
        XCTAssertEqual(persisted.coverage?.status, .installLimited)
        XCTAssertEqual(persisted.coverage?.readyThroughUsageDate, "2026-07-18")
        XCTAssertTrue(center.activities.contains(DeviceActivityName(verifiedRoute.activityName)))
        let nextWork = try work(forUsageDate: "2026-07-19", in: persisted)
        XCTAssertEqual(nextWork.phase, .pendingStart)
        XCTAssertEqual(nextWork.retry.attemptCount, 0)
    }

    func testEightRoutesStartOnceThenOneHundredTwentyPollsCauseNoChurn() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore, center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()), clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner).count, 8)
        XCTAssertEqual(center.startCalls.count, 8)
        for _ in 0..<120 {
            fixture.clock.date = fixture.clock.date.addingTimeInterval(10)
            XCTAssertTrue(try installer.reconcile(ownerChildDeviceID: owner).isEmpty)
        }
        XCTAssertEqual(center.startCalls.count, 8)
        XCTAssertTrue(center.stopCalls.isEmpty)
    }

    func testCrashAfterClaimResumesWithOneStart() throws {
        try assertCrashAfterClaimRecoversByStartingOnce()
    }

    func testCrashAfterAppleStartAdoptsWithoutDuplicateStart() throws {
        try assertCrashAfterAppleStartAdoptsWithoutAnotherStart()
    }

    func testCrashAfterPersistedInstallVerifiesWithoutDuplicateStart() throws {
        try assertCrashAfterPersistedInstallVerifiesWithoutAnotherStart()
    }

    func testCrashAfterVerificationDoesNoFurtherWork() throws {
        try assertCrashAfterVerificationDoesNoFurtherWork()
    }

    private func assertCrashAfterClaimRecoversByStartingOnce() throws {
        let fixture = try makeFixture()
        let work = try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart }!
        let identity = MeteringProcessIdentity(role: .app, instanceID: UUID())
        let claim = try XCTUnwrap(fixture.firstStore.claimInstallWork(workID: work.workID, owner: owner, processIdentity: identity, now: start))
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .starting)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.claim, claim.claim)
        let center = DatedCenter()
        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        let installer = DatedRouteInstaller(store: fixture.secondStore, center: center, processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()), clock: fixture.clock)

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: work.workID)])
        XCTAssertEqual(center.startCalls.count, 1)
    }

    private func assertCrashAfterAppleStartAdoptsWithoutAnotherStart() throws {
        let fixture = try makeFixture()
        let state = try fixture.firstStore.read()
        let work = state.installWork.values.first { $0.phase == .pendingStart }!
        let route = state.routes[work.routeID]!
        let identity = MeteringProcessIdentity(role: .app, instanceID: UUID())
        let claim = try XCTUnwrap(fixture.firstStore.claimInstallWork(workID: work.workID, owner: owner, processIdentity: identity, now: start))
        let center = DatedCenter()
        center.start(route: route)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .starting)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.claim, claim.claim)
        XCTAssertTrue(center.activities.contains(DeviceActivityName(route.activityName)))
        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        let installer = DatedRouteInstaller(store: fixture.secondStore, center: center, processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()), clock: fixture.clock)

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.adopted(workID: work.workID)])
        XCTAssertEqual(center.startCalls.count, 1)
    }

    private func assertCrashAfterPersistedInstallVerifiesWithoutAnotherStart() throws {
        let fixture = try makeFixture()
        let state = try fixture.firstStore.read()
        let work = state.installWork.values.first { $0.phase == .pendingStart }!
        let route = state.routes[work.routeID]!
        let identity = MeteringProcessIdentity(role: .app, instanceID: UUID())
        let claim = try fixture.firstStore.claimInstallWork(workID: work.workID, owner: owner, processIdentity: identity, now: start)!
        let center = DatedCenter()
        center.start(route: route)
        XCTAssertTrue(try fixture.firstStore.recordInstalledRoute(workID: work.workID, token: claim.claim.token, owner: owner, now: start))
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .installed)
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.claim, claim.claim)
        XCTAssertTrue(center.activities.contains(DeviceActivityName(route.activityName)))
        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        let installer = DatedRouteInstaller(store: fixture.secondStore, center: center, processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()), clock: fixture.clock)

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: work.workID)])
        XCTAssertEqual(center.startCalls.count, 1)
    }

    private func assertCrashAfterVerificationDoesNoFurtherWork() throws {
        let fixture = try makeFixture()
        let work = try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart }!
        let center = DatedCenter()
        let installer = DatedRouteInstaller(store: fixture.firstStore, center: center, processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()), clock: fixture.clock)

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: work.workID)])
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .verified)
        XCTAssertNil(try fixture.firstStore.read().installWork[work.workID]?.claim)
        let verifiedRoute = try XCTUnwrap(try fixture.firstStore.read().routes[work.routeID])
        XCTAssertTrue(center.activities.contains(DeviceActivityName(verifiedRoute.activityName)))
        XCTAssertTrue(try installer.reconcile(ownerChildDeviceID: owner).isEmpty)
        XCTAssertEqual(center.startCalls.count, 1)
    }

    private func makeFixture(leaveAllPending: Bool = false, registeredAll: Bool = false) throws -> DatedFixture {
        let io = DatedFileIO()
        let lock = DatedLock()
        let makeStore = {
            DeviceEpochStore(
                fileURL: URL(fileURLWithPath: "/tmp/evlin-dated-installer-test.json"),
                lock: lock,
                fileIO: io,
                ownerProvider: { self.owner }
            )
        }
        let store = makeStore()
        let clock = DatedClock(date: start)
        let selection = try JSONEncoder().encode(FamilyActivitySelection())
        let key = MeteringGenerationKey(
            protocolVersion: 2, childDeviceID: owner, canonicalTimezone: "America/New_York",
            policyRevision: "r1", measurementSelectionDigest: MeteringEpochContract.selectionDigest(persistedBytes: selection),
            enforcementSetID: UUID()
        )
        _ = try store.reconcileMeteringHorizon(MeteringHorizonRequest(
            ownerChildDeviceID: owner, today: "2026-07-18", generationKey: key,
            persistedSelectionBytes: selection, poolMinutes: 40, deviceCapMinutes: 40,
            authoritativeBaseAcceptedMinutes: 0, now: start
        ))
        if !leaveAllPending || registeredAll {
            try store.transaction(expectedOwner: owner) { state in
                let candidateWorkID = try! work(forUsageDate: "2026-07-18", in: state).workID
                for key in state.installWork.keys {
                    if registeredAll { state.installWork[key]?.authorization = .registered }
                    if !leaveAllPending && key == candidateWorkID {
                        state.installWork[key]?.authorization = .registered
                    }
                    if !leaveAllPending && key != candidateWorkID { state.installWork[key]?.phase = .verified }
                }
            }
        }
        return DatedFixture(firstStore: store, secondStore: makeStore(), clock: clock, io: io)
    }

    private func work(forUsageDate usageDate: String, in state: DeviceEpochStoreState) throws -> ActivityInstallWork {
        let route = try XCTUnwrap(state.routes.values.first { $0.usageDate == usageDate })
        return try XCTUnwrap(state.installWork.values.first { $0.routeID == route.routeID })
    }
}

private struct DatedFixture {
    let firstStore: DeviceEpochStore
    let secondStore: DeviceEpochStore
    let clock: DatedClock
    let io: DatedFileIO
}

private final class DatedClock: MeteringClock, @unchecked Sendable {
    var date: Date
    init(date: Date) { self.date = date }
    var now: Date { date }
}

@MainActor
private final class DatedCenter: MeteringDeviceActivityCenter {
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
    var startCalls: [DeviceActivityName] = []
    var stopCalls: [[DeviceActivityName]] = []
    var inspectionCalls = 0
    var startError: Error?

    var activities: [DeviceActivityName] { inspectionCalls += 1; return Array(records.keys) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { inspectionCalls += 1; return records[activity]?.0 }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        inspectionCalls += 1
        return records[activity]?.1.mapValues { $0.event() } ?? [:]
    }
    func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) throws {
        startCalls.append(activity)
        if let startError { throw startError }
        records[activity] = (schedule, events.mapValues(EventRecord.init))
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) { stopCalls.append(activities); activities.forEach { records.removeValue(forKey: $0) } }

    func install(route: MeteringCallbackRoute, thresholdOverride: Int? = nil) {
        let schedule = try! MeteringDatedSchedule.datedSchedule(usageDate: route.usageDate, timeZone: TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)!)
        let selection = FamilyActivitySelection()
        let events = Dictionary(uniqueKeysWithValues: route.plannedEvents.map { plan in
            let threshold = thresholdOverride ?? plan.thresholdMinutes
            return (DeviceActivityEvent.Name(plan.eventName), MeteringDatedSchedule.makeEvent(selection: selection, thresholdMinutes: threshold))
        })
        records[DeviceActivityName(route.activityName)] = (schedule, events.mapValues(EventRecord.init))
    }

    func start(route: MeteringCallbackRoute) {
        startCalls.append(DeviceActivityName(route.activityName))
        install(route: route)
    }
}

private final class DatedLock: DeviceEpochStoreLocking, @unchecked Sendable {
    func withLock<T>(_ body: () -> T) -> T? { body() }
}

private final class DatedFileIO: DeviceEpochFileIO, @unchecked Sendable {
    var data: Data?
    var writeCount = 0
    func read(from url: URL) throws -> Data? { data }
    func writeAtomically(_ data: Data, to url: URL) throws { self.data = data; writeCount += 1 }
}

private final class DatedRegistrationTransport: MeteringHTTPTransport, @unchecked Sendable {
    private var result: (Data, URLResponse)?

    init(result: (Data, URLResponse)) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let result else { throw URLError(.badServerResponse) }
        self.result = nil
        return result
    }
}
