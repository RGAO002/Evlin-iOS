# Phase 0 Spike Notes — 2026-04-22

## Environment
- Device: physical iPhone (user's personal device)
- iOS: current (2026 Q2 release)
- Auth granted: `.individual`
- Child Apple ID: **not configured** (user has only personal account)

---

## Test 1: `Application(bundleIdentifier:)` + `blockedApplications`

**Steps**:
1. Tap "Block Instagram" in SpikeView
2. Return to home screen, attempt to open Instagram

**Result**: **PASS** — stronger than expected.

**Observations**:
- Instagram **icon disappears entirely** from home screen when `blockedApplications` contains its bundle identifier. Not just launch-blocked — visually hidden.
- App remains installed (not uninstalled); icon reappears immediately when block is cleared.
- No user-facing dialog was needed; the "hidden icon" state is its own UI signal.

**Implications for spec**: Spec §2 Tier A says "Lock shows iOS's system-level 'not available' dialog on launch." This description is incomplete — the primary behavior is **icon hiding**. Dialog appears only via deep-link / alternate launch paths. Rewrite §2 Tier A "Characteristics" accordingly.

---

## Test 2: `denyAppRemoval`

**Steps**:
1. Long-press Evlin icon before enabling — observe menu options
2. Tap "Enable" under denyAppRemoval in SpikeView
3. Long-press Evlin icon — observe options
4. Tap "Disable"
5. Long-press again

**Result**: **PASS under `.individual` authorization.** No Child Apple ID required.

**Observations**:
- Pre-enable: long-press shows "Remove App" with sub-options including "Delete App".
- Post-enable: **"Delete App" option is removed**. Only "Remove from Home Screen" remains (which hides the icon but does NOT uninstall the app).
- Also verified: Settings → General → iPhone Storage → Evlin → no "Delete App" button.
- Post-disable: "Delete App" returns.

**Implications — MAJOR**: Spec / plan assumed `denyAppRemoval` required `.child` authorization (i.e. Child Apple ID + Family Sharing). This assumption is **wrong**. `.individual` auth grants access to `denyAppRemoval` just as well.

Downstream consequences:
1. **Std mode gets deletion protection for free**. No need for the "set Family Controls passcode + disable app deletion in Content & Privacy" manual dance to protect Evlin from being deleted.
2. **Max mode now has one clear unique capability** instead of two: the parent-device picker rendering child's installed apps via Family Sharing (remote list management). This is still a meaningful differentiator.
3. Child onboarding `DeletionProtectionStep` applies to **both** Max and Std paths (previously Max-only).
4. Parent onboarding Std path loses the "Disable Deleting Apps" and "Std Verification" steps (no manual dance required).

---

## Test 3: Max-mode token transferability

**Result**: **BLOCKED — no Child Apple ID available for testing.**

**Action**: Deferred to a future spike when Child Apple ID is set up. Not a blocker for MVP given Test 2's finding (Max mode demoted to post-MVP optional feature).

---

## Decisions (inform Phase 1 onward)

1. **Tier A (bundle-id block)**: CONFIRMED. Use `Application(bundleIdentifier:)` + `store.application.blockedApplications`. Expect icon hiding as primary UX; surface this in user-facing copy ("Instagram is blocked and hidden from the home screen").

2. **`denyAppRemoval`**: CONFIRMED under `.individual` auth. Use it in both Std and Max paths of onboarding. The manual "Content & Privacy → Deleting Apps → Don't Allow" step is redundant — delete from Std onboarding UX. Keep the Screen Time passcode step for Std (protects Screen Time settings from the child modifying them, a separate concern).

3. **Max mode retained as DEFAULT/RECOMMENDED onboarding**. Std mode stays as the fallback path. Per product direction (2026-04-22): dual implementation for future monetization — Max as premium tier (remote parent picker), Std as free tier (physical-presence picker). Both modes are fully built in v1; no deferral.

4. **Phase 4 adjustments**:
   - `DeletionProtectionStep` moves from Max-only to **both paths** in Child onboarding (Task 4.7).
   - Parent Std path drops `DisableDeletionStep` and `StdVerificationStep` (Task 4.6 simplifies to just `SetPasscodeStep`).
   - All Max-mode tasks remain (Tasks 4.4 Max steps, 4.5 auth-status endpoint, 4.9 ParentFirstSavedList, 4.11 blob relay).

5. **PendingBlob infrastructure**: Built in v1 for Max mode. Phase 2 includes the full `PendingBlob` table and ephemeral-relay endpoints as originally specified.

6. **Max-mode token transferability (Test 3)**: Still BLOCKED pending Child Apple ID. The plan Phase 4 Task 4.11 assumes transferability; if Test 3 eventually fails, Max degrades to "remote trigger → child-device picker prompt" flow. Document the fallback in Task 4.11 as a contingency note.
