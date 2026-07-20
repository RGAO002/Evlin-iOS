import DeviceActivity
import FamilyControls
import XCTest
@testable import Evlin_iOS

final class AppLimitPauseResumeTests: XCTestCase {
    private final class ArmIDSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID]

        init(_ values: [UUID]) {
            self.values = values
        }

        func next() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            return values.removeFirst()
        }
    }

    private final class SchedulerSpy: DeviceActivityScheduling {
        private(set) var active = Set<DeviceActivityName>()
        private(set) var starts: [DeviceActivityName] = []
        private(set) var stops: [[DeviceActivityName]] = []

        func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
            active.insert(name)
            starts.append(name)
        }

        func startMonitoring(
            _ activity: DeviceActivityName,
            during schedule: DeviceActivitySchedule,
            events: [DeviceActivityEvent.Name: DeviceActivityEvent]
        ) throws {
            active.insert(activity)
            starts.append(activity)
        }

        func stopMonitoring(_ activities: [DeviceActivityName]) {
            stops.append(activities)
            active.subtract(activities)
        }

        func stopMonitoring() {
            stops.append(Array(active))
            active.removeAll()
        }

        func monitoredActivities() -> [DeviceActivityName] {
            Array(active)
        }
    }

    func testPauseThenResumeCreatesOneSuccessorWithoutChargingPausedRawUsage() throws {
        let owner = UUID()
        let rule = makeRule()
        let firstArm = UUID()
        let successorArm = UUID()
        let store = makeStore(owner: owner)
        let scheduler = SchedulerSpy()
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let armIDs = ArmIDSequence([firstArm])
        let planner = AppLimitPlanner(
            scheduler: scheduler,
            now: { now },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { armIDs.next() }
        )
        try seed(rule, owner: owner, store: store)

        XCTAssertEqual(planner.arm(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        let originalName = AppLimitPlanner.v2ActivityName(armID: firstArm)

        XCTAssertEqual(planner.pauseActiveArms(), 1)
        XCTAssertTrue(scheduler.stops.isEmpty, "pausing must preserve the live monitor")
        try store.transaction(source: .wakeRecovery, expectedOwner: owner) { state in
            var slot = try XCTUnwrap(state.slots[rule.id])
            var provenance = try XCTUnwrap(slot.armProvenance)
            XCTAssertNotNil(provenance.pausedAt)
            provenance.lastRawThresholdMinutes = 10
            provenance.ignoredWhilePausedMinutes = 20
            slot.armProvenance = provenance
            state.slots[rule.id] = slot
        }

        // The app can be terminated while the gate is closed. A fresh planner
        // must create the same conservative successor when the next poll opens it.
        let reopened = AppLimitPlanner(
            scheduler: scheduler,
            now: { now.addingTimeInterval(60) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { successorArm }
        )
        XCTAssertEqual(reopened.resumePausedArms(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        let successor = try XCTUnwrap(store.read().slots[rule.id]?.armProvenance)
        XCTAssertEqual(successor.armID, successorArm)
        XCTAssertEqual(successor.baseAcceptedMinutes, 10)
        XCTAssertEqual(successor.lastRawThresholdMinutes, 0)
        XCTAssertEqual(successor.ignoredWhilePausedMinutes, 0)
        XCTAssertEqual(successor.predecessorIgnoredWhilePausedMinutes, 20)
        XCTAssertNil(successor.pausedAt)
        XCTAssertEqual(scheduler.stops, [[DeviceActivityName(originalName)]])
        XCTAssertEqual(scheduler.starts.count, 2)

        let repeatedOpen = AppLimitPlanner(
            scheduler: scheduler,
            now: { now.addingTimeInterval(120) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { UUID() }
        )
        XCTAssertEqual(repeatedOpen.resumePausedArms(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(scheduler.starts.count, 2, "restart/repeated open must reuse the successor")
    }

    func testClearWhilePausedCannotResurrectThePredecessor() throws {
        let owner = UUID()
        let rule = makeRule()
        let store = makeStore(owner: owner)
        let scheduler = SchedulerSpy()
        let firstArm = UUID()
        let planner = AppLimitPlanner(
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_721_174_400) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { firstArm }
        )
        try seed(rule, owner: owner, store: store)
        XCTAssertEqual(planner.arm(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(planner.pauseActiveArms(), 1)

        let coordinator = AppLimitCommandCoordinator(
            store: store,
            expectedOwnerProvider: { owner }
        )
        let clear = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: rule.id,
            orderingToken: 2,
            kind: .clear,
            payloadDigest: "clear-2",
            receivedAt: Date(timeIntervalSince1970: 1_721_174_460),
            source: .poll,
            rule: nil
        )
        XCTAssertEqual(try coordinator.ingest(clear), .acceptedNeedsOwner)

        XCTAssertEqual(planner.resumePausedArms(rules: []), .armed(activityCount: 0, eventCount: 0))
        XCTAssertEqual(scheduler.starts.count, 1)
        XCTAssertTrue(scheduler.active.isEmpty)
    }

    func testRestartDuringReplacementStartsThePersistedSuccessorExactlyOnce() throws {
        let owner = UUID()
        let rule = makeRule()
        let firstArm = UUID()
        let successorArm = UUID()
        let store = makeStore(owner: owner)
        let scheduler = SchedulerSpy()
        let planner = AppLimitPlanner(
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_721_174_400) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { firstArm }
        )
        try seed(rule, owner: owner, store: store)
        XCTAssertEqual(planner.arm(rules: [rule]), .armed(activityCount: 1, eventCount: 1))

        try store.transaction(source: .wakeRecovery, expectedOwner: owner) { state in
            var slot = try XCTUnwrap(state.slots[rule.id])
            var successor = try XCTUnwrap(slot.armProvenance)
            successor.armID = successorArm
            successor.activityName = AppLimitPlanner.v2ActivityName(armID: successorArm)
            successor.pausedAt = nil
            successor.monitorStartPending = true
            slot.armProvenance = successor
            state.slots[rule.id] = slot
        }

        let restarted = AppLimitPlanner(
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_721_174_460) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { UUID() }
        )
        XCTAssertTrue(restarted.hasPausedArms())
        XCTAssertEqual(restarted.resumePausedArms(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(scheduler.starts.count, 2)
        XCTAssertEqual(
            Set(scheduler.active.map(\.rawValue)),
            [AppLimitPlanner.v2ActivityName(armID: successorArm)]
        )
        XCTAssertFalse(try XCTUnwrap(store.read().slots[rule.id]?.armProvenance).monitorStartPending ?? true)
    }

    func testResumeAcrossUsageDateLetsEpochReplacementCreateOneNewDayArm() throws {
        let owner = UUID()
        let rule = makeRule()
        let firstArm = UUID()
        let nextDayArm = UUID()
        let store = makeStore(owner: owner)
        let scheduler = SchedulerSpy()
        let firstDay = Date(timeIntervalSince1970: 1_721_174_400)
        let initial = AppLimitPlanner(
            scheduler: scheduler,
            now: { firstDay },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { firstArm }
        )
        try seed(rule, owner: owner, store: store)
        XCTAssertEqual(initial.arm(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        XCTAssertEqual(initial.pauseActiveArms(), 1)

        let nextDay = AppLimitPlanner(
            scheduler: scheduler,
            now: { firstDay.addingTimeInterval(86_400) },
            epochStore: store,
            ownerProvider: { owner },
            armIDProvider: { nextDayArm }
        )
        XCTAssertEqual(nextDay.resumePausedArms(rules: [rule]), .armed(activityCount: 1, eventCount: 1))
        let provenance = try XCTUnwrap(store.read().slots[rule.id]?.armProvenance)
        XCTAssertEqual(provenance.armID, nextDayArm)
        XCTAssertEqual(provenance.usageDate, "2024-07-18")
        XCTAssertEqual(scheduler.starts.count, 2)
    }

    private func makeRule() -> AppLimitRule {
        AppLimitRule(
            id: UUID(),
            appTokens: [],
            bundleID: "com.example.pause-resume",
            displayName: "Pause Resume",
            budgetMinutes: 60,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "UTC"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
    }

    private func makeStore(owner: UUID) -> AppLimitEpochStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-limit-pause-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppLimitEpochStore(
            fileURL: directory.appendingPathComponent("epoch.json"),
            lock: ActiveLockPersistenceLock.shared,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
    }

    private func seed(
        _ rule: AppLimitRule,
        owner: UUID,
        store: AppLimitEpochStore
    ) throws {
        let coordinator = AppLimitCommandCoordinator(
            store: store,
            expectedOwnerProvider: { owner }
        )
        let envelope = AppLimitCommandEnvelope(
            commandID: UUID(),
            ruleID: rule.id,
            orderingToken: 1,
            kind: .set,
            payloadDigest: "set-1",
            receivedAt: Date(timeIntervalSince1970: 1_721_174_400),
            source: .poll,
            rule: rule
        )
        XCTAssertEqual(try coordinator.ingest(envelope), .acceptedNeedsOwner)
    }
}
