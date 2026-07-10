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
date.

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

For every successful sample POST, iOS decodes `counted` and the server
`estimated_minutes`:

- `counted: true`: retain the monotonic maximum of the local and server
  accepted estimates.
- `counted: false`: replace the local estimate and re-arm offset with the
  server estimate, record a `backend_counting_paused` diagnostic, and do not
  enqueue a retry.

The explicit flag avoids treating an out-of-order but counted response as a
rejection. Network failures and non-success statuses retain the existing retry
behavior.

## Failure Handling

- Missing optional runtime state never clears a previously valid policy.
- Invalid or incomplete runtime values are ignored and diagnosed; they do not
  arm a zero/negative ladder.
- A paused sample is never retried, because later billing would charge usage
  that occurred while the clock was intentionally stopped.
- A network failure remains retryable and does not alter the accepted local
  estimate.
- The server remains the authority for usage date and timezone.

## Tests

Backend tests must prove:

1. `/child/state` returns `usage_counting_allowed=false` for an active
   reflection and true after resolution.
2. Runtime state returns exact pool, explicit/fallback cap, remaining, estimate,
   canonical usage date, and timezone.
3. A paused sample returns HTTP 200 with `counted=false` and creates no sample
   or day rows.
4. A normal sample returns `counted=true` and persists the ledger.

iOS tests must prove:

1. New child-state fields decode through `JSONDecoder.bigKid`; missing fields
   use the compatibility fallback.
2. Reflection presence disables counting in the fallback path.
3. A poll writes exact runtime policy before attempting a re-arm.
4. An allowed poll retries `armIfReady` after identity/list readiness changes,
   while the arm signature prevents repeated DeviceActivity replacement.
5. `counted=false` reconciles estimate and offset to the server value without a
   retry; counted and out-of-order responses preserve monotonic accepted usage.
6. Existing task-pause stop/re-arm tests remain green.

## Deployment And One-Time Recovery

Deploy the backend first because all new response fields are additive. Then
install the fixed iOS build on the child device.

After both sides are running, perform a one-time local recovery for
`gruoping@gmail.com`:

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
