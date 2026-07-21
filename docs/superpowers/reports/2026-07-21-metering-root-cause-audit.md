# Metering Root-Cause Audit - 2026-07-21

Status: INVESTIGATION IN PROGRESS. No release claim. No production fix is approved by this document.

Repositories:

- iOS: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-iOS`
- Backend: `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend`

## Evidence Standard

A cause is marked PROVEN only when the production data path and either durable
device/backend evidence or a deterministic reproduction agree. Static suspicion
alone is not enough. Apple DeviceActivity daemon behavior remains unproven until
read back on a paired physical device.

## Proven Findings

### P1 - A same-day SQL reset is not a real meter reset

`EarnedTimeStore.reconcileAcceptedUsageLocked` deliberately applies
`max(local, server)` on the same canonical usage date. A backend change from 120
to 0 is therefore rejected by the device. Apple also exposes no API that clears
an existing DeviceActivity event's same-day counter.

The backup `/tmp/evlin-db-reset-1784650843.sql` proves this happened in the
physical session. After the SQL reset, the first accepted event was `t65`, then
`t70`, `t75`, ... `t120` at roughly five-minute intervals. The device retained
an approximately 60-minute local basis and continued correctly from it; it did
not restart from zero.

Consequence: deleting/resetting SQL rows can change the P-side display briefly,
but cannot reset an already-running K-side counter. A legitimate same-day reset
requires a named generation replacement plus an explicit from-now base.

### P2 - `unshield_all` can kill every Evlin DeviceActivity monitor

The main-app `ActionExecutor` handles `.unshieldAll` by calling
`cancelAllScheduled()`, which calls the no-argument
`DeviceActivityCenter.stopMonitoring()`. That API stops all activities owned by
Evlin, not only timed shield activities. It therefore removes:

- legacy earned Total Pool / Device Limit activities;
- per-app v2 activities;
- legacy device-total activity;
- command heartbeat activity;
- timed shield/block activities.

The operation then clears shield records but does not invalidate the legacy
earned active generation, per-app arm provenance, or applied receipt. Subsequent
recovery can therefore conclude that the missing daemon monitor is already
armed:

- legacy earned sees the same active generation and logs `already-armed`;
- per-app sees a durable applied receipt and no pending owner work;
- per-app's planner compares only activity names when it is invoked, not the
  daemon's complete configuration.

This is a complete causal chain for "unlock/reset, then all bars stop".

Delivery makes the bug intermittent. The NSE implementation of `unshield_all`
only clears ActiveLockStore and does not stop monitors. If NSE confirms first,
the command leaves the backend pending queue and the main app does not execute
the destructive branch. If NSE cannot apply and the foreground poller executes
the same command, all monitors are stopped. The same user-level action can thus
have different meter effects depending on which delivery path wins.

Reflection resolution/cancel and chat/REST "unlock all" emit `unshield_all`.
The Profile green/red child-wide button is different: it emits a saved-list
`unshield` scoped to `unlock_sources=[manual]`; that normal button does not call
the global stop branch.

### P3 - The foreground poll restarts the legacy device-total activity every 10 seconds

Every active `/child/state` response invokes `startLegacyDeviceTotal()`.
`BigKidActivityScheduler.start()` unconditionally calls `startMonitoring` on
the fixed `evlin.bigkid.freeplay` activity. There is no daemon readback or
stable-active no-op. Existing tests cover one active poll and
active/disabled/active, but not two stable active polls.

This is a real churn defect. It can prevent its own five-minute chunk from
reaching threshold and adds unnecessary DeviceActivity XPC traffic.

It is not, by itself, proven to be the direct source of the current SQL-backed
Total Pool/Device Limit bars. `/child/time-consumption` mutates the in-memory
BigKidStore, while `/child/state` overrides minutes with the SQL earned runtime
when available. It must be removed or made idempotent, but it must not be used
as a substitute explanation for the authoritative earned ladder without
physical evidence.

### P4 - Task/reflection pause can permanently consume legacy earned thresholds

The currently paired database devices are protocol v1. On a v1 device:

1. A task/reflection gate closes and `usageCountingAllowed` becomes false.
2. The legacy earned DeviceActivity monitor remains installed.
3. If Apple fires a threshold while paused, the extension returns before
   recording or reporting it.
4. Apple does not refire that already-reached threshold.
5. When the gate reopens, `ensureEarnedArmed()` sees the unchanged active legacy
   generation and skips as `already-armed`.
6. `rearmOtherUsageCountersFromStoredPolicy()` resumes per-app arms but does not
   replace the legacy earned generation.

Result: Total Pool/Device Limit can freeze after task/reflection activity.

Phase 3's v2 conservative successor protocol was designed to close this exact
class of gap, but it is not active on the tested devices.

### P5 - The rebuilt whole-device v2 protocol is not active on real devices

Local database evidence showed all 43 devices at
`metering_protocol_version=1`; both Giannis devices were v1. Backend setting
`METERING_EPOCH_ADVERTISED_VERSION` defaults to 1 and local `.env` did not
override it. The registration endpoint rejects an unadvertised v2 registration.
Neither physical App Group contained `metering-device-epoch-store-v4.json`.

Therefore the recent Total Pool/Device Limit physical tests exercised the old
v1 ladder, not the Phase 2/3 v2 horizon, rollover, and successor machinery. It
is invalid to claim Phase 3 fixed the physical behavior until one device is
locally advertised, registered, verified, activated, and observed as v2.

### P6 - Legacy earned mid-day rearm can remove its own earned shield

`intervalDidStart` treats every authorized legacy earned activity start as a
daily reset and calls `resetEarnedTimeShields` with no day-key guard. Legacy
replacements use an arm-from-now schedule, so a policy/generation replacement
mid-day can invoke the same callback and strip `.earnedTime` as if midnight had
occurred. The per-app legacy reset path has a same-day guard; earned does not.

This is a separate explanation for "the bar exhausted but the app became
unlocked after rearm" on v1.

### P7 - Current connected devices are not valid test baselines

Read-only CoreDevice snapshot at approximately 16:57 local time:

- Ruoping iPad: app defaults contain `appMode=child` but no child device ID;
  App Group records `ownerMismatch` and `family_removed` for the old device.
- Liam iPhone: app defaults contain the old child device ID but no `appMode`;
  App Group records earned arming skipped because `appMode=(empty)`.

Neither device can currently prove meter behavior. One device must be explicitly
re-paired before the next experiment.

## Per-App P0 - Proven Boundary, Remaining Unknown

Historical database samples prove the old per-app implementation fired on real
hardware (for example WhatsApp t15/t30/t45/t60). Phase 4 v2 commands later
reported `confirmed/applied` and an arm ID but produced no callback or usage
sample.

The word "applied" is not daemon proof:

1. `AppLimitPlanner.armV2Locked` calls `startMonitoring` and treats "did not
   throw" as success.
2. It persists Evlin's own arm provenance/receipt.
3. The later `currentAppliedReceipt` readback reads that Evlin receipt, not
   `DeviceActivityCenter.schedule(for:)` or `events(for:)`.
4. Stable reconciliation compares only daemon activity names. It does not compare
   schedule, event names, application/category/web tokens, thresholds, or
   `includesPastActivity`.

The whole-device dated installer does perform exact daemon readback of all those
fields. Per-app does not. Therefore per-app can acknowledge success while Apple
has missing or different configuration.

Static tracing does not support the hypothesis that per-app is restarted every
10-second state poll. Once the durable owner receipt is committed, poll-completion
recovery normally performs readback/confirmation without rerunning the planner.
Per-app churn remains a physical question, not a proven cause.

## Required Single-Variable Physical Experiment

Do not change production behavior before this experiment.

1. Re-pair exactly one K device and verify both `appMode=child` and the current
   child device ID in app and App Group state.
2. Add a DEBUG-only, rate-limited, off-main diagnostic readback. Capture for each
   `evlin.limit.v2.*` activity:
   - start call timestamp/count;
   - arm ID and activity name;
   - actual schedule;
   - actual event names;
   - application/category/web token counts or digests;
   - thresholds and `includesPastActivity`;
   - expected-vs-actual mismatch reason.
3. Read back once after arm, once after a configuration change, and once at a
   low-frequency audit interval. Never read the full daemon state every 10
   seconds; synchronous XPC previously caused a watchdog termination.
4. Use one app with zero usage that day and one freshly selected token.
5. Run old legacy window and v2 per-rule registrations with the same token,
   schedule, threshold, and `includesPastActivity`; change only the activity/event
   topology. Record callbacks for each.
6. Record every start/stop call during the minute. This directly confirms or
   rejects the per-app churn hypothesis.

Only after this A/B can the remaining per-app cause be promoted from UNKNOWN to
PROVEN.

## Symptom Mapping

| Reported symptom | Proven current explanation |
|---|---|
| Bar moves then freezes | v1 gate consumes thresholds; global stop leaves stale local "armed" state |
| Midnight resets but apps do not lock | v1 arm-from-now monitor ends; no future horizon while app is killed; v2 not active |
| Bar never starts | invalid identity/readiness, missing daemon monitor hidden by local receipt, or v1 monitor killed globally |
| Next day bar never starts | v1 requires process wake/replacement; v2 eight-day routes are not activated |
| Reports too much usage | same-day SQL reset is rejected; retained local base is added to new raw thresholds |
| One device appears to affect another | shared pool is intentionally shared; device cap attribution remains per-device. The captured incident had samples only from the iPhone and zero iPad device-day usage |
| Lock/unlock seems to break counting | normal manual saved-list button is meter-neutral; `unshield_all` through main-app polling is destructive |

## No-Claim Boundary

The following statements are not yet justified:

- "all three pools work";
- "per-app is fixed";
- "Phase 3 works on device";
- "includesPastActivity=true is the fix";
- "10-second poll churn explains all three bars".

Release requires automated invariants plus paired physical evidence for Total
Pool, Device Limit, per-app limit, gate pause/resume, same-day reset generation,
midnight rollover, app termination, manual-only lock/unlock, and two-device
attribution.

## Cross-Review Addendum - 2026-07-21

Claude independently verified that the v2 local ratchet can reach `.v2` only
after the dual-active activation acknowledgement and complete install phase.
That static finding agrees with the physical App Group and database evidence:
the tested devices never completed that promotion.

Claude also disclosed that three diagnostic `unshield_all` commands were
injected during the overnight session. Because the foreground executor's
`unshield_all` branch calls the no-argument `stopMonitoring()`, any command that
reached the foreground path invalidated the meter state for that run. Those
runs are contaminated and must not be used to attribute a recovery or freeze
to `includesPastActivity`, rearming, or a particular protocol implementation.

The earlier statement that changing `includesPastActivity` made the two earned
bars work is therefore withdrawn as a causal claim. The only admissible fact is
that movement was observed after several simultaneous changes. The diagnostic
build described below must repeat the observation with one variable changed at
a time.
