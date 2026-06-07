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

    private func makeApplier(store: ActiveLockStore, spy: LockSchedulerSpy) -> ReflectionLockApplier {
        ReflectionLockApplier(store: store, scheduler: LockScheduler(activityScheduler: spy))
    }

    // MARK: - apply

    func test_apply_active_pending_creates_record_and_schedules() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        let applier = makeApplier(store: store, spy: spy)
        let rid = UUID()
        let childID = UUID()

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
        let applier = makeApplier(store: store, spy: spy)
        let rid = UUID()
        let childID = UUID()

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

    // MARK: - schedule failure recorded, not swallowed

    func test_schedule_failure_is_recorded_not_swallowed() async {
        let store = ActiveLockStore()
        let spy = LockSchedulerSpy()
        spy.errorToThrow = NSError(domain: "t", code: 1)
        let applier = makeApplier(store: store, spy: spy)

        await applier.reconcile(snapshot: pendingSnapshot(rid: UUID()), childID: UUID())

        let recorded = UserDefaults(suiteName: "group.com.evlin.ios")?
            .string(forKey: "evlin.reflectionLockScheduleFailure")
        XCTAssertNotNil(recorded, "a failed schedule must be surfaced, not swallowed")
    }
}
