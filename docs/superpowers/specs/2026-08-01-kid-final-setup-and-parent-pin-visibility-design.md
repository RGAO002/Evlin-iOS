# Kid final setup step + parent-visible PIN — design

**Date:** 2026-08-01
**Status:** approved by Fred (mockups reviewed 2026-08-01), not implemented
**Scope:** K-side onboarding last step, backend PIN storage, P-side device detail

## Problem

Three gaps, one screen apart:

1. **Screen-time tracking selection is not part of onboarding.** The all-category
   `FamilyActivitySelection` that the earned-time ladder measures against is captured
   by `ScreenTimeCaptureView`, which only appears as a card on `BigKidHomeView` *after*
   onboarding, gated on `EarnedTimeStore.shared.measurementSelection == nil`. A kid who
   never taps that card leaves the pool unarmable — a known cause of "the bar never moves".

2. **The Parent PIN is set after the fact, or never.** `EvlinPINGateView` creates it
   lazily the first time someone opens Parent Controls on the kid device. The parent
   V2 onboarding text already warns about the consequence: if the parent skips it, the
   kid can open Parent Controls first, create their own PIN, and turn protections off.

3. **A forgotten PIN is unrecoverable.** `EvlinPINStore` persists only
   `salt || sha256(salt || pin)`; there is deliberately no "Forgot PIN" affordance
   (a confirm alert is not authentication). A beta parent has already hit this: they
   forgot the PIN, cannot open Parent Controls, and cannot uninstall Evlin.

The last onboarding page today (`ChildReadyStep`) is a pure text notice — "All set! /
Waiting for commands from your parent's Evlin." It occupies the slot where real work
should happen.

## Solution

Replace the terminal text page with a **functional final step** that does both setup
jobs, then make the PIN readable by the parent on their own phone.

### 1. `childFinalSetup` replaces `childReady`

One screen, two required cards, one gated primary button.

**Card A — Screen-time tracking.** Reuses the capture logic that
`ScreenTimeCaptureView` already implements (`FamilyActivitySelection(includeEntireCategory: true)`
→ `familyActivityPicker` → `EarnedTimeStore.saveMeasurementSelection()`). Extract that
logic into a shared model/component so onboarding and the home card are one
implementation, not two.

**Card B — Parent PIN.** Tapping "Create Parent PIN" presents `EvlinPINGateView`,
**reusing its existing UI and validation** (`store: .shared`, `fullScreenCover`, same as
`BigKidRootView:272`) — first-run create → confirm, 4–8 digits, mismatch shake, cancel.
Two changes are required, since "unchanged" is incompatible with uploading the value:

- **New callback `onPINCreated(String)`**, fired *only* on the first-run create path
  (`EvlinPINGateView.swift:157`, right after `store.setPIN(pin)` succeeds), carrying the
  plaintext. The existing no-arg `onUnlocked()` stays as-is for the three unlock call
  sites, which must not receive a PIN. The verify path never fires the new callback.
- Two copy edits (see Copy below).

Without this the plaintext is unrecoverable the moment `setPIN` returns — the store
keeps only `salt || sha256(salt || pin)`.

**Card B is "done" only when the backend has acked the upload.** A network failure keeps
the card in a retry state inside the step ("Couldn't save the PIN. Retry") rather than
letting the kid leave with a PIN the parent can never see. The pending plaintext is held
in a durable payload (App Group, not `UserDefaults.standard`) that is deleted on ack and
retried on next foreground, so an app kill mid-upload does not strand it.

**Gate.** "Finish setup" is disabled until both cards report done. No skip: skipping is
exactly how today's "kid sets their own PIN first" failure happens.

**Finish sequence — order is load-bearing, each step blocks the next:**

1. Both cards report done (tracking saved; PIN acked by backend).
2. `persistPairedIdentifiers()` — write `evlin.childDeviceID` / `evlin.familyID`.
   **Strictly before** step 4, because `Evlin_iOSApp.onChange(of: onboardingComplete)`
   reads those keys synchronously to start the CommandPoller.
3. `await apiClient.markChildAllSet(childDeviceID:)` **must return true, and the
   response must report the default pool ready** (see §5). On failure show
   "Couldn't finish setup. Retry" and stay on the step.
4. Single-device mode: call `onSingleDeviceContinue`. Otherwise flip
   `onboardingComplete` and call `onEnter`.

Step 3 is not optional bookkeeping. `POST /onboarding/child-all-set`
(`family.py:860`) is what (a) advances the parent's waiting screen and (b) silently
auto-provisions the default 120-minute daily pool. The transport is already
sound — `APIClient.deliverAllSet` retries up to 8 times with 0.5s→8s backoff and
returns a `Bool`. The defect is at both ends of it: `ChildReadyStep` **discards that
`Bool`** and leaves the screen regardless, and the server answers `ok: true` even when
pool provisioning failed (§5). So a kid can finish onboarding with no pool at all, which
presents exactly as "the bar never moves". The new step consumes the result instead of
dropping it.

`ChildReadyStep.swift` is deleted once nothing references it.

### 2. PIN becomes parent-visible

The PIN travels: **kid device → backend → parent device.** The parent's phone never
computes anything; it renders what the kid's device uploaded.

- **Backend:** `Device.parent_pin` — `String(8)`, nullable — **plus
  `Device.parent_pin_status`**, an enum column: `not_set | pending_sync | available |
  unrecoverable`. A nullable value alone cannot distinguish "never set" from "set on the
  device but not yet uploaded" from "hash could not be recovered", which is exactly the
  three-state display the P side promises. The status is reported explicitly by the kid
  device; the server never infers it from value presence. Alembic migration for both.
- **Write:** `PUT /child/device/parent-pin` (kid-device-authed). Body carries the value
  and the status. Server validates the value against `^[0-9]{4,8}$` and returns 422
  otherwise — `String(8)` bounds the column, not the format. Called right after the gate
  reports a created PIN; retried from the durable payload until acked.
- **Read:**
  - Parent-authed enrolled-devices path returns `parent_pin_status` **and** the optional
    plaintext (`EnrolledDeviceDTO` gains both fields).
  - Child-authed reads return **status only, never the value**, so the kid device can
    answer "does the backend already have a PIN for me?" (needed to decide whether the
    recovery migration in §3 should run) without the child surface ever echoing a PIN.
- **Local storage is unchanged** — `EvlinPINStore` keeps storing only the salted hash.
  The backend copy is the recovery channel, not the source of truth for verification.
- **Lifecycle:** `parent_pin` and its status are cleared wherever enrollment ends.
  Device removal is a soft delete (`profile.py:394` sets `unpaired_at` and keeps the
  row), so without explicit clearing a stale PIN would outlive the pairing. Clear on:
  unpair, cross-family re-pair (the Pairing v2 `identitySwitch` branch), and account
  deletion.

**Security position.** This PIN is a local edit-gate, not a credential — the store's own
header says "It is NOT a credential store," and its realistic bypass (factory reset) is
already easier than attacking the digest. Storing it recoverably to give the *parent*
— the person who set it — a way to read it back is consistent with what it protects.
It is not a password and must never be reused as one.

### 3. Recovering already-set PINs (the beta parent's case)

Existing installs have only a hash, so there is nothing to upload. But the app holds
both the salt and the digest, and the PIN is 4–8 ASCII digits (≈1.1×10⁸ worst case, and
4-digit is 10⁴). The app can recover its own value by brute force.

On first foreground after upgrade, when `EvlinPINStore.isSet()` is true and the
child-authed status read says the backend has no PIN for this device: search ascending
digit lengths off the main thread, stop at the first match, upload, done. Silent —
neither kid nor parent sees it.

**Cost is not uniform and must not be treated as one pass.** 4 digits is 10⁴ hashes
(instant); 8 digits is 1.1×10⁸ and, with a `Data` allocation per attempt, is not
something to run blindly on a phone. Therefore:

- **Ship 4–6 digits automatically** (≈1.1×10⁶ worst case). 7–8 digit auto-recovery is
  **gated on a real-device benchmark** taken during implementation; if a full 8-digit
  sweep cannot finish within a few foreground sessions at acceptable power, it stays off
  and those devices report `unrecoverable`.
- **Checkpoint and resume.** Persist the search cursor (length + index) so each
  foreground continues where the last left off instead of restarting from zero. A
  partial sweep must never be re-run from the beginning.
- **Chunked and cancellable.** Work in slices with cooperative cancellation on
  backgrounding; never block the main thread.
- Main app process only, foreground, paired state only. **Never** callable from an
  extension, and never exposed as a general API. It is a one-time migration, not a
  capability.
- On exhaustion without a match, report status `unrecoverable`; P-side shows
  "Set on device — value not recoverable. Ask <kid> to reset it in Parent Controls."
  Do not claim a value that was not recovered.
- The migration only helps devices running the new build. Until the beta parent updates
  the kid's phone and opens the app once, their only route remains reinstalling the kid
  app (`clear()` wipes the PIN, at the cost of re-pairing).

### 4. P-side device detail

In `HomeSettingsSheet.deviceDetailMenu`:

- **Add** a `Security` section: "Parent PIN", subtitle "Unlocks Parent Controls on this
  device". The row renders off `parent_pin_status`, never off value presence:
  - `available` → the value in a monospaced field with an eye toggle (masked by
    default), footnote "Set during setup on <kid>'s phone".
  - `not_set` → "Not set", subtitle "Create it in Parent Controls on <kid>'s phone."
  - `pending_sync` → "Will appear when <kid>'s phone syncs".
  - `unrecoverable` → "Set on device — value not recoverable", subtitle "Ask <kid> to
    reset it in Parent Controls."
- **Remove** the `Device Inventory` section. Both of its rows ("Registered Apps",
  "Saved Lists") are `Not wired` placeholders with `disabled: true` — dead UI.

### 5. `child-all-set` must stop reporting success it didn't achieve

Today the endpoint sets `child_onboarding_complete = True` and commits, *then*
best-effort provisions the default pool inside a `try/except` that logs and swallows,
then returns `{"ok": true}` regardless (`family.py:875-890`). A caller that waits for
success therefore still cannot tell whether the pool exists — the parent's waiting
screen is released, the kid's Finish completes, and the child has no pool.

New contract:

1. Idempotently create **or confirm** an active default pool for this child. Reusing an
   existing pool is a success, so retries after a partial failure converge.
2. Only after the pool is confirmed, set `child_onboarding_complete = True`.
3. Any failure returns non-2xx. The kid retries; the parent stays on waiting. Never
   report completion that did not happen.
4. Response body: `{"all_set": true, "default_pool_ready": true}` so the client asserts
   on the fact rather than on an unconditional `ok`.

The ordering matters as much as the error code: flipping the completion flag first is
what makes a later pool failure invisible and unrecoverable — the device never asks
again because it already "succeeded".

A third silent path needs the same treatment: `_auto_provision_default_pool` returns
early with only a log line when `child.child_profile_id is None` (`family.py:900-906`).
That is a device that can never earn time, reported as fully set up. Under the new
contract a missing profile is a failure response, not a no-op.

## Copy

Final step: title "Two quick things and you're done", subtitle "Both are needed before
Evlin can start."

Card A: eyebrow "SCREEN-TIME TRACKING", title "Turn on tracking", body "Tap below and
choose **All Apps & Categories** so Evlin can count screen time and award earned
minutes.", button "Select All Apps & Categories" → done state "Tracking enabled".

Card B: eyebrow "PARENT PIN", title "Hand the phone to your parent", body "A parent
creates a 4–8 digit PIN that locks Parent Controls on this phone.", button "Create
Parent PIN" → done state "PIN created".

`EvlinPINGateView` copy changes:
- title on the create path → "Create your Evlin Parent PIN" (disambiguates it from the
  iOS Screen Time passcode set one step earlier).
- subtitle → "4–8 digits. Your child can't change managed apps without it."
- add a footnote under the keypad: "You can view this PIN anytime on your own phone:
  Settings → <kid> → this device."

`childSafetyLock` copy changes (the preceding step): title → "Set the iOS Screen Time
Passcode", and open the body with "This is the iOS Screen Time passcode — different from
the Evlin Parent PIN you'll create next."

Retry states: PIN upload failure → "Couldn't save the PIN. Retry"; all-set failure →
"Couldn't finish setup. Retry".

Primary button "Finish setup"; disabled hint "Finish unlocks when both are done".

## Sequencing and dependencies

- **Blocked by the metering freeze.** The pool work tree is frozen pending baseline
  verification; this feature must not be implemented into that tree until the freeze
  lifts and the baseline is taken.
- **FIX-K is a hard deployment prerequisite, not a co-release.** `PUT
  /child/device/parent-pin` runs over the child endpoint surface, which today derives
  device identity from a self-asserted body/header UUID. A recoverable PIN must not
  cross that surface until identity comes from a verified credential — "ship together"
  still leaves a window where the endpoint is live and unauthenticated. The endpoint
  ships only after FIX-K is deployed.

## Resolved decisions

- **Keep `childSafetyLock`.** The two controls sit at different security layers (iOS
  Screen Time passcode vs. Evlin's local edit gate), so neither merging nor dropping is
  right. Disambiguate by title instead: "iOS Screen Time Passcode" vs. "Evlin Parent
  PIN", with the explicit contrast line in the copy above.

## Testing

- Unit: recovery finds a known 4/5/6-digit PIN against a real `EvlinPINStore` blob,
  returns nil for a corrupted one, and resumes from a persisted cursor instead of
  restarting; the gate stays disabled until both cards report done; the Finish sequence
  runs `persistPairedIdentifiers` → `markChildAllSet` → flip, and a `markChildAllSet`
  failure leaves the step on screen with Retry.
- Backend: value + status round-trip through the parent read path; the child surface
  returns status and never the value; `^[0-9]{4,8}$` violations return 422; the upload
  is idempotent; unpair, cross-family re-pair, and account deletion all clear the PIN
  and reset the status.
- Backend `child-all-set`: pool-provisioning failure returns non-2xx and leaves
  `child_onboarding_complete` false; a retry against a child that already has a pool
  succeeds and sets the flag; a successful call returns
  `all_set: true, default_pool_ready: true` and the pool exists.
- Device: clean onboarding ends on the new step, both cards complete, the PIN appears on
  the parent phone, and the default pool exists afterwards (proving `markChildAllSet`
  landed); a pre-existing PIN appears after upgrading and opening the kid app once.
- Benchmark: measure a full 6- and 8-digit sweep on a real device before deciding
  whether 7–8 digit auto-recovery ships.
