# Earned-Time Poll Self-Heal Design

**Date:** 2026-07-10

## Problem

A newly paired child can have working per-app limits while Total Pool and
Device Limit never move. The confirmed `gruoping@gmail.com` incident had this
cross-layer state:

- PostgreSQL had an active 120-minute earned-time config but no samples or day
  rows.
- The child device had a measurable selection and a valid Locked set.
- The extension reached 10 minutes and received HTTP 200 from
  `POST /child/earned-time/sample`, but the backend intentionally skipped the
  write because an onboarding reflection was active.
- iOS treated every 2xx as counted, retained a 10-minute local estimate, and
  did not know that the backend ledger remained at zero.
- A child-device identity transition cleared the stored 120-minute pool/cap.
  A later re-arm fell back to 60 minutes and then armed a 50-minute ladder
  after subtracting the incorrect 10-minute offset.

The systems disagree because the backend owns the reflection-aware metering
gate while iOS derives its gate only from tasks, the sample response does not
say whether it was counted, and `/child/state` cannot restore the exact policy
that identity teardown deliberately clears.

A second confirmed incident on 2026-07-11 exposed the monitor-lifecycle side of
the same subsystem. A newly paired iPad emitted 17 thresholds from `t5` through
`t85` in eight minutes, including out-of-order thresholds in the same second.
Its App Group log showed an old-to-new device identity transition followed by
`intervalDidStart` roughly every eleven seconds. The fixed
`evlin.earned.budget` activity name was repeatedly reused across identities and
re-arms, allowing DeviceActivity to replay usage accumulated before onboarding.
The backend correctly attributed those samples to the new iPad; the samples
themselves were false.

## Goals

1. Use one backend-authoritative metering gate for unfinished tasks and active
   reflections.
2. Make a successful-but-not-counted sample explicit on the wire.
3. Let the existing child-state poll restore exact pool/cap/remaining policy
   and re-arm after identity changes, missed config commands, or delayed Locked
   set publication.
4. Preserve the product rule that time used during a task pause or reflection
   does not count toward Total Pool, Device Limit, or Per-App Limit.
5. Reset the affected local test account once after the fix; do not ship a
   general automatic history-correction or migration feature.
6. Give every earned monitor installation a fresh generation identity so a
   previous account, device identity, or ladder cannot replay thresholds.
7. Keep backend-accepted usage separate from the offset owned by the currently
   running raw ladder.
8. Make multi-device rows show effective usable time, not a cap-only number
   beside a shared-pool-clamped progress bar.

## Non-Goals

- Do not change the five-minute earned-time threshold granularity.
- Do not change per-app daily reset semantics or app-limit enforcement.
- Do not change lock precedence, task-lock behavior, or reflection UX.
- Do not modify remote Render data as part of local verification.
- Do not infer accepted usage from HTTP status alone.

## Considered Approaches

### A. Backend-authoritative state in the existing poll (chosen)

Extend `/child/state` with the authoritative metering gate and current
earned-time runtime policy. Extend the sample response with `counted`. iOS
stops/re-arms from that state every poll and reconciles a rejected local
estimate to the server snapshot.

This fixes all three failure boundaries and reuses the existing ten-second
poll. The fields are optional on iOS so a newer client can still decode an
older backend during deployment.

### B. iOS-only reflection gating

Teach iOS to include `reflectionRequest` in its local gate. This prevents the
common case but leaves a race before the next poll, preserves ambiguous 200
responses, and cannot recover an exact pool/cap after identity teardown.

### C. Backend-only response changes

Return a non-2xx or a new marker for skipped samples. This removes the false
success but does not stop the local DeviceActivity ladder or restore cleared
policy. Retrying paused usage would also violate the stop-the-clock rule.

## Wire Contract

### `GET /child/state`

Add these fields to `ChildStateResponse`:

```json
{
  "usage_counting_allowed": true,
  "earned_time_runtime": {
    "usage_date": "2026-07-10",
    "timezone": "America/New_York",
    "daily_pool_minutes": 120,
    "device_cap_minutes": 120,
    "remaining_minutes": 120,
    "estimated_minutes": 0
  }
}
```

`usage_counting_allowed` is computed by the existing backend
`bigkid_usage_gate.usage_counting_allowed`, which already combines persisted
tasks with active reflection state.

`earned_time_runtime` is `null` when no active earned-time config exists. When
present, it is built from the same active config, cap, child day, and device day
used by the parent summary. `device_cap_minutes` is the explicit cap when one
exists, otherwise the daily pool. `remaining_minutes` and
`estimated_minutes` are authoritative server values for the canonical usage
date. In this payload, `estimated_minutes` means the maximum usage threshold
the server has accepted for that device and usage date. It is not a remaining
estimate and it does not include a client-side threshold that is still in
flight.

The iOS fields are optional for rollout compatibility. If
`usage_counting_allowed` is absent, iOS falls back to the conservative local
rule: all tasks complete and no active reflection request. If
`earned_time_runtime` is absent, existing stored policy remains unchanged.

### `POST /child/earned-time/sample`

Add `counted: bool` to `DeviceDaySnapshot`.

- Normal ingest and idempotent replays return `counted: true`.
- A task/reflection-paused request returns the current authoritative snapshot
  with `counted: false` and remains HTTP 200. It is intentionally dropped, not
  queued for later billing.

Keeping HTTP 200 preserves compatibility with existing clients while the new
field removes ambiguity for fixed clients.

## iOS Runtime Flow

For every successful child-state poll:

1. Reconcile the reflection shield from the snapshot.
2. Apply the snapshot to UI state.
3. Persist `earned_time_runtime` into `EarnedTimeStore`: exact pool, exact cap,
   backend remaining, latest accepted estimate, and sync timestamp.
4. Apply the backend-authoritative `usage_counting_allowed` gate.
5. If the gate is false, stop earned, device-total, and per-app counters.
6. If the gate is true, call `EarnedBudgetArming.armIfReady()` and re-arm the
   other usage counters as needed. The existing arm signature makes the
   earned-time call a no-op when the correct ladder is already active.

Calling `armIfReady()` on every allowed poll is deliberate. It closes the race
where identity teardown runs before the Locked set is republished: one poll may
skip because the set is missing, and the next poll self-heals after the async
publication completes. It also restores an acknowledged config command that
was subsequently cleared by identity teardown.

Poll reconciliation is monotonic only within one canonical usage date. The
store records the usage date that owns the accepted estimate. For a poll whose
`usage_date` matches that stored date, the accepted baseline becomes
`max(localAccepted, serverEstimated)`, so a stale read cannot move the odometer
backward before a re-arm. When the canonical `usage_date` changes, the old
baseline does not participate: the accepted estimate resets to the new day's
server estimate. A `counted: false` sample response is the only same-day path
allowed to lower that accepted baseline, because it explicitly removes a
client-side phantom that the server did not count. Neither path mutates the
offset owned by an already-running ladder; the accepted value becomes the
offset only if a replacement ladder is subsequently installed.

`acceptedEstimateMinutes` and `earnedUsageOffsetMinutes` are different state:

- accepted estimate is the backend ledger high-water mark for the canonical
  day;
- usage offset is the base added by the **currently installed** raw ladder.

Sample and poll reconciliation update accepted usage but never mutate the
running ladder's offset. `EarnedBudgetArming.armIfReady()` chooses the accepted
estimate as the new offset only when it actually installs a replacement ladder;
it persists that offset only after installation succeeds. While the app is
backgrounded, the old ladder therefore continues reporting correct cumulative
raw thresholds instead of adding a newly advanced accepted value a second time.

Reconciliation durability does not depend on the Boolean returned by
`UserDefaults.synchronize()`. On physical devices that API can return `false`
even though the App Group suite remains readable and writable. A false return is
recorded as a diagnostic, but it does not by itself reject authoritative runtime
state. The transaction remains protected by the interprocess file lock, identity
validation before and after mutation, and write-then-read verification of every
committed field. A lock failure, identity change, or read-back mismatch still
rolls the mutation back and prevents arming.

Stopping earned monitoring also invalidates its arm signature. A later
false-to-true gate transition must install a ladder even when policy and
selection are unchanged. Config handling and child-state polling share
`EarnedBudgetArming.armIfReady()` as the sole production earned-arm entry point.

Each successful installation uses a new activity name under
`evlin.earned.budget.<generation>`. The active generation is persisted in the
App Group; stop/identity teardown stops both that generation and the legacy
fixed name. The extension recognizes the earned activity prefix. Reusing the
same event names is safe because event state is scoped by the fresh activity.

Stable allowed polls do not replace a running ladder merely because accepted
usage advanced. Policy/date/selection changes, an invalidated signature, or an
explicit force cause a generation replacement. Overlapping refresh requests
coalesce into one follow-up refresh instead of being discarded.

For every successful sample POST, iOS decodes `counted` and the server
`estimated_minutes`:

- `counted: true`: retain the monotonic maximum of the local and server
  accepted estimates for the response `usage_date`.
- `counted: false`: replace the local accepted estimate with the server
  estimate, leave the currently installed ladder offset unchanged, record a
  `backend_counting_paused` diagnostic, and do not enqueue a retry. A future
  replacement ladder uses the reconciled accepted estimate as its new offset.

The explicit flag avoids treating an out-of-order but counted response as a
rejection. Network failures and non-success statuses retain the existing retry
behavior.

## Failure Handling

- Missing optional runtime state never clears a previously valid policy.
- Invalid or incomplete runtime values are ignored and diagnosed; they do not
  arm a zero/negative ladder.
- A poll may lower the accepted estimate only when its canonical usage date
  differs from the stored accepted-usage date. A same-date poll always uses a
  monotonic maximum. Poll reconciliation never mutates the running ladder
  offset.
- A paused sample is never retried, because later billing would charge usage
  that occurred while the clock was intentionally stopped.
- A network failure remains retryable and does not alter the accepted local
  estimate.
- A false `UserDefaults.synchronize()` return is diagnostic only. Read-back
  mismatch remains a hard failure and must preserve the prior committed state.
- The server remains the authority for usage date and timezone.

## Tests

Backend tests must prove:

1. `/child/state` returns `usage_counting_allowed=false` for an active
   reflection and true after resolution.
2. For the same child device UUID, `/child/state.usage_counting_allowed` and a
   concurrent sample response's `counted` value agree while paused and while
   allowed. Both paths must call the shared gate with the device UUID, not the
   child-profile UUID.
3. Runtime state returns exact pool, explicit/fallback cap, remaining, estimate,
   canonical usage date, and timezone.
4. A paused sample returns HTTP 200 with `counted=false` and creates no sample
   or day rows.
5. A normal sample returns `counted=true` and persists the ledger.

iOS tests must prove:

1. New child-state fields decode through `JSONDecoder.bigKid`; missing fields
   use the compatibility fallback.
2. Reflection presence disables counting in the fallback path.
3. A poll writes exact runtime policy before attempting a re-arm.
4. A stale same-date poll cannot lower the accepted estimate; a canonical
   usage-date change resets the accepted estimate to the new server value while
   leaving the running ladder offset unchanged until a replacement succeeds.
5. An allowed poll retries `armIfReady` after identity/list readiness changes,
   while the arm signature prevents repeated DeviceActivity replacement.
6. `counted=false` reconciles the accepted estimate to the server value without
   a retry and leaves the running ladder offset unchanged; counted and
   out-of-order responses preserve monotonic accepted usage.
7. The false gate invokes the existing three-counter stop path: earned ladder,
   device-total activity, and per-app activities all stop. Existing task-pause
   stop/re-arm tests remain green under the reflection-aware server gate.
8. A counted `t5` response can advance accepted usage while the running offset
   remains zero; the next raw `t10` therefore remains 10 while backgrounded.
9. Stop invalidates the signature; false-to-true reinstalls exactly one earned
   ladder. Config and state-poll paths cannot call the scheduler directly.
10. Every real replacement receives a fresh generation activity name, stops
    the prior/legacy names, and the extension recognizes generated names.
11. Stable polls do not re-arm solely because accepted usage advances; policy,
    date, selection, and gate transitions do re-arm with the accepted offset.
12. A refresh arriving during an in-flight refresh causes one coalesced follow-
    up fetch.
13. A device row label and bar both use
    `min(remaining_to_cap_minutes, overall_remaining_minutes)` when both values
    exist.
14. Reconciliation succeeds when the App Group file lock is held, identity is
    stable, writes read back correctly, and `UserDefaults.synchronize()` returns
    false. It still fails and rolls back when read-back verification differs.
15. Per-app counters and rules remain unchanged by this durability fix; the
    shared backend gate still stops and resumes earned, device-total, and
    per-app counters together.

## Deployment And One-Time Recovery

Deploy the backend first because all new response fields are additive. Then
install the fixed iOS build on the child device.

After both sides are running, perform a one-time local recovery for
`gruoping@gmail.com`:

The affected child device was directly inspected on 2026-07-10 and stored
`evlin.baseURL = http://192.168.1.175:8000/api/v1`; this incident and its reset
therefore target the local PostgreSQL database and local backend only. Render
is out of scope. Any later reset against `evlin-backend.onrender.com` is a
separate production operation requiring explicit approval after its account
and device are re-identified.

1. Delete only today's earned-time samples, child-day, and device-day rows for
   this family in the local database.
2. Stop the child app and clear only local earned estimate, offset, backend
   sync, pool/cap, and arm-signature keys.
3. Preserve the measurement selection, Locked set IDs/token data, app-control
   rules, and account pairing.
4. Relaunch the child app. The first state poll restores the 120-minute policy
   and arms from zero.
5. Verify a measured app produces a counted five-minute sample and both Total
   Pool and Device Limit move while Per-App Limit remains functional.

The reset is an operational action for this test account, not committed
product behavior.
