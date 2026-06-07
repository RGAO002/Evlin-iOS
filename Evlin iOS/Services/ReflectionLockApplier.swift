import Foundation

enum ReflectionLockRecordFactory {
    static func make(rid: UUID, expiresAt: Date, childID: UUID) -> ShieldRecord {
        ShieldRecord(
            recordKey: "all:reflection:\(rid.uuidString)",
            tier: .all, targetKey: "reflection:\(rid.uuidString)",
            displayName: "Reflection lock", lastCommandID: UUID(),
            appTokens: [], categoryTokens: [], webDomainTokens: [],
            appliesToAll: true, issuedAt: Date(), expiresAt: expiresAt,
            originalRequest: "reflection lockdown", targetChildID: childID)
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

    init(store: ActiveLockStore = .shared, scheduler: LockScheduler) {
        self.store = store; self.scheduler = scheduler
    }

    func reconcile(snapshot: ChildStateResponse, childID: UUID, now: Date = Date()) async {
        let sticky = loadSticky()
        let r = snapshot.reflectionRequest
        let heldRecordKey = sticky.heldRID.map { "all:reflection:\($0.uuidString)" }
        var currentExpiry: Date? = nil
        if let key = heldRecordKey {
            currentExpiry = await store.allCurrent().shields.first(where: { $0.recordKey == key })?.expiresAt
        }
        let (decision, next) = ReflectionLockReconciler.decide(
            reflectionRID: r?.id, status: r?.status, serverCap: r?.reflectionLockCapExpiresAt,
            lastResolved: snapshot.lastResolvedReflection, sticky: sticky,
            currentRecordExpiry: currentExpiry, now: now)
        switch decision {
        case .noop: break
        case .apply(let rid, let expiresAt):
            let rec = ReflectionLockRecordFactory.make(rid: rid, expiresAt: expiresAt, childID: childID)
            _ = await store.addShield(rec, force: true)   // force so re-arm overwrites, no confirm prompt
            scheduleOrDiagnose(rec, rid: rid)
            // §8.1 (Plan 7): first-sight honest payoff — tell the backend the kid
            // device APPLIED the all-apps reflection lock so the parent's
            // first-actions poll sees `lock_applied_at`. Best-effort, idempotent
            // server-side; never blocks the lock.
            postLockAppliedBestEffort(childID: childID, rid: rid)
        case .release(let rid):
            _ = await store.removeShield(recordKey: "all:reflection:\(rid.uuidString)")
            let name = ReflectionLockRecordFactory
                .make(rid: rid, expiresAt: now, childID: childID).deviceActivityName
            scheduler.cancel(deviceActivityName: name)
        case .swap(let releaseRID, let applyRID, let expiresAt):
            _ = await store.removeShield(recordKey: "all:reflection:\(releaseRID.uuidString)")
            scheduler.cancel(deviceActivityName: ReflectionLockRecordFactory
                .make(rid: releaseRID, expiresAt: now, childID: childID).deviceActivityName)
            let rec = ReflectionLockRecordFactory.make(rid: applyRID, expiresAt: expiresAt, childID: childID)
            _ = await store.addShield(rec, force: true)
            scheduleOrDiagnose(rec, rid: applyRID)
            postLockAppliedBestEffort(childID: childID, rid: applyRID)
        }
        saveSticky(next)
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
                defaults?.set(true, forKey: markerKey)
            } catch {
                // Non-fatal: the lock is applied locally regardless; the parent
                // payoff just won't flip until a later reconcile re-posts.
            }
        }
    }

    /// Schedule the DAM auto-removal; on failure DO NOT swallow — record a diagnostic
    /// (a failed schedule means no OS timer, so the lock could outlive its lease).
    private func scheduleOrDiagnose(_ rec: ShieldRecord, rid: UUID) {
        do {
            try scheduler.schedule(record: rec)
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
