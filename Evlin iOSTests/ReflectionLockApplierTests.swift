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
        // The backlog is persisted, so without this one test's stranded stop is
        // retried inside the next one and shows up as a phantom extra `stop`.
        groupDefaults?.removeObject(forKey: pendingStopsKey)
        ScreenTimeEventLog.clear()
    }

    private let pendingStopsKey = "evlin.reflectionLockPendingStops"

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
    /// window is inside the CANCEL.
    ///
    /// `afterLocalMutation` runs immediately after `addShield`, so counting it
    /// proves whether the incoming shield was ever created — the end state cannot,
    /// because the later post-schedule guard tears one down again.
    func test_identitySwitchDuringSwapCancelNeverAddsTheIncomingShield() async {
        let store = ActiveLockStore()
        let spy = BlockingLockSchedulerSpy()
        spy.blocksOnStop = true
        let oldID = UUID()
        let identity = MutableIdentityBox(oldID)
        let mutations = MutationCounter()
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { identity.value },
            afterLocalMutation: { mutations.bump() }
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

        XCTAssertEqual(
            mutations.count,
            0,
            "the incoming shield must never be created for a child who has left"
        )
        XCTAssertTrue(spy.startedNames.isEmpty, "and its expiry must not be scheduled")
        XCTAssertNil(
            groupDefaults?.data(forKey: stickyKey),
            "the departed child's sticky must be cleared — it carries no owner, so "
                + "leaving it makes the NEXT child inherit their reflection RID"
        )
    }

    /// End to end, because the previous version wrote the queue key by hand and
    /// would still have passed with `enqueuePendingStop` deleted:
    /// gateway refuses -> the refusal enqueues -> the next reconcile stops it ->
    /// the queue empties.
    func test_refusedStopIsEnqueuedThenRetriedOnTheNextPass() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let childID = UUID()
        let applier = makeApplier(store: store, spy: spy, childID: childID)
        let rid = UUID()
        let name = ReflectionLockRecordFactory
            .make(rid: rid, expiresAt: Date(), childID: childID).deviceActivityName

        // Apply first, so there is something for the release to tear down.
        await applier.reconcile(snapshot: pendingSnapshot(rid: rid), childID: childID)
        let startedBefore = spy.stopped.count

        // Pass 1: every gateway slot held, so the release's stop is refused and
        // never reaches the scheduler.
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
            < MeteringDeviceActivityGateway.maxInFlight, spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        await applier.reconcile(
            snapshot: resolvedSnapshot(rid: rid, resolution: .approved),
            childID: childID
        )
        XCTAssertEqual(
            spy.stopped.count,
            startedBefore,
            "pass 1's stop must have been refused, not delivered"
        )
        XCTAssertEqual(
            groupDefaults?.stringArray(forKey: pendingStopsKey),
            [name],
            "a refused stop must enqueue itself; a log line is not a retry"
        )

        // Pass 2: slots free again.
        for _ in holders { gate.signal() }
        for h in holders { await h.value }
        await applier.reconcile(
            snapshot: resolvedSnapshot(rid: rid, resolution: .approved),
            childID: childID
        )
        // The drain is deliberately NOT awaited by `reconcile` any more, so wait
        // for the background task rather than assuming it finished.
        var drainSpins = 0
        while groupDefaults?.stringArray(forKey: pendingStopsKey) != nil,
              drainSpins < 20_000 {
            await Task.yield()
            drainSpins += 1
        }
        XCTAssertTrue(
            spy.stopped.contains { ($0 ?? []).contains(where: { $0.rawValue == name }) },
            "the queued stop must actually be retried"
        )
        XCTAssertNil(
            groupDefaults?.stringArray(forKey: pendingStopsKey),
            "and a stop that lands must leave the queue"
        )
    }

    /// The drain must not be on the poller's await chain at all.
    ///
    /// BigKidStatePoller awaits `reconcile` and then replays metering callbacks,
    /// applies the UI snapshot and reconciles the pool. Awaiting the drain — even
    /// after committing the current reflection work — meant one historical stop
    /// that entered the daemon and never returned froze all of that and left
    /// `isFetchInFlight` set for good. Responsive UI made it invisible.
    ///
    /// Asserted on elapsed time rather than on "did it hang", so the difference is
    /// deterministic: with the drain awaited this call cannot return until the
    /// parked stop gives up, which is `blockSeconds` away.
    func test_wedgedBacklogStopDoesNotBlockReconcileFromReturning() async {
        let blockSeconds: TimeInterval = 20
        let store = ActiveLockStore()
        let spy = BlockingLockSchedulerSpy()
        let childID = UUID()
        let stranded = "evlin.shield.stranded.forever"
        spy.blocksOnlyStopNamed = stranded
        spy.blocksOnStart = false
        spy.blockSeconds = blockSeconds
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { childID }
        )
        groupDefaults?.set([stranded], forKey: pendingStopsKey)

        let started = Date()
        await applier.reconcile(snapshot: pendingSnapshot(rid: UUID()), childID: childID)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            blockSeconds / 4,
            "reconcile waited on the backlog: a stop parked in the daemon must not "
                + "hold up metering replay, the UI snapshot or the pool reconcile"
        )
        // Prove the wedge was real rather than absent.
        var spins = 0
        while !spy.stoppedNames.contains(stranded), spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(
            spy.stoppedNames.contains(stranded),
            "the backlog drain must actually have been attempted"
        )
        XCTAssertEqual(
            groupDefaults?.stringArray(forKey: pendingStopsKey),
            [stranded],
            "a stop still parked in the daemon stays queued — only success dequeues"
        )
        spy.releaseStart()
    }

    /// Observation 2 from review: a drain whose first XPC never returns never
    /// finishes, which is an acceptable bounded degradation ONLY if it is visible.
    /// Otherwise the sole symptom is orphan activities accumulating over days.
    func test_stuckDrainIsReportedWithQueueLength() async {
        // Via the recorder's own test seam, so this asserts what the applier
        // emits rather than what the rate limiter happens to let through.
        let sink = RecordedEvents()
        MeteringFlightRecorder.testSink = { sink.append($0) }
        defer { MeteringFlightRecorder.testSink = nil }
        let store = ActiveLockStore()
        let spy = BlockingLockSchedulerSpy()
        let childID = UUID()
        let stranded = "evlin.shield.stranded.visible"
        spy.blocksOnlyStopNamed = stranded
        spy.blocksOnStart = false
        spy.blockSeconds = 20
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { childID }
        )
        groupDefaults?.set([stranded], forKey: pendingStopsKey)

        await applier.reconcile(snapshot: pendingSnapshot(rid: UUID()), childID: childID)
        var spins = 0
        while !spy.stoppedNames.contains(stranded), spins < 20_000 {
            await Task.yield()
            spins += 1
        }

        // `site` and `detail` both land in `app`; `verdict` lands in `reason`.
        let recorded = sink.all
        let drainEvents = recorded.filter {
            ($0.app ?? "").contains("reflection.pendingStops.drain")
        }
        XCTAssertTrue(
            drainEvents.contains { ($0.app ?? "").contains("queued=1") && $0.reason == "started" },
            "the drain must record what it set out to clear, so a queue that never "
                + "empties is readable rather than invisible. Saw: "
                + "\(recorded.map { "\($0.reason)|\($0.app ?? "")" })"
        )
        spy.releaseStart()
    }

    /// Pins the stall reporter's throttle at the five boundaries review specified.
    /// The clock is the `now` `reconcile` already takes, so nothing waits.
    ///
    /// Without a throttle this fires on EVERY poll — about six a minute against a
    /// 300-slot failure ring, which wipes every other piece of failure evidence
    /// inside an hour. The reporter would destroy what it was added to protect.
    func test_stalledDrainIsReportedAtMostOncePerThresholdWindow() async {
        let sink = RecordedEvents()
        MeteringFlightRecorder.testSink = { sink.append($0) }
        defer { MeteringFlightRecorder.testSink = nil }

        let store = ActiveLockStore()
        let spy = BlockingLockSchedulerSpy()
        let childID = UUID()
        let stranded = "evlin.shield.stranded.stalled"
        spy.blocksOnlyStopNamed = stranded
        spy.blocksOnStart = false
        spy.blockSeconds = 60
        let applier = ReflectionLockApplier(
            store: store,
            scheduler: LockScheduler(activityScheduler: spy),
            currentChildID: { childID }
        )
        groupDefaults?.set([stranded], forKey: pendingStopsKey)

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // Pass 1 starts the drain, which parks in the daemon.
        await applier.reconcile(snapshot: pendingSnapshot(rid: UUID()), childID: childID, now: t0)
        var spins = 0
        while !spy.stoppedNames.contains(stranded), spins < 20_000 {
            await Task.yield()
            spins += 1
        }

        func stalledCount() -> Int {
            sink.all.filter {
                ($0.app ?? "").contains("reflection.pendingStops.drain")
                    && $0.reason == "stalled"
            }.count
        }

        await applier.reconcile(
            snapshot: pendingSnapshot(rid: UUID()), childID: childID,
            now: t0.addingTimeInterval(299)
        )
        XCTAssertEqual(stalledCount(), 0, "299s is inside the window — nothing yet")

        await applier.reconcile(
            snapshot: pendingSnapshot(rid: UUID()), childID: childID,
            now: t0.addingTimeInterval(300)
        )
        XCTAssertEqual(stalledCount(), 1, "300s reports exactly once")

        await applier.reconcile(
            snapshot: pendingSnapshot(rid: UUID()), childID: childID,
            now: t0.addingTimeInterval(301)
        )
        XCTAssertEqual(stalledCount(), 1, "301s must not report again")

        await applier.reconcile(
            snapshot: pendingSnapshot(rid: UUID()), childID: childID,
            now: t0.addingTimeInterval(600)
        )
        XCTAssertEqual(stalledCount(), 2, "a second window allows a second report")

        // The queue length has to survive into the report, or the record says a
        // drain is stuck without saying how much is stuck behind it.
        XCTAssertTrue(
            sink.all.contains { ($0.app ?? "").contains("queued=1") && $0.reason == "stalled" },
            "the stall report must carry the queue length"
        )
        spy.releaseStart()
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
        guard blocksOnStart else { return }
        _ = release.wait(timeout: .now() + blockSeconds)
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
    /// Block only this activity, so a test can wedge the backlog drain without
    /// also wedging the current pass's own cancel.
    var blocksOnlyStopNamed: String?
    var blockSeconds: TimeInterval = 10
    /// Whether `startMonitoring` parks. On for the `.apply` identity window, off
    /// when a test only wants to wedge a stop — otherwise the start's own block
    /// dominates whatever the test is measuring.
    var blocksOnStart = true

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        lock.lock(); _stoppedNames.append(contentsOf: activities.map(\.rawValue)); lock.unlock()
        if let target = blocksOnlyStopNamed {
            guard activities.contains(where: { $0.rawValue == target }) else { return }
            _ = release.wait(timeout: .now() + blockSeconds)
            return
        }
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

/// Counts `afterLocalMutation`, which the applier calls immediately after
/// `addShield` — so a count of zero proves no shield was created.
private final class MutationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func bump() { lock.lock(); stored += 1; lock.unlock() }
}

/// Collects flight-recorder events emitted during a test.
private final class RecordedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ScreenTimeEvent] = []
    var all: [ScreenTimeEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ e: ScreenTimeEvent) { lock.lock(); stored.append(e); lock.unlock() }
}
