import CryptoKit
import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

/// P5 — the "20-slot packer". These tests assert on event NAMES / counts and
/// window bucketing, never on opaque `ApplicationToken` contents (which cannot
/// be minted in a unit test — see `AppLimitRuleStoreTests`, which uses `[]`).
final class AppLimitPlannerTests: XCTestCase {

    // MARK: - Spy

    /// Records the `events:` overload so we can assert which activities were
    /// armed, the events dict per activity, and the stop/start ordering.
    private final class PlannerSchedulerSpy: DeviceActivityScheduling {
        struct Armed {
            let name: DeviceActivityName
            let schedule: DeviceActivitySchedule
            let events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        }
        /// Append-only log of every monitoring call, in order, so a test can
        /// assert "stopped before started" (idempotent repack).
        enum Call: Equatable {
            case start(String)
            case startEvents(String)
            case stop([String])
            case stopAll
        }
        private(set) var armed: [Armed] = []
        private(set) var startedNoEvents: [(name: DeviceActivityName, schedule: DeviceActivitySchedule)] = []
        private(set) var stopped: [[DeviceActivityName]?] = []
        private(set) var calls: [Call] = []
        /// Live armed set backing `monitoredActivities()`. Added on a successful
        /// start, removed on stop — so a spy shared across two planner instances
        /// reports the live set, which is what self-healing discovery reads.
        private(set) var activeActivities: Set<DeviceActivityName> = []
        /// Throws from EVERY startMonitoring call (legacy unconditional path).
        var errorToThrow: Error?
        /// Throws ONLY when the armed activity's name is in this set — lets a
        /// test make a single window fail while the rest succeed.
        var failingActivityNames: Set<String> = []
        var beforeStartEvents: ((String) -> Void)?

        func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
            if let e = errorToThrow { throw e }
            if failingActivityNames.contains(name.rawValue) { throw NSError(domain: "spy", code: 1) }
            startedNoEvents.append((name, schedule))
            activeActivities.insert(name)
            calls.append(.start(name.rawValue))
        }

        func startMonitoring(
            _ activity: DeviceActivityName,
            during schedule: DeviceActivitySchedule,
            events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        ) throws {
            if let e = errorToThrow { throw e }
            if failingActivityNames.contains(activity.rawValue) { throw NSError(domain: "spy", code: 1) }
            beforeStartEvents?(activity.rawValue)
            armed.append(Armed(name: activity, schedule: schedule, events: events))
            activeActivities.insert(activity)
            calls.append(.startEvents(activity.rawValue))
        }

        func stopMonitoring(_ activities: [DeviceActivityName]) {
            stopped.append(activities)
            for a in activities { activeActivities.remove(a) }
            calls.append(.stop(activities.map(\.rawValue).sorted()))
        }

        func stopMonitoring() {
            stopped.append(nil)
            activeActivities.removeAll()
            calls.append(.stopAll)
        }

        func monitoredActivities() -> [DeviceActivityName] { Array(activeActivities) }
    }

    // MARK: - Fixtures

    private let dailyWindow = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil)

    private func rule(
        id: UUID = UUID(),
        budget: Int = 30,
        window: AppLimitWindow? = nil,
        effectiveFrom: Date = Date(timeIntervalSince1970: 0),
        expiresAt: Date? = nil,
        bundleID: String = "com.example.app"
    ) -> AppLimitRule {
        AppLimitRule(
            id: id,
            appTokens: [],
            bundleID: bundleID,
            displayName: bundleID,
            budgetMinutes: budget,
            window: window ?? dailyWindow,
            effectiveFrom: effectiveFrom,
            expiresAt: expiresAt
        )
    }

    // MARK: - Phase 4 stable per-rule provenance

    func testProgressAndRestartPreserveArmProvenanceWithoutCenterCalls() throws {
        let owner = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
        let armID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let store = makeEpochStore(owner: owner)
        let configured = rule(
            id: ruleID,
            budget: 30,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "UTC"
            )
        )
        try seed(configured, token: 7, owner: owner, store: store)
        let spy = PlannerSchedulerSpy()

        let first = AppLimitPlanner(
            scheduler: spy,
            now: { now },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { armID }
        )
        XCTAssertEqual(first.arm(rules: [configured]), .armed(activityCount: 1, eventCount: 1))
        let initialCalls = spy.calls
        let initial = try XCTUnwrap(store.read().slots[ruleID]?.armProvenance)
        XCTAssertEqual(initial.ruleID, ruleID)
        XCTAssertEqual(initial.ruleRevision, 7)
        XCTAssertEqual(initial.childDeviceID, owner)
        XCTAssertEqual(initial.usageDate, "2024-07-17")
        XCTAssertEqual(initial.timezone, "UTC")
        XCTAssertEqual(initial.scheduleWindow, configured.window)
        XCTAssertEqual(initial.budgetMinutes, 30)
        XCTAssertEqual(initial.armID, armID)
        XCTAssertEqual(initial.activityName, "evlin.limit.v2.\(armID.uuidString.lowercased())")

        try store.transaction(source: .wakeRecovery, expectedOwner: owner) { state in
            var slot = try XCTUnwrap(state.slots[ruleID])
            var progress = try XCTUnwrap(slot.armProvenance)
            progress.lastRawThresholdMinutes = 15
            progress.baseAcceptedMinutes = 5
            slot.armProvenance = progress
            state.slots[ruleID] = slot
        }

        let restarted = AppLimitPlanner(
            scheduler: spy,
            now: { now.addingTimeInterval(600) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { UUID() }
        )
        XCTAssertEqual(restarted.arm(rules: [configured]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(spy.calls, initialCalls, "progress/restart must not stop or re-arm")
        let after = try XCTUnwrap(store.read().slots[ruleID]?.armProvenance)
        XCTAssertEqual(after.armID, armID)
        XCTAssertEqual(after.activityName, initial.activityName)
        XCTAssertEqual(after.lastRawThresholdMinutes, 15)
        XCTAssertEqual(after.baseAcceptedMinutes, 5)
    }

    func testReplacementKeyChangeCreatesNewArmAndNames() throws {
        let owner = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
        let firstArm = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let secondArm = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000011")!
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let store = makeEpochStore(owner: owner)
        let original = rule(id: ruleID, budget: 30)
        try seed(original, token: 7, owner: owner, store: store)
        let spy = PlannerSchedulerSpy()
        _ = AppLimitPlanner(
            scheduler: spy,
            now: { now },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { firstArm }
        ).arm(rules: [original])

        let changed = rule(id: ruleID, budget: 31)
        try seed(changed, token: 8, owner: owner, store: store)
        _ = AppLimitPlanner(
            scheduler: spy,
            now: { now },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { secondArm }
        ).arm(rules: [changed])

        let provenance = try XCTUnwrap(store.read().slots[ruleID]?.armProvenance)
        XCTAssertEqual(provenance.armID, secondArm)
        XCTAssertEqual(provenance.ruleRevision, 8)
        XCTAssertEqual(provenance.budgetMinutes, 31)
        XCTAssertTrue(spy.calls.contains(.stop(["evlin.limit.v2.\(firstArm.uuidString.lowercased())"])))
        XCTAssertTrue(spy.calls.contains(.startEvents("evlin.limit.v2.\(secondArm.uuidString.lowercased())")))
    }

    func testV2EnforcementAndMeasurementEventsExcludePastActivity() throws {
        let owner = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
        let armID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let store = makeEpochStore(owner: owner)
        let configured = rule(id: ruleID, budget: 60)
        try seed(configured, token: 7, owner: owner, store: store)
        let spy = PlannerSchedulerSpy()

        _ = AppLimitPlanner(
            scheduler: spy,
            now: { Date(timeIntervalSince1970: 1_721_174_400) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { armID }
        ).arm(rules: [configured])

        let events = try XCTUnwrap(spy.armed.first?.events)
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events.values.allSatisfy { !$0.includesPastActivity })
        XCTAssertNotNil(events[DeviceActivityEvent.Name(
            "evlin.limit.v2.\(armID.uuidString.lowercased()).budget"
        )])
        for threshold in [15, 30, 45] {
            XCTAssertNotNil(events[DeviceActivityEvent.Name(
                "evlin.applimit.v2.\(armID.uuidString.lowercased()).t\(threshold)"
            )])
        }
    }

    func testRetryAfterFailedStartRefreshesPhysicalStartWithoutChangingArm() throws {
        let owner = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
        let armID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let firstAttempt = Date(timeIntervalSince1970: 1_721_174_400)
        let retryAttempt = firstAttempt.addingTimeInterval(3_600)
        let store = makeEpochStore(owner: owner)
        let configured = rule(id: ruleID, budget: 30)
        try seed(configured, token: 7, owner: owner, store: store)
        let spy = PlannerSchedulerSpy()
        spy.errorToThrow = NSError(domain: "start", code: 1)

        let failed = AppLimitPlanner(
            scheduler: spy,
            now: { firstAttempt },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { armID }
        )
        XCTAssertEqual(failed.arm(rules: [configured]), .partiallyArmed(armed: 0, failed: 1))
        XCTAssertEqual(try store.read().slots[ruleID]?.armProvenance?.startedAt, firstAttempt)

        spy.errorToThrow = nil
        let retry = AppLimitPlanner(
            scheduler: spy,
            now: { retryAttempt },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { UUID() }
        )
        XCTAssertEqual(retry.arm(rules: [configured]), .armed(activityCount: 1, eventCount: 1))

        let provenance = try XCTUnwrap(store.read().slots[ruleID]?.armProvenance)
        XCTAssertEqual(provenance.armID, armID, "retry preserves replacement identity")
        XCTAssertEqual(
            provenance.startedAt,
            retryAttempt,
            "physical trust must start at the successful retry, not the failed attempt"
        )
    }

    func testRemainingBudgetViewUpdatesBaseWithoutReplacingOrRearming() throws {
        let owner = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
        let armID = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let store = makeEpochStore(owner: owner)
        let canonical = rule(id: ruleID, budget: 30)
        try seed(canonical, token: 7, owner: owner, store: store)
        let spy = PlannerSchedulerSpy()

        let initial = AppLimitPlanner(
            scheduler: spy,
            now: { now },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { armID }
        )
        XCTAssertEqual(initial.arm(rules: [canonical]), .armed(activityCount: 1, eventCount: 1))
        let initialCalls = spy.calls

        let remainingView = rule(id: ruleID, budget: 20)
        let progress = AppLimitPlanner(
            scheduler: spy,
            now: { now.addingTimeInterval(600) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { UUID() }
        )
        XCTAssertEqual(progress.arm(rules: [remainingView]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(spy.calls, initialCalls, "progress must not stop or re-arm the live activity")

        let provenance = try XCTUnwrap(try store.read().slots[ruleID]?.armProvenance)
        XCTAssertEqual(provenance.armID, armID)
        XCTAssertEqual(provenance.budgetMinutes, 30, "replacement identity keeps canonical policy")
        XCTAssertEqual(provenance.baseAcceptedMinutes, 10, "remaining view advances progress only")
    }

    func testConcurrentReplacementCannotCommitBetweenArmCheckAndStart() throws {
        let owner = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "dddddddd-0000-0000-0000-000000000400")!
        let firstArm = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000010")!
        let secondArm = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000011")!
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let store = makeEpochStore(owner: owner, lock: ActiveLockPersistenceLock.shared)
        let original = rule(id: ruleID, budget: 30)
        let replacement = rule(id: ruleID, budget: 31)
        try seed(original, token: 7, owner: owner, store: store)
        let spy = PlannerSchedulerSpy()
        let replacementAttempted = DispatchSemaphore(value: 0)
        let replacementFinished = DispatchSemaphore(value: 0)
        var replacementCommittedInsideStart = false

        spy.beforeStartEvents = { name in
            guard name == AppLimitPlanner.v2ActivityName(armID: firstArm) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                replacementAttempted.signal()
                let coordinator = AppLimitCommandCoordinator(
                    store: store,
                    expectedOwnerProvider: { owner }
                )
                let envelope = AppLimitCommandEnvelope(
                    commandID: UUID(),
                    ruleID: ruleID,
                    orderingToken: 8,
                    kind: .set,
                    payloadDigest: "set-8",
                    receivedAt: now.addingTimeInterval(1),
                    source: .poll,
                    rule: replacement
                )
                _ = try? coordinator.ingest(envelope)
                replacementFinished.signal()
            }
            XCTAssertEqual(replacementAttempted.wait(timeout: .now() + 1), .success)
            replacementCommittedInsideStart = replacementFinished.wait(timeout: .now() + 1) == .success
        }

        let first = AppLimitPlanner(
            scheduler: spy,
            now: { now },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { firstArm }
        )
        XCTAssertEqual(first.arm(rules: [original]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertFalse(
            replacementCommittedInsideStart,
            "a newer token must not commit between the final arm check and startMonitoring"
        )
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try store.read().slots[ruleID]?.latestOrderingToken, 8)

        spy.beforeStartEvents = nil
        let second = AppLimitPlanner(
            scheduler: spy,
            now: { now.addingTimeInterval(2) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { secondArm }
        )
        XCTAssertEqual(second.arm(rules: [replacement]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(
            Set(spy.monitoredActivities().map(\.rawValue)),
            [AppLimitPlanner.v2ActivityName(armID: secondArm)]
        )
        let starts = spy.calls.compactMap { call -> String? in
            guard case .startEvents(let name) = call else { return nil }
            return name
        }
        XCTAssertEqual(
            starts,
            [
                AppLimitPlanner.v2ActivityName(armID: firstArm),
                AppLimitPlanner.v2ActivityName(armID: secondArm),
            ],
            "the stale arm may run before replacement, never after it"
        )
    }

    private func makeEpochStore(
        owner: UUID,
        lock: any DeviceEpochStoreLocking = PlannerEpochLock()
    ) -> AppLimitEpochStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-provenance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: lock,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
    }

    private func seed(
        _ rule: AppLimitRule,
        token: Int64,
        owner: UUID,
        store: AppLimitEpochStore
    ) throws {
        let envelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: rule.id,
            orderingToken: token,
            kind: .set,
            payloadDigest: "set-\(token)",
            receivedAt: Date(timeIntervalSince1970: 1_721_174_400),
            source: .poll,
            rule: rule
        )
        let coordinator = AppLimitCommandCoordinator(
            store: store,
            expectedOwnerProvider: { owner }
        )
        XCTAssertEqual(try coordinator.ingest(envelope), .acceptedNeedsOwner)
    }

    private func expectedWindowActivityName(_ window: AppLimitWindow) -> String {
        let key = "\(window.startMinute)|\(window.endMinute)|\(window.repeats)|\(window.timezone ?? "")"
        let hash = SHA256.hash(data: Data(key.utf8))
        let hex = Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "evlin.limit.window.\(hex)"
    }

    // MARK: - Daily window collapses to ONE activity with N events

    func testDailyWindowCollapsesToOneActivityWithNEvents() throws {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        let rules = (0..<5).map { rule(budget: 10 + $0, bundleID: "com.app.\($0)") }
        let result = planner.arm(rules: rules)

        guard case let .armed(activityCount, eventCount) = result else {
            return XCTFail("expected .armed, got \(result)")
        }
        XCTAssertEqual(activityCount, 1, "all 5 rules share the daily window → 1 slot")
        XCTAssertEqual(eventCount, 5)
        XCTAssertEqual(spy.armed.count, 1)

        let armed = try XCTUnwrap(spy.armed.first)
        XCTAssertEqual(armed.name.rawValue, expectedWindowActivityName(dailyWindow))
        XCTAssertTrue(armed.schedule.repeats)
        // ENFORCEMENT events only (`evlin.limit.*`); measurement (`evlin.applimit.*`)
        // usage-bar events also ride in the dict but aren't counted here.
        XCTAssertEqual(armed.events.keys.filter { $0.rawValue.hasPrefix("evlin.limit.") }.count, 5)

        // Each event is named evlin.limit.<ruleId> and threshold = budget minutes.
        for r in rules {
            let name = DeviceActivityEvent.Name("evlin.limit.\(r.id.uuidString)")
            let event = try XCTUnwrap(armed.events[name], "missing event for rule \(r.id)")
            XCTAssertEqual(event.threshold.minute, r.budgetMinutes)
        }
    }

    // MARK: - Two distinct windows → two activities

    func testTwoDistinctWindowsArmTwoActivities() throws {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        let morning = AppLimitWindow(startMinute: 0, endMinute: 720, repeats: true, timezone: nil)
        let evening = AppLimitWindow(startMinute: 720, endMinute: 1439, repeats: true, timezone: nil)
        let rules = [
            rule(window: morning, bundleID: "com.a"),
            rule(window: morning, bundleID: "com.b"),
            rule(window: evening, bundleID: "com.c"),
        ]

        let result = planner.arm(rules: rules)
        guard case let .armed(activityCount, eventCount) = result else {
            return XCTFail("expected .armed, got \(result)")
        }
        XCTAssertEqual(activityCount, 2)
        XCTAssertEqual(eventCount, 3)

        let names = Set(spy.armed.map(\.name.rawValue))
        XCTAssertEqual(names, [expectedWindowActivityName(morning), expectedWindowActivityName(evening)])

        let morningActivity = try XCTUnwrap(spy.armed.first { $0.name.rawValue == expectedWindowActivityName(morning) })
        XCTAssertEqual(morningActivity.events.keys.filter { $0.rawValue.hasPrefix("evlin.limit.") }.count, 2)
        let eveningActivity = try XCTUnwrap(spy.armed.first { $0.name.rawValue == expectedWindowActivityName(evening) })
        XCTAssertEqual(eveningActivity.events.keys.filter { $0.rawValue.hasPrefix("evlin.limit.") }.count, 1)
    }

    // MARK: - Quota: > 20 distinct windows → atomic failure, nothing armed

    func testTooManyDistinctWindowsReturnsQuotaExceededAndArmsNothing() {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        // 21 distinct windows (distinct startMinute) → exceeds the 20-slot cap.
        let rules = (0..<21).map { i -> AppLimitRule in
            let w = AppLimitWindow(startMinute: i, endMinute: 1439, repeats: true, timezone: nil)
            return rule(window: w, bundleID: "com.app.\(i)")
        }

        let result = planner.arm(rules: rules)
        guard case let .quotaExceeded(windows, slotsNeeded, cap) = result else {
            return XCTFail("expected .quotaExceeded, got \(result)")
        }
        XCTAssertEqual(windows, 21)
        XCTAssertEqual(slotsNeeded, 21)
        XCTAssertEqual(cap, AppLimitPlanner.maxActivities)

        // Atomic: validate-then-commit means NOTHING was armed (no partial arm).
        XCTAssertTrue(spy.armed.isEmpty, "must not arm any activity when quota is exceeded")
        XCTAssertTrue(spy.startedNoEvents.isEmpty)
        // And nothing was stopped either — we bail before touching the scheduler.
        XCTAssertTrue(spy.stopped.isEmpty, "atomic failure must not stop existing activities")
    }

    // MARK: - Exactly 20 windows is allowed (boundary)

    func testExactlyMaxWindowsIsAllowed() {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        let rules = (0..<AppLimitPlanner.maxActivities).map { i -> AppLimitRule in
            let w = AppLimitWindow(startMinute: i, endMinute: 1439, repeats: true, timezone: nil)
            return rule(window: w, bundleID: "com.app.\(i)")
        }

        let result = planner.arm(rules: rules)
        guard case let .armed(activityCount, _) = result else {
            return XCTFail("expected .armed at the boundary, got \(result)")
        }
        XCTAssertEqual(activityCount, AppLimitPlanner.maxActivities)
        XCTAssertEqual(spy.armed.count, AppLimitPlanner.maxActivities)
    }

    // MARK: - Time filtering

    func testFutureEffectiveFromIsFilteredOut() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        let active = rule(effectiveFrom: now.addingTimeInterval(-100), bundleID: "com.active")
        let future = rule(effectiveFrom: now.addingTimeInterval(3600), bundleID: "com.future")

        let result = planner.arm(rules: [active, future])
        guard case let .armed(activityCount, eventCount) = result else {
            return XCTFail("expected .armed, got \(result)")
        }
        XCTAssertEqual(activityCount, 1)
        XCTAssertEqual(eventCount, 1, "the future rule must be excluded")

        let armed = spy.armed.first
        let activeName = DeviceActivityEvent.Name("evlin.limit.\(active.id.uuidString)")
        let futureName = DeviceActivityEvent.Name("evlin.limit.\(future.id.uuidString)")
        XCTAssertNotNil(armed?.events[activeName])
        XCTAssertNil(armed?.events[futureName])
    }

    func testExpiredRuleIsFilteredOut() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        let active = rule(bundleID: "com.active")
        let expired = rule(expiresAt: now.addingTimeInterval(-1), bundleID: "com.expired")

        let result = planner.arm(rules: [active, expired])
        guard case let .armed(activityCount, eventCount) = result else {
            return XCTFail("expected .armed, got \(result)")
        }
        XCTAssertEqual(activityCount, 1)
        XCTAssertEqual(eventCount, 1, "the expired rule must be excluded")
    }

    func testExpiresAtIsExclusiveUpperBound() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        // expiresAt == now → now is NOT in [effectiveFrom, expiresAt) → filtered.
        let atBoundary = rule(expiresAt: now, bundleID: "com.boundary")
        let result = planner.arm(rules: [atBoundary])
        guard case let .armed(activityCount, _) = result else {
            return XCTFail("expected .armed (empty), got \(result)")
        }
        XCTAssertEqual(activityCount, 0)
        XCTAssertTrue(spy.armed.isEmpty)
    }

    func testNoActiveRulesArmsNothingButStillStopsPrior() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        let result = planner.arm(rules: [])
        XCTAssertEqual(result, .armed(activityCount: 0, eventCount: 0))
        XCTAssertTrue(spy.armed.isEmpty)
    }

    // MARK: - Idempotent repack: stop prior, then re-arm

    func testReArmingStopsPriorWindowThenReArms() {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        let rules = [rule(bundleID: "com.a"), rule(bundleID: "com.b")]

        // First arm.
        _ = planner.arm(rules: rules)
        // Second arm with same windows — must stop the prior activity, then re-arm.
        _ = planner.arm(rules: rules)

        let windowName = expectedWindowActivityName(dailyWindow)

        // The second run's call sequence must contain a stop of the window name
        // that happens BEFORE the re-arm of that same name.
        let secondRunCalls = spy.calls.suffix(2)
        XCTAssertEqual(
            Array(secondRunCalls),
            [.stop([windowName]), .startEvents(windowName)],
            "second arm must stop the prior window activity, then re-arm it (in that order)"
        )
    }

    func testReArmStopsWindowsThatVanishedBetweenRuns() {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        let morning = AppLimitWindow(startMinute: 0, endMinute: 720, repeats: true, timezone: nil)
        let evening = AppLimitWindow(startMinute: 720, endMinute: 1439, repeats: true, timezone: nil)

        // Run 1: two windows.
        _ = planner.arm(rules: [rule(window: morning, bundleID: "com.a"),
                                rule(window: evening, bundleID: "com.b")])
        // Run 2: only the morning window remains. The evening activity must be
        // stopped even though no current rule names it.
        _ = planner.arm(rules: [rule(window: morning, bundleID: "com.a")])

        // Last stop call should include BOTH window names (the union of what we
        // armed before + what we are about to arm now).
        let stops = spy.stopped.compactMap { $0 }.map { Set($0.map(\.rawValue)) }
        let lastStop = stops.last ?? []
        XCTAssertTrue(lastStop.contains(expectedWindowActivityName(morning)))
        XCTAssertTrue(lastStop.contains(expectedWindowActivityName(evening)),
                      "the vanished evening window must still be stopped")
    }

    // MARK: - Timezone is honored in the window key (distinct slots)

    func testDifferentTimezonesAreDistinctWindows() {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        let la = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: "America/Los_Angeles")
        let ny = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: "America/New_York")
        let result = planner.arm(rules: [rule(window: la, bundleID: "com.a"),
                                         rule(window: ny, bundleID: "com.b")])
        guard case let .armed(activityCount, _) = result else {
            return XCTFail("expected .armed, got \(result)")
        }
        XCTAssertEqual(activityCount, 2, "same minutes but different tz are distinct windows")
    }

    // MARK: - Quota: too many app tokens per window (conservative cap)

    func testTooManyEventsPerActivityReturnsQuotaExceeded() {
        let spy = PlannerSchedulerSpy()
        let planner = AppLimitPlanner(scheduler: spy, now: { Date(timeIntervalSince1970: 1_000_000) })

        // One window, more rules than maxEventsPerActivity → exceeds per-activity cap.
        let rules = (0...AppLimitPlanner.maxEventsPerActivity).map { rule(bundleID: "com.app.\($0)") }
        let result = planner.arm(rules: rules)
        guard case .quotaExceeded = result else {
            return XCTFail("expected .quotaExceeded for too many events, got \(result)")
        }
        XCTAssertTrue(spy.armed.isEmpty, "atomic: nothing armed when per-activity event cap exceeded")
    }

    // MARK: - Cross-instance self-healing: a fresh planner discovers + stops orphans

    /// The planner is NOT a singleton. Instance A arms window X. Instance B is a
    /// fresh `AppLimitPlanner` sharing the SAME scheduler, and arms a rule set
    /// whose windows no longer include X. B's in-memory `lastArmedActivityNames`
    /// is empty, so the ONLY way it can stop X is by reading the scheduler's live
    /// activity set. Asserting X is stopped proves self-healing discovery.
    func testFreshInstanceStopsOrphanWindowFromLiveActivitySet() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let windowX = AppLimitWindow(startMinute: 0, endMinute: 720, repeats: true, timezone: nil)
        let windowY = AppLimitWindow(startMinute: 720, endMinute: 1439, repeats: true, timezone: nil)

        // Instance A arms window X.
        let plannerA = AppLimitPlanner(scheduler: spy, now: { now })
        _ = plannerA.arm(rules: [rule(window: windowX, bundleID: "com.a")])
        XCTAssertTrue(
            spy.monitoredActivities().map(\.rawValue).contains(expectedWindowActivityName(windowX)),
            "precondition: instance A left window X armed in the live set"
        )

        // Instance B is brand new (empty in-memory state) and shares the spy. It
        // arms a rule set that NO LONGER contains window X.
        let plannerB = AppLimitPlanner(scheduler: spy, now: { now })
        _ = plannerB.arm(rules: [rule(window: windowY, bundleID: "com.b")])

        // Window X's activity must have been stopped, discovered purely from the
        // live activity set — not from any in-memory tracking B never had.
        let stops = spy.stopped.compactMap { $0 }.map { Set($0.map(\.rawValue)) }
        let lastStop = stops.last ?? []
        XCTAssertTrue(
            lastStop.contains(expectedWindowActivityName(windowX)),
            "fresh instance B must stop orphaned window X discovered from the live set"
        )
        // And X is no longer monitored after B's repack.
        XCTAssertFalse(
            spy.monitoredActivities().map(\.rawValue).contains(expectedWindowActivityName(windowX)),
            "orphan window X must be gone from the live set after self-healing"
        )
    }

    // MARK: - Arm failure: a window that throws → .partiallyArmed, not swallowed

    func testWindowArmFailureReturnsPartiallyArmed() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        let morning = AppLimitWindow(startMinute: 0, endMinute: 720, repeats: true, timezone: nil)
        let evening = AppLimitWindow(startMinute: 720, endMinute: 1439, repeats: true, timezone: nil)

        // Make exactly the evening window's startMonitoring throw at runtime.
        spy.failingActivityNames = [expectedWindowActivityName(evening)]

        let result = planner.arm(rules: [
            rule(window: morning, bundleID: "com.a"),
            rule(window: evening, bundleID: "com.b"),
        ])

        // 2 windows passed validation; one threw at arm time → partiallyArmed(1, 1).
        guard case let .partiallyArmed(armedCount, failedCount) = result else {
            return XCTFail("expected .partiallyArmed when a window throws, got \(result)")
        }
        XCTAssertEqual(armedCount, 1, "only the morning window armed")
        XCTAssertEqual(failedCount, 1, "the evening window's throw was surfaced, not swallowed")

        // The surviving window did arm; the failing one is not in the armed log.
        let armedNames = Set(spy.armed.map(\.name.rawValue))
        XCTAssertTrue(armedNames.contains(expectedWindowActivityName(morning)))
        XCTAssertFalse(armedNames.contains(expectedWindowActivityName(evening)))
    }

    // MARK: - Timezone normalization: nil and invalid id collapse to one window

    /// `schedule(for:)` falls back to device-local for both a nil tz and an
    /// invalid IANA id, so they must hash to the SAME window activity (one slot,
    /// not two doing the same thing). See `windowKey` normalization.
    func testNilAndInvalidTimezoneProduceSameWindowActivity() {
        let spy = PlannerSchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let planner = AppLimitPlanner(scheduler: spy, now: { now })

        let nilTz = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil)
        let invalidTz = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: "Not/AZone")

        XCTAssertEqual(
            AppLimitPlanner.activityName(for: nilTz),
            AppLimitPlanner.activityName(for: invalidTz),
            "a nil tz and an invalid-id tz must resolve to the same window activity"
        )

        // And the planner collapses both rules into ONE slot, not two.
        let result = planner.arm(rules: [
            rule(window: nilTz, bundleID: "com.a"),
            rule(window: invalidTz, bundleID: "com.b"),
        ])
        guard case let .armed(activityCount, eventCount) = result else {
            return XCTFail("expected .armed, got \(result)")
        }
        XCTAssertEqual(activityCount, 1, "nil tz + invalid-id tz collapse to one window")
        XCTAssertEqual(eventCount, 2)
    }
}

private final class PlannerEpochLock: DeviceEpochStoreLocking, @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
