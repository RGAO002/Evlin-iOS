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
        var errorToThrow: Error?

        func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
            if let e = errorToThrow { throw e }
            startedNoEvents.append((name, schedule))
            calls.append(.start(name.rawValue))
        }

        func startMonitoring(
            _ activity: DeviceActivityName,
            during schedule: DeviceActivitySchedule,
            events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        ) throws {
            if let e = errorToThrow { throw e }
            armed.append(Armed(name: activity, schedule: schedule, events: events))
            calls.append(.startEvents(activity.rawValue))
        }

        func stopMonitoring(_ activities: [DeviceActivityName]) {
            stopped.append(activities)
            calls.append(.stop(activities.map(\.rawValue).sorted()))
        }

        func stopMonitoring() {
            stopped.append(nil)
            calls.append(.stopAll)
        }
    }

    // MARK: - Fixtures

    private let dailyWindow = AppLimitWindow(startMinute: 0, endMinute: 1439, repeats: true, timezone: nil)

    private func rule(
        budget: Int = 30,
        window: AppLimitWindow? = nil,
        effectiveFrom: Date = Date(timeIntervalSince1970: 0),
        expiresAt: Date? = nil,
        bundleID: String = "com.example.app"
    ) -> AppLimitRule {
        AppLimitRule(
            id: UUID(),
            appTokens: [],
            bundleID: bundleID,
            displayName: bundleID,
            budgetMinutes: budget,
            window: window ?? dailyWindow,
            effectiveFrom: effectiveFrom,
            expiresAt: expiresAt
        )
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
        XCTAssertEqual(armed.events.count, 5)

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
        XCTAssertEqual(morningActivity.events.count, 2)
        let eveningActivity = try XCTUnwrap(spy.armed.first { $0.name.rawValue == expectedWindowActivityName(evening) })
        XCTAssertEqual(eveningActivity.events.count, 1)
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
}
