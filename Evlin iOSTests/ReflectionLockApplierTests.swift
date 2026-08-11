import DeviceActivity
import XCTest
@testable import Evlin_iOS

/// Tests for the impure ReflectionLockApplier glue: it runs the pure reconciler,
/// applies/removes the dedicated reflection ShieldRecord, schedules its DAM
/// auto-removal, and records (does NOT swallow) a schedule failure.
@MainActor
final class ReflectionLockApplierTests: XCTestCase {
    private let stickyKey = "evlin.reflectionLockSticky"
    private let scheduleFailureKey = "evlin.reflectionLockScheduleFailure"
    private var groupDefaults: UserDefaults? { UserDefaults(suiteName: "group.com.evlin.ios") }

    override func setUp() async throws {
        // Fresh sticky + failure state so tests don't bleed into each other.
        groupDefaults?.removeObject(forKey: stickyKey)
        groupDefaults?.removeObject(forKey: scheduleFailureKey)
        groupDefaults?.removeObject(forKey: "evlin.shieldRecords")
        groupDefaults?.removeObject(forKey: "evlin.blockRecords")
    }

    // MARK: - Fixtures

    /// Build a snapshot carrying an active pending reflection with the given rid
    /// and a server cap 2h out (well inside the lease so the reconciler applies).
    private func pendingSnapshot(rid: UUID, now: Date = Date()) -> ChildStateResponse {
        let request = ReflectionRequest(
            id: rid,
            reason: "stayed up past bedtime",
            displayReason: nil,
            topicLabel: nil,
            videoId: "v",
            videoTitle: "t",
            writingPrompt: "p",
            quiz: [],
            stepsCompleted: [],
            quizScore: nil,
            essayText: nil,
            status: .pending,
            parentNote: nil,
            submittedAt: nil,
            approvedAt: nil,
            parentRedoNote: nil,
            lastNudgeAt: nil,
            reflectionLockCapExpiresAt: now.addingTimeInterval(2 * 60 * 60),
            lockAppliedAt: nil
        )
        return ChildStateResponse(
            childName: "Liam", minutesLeft: 0, minutesMax: 120, tasks: [],
            reflectionRequest: request, notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false, screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: nil)
    }

    private func resolvedSnapshot(rid: UUID, resolution: ResolvedReflection.Resolution) -> ChildStateResponse {
        ChildStateResponse(
            childName: "Liam", minutesLeft: 0, minutesMax: 120, tasks: [],
            reflectionRequest: nil, notifyParentCooldownEndsAt: nil,
            dailyCompleteAcknowledged: false, screenTimeFinishedAcknowledged: false,
            lastResolvedReflection: ResolvedReflection(rid: rid, resolution: resolution))
    }


    // MARK: - Identity switching DURING the off-main scheduler suspension

    /// Making the scheduler `async` created a window the synchronous code did not
    /// have: the device can change hands while a schedule is in flight. The test
    /// above covers the `afterLocalMutation` window; this covers the one the
    /// off-main move added, where the work has already reached Apple and has to be
    /// undone rather than merely skipped.
    func test_identitySwitchDuringScheduleUndoesTheSchedule() async {
        let store = ActiveLockStore()
        let spy = BlockingLockSchedulerSpy()
        let oldID = UUID()
        let identity = MutableIdentityBox(oldID)
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { identity.value }
        )
        let rid = UUID()
        let reconcile = Task {
            await applier.reconcile(snapshot: pendingSnapshot(rid: rid), childID: oldID)
        }
        // Hold the applier inside `startMonitoring`, hand the device to another
        // child, then let it finish.
        // Poll rather than block: the applier is `@MainActor`, so waiting on a
        // semaphore here would starve the very task we are waiting for.
        var spins = 0
        while spy.startedNames.isEmpty, spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertFalse(spy.startedNames.isEmpty, "the schedule was never attempted")
        identity.value = UUID()
        spy.releaseStart()
        await reconcile.value

        let armed = spy.startedNames.first
        XCTAssertNotNil(armed)
        XCTAssertTrue(
            spy.stoppedNames.contains(armed ?? ""),
            "a schedule that landed for a child who has since left must be undone, "
                + "or it re-creates the old family's activity after cleanup ran"
        )
        let shields = await store.allCurrent().shields
        XCTAssertFalse(
            shields.contains { $0.recordKey == "all:reflection:\(rid.uuidString)" },
            "the old family's reflection record must not survive the switch"
        )
    }

    /// A refused cancel is not a cancel. With every gateway slot held, `perform`
    /// returns nil without touching the scheduler at all, and the caller used to
    /// read that as done — leaving a live activity and nothing to retry from.
    func test_refusedCancelReportsFalseAndNeverTouchesTheScheduler() async {
        let spy = LockSchedulerSpy()
        let scheduler = LockScheduler(activityScheduler: spy)

        let gate = DispatchSemaphore(value: 0)
        var holders: [Task<Void, Never>] = []
        for _ in 0..<MeteringDeviceActivityGateway.maxInFlight {
            holders.append(Task {
                _ = await MeteringDeviceActivityGateway.perform("test.hold") {
                    _ = gate.wait(timeout: .now() + 10)
                    return true
                }
            })
        }
        var spins = 0
        while MeteringDeviceActivityGateway.inFlightCount()
            < MeteringDeviceActivityGateway.maxInFlight, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        let cancelled = await scheduler.cancel(deviceActivityName: "evlin.shield.refused")

        for _ in holders { gate.signal() }
        for h in holders { await h.value }

        XCTAssertFalse(
            cancelled,
            "a cancel the gateway never ran must report false, not silently pass"
        )
        XCTAssertEqual(spy.stopped.count, 0, "the scheduler must not have been touched")
    }

    /// `.swap` cancels the outgoing lock and then adds the incoming one, so its
    /// window is inside the CANCEL. The production guard is in place; this proves
    /// it, rather than leaving `.swap` covered only by inspection.
    func test_identitySwitchDuringSwapCancelDoesNotShieldForTheOldChild() async {
        let store = ActiveLockStore()
        let spy = BlockingLockSchedulerSpy()
        spy.blocksOnStop = true
        let oldID = UUID()
        let identity = MutableIdentityBox(oldID)
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { identity.value }
        )
        let outgoing = UUID()
        let incoming = UUID()
        groupDefaults?.set(
            try? JSONEncoder().encode(ReflectionLockSticky(
                heldRID: outgoing,
                capExpiresAt: Date().addingTimeInterval(120)
            )),
            forKey: stickyKey
        )

        let reconcile = Task {
            await applier.reconcile(snapshot: pendingSnapshot(rid: incoming), childID: oldID)
        }
        var spins = 0
        while spy.stoppedNames.isEmpty, spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertFalse(spy.stoppedNames.isEmpty, "the swap never reached its cancel")
        identity.value = UUID()
        spy.releaseStart()
        await reconcile.value

        let shields = await store.allCurrent().shields
        XCTAssertFalse(
            shields.contains { $0.recordKey == "all:reflection:\(incoming.uuidString)" },
            "a device that changed hands mid-swap must not receive the previous "
                + "child's all-app lock"
        )
        XCTAssertTrue(
            spy.startedNames.isEmpty,
            "and it must not schedule that lock's expiry either"
        )
        // Pins the PRE-shield guard specifically. Without it the swap adds the
        // shield and the later post-schedule guard tears it down again, so the end
        // state alone cannot tell the two apart — but that later path also clears
        // the sticky, whereas returning before the shield leaves it untouched.
        let stickyAfter: ReflectionLockSticky? = groupDefaults?
            .data(forKey: stickyKey)
            .flatMap { try? JSONDecoder().decode(ReflectionLockSticky.self, from: $0) }
        XCTAssertEqual(
            stickyAfter?.heldRID,
            outgoing,
            "the swap must have returned BEFORE mutating anything, leaving the "
                + "outgoing lock's sticky exactly as it was"
        )
    }

    /// A refused stop has to be retried by a machine, not just written down. Left
    /// as a log line, the state machine called the release finished while Apple
    /// still held the activity — and unclaimed activities are invisible to the
    /// planner's 20-slot quota check, so they pile up until a real arm fails.
    func test_refusedStopIsRetriedOnTheNextReconcile() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let childID = UUID()
        let applier = makeApplier(store: store, spy: spy, childID: childID)
        let rid = UUID()
        let stranded = ReflectionLockRecordFactory
            .make(rid: rid, expiresAt: Date(), childID: childID).deviceActivityName
        // Stand in for "the gateway refused this stop on an earlier pass".
        groupDefaults?.set([stranded], forKey: "evlin.reflectionLockPendingStops")

        await applier.reconcile(snapshot: resolvedSnapshot(rid: rid, resolution: .approved),
                                childID: childID)

        XCTAssertTrue(
            spy.stopped.contains { ($0 ?? []).contains(where: { $0.rawValue == stranded }) },
            "the queued stop must be retried, not left on the device forever"
        )
        XCTAssertNil(
            groupDefaults?.stringArray(forKey: "evlin.reflectionLockPendingStops"),
            "a stop that lands must leave the queue"
        )
    }

    private func makeApplier(
        store: ActiveLockStore,
        spy: LockSchedulerSpy,
        childID: UUID
    ) -> ReflectionLockApplier {
        ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { childID }
        )
    }

    // MARK: - apply

    /// C-3 Task 1: the reflection record must REQUEST web access at the record
    /// level (`webOpen == true`) instead of any view nil-ing shield fields.
    func test_reflection_factory_requests_web_open() {
        let record = ReflectionLockRecordFactory.make(
            rid: UUID(), expiresAt: Date(timeIntervalSince1970: 2_000), childID: UUID()
        )
        XCTAssertTrue(record.webOpen)
        XCTAssertEqual(record.tier, .allApps)
    }

    func test_reflection_record_locks_apps_without_web_domain_category() {
        let record = ReflectionLockRecordFactory.make(
            rid: UUID(),
            expiresAt: Date().addingTimeInterval(60),
            childID: UUID()
        )

        XCTAssertEqual(record.tier.rawValue, "allApps")
        XCTAssertTrue(record.appliesToAll)
        XCTAssertTrue(record.webDomainTokens.isEmpty)
    }

    func test_apply_active_pending_creates_record_and_schedules() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let rid = UUID()
        let childID = UUID()
        let applier = makeApplier(store: store, spy: spy, childID: childID)

        await applier.reconcile(snapshot: pendingSnapshot(rid: rid), childID: childID)

        let shields = await store.allCurrent().shields
        XCTAssertTrue(shields.contains(where: { $0.recordKey == "all:reflection:\(rid.uuidString)" }),
                      "expected a reflection record keyed by rid")
        XCTAssertEqual(spy.started.count, 1)
    }

    // MARK: - release

    func test_release_on_resolved_removes_record_and_cancels() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let rid = UUID()
        let childID = UUID()
        let applier = makeApplier(store: store, spy: spy, childID: childID)

        // First apply so a record + sticky exist.
        await applier.reconcile(snapshot: pendingSnapshot(rid: rid), childID: childID)
        XCTAssertEqual(spy.started.count, 1)

        // Then resolve (cancelled) with no active reflection → release.
        await applier.reconcile(snapshot: resolvedSnapshot(rid: rid, resolution: .cancelled),
                                childID: childID)

        let shields = await store.allCurrent().shields
        XCTAssertFalse(shields.contains(where: { $0.recordKey == "all:reflection:\(rid.uuidString)" }),
                       "record should be gone after release")
        XCTAssertEqual(spy.stopped.count, 1)
    }

    func test_release_preserves_existing_blocks() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let rid = UUID()
        let childID = UUID()
        let applier = makeApplier(store: store, spy: spy, childID: childID)
        let block = BlockRecord(
            bundleID: "com.burbn.instagram",
            displayName: "Instagram",
            blockedAt: Date(),
            lastCommandID: UUID(),
            originalRequest: "block Instagram",
            targetChildID: childID
        )

        _ = await store.addBlock(block)
        await applier.reconcile(snapshot: pendingSnapshot(rid: rid), childID: childID)
        await applier.reconcile(snapshot: resolvedSnapshot(rid: rid, resolution: .approved),
                                childID: childID)

        let current = await store.allCurrent()
        XCTAssertFalse(current.shields.contains(where: { $0.recordKey == "all:reflection:\(rid.uuidString)" }),
                       "reflection release must remove only its dedicated all-apps shield")
        XCTAssertTrue(current.blocks.contains(where: { $0.bundleID == "com.burbn.instagram" }),
                      "reflection release must not clear unrelated active blocks")
    }

    // MARK: - schedule failure recorded, not swallowed

    func test_schedule_failure_is_recorded_not_swallowed() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        spy.errorToThrow = NSError(domain: "t", code: 1)
        let childID = UUID()
        let applier = makeApplier(store: store, spy: spy, childID: childID)

        await applier.reconcile(snapshot: pendingSnapshot(rid: UUID()), childID: childID)

        let recorded = UserDefaults(suiteName: "group.com.evlin.ios")?
            .string(forKey: "evlin.reflectionLockScheduleFailure")
        XCTAssertNotNil(recorded, "a failed schedule must be surfaced, not swallowed")
    }

    func test_missingIdentityAfterApplySuspensionRemovesOldFamilyReflectionRecord() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let oldID = UUID()
        var currentID: UUID? = oldID
        var resumeMutation: CheckedContinuation<Void, Never>?
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { currentID },
            afterLocalMutation: {
                await withCheckedContinuation { resumeMutation = $0 }
            }
        )
        let rid = UUID()
        groupDefaults?.set(
            try? JSONEncoder().encode(ReflectionLockSticky(
                heldRID: rid,
                capExpiresAt: Date().addingTimeInterval(120)
            )),
            forKey: stickyKey
        )

        let reconcile = Task {
            await applier.reconcile(snapshot: pendingSnapshot(rid: rid), childID: oldID)
        }
        while resumeMutation == nil { await Task.yield() }
        currentID = nil
        resumeMutation?.resume()
        await reconcile.value

        let shields = await store.allCurrent().shields
        XCTAssertFalse(shields.contains { $0.recordKey == "all:reflection:\(rid.uuidString)" })
        XCTAssertTrue(spy.started.isEmpty)
        XCTAssertNil(groupDefaults?.data(forKey: stickyKey))
    }
}

/// Holds the caller inside `startMonitoring` so a test can change the device's
/// identity while the schedule is suspended. The protocol is synchronous, so this
/// blocks on a semaphore rather than a continuation — safe, because the call
/// already runs on a detached task.
private final class BlockingLockSchedulerSpy: DeviceActivityScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _startedNames: [String] = []
    private var _stoppedNames: [String] = []
    private let release = DispatchSemaphore(value: 0)

    var startedNames: [String] { lock.lock(); defer { lock.unlock() }; return _startedNames }
    var stoppedNames: [String] { lock.lock(); defer { lock.unlock() }; return _stoppedNames }

    func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule) throws {
        lock.lock(); _startedNames.append(name.rawValue); lock.unlock()
        _ = release.wait(timeout: .now() + 10)
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        try startMonitoring(activity, during: schedule)
    }

    /// Set before use to hold the caller inside `stopMonitoring` instead —
    /// `.swap` cancels before it adds its shield, so that is where its window is.
    var blocksOnStop = false

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        lock.lock(); _stoppedNames.append(contentsOf: activities.map(\.rawValue)); lock.unlock()
        guard blocksOnStop else { return }
        _ = release.wait(timeout: .now() + 10)
    }

    func stopMonitoring() {}
    func monitoredActivities() -> [DeviceActivityName] { [] }

    func releaseStart() { release.signal() }
}

/// The device's current child id, mutable across the concurrency boundary.
private final class MutableIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?
    init(_ value: UUID?) { stored = value }
    var value: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
