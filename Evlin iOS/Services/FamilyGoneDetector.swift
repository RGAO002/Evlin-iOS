import Foundation

/// Plan 8 — kid family-gone FAIL-OPEN (§15.3 / §1.13).
///
/// When the family that owns this kid device is DELETED, the kid read-paths
/// (`GET /child/state`, `GET /child/commands`) return a terminal `410 Gone`
/// with `detail == "family_removed"`. A deleted family must NEVER leave a kid
/// bricked in a permanent reflection lock, so on first sight of that terminal
/// signal we release EVERY Evlin shield/block, clear the reflection sticky, and
/// reset the kid's pairing state. This is a pure classifier + one `failOpen()`
/// side-effect that REUSES the shipped `ActiveLockStore` release path — never a
/// parallel shield mechanism.
enum FamilyGoneDetector {

    /// True iff `error` is the terminal `410 family_removed` signal — the only
    /// non-retryable kid read-path error. A bare 410 (no detail) or a 410 with a
    /// different detail is NOT treated as family-gone (don't fail open on an
    /// unrelated Gone). Network errors / other statuses are NOT terminal.
    static func isFamilyGone(error: Error) -> Bool {
        // BigKidStatePoller path: BigKidAPIError{status, detail}.
        if let e = error as? BigKidAPIError {
            return e.status == 410 && e.detail == "family_removed"
        }
        // CommandPoller path: APIError.serverError(410) — the detail isn't
        // carried, so a 410 from the kid command read-path is treated as
        // family-gone (the only 410 that endpoint emits is family_removed).
        if let apiError = error as? APIError, case .serverError(let code) = apiError {
            return code == 410
        }
        return false
    }

    /// Release ALL Evlin restrictions for this kid device and reset its pairing
    /// state so a deleted family can never brick the phone. Idempotent. REUSES
    /// `ActiveLockStore.unshieldAll()` + `unblockAll()` (the shipped release
    /// path) and clears the `ReflectionLockSticky` so the reconciler won't re-arm.
    @MainActor
    static func failOpen(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = UserDefaults(
            suiteName: EarnedTimeStore.appGroupSuiteName
        ),
        releaseRestrictions: (() async -> Void)? = nil,
        teardownEarned: (() -> Void)? = nil
    ) async {
        if let teardownEarned {
            teardownEarned()
        } else {
            EarnedBudgetArming.teardownFamilyIdentity(
                appGroupDefaults: appGroupDefaults
            )
        }
        appGroupDefaults?.removeObject(forKey: "evlin.childId")
        appGroupDefaults?.synchronize()

        // Earned monitoring is invalidated synchronously before any suspension
        // point can expose a newly mirrored identity to an old callback.

        // 1. Drop every shield + block (reflection lock included — it's an
        //    `.all`-tier ShieldRecord, so unshieldAll() releases it too).
        if let releaseRestrictions {
            await releaseRestrictions()
        } else {
            _ = await ActiveLockStore.shared.unshieldAll()
            _ = await ActiveLockStore.shared.unblockAll()
        }

        // 2. Clear the reflection sticky so a stale held RID can't make the
        //    reconciler re-apply a lock on a later (spurious) poll.
        appGroupDefaults?.removeObject(forKey: "evlin.reflectionLockSticky")

        // 3. Reset kid pairing state. Drop the child device id (the key every
        //    poller reads) + the family id so the kid app stops polling a dead
        //    family. Leave `appMode`/`onboardingComplete` so the device returns
        //    to a clean unpaired shell rather than crash-looping.
        defaults.removeObject(forKey: CommandPoller.childDeviceIDDefaultsKey)
        defaults.removeObject(forKey: "evlin.familyID")
    }
}
