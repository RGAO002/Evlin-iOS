# Metering Epoch Reliability Design

**Date:** 2026-07-15
**Status:** Proposed for joint review before implementation

**Platform floor:** iOS 17.6 and iPadOS 17.6 for the app and all Screen Time
extensions. Capability spikes and release builds must exercise this floor even
when development devices run iOS/iPadOS 26.

**Targeted supersession:** This document replaces only the conflicting
arm/gate clauses in `2026-07-10-earned-time-poll-self-heal-design.md`, the
`+5-minute` formula in `2026-07-13-earned-threshold-plausibility-design.md`, and
the any-source/override Profile CTA behavior in
`2026-07-12-profile-multi-device-lock-design.md`. Their unrelated requirements
remain in force.

## 1. Purpose

Evlin must make Total Pool, Device Limit, and Per-App Limit behave as three
predictable products instead of three loosely related collections of
`DeviceActivity` callbacks.

This design replaces repeated arm/re-arm heuristics with explicit, versioned
metering epochs. It keeps the existing dual-authority architecture:

- the backend owns policy, the durable ledger, shared-pool aggregation, and the
  desired lock state;
- the child device owns immediate offline measurement and enforcement from the
  latest versioned policy snapshot;
- reconciliation converges the two without treating an opaque Apple callback
  as proof by itself.

The design is intentionally not a rewrite of lock storage. `ActiveLockStore`,
source provenance, command receipts, and the identity-switch firewall remain
the execution foundation.

## 2. Confirmed Failure Mechanism

The 2026-07-12 iPad App Group capture contains 207 `earnedPool`
`interval_reset` events between 15:41:23Z and 16:27:55Z, approximately one
reset every 13.5 seconds. The child-state poll runs every 10 seconds.

Two independent values currently make a semantically unchanged arm signature
look different:

1. `EarnedBudgetArming.selectionFingerprint` decodes a
   `FamilyActivitySelection` and re-encodes its `Set` members before hashing.
   Set order is not a stable serialization contract.
2. The arm signature includes `offset`. Every accepted threshold advances the
   offset, so accounting progress itself makes the next poll request a new
   generation.

The loop is therefore self-sustaining:

```text
poll -> replacement arm -> early Apple t5 callback -> +5-minute tolerance
accepts it -> accepted offset advances -> signature changes -> next poll arms
again
```

If Apple immediately emits `t5`, the pool ratchets to exhaustion. If Apple does
not emit it, the baseline resets before five minutes elapse and the bar never
moves. Both symptoms come from the same churn.

The current plausibility rule also grants every new generation five free
minutes:

```text
maximum = offset + floor(elapsedSeconds / 60) + 5
```

That rule is not safe when generation creation is unstable. A test currently
pins a callback received exactly at `armedAt` as a valid `t5`; that expectation
must be reversed.

### 2.1 Seven-Symptom Closure Map

| Reported symptom | Required closure in this design |
|---|---|
| Progress moves and then freezes | Unchanged polls cannot replace a monitor; delayed active-epoch callbacks remain valid. |
| Midnight resets but today's task lock is missing | Database-driven canonical-day task reconciliation plus NSE-primary delivery and device self-heal. |
| Progress never moves from first launch | Explicit readiness state, one stable initial arm, and first-threshold acceptance only after real elapsed use. |
| The next day's progress never moves | Daily epoch rollover is independent of the main app and rejects stale-day state before mutation. |
| Usage jumps or reaches zero far too early | No `+5` allowance, immutable epoch start/base, strict early-callback rejection, and no churn. |
| One device appears to consume another device's cap | Per-device ledger isolation and own-cap-only device progress bars; only the child pool is shared. |
| Unlocking a task lock stops later accounting | A separate day-scoped task bypass reopens the task gate; the Profile manual CTA never touches the gate. |

The per-app regression is covered by the same early-callback and stable-arm
rules, while retaining its separate rule/device ledger.

## 3. Normative Product Contract

### 3.1 Total Pool

- One child profile has one shared daily pool.
- Accepted usage from every enrolled child device is summed once.
- A device contributes only its own accepted cumulative usage for the
  canonical usage date.
- The parent profile bar shows `shared remaining / daily pool`.
- When shared remaining reaches zero, every currently enrolled child device is
  sent an `earned_time` selected-set lock. Each device has an independent
  command receipt and acknowledgement.
- A trustworthy local terminal callback may lock the reporting device
  immediately while offline. Backend fanout later converges all sibling
  devices.

### 3.2 Device Limit

- Each device has its own daily cap; when no explicit cap exists, the pool is
  the fallback cap.
- Device A usage never advances Device B's device-day estimate.
- The device row label may show effective usable time:
  `min(shared pool remaining, own cap remaining)`.
- The device row progress bar always shows only
  `own cap remaining / own cap`. An unused device therefore has a full device
  bar even when a sibling has consumed shared time.
- Reaching a device cap locks only that device with `earned_time` provenance.
  Reaching the shared pool locks all devices.

### 3.3 Per-App Limit

- A per-app rule belongs to one child device and one exact selected app token
  set.
- Its daily usage and lock are independent of Total Pool and Device Limit
  ledgers.
- Reaching the rule budget applies only that rule's `.limit` shield on that
  device.
- Per-app measurement and enforcement callbacks use the same epoch provenance
  and physical-time trust rule as earned-time callbacks.
- Re-arming a partially used rule preserves same-day accepted usage without
  converting that usage into epoch identity.

### 3.4 Five-Minute Accuracy Boundary

Total Pool and Device Limit remain five-minute, monotonic estimates because
Apple exposes threshold events rather than a readable usage counter. Their UI
may move in five-minute steps. "At the limit" means the first trustworthy
callback at or after the configured threshold, not second-level precision.

Per-app limits retain their configured minute budget, subject to Apple's
callback delivery latency.

### 3.5 Task and Reflection Pause

- Unfinished tasks or an active reflection close the accounting gate for all
  three products.
- Closing the accounting gate stops charging time; it does not erase accepted
  usage and does not create a new epoch identity by itself.
- A callback observed while paused cannot mutate the ledger, enqueue a sample,
  or apply a pool/device/per-app limit shield.
- A parent task-bypass action may waive unfinished tasks for the current
  canonical day. While that day-scoped marker is active, the task component of
  the accounting gate is satisfied and counting resumes.
- Reflection remains independently gated and cannot be waived by a task
  bypass.
- The task-bypass marker expires naturally when the canonical usage date
  changes.

### 3.6 Profile Manual Lock Button

The large green/red Profile button is a manual-lock control only:

- green `Lock` adds only the `manual` source to the selected-set record on all
  enrolled devices;
- red `Unlock` removes only the `manual` source from all enrolled devices;
- its color and verb reflect aggregate `manual` provenance only;
- task, reflection, total-pool, device-cap, and per-app locks do not turn this
  button into an automatic-lock remover;
- pressing either state does not change the accounting gate, task suppression,
  reflection state, pool state, device-day state, accepted estimate, running
  offset, epoch, arm signature, or per-app usage;
- pressing either state must not stop, start, replace, or otherwise re-arm a
  usage monitor;
- removing `manual` leaves every automatic source intact.

"Parent explicitly bypasses today's task requirement" is a separate action and
must never be inferred from this button.

When an automatic source remains while the manual button is green, the parent
surface must make the active automatic reason visible and provide a separate,
policy-specific action where one exists (for example, today's task bypass or an
earned-time exhaustion override). Those actions must remain distinct from the
manual CTA in presentation, API call, provenance, and side effects.

The dedicated exhaustion override is atomic at the backend boundary: it writes
the canonical-day override and queues one saved-list `unshield` command for
every enrolled device, with exactly `unlock_sources=["earned_time"]`. When a
stable selected-set identity exists, the command carries it and removes that
source; otherwise the list ID stays absent and the command is marker-only - it
must never guess a target. It never removes `manual` or `task_pause`. Each
command carries the canonical `usage_date`; both the foreground command
executor and the NSE must validate and persist
`earned.overridden.<usage_date>` before removing the earned source. Invalid
override metadata fails closed without unlocking, and ordinary earned-source
release commands that do not carry override metadata retain their existing
behavior. "Valid" includes day and identity, not only string shape: the
requested/command date must equal the child's current canonical usage date,
and the device applying the command must still be the device for which it was
fetched. A stale prior-day delivery or an identity switch between fetch and
mutation leaves both the marker and shield sources unchanged. The parent
endpoint returns `409 stale_usage_date` rather than writing a historical-day
override. Device-side validation requires the persisted authoritative runtime
timezone; it must not fall back to `TimeZone.current`. If that timezone is not
ready, execution fails closed without either mutation.

## 4. Existing Decisions That Remain Binding

All approved decisions D-1 through D-12 in `LOCK_BEHAVIOR_BOUNDARIES.md`
remain normative. In particular:

- all lock tiers retain source provenance;
- `ActiveLockStore` remains the single production shield writer;
- a trustworthy local exhaustion callback may lock first and reconcile later;
- reflection unlock still requires a positive approve/cancel signal;
- canonical runtime timezone remains the usage-date authority;
- shared-pool fanout remains child-wide;
- task suppression is day-scoped;
- an exhaustion override wins for the rest of that canonical day;
- a task bypass resumes counting;
- device labels may be shared-pool clamped, while device bars are own-cap only.

This spec explicitly supersedes three older implementation statements:

1. `offset` is not an arm/epoch identity field.
2. R-15's `+5 minutes` trust allowance is removed.
3. A false accounting gate no longer destroys the only monitor capable of
   recovering while the main app is force-killed.

## 5. Considered Approaches

### A. Patch the Existing Signatures and Guards

Remove `offset`, hash raw selection bytes, reduce the plausibility tolerance,
and add several midnight/task special cases.

This is the smallest patch, but it leaves generation ownership, pause/resume,
legacy device-total monitoring, per-app enforcement, and backend fanout as
separate state machines. It can stop the current ratchet but does not make the
seven reported scenarios closed under future changes.

### B. Versioned Metering Epochs (chosen)

Introduce a stable monitor identity, explicit daily/accounting epochs,
backend registration, immutable provenance, and one shared callback trust
function. Keep existing ledgers and lock records.

This is more work than Approach A, but it makes arm replacement an explicit
state transition and turns the seven incidents into executable state-machine
tests.

### C. Remove Live Total/Device Measurement

Keep per-app enforcement and replace Total Pool/Device Limit with coarse manual
or scheduled locks.

This would be simpler but does not satisfy the product requirement. It is
rejected.

## 6. Architecture

### 6.1 Stable Monitor Generation

A monitor generation represents one installed Apple `DeviceActivity`
schedule. Its replacement key contains only stable policy identity:

```text
protocolVersion
childDeviceID
canonicalTimezone
policyRevision
measurementSelectionDigest
enforcementSetID
```

It explicitly excludes:

```text
usage offset
accepted estimate
remaining minutes
last sync time
armedAt
callback count
retry count
accounting gate state
```

`usageDate` belongs to the daily epoch, not the long-lived repeating monitor.
This lets Apple's repeating schedule cross midnight without requiring the main
app to be alive.

`measurementSelectionDigest` is SHA-256 of the exact persisted
`earned.measurementSelection` bytes. A normal poll must not decode and re-encode
the selection. An explicit user save may produce new persisted bytes and one
intentional replacement, even when the selected set is semantically unchanged.

`policyRevision` is backend-generated from the immutable active config ID and
active device-cap ID (`pool` when the cap falls back to the pool). Pool, cap,
and timezone changes create new immutable policy rows and therefore a new
revision.

### 6.2 Daily Metering Epoch

A daily epoch is one device's cumulative accounting session for one canonical
usage date. It contains:

```text
epochID
protocolVersion = 2
childDeviceID
usageDate
canonicalTimezone
policyRevision
measurementSelectionDigest
enforcementSetID
startedAt
registeredAt
baseAcceptedMinutes
lastRawThresholdMinutes
excludedWhilePausedMinutes
status = active | paused | exhausted | retired
retiredAt
retireReason
```

The daily epoch stable key is exactly
`(protocolVersion, childDeviceID, usageDate, canonicalTimezone,
policyRevision, measurementSelectionDigest, enforcementSetID)`. `epochID`
identifies one concrete instance but is not part of that stable key. A new
epoch is created only when the stable key changes or for an explicit recovery
transition such as `gate_resume_exact_rebase` or `identity_recovery`; ordinary
polling is never such a transition.

After successful registration, `epochID`, the stable key, `startedAt`,
`registeredAt`, and `baseAcceptedMinutes` are immutable provenance. Raw
threshold high-water, pause exclusions, status, and retirement metadata are
mutable runtime state. Timestamps, base values, and mutable progress are never
replacement triggers.

At most one epoch is active for `(childDeviceID, usageDate)`. Replacement
requires a named reason:

```text
initial
day_rollover
policy_change
selection_change
enforcement_set_change
identity_recovery
gate_resume_exact_rebase
```

There is no `poll_refresh` replacement reason.

### 6.3 Backend Epoch Registry

Add `evlin_earned_time_metering_epochs` as an audit table. It stores the daily
epoch fields above, family/profile ownership, last accepted sample time, and
retirement metadata. `evlin_earned_time_samples.epoch_id` is nullable for
legacy samples and references this table for protocol-v2 samples.

Registration is idempotent by `epochID`. The backend validates:

- the header device ID matches the body;
- the device is a child device in the authenticated family/profile;
- the submitted canonical usage date matches server projection;
- the policy revision is currently valid for that date;
- `baseAcceptedMinutes` equals the committed device-day estimate;
- an epoch ID has never been registered under another
  family/profile/device scope.

A base mismatch returns the authoritative snapshot and does not activate the
epoch. The client reconciles, chooses the returned accepted value as mutable
base state, and registers one corrected epoch. It does not edit an already
registered epoch in place.

### 6.4 Device Epoch Store

The App Group stores the active monitor generation and daily epoch as one
versioned transaction protected by the existing interprocess persistence lock.
Every read and write rechecks the mirrored child-device owner before and after
the mutation.

Identity change retires the generation, removes all queued registrations and
samples owned by the old device, clears day-scoped metering state, stops known
old activity names, and prevents a delayed callback from entering local
mutation. This preserves the t185 cross-account firewall.

### 6.5 One Callback Trust Function

Swift and Python implement the same pure decision from shared JSON vectors.
For an active epoch:

```text
deltaMinutes = adjustedEstimateMinutes - baseAcceptedMinutes
elapsedSeconds = callbackAt - startedAt
trusted when deltaMinutes >= 0
  and deltaMinutes * 60 <= elapsedSeconds + jitterSeconds
```

The production default is `jitterSeconds = 30`. It may only be raised from
captured physical-device evidence and may never exceed 60 seconds.

This is an upper-bound check only. A callback may arrive late after sleep,
network delay, or extension scheduling and remains valid. An early callback is
invalid. There is no lower-bound freshness requirement and no whole-threshold
free allowance.

A callback must also match active epoch ID, device owner, canonical usage date,
policy revision, and event namespace. Failure happens before local estimate
mutation, retry enqueue, network dispatch, notification, or shield application.

### 6.6 Sample Semantics

For an accepted protocol-v2 sample:

```text
deviceEstimate = max(committedDeviceEstimate, adjustedEstimate)
childUsed = sum(deviceEstimate for each child device on that usageDate)
sharedRemaining = max(0, pool - childUsed)
ownRemaining = max(0, effectiveDeviceCap - deviceEstimate)
```

Samples are monotonic only within one `(device, usageDate)`. Values from a prior
day never form the baseline for a new day. An old or retired epoch sample is
`counted=false` and is not retried. This chooses bounded under-counting over
double-counting when a delayed callback races a valid replacement.

## 7. Wire Contract and Compatibility

### 7.1 Child State

`GET /child/state` adds optional protocol-v2 runtime fields:

```json
{
  "metering_protocol_version": 2,
  "earned_time_runtime": {
    "policy_revision": "<config-id>:<cap-id-or-pool>",
    "usage_date": "2026-07-15",
    "timezone": "America/New_York",
    "daily_pool_minutes": 120,
    "device_cap_minutes": 60,
    "remaining_minutes": 95,
    "estimated_minutes": 10
  }
}
```

Existing fields remain wire-compatible. New iOS does not emit epoch-v2 samples
until the backend advertises version 2. Deployment order is backend first.

### 7.2 Epoch Registration

Add `POST /child/earned-time/epochs`:

```json
{
  "protocol_version": 2,
  "epoch_id": "uuid",
  "device_id": "uuid",
  "usage_date": "2026-07-15",
  "timezone": "America/New_York",
  "policy_revision": "<config-id>:<cap-id-or-pool>",
  "measurement_selection_digest": "64-lowercase-hex",
  "enforcement_set_id": "uuid",
  "started_at": "2026-07-15T14:00:00Z",
  "base_accepted_minutes": 10,
  "reason": "initial"
}
```

The response returns registration status plus the authoritative device-day
snapshot. A conflict response is actionable reconciliation, not a blind retry.

### 7.3 Sample Ingest

The existing sample request adds optional `protocol_version` and `epoch_id`.
Existing generation telemetry remains accepted during rollout.

Protocol-v2 outcomes are explicit:

- active, trustworthy, gate open: `counted=true`;
- gate closed: `counted=false`, `warning=accounting_paused`;
- retired or unknown epoch: `counted=false`, `warning=stale_epoch`;
- physically impossible callback: `counted=false`,
  `warning=implausible_threshold`;
- identity/policy/date mismatch: `counted=false` with the matching stable reason.

Only a registration/base conflict is retryable after reconciliation. Paused,
stale, and implausible samples are terminal drops.

### 7.4 Rollout Ratchet

- Backend supports v1 and v2 before the iOS release.
- Wire compatibility does not preserve the unsafe trust allowance. Legacy
  requests that already supply generation metadata use the same strict
  upper-bound check with no `+5` minutes before the v2 rollout begins.
- A device remains on the legacy lane until it successfully registers its first
  v2 epoch.
- After that registration, the backend records that device as v2-capable and
  never counts a later metadata-free v1 sample for that device. It returns HTTP
  200 with `counted=false`, `warning=legacy_after_v2` so downgrade cannot create
  a false lock or retry storm.
- An old client remains functional before the ratchet. A downgraded client on a
  ratcheted device fails open by not advancing time rather than corrupting the
  ledger.
- No existing endpoint or response field is removed in this rollout.

## 8. Event State Machine

### 8.1 Poll

Every 10-second poll may reconcile policy, gate, backend accepted usage, and
lock state. It performs zero monitor replacement when the stable replacement
key is unchanged. Advancing accepted usage or offset cannot change that key.

The churn invariant is:

```text
20 minutes of unchanged 10-second polls -> exactly one successful arm
```

### 8.2 Policy or Selection Change

Pool, cap, timezone, measurement selection, or enforcement-set changes retire
the current generation/epoch once, register a replacement using the committed
backend device estimate as mutable base, and install the new monitor only after
registration succeeds or while explicitly operating offline from a durable
pending registration.

### 8.3 Accounting Pause and Resume

Closing the accounting gate changes epoch status to `paused` but does not tear
down the only repeating monitor. Thresholds observed while paused update only a
local ignored-raw high-water mark and diagnostics.

The continuous-monitor accounting is explicit. Let `R` be the current raw
threshold, `L` the previous raw threshold, and `E` excluded raw minutes:

```text
paused callback: E = E + max(0, R - L); L = R; emit no sample
active callback: adjusted = baseAcceptedMinutes + R - E; L = R
```

When a resume cannot perform an exact rebase, a `resumeBoundaryPending` flag
causes the first post-resume callback to execute the paused-callback rule. That
discards the one bucket whose usage cannot be split safely across the boundary;
later callbacks use the active rule.

On resume:

1. If an exact rebase can be installed by the active app or a proven extension
   execution path, retire the paused epoch once and create
   `gate_resume_exact_rebase` from backend accepted usage.
2. If the main app is force-killed and no extension context can legally replace
   monitoring, continue the repeating monitor. The first threshold bucket that
   straddles the pause boundary is discarded, and later raw progress subtracts
   the ignored paused high-water mark. This may under-count at most one
   five-minute bucket but can never overcharge or false-lock.

Implementation begins with a physical-device capability spike that tests
`DeviceActivityCenter.startMonitoring` from both the DeviceActivity monitor
extension and the Notification Service extension on the minimum supported
iPadOS/iOS. The spike also verifies whether `DeviceActivitySchedule` honors a
canonical timezone carried by `DateComponents` when the device timezone is
different. The exact-rebase or canonical-schedule branch is enabled only for
contexts that pass the same start, callback, stop, replacement, and day-boundary
assertions. The conservative continuous-monitor branch is mandatory regardless,
so force-kill recovery never depends on an unproven extension capability.

### 8.4 Midnight and Canonical Day Change

Day rollover has three idempotent triggers:

1. DeviceActivity `intervalDidStart`/`intervalDidEnd`;
2. any extension callback whose server-authoritative canonical day differs
   from the stored daily epoch;
3. a backend canonical-day reconciler that runs periodically, expires
   task-bypass state, re-reconciles task locks, and queues a day-rollover state
   delivery to every child device through the NSE-primary path.

The backend reconciler is database-driven and idempotent under multiple
workers. It uses durable day/device rows plus the command outbox as its guards;
process-local `BigKidStore` state is hydrated input, never the once-only marker.

The first trigger that observes the new day:

- retires yesterday's daily epoch;
- creates today's epoch with backend base zero or the authoritative already
  accepted value;
- resets only prior-day earned/per-app automatic sources;
- leaves `manual` sources untouched;
- re-applies `task_pause` when today's tasks are incomplete;
- records the canonical runtime timezone and day key;
- rejects the triggering stale callback before local estimate mutation.

The repeating monitor remains available when the main app is force-killed. A
new day never requires a foreground poll merely to become measurable.

### 8.5 Exhaustion and Override

- A trustworthy device-cap terminal callback may self-lock that device.
- A trustworthy shared-pool terminal callback may self-lock the reporting
  device; the backend fans out to siblings after durable aggregation.
- Local self-lock records include epoch ID, generation, record key, and the
  post-mutation snapshot. Backend headroom may remove that self-lock only by
  compare-and-swap when no later writer changed the record.
- An explicit exhaustion override follows D-10: it suppresses earned-time
  relocking for the rest of the canonical day. It is not the Profile manual
  button.

## 9. Per-App Epoch Provenance

Per-app rules keep their existing local storage and backend usage endpoint, but
each armed rule/window persists:

```text
ruleID
ruleRevision
childDeviceID
usageDate
timezone
scheduleWindow
tokenDigest
budgetMinutes
startedAt
baseAcceptedMinutes
lastRawThresholdMinutes
ignoredWhilePausedMinutes
activityName
```

The replacement key excludes `baseAcceptedMinutes`, used/reported minutes, and
all callback progress. Both enforcement and usage-bar events explicitly set
`includesPastActivity=false` where the SDK supports it. That flag is a hint,
not the trust boundary: the shared upper-bound validator still runs before
`applyLimitShield` or usage reporting.

An immediate full-budget callback after re-arm is therefore rejected and cannot
shield the app. A delayed, physically possible callback remains valid.

## 10. Multi-Device Lock and Display Convergence

The backend summary remains authoritative:

- child-day used is the sum of each device-day estimate;
- each device row returns its own estimate and cap remaining;
- the UI computes the label and bar with the distinct rules in sections 3.1
  and 3.2.

Shared-pool exhaustion uses child-wide command fanout. Device-cap exhaustion
uses one-device delivery. Tests must separately prove, for every target device:

1. its meter reached the expected terminal state;
2. the expected source exists in the durable shield snapshot;
3. the command or local self-lock has a receipt;
4. an unrelated sibling device was or was not locked according to the source.

Stopping a counter is not evidence that an app was shielded.

## 11. Legacy Device-Total Counter

`BigKidActivityScheduler` and `/child/time-consumption` form a legacy five-minute
device-total path backed by the process-local `BigKidStore`. The earned-time
runtime now supplies the authoritative Total Pool and Device Limit state.

Before removal:

1. inventory every production caller and consumer;
2. add per-device telemetry distinguishing legacy writes from earned-time
   samples;
3. disable legacy arming behind a server/client capability flag for one release;
4. require zero production-only consumers and no UI/state regressions;
5. then remove the scheduler, extension reporter, client method, route, and
   process-local ledger together.

Physical deletion is not part of the first epoch change and cannot be inferred
only from repository grep.

## 12. Observability

Diagnostics record bounded, non-sensitive fields:

- monitor generation ID and replacement reason;
- epoch ID, device ID, usage date, policy revision, and status;
- arm attempt count and successful arm count;
- callback raw threshold, adjusted estimate, elapsed seconds, trust result, and
  rejection reason;
- gate transitions and ignored paused high-water mark;
- backend registration conflict and authoritative base;
- local self-lock receipt/CAS result;
- shared fanout target/ack counts.

Opaque Screen Time tokens and full selection bytes are never logged or sent to
Sentry. Only their digest and counts are recorded.

The diagnostics page must distinguish:

```text
not configured
ready but waiting for first threshold
actively metering
paused by tasks
paused by reflection
exhausted
registration pending/offline
monitor replacement failed
```

This prevents a full-looking but unarmed bar from masquerading as working
tracking.

Parent and child production surfaces follow the same rule: when measurement
selection, Screen Time authorization, authoritative policy, or enforcement set
is missing, they show a tracking-setup/not-ready state rather than a healthy
full bar whose value cannot move.

## 13. Automated Test Contract

Automation is the primary acceptance mechanism. The user does not manually wait
through every state transition.

### 13.1 Shared Golden Vectors

Create versioned JSON vectors consumed byte-for-byte by Swift XCTest and
pytest. They must cover at least:

1. unchanged poll for 20 virtual minutes arms exactly once;
2. accepted offset advances without changing generation/epoch identity;
3. identical persisted selection bytes produce one stable digest;
4. immediate `t5` and immediate full per-app budget are rejected with no side
   effects;
5. a delayed but physically possible callback is accepted;
6. progress followed by repeated polls does not freeze;
7. first-launch ready state reaches its first threshold;
8. stale prior-day callbacks are rejected before local mutation;
9. virtual midnight resets the day and remains measurable without app lifecycle
   events;
10. pause/resume with the main app absent never overcharges or gets stuck;
11. task bypass resumes counting today and expires tomorrow;
12. reflection remains paused despite task bypass;
13. identity switch rejects all old-device epoch, retry, and callback data;
14. Device A usage advances shared pool and A's cap bar but not B's cap bar;
15. A device cap locks only A;
16. shared-pool exhaustion locks A and B with separate receipts;
17. per-app exhaustion locks only the rule app on the rule device;
18. manual Lock/Unlock changes only `manual` sources and leaves all meter state
    byte-identical;
19. old-client requests decode and run before the v2 ratchet;
20. v1 samples after a v2 ratchet are terminal non-counted drops;
21. with device timezone `Asia/Tokyo` and canonical timezone
    `America/New_York`, device-local midnight does not roll the usage date or
    epoch, while canonical midnight does exactly once;
22. changing the canonical timezone while the device timezone stays fixed
    retires the old epoch, creates exactly one replacement epoch, rejects old
    callbacks before mutation, and evaluates task bypass/override state against
    the new canonical date without migrating prior-date markers;
23. rapid per-app updates converge by authoritative command version even when
    delivered out of order: newer `set` beats older `set`, newer `clear` leaves
    a tombstone that prevents an older `set` from resurrecting the rule, and
    duplicate versions are idempotent.

Every callback vector asserts all side effects, not only the return value:

```text
local estimate mutation
retry enqueue
network dispatch
backend sample row
device-day and child-day ledger
notification
shield records and sources
arm/stop calls
```

### 13.2 Virtual Time and Fault Injection

- Swift uses an injected `MeteringClock` and fake `DeviceActivityCenter`.
- Python routes/services accept `now_utc` and canonical usage-date injection.
- A DEBUG-only App Group clock override drives extension day changes without
  changing the physical device clock. Release builds contain no override.
- Tests advance seconds, five-minute thresholds, midnight, and multiple days in
  milliseconds.
- Fault cases include offline registration, duplicate delivery, out-of-order
  samples, concurrent samples, stale poll snapshots, delayed retired epochs,
  partial sibling fanout, app-process absence, and identity changes during an
  asynchronous write.

### 13.3 Required Build and Regression Gates

- Focused Swift unit/state-machine suites pass.
- Full iOS test target passes except documented unrelated pre-existing failures.
- All touched backend suites pass under PostgreSQL.
- App, DeviceActivity extension, NSE, and push-applier targets compile for the
  minimum supported iOS/iPadOS version.
- The existing identity-switch, source-provenance, app-limit reset, task-lock,
  and child-wide manual-lock suites remain green.

## 14. Minimal Physical-Device Gates

Apple's DeviceActivity daemon cannot be fully simulated. Only these gates need
real elapsed time:

1. **Production earned threshold:** one 6-7 minute run with a real five-minute
   threshold. Repeat once with the Evlin main app force-killed. Expected: one
   arm, one accepted t5, five minutes deducted, no reset churn.
2. **DEBUG per-app threshold:** one one-minute rule. Expected: no immediate
   false shield after arm; one shield after real use crosses the minute.
3. **Two-device attribution smoke:** use a monitored app on A for one production
   bucket while B remains idle. Expected: shared pool drops five, A own-cap bar
   drops five, B own-cap bar remains full. Then reverse once.
4. **TestFlight overnight soak:** leave both child apps force-killed across one
   canonical midnight. Expected: new-day pool/caps reset, yesterday's automatic
   sources clear, today's task lock reconciles, and the first trustworthy usage
   bucket advances without opening Evlin.

Codex drives builds, installs, launches, App Group capture, backend queries,
and result comparison. The human tester only unlocks/authorizes devices, opens
the named monitored app, force-kills Evlin when requested, and confirms the
visible shield. Two connected devices are required only for gate 3 and the
overnight soak.

No release may claim the three products are fixed until the automated matrix
and all applicable physical gates pass. A unit-test-only result is insufficient.

## 15. Implementation Phases

### Phase 0: Independent Display and Manual-CTA Guardrails

- Correct the device bar to own-cap-only while retaining the effective-minutes
  label.
- Pin the existing manual-only child-wide endpoints and button presentation.
- Add no-side-effect assertions proving the button cannot change metering,
  automatic sources, overrides, or task suppression.
- When an automatic source remains, expose its reason and the separate
  policy-specific action, if one is permitted, without changing the manual
  button's color, verb, endpoint, or semantics.

This phase is independently releasable and does not wait for epoch migration.

### Phase 1: Executable Rules and Capability Spike

- Add golden vectors, pure epoch identity/trust functions, injected clocks, and
  fake monitor interfaces.
- Run the DAM/NSE `startMonitoring` capability spike and record results for the
  minimum supported iPhone and iPad targets.
- Label a successful short spike only as process capability. It cannot enable
  exact canonical-midnight rebase or NSE-primary production ownership; Phase 3
  retains the conservative continuous-monitor branch until a later physical
  day-boundary gate passes.

### Phase 2: Backend Epoch Protocol

- Add epoch storage/migration, optional wire fields, registration, v2 sample
  validation, protocol ratchet, periodic canonical-day/task reconciliation,
  shared-pool fanout, and backend tests.
- Establish an authoritative per-rule ordering token for `set_limit` and
  `clear_limit`. Existing `updated_at` may be used only if concurrency tests
  prove it is strictly increasing for serialized writes to one rule; otherwise
  add an explicit monotonic `policy_revision`. Every emitted command carries
  the token, including clear commands.
- Deploy backend first with v2 advertised only after migrations and tests pass.

### Phase 3: Earned-Time Device Epoch

- Add stable raw-byte digest, generation/day epoch persistence, registration and
  retry ordering, strict trust validation, pause accounting, midnight
  self-heal, identity teardown, and local self-lock CAS provenance.

### Phase 4: Per-App Epoch Provenance

- Add explicit `includesPastActivity=false`, stable per-rule arm identity,
  physical-time validation, pause/resume behavior, and false-callback tests.
- Persist the latest applied ordering token per rule independently of the
  active rule, including a clear tombstone. Drop older `set_limit` or
  `clear_limit` commands before mutating the rule store, shields, usage state,
  or monitor schedule; acknowledge an equal-version duplicate idempotently
  without repeating those mutations. Two rapid edits and set-then-clear must
  converge to the backend's final value even when wake, NSE, and poll delivery
  reorder them.

### Phase 5: Multi-Device and Delivery Closure

- Verify shared-pool fanout on every enrolled device, source/receipt readback,
  partial failure recovery, and NSE-primary state delivery.
- Close G-17 explicitly: all five reflection transition paths (chat
  interception, REST trigger, and agent propose/cancel/approve) use one
  canonical state-change-and-delivery helper. No path may update reflection
  state without queuing the matching lock/release delivery and wake.
- Close G-18 explicitly: `set_limit` and `clear_limit` use the same versioned,
  force-kill-capable delivery path and readback contract. If the Phase 1 spike
  proves NSE cannot safely start or replace DeviceActivity monitoring, NSE must
  durably persist the newest rule/tombstone and wake state; the UI may not claim
  enforcement until the monitor owner applies and acknowledges that version.
- G-19 is absorbed by Phases 2/3 plus this delivery closure: an
  `earned_time_config` update must durably update the App Group policy while
  monitor replacement remains owned by the proven DAM/main-app path.
- Run the two-device and overnight gates.

### Phase 6: Legacy Counter Deprecation

- Observe the flagged legacy path for one release, verify no remaining
  production consumer, then remove it in a separate reviewed change.

Each phase requires a separate TDD implementation plan and review checkpoint.
No phase may silently broaden the behavior of the Profile manual button.

## 16. Acceptance Criteria

The work is complete only when all of these are true:

- Total Pool advances once per trustworthy device usage bucket, sums devices,
  and locks all devices at zero.
- Device Limit advances only from that device and locks only that device at its
  cap unless the shared pool is also exhausted.
- Per-App Limit advances only for the rule app/device and applies only the
  `.limit` source at the rule budget.
- Unchanged polling never re-arms, including after accepted usage advances.
- Immediate/history callbacks cannot mutate usage or lock anything.
- Delayed physically possible callbacks remain accepted.
- Task/reflection pauses do not charge time; task bypass resumes the same day;
  a new day expires the bypass.
- Force-killing the main app does not prevent threshold measurement, new-day
  recovery, task-lock reconciliation, or automatic enforcement.
- Multi-device labels and bars follow D-12 and never imply B used A's minutes.
- The Profile button adds/removes only `manual`, and every meter/automatic state
  remains unchanged by the button.
- Parents can see the remaining automatic reason and reach any permitted
  bypass/override without overloading the manual button.
- Rapid per-app edits and clears converge to the newest backend version under
  duplicate and out-of-order delivery; a stale set cannot resurrect a cleared
  rule.
- Every G-17 reflection path and G-18 app-limit command has a force-kill-capable
  delivery/readback result rather than relying only on foreground polling.
- Identity switches cannot carry usage, retry entries, epochs, or automatic
  locks into the new account.
- Backend v1/v2 rollout remains wire compatible and ratchets safely per device.
- Automated and physical-device release gates have recorded evidence.

## 17. Non-Goals

- Exact second-by-second usage display.
- Reading Apple's private Screen Time totals.
- Correcting historical production usage automatically.
- Replacing `ActiveLockStore` or the approved lock-source precedence model.
- Letting the Profile manual button override automatic policy.
- Physically deleting the legacy counter before its one-release deprecation
  gate.
- Claiming reliability solely from simulator or unit-test results.

## 18. Review Addendum (2026-07-15)

This addendum records the scope decisions added during final architecture
review; the normative phase and test sections above already incorporate them.

1. G-17 and G-18 remain owned work in Phase 5; replacing the older roadmap does
   not remove either delivery gap. G-19 is split across the epoch protocol,
   device application, and Phase 5 delivery verification.
2. Canonical-timezone behavior is covered by shared vectors 21 and 22, including
   a device whose local timezone differs from policy timezone.
3. `2026-07-12-profile-multi-device-lock-design.md` and its implementation plan
   are superseded for CTA semantics. Section 3.6 and Phase 0 here are
   authoritative: the CTA controls `manual` only.
4. Rapid per-app edits are a convergence requirement, not merely a UI debounce
   concern. Phase 2 establishes the ordering token; Phase 4 persists and
   enforces newest-wins semantics on every delivery path.
5. The separate exhaustion override is not complete until the override row and
   earned-only per-device releases are committed together; ledger-only success
   must not be presented as an unlocked device.
6. The short DAM/NSE spike establishes process capability only. Exact
   canonical-day-boundary behavior remains physically gated and the
   conservative branch remains mandatory beforehand.
