import XCTest
@testable import Evlin_iOS

final class ReflectionLockReconcilerTests: XCTestCase {
    let rid = UUID()
    func now() -> Date { Date(timeIntervalSince1970: 1_000_000) }
    func cap(_ s: TimeInterval) -> Date { now().addingTimeInterval(s) }

    func decide(reflection: (rid: UUID, status: BigKidReflectionStatus, cap: Date?)?,
                resolved: ResolvedReflection?, sticky: ReflectionLockSticky,
                currentExpiry: Date?) -> (ReflectionLockDecision, ReflectionLockSticky) {
        ReflectionLockReconciler.decide(
            reflectionRID: reflection?.rid, status: reflection?.status,
            serverCap: reflection?.cap, lastResolved: resolved,
            sticky: sticky, currentRecordExpiry: currentExpiry, now: now())
    }

    func testFirstSightActivePendingApplies() {
        let (d, s) = decide(reflection: (rid, .pending, cap(7200)), resolved: nil,
                            sticky: .empty, currentExpiry: nil)
        guard case .apply(let r, let exp) = d else { return XCTFail("\(d)") }
        XCTAssertEqual(r, rid)
        XCTAssertEqual(exp, now().addingTimeInterval(20*60))   // min(now+20m, cap=2h)
        XCTAssertEqual(s.heldRID, rid)
    }

    func testHealthyLeaseIsNoop() {  // >½ lease remaining → don't churn DAM
        var sticky = ReflectionLockSticky.empty; sticky.heldRID = rid; sticky.capExpiresAt = cap(7200)
        let (d, _) = decide(reflection: (rid, .pending, cap(7200)), resolved: nil,
                            sticky: sticky, currentExpiry: now().addingTimeInterval(15*60))
        XCTAssertEqual(d, .noop)
    }

    func testLowLeaseReArms() {  // <½ lease remaining → re-apply
        var sticky = ReflectionLockSticky.empty; sticky.heldRID = rid; sticky.capExpiresAt = cap(7200)
        let (d, _) = decide(reflection: (rid, .pending, cap(7200)), resolved: nil,
                            sticky: sticky, currentExpiry: now().addingTimeInterval(9*60))
        guard case .apply = d else { return XCTFail("\(d)") }
    }

    func testApprovedReleases() {
        var sticky = ReflectionLockSticky.empty; sticky.heldRID = rid; sticky.capExpiresAt = cap(7200)
        let (d, s) = decide(reflection: (rid, .approved, cap(7200)), resolved: nil,
                            sticky: sticky, currentExpiry: now().addingTimeInterval(600))
        XCTAssertEqual(d, .release(rid: rid)); XCTAssertNil(s.heldRID)
    }

    func testCancelledForRidReleasesEvenWhenReflectionNil() {
        var sticky = ReflectionLockSticky.empty; sticky.heldRID = rid; sticky.capExpiresAt = cap(7200)
        let (d, s) = decide(reflection: nil,
                            resolved: ResolvedReflection(rid: rid, resolution: .cancelled),
                            sticky: sticky, currentExpiry: now().addingTimeInterval(600))
        XCTAssertEqual(d, .release(rid: rid)); XCTAssertNil(s.heldRID)
    }

    func testBareNilKeepsLock() {  // backend amnesia / multi-worker → DO NOT unlock
        var sticky = ReflectionLockSticky.empty; sticky.heldRID = rid; sticky.capExpiresAt = cap(7200)
        let (d, s) = decide(reflection: nil, resolved: nil,
                            sticky: sticky, currentExpiry: now().addingTimeInterval(600))
        XCTAssertEqual(d, .noop); XCTAssertEqual(s.heldRID, rid)
    }

    func testCapReachedIsTerminalAndMarksExhausted() {
        var sticky = ReflectionLockSticky.empty; sticky.heldRID = rid; sticky.capExpiresAt = cap(-1)
        let (d, s) = decide(reflection: (rid, .pending, cap(-1)), resolved: nil,
                            sticky: sticky, currentExpiry: now().addingTimeInterval(60))
        XCTAssertEqual(d, .release(rid: rid))
        XCTAssertNil(s.heldRID)
        XCTAssertTrue(s.capExhaustedRIDs.contains(rid))
    }

    func testCapExhaustedRidNeverReLocks() {  // fresh sight of an already-capped rid
        var sticky = ReflectionLockSticky.empty; sticky.capExhaustedRIDs = [rid]
        let (d, _) = decide(reflection: (rid, .pending, cap(7200)), resolved: nil,
                            sticky: sticky, currentExpiry: nil)
        XCTAssertEqual(d, .noop)
    }

    func testNewRidSupersedesOldHeld() {  // new reflection while holding an old one → swap (no half-state)
        let oldRID = UUID(), newRID = UUID()
        var sticky = ReflectionLockSticky.empty
        sticky.heldRID = oldRID; sticky.capExpiresAt = cap(7200)
        let (d, s) = decide(reflection: (newRID, .pending, cap(3600)), resolved: nil,
                            sticky: sticky, currentExpiry: now().addingTimeInterval(600))
        guard case .swap(let rel, let app, let exp) = d else { return XCTFail("\(d)") }
        XCTAssertEqual(rel, oldRID)
        XCTAssertEqual(app, newRID)
        XCTAssertEqual(exp, now().addingTimeInterval(20*60))   // min(now+20m, newCap=1h)
        XCTAssertEqual(s.heldRID, newRID)
        XCTAssertEqual(s.capExpiresAt, cap(3600))              // adopts the NEW server cap
    }
}
