import XCTest
import DeviceActivity
import FamilyControls
@testable import Evlin_iOS

/// B4 — Pure threshold-planning logic tests.
///
/// These tests exercise `EarnedBudgetScheduler.thresholds(poolMinutes:capMinutes:)`
/// only. No DeviceActivity framework, no live system calls, no entitlements required.
final class EarnedBudgetSchedulerTests: XCTestCase {

    func testDatedScheduleUsesCanonicalMidnightsAcrossNewYorkDSTTransitions() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        for usageDate in ["2026-03-08", "2026-11-01"] {
            let schedule = try EarnedBudgetScheduler.datedSchedule(
                usageDate: usageDate,
                timeZone: timeZone
            )

            XCTAssertFalse(schedule.repeats)
            XCTAssertEqual(schedule.intervalStart.year, Int(usageDate.prefix(4)))
            XCTAssertEqual(schedule.intervalStart.month, Int(usageDate.dropFirst(5).prefix(2)))
            XCTAssertEqual(schedule.intervalStart.day, Int(usageDate.suffix(2)))
            XCTAssertEqual(schedule.intervalStart.hour, 0)
            XCTAssertEqual(schedule.intervalStart.minute, 0)
            XCTAssertEqual(schedule.intervalStart.timeZone, timeZone)

            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = timeZone
            let start = try XCTUnwrap(calendar.date(from: schedule.intervalStart))
            let end = try XCTUnwrap(calendar.date(from: schedule.intervalEnd))
            XCTAssertEqual(calendar.dateComponents([.day], from: start, to: end).day, 1)
        }
    }

    func testDatedScheduleUsesPersistedCurrentDayInstallStartAndIncludesObservedIntervalUsage() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let installStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 23,
            hour: 14,
            minute: 37,
            second: 12
        )))

        let schedule = try MeteringDatedSchedule.datedSchedule(
            usageDate: "2026-07-23",
            timeZone: timeZone,
            intervalStartAt: installStart
        )
        let event = MeteringDatedSchedule.makeEvent(
            selection: FamilyActivitySelection(),
            thresholdMinutes: 5
        )

        XCTAssertEqual(calendar.date(from: schedule.intervalStart), installStart)
        XCTAssertEqual(schedule.intervalEnd.hour, 0)
        XCTAssertEqual(schedule.intervalEnd.minute, 0)
        XCTAssertEqual(schedule.intervalEnd.day, 24)
        XCTAssertFalse(schedule.repeats)
        XCTAssertTrue(event.includesPastActivity)
    }

    func testLegacyDatedSchedulePlanWithoutInstallStartStillDecodesAsMidnightPlan() throws {
        let data = Data("""
        {
          "usageDate": "2026-07-23",
          "timezoneIdentifier": "America/New_York",
          "calendarIdentifier": "gregorian"
        }
        """.utf8)

        let plan = try JSONDecoder().decode(DatedSchedulePlan.self, from: data)

        XCTAssertNil(plan.topologyVersion)
        XCTAssertNil(plan.intervalStartAt)
    }

    func testDatedScheduleUsesSuppliedTimezoneAndRejectsNonCanonicalDates() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let tokyoSchedule = try MeteringDatedSchedule.datedSchedule(
            usageDate: "2026-07-18",
            timeZone: tokyo
        )
        let newYorkSchedule = try MeteringDatedSchedule.datedSchedule(
            usageDate: "2026-07-17",
            timeZone: newYork
        )

        XCTAssertEqual(tokyoSchedule.intervalStart.timeZone, tokyo)
        XCTAssertEqual(tokyoSchedule.intervalStart.day, 18)
        XCTAssertEqual(newYorkSchedule.intervalStart.timeZone, newYork)
        XCTAssertEqual(newYorkSchedule.intervalStart.day, 17)
        for invalidDate in ["2026-2-03", "2026-02-3", "2026-02-30", "2026/02/03", "20260203"] {
            XCTAssertThrowsError(try MeteringDatedSchedule.datedSchedule(
                usageDate: invalidDate,
                timeZone: tokyo
            ))
        }
    }

    func testDatedScheduleRemainsGregorianWhenCallerSuppliesAnotherCalendar() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let schedule = try MeteringDatedSchedule.datedSchedule(
            usageDate: "2026-07-17",
            timeZone: timeZone,
            calendar: Calendar(identifier: .buddhist)
        )

        XCTAssertEqual(schedule.intervalStart.calendar?.identifier, .gregorian)
        XCTAssertEqual(schedule.intervalStart.year, 2026)
        XCTAssertEqual(schedule.intervalStart.month, 7)
        XCTAssertEqual(schedule.intervalStart.day, 17)
    }

    func testHorizonPlannerProducesTodayAndSevenFutureCanonicalDates() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        XCTAssertEqual(
            try MeteringHorizonPlanner.requiredUsageDates(today: "2026-03-08", timeZone: timeZone),
            [
                "2026-03-08", "2026-03-09", "2026-03-10", "2026-03-11",
                "2026-03-12", "2026-03-13", "2026-03-14", "2026-03-15",
            ]
        )
    }

    func testHorizonReconciliationPersistsOneGenerationAndEightImmutableDatedRoutes() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-horizon-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let selectionBytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let request = MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: generationKey(owner: owner),
            persistedSelectionBytes: selectionBytes,
            poolMinutes: 120,
            deviceCapMinutes: 62,
            authoritativeBaseAcceptedMinutes: 12,
            now: Date(timeIntervalSince1970: 1_784_764_800)
        )

        let first = try store.reconcileMeteringHorizon(request)
        let firstState = try store.read()
        let second = try store.reconcileMeteringHorizon(request)
        let secondState = try store.read()

        XCTAssertEqual(first, second)
        XCTAssertEqual(firstState, secondState)
        XCTAssertEqual(firstState.generations.count, 1)
        XCTAssertEqual(firstState.routes.count, MeteringHorizonPlanner.dateCount)
        XCTAssertEqual(firstState.epochs.count, MeteringHorizonPlanner.dateCount)
        XCTAssertEqual(firstState.installWork.count, MeteringHorizonPlanner.dateCount)
        XCTAssertEqual(firstState.registrationWork.count, 1)
        XCTAssertEqual(firstState.generations[first.generationID]?.measurementSelectionBytes, selectionBytes)

        let routesByDate = Dictionary(uniqueKeysWithValues: firstState.routes.values.map { ($0.usageDate, $0) })
        XCTAssertEqual(routesByDate.keys.sorted(), try MeteringHorizonPlanner.requiredUsageDates(
            today: request.today,
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        ))
        XCTAssertEqual(routesByDate[request.today]?.lifecycle, .planned)
        XCTAssertEqual(routesByDate[request.today]?.plannedSchedule.usageDate, request.today)
        let todayRoute = try XCTUnwrap(routesByDate[request.today])
        XCTAssertEqual(todayRoute.plannedEvents.map(\.thresholdMinutes), [
            5, 10, 15, 20, 25, 30, 35, 40, 45, 50,
        ])
        XCTAssertEqual(todayRoute.plannedEvents.map(\.eventName), todayRoute.plannedEvents.map {
            MeteringRouteNamespace.eventName(
                routeID: todayRoute.routeID,
                thresholdMinutes: $0.thresholdMinutes
            )
        })
        let todayEpoch = try XCTUnwrap(firstState.epochs[todayRoute.epochID])
        XCTAssertEqual(todayEpoch.baseAcceptedMinutes, 12)
        XCTAssertEqual(todayEpoch.baseSource, .childState200)
        XCTAssertEqual(firstState.installWork.values.first(where: { $0.routeID == todayRoute.routeID })?.authorization, .registrationRequired)
        XCTAssertEqual(firstState.registrationWork.values.first?.routeID, todayRoute.routeID)

        for route in firstState.routes.values where route.usageDate != request.today {
            XCTAssertEqual(route.plannedEvents.map(\.thresholdMinutes), [
                5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 62,
            ])
            XCTAssertEqual(route.plannedEvents.map(\.eventName), route.plannedEvents.map {
                MeteringRouteNamespace.eventName(
                    routeID: route.routeID,
                    thresholdMinutes: $0.thresholdMinutes
                )
            })
            XCTAssertEqual(
                firstState.installWork.values.first(where: { $0.routeID == route.routeID })?.authorization,
                .futurePlanned
            )
            XCTAssertNil(firstState.registrationWork.values.first(where: { $0.routeID == route.routeID }))
        }
    }

    func testCurrentRouteUsesAuthoritativeBaseForRemainingLadderAndFutureRoutesUseFullLadder() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-horizon-ladder-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let request = MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: generationKey(owner: owner),
            persistedSelectionBytes: Data([0x00, 0x01, 0xFE, 0xFF]),
            poolMinutes: 60,
            deviceCapMinutes: 12,
            authoritativeBaseAcceptedMinutes: 5,
            now: Date(timeIntervalSince1970: 1_784_764_800)
        )

        let plan = try store.reconcileMeteringHorizon(request)
        let state = try store.read()
        let todayRoute = try XCTUnwrap(state.routes[plan.routeIDsByUsageDate[request.today]!])
        let futureRoute = try XCTUnwrap(state.routes[plan.routeIDsByUsageDate["2026-07-18"]!])

        XCTAssertEqual(todayRoute.plannedEvents.map(\.thresholdMinutes), [5, 7])
        XCTAssertEqual(futureRoute.plannedEvents.map(\.thresholdMinutes), [5, 10, 12])
        XCTAssertEqual(
            todayRoute.plannedEvents.first?.eventName,
            MeteringRouteNamespace.eventName(routeID: todayRoute.routeID, thresholdMinutes: 5)
        )
        XCTAssertEqual(request.authoritativeBaseAcceptedMinutes + 5, 10)
    }

    func testExhaustedCurrentRouteHasNoEventsAndExistingRoutesIgnoreChangedPoolAndCap() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-horizon-exhausted-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let exhausted = MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: generationKey(owner: owner),
            persistedSelectionBytes: Data([0x00, 0x01, 0xFE, 0xFF]),
            poolMinutes: 60,
            deviceCapMinutes: 12,
            authoritativeBaseAcceptedMinutes: 12,
            now: Date(timeIntervalSince1970: 1_784_764_800)
        )
        let first = try store.reconcileMeteringHorizon(exhausted)
        let firstState = try store.read()
        let changedRuntime = MeteringHorizonRequest(
            ownerChildDeviceID: exhausted.ownerChildDeviceID,
            today: exhausted.today,
            generationKey: exhausted.generationKey,
            persistedSelectionBytes: exhausted.persistedSelectionBytes,
            poolMinutes: 30,
            deviceCapMinutes: 30,
            authoritativeBaseAcceptedMinutes: exhausted.authoritativeBaseAcceptedMinutes,
            now: exhausted.now.addingTimeInterval(60)
        )
        let second = try store.reconcileMeteringHorizon(changedRuntime)
        let secondState = try store.read()

        XCTAssertTrue(firstState.routes[first.routeIDsByUsageDate[exhausted.today]!]!.plannedEvents.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(firstState, secondState)
    }

    func testGenerationDecisionChangesOnlyForTheSixGenerationIdentityFields() {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let active = generationKey(owner: owner)
        let alteredKeys = [
            MeteringGenerationKey(protocolVersion: 3, childDeviceID: owner, canonicalTimezone: active.canonicalTimezone, policyRevision: active.policyRevision, measurementSelectionDigest: active.measurementSelectionDigest, enforcementSetID: active.enforcementSetID),
            MeteringGenerationKey(protocolVersion: active.protocolVersion, childDeviceID: UUID(), canonicalTimezone: active.canonicalTimezone, policyRevision: active.policyRevision, measurementSelectionDigest: active.measurementSelectionDigest, enforcementSetID: active.enforcementSetID),
            MeteringGenerationKey(protocolVersion: active.protocolVersion, childDeviceID: owner, canonicalTimezone: "Asia/Tokyo", policyRevision: active.policyRevision, measurementSelectionDigest: active.measurementSelectionDigest, enforcementSetID: active.enforcementSetID),
            MeteringGenerationKey(protocolVersion: active.protocolVersion, childDeviceID: owner, canonicalTimezone: active.canonicalTimezone, policyRevision: "policy-r2", measurementSelectionDigest: active.measurementSelectionDigest, enforcementSetID: active.enforcementSetID),
            MeteringGenerationKey(protocolVersion: active.protocolVersion, childDeviceID: owner, canonicalTimezone: active.canonicalTimezone, policyRevision: active.policyRevision, measurementSelectionDigest: "other-digest", enforcementSetID: active.enforcementSetID),
            MeteringGenerationKey(protocolVersion: active.protocolVersion, childDeviceID: owner, canonicalTimezone: active.canonicalTimezone, policyRevision: active.policyRevision, measurementSelectionDigest: active.measurementSelectionDigest, enforcementSetID: UUID()),
        ]

        XCTAssertEqual(MeteringEpochContract.generationDecision(active: active, next: active), .keep)
        for changed in alteredKeys {
            XCTAssertEqual(MeteringEpochContract.generationDecision(active: active, next: changed), .install(changed))
        }
    }

    func testMutableReconciliationAxesNeverReplaceExistingGenerationOrRoutes() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-horizon-mutable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let initial = MeteringHorizonRequest(
            ownerChildDeviceID: owner,
            today: "2026-07-17",
            generationKey: generationKey(owner: owner),
            persistedSelectionBytes: Data([0x00, 0x01, 0xFE, 0xFF]),
            poolMinutes: 120,
            deviceCapMinutes: 62,
            authoritativeBaseAcceptedMinutes: 12,
            now: Date(timeIntervalSince1970: 1_784_764_800)
        )
        let first = try store.reconcileMeteringHorizon(initial)
        let originalRouteIDs = first.routeIDsByUsageDate
        let todayRouteID = try XCTUnwrap(originalRouteIDs[initial.today])
        let todayEpochID = try XCTUnwrap((try store.read()).routes[todayRouteID]?.epochID)

        try store.transaction(expectedOwner: owner) { state in
            let route = try XCTUnwrap(state.routes[todayRouteID])
            let epoch = try XCTUnwrap(state.epochs[route.epochID])
            state.epochs[route.epochID] = DeviceDailyEpoch(
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
                baseAcceptedMinutes: 37,
                baseSource: epoch.baseSource,
                lastRawThresholdMinutes: 45,
                excludedWhilePausedMinutes: epoch.excludedWhilePausedMinutes,
                status: .paused,
                resumeBoundaryPending: true,
                retiredAt: epoch.retiredAt,
                retireReason: epoch.retireReason,
                exhaustedAt: epoch.exhaustedAt,
                baseCorrectionState: epoch.baseCorrectionState,
                authoritativeBaseConflict: epoch.authoritativeBaseConflict
            )
            let installKey = try XCTUnwrap(state.installWork.first(where: { $0.value.routeID == route.routeID })?.key)
            var work = try XCTUnwrap(state.installWork[installKey])
            work.retry = MeteringRetryState(
                attemptCount: 3,
                nextAttemptAt: initial.now.addingTimeInterval(60),
                lastErrorCode: "transient",
                terminal: .pending
            )
            state.installWork[installKey] = work
        }

        // V2 has no offset input: offset is deliberately absent from both the
        // request and generation key. A changed canonical date and timestamp are
        // represented by these two request fields without becoming generation identity.
        let nextDay = MeteringHorizonRequest(
            ownerChildDeviceID: initial.ownerChildDeviceID,
            today: "2026-07-18",
            generationKey: initial.generationKey,
            persistedSelectionBytes: initial.persistedSelectionBytes,
            poolMinutes: initial.poolMinutes,
            deviceCapMinutes: initial.deviceCapMinutes,
            authoritativeBaseAcceptedMinutes: 99,
            now: initial.now.addingTimeInterval(300)
        )
        let second = try store.reconcileMeteringHorizon(nextDay)
        let state = try store.read()

        XCTAssertEqual(second.generationID, first.generationID)
        for (usageDate, routeID) in originalRouteIDs {
            XCTAssertEqual(state.routes[routeID]?.usageDate, usageDate)
        }
        XCTAssertEqual(state.routes[todayRouteID]?.epochID, todayEpochID)
        XCTAssertEqual(state.epochs[todayEpochID]?.baseAcceptedMinutes, 37)
        XCTAssertEqual(state.epochs[todayEpochID]?.lastRawThresholdMinutes, 45)
        XCTAssertEqual(state.epochs[todayEpochID]?.status, .paused)
        XCTAssertEqual(state.epochs[todayEpochID]?.resumeBoundaryPending, true)
        XCTAssertEqual(state.installWork.values.first(where: { $0.routeID == todayRouteID })?.retry.attemptCount, 3)
        XCTAssertEqual(state.installWork.values.first(where: { $0.routeID == todayRouteID })?.retry.lastErrorCode, "transient")
        XCTAssertFalse(Mirror(reflecting: initial).children.compactMap(\.label).contains("offsetMinutes"))
    }

    func testRetiredGenerationIsNotReusedWhenIdentityReturnsFromR1ToR2ToR1() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let selectionBytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-horizon-retired-generation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })
        let r1Key = generationKey(owner: owner)
        let r2Key = MeteringGenerationKey(
            protocolVersion: r1Key.protocolVersion,
            childDeviceID: r1Key.childDeviceID,
            canonicalTimezone: r1Key.canonicalTimezone,
            policyRevision: "policy-r2",
            measurementSelectionDigest: r1Key.measurementSelectionDigest,
            enforcementSetID: r1Key.enforcementSetID
        )
        let startedAt = Date(timeIntervalSince1970: 1_784_764_800)

        func request(key: MeteringGenerationKey, now: Date) -> MeteringHorizonRequest {
            MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: "2026-07-17",
                generationKey: key,
                persistedSelectionBytes: selectionBytes,
                poolMinutes: 120,
                deviceCapMinutes: 62,
                authoritativeBaseAcceptedMinutes: 12,
                now: now
            )
        }

        let firstR1 = try store.reconcileMeteringHorizon(request(key: r1Key, now: startedAt))
        let r2 = try store.reconcileMeteringHorizon(
            request(key: r2Key, now: startedAt.addingTimeInterval(60))
        )
        XCTAssertNotEqual(r2.generationID, firstR1.generationID)

        let retiredAt = startedAt.addingTimeInterval(120)
        try store.transaction(expectedOwner: owner) { state in
            XCTAssertEqual(state.activeGenerationID, r2.generationID)
            var retiredR1 = try XCTUnwrap(state.generations[firstR1.generationID])
            retiredR1.retiredAt = retiredAt
            state.generations[firstR1.generationID] = retiredR1
        }
        let retiredState = try store.read()
        let retiredGeneration = try XCTUnwrap(retiredState.generations[firstR1.generationID])
        let oldRouteIDs = Set(firstR1.routeIDsByUsageDate.values)
        let oldEpochIDs = Set(try oldRouteIDs.map { routeID in
            try XCTUnwrap(retiredState.routes[routeID]?.epochID)
        })

        let returningR1 = try store.reconcileMeteringHorizon(
            request(key: r1Key, now: startedAt.addingTimeInterval(180))
        )
        let finalState = try store.read()
        let returningRouteIDs = Set(returningR1.routeIDsByUsageDate.values)
        let returningEpochIDs = Set(try returningRouteIDs.map { routeID in
            try XCTUnwrap(finalState.routes[routeID]?.epochID)
        })

        XCTAssertNotEqual(returningR1.generationID, firstR1.generationID)
        XCTAssertNotEqual(returningR1.generationID, r2.generationID)
        XCTAssertTrue(oldRouteIDs.isDisjoint(with: returningRouteIDs))
        XCTAssertTrue(oldEpochIDs.isDisjoint(with: returningEpochIDs))
        XCTAssertEqual(finalState.generations[firstR1.generationID], retiredGeneration)
        for routeID in oldRouteIDs {
            XCTAssertEqual(finalState.routes[routeID], retiredState.routes[routeID])
        }
        for epochID in oldEpochIDs {
            XCTAssertEqual(finalState.epochs[epochID], retiredState.epochs[epochID])
        }
    }

    func testLiveGenerationReusePrefersActiveThenNewestThenUUIDTieBreak() throws {
        let owner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let selectionBytes = Data([0x00, 0x01, 0xFE, 0xFF])
        let key = generationKey(owner: owner)
        let startedAt = Date(timeIntervalSince1970: 1_784_764_800)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metering-horizon-generation-order-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = DeviceEpochStore(fileURL: storeURL, ownerProvider: { owner })

        func request(now: Date) -> MeteringHorizonRequest {
            MeteringHorizonRequest(
                ownerChildDeviceID: owner,
                today: "2026-07-17",
                generationKey: key,
                persistedSelectionBytes: selectionBytes,
                poolMinutes: 120,
                deviceCapMinutes: 62,
                authoritativeBaseAcceptedMinutes: 12,
                now: now
            )
        }

        func generation(id: UUID, createdAt: Date) -> MeteringPolicyGeneration {
            MeteringPolicyGeneration(
                generationID: id,
                protocolVersion: key.protocolVersion,
                childDeviceID: key.childDeviceID,
                canonicalTimezone: key.canonicalTimezone,
                policyRevision: key.policyRevision,
                measurementSelectionDigest: key.measurementSelectionDigest,
                enforcementSetID: key.enforcementSetID,
                measurementSelectionBytes: selectionBytes,
                createdAt: createdAt,
                retiredAt: nil
            )
        }

        let initial = try store.reconcileMeteringHorizon(request(now: startedAt))
        let newerID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        try store.transaction(expectedOwner: owner) { state in
            state.generations[newerID] = generation(
                id: newerID,
                createdAt: startedAt.addingTimeInterval(60)
            )
        }

        let activePreferred = try store.reconcileMeteringHorizon(
            request(now: startedAt.addingTimeInterval(120))
        )
        XCTAssertEqual(activePreferred.generationID, initial.generationID)

        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = nil
        }
        let newestPreferred = try store.reconcileMeteringHorizon(
            request(now: startedAt.addingTimeInterval(180))
        )
        XCTAssertEqual(newestPreferred.generationID, newerID)

        let lowerTieID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let upperTieID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let tiedCreatedAt = startedAt.addingTimeInterval(240)
        try store.transaction(expectedOwner: owner) { state in
            state.activeGenerationID = nil
            state.generations[upperTieID] = generation(id: upperTieID, createdAt: tiedCreatedAt)
            state.generations[lowerTieID] = generation(id: lowerTieID, createdAt: tiedCreatedAt)
        }
        let tieBroken = try store.reconcileMeteringHorizon(
            request(now: startedAt.addingTimeInterval(300))
        )
        XCTAssertEqual(tieBroken.generationID, lowerTieID)
    }

    private func generationKey(owner: UUID) -> MeteringGenerationKey {
        MeteringGenerationKey(
            protocolVersion: 2,
            childDeviceID: owner,
            canonicalTimezone: "America/New_York",
            policyRevision: "policy-r1",
            measurementSelectionDigest: MeteringEpochContract.selectionDigest(
                persistedBytes: Data([0x00, 0x01, 0xFE, 0xFF])
            ),
            enforcementSetID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
    }

    func test_makeEventExcludesPastActivity() {
        let event = EarnedBudgetScheduler.makeEvent(
            selection: FamilyActivitySelection(),
            thresholdMinutes: 5
        )

        XCTAssertFalse(event.includesPastActivity)
    }


    func test_generatedActivityNamesAreDistinctAndRecognized() {
        let first = LegacyMeteringActivity.generatedActivityName(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = LegacyMeteringActivity.generatedActivityName(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(LegacyMeteringActivity.isEarnedActivityName(first))
        XCTAssertTrue(LegacyMeteringActivity.isEarnedActivityName(second))
        XCTAssertTrue(LegacyMeteringActivity.isEarnedActivityName(
            LegacyMeteringActivity.legacyActivityName
        ))
        XCTAssertFalse(LegacyMeteringActivity.isEarnedActivityName("evlin.earned.other"))
    }


    // MARK: - Bucket constant

    func test_bucketMinutes_isFive() {
        XCTAssertEqual(EarnedBudgetScheduler.earnedBucketMinutes, 5)
    }

    // MARK: - Basic capping at cap (cap < pool, multiple of bucket)

    func test_thresholds_pool120_cap90_stopsAtCap() {
        // cap=90, buckets: 5,10,15,...,90 (all multiples up to cap)
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 90)
        let expected = stride(from: 5, through: 90, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Exact cap appended when not a multiple of bucket

    func test_thresholds_pool120_cap95_appendsExactCap() {
        // cap=97, buckets up to 95 (last multiple ≤ 97), then 97 appended
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 97)
        let multiples = stride(from: 5, through: 95, by: 5).map { $0 }
        let expected = multiples + [97]
        XCTAssertEqual(result, expected)
    }

    // MARK: - pool == cap (full range)

    func test_thresholds_pool120_cap120_coversFullRange() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 120)
        let expected = stride(from: 5, through: 120, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
    }

    // MARK: - Pool smaller than cap → capped at pool

    func test_thresholds_pool60_cap120_cappedAtPool() {
        // effective ceiling = min(60, 120) = 60
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 60, capMinutes: 120)
        let expected = stride(from: 5, through: 60, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
    }

    func test_thresholds_pool240_cap240_coversFourHoursAtFiveMinuteGranularity() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 240, capMinutes: 240)
        let expected = stride(from: 5, through: 240, by: 5).map { $0 }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.count, 48)
        XCTAssertEqual(EarnedBudgetScheduler.guardEventCount, 48)
    }

    // MARK: - Event count guard

    func test_thresholds_neverExceedsGuardConstant() {
        // Even with a very large pool/cap the count stays ≤ guardEventCount
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 10_000, capMinutes: 10_000)
        XCTAssertLessThanOrEqual(result.count, EarnedBudgetScheduler.guardEventCount)
    }

    func test_thresholds_300MinutePolicyUsesExactAdaptiveTenMinuteLadder() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 300, capMinutes: 300)

        XCTAssertEqual(result, stride(from: 10, through: 300, by: 10).map { $0 })
        XCTAssertEqual(result.count, 30)
    }

    func test_thresholds_1440MinutePolicyUsesCompleteThirtyMinuteLadderWithinGuard() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 1_440, capMinutes: 1_440)

        XCTAssertEqual(result, stride(from: 30, through: 1_440, by: 30).map { $0 })
        XCTAssertEqual(result.count, EarnedBudgetScheduler.guardEventCount)
    }

    func test_thresholds_ordinaryPolicyPreservesFiveMinuteLadderAndExactTerminal() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 237, capMinutes: 237)

        XCTAssertEqual(result, stride(from: 5, through: 235, by: 5).map { $0 } + [237])
        XCTAssertEqual(result.count, EarnedBudgetScheduler.guardEventCount)
    }

    func test_thresholds_adaptivePolicyRetainsNonmultipleTerminalWithoutLargeGap() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 301, capMinutes: 301)

        XCTAssertEqual(result, stride(from: 10, through: 300, by: 10).map { $0 } + [301])
        XCTAssertLessThanOrEqual(result.count, EarnedBudgetScheduler.guardEventCount)
    }

    func test_thresholds_coverEveryLegalMinuteCeilingWithoutSilentGap() {
        for ceiling in 1...1_440 {
            let result = EarnedBudgetScheduler.thresholds(
                poolMinutes: ceiling,
                capMinutes: ceiling
            )

            XCTAssertFalse(result.isEmpty, "ceiling=\(ceiling)")
            XCTAssertLessThanOrEqual(
                result.count,
                EarnedBudgetScheduler.guardEventCount,
                "ceiling=\(ceiling)"
            )
            XCTAssertEqual(result.last, ceiling, "ceiling=\(ceiling)")
            XCTAssertEqual(result, result.sorted(), "ceiling=\(ceiling)")
            XCTAssertEqual(Set(result).count, result.count, "ceiling=\(ceiling)")

            let minimumStep = (ceiling + EarnedBudgetScheduler.guardEventCount - 1)
                / EarnedBudgetScheduler.guardEventCount
            let expectedStep = max(
                EarnedBudgetScheduler.earnedBucketMinutes,
                ((minimumStep + EarnedBudgetScheduler.earnedBucketMinutes - 1)
                    / EarnedBudgetScheduler.earnedBucketMinutes)
                    * EarnedBudgetScheduler.earnedBucketMinutes
            )
            let points = [0] + result
            for (lower, upper) in zip(points, points.dropFirst()) {
                XCTAssertGreaterThan(upper, lower, "ceiling=\(ceiling)")
                XCTAssertLessThanOrEqual(
                    upper - lower,
                    expectedStep,
                    "ceiling=\(ceiling) gap=\(lower)...\(upper)"
                )
            }

            if ceiling <= 240 {
                var expected = stride(from: 5, through: ceiling, by: 5).map { $0 }
                if expected.last != ceiling {
                    expected.append(ceiling)
                }
                XCTAssertEqual(result, expected, "ceiling=\(ceiling)")
            }
        }
    }

    // MARK: - Threshold list never exceeds min(pool, cap)

    func test_thresholds_neverExceedsMinPoolCap() {
        let cases: [(pool: Int, cap: Int)] = [
            (90, 90), (120, 90), (90, 120),
            (45, 50), (50, 45), (240, 240)
        ]
        for (pool, cap) in cases {
            let result = EarnedBudgetScheduler.thresholds(poolMinutes: pool, capMinutes: cap)
            let ceiling = min(pool, cap)
            XCTAssertTrue(
                result.allSatisfy { $0 <= ceiling },
                "pool=\(pool) cap=\(cap) — found threshold > \(ceiling): \(result)"
            )
        }
    }

    // MARK: - Exact cap NOT duplicated when already a bucket multiple

    func test_thresholds_capAlreadyMultipleOfBucket_notDuplicated() {
        // cap=90 is already a multiple of 5; it must appear exactly once
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 90)
        let count = result.filter { $0 == 90 }.count
        XCTAssertEqual(count, 1, "cap=90 (already a bucket multiple) must appear exactly once")
    }

    // MARK: - Edge: pool or cap ≤ 0 → empty

    func test_thresholds_zeroPool_isEmpty() {
        XCTAssertTrue(EarnedBudgetScheduler.thresholds(poolMinutes: 0, capMinutes: 60).isEmpty)
    }

    func test_thresholds_zeroCap_isEmpty() {
        XCTAssertTrue(EarnedBudgetScheduler.thresholds(poolMinutes: 60, capMinutes: 0).isEmpty)
    }

    // MARK: - Ascending order

    func test_thresholds_alwaysAscending() {
        let result = EarnedBudgetScheduler.thresholds(poolMinutes: 120, capMinutes: 97)
        for i in 1..<result.count {
            XCTAssertLessThan(result[i - 1], result[i], "thresholds must be strictly ascending")
        }
    }

    func test_remainingPolicyArmsOnlyUncountedWindowAfterOffset() {
        let policy = EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: 20,
            capMinutes: 20,
            offsetMinutes: 5
        )

        XCTAssertEqual(policy?.poolMinutes, 15)
        XCTAssertEqual(policy?.capMinutes, 15)
        XCTAssertEqual(
            EarnedBudgetScheduler.thresholds(
                poolMinutes: policy?.poolMinutes ?? 0,
                capMinutes: policy?.capMinutes ?? 0
            ),
            [5, 10, 15]
        )
    }

    func test_remainingPolicyReturnsNilWhenOffsetAlreadyExhausted() {
        XCTAssertNil(EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: 20,
            capMinutes: 20,
            offsetMinutes: 20
        ))
        XCTAssertNil(EarnedBudgetScheduler.remainingPolicy(
            poolMinutes: 20,
            capMinutes: 15,
            offsetMinutes: 15
        ))
    }

    func test_resumeScheduleUsesBackendTimezoneForPolicyDayBoundary() {
        let backendTimeZone = TimeZone(identifier: "America/Los_Angeles")!
        let deviceCalendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_768_173_300) // 2026-01-11T23:15:00Z

        let schedule = EarnedBudgetScheduler.resumeSchedule(
            startingAt: start,
            timeZone: backendTimeZone,
            calendar: deviceCalendar
        )

        XCTAssertEqual(schedule.intervalStart.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalStart.hour, 15)
        XCTAssertEqual(schedule.intervalEnd.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalEnd.hour, 23)
        XCTAssertEqual(schedule.intervalEnd.minute, 59)
    }

    func test_dailyScheduleCarriesBackendTimezoneInBothBoundaries() {
        let backendTimeZone = TimeZone(identifier: "Pacific/Honolulu")!

        let schedule = EarnedBudgetScheduler.dailySchedule(
            timeZone: backendTimeZone
        )

        XCTAssertEqual(schedule.intervalStart.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalStart.hour, 0)
        XCTAssertEqual(schedule.intervalEnd.timeZone, backendTimeZone)
        XCTAssertEqual(schedule.intervalEnd.hour, 23)
        XCTAssertEqual(schedule.intervalEnd.minute, 59)
        XCTAssertTrue(schedule.repeats)
    }

    func test_resumeScheduleStartsAtNowAndDoesNotRepeatFromMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 3,
            hour: 14,
            minute: 32,
            second: 16
        ).date!

        let schedule = EarnedBudgetScheduler.resumeSchedule(startingAt: start, calendar: calendar)

        XCTAssertEqual(schedule.intervalStart.year, 2026)
        XCTAssertEqual(schedule.intervalStart.month, 7)
        XCTAssertEqual(schedule.intervalStart.day, 3)
        XCTAssertEqual(schedule.intervalStart.hour, 14)
        XCTAssertEqual(schedule.intervalStart.minute, 32)
        XCTAssertEqual(schedule.intervalStart.second, 16)
        XCTAssertEqual(schedule.intervalEnd.hour, 23)
        XCTAssertEqual(schedule.intervalEnd.minute, 59)
        XCTAssertFalse(schedule.repeats)
    }
}
