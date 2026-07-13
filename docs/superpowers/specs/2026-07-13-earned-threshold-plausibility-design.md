# Earned Threshold Plausibility Design

**Date:** 2026-07-13

**Authority:** `LOCK_BEHAVIOR_BOUNDARIES.md` G-20 / R-15. This is the stage 1.1 safety patch discovered during the stage 1 physical acceptance run. It executes before stage 2 and does not replace G-14.

## Problem

On Ruoping's iPad running iPadOS 26.4.2, the earned-time ladder behaved normally through 50 minutes, then delivered thresholds 55 through 120 in two bursts over six seconds. The backend correctly treated those callbacks as authoritative and exhausted Giannis's 120-minute pool even though that amount of foreground use was physically impossible.

The current scheduler uses the legacy `DeviceActivityEvent` initializer. It does not explicitly set `includesPastActivity` to `false`. Apple documents that past activity can contribute to a newly monitored event, and iOS 26 also has a reported regression where callbacks may fire immediately even when past activity is disabled.

This is not a parent UI bug. The device callback, local estimate, backend ledger, and parent summary all converged on the same false value.

## Goals

1. A newly armed earned-time generation must not count activity from before it was armed.
2. A callback must never advance counted usage faster than physical wall-clock time permits.
3. An implausible callback must not update the device estimate, reach the backend ledger, or apply a local shield.
4. The backend must independently reject implausible samples from clients that send generation timing metadata.
5. Existing clients and lifecycle data remain wire-compatible during rollout.
6. Per-app limit behavior remains unchanged.

## Non-Goals

- Replacing `DeviceActivity` with Screen Time reports.
- Correcting Apple's private Screen Time database.
- Making force-quit metering exact when iPadOS stops or corrupts callbacks.
- Deploying the backend to Render in this work item.
- Changing pool, device-cap, task-pause, reflection, or manual-lock precedence.

## Considered Approaches

### A. Explicitly disable past activity only

Construct every earned `DeviceActivityEvent` with `includesPastActivity: false`.

This is required but insufficient. Apple has reports of immediate callbacks on iOS 26 even with the flag set, so this cannot be the only correctness boundary.

### B. Device-only plausibility guard

Reject callbacks that exceed elapsed wall-clock time on the iPad.

This prevents local false locks, but an old or compromised client can still poison the backend and parent summary. It also leaves the server unable to distinguish a legitimate delayed sample from an impossible one.

### C. Layered guard (selected)

Explicitly disable past activity, attach generation timing metadata to every sample, reject impossible callbacks before any local mutation, and repeat the same validation on the backend.

This provides the smallest complete boundary. Device enforcement fails open on bad OS callbacks, while the backend remains authoritative for accepted usage.

R-15 validation runs before R-3. R-3's lock-first reconciliation applies only after a callback is physically plausible; an implausible callback is input corruption and never becomes a lock decision.

## Device Design

### Generation timing

`EarnedActivityGeneration.Generation` gains an optional UTC `armedAt` timestamp. New generations always populate it immediately before `startMonitoring`. Older persisted generations decode with `armedAt == nil` and are replaced by the main app before their callbacks are trusted.

The lifecycle format remains backward-decodable. A missing `armedAt` is a migration signal, not a reason to crash or discard identity state.

### Event construction

The deployment target is iOS 17.6, so earned events use the iOS 17.4 initializer directly:

```swift
DeviceActivityEvent(
    applications: selection.applicationTokens,
    categories: selection.categoryTokens,
    webDomains: selection.webDomainTokens,
    threshold: DateComponents(minute: minutes),
    includesPastActivity: false
)
```

Per-app events are outside this change.

### Plausibility rule

For bucket size `B = 5`, generation offset `O`, arm time `A`, and callback time `T`, the maximum trusted cumulative estimate is:

```text
maximumTrusted = O + floor(max(0, T - A) / 60 seconds) + B
```

A callback with `adjustedEstimate <= maximumTrusted` is plausible. A callback before `armedAt`, with missing timing on a newly generated activity, or above the ceiling is implausible.

The one-bucket allowance absorbs callback scheduling jitter and permits the first 5-minute event. It does not permit a 50-to-120 jump after three elapsed minutes.

### Rejection behavior

An implausible callback:

- does not call `recordLocalThresholdEstimate`;
- does not enqueue or POST an earned sample;
- does not apply an earned or device-cap shield;
- writes a bounded App Group diagnostic containing generation, raw threshold, adjusted threshold, arm time, callback time, and ceiling;
- leaves the current generation authorized so later callbacks are also evaluated, but does not automatically re-arm from inside the extension.

Fail-open undercount is intentional. Automatically re-arming after a false callback can create a loop that manufactures five minutes on every re-arm. Same-day recovery requires a normal main-app policy/identity re-arm or a fresh Screen Time selection; midnight creates a new generation normally.

## Sample Protocol

`POST /child/earned-time/sample` gains two optional fields:

```json
{
  "generation_armed_at": "2026-07-13T17:00:00Z",
  "generation_offset_minutes": 25
}
```

New iOS builds always send both. They are optional so the backend can deploy before iOS and old TestFlight builds continue to work.

When both fields are present, the backend applies the same five-minute plausibility rule using `observed_at`. If one field is present without the other, or the estimate exceeds the ceiling, the route returns HTTP 200 with the current authoritative snapshot, `counted=false`, and `warning="implausible_threshold"`. It does not insert a sample, advance either ledger, or queue an auto-lock.

When neither field is present, legacy ingestion behavior remains unchanged. This compatibility window ends only in a separately approved rollout.

No database migration is required; the timing fields are validation metadata and the existing raw payload may retain them for accepted samples.

## Reset And Acceptance

Before resetting, preserve the current App Group plist and database evidence. Reset only Giannis's 2026-07-13 local test data:

- delete today's earned samples, device-day row, child-day row, and test-generated earned lock command state in one local database transaction;
- preserve the active pool config, family, child, device, measurement selection, and locked-set tokens;
- invalidate the old device generation and clear today's accepted estimate, offset, backend remaining cache, threshold diagnostic, and earned shield source;
- install and launch the new build once so it creates a fresh generation.

Acceptance uses two runs:

1. **Background:** launch Evlin, wait for an armed generation, background it, use Apple Maps for 6-10 minutes, and verify a 5- or 10-minute accepted sample plus matching parent remaining time.
2. **Force quit:** after a fresh accepted baseline, force quit Evlin, use Apple Maps for another 6-10 minutes, do not reopen Evlin, and verify the backend directly. If iPadOS emits an impossible burst, verify it is rejected and no false lock occurs. Exact counting is not promised when the OS callback stream is corrupt.

## Tests

### iOS

- earned events explicitly set `includesPastActivity == false`;
- generation timestamps round-trip and legacy lifecycle data still decodes;
- an old generation without `armedAt` forces replacement;
- threshold at `offset + elapsed + 5` is accepted;
- threshold above that ceiling is rejected;
- rejected threshold does not mutate estimate, queue a sample, or shield;
- normal 5-minute progression remains monotonic;
- per-app regression suites remain green.

### Backend

- a plausible metadata-bearing sample is counted;
- an impossible jump returns 200, `counted=false`, and the warning without inserting rows or commands;
- partial generation metadata is rejected as uncounted;
- legacy samples without generation metadata retain current behavior;
- task/reflection metering gates still take precedence and return the authoritative snapshot.

## Rollout

1. Implement and test backend and iOS locally.
2. Complete the local iPad reset and both physical acceptance runs.
3. Commit locally on `calendar-in-chat`.
4. Do not push or deploy Render without explicit approval.
5. For production, deploy the backward-compatible backend first, then ship iOS.
