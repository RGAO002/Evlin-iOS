# Per-App Limit Midnight Rollover Design

**Date:** 2026-07-26

## Problem

A recurring per-app `DeviceActivity` remains installed across midnight, but its
persisted `AppLimitArmProvenance.usageDate` remains on the installation day.
`AppLimitCallbackValidator` compares that stale date with the current canonical
usage date and rejects every new-day callback as `stale_provenance`.

The Liam iPhone state captured on 2026-07-26 proves the failure:

- Facebook activity:
  `evlin.limit.v2.19e4f2c6-6fa1-43d9-b853-ff72ea55e8d9`
- persisted usage date: `2026-07-25`
- current canonical usage date: `2026-07-26`
- the activity remains installed, so the main app sees no missing activity to
  repair while it is not running

Earned Total Pool and Device Limit are outside this fix. Their v2 implementation
uses preinstalled dated routes and the same device accepted a 2026-07-26 earned
sample after canonical midnight.

## Decision

Keep the existing recurring Apple monitor installed. At its v2 per-app
`intervalDidStart` callback, atomically roll the persisted accounting interval
to the current canonical usage date without calling `startMonitoring`.

The rollover:

1. resolves exactly one current set slot by the callback activity name;
2. verifies owner, rule revision, recurring schedule, token digest, and forward
   canonical-date movement;
3. preserves the Apple activity name and monitor arm ID;
4. writes the new usage date and callback start time;
5. resets base accepted, raw threshold, and ignored threshold to zero;
6. preserves whether counting is paused;
7. clears the day-scoped authoritative used snapshot to zero;
8. is idempotent when `intervalDidStart` repeats for the same day.

Apple documents that a repeating schedule recurs until monitoring stops and
that `intervalDidStart` is the extension callback for a new interval. The
extension is therefore the correct owner for the local day transition. It must
not try to replace the monitor: physical capability testing did not prove
extension-origin replacement reliable.

## Daily Effect Identity

The Apple activity and event names remain stable across recurring intervals, so
the local effect journal must include `usageDate` in
`AppLimitEffectKey.storageKey`. Otherwise day D and D+1 threshold `t5` collide
under the same arm ID and the second day is silently deduplicated.

Legacy persisted effect keys remain readable: an absent `usageDate` retains the
old storage-key format. New callbacks always write a canonical usage date.
Backend sample IDs already include `usageDate`, so their day identity remains
compatible.

## Shield Reset

After a successful or same-day-idempotent v2 interval transition, the extension
runs the existing limit-only day reset. It removes only `.limit`; manual,
earned-time, task-pause, reflection, and block sources remain untouched.

The existing day-key guard keeps repeated or mid-day `intervalDidStart`
callbacks harmless.

## Recovery

- If the extension misses midnight because the device is off, the next
  main-app owner recovery still creates the existing fresh replacement arm.
- If the extension callback repeats, the second transition is a no-op.
- If a callback arrives for an earlier date, rollover rejects it and changes
  nothing.
- Old high-threshold callbacks arriving immediately after rollover are rejected
  by the existing physical elapsed-time upper bound.
- A process death cannot create a second Apple monitor because rollover never
  calls `startMonitoring`.

## Tests

Automated tests must prove:

1. a D provenance rejects a D+1 callback before the fix;
2. D+1 `intervalDidStart` advances local day state without scheduler calls;
3. the first physically plausible D+1 callback is accepted and journaled;
4. equal threshold numbers on D and D+1 create distinct effect keys;
5. repeated same-day start is idempotent;
6. backward-date start fails closed;
7. paused state survives rollover while day high-waters reset;
8. the v2 interval entry invokes limit-only shield reset;
9. existing earned, planner, pause/resume, and command convergence suites remain
   green.

## Non-Goals

- No backend schema or route changes.
- No Total Pool or Device Limit changes.
- No extension/NSE `startMonitoring`.
- No policy, token, lock-precedence, or notification-copy changes.
- No production deployment or TestFlight upload.
