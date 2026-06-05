import Foundation

struct ReflectionLockSticky: Codable, Equatable {
    var heldRID: UUID?
    var capExpiresAt: Date?
    var capExhaustedRIDs: Set<UUID> = []
    static let empty = ReflectionLockSticky()
}

enum ReflectionLockDecision: Equatable {
    case noop
    case apply(rid: UUID, expiresAt: Date)   // addShield(record) + LockScheduler.schedule
    case release(rid: UUID)                  // removeShield(key) + LockScheduler.cancel
    case swap(releaseRID: UUID, applyRID: UUID, expiresAt: Date)  // a NEW reflection supersedes the held one
}

enum ReflectionLockReconciler {
    static let lease: TimeInterval = 20 * 60
    static let fallbackCap: TimeInterval = 2 * 60 * 60   // when server cap absent

    /// PURE. Decides the lock action and the next sticky from the snapshot.
    static func decide(
        reflectionRID: UUID?, status: BigKidReflectionStatus?, serverCap: Date?,
        lastResolved: ResolvedReflection?, sticky: ReflectionLockSticky,
        currentRecordExpiry: Date?, now: Date
    ) -> (ReflectionLockDecision, ReflectionLockSticky) {
        var s = sticky

        // (0) CAP IS TERMINAL — check first. DAM removes the shield; only we clear the sticky.
        if let held = s.heldRID, let cap = s.capExpiresAt, now >= cap {
            s.heldRID = nil; s.capExpiresAt = nil; s.capExhaustedRIDs.insert(held)
            return (.release(rid: held), s)
        }

        let activeRID: UUID? = {
            guard let rid = reflectionRID, let st = status, st != .approved else { return nil }
            return rid
        }()

        if let rid = activeRID, !s.capExhaustedRIDs.contains(rid) {
            // A DIFFERENT active reflection supersedes the one we hold: release old, switch to new.
            if let held = s.heldRID, held != rid {
                let newCap = serverCap ?? now.addingTimeInterval(fallbackCap)
                if now >= newCap {   // the new one is already past its cap → release old, don't lock new
                    s.heldRID = nil; s.capExpiresAt = nil; s.capExhaustedRIDs.insert(rid)
                    return (.release(rid: held), s)
                }
                s.heldRID = rid; s.capExpiresAt = newCap
                let target = min(now.addingTimeInterval(lease), newCap)
                return (.swap(releaseRID: held, applyRID: rid, expiresAt: target), s)
            }
            let cap = s.capExpiresAt ?? serverCap ?? now.addingTimeInterval(fallbackCap)
            if now >= cap {  // fresh sight of an already-expired cap → terminal, never lock
                s.heldRID = nil; s.capExpiresAt = nil; s.capExhaustedRIDs.insert(rid)
                return (.release(rid: rid), s)
            }
            if s.heldRID == nil { s.heldRID = rid; s.capExpiresAt = cap }   // first sight
            let target = min(now.addingTimeInterval(lease), cap)
            // throttle: re-arm only when < ½ lease remains (or no current record)
            let needsReArm: Bool = {
                guard let cur = currentRecordExpiry else { return true }
                return cur.timeIntervalSince(now) < lease / 2
            }()
            return needsReArm ? (.apply(rid: rid, expiresAt: target), s) : (.noop, s)
        }

        // Not active (approved / nil / cap-exhausted). Release ONLY on a positive signal.
        if let held = s.heldRID {
            let approved = (reflectionRID == held && status == .approved)
            let resolved = (lastResolved?.rid == held)   // approved or cancelled for this rid
            if approved || resolved {
                s.heldRID = nil; s.capExpiresAt = nil
                return (.release(rid: held), s)
            }
            return (.noop, s)   // bare absence → KEEP
        }
        return (.noop, s)
    }
}
