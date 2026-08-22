import XCTest
@testable import Evlin_iOS

/// The cross-process half of the authorization revoke detector.
///
/// The old guard was process-local: a revoke that happened while the app was
/// not running was invisible, so the device kept twelve rotated-dead tokens,
/// acked every lock `not_authorized`, and never asked the parent to re-pick
/// (Enerel's iPad, 2026-08-11). The persisted state machine closes that while
/// keeping the 2026-08-07 lesson: a launch-transient `.notDetermined` must
/// never count as a revoke.
///
/// One walk in one method: `sawApprovedThisProcess` is deliberately static
/// process state, so the order of observations IS the scenario. Splitting into
/// methods would re-run earlier steps against dirtied statics.
@MainActor
final class AppControlsIdentityGuardAuthorizationTests: XCTestCase {

    private var defaults: UserDefaults { UserDefaults(suiteName: "group.com.evlin.ios")! }
    private let revokedKey = "evlin.appControls.sawAuthorizationRevoked"
    private let lastStableKey = "evlin.appControls.lastStableAuthorization"

    func test_authorizationStateMachine_fullWalk() {
        // ── Fresh install, launch transient ──────────────────────────────
        defaults.removeObject(forKey: revokedKey)
        defaults.removeObject(forKey: lastStableKey)
        AppControlsIdentityGuard.noteAuthorizationRevoked(denied: false)
        XCTAssertFalse(
            defaults.bool(forKey: revokedKey),
            "a transient notDetermined before any approved must never count"
        )

        // Even an explicit denied with NO stable approved on record is not a
        // revoke — there was never a grant whose tokens could rotate.
        AppControlsIdentityGuard.noteAuthorizationRevoked(denied: true)
        XCTAssertFalse(defaults.bool(forKey: revokedKey))

        // ── Cross-process revoke (the Enerel hole) ───────────────────────
        // A PREVIOUS process persisted a stable approved; this process starts
        // cold (sawApprovedThisProcess == false) and observes .denied.
        defaults.set("approved", forKey: lastStableKey)
        AppControlsIdentityGuard.noteAuthorizationRevoked(denied: false)
        XCTAssertFalse(
            defaults.bool(forKey: revokedKey),
            "cold-start notDetermined stays ignored even with a stable approved"
        )
        AppControlsIdentityGuard.noteAuthorizationRevoked(denied: true)
        XCTAssertTrue(
            defaults.bool(forKey: revokedKey),
            "cold-start .denied after a persisted approved IS the "
                + "out-of-process revoke — the case the process-local flag missed"
        )

        // ── Re-grant purges and re-arms the detector ─────────────────────
        AppControlsIdentityGuard.noteAuthorizationApproved()
        XCTAssertFalse(
            defaults.bool(forKey: revokedKey),
            "the re-grant consumes the pending revoke (purge + reset)"
        )
        XCTAssertEqual(defaults.string(forKey: lastStableKey), "approved")

        // ── In-process revoke still works, status irrelevant ─────────────
        AppControlsIdentityGuard.noteAuthorizationRevoked(denied: false)
        XCTAssertTrue(
            defaults.bool(forKey: revokedKey),
            "once this process saw approved, ANY non-approved is a real edge"
        )
    }
}
