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

    func testDAMLeavesCurrentDayStartForAppOwner() throws {
        let fixture = try makeFixture()
        let initial = try fixture.firstStore.read()
        let work = try work(forUsageDate: "2026-07-18", in: initial)
        let route = try XCTUnwrap(initial.routes[work.routeID])
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)
        )
        let currentDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 12
        )))
        fixture.clock.date = currentDay
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.routes[route.routeID]?.plannedSchedule = DatedSchedulePlan(
                usageDate: route.plannedSchedule.usageDate,
                timezoneIdentifier: route.plannedSchedule.timezoneIdentifier,
                calendarIdentifier: route.plannedSchedule.calendarIdentifier,
                intervalStartAt: currentDay
            )
            for key in state.installWork.keys {
                state.installWork[key]?.retry.nextAttemptAt =
                    key == work.workID
                        ? currentDay
                        : currentDay.addingTimeInterval(24 * 60 * 60)
            }
        }
        let center = DatedCenter()
        let dam = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(
                role: .deviceActivityMonitor,
                instanceID: UUID()
            ),
            clock: fixture.clock
        )

        XCTAssertEqual(try dam.reconcile(ownerChildDeviceID: owner), [])
        XCTAssertTrue(center.startCalls.isEmpty)
        XCTAssertEqual(
            try fixture.firstStore.read().installWork[work.workID]?.phase,
            .pendingStart
        )

        let app = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )
        XCTAssertEqual(
            try app.reconcile(ownerChildDeviceID: owner),
            [.verified(workID: work.workID)]
        )
        XCTAssertEqual(center.startCalls, [DeviceActivityName(route.activityName)])
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

    func testCurrentDayInstallClaimPinsStartOnceAndCrashRetryKeepsSameStart() throws {
        let fixture = try makeFixture()
        let state = try fixture.firstStore.read()
        let work = try work(forUsageDate: "2026-07-18", in: state)
        let route = try XCTUnwrap(state.routes[work.routeID])
        let timeZone = try XCTUnwrap(TimeZone(identifier: route.plannedSchedule.timezoneIdentifier))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let firstInstallAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 14,
            minute: 37,
            second: 12
        )))
        fixture.clock.date = firstInstallAt
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[work.workID]?.retry.nextAttemptAt = firstInstallAt
        }

        let firstClaim = try XCTUnwrap(fixture.firstStore.claimInstallWork(
            workID: work.workID,
            owner: owner,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            now: firstInstallAt
        ))
        XCTAssertEqual(
            try fixture.firstStore.read().routes[route.routeID]?.plannedSchedule.intervalStartAt,
            firstInstallAt
        )

        let retryAt = firstInstallAt.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        let retryClaim = try XCTUnwrap(fixture.secondStore.claimInstallWork(
            workID: work.workID,
            owner: owner,
            processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()),
            now: retryAt
        ))

        XCTAssertNotEqual(firstClaim.claim.token, retryClaim.claim.token)
        XCTAssertEqual(
            try fixture.secondStore.read().routes[route.routeID]?.plannedSchedule.intervalStartAt,
            firstInstallAt
        )
        let futureRoute = try XCTUnwrap(
            try fixture.secondStore.read().routes.values.first { $0.usageDate == "2026-07-19" }
        )
        XCTAssertNil(futureRoute.plannedSchedule.intervalStartAt)
    }

    func testZeroProgressActiveMidnightRouteMigratesOnceAndReturnsToActiveAfterVerification() throws {
        let fixture = try makeFixture()
        let initial = try fixture.firstStore.read()
        let work = try work(forUsageDate: "2026-07-18", in: initial)
        let route = try XCTUnwrap(initial.routes[work.routeID])
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: route.plannedSchedule.timezoneIdentifier))
        let migrationAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 15,
            minute: 4
        )))
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = route.routeID
            state.routes[route.routeID]?.lifecycle = .active
            state.routes[route.routeID]?.plannedSchedule = DatedSchedulePlan(
                usageDate: route.plannedSchedule.usageDate,
                timezoneIdentifier: route.plannedSchedule.timezoneIdentifier,
                calendarIdentifier: route.plannedSchedule.calendarIdentifier,
                topologyVersion: nil
            )
            state.installWork[work.workID]?.phase = .active
        }

        XCTAssertEqual(
            try fixture.firstStore.prepareCurrentDayInstallStartMigrationIfNeeded(
                owner: owner,
                now: migrationAt
            ),
            work.workID
        )
        XCTAssertNil(try fixture.firstStore.prepareCurrentDayInstallStartMigrationIfNeeded(
            owner: owner,
            now: migrationAt.addingTimeInterval(60)
        ))
        var migrated = try fixture.firstStore.read()
        XCTAssertEqual(migrated.routes[route.routeID]?.plannedSchedule.intervalStartAt, migrationAt)
        XCTAssertEqual(migrated.installWork[work.workID]?.phase, .pendingStart)

        fixture.clock.date = migrationAt
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )
        XCTAssertEqual(
            try installer.reconcile(ownerChildDeviceID: owner),
            [.verified(workID: work.workID)]
        )
        let installedSchedule = try XCTUnwrap(
            center.schedule(for: DeviceActivityName(route.activityName))
        )
        XCTAssertEqual(calendar.date(from: installedSchedule.intervalStart), migrationAt)
        XCTAssertTrue(try fixture.firstStore.finalizeCurrentDayInstallStartMigrationIfNeeded(owner: owner))
        migrated = try fixture.firstStore.read()
        XCTAssertEqual(migrated.installWork[work.workID]?.phase, .active)
    }

    func testActiveMidnightRouteWithAcceptedRawProgressIsNotMigratedInPlace() throws {
        let fixture = try makeFixture()
        let initial = try fixture.firstStore.read()
        let work = try work(forUsageDate: "2026-07-18", in: initial)
        let route = try XCTUnwrap(initial.routes[work.routeID])
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: route.plannedSchedule.timezoneIdentifier))
        let migrationAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 15,
            minute: 4
        )))
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = route.routeID
            state.routes[route.routeID]?.lifecycle = .active
            state.routes[route.routeID]?.plannedSchedule = DatedSchedulePlan(
                usageDate: route.plannedSchedule.usageDate,
                timezoneIdentifier: route.plannedSchedule.timezoneIdentifier,
                calendarIdentifier: route.plannedSchedule.calendarIdentifier,
                topologyVersion: nil
            )
            state.epochs[route.epochID]?.lastRawThresholdMinutes = 5
            state.installWork[work.workID]?.phase = .active
        }

        XCTAssertNil(try fixture.firstStore.prepareCurrentDayInstallStartMigrationIfNeeded(
            owner: owner,
            now: migrationAt
        ))
        XCTAssertNil(
            try fixture.firstStore.read().routes[route.routeID]?.plannedSchedule.intervalStartAt
        )
        XCTAssertEqual(try fixture.firstStore.read().installWork[work.workID]?.phase, .active)
    }

    func testZeroProgressCurrentDayRouteUpgradesOlderEventTopologyToCanonicalMidnight() throws {
        let fixture = try makeFixture()
        let initial = try fixture.firstStore.read()
        let work = try work(forUsageDate: "2026-07-18", in: initial)
        let route = try XCTUnwrap(initial.routes[work.routeID])
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)
        )
        let originalStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 14,
            minute: 30
        )))
        let upgradeAt = originalStart.addingTimeInterval(600)

        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = route.generationID
            state.activeEpochID = route.epochID
            state.activeRouteID = route.routeID
            state.routes[route.routeID]?.lifecycle = .active
            state.routes[route.routeID]?.plannedSchedule = DatedSchedulePlan(
                usageDate: route.plannedSchedule.usageDate,
                timezoneIdentifier: route.plannedSchedule.timezoneIdentifier,
                calendarIdentifier: route.plannedSchedule.calendarIdentifier,
                topologyVersion: 2,
                intervalStartAt: originalStart
            )
            state.installWork[work.workID]?.phase = .active
        }

        XCTAssertEqual(
            try fixture.firstStore.prepareCurrentDayInstallStartMigrationIfNeeded(
                owner: owner,
                now: upgradeAt
            ),
            work.workID
        )
        let upgraded = try fixture.firstStore.read()
        let canonicalMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18
        )))
        XCTAssertEqual(
            upgraded.routes[route.routeID]?.plannedSchedule.topologyVersion,
            DatedSchedulePlan.currentTopologyVersion
        )
        XCTAssertEqual(
            upgraded.routes[route.routeID]?.plannedSchedule.intervalStartAt,
            canonicalMidnight
        )
        XCTAssertEqual(upgraded.installWork[work.workID]?.phase, .pendingStart)
    }

    func testDeferredInstallCASRefusesExpiredClaimAndInstallerReportsClaimLost() throws {
        let fixture = try makeFixture()
        let work = try XCTUnwrap(
            try fixture.firstStore.dueInstallWork(owner: owner, now: start).first
        )
        let center = DatedCenter()
        center.startError = DeviceActivityCenter.MonitoringError.excessiveActivities
        center.onStart = { fixture.clock.date = self.start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds) }
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.deferred(workID: work.workID, code: "claimLost")])

        let persisted = try fixture.firstStore.read().installWork[work.workID]
        XCTAssertEqual(persisted?.phase, .starting)
        XCTAssertNotNil(persisted?.claim)
        XCTAssertEqual(persisted?.retry.attemptCount, 0)
    }

    func testExcessiveActivitiesStopsFillingWhenLeaseExpiresBeforeDeferCAS() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let work = try XCTUnwrap(
            try fixture.firstStore.dueInstallWork(owner: owner, now: start).first
        )
        let center = DatedCenter()
        center.startError = DeviceActivityCenter.MonitoringError.excessiveActivities
        center.onStart = { fixture.clock.date = self.start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds) }
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.deferred(workID: work.workID, code: "claimLost")])

        let persisted = try fixture.firstStore.read()
        XCTAssertEqual(center.startCalls.count, 1)
        XCTAssertEqual(persisted.installWork[work.workID]?.phase, .starting)
        XCTAssertEqual(persisted.installWork[work.workID]?.retry.attemptCount, 0)
        XCTAssertTrue(persisted.installWork.values.filter { $0.workID != work.workID }.allSatisfy {
            $0.claim == nil && $0.phase == .pendingStart && $0.retry.attemptCount == 0
        })
    }

    func testReconcileStopsOnlyOrphanedV2EarnedActivitiesBeforeInstalling() throws {
        let fixture = try makeFixture()
        var state = try fixture.firstStore.read()
        let currentRoute = try XCTUnwrap(state.routes.values.first { $0.usageDate == "2026-07-18" })
        let currentWork = try XCTUnwrap(
            state.installWork.values.first { $0.routeID == currentRoute.routeID }
        )
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[currentWork.workID]?.retry.lastErrorCode = "excessiveActivities"
            state.installWork[currentWork.workID]?.retry.attemptCount = 4
            state.installWork[currentWork.workID]?.retry.nextAttemptAt =
                self.start.addingTimeInterval(3_600)
        }
        state = try fixture.firstStore.read()
        let orphanRouteID = UUID()
        let orphanRoute = MeteringCallbackRoute(
            routeID: orphanRouteID,
            activityName: MeteringRouteNamespace.activityName(routeID: orphanRouteID),
            namespace: MeteringRouteNamespace.prefix,
            generationID: currentRoute.generationID,
            generationKey: currentRoute.generationKey,
            ownerChildDeviceID: owner,
            usageDate: currentRoute.usageDate,
            epochID: currentRoute.epochID,
            plannedSchedule: currentRoute.plannedSchedule,
            installedSchedule: currentRoute.installedSchedule,
            plannedEvents: currentRoute.plannedEvents,
            installedEvents: currentRoute.installedEvents,
            lifecycle: .active,
            createdAt: start
        )
        let center = DatedCenter()
        center.install(route: orphanRoute)
        center.installOpaqueActivity(named: "evlin.limit.v2.keep")
        center.installOpaqueActivity(named: "evlin.bigkid.freeplay")
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        _ = try installer.reconcile(ownerChildDeviceID: owner)

        XCTAssertFalse(center.activities.contains(DeviceActivityName(orphanRoute.activityName)))
        XCTAssertTrue(center.activities.contains(DeviceActivityName("evlin.limit.v2.keep")))
        XCTAssertTrue(center.activities.contains(DeviceActivityName("evlin.bigkid.freeplay")))
        XCTAssertTrue(center.stopCalls.contains([DeviceActivityName(orphanRoute.activityName)]))
        XCTAssertTrue(center.startCalls.contains(DeviceActivityName(currentRoute.activityName)))
        let repairedWork = try XCTUnwrap(
            try fixture.firstStore.read().installWork[currentWork.workID]
        )
        XCTAssertEqual(repairedWork.phase, .verified)
    }

    func testReconcileCollectsRetiredGenerationAfterDaemonConfirmsItsActivitiesAreAbsent() throws {
        let fixture = try makeFixture()
        let retired = try addRetiredGeneration(to: fixture.firstStore)
        let center = DatedCenter()
        center.install(route: retired.route)
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        _ = try installer.reconcile(ownerChildDeviceID: owner)

        let persisted = try fixture.firstStore.read()
        XCTAssertTrue(center.stopCalls.contains([DeviceActivityName(retired.route.activityName)]))
        XCTAssertNil(persisted.generations[retired.generationID])
        XCTAssertNil(persisted.epochs[retired.epochID])
        XCTAssertNil(persisted.routes[retired.route.routeID])
        XCTAssertFalse(persisted.installWork.values.contains { $0.routeID == retired.route.routeID })
    }

    func testReconcilePreservesRetiredGenerationReferencedByShieldReceipt() throws {
        let fixture = try makeFixture()
        let retired = try addRetiredGeneration(to: fixture.firstStore, addShieldReference: true)
        let center = DatedCenter()
        center.install(route: retired.route)
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        _ = try installer.reconcile(ownerChildDeviceID: owner)

        let persisted = try fixture.firstStore.read()
        XCTAssertTrue(center.stopCalls.contains([DeviceActivityName(retired.route.activityName)]))
        XCTAssertNotNil(persisted.generations[retired.generationID])
        XCTAssertNotNil(persisted.epochs[retired.epochID])
        XCTAssertNotNil(persisted.routes[retired.route.routeID])
        XCTAssertEqual(
            persisted.routes.values.filter {
                $0.generationID == retired.generationID
            }.map(\.routeID),
            [retired.route.routeID]
        )
        XCTAssertTrue(persisted.shieldReferences.values.contains {
            $0.generationID == retired.generationID
        })
        let retainedSamples = persisted.sampleWork.values.filter {
            $0.routeID == retired.route.routeID
        }
        XCTAssertEqual(retainedSamples.count, 1)
        XCTAssertEqual(retainedSamples.first?.request.estimatedMinutes, 10)
    }

    func testInstallerStartsCurrentUsageDateBeforeFutureRoutesWithEqualRetryTime() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let todayWorkID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let futureWorkID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            let today = try XCTUnwrap(
                state.installWork.values.first {
                    state.routes[$0.routeID]?.usageDate == "2026-07-18"
                }
            )
            let future = try XCTUnwrap(
                state.installWork.values.first {
                    state.routes[$0.routeID]?.usageDate == "2026-07-19"
                }
            )
            state.installWork.removeValue(forKey: today.workID)
            state.installWork.removeValue(forKey: future.workID)
            for key in state.installWork.keys {
                state.installWork[key]?.phase = .verified
            }
            state.installWork[todayWorkID] = ActivityInstallWork(
                workID: todayWorkID,
                ownerChildDeviceID: today.ownerChildDeviceID,
                routeID: today.routeID,
                authorization: .registered,
                phase: .pendingStart,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: self.start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: self.start
            )
            state.installWork[futureWorkID] = ActivityInstallWork(
                workID: futureWorkID,
                ownerChildDeviceID: future.ownerChildDeviceID,
                routeID: future.routeID,
                authorization: .registered,
                phase: .pendingStart,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: self.start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: self.start
            )
        }
        let expectedTodayName = try XCTUnwrap(
            try fixture.firstStore.read().routes.values.first {
                $0.usageDate == "2026-07-18"
            }?.activityName
        )
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        _ = try installer.reconcile(ownerChildDeviceID: owner)

        XCTAssertEqual(center.startCalls.first?.rawValue, expectedTodayName)
    }

    func testRetiredOrNonCandidateInstallWorkIsSupersededWithoutStartingApple() throws {
        for retired in [true, false] {
            let fixture = try makeFixture()
            let work = try XCTUnwrap(try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart })
            let route = try XCTUnwrap(try fixture.firstStore.read().routes[work.routeID])
            try fixture.firstStore.transaction(expectedOwner: owner) { state in
                if retired {
                    state.generations[route.generationID]?.retiredAt = self.start
                } else {
                    let generation = try XCTUnwrap(state.generations[route.generationID])
                    let replacementID = UUID()
                    state.generations[replacementID] = MeteringPolicyGeneration(
                        generationID: replacementID,
                        protocolVersion: generation.protocolVersion,
                        childDeviceID: generation.childDeviceID,
                        canonicalTimezone: generation.canonicalTimezone,
                        policyRevision: generation.policyRevision,
                        measurementSelectionDigest: generation.measurementSelectionDigest,
                        enforcementSetID: generation.enforcementSetID,
                        measurementSelectionBytes: generation.measurementSelectionBytes,
                        createdAt: generation.createdAt,
                        retiredAt: nil
                    )
                    state.activeGenerationID = replacementID
                    state.activeRouteID = nil
                }
            }
            let center = DatedCenter()
            let installer = DatedRouteInstaller(
                store: fixture.firstStore,
                center: center,
                processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
                clock: fixture.clock
            )

            XCTAssertTrue(try installer.reconcile(ownerChildDeviceID: owner).isEmpty)

            let persisted = try fixture.firstStore.read().installWork[work.workID]
            XCTAssertEqual(persisted?.retry.terminal, .superseded)
            XCTAssertEqual(persisted?.retry.lastErrorCode, "route_superseded")
            XCTAssertNil(persisted?.claim)
            XCTAssertTrue(center.startCalls.isEmpty)
        }
    }

    func testRetiredEpochInstallWorkIsSupersededWithoutStartingApple() throws {
        let fixture = try makeFixture()
        let work = try XCTUnwrap(try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart })
        let route = try XCTUnwrap(try fixture.firstStore.read().routes[work.routeID])
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.epochs[route.epochID]?.status = .retired
            state.epochs[route.epochID]?.retiredAt = self.start
        }
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertTrue(try installer.reconcile(ownerChildDeviceID: owner).isEmpty)

        let persisted = try fixture.firstStore.read().installWork[work.workID]
        XCTAssertEqual(persisted?.retry.terminal, .superseded)
        XCTAssertEqual(persisted?.retry.lastErrorCode, "route_superseded")
        XCTAssertNil(persisted?.claim)
        XCTAssertTrue(center.startCalls.isEmpty)
    }

    func testPreparingHandoffCandidateInstallsWhilePriorRouteRemainsActive() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let initial = try fixture.firstStore.read()
        let priorRoute = try XCTUnwrap(initial.routes.values.first { $0.usageDate == "2026-07-18" })
        let candidateWork = try XCTUnwrap(initial.installWork.values.first { $0.routeID != priorRoute.routeID })
        let candidateRoute = try XCTUnwrap(initial.routes[candidateWork.routeID])
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = priorRoute.generationID
            state.activeEpochID = priorRoute.epochID
            state.activeRouteID = priorRoute.routeID
            state.routes[priorRoute.routeID]?.lifecycle = .active
            let generation = try XCTUnwrap(state.generations[candidateRoute.generationID])
            let candidateGenerationID = UUID()
            state.generations[candidateGenerationID] = MeteringPolicyGeneration(
                generationID: candidateGenerationID,
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                measurementSelectionBytes: generation.measurementSelectionBytes,
                createdAt: generation.createdAt,
                retiredAt: nil
            )
            state.routes[candidateRoute.routeID] = MeteringCallbackRoute(
                routeID: candidateRoute.routeID,
                activityName: candidateRoute.activityName,
                namespace: candidateRoute.namespace,
                generationID: candidateGenerationID,
                generationKey: candidateRoute.generationKey,
                ownerChildDeviceID: candidateRoute.ownerChildDeviceID,
                usageDate: candidateRoute.usageDate,
                epochID: candidateRoute.epochID,
                plannedSchedule: candidateRoute.plannedSchedule,
                installedSchedule: candidateRoute.installedSchedule,
                plannedEvents: candidateRoute.plannedEvents,
                installedEvents: candidateRoute.installedEvents,
                lifecycle: candidateRoute.lifecycle,
                createdAt: candidateRoute.createdAt
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: self.owner,
                fromGenerationID: priorRoute.generationID,
                fromEpochID: priorRoute.epochID,
                fromRouteID: priorRoute.routeID,
                toGenerationID: candidateGenerationID,
                toEpochID: candidateRoute.epochID,
                toRouteID: candidateRoute.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: self.start
            )
            for (workID, work) in state.installWork where workID != candidateWork.workID {
                state.installWork[workID]?.phase = .verified
            }
        }
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: candidateWork.workID)])
        XCTAssertEqual(center.startCalls, [DeviceActivityName(candidateRoute.activityName)])
        XCTAssertTrue(center.stopCalls.isEmpty)
        XCTAssertEqual(try fixture.firstStore.read().activeRouteID, priorRoute.routeID)
    }

    func testPreparingHandoffInstallsCandidateGenerationFutureHorizonWithoutSupersedingIt() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let initial = try fixture.firstStore.read()
        let priorRoute = try XCTUnwrap(initial.routes.values.first { $0.usageDate == "2026-07-18" })
        let candidateRoutes = initial.routes.values
            .filter { $0.routeID != priorRoute.routeID }
            .sorted { $0.usageDate < $1.usageDate }
        let handoffRoute = try XCTUnwrap(candidateRoutes.first)
        let candidateGenerationID = UUID()

        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = priorRoute.generationID
            state.activeEpochID = priorRoute.epochID
            state.activeRouteID = priorRoute.routeID
            state.routes[priorRoute.routeID]?.lifecycle = .active

            let generation = try XCTUnwrap(state.generations[priorRoute.generationID])
            state.generations[candidateGenerationID] = MeteringPolicyGeneration(
                generationID: candidateGenerationID,
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                measurementSelectionBytes: generation.measurementSelectionBytes,
                createdAt: generation.createdAt,
                retiredAt: nil
            )

            for route in candidateRoutes {
                state.routes[route.routeID] = MeteringCallbackRoute(
                    routeID: route.routeID,
                    activityName: route.activityName,
                    namespace: route.namespace,
                    generationID: candidateGenerationID,
                    generationKey: route.generationKey,
                    ownerChildDeviceID: route.ownerChildDeviceID,
                    usageDate: route.usageDate,
                    epochID: route.epochID,
                    plannedSchedule: route.plannedSchedule,
                    installedSchedule: route.installedSchedule,
                    plannedEvents: route.plannedEvents,
                    installedEvents: route.installedEvents,
                    lifecycle: route.lifecycle,
                    createdAt: route.createdAt
                )
                let workID = try XCTUnwrap(
                    state.installWork.first(where: { $0.value.routeID == route.routeID })?.key
                )
                state.installWork[workID]?.authorization = .futurePlanned
            }

            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: self.owner,
                fromGenerationID: priorRoute.generationID,
                fromEpochID: priorRoute.epochID,
                fromRouteID: priorRoute.routeID,
                toGenerationID: candidateGenerationID,
                toEpochID: handoffRoute.epochID,
                toRouteID: handoffRoute.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: self.start
            )

            let priorWorkID = try XCTUnwrap(
                state.installWork.first(where: { $0.value.routeID == priorRoute.routeID })?.key
            )
            state.installWork[priorWorkID]?.phase = .active
        }

        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertEqual(
            try installer.reconcile(ownerChildDeviceID: owner).filter {
                if case .verified = $0 { return true }
                return false
            }.count,
            candidateRoutes.count
        )
        XCTAssertEqual(Set(center.startCalls.map(\.rawValue)), Set(candidateRoutes.map(\.activityName)))
        let persisted = try fixture.firstStore.read()
        for route in candidateRoutes {
            let work = try XCTUnwrap(persisted.installWork.values.first { $0.routeID == route.routeID })
            XCTAssertEqual(work.phase, .verified)
            XCTAssertEqual(work.retry.terminal, .pending)
            XCTAssertNil(work.retry.lastErrorCode)
        }
        XCTAssertEqual(persisted.activeRouteID, priorRoute.routeID)
    }

    func testOrphanedPreparingHandoffCandidateIsSupersededWithoutStartingApple() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let initial = try fixture.firstStore.read()
        let priorRoute = try XCTUnwrap(initial.routes.values.first { $0.usageDate == "2026-07-18" })
        let candidateWork = try XCTUnwrap(initial.installWork.values.first { $0.routeID != priorRoute.routeID })
        let candidateRoute = try XCTUnwrap(initial.routes[candidateWork.routeID])
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = priorRoute.generationID
            state.activeEpochID = priorRoute.epochID
            state.activeRouteID = priorRoute.routeID
            state.routes[priorRoute.routeID]?.lifecycle = .active
            let generation = try XCTUnwrap(state.generations[candidateRoute.generationID])
            let candidateGenerationID = UUID()
            state.generations[candidateGenerationID] = MeteringPolicyGeneration(
                generationID: candidateGenerationID,
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                measurementSelectionBytes: generation.measurementSelectionBytes,
                createdAt: generation.createdAt,
                retiredAt: nil
            )
            state.routes[candidateRoute.routeID] = MeteringCallbackRoute(
                routeID: candidateRoute.routeID,
                activityName: candidateRoute.activityName,
                namespace: candidateRoute.namespace,
                generationID: candidateGenerationID,
                generationKey: candidateRoute.generationKey,
                ownerChildDeviceID: candidateRoute.ownerChildDeviceID,
                usageDate: candidateRoute.usageDate,
                epochID: candidateRoute.epochID,
                plannedSchedule: candidateRoute.plannedSchedule,
                installedSchedule: candidateRoute.installedSchedule,
                plannedEvents: candidateRoute.plannedEvents,
                installedEvents: candidateRoute.installedEvents,
                lifecycle: candidateRoute.lifecycle,
                createdAt: candidateRoute.createdAt
            )
            state.v2RouteHandoff = V2RouteHandoff(
                handoffID: UUID(),
                ownerChildDeviceID: self.owner,
                fromGenerationID: priorRoute.generationID,
                fromEpochID: priorRoute.epochID,
                fromRouteID: priorRoute.routeID,
                toGenerationID: candidateGenerationID,
                toEpochID: candidateRoute.epochID,
                toRouteID: candidateRoute.routeID,
                phase: .preparing,
                priorRouteInputClosedAt: nil,
                registrationAcknowledgedAt: nil,
                activationAcknowledgedAt: nil,
                priorStopAcknowledgedAt: nil,
                createdAt: self.start
            )
            state.activeRouteID = nil
            for (workID, work) in state.installWork where workID != candidateWork.workID {
                state.installWork[workID]?.phase = .verified
            }
        }
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertTrue(try installer.reconcile(ownerChildDeviceID: owner).isEmpty)

        let persisted = try fixture.firstStore.read().installWork[candidateWork.workID]
        XCTAssertEqual(persisted?.retry.terminal, .superseded)
        XCTAssertEqual(persisted?.retry.lastErrorCode, "route_superseded")
        XCTAssertNil(persisted?.claim)
        XCTAssertTrue(center.startCalls.isEmpty)
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

    func testWarningTimeMismatchReplacesCandidateWithoutStoppingPriorMonitor() throws {
        let fixture = try makeFixture()
        let state = try fixture.firstStore.read()
        let work = try XCTUnwrap(state.installWork.values.first { $0.phase == .pendingStart })
        let route = try XCTUnwrap(state.routes[work.routeID])
        let priorRoute = try XCTUnwrap(state.routes.values.first { $0.routeID != route.routeID })
        let priorWork = try XCTUnwrap(state.installWork.values.first { $0.routeID == priorRoute.routeID })
        let center = DatedCenter()
        center.install(route: priorRoute)
        center.install(route: route, warningTimeOverride: DateComponents(minute: 1))
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.installWork[priorWork.workID]?.phase = .verified
            state.installWork[work.workID]?.phase = .starting
            state.installWork[work.workID]?.claim = ActivityInstallClaim(
                token: UUID(), process: .app, instanceID: UUID(), claimedAt: self.start,
                expiresAt: self.start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
            )
        }
        fixture.clock.date = start.addingTimeInterval(DatedRouteInstaller.claimLeaseSeconds)
        let installer = DatedRouteInstaller(
            store: fixture.secondStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .deviceActivityMonitor, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.verified(workID: work.workID)])
        XCTAssertEqual(center.startCalls, [DeviceActivityName(route.activityName)])
        XCTAssertTrue(center.stopCalls.isEmpty)
        XCTAssertTrue(center.activities.contains(DeviceActivityName(priorRoute.activityName)))
    }

    func testExcessiveActivitiesCoverageUsesEligibleCanonicalDatesAndStopsAfterFirstFailure() throws {
        let fixture = try makeFixture(leaveAllPending: true)
        let state = try fixture.firstStore.read()
        XCTAssertNil(state.coverage)
        let first = try work(forUsageDate: "2026-07-18", in: state)
        let nonContiguousVerified = try work(forUsageDate: "2026-07-20", in: state)
        let tombstoned = try work(forUsageDate: "2026-07-19", in: state)
        let verifiedRoute = state.routes[first.routeID]!
        let laterVerifiedRoute = state.routes[nonContiguousVerified.routeID]!
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.coverage = MonitorCoverageState(
                ownerChildDeviceID: owner,
                requiredFromUsageDate: "2026-07-17",
                requiredThroughUsageDate: "2026-07-26",
                readyThroughUsageDate: "2026-07-26",
                status: .installLimited,
                refreshedAt: start.addingTimeInterval(-60),
                errorCode: "older_limit"
            )
            state.installWork[first.workID]?.phase = .verified
            state.installWork[nonContiguousVerified.workID]?.phase = .verified
            state.installWork[tombstoned.workID]?.phase = .verified
            state.routes[tombstoned.routeID]?.lifecycle = .tombstoned
            let tombstoneRoute = state.routes[tombstoned.routeID]!
            state.tombstones[tombstoned.routeID] = MeteringRouteTombstone(
                routeID: tombstoneRoute.routeID,
                activityName: tombstoneRoute.activityName,
                eventNames: tombstoneRoute.plannedEvents.map(\.eventName),
                ownerChildDeviceID: owner,
                usageDate: tombstoneRoute.usageDate,
                epochID: tombstoneRoute.epochID,
                generationID: tombstoneRoute.generationID,
                canonicalDayEnd: start.addingTimeInterval(86_400),
                stopAcknowledgedAt: nil,
                referencedWorkIDs: [],
                retainedUntil: nil
            )
            let duplicateRouteID = UUID()
            let duplicateGenerationID = UUID()
            let duplicateGeneration = state.generations[tombstoneRoute.generationID]!
            state.generations[duplicateGenerationID] = MeteringPolicyGeneration(
                generationID: duplicateGenerationID,
                protocolVersion: duplicateGeneration.protocolVersion,
                childDeviceID: duplicateGeneration.childDeviceID,
                canonicalTimezone: duplicateGeneration.canonicalTimezone,
                policyRevision: duplicateGeneration.policyRevision,
                measurementSelectionDigest: duplicateGeneration.measurementSelectionDigest,
                enforcementSetID: duplicateGeneration.enforcementSetID,
                measurementSelectionBytes: duplicateGeneration.measurementSelectionBytes,
                createdAt: start.addingTimeInterval(-1),
                retiredAt: start
            )
            state.routes[duplicateRouteID] = MeteringCallbackRoute(
                routeID: duplicateRouteID,
                activityName: "evlin.earned.duplicate.\(duplicateRouteID.uuidString.lowercased())",
                namespace: tombstoneRoute.namespace,
                generationID: duplicateGenerationID,
                generationKey: tombstoneRoute.generationKey,
                ownerChildDeviceID: owner,
                usageDate: tombstoneRoute.usageDate,
                epochID: tombstoneRoute.epochID,
                plannedSchedule: tombstoneRoute.plannedSchedule,
                installedSchedule: tombstoneRoute.plannedSchedule,
                plannedEvents: tombstoneRoute.plannedEvents,
                installedEvents: tombstoneRoute.plannedEvents,
                lifecycle: .retired,
                createdAt: start
            )
            let duplicateWorkID = UUID()
            state.installWork[duplicateWorkID] = ActivityInstallWork(
                workID: duplicateWorkID,
                ownerChildDeviceID: owner,
                routeID: duplicateRouteID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .succeeded),
                createdAt: start
            )
            let oldEpochID = UUID()
            let firstEpoch = state.epochs[verifiedRoute.epochID]!
            state.epochs[oldEpochID] = DeviceDailyEpoch(
                epochID: oldEpochID,
                protocolVersion: firstEpoch.protocolVersion,
                childDeviceID: firstEpoch.childDeviceID,
                usageDate: "2026-07-01",
                canonicalTimezone: firstEpoch.canonicalTimezone,
                policyRevision: firstEpoch.policyRevision,
                measurementSelectionDigest: firstEpoch.measurementSelectionDigest,
                enforcementSetID: firstEpoch.enforcementSetID,
                startedAt: firstEpoch.startedAt,
                registeredAt: nil,
                baseAcceptedMinutes: 0,
                baseSource: firstEpoch.baseSource,
                lastRawThresholdMinutes: 0,
                excludedWhilePausedMinutes: 0,
                status: .active,
                resumeBoundaryPending: false,
                retiredAt: nil,
                retireReason: nil,
                exhaustedAt: nil,
                baseCorrectionState: .available
            )
            let historicalRouteID = UUID()
            state.routes[historicalRouteID] = MeteringCallbackRoute(
                routeID: historicalRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: historicalRouteID),
                namespace: verifiedRoute.namespace,
                generationID: verifiedRoute.generationID,
                generationKey: verifiedRoute.generationKey,
                ownerChildDeviceID: owner,
                usageDate: "2026-07-01",
                epochID: oldEpochID,
                plannedSchedule: DatedSchedulePlan(usageDate: "2026-07-01", timezoneIdentifier: verifiedRoute.plannedSchedule.timezoneIdentifier, calendarIdentifier: "gregorian"),
                installedSchedule: nil,
                plannedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: historicalRouteID, thresholdMinutes: 10), thresholdMinutes: 10)],
                installedEvents: nil,
                lifecycle: .planned,
                createdAt: start.addingTimeInterval(-60)
            )
            let historicalWorkID = UUID()
            state.installWork[historicalWorkID] = ActivityInstallWork(
                workID: historicalWorkID,
                ownerChildDeviceID: owner,
                routeID: historicalRouteID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .succeeded),
                createdAt: start.addingTimeInterval(-60)
            )
            let duplicateCurrentRouteID = UUID()
            state.routes[duplicateCurrentRouteID] = MeteringCallbackRoute(
                routeID: duplicateCurrentRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: duplicateCurrentRouteID),
                namespace: verifiedRoute.namespace,
                generationID: verifiedRoute.generationID,
                generationKey: verifiedRoute.generationKey,
                ownerChildDeviceID: owner,
                usageDate: verifiedRoute.usageDate,
                epochID: verifiedRoute.epochID,
                plannedSchedule: verifiedRoute.plannedSchedule,
                installedSchedule: verifiedRoute.plannedSchedule,
                plannedEvents: verifiedRoute.plannedEvents,
                installedEvents: verifiedRoute.plannedEvents,
                lifecycle: .planned,
                createdAt: start
            )
            let duplicateCurrentWorkID = UUID()
            state.installWork[duplicateCurrentWorkID] = ActivityInstallWork(
                workID: duplicateCurrentWorkID,
                ownerChildDeviceID: owner,
                routeID: duplicateCurrentRouteID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: start, lastErrorCode: nil, terminal: .succeeded),
                createdAt: start
            )
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
        XCTAssertEqual(persisted.coverage?.requiredFromUsageDate, "2026-07-18")
        XCTAssertEqual(persisted.coverage?.requiredThroughUsageDate, "2026-07-25")
        XCTAssertEqual(persisted.coverage?.readyThroughUsageDate, "2026-07-18")
        XCTAssertTrue(center.activities.contains(DeviceActivityName(verifiedRoute.activityName)))
        XCTAssertEqual(persisted.installWork.values.filter { $0.retry.attemptCount > 0 }.count, 1)
        XCTAssertTrue(persisted.installWork.values.filter { $0.phase == .pendingStart }.allSatisfy { $0.retry.attemptCount <= 1 })
    }

    func testInstallLimitedCoverageIgnoresStalePriorGenerationDates() throws {
        let fixture = try makeFixture(leaveAllPending: true, registeredAll: true)
        let initial = try fixture.firstStore.read()
        let failedWork = try work(forUsageDate: "2026-07-18", in: initial)
        let failedRoute = try XCTUnwrap(initial.routes[failedWork.routeID])
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            let generation = try XCTUnwrap(state.generations[failedRoute.generationID])
            let priorGenerationID = UUID()
            state.generations[priorGenerationID] = MeteringPolicyGeneration(
                generationID: priorGenerationID,
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID,
                measurementSelectionBytes: generation.measurementSelectionBytes,
                createdAt: self.start.addingTimeInterval(-60),
                retiredAt: self.start
            )
            let priorEpochID = UUID()
            let epoch = try XCTUnwrap(state.epochs[failedRoute.epochID])
            state.epochs[priorEpochID] = DeviceDailyEpoch(
                epochID: priorEpochID,
                protocolVersion: epoch.protocolVersion,
                childDeviceID: epoch.childDeviceID,
                usageDate: "2026-07-17",
                canonicalTimezone: epoch.canonicalTimezone,
                policyRevision: epoch.policyRevision,
                measurementSelectionDigest: epoch.measurementSelectionDigest,
                enforcementSetID: epoch.enforcementSetID,
                startedAt: epoch.startedAt,
                registeredAt: epoch.registeredAt,
                baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                baseSource: epoch.baseSource,
                lastRawThresholdMinutes: epoch.lastRawThresholdMinutes,
                excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
                status: .retired,
                resumeBoundaryPending: epoch.resumeBoundaryPending,
                retiredAt: self.start,
                retireReason: .policyChange,
                exhaustedAt: epoch.exhaustedAt,
                baseCorrectionState: epoch.baseCorrectionState
            )
            let priorRouteID = UUID()
            state.routes[priorRouteID] = MeteringCallbackRoute(
                routeID: priorRouteID,
                activityName: MeteringRouteNamespace.activityName(routeID: priorRouteID),
                namespace: failedRoute.namespace,
                generationID: priorGenerationID,
                generationKey: failedRoute.generationKey,
                ownerChildDeviceID: self.owner,
                usageDate: "2026-07-17",
                epochID: priorEpochID,
                plannedSchedule: DatedSchedulePlan(usageDate: "2026-07-17", timezoneIdentifier: failedRoute.plannedSchedule.timezoneIdentifier, calendarIdentifier: "gregorian"),
                installedSchedule: nil,
                plannedEvents: [MeteringEventPlan(eventName: MeteringRouteNamespace.eventName(routeID: priorRouteID, thresholdMinutes: 5), thresholdMinutes: 5)],
                installedEvents: nil,
                lifecycle: .active,
                createdAt: self.start.addingTimeInterval(-60)
            )
            let priorWorkID = UUID()
            state.installWork[priorWorkID] = ActivityInstallWork(
                workID: priorWorkID,
                ownerChildDeviceID: self.owner,
                routeID: priorRouteID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(attemptCount: 0, nextAttemptAt: self.start, lastErrorCode: nil, terminal: .succeeded),
                createdAt: self.start.addingTimeInterval(-60)
            )
        }
        let claim = try XCTUnwrap(try fixture.firstStore.claimInstallWork(
            workID: failedWork.workID,
            owner: owner,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            now: start
        ))

        XCTAssertTrue(try fixture.firstStore.deferInstallWork(
            workID: failedWork.workID,
            token: claim.claim.token,
            owner: owner,
            now: start,
            code: "excessiveActivities",
            installLimited: true
        ))

        let coverage = try XCTUnwrap(try fixture.firstStore.read().coverage)
        XCTAssertEqual(coverage.requiredFromUsageDate, "2026-07-18")
        XCTAssertEqual(coverage.requiredThroughUsageDate, "2026-07-25")
    }

    func testMalformedPersistedEventPlansDeferAndClearClaim() throws {
        for plannedEvents in [
            [MeteringEventPlan(eventName: "duplicate", thresholdMinutes: 5), MeteringEventPlan(eventName: "duplicate", thresholdMinutes: 10)],
            [MeteringEventPlan(eventName: "invalid", thresholdMinutes: 0)],
            [MeteringEventPlan(eventName: "invalid", thresholdMinutes: 5)]
        ] {
            let fixture = try makeFixture()
            let work = try XCTUnwrap(try fixture.firstStore.read().installWork.values.first { $0.phase == .pendingStart })
            let route = try XCTUnwrap(try fixture.firstStore.read().routes[work.routeID])
            try fixture.firstStore.transaction(expectedOwner: owner) { state in
                state.routes[route.routeID] = MeteringCallbackRoute(
                    routeID: route.routeID,
                    activityName: route.activityName,
                    namespace: route.namespace,
                    generationID: route.generationID,
                    generationKey: route.generationKey,
                    ownerChildDeviceID: route.ownerChildDeviceID,
                    usageDate: route.usageDate,
                    epochID: route.epochID,
                    plannedSchedule: route.plannedSchedule,
                    installedSchedule: route.installedSchedule,
                    plannedEvents: plannedEvents,
                    installedEvents: route.installedEvents,
                    lifecycle: route.lifecycle,
                    createdAt: route.createdAt
                )
            }
            let center = DatedCenter()
            let installer = DatedRouteInstaller(
                store: fixture.firstStore,
                center: center,
                processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
                clock: fixture.clock
            )

            XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.deferred(workID: work.workID, code: "configurationFailed")])

            let persisted = try fixture.firstStore.read().installWork[work.workID]
            XCTAssertEqual(persisted?.phase, .pendingStart)
            XCTAssertNil(persisted?.claim)
            XCTAssertEqual(persisted?.retry.attemptCount, 1)
            XCTAssertTrue(center.startCalls.isEmpty)
        }
    }

    func testConfigurationFailureDefersInstallAndClearsOwnedClaim() throws {
        let fixture = try makeFixture()
        let initial = try fixture.firstStore.read()
        let work = try XCTUnwrap(initial.installWork.values.first { $0.phase == .pendingStart })
        let route = try XCTUnwrap(initial.routes[work.routeID])
        let generation = try XCTUnwrap(initial.generations[route.generationID])
        let invalidSelection = Data("not-a-selection".utf8)
        let invalidDigest = MeteringEpochContract.selectionDigest(persistedBytes: invalidSelection)
        let invalidKey = MeteringGenerationKey(
            protocolVersion: generation.protocolVersion,
            childDeviceID: generation.childDeviceID,
            canonicalTimezone: generation.canonicalTimezone,
            policyRevision: generation.policyRevision,
            measurementSelectionDigest: invalidDigest,
            enforcementSetID: generation.enforcementSetID
        )
        try fixture.firstStore.transaction(expectedOwner: owner) { state in
            state.generations[route.generationID] = MeteringPolicyGeneration(
                generationID: generation.generationID,
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: invalidDigest,
                enforcementSetID: generation.enforcementSetID,
                measurementSelectionBytes: invalidSelection,
                createdAt: generation.createdAt,
                retiredAt: generation.retiredAt
            )
            for (epochID, epoch) in Array(state.epochs) {
                state.epochs[epochID] = DeviceDailyEpoch(
                    epochID: epoch.epochID,
                    protocolVersion: epoch.protocolVersion,
                    childDeviceID: epoch.childDeviceID,
                    usageDate: epoch.usageDate,
                    canonicalTimezone: epoch.canonicalTimezone,
                    policyRevision: epoch.policyRevision,
                    measurementSelectionDigest: invalidDigest,
                    enforcementSetID: epoch.enforcementSetID,
                    startedAt: epoch.startedAt,
                    registeredAt: epoch.registeredAt,
                    baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                    baseSource: epoch.baseSource,
                    lastRawThresholdMinutes: epoch.lastRawThresholdMinutes,
                    excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
                    status: epoch.status,
                    resumeBoundaryPending: epoch.resumeBoundaryPending,
                    retiredAt: epoch.retiredAt,
                    retireReason: epoch.retireReason,
                    exhaustedAt: epoch.exhaustedAt,
                    baseCorrectionState: epoch.baseCorrectionState,
                    authoritativeBaseConflict: epoch.authoritativeBaseConflict
                )
            }
            for (routeID, route) in Array(state.routes) {
                state.routes[routeID] = MeteringCallbackRoute(
                    routeID: route.routeID,
                    activityName: route.activityName,
                    namespace: route.namespace,
                    generationID: route.generationID,
                    generationKey: invalidKey,
                    ownerChildDeviceID: route.ownerChildDeviceID,
                    usageDate: route.usageDate,
                    epochID: route.epochID,
                    plannedSchedule: route.plannedSchedule,
                    installedSchedule: route.installedSchedule,
                    plannedEvents: route.plannedEvents,
                    installedEvents: route.installedEvents,
                    lifecycle: route.lifecycle,
                    createdAt: route.createdAt
                )
            }
        }
        let center = DatedCenter()
        let installer = DatedRouteInstaller(
            store: fixture.firstStore,
            center: center,
            processIdentity: MeteringProcessIdentity(role: .app, instanceID: UUID()),
            clock: fixture.clock
        )

        XCTAssertEqual(try installer.reconcile(ownerChildDeviceID: owner), [.deferred(workID: work.workID, code: "configurationFailed")])

        let persisted = try fixture.firstStore.read().installWork[work.workID]
        XCTAssertEqual(persisted?.phase, .pendingStart)
        XCTAssertNil(persisted?.claim)
        XCTAssertEqual(persisted?.retry.attemptCount, 1)
        XCTAssertEqual(persisted?.retry.lastErrorCode, "configurationFailed")
        XCTAssertTrue(center.startCalls.isEmpty)
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

    private func addRetiredGeneration(
        to store: DeviceEpochStore,
        addShieldReference: Bool = false
    ) throws -> (generationID: UUID, epochID: UUID, route: MeteringCallbackRoute) {
        let initial = try store.read()
        let templateRoute = try XCTUnwrap(initial.routes.values.first)
        let templateGeneration = try XCTUnwrap(initial.generations[templateRoute.generationID])
        let templateEpoch = try XCTUnwrap(initial.epochs[templateRoute.epochID])
        let generationID = UUID()
        let epochID = UUID()
        let routeID = UUID()
        let generation = MeteringPolicyGeneration(
            generationID: generationID,
            protocolVersion: templateGeneration.protocolVersion,
            childDeviceID: templateGeneration.childDeviceID,
            canonicalTimezone: templateGeneration.canonicalTimezone,
            policyRevision: templateGeneration.policyRevision,
            measurementSelectionDigest: templateGeneration.measurementSelectionDigest,
            enforcementSetID: templateGeneration.enforcementSetID,
            measurementSelectionBytes: templateGeneration.measurementSelectionBytes,
            createdAt: start.addingTimeInterval(-120),
            retiredAt: start.addingTimeInterval(-60),
            configuredPoolMinutes: templateGeneration.configuredPoolMinutes,
            configuredDeviceCapMinutes: templateGeneration.configuredDeviceCapMinutes
        )
        let epoch = DeviceDailyEpoch(
            epochID: epochID,
            protocolVersion: templateEpoch.protocolVersion,
            childDeviceID: templateEpoch.childDeviceID,
            usageDate: templateEpoch.usageDate,
            canonicalTimezone: templateEpoch.canonicalTimezone,
            policyRevision: templateEpoch.policyRevision,
            measurementSelectionDigest: templateEpoch.measurementSelectionDigest,
            enforcementSetID: templateEpoch.enforcementSetID,
            startedAt: start.addingTimeInterval(-120),
            registeredAt: start.addingTimeInterval(-120),
            baseAcceptedMinutes: 0,
            baseSource: templateEpoch.baseSource,
            lastRawThresholdMinutes: 0,
            excludedWhilePausedMinutes: 0,
            status: .retired,
            resumeBoundaryPending: false,
            retiredAt: start.addingTimeInterval(-60),
            retireReason: .policyChange,
            exhaustedAt: nil,
            baseCorrectionState: .available
        )
        let route = MeteringCallbackRoute(
            routeID: routeID,
            activityName: MeteringRouteNamespace.activityName(routeID: routeID),
            namespace: MeteringRouteNamespace.prefix,
            generationID: generationID,
            generationKey: MeteringGenerationKey(
                protocolVersion: generation.protocolVersion,
                childDeviceID: generation.childDeviceID,
                canonicalTimezone: generation.canonicalTimezone,
                policyRevision: generation.policyRevision,
                measurementSelectionDigest: generation.measurementSelectionDigest,
                enforcementSetID: generation.enforcementSetID
            ),
            ownerChildDeviceID: owner,
            usageDate: epoch.usageDate,
            epochID: epochID,
            plannedSchedule: templateRoute.plannedSchedule,
            installedSchedule: templateRoute.plannedSchedule,
            plannedEvents: templateRoute.plannedEvents,
            installedEvents: templateRoute.plannedEvents,
            lifecycle: .planned,
            createdAt: start.addingTimeInterval(-120)
        )
        let installID = UUID()
        try store.transaction(expectedOwner: owner) { state in
            state.generations[generationID] = generation
            state.epochs[epochID] = epoch
            state.routes[routeID] = route
            state.installWork[installID] = ActivityInstallWork(
                workID: installID,
                ownerChildDeviceID: owner,
                routeID: routeID,
                authorization: .registered,
                phase: .verified,
                claim: nil,
                retry: MeteringRetryState(
                    attemptCount: 0,
                    nextAttemptAt: start,
                    lastErrorCode: nil,
                    terminal: .pending
                ),
                createdAt: start.addingTimeInterval(-120)
            )
            if addShieldReference {
                let redundantRouteID = UUID()
                let redundantEpochID = UUID()
                let redundantEpoch = DeviceDailyEpoch(
                    epochID: redundantEpochID,
                    protocolVersion: epoch.protocolVersion,
                    childDeviceID: epoch.childDeviceID,
                    usageDate: epoch.usageDate,
                    canonicalTimezone: epoch.canonicalTimezone,
                    policyRevision: epoch.policyRevision,
                    measurementSelectionDigest: epoch.measurementSelectionDigest,
                    enforcementSetID: epoch.enforcementSetID,
                    startedAt: epoch.startedAt,
                    registeredAt: epoch.registeredAt,
                    baseAcceptedMinutes: epoch.baseAcceptedMinutes,
                    baseSource: epoch.baseSource,
                    lastRawThresholdMinutes: epoch.lastRawThresholdMinutes,
                    excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
                    status: epoch.status,
                    resumeBoundaryPending: epoch.resumeBoundaryPending,
                    retiredAt: epoch.retiredAt,
                    retireReason: epoch.retireReason,
                    exhaustedAt: epoch.exhaustedAt,
                    baseCorrectionState: epoch.baseCorrectionState
                )
                let redundantRoute = MeteringCallbackRoute(
                    routeID: redundantRouteID,
                    activityName: MeteringRouteNamespace.activityName(
                        routeID: redundantRouteID
                    ),
                    namespace: route.namespace,
                    generationID: generationID,
                    generationKey: route.generationKey,
                    ownerChildDeviceID: owner,
                    usageDate: route.usageDate,
                    epochID: redundantEpochID,
                    plannedSchedule: route.plannedSchedule,
                    installedSchedule: route.installedSchedule,
                    plannedEvents: route.plannedEvents,
                    installedEvents: route.installedEvents,
                    lifecycle: .planned,
                    createdAt: route.createdAt
                )
                let redundantInstallID = UUID()
                state.epochs[redundantEpochID] = redundantEpoch
                state.routes[redundantRouteID] = redundantRoute
                state.installWork[redundantInstallID] = ActivityInstallWork(
                    workID: redundantInstallID,
                    ownerChildDeviceID: owner,
                    routeID: redundantRouteID,
                    authorization: .registered,
                    phase: .verified,
                    claim: nil,
                    retry: MeteringRetryState(
                        attemptCount: 0,
                        nextAttemptAt: start,
                        lastErrorCode: nil,
                        terminal: .pending
                    ),
                    createdAt: start.addingTimeInterval(-120)
                )
                state.shieldReferences[routeID] = EarnedShieldReference(
                    operationID: routeID,
                    ownerChildDeviceID: owner,
                    generationID: generationID,
                    epochID: epochID,
                    routeID: routeID,
                    recordKey: "test-retained-shield",
                    expectedRecordBytes: Data("record".utf8),
                    retry: MeteringRetryState(
                        attemptCount: 0,
                        nextAttemptAt: start,
                        lastErrorCode: nil,
                        terminal: .succeeded
                    ),
                    createdAt: start.addingTimeInterval(-120)
                )
                for threshold in [5, 10] {
                    let sampleID = UUID()
                    state.sampleWork[sampleID] = EpochSampleWork(
                        workID: sampleID,
                        ownerChildDeviceID: owner,
                        epochID: epochID,
                        routeID: routeID,
                        request: EpochSampleRequestDTO(
                            deviceID: owner,
                            usageDate: epoch.usageDate,
                            timezone: epoch.canonicalTimezone,
                            activityName: MeteringSampleWireAliases.activityName(routeID: routeID),
                            eventName: MeteringSampleWireAliases.eventName(
                                thresholdMinutes: threshold
                            ),
                            thresholdMinutes: threshold,
                            estimatedMinutes: threshold,
                            observedAt: start.addingTimeInterval(TimeInterval(threshold * 60)),
                            clientSampleID: MeteringSampleWireAliases.clientSampleID(
                                lane: .v2,
                                routeID: routeID,
                                thresholdMinutes: threshold
                            ),
                            protocolVersion: 2,
                            epochID: epochID,
                            generationArmedAt: nil,
                            generationOffsetMinutes: nil
                        ),
                        authorization: .v2Deliverable,
                        claim: nil,
                        retry: MeteringRetryState(
                            attemptCount: 1,
                            nextAttemptAt: start,
                            lastErrorCode: nil,
                            terminal: .succeeded
                        ),
                        createdAt: start.addingTimeInterval(TimeInterval(-100 + threshold))
                    )
                }
            }
        }
        return (generationID, epochID, route)
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

private nonisolated final class DatedCenter: MeteringDeviceActivityCenter, @unchecked Sendable {
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
    var onStart: (() -> Void)?

    var activities: [DeviceActivityName] { inspectionCalls += 1; return Array(records.keys) }
    func schedule(for activity: DeviceActivityName) -> DeviceActivitySchedule? { inspectionCalls += 1; return records[activity]?.0 }
    func events(for activity: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        inspectionCalls += 1
        return records[activity]?.1.mapValues { $0.event() } ?? [:]
    }
    func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule, events: [DeviceActivityEvent.Name: DeviceActivityEvent]) throws {
        startCalls.append(activity)
        onStart?()
        if let startError { throw startError }
        records[activity] = (schedule, events.mapValues(EventRecord.init))
    }
    func stopMonitoring(_ activities: [DeviceActivityName]) { stopCalls.append(activities); activities.forEach { records.removeValue(forKey: $0) } }

    func install(route: MeteringCallbackRoute, thresholdOverride: Int? = nil, warningTimeOverride: DateComponents? = nil) {
        let expectedSchedule = try! MeteringDatedSchedule.datedSchedule(
            usageDate: route.usageDate,
            timeZone: TimeZone(identifier: route.plannedSchedule.timezoneIdentifier)!,
            intervalStartAt: route.plannedSchedule.intervalStartAt
        )
        let schedule = DeviceActivitySchedule(
            intervalStart: expectedSchedule.intervalStart,
            intervalEnd: expectedSchedule.intervalEnd,
            repeats: expectedSchedule.repeats,
            warningTime: warningTimeOverride
        )
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

    func installOpaqueActivity(named name: String) {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        records[DeviceActivityName(name)] = (schedule, [:])
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
