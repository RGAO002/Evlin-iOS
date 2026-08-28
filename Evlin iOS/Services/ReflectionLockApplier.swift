import Foundation

enum ReflectionLockRecordFactory {
    static func targetKey(childID: UUID) -> String {
        "reflection:\(childID.uuidString.lowercased())"
    }

    static func recordKey(childID: UUID) -> String {
        ShieldRecord.makeRecordKey(tier: .allApps, targetKey: targetKey(childID: childID))
    }

    static func legacyRecordKey(rid: UUID) -> String {
        "all:reflection:\(rid.uuidString)"
    }

    static func legacyMake(rid: UUID, expiresAt: Date, childID: UUID) -> ShieldRecord {
        ShieldRecord(
            recordKey: legacyRecordKey(rid: rid),
            tier: .allApps,
            targetKey: "reflection:\(rid.uuidString)",
            displayName: "Reflection lock",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: true,
            issuedAt: Date(),
            expiresAt: expiresAt,
            originalRequest: "reflection lockdown",
            targetChildID: childID,
            webOpen: true
        )
    }

    static func make(rid: UUID, expiresAt: Date, childID: UUID) -> ShieldRecord {
        let targetKey = targetKey(childID: childID)
        return ShieldRecord(
            recordKey: recordKey(childID: childID),
            tier: .allApps, targetKey: targetKey,
            displayName: "Reflection lock", lastCommandID: UUID(),
            appTokens: [], categoryTokens: [], webDomainTokens: [],
            appliesToAll: true, issuedAt: Date(), expiresAt: expiresAt,
            originalRequest: "reflection lockdown", targetChildID: childID,
            // C-3: request web access at the record level so the embedded
            // reflection video loads; honored by ActiveShieldProjection.
            webOpen: true)
    }
}

/// Impure glue: runs the pure reconciler, performs side effects, persists sticky.
@MainActor
final class ReflectionLockApplier {
    private let store: ActiveLockStore
    private let scheduler: LockScheduler
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let stickyKey = "evlin.reflectionLockSticky"
    private let scheduleFailureKey = "evlin.reflectionLockScheduleFailure"
    /// Activity names whose stop the gateway refused. A diagnostic string is not
    /// a retry: without this the state machine treated a release as finished, the
    /// Apple activity stayed live, and nothing ever tried again. Unclaimed
    /// activities are invisible to the planner's own 20-slot quota check, so they
    /// accumulate silently until a legitimate arm gets `excessiveActivities`.
    private let pendingStopsKey = "evlin.reflectionLockPendingStops"
    /// Cap per pass so a backlog cannot monopolise the gateway's four slots and
    /// starve the enforcement work this same call is here to do.
    private let pendingStopsPerPass = 4
    /// At most one background drain at a time. An instance flag, not a static:
    /// BigKidStatePoller holds this applier for its lifetime, so the instance is
    /// the right scope — and it keeps tests from inheriting each other's state.
    private var pendingStopDrainInFlight = false
    /// When the in-flight drain started. A drain whose first XPC never returns
    /// never ends either — a bounded, acceptable degradation, but only if it is
    /// VISIBLE. Without this the sole symptom is orphan activities quietly
    /// accumulating over days.
    private var pendingStopDrainStartedAt: Date?
    /// How long a drain may run before every skipped attempt reports it as stuck.
    private let drainStallThreshold: TimeInterval = 5 * 60
    /// When the stall was last reported, so a stuck drain does not report on every
    /// poll. `.meteringError` is never rate-limited by the flight recorder, and
    /// the poller runs about every ten seconds — roughly six an hour became six a
    /// MINUTE, which fills the 300-slot failure ring in under an hour and evicts
    /// exactly the evidence that ring exists to keep. The reporter was destroying
    /// the thing it was added to protect.
    private var lastDrainStallReportAt: Date?
    /// Reports per stuck drain. Throttling alone is not enough: one every five
    /// minutes is ~288 a day, which still fills the ring. Twelve consecutive
    /// reports establish the condition; the thirteenth adds nothing and starts
    /// costing other evidence, so after an hour it goes quiet and the queue length
    /// stays readable from the drain's own `started` record.
    private let drainStallReportCap = 12
    private var drainStallReportCount = 0
    private let currentChildID: () -> UUID?
    private let afterLocalMutation: () async -> Void

    init(
        store: ActiveLockStore = .shared,
        scheduler: LockScheduler,
        currentChildID: @escaping () -> UUID? = { nil },
        afterLocalMutation: @escaping () async -> Void = {}
    ) {
        self.store = store
        self.scheduler = scheduler
        self.currentChildID = currentChildID
        self.afterLocalMutation = afterLocalMutation
    }

    nonisolated deinit {}

    func reconcile(snapshot: ChildStateResponse, childID: UUID, now: Date = Date()) async {
        guard identityIsCurrent(childID) else {
            // Trigger, never await — see `schedulePendingStopDrain`. This is also
            // the case that CREATES most of the backlog, since an identity switch
            // abandons whatever the previous child had armed.
            schedulePendingStopDrain(now: now)
            return
        }
        let sticky = loadSticky()
        let r = snapshot.reflectionRequest
        let heldRecordKey = sticky.heldRID.map { _ in
            ReflectionLockRecordFactory.recordKey(childID: childID)
        }
        var currentExpiry: Date? = nil
        if let key = heldRecordKey {
            let shields = await store.allCurrent().shields
            currentExpiry = shields.first(where: { $0.recordKey == key })?.expiresAt
            if currentExpiry != nil, let heldRID = sticky.heldRID {
                await removeLegacyReflectionRecordIfOwned(rid: heldRID, childID: childID)
            }
            guard identityIsCurrent(childID) else { return }
        }
        let (decision, next) = ReflectionLockReconciler.decide(
            reflectionRID: r?.id, status: r?.status, serverCap: r?.reflectionLockCapExpiresAt,
            lastResolved: snapshot.lastResolvedReflection, sticky: sticky,
            currentRecordExpiry: currentExpiry, now: now)
        switch decision {
        case .noop: break
        case .apply(let rid, let expiresAt):
            guard identityIsCurrent(childID) else { return }
            let rec = ReflectionLockRecordFactory.make(rid: rid, expiresAt: expiresAt, childID: childID)
            _ = await store.addShield(rec, force: true)   // force so re-arm overwrites, no confirm prompt
            await afterLocalMutation()
            guard identityIsCurrent(childID) else {
                await removeReflectionRecordIfOwned(rec)
                clearReflectionStickyIfHeld(in: [rid])
                return
            }
            await scheduleOrDiagnose(rec, rid: rid)
            await removeLegacyReflectionRecordIfOwned(rid: rid, childID: childID)
            // The schedule is a suspension point, so the device may have changed
            // hands while it was in flight — and unlike the checks above, this one
            // has to undo something that has already landed with Apple. Without
            // it the schedule re-creates the previous family's activity AFTER its
            // cleanup ran, and the ack below credits the lock to a child who is
            // no longer on this device.
            guard identityIsCurrent(childID) else {
                await cancelOrDiagnose(rec.deviceActivityName, rid: rid)
                await removeReflectionRecordIfOwned(rec)
                clearReflectionStickyIfHeld(in: [rid])
                return
            }
            // §8.1 (Plan 7): first-sight honest payoff — tell the backend the kid
            // device APPLIED the all-apps reflection lock so the parent's
            // first-actions poll sees `lock_applied_at`. Best-effort, idempotent
            // server-side; never blocks the lock.
            postLockAppliedBestEffort(childID: childID, rid: rid)
        case .release(let rid):
            let key = ReflectionLockRecordFactory.recordKey(childID: childID)
            let held = await store.allCurrent().shields.first { $0.recordKey == key }
            guard identityIsCurrent(childID) else { return }
            if held?.targetChildID == childID {
                _ = await store.removeShield(recordKey: key)
            }
            await removeLegacyReflectionRecordIfOwned(rid: rid, childID: childID)
            guard identityIsCurrent(childID) else { return }
            let name = ReflectionLockRecordFactory
                .make(rid: rid, expiresAt: now, childID: childID).deviceActivityName
            await cancelOrDiagnose(name, rid: rid)
        case .swap(let releaseRID, let applyRID, let expiresAt):
            let releaseKey = ReflectionLockRecordFactory.recordKey(childID: childID)
            let held = await store.allCurrent().shields.first { $0.recordKey == releaseKey }
            guard identityIsCurrent(childID) else { return }
            if held?.targetChildID == childID {
                _ = await store.removeShield(recordKey: releaseKey)
            }
            await removeLegacyReflectionRecordIfOwned(rid: releaseRID, childID: childID)
            guard identityIsCurrent(childID) else { return }
            await cancelOrDiagnose(
                ReflectionLockRecordFactory
                    .make(rid: releaseRID, expiresAt: now, childID: childID).deviceActivityName,
                rid: releaseRID
            )
            // The cancel suspended. Re-verify BEFORE adding a shield, or a device
            // that changed hands mid-swap gets the previous child's all-app lock.
            //
            // Clearing the sticky is part of the same obligation, not a nicety:
            // `ReflectionLockSticky` carries no owner, so a sticky left behind
            // here is read as the NEW child's held reflection on the next
            // reconcile. `.apply`'s mismatch path already clears it; leaving
            // `.swap` inconsistent was the bug, and asserting the old behaviour
            // in a test made it a contract.
            guard identityIsCurrent(childID) else {
                clearReflectionStickyIfHeld(in: [releaseRID, applyRID])
                return
            }
            let rec = ReflectionLockRecordFactory.make(rid: applyRID, expiresAt: expiresAt, childID: childID)
            _ = await store.addShield(rec, force: true)
            await afterLocalMutation()
            guard identityIsCurrent(childID) else {
                await removeReflectionRecordIfOwned(rec)
                clearReflectionStickyIfHeld(in: [releaseRID, applyRID])
                return
            }
            await scheduleOrDiagnose(rec, rid: applyRID)
            await removeLegacyReflectionRecordIfOwned(rid: applyRID, childID: childID)
            guard identityIsCurrent(childID) else {
                await cancelOrDiagnose(rec.deviceActivityName, rid: applyRID)
                await removeReflectionRecordIfOwned(rec)
                clearReflectionStickyIfHeld(in: [releaseRID, applyRID])
                return
            }
            postLockAppliedBestEffort(childID: childID, rid: applyRID)
        }
        guard identityIsCurrent(childID) else { return }
        saveSticky(next)
        schedulePendingStopDrain(now: now)
    }

    /// Start the backlog drain and return immediately.
    ///
    /// Moving the drain after the current enforcement was not enough: `reconcile`
    /// still awaited it, and BigKidStatePoller awaits `reconcile` before it
    /// replays metering callbacks, applies the UI snapshot and reconciles the
    /// pool. So a historical stop that enters the daemon and never returns froze
    /// the entire back half of every poll and left `isFetchInFlight` set for good.
    /// It was easy to miss precisely because the UI thread stayed responsive.
    ///
    /// A wedged drain now costs one gateway slot and nothing else. Single-flight,
    /// so a queue that cannot be drained does not accumulate tasks either.
    private func schedulePendingStopDrain(now: Date) {
        let queued = loadPendingStops()
        guard !queued.isEmpty else { return }
        if pendingStopDrainInFlight {
            reportDrainStallIfOverdue(queueLength: queued.count, now: now)
            return
        }
        pendingStopDrainInFlight = true
        pendingStopDrainStartedAt = now
        lastDrainStallReportAt = nil
        drainStallReportCount = 0
        MeteringFlightRecorder.emit(
            kind: .meteringWork,
            site: "reflection.pendingStops.drain",
            verdict: "started",
            detail: "queued=\(queued.count)"
        )
        Task { [weak self] in
            await self?.drainPendingStops()
            guard let self else { return }
            let remaining = self.loadPendingStops().count
            MeteringFlightRecorder.emit(
                kind: .meteringWork,
                site: "reflection.pendingStops.drain",
                verdict: remaining == 0 ? "cleared" : "partial",
                detail: "remaining=\(remaining)"
            )
            self.pendingStopDrainInFlight = false
            self.pendingStopDrainStartedAt = nil
            self.lastDrainStallReportAt = nil
            self.drainStallReportCount = 0
        }
    }

    /// A drain in flight past the threshold is parked in the daemon and will not
    /// finish. Report it — but at most once per threshold window, and at most
    /// `drainStallReportCap` times, because the report itself is unsuppressed.
    private func reportDrainStallIfOverdue(queueLength: Int, now: Date) {
        guard let startedAt = pendingStopDrainStartedAt,
              now.timeIntervalSince(startedAt) >= drainStallThreshold,
              drainStallReportCount < drainStallReportCap
        else { return }
        if let last = lastDrainStallReportAt,
           now.timeIntervalSince(last) < drainStallThreshold {
            return
        }
        lastDrainStallReportAt = now
        drainStallReportCount += 1
        MeteringFlightRecorder.emitFailure(
            site: "reflection.pendingStops.drain",
            verdict: "stalled",
            detail: "queued=\(queueLength) "
                + "stuckFor=\(Int(now.timeIntervalSince(startedAt)))s "
                + "report=\(drainStallReportCount)/\(drainStallReportCap)"
        )
    }

    private func identityIsCurrent(_ expectedChildID: UUID) -> Bool {
        currentChildID() == expectedChildID
    }

    private func removeReflectionRecordIfOwned(_ record: ShieldRecord) async {
        let current = await store.allCurrent().shields.first {
            $0.recordKey == record.recordKey
        }
        guard current?.targetChildID == record.targetChildID else { return }
        _ = await store.removeShield(recordKey: record.recordKey)
    }

    private func removeLegacyReflectionRecordIfOwned(rid: UUID, childID: UUID) async {
        let legacy = ReflectionLockRecordFactory.legacyMake(
            rid: rid,
            expiresAt: Date(),
            childID: childID
        )
        let held = await store.allCurrent().shields.first {
            $0.recordKey == legacy.recordKey
        }
        guard held?.targetChildID == childID else { return }
        _ = await store.removeShield(recordKey: legacy.recordKey)
        await cancelOrDiagnose(legacy.deviceActivityName, rid: rid)
    }

    private func clearReflectionStickyIfHeld(in reflectionIDs: Set<UUID>) {
        let sticky = loadSticky()
        guard let heldRID = sticky.heldRID, reflectionIDs.contains(heldRID) else { return }
        defaults?.removeObject(forKey: stickyKey)
    }

    /// §8.1 first-sight hook (Plan 7): fire-and-forget POST
    /// /child/reflection/{rid}/lock-applied so the parent's onboarding payoff
    /// poll reads the honest `lock_applied_at`. Guards against re-posting the
    /// same rid more than once per process via a small App-Group marker, so the
    /// 20s poll loop's repeated `.apply`/re-arm reconciles stay quiet. Best-
    /// effort: any failure is swallowed (the lock already applied locally).
    private func postLockAppliedBestEffort(childID: UUID, rid: UUID) {
        let markerKey = "evlin.reflectionLockApplied.\(rid.uuidString)"
        if defaults?.bool(forKey: markerKey) == true { return }
        Task {
            do {
                try await APIClient().postReflectionLockApplied(
                    childDeviceID: childID, reflectionID: rid)
                if identityIsCurrent(childID) {
                    defaults?.set(true, forKey: markerKey)
                }
            } catch {
                // Non-fatal: the lock is applied locally regardless; the parent
                // payoff just won't flip until a later reconcile re-posts.
            }
        }
    }

    /// Schedule the DAM auto-removal; on failure DO NOT swallow — record a diagnostic
    /// (a failed schedule means no OS timer, so the lock could outlive its lease).
    /// A refused cancel leaves a live activity nobody claims. It is recorded for
    /// diagnostics AND queued for retry — the diagnostic alone let the state
    /// machine call a release finished while Apple still held the activity.
    private func cancelOrDiagnose(_ deviceActivityName: String, rid: UUID) async {
        guard await scheduler.cancel(deviceActivityName: deviceActivityName) else {
            defaults?.set(
                "ts=\(Date().timeIntervalSince1970) cancel_refused "
                    + "key=all:reflection:\(rid.uuidString) name=\(deviceActivityName)",
                forKey: scheduleFailureKey
            )
            enqueuePendingStop(deviceActivityName)
            return
        }
        // A name can be queued from an earlier refusal; a stop that lands now
        // retires it. `cancel` is idempotent, so a duplicate attempt is harmless.
        removePendingStop(deviceActivityName)
    }

    /// Retry a bounded slice of the queued stops. Names that are refused again
    /// stay queued for the next pass, so the loop closes only on success.
    private func drainPendingStops() async {
        let queued = loadPendingStops()
        guard !queued.isEmpty else { return }
        for name in queued.prefix(pendingStopsPerPass) {
            if await scheduler.cancel(deviceActivityName: name) {
                removePendingStop(name)
            }
        }
    }

    private func loadPendingStops() -> [String] {
        defaults?.stringArray(forKey: pendingStopsKey) ?? []
    }

    private func enqueuePendingStop(_ name: String) {
        var queued = loadPendingStops()
        guard !queued.contains(name) else { return }
        queued.append(name)
        defaults?.set(queued, forKey: pendingStopsKey)
    }

    private func removePendingStop(_ name: String) {
        let queued = loadPendingStops()
        guard queued.contains(name) else { return }
        let remaining = queued.filter { $0 != name }
        if remaining.isEmpty {
            defaults?.removeObject(forKey: pendingStopsKey)
        } else {
            defaults?.set(remaining, forKey: pendingStopsKey)
        }
    }

    private func scheduleOrDiagnose(_ rec: ShieldRecord, rid: UUID) async {
        do {
            try await scheduler.schedule(record: rec)
            defaults?.removeObject(forKey: scheduleFailureKey)   // clear stale failure on success
        } catch {
            defaults?.set("ts=\(Date().timeIntervalSince1970) key=all:reflection:\(rid.uuidString) err=\(error)",
                          forKey: scheduleFailureKey)
        }
    }

    private func loadSticky() -> ReflectionLockSticky {
        guard let d = defaults?.data(forKey: stickyKey),
              let s = try? JSONDecoder().decode(ReflectionLockSticky.self, from: d) else { return .empty }
        return s
    }
    private func saveSticky(_ s: ReflectionLockSticky) {
        defaults?.set(try? JSONEncoder().encode(s), forKey: stickyKey)
    }
}
