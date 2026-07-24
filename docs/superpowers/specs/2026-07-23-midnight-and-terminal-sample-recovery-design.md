# Midnight and Terminal Sample Recovery Design

## Goal

Fix two true-device failures without weakening identity, stale-command, or
physical-plausibility fences:

1. earned Total Pool and Device Limit must continue on the canonical day after
   midnight; and
2. a per-app terminal threshold already applied locally must eventually reach
   the backend even if the parent changes or clears the rule immediately after
   the local effect.

## Confirmed Evidence

### Canonical rollover

The iPad received `intervalDidEnd` for its active
`evlin.earned.v2.<route-id>` at canonical midnight. Its active route and epoch
still belonged to the previous usage date. The current generation's route for
the new date existed, but its install work was terminal
`route_superseded`. No `RolloverEffectsWork` or v2 handoff existed.

The production DAM interval callback does not prepare canonical rollover work.
App/DAM recovery can recover existing rollover work, but no production caller
creates that work. The production recovery composition also does not provide
the rollover local-effect reset adapter.

During generation activation, future routes are installed before the candidate
generation becomes active. `hasCurrentRegistrationProvenance` authorizes only
the active generation or the handoff's exact current-day route, so the
candidate generation's future routes are incorrectly terminalized before the
generation becomes active.

### Per-app terminal sample

The iPad recorded a local 15-minute terminal threshold and applied the TikTok
limit shield. The backend received only the preceding 11-minute threshold, so
the parent displayed `11/15` while the device was correctly locked.

Local application is synchronous and durable. Transport begins afterward from
an asynchronous extension task. A subsequent clear/recreate makes the old rule
non-current; journal recovery and the backend then reject or discard the
already-applied terminal sample.

## Design

### 1. Installation authority is not callback authority

A `futurePlanned` route in the current activation handoff's candidate
generation may be installed when all of these immutable fields match:

- owner child device;
- candidate generation;
- active handoff;
- generation policy/selection/enforcement identity;
- bounded horizon usage date; and
- active, non-retired epoch and planned route.

This permission authorizes only Apple schedule installation. It does not make
the future route eligible to accept callbacks. Callback accounting continues
to require the existing active/dual-active route provenance.

Install work must not become terminal merely because its generation has not
completed activation. A truly retired, replaced, foreign-owner, or
out-of-horizon route remains terminal.

### 2. Canonical rollover has one idempotent preparation operation

Add a shared production operation that:

1. derives canonical today from the persisted active generation timezone;
2. returns without mutation when the active route already belongs to today;
3. prepares exactly one `RolloverEffectsWork` and exact old-to-new handoff;
4. replaces a previously terminalized new-day install work with fresh work
   carrying the same immutable route identity where safe, or creates a fresh
   replacement route when the old identity is no longer recoverable; and
5. invokes existing recovery until the new route is daemon-readback verified
   before retiring the old route.

The operation is invoked from:

- earned v2 `intervalDidEnd`;
- app foreground/poll recovery; and
- DAM recovery.

All triggers are idempotent and converge on the same persisted work ID.

### 3. Production rollover reset adapter

Production composition supplies the existing rollover state machine with a
local reset adapter for its declared effects. Each effect is idempotent and
owner/date fenced. The adapter may clear only the named old-day state; it must
not globally stop DeviceActivity monitoring or remove unrelated manual,
task-pause, reflection, block, or per-app sources.

### 4. A local receipt creates immutable transport authority

Before `localReceipt` exists, current-rule and owner checks remain unchanged.
An unapplied stale callback has zero local and network effects.

After an exact callback has been durably applied and its `localReceipt` has
been read back, the journal item becomes a physical-usage outbox entry. It may
be transported after that rule is cleared or replaced when:

- the current child-device owner still matches;
- callback identity, rule ID, ordering token, usage date, event name, arm ID,
  and receipt are unchanged;
- the usage request remains idempotent; and
- physical plausibility validation still succeeds.

Rule changes may remove enforcement authority, but cannot erase already
observed physical usage.

### 5. Backend acceptance of delayed historical usage

The backend accepts an idempotent, exact-token delayed sample for a disabled
historical rule. It records usage only; it never re-enables or re-applies the
old rule. Unknown rules, mismatched tokens, foreign devices/families, malformed
dates, and implausible thresholds remain rejected.

Parent aggregation continues to group physical usage by device, bundle, and
usage date across historical rule IDs. Therefore the terminal sample advances
the display from `11/15` to `15/15` without reviving the disabled rule.

## Required Tests

1. Candidate-generation future routes install before activation and never gain
   callback authority.
2. Retired/foreign/out-of-horizon routes still become superseded.
3. DAM midnight and cold app reopen prepare the same rollover work.
4. A terminalized current-day install is repaired once and daemon verified.
5. Rollover reset never performs a global DeviceActivity stop.
6. A locally applied per-app terminal sample survives clear/recreate and
   uploads once.
7. An unapplied stale sample is discarded with zero network effects.
8. Owner switch rejects the historical sample.
9. Backend accepts exact historical token usage but rejects token mismatch.
10. Parent bundle/day aggregation includes the delayed terminal sample.

## Release Gate

Automated tests prove state-machine behavior. Completion still requires a fresh
true-device run:

- cross canonical midnight with the app force-quit and observe both earned
  bars advance on the new day;
- apply a one-minute per-app rule, reach the threshold, immediately change the
  rule, and verify local lock plus parent terminal usage converge; and
- repeat on both enrolled child devices.

