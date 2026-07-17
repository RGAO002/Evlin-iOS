# Metering Epoch Reliability Design

**Date:** 2026-07-15
**Status:** Revised 2026-07-17 (review round 5); PASS / READY FOR IMPLEMENTATION

**Platform floor:** iOS 17.6 and iPadOS 17.6 for the app and all Screen Time
extensions. Capability spikes and release builds must exercise this floor even
when development devices run iOS/iPadOS 26.

**Targeted supersession:** This document replaces only the conflicting
arm/gate clauses in `2026-07-10-earned-time-poll-self-heal-design.md`, the
`+5-minute` formula in `2026-07-13-earned-threshold-plausibility-design.md`, and
the any-source/override Profile CTA behavior in
`2026-07-12-profile-multi-device-lock-design.md`. Their unrelated requirements
remain in force.

## 0. Architecture Corrections (2026-07-17)

### 0.1 Callback provenance and dated coverage

This correction is normative and supersedes every conflicting sentence in the
original 2026-07-15 text. Local Xcode 26.3 / iPhoneOS 26.2 SDK interfaces and
the implemented Phase 2 backend contract prove two earlier premises impossible:

1. Apple's monitor callback supplies only `DeviceActivityName` and
   `DeviceActivityEvent.Name`; it does not supply an independently trustworthy
   usage date, epoch, policy, owner, or raw counter snapshot.
2. A repeating activity name cannot identify which canonical day produced a
   delayed callback. The app and DAM also have no synchronous exact raw-usage
   read API from which to perform an exact resume rebase.

Phase 3 therefore uses immutable, dated, non-repeating callback routes. An
opaque route UUID appears in both Apple names, and one durable route record
independently binds that UUID to owner, canonical date, epoch, generation,
policy, namespace, schedule, events, and lifecycle. The Apple-shaped callback
DTO contains only `{activityName, eventName, observedAt}`. No callback field is
trusted until the route is resolved and all durable owner/date/epoch/policy
checks pass.

For each active policy generation, the app maintains a bounded installation
horizon of canonical today plus the next seven canonical dates: exactly eight
dated routes when fully ready. Running the app fills the horizon without
replacing unchanged routes. If the horizon expires while Evlin remains
force-quit, the device enters explicit `coverageExhausted` monitoring state.
Unknown or uncovered callbacks then have zero usage, ledger, retry, network,
notification, or earned auto-shield effects. Evlin neither manufactures usage
nor applies an earned-time fail-closed lock. Manual, task-pause, reflection,
admin, block, per-app, and other non-metering sources remain independent.

No NSE-primary monitor ownership is authorized by this correction.

### 0.2 Review-round-2 protocol and recovery correction

The 2026-07-17 second review verified that the deployed Phase 2 backend marks a
trusted closed-gate epoch `paused` and refuses to resume that row except through
`gate_resume_exact_rebase`. Because Apple exposes no exact raw counter to the app
or DAM, continuing the same epoch after pause is not implementable. Phase 3 is
therefore required to extend the backend additively with
`gate_resume_conservative`. The old reason remains decodable for wire and stored
row compatibility but is never emitted by new iOS code.

Conservative resume retires the paused epoch and creates a fresh immutable epoch
and fresh route/install/registration work from the backend's authoritative
`estimated_minutes`. The old monitor is not stopped merely because the gate is
closed: its epoch and route are logically retired/tombstoned in the replacement
transaction, while its Apple monitor remains a crash-safe physical stop target.
Once the new monitor is registered, started, daemon-verified, and activated, the
old monitor is stopped and absence-acknowledged. The first callback on the new
route is discarded and becomes its excluded boundary high-water. A registration
or activation race that observes the gate closed returns `epoch_status=paused`,
does not activate locally, and is recovered after the gate opens by another
fresh epoch and route. No paused or base-corrected epoch ever reuses a route.

Registration HTTP 200 alone also cannot remove functional protocol 1. The exact
legacy active/pending/retiring generation state is migrated into
`LegacyCompatibilityMonitorState`; its real callbacks and durable v1 queue
continue while v2 is unadvertised, offline, registration-only, or recovering
after restart. A new activation acknowledgement endpoint ratchets the backend
device only after the v2 route is started, verified, and a durable local
`dualActive` transaction has authorized that exact route to accept callbacks
while keeping the legacy lane functional. During `dualActive`, v1 and v2
cumulative samples may overlap; the backend's monotonic accepted estimate makes
their overlap idempotent rather than additive. The legacy monitor stops only
after the acknowledgement is durably reflected as local v2-only state. This
closes both crash windows: before the backend ratchet v1 remains countable, and
after the backend ratchet v2 was already locally authorized.

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
| Progress never moves from first launch | Explicit readiness state, one stable eight-date route horizon, and first-threshold acceptance only after real elapsed use. |
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

### 6.1 Stable Policy Generation

A policy generation is not an Apple schedule. It is the durable identity shared
by a bounded set of dated route installations. Its replacement key contains
exactly these six fields:

```text
protocolVersion
childDeviceID
canonicalTimezone
policyRevision
measurementSelectionDigest
enforcementSetID
```

The key excludes `usageDate`, offset, accepted estimate, remaining minutes,
counters, timestamps, raw high-water marks, gate state, install state, and
retry state. Date belongs to the daily epoch and route. One immutable
`generationID` identifies the concrete generation but is not a key field.

`measurementSelectionDigest` is SHA-256 of the exact bytes persisted at
`earned.measurementSelection`. The generation also retains those exact bytes
for recovery. Normal reconciliation never decodes and re-encodes the selection
before hashing. `policyRevision` remains the backend's string value formed from
the immutable config/cap identity.

### 6.2 Dated Callback Routes And Coverage

Each canonical date has one non-repeating `DeviceActivitySchedule` built by the
exact Swift interface:

```swift
nonisolated static func datedSchedule(
    usageDate: String,
    timeZone: TimeZone,
    calendar: Calendar = Calendar(identifier: .gregorian)
) throws -> DeviceActivitySchedule
```

Phase 3 implements this on shared `MeteringDatedSchedule`, compiled by both app
and DAM. The app-only legacy scheduler may delegate to it, but the dated
installer never depends on an app-only scheduler type.

The schedule contains absolute year/month/day components in the canonical
timezone and `repeats == false`. A route uses these names:

```text
activity = evlin.earned.v2.<route-uuid>
event    = evlin.earned.v2.<route-uuid>.t<threshold-minutes>
```

The durable route is immutable after creation and contains `routeID`, both name
forms/namespace, `generationID`, the six-field generation key,
`ownerChildDeviceID`, `usageDate`, `epochID`, planned/installed schedule,
planned events, and lifecycle. Parsing the same route UUID from both names is
necessary but never sufficient; the store record supplies independent
provenance.

The app fills exactly eight canonical dates, today through today + 7, whenever
it runs. Reconciliation of an unchanged, already full horizon performs no
start, stop, replacement, route-ID, generation-ID, or epoch-ID mutation. When
the canonical date advances while the app runs, it appends only the newly
needed future route and retires expired work through the normal tombstone
protocol. A route tombstone remains until Apple stop is acknowledged, all work
that references the route is terminal, and the retention horizon has elapsed.

Coverage state records the required range, verified `readyThroughUsageDate`,
status (`ready`, `installLimited`, or `coverageExhausted`), refresh time, and
bounded error code. `DeviceActivityCenter.MonitoringError.excessiveActivities`
does not authorize destructive replacement: preserve every verified existing
route, stop filling, record the actual ready-through date, and expose
`installLimited`. If today is not covered, transition to `coverageExhausted`
and apply the zero-metering-effects rule from section 0.

### 6.3 Daily Metering Epoch

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
baseSource = childState200 | registration200 | registrationConflict409
lastRawThresholdMinutes
excludedWhilePausedMinutes
status = active | paused | exhausted | retired
resumeBoundaryPending
retiredAt
retireReason
exhaustedAt
baseCorrectionState = available | used
```

The stable key is exactly the six-field generation key plus `usageDate`.
`epochID`, dates, bases, progress, and status are not key fields. The backend
`earned_time_runtime.estimated_minutes` (or the authoritative snapshot in a
registration 409) is the only input to `baseAcceptedMinutes`; remaining, cap,
local offsets, and local estimates cannot be substituted.

At most one backend epoch is non-retired for `(childDeviceID, usageDate)`.
Phase 3 iOS emits `initial`, `day_rollover`, `policy_change`,
`selection_change`, `enforcement_set_change`, `identity_recovery`, or
`gate_resume_conservative` as appropriate. The backend continues decoding
`gate_resume_exact_rebase` for old rows and clients, but new iOS never emits it.
Exhaustion is an epoch status with `exhaustedAt`, not a free-standing Boolean
guard. Paused, exhausted, and retired epochs never return to active. Resume,
authoritative-base correction, and any other immutable epoch replacement always
create a fresh route as well as a fresh epoch.

### 6.4 Backend Epoch Registry

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
candidate epoch. In one local transaction the client terminalizes only that
rejected candidate epoch, route, and candidate-route queued samples with
`superseded_by_authoritative_base`; the prior functioning epoch and route remain
active. It creates a corrected candidate epoch, a fresh route, fresh install
work, and fresh registration work from
`authoritative_snapshot.estimated_minutes`. The corrected monitor completes the
dual-v2 handoff below before the prior functioning route is retired or stopped.
A second mismatch is terminal for the candidate and still leaves the prior
functioning route untouched; no registered provenance or route is edited or
reused in place.

The corrected backend registration response keeps the existing `status`,
`epoch_id`, `metering_protocol_version`, and authoritative `snapshot` fields and
adds `epoch_status` (`active`, `paused`, `exhausted`, or `retired`). New iOS
requires that field before local activation; absence is handled conservatively
by leaving work pending and fetching state again. `snapshot` is the authoritative
snapshot; no duplicate snapshot field is added.

The backend adds idempotent
`POST /child/earned-time/epochs/{epoch_id}/activation`. Its request carries
`protocol_version`, `device_id`, `route_id`, and `verified_at`. The endpoint
observes device scope, takes the profile advisory lock, row-locks and revalidates
device family/profile/mode, then rechecks immutable epoch
family/profile/device/protocol/not-retired scope and exact route ownership. A
same-route row with non-null `activated_at` returns idempotent
`already_activated` before mutable authority checks. Only a first activation
continues through canonical date/timezone, current policy revision, currently
selected active enforcement set, verification timestamp, and accounting gate.
That first successful transaction stores `activation_route_id` and
`activated_at` and ratchets the device to protocol 2. If its gate is closed it
leaves the epoch paused, leaves the per-device ratchet unchanged, and returns
`status=paused`, `epoch_status=paused`, the current
`metering_protocol_version`, and the authoritative `snapshot`.

No activation service accepts a caller-supplied clock instant, canonical date,
or timezone override. It consumes locked canonical authority issued from one
production server-clock capture. Tests control that production clock seam;
wire callers cannot choose the instant used for activation or ratcheting.

### 6.5 One Versioned Device Epoch Store

One App Group root is the sole Phase 3 payload authority. Every transaction is
protected by `ActiveLockPersistenceLock`, uses atomic replacement plus readback,
and rechecks the mirrored owner before and after mutation. The root contains:

```text
schemaVersion and ownerChildDeviceID
generations and activeGenerationID
daily epochs and activeEpochID
immutable routes and route tombstones
legacy compatibility monitor state
registration, activation, and sample queues
activity install/start/verify/dualActive/activate/stop acknowledgements
v2 route handoff with exact from/to epoch and route IDs
install claim/lease arbitration
coverage state
shield-effect operation references
identity-cleanup envelope
rollover-effects envelope
per-owner protocol ratchet
```

Registration, activation, sample, fallback, install, shield-reference, cleanup,
rollover, and ratchet work is never split across uncoordinated `UserDefaults` flags. A
reopen recovery driver examines every nonterminal envelope before creating new
work. It adopts or retries the same UUIDs and makes each external operation
idempotent.

The sample queue, exact legacy lifecycle import, and protocol-1 backfill are
active before any production path may select protocol 2. Advertising v2 or
receiving registration HTTP 200 does not stop or disable v1. The owner remains
backend-ratcheted at 1 until the new v2 route is started, schedule/events are
daemon-verified, and one durable local transaction enters `dualActive` for the
exact owner/epoch/route/generation. `dualActive` accepts trusted v2 callbacks
and preserves functional v1 callbacks; overlapping cumulative estimates are
committed by monotonic max, never summed. Only after that transaction may the
activation request ratchet the backend. Its `activated`/`already_activated`
response, or an idempotent recovery read after a lost response, lets one local
transaction select v2-only and mark the legacy monitor retiring; legacy stop
follows that transaction.

Every v2-to-v2 replacement uses a separate durable `V2RouteHandoff`. The prior
epoch/route remains locally active while the replacement route is physically
started and daemon-verified. One transaction then enters `dualV2`, authorizing
both exact routes and queueing replacement callbacks without retiring the prior
route. Recovery first settles every deliverable prior-route sample and waits for
any in-flight prior delivery. Under the same Device Epoch Store lock used by
callbacks, it then requires no nonterminal prior-route sample work and advances
the handoff to `cutoverReady`. A prior callback racing this barrier either queues
before it and prevents the transition, or arrives after it and is discarded
without mutation; replacement callbacks remain durably queued waiting for
registration. Only `cutoverReady` may send registration and atomically replace
the backend epoch. If that response is lost, the replacement route is already
countable locally and its queued samples retry idempotently; prior-route samples
become terminal only after the backend cutover. Overlapping cumulative samples
from the two exact routes converge by monotonic maximum for the same owner/day,
never by addition. Activation of the replacement and one local active commit
then retire/tombstone the prior route and schedule its physical stop. Thus every
crash boundary has at least one countable route and no overlap can double count.
Future routes cannot be registered because Phase 2 validates registration
against canonical today, so they carry explicit `futurePlanned` authorization.
An initial v1-to-v2 route registers before install. A v2-to-v2 replacement is
started and verified before its registration cutover, under the explicit
`dualV2` handoff. If offline, a candidate may carry durable `offlinePending`;
callbacks are queued without business effects until registration resolves,
while the prior functioning route remains authoritative.

### 6.6 Crash-Safe Install And Retirement

Initial v1-to-v2 migration follows this exact order:

1. Atomically create the generation/epoch/route, registration work, and durable
   `pendingStart` install work.
2. Register today's epoch, except for explicit `futurePlanned` or
   `offlinePending` authorization. Registration 200 is not a protocol ratchet.
3. Claim the pending start, start the new dated route, then verify it through
   `activities`, `schedule(for:)`, and `events(for:)`.
4. Atomically enter `dualActive` for the verified route. Both exact v1 and v2
   callbacks remain countable, and duplicate cumulative coverage converges by
   monotonic max. Only then call the activation endpoint. A new `activated`
   result must have active epoch status; a same-route `already_activated` replay
   acknowledges the committed ratchet even when current mutable status has since
   become paused or exhausted.
5. Atomically activate the verified route and epoch and select owner protocol 2;
   only now mark the legacy monitor retiring.
6. Stop old canonical activity names and acknowledge their absence before
   terminalizing the stop work or tombstone.

Every generation, day, pause-resume, or base-correction v2-to-v2 replacement
instead follows this exact order:

1. Keep the prior epoch, route, and monitor active. Atomically create only the
   candidate epoch/route plus install and registration work.
2. Claim, start, and daemon-verify the candidate monitor while the prior route
   continues to authorize callbacks.
3. Atomically enter `V2RouteHandoff.dualV2` with exact from/to epoch, route, and
   generation IDs. Both routes are locally countable; cumulative overlap merges
   by monotonic maximum.
4. Deliver every queued/in-flight prior-route sample. In one callback-serialized
   transaction require no nonterminal prior work and enter `cutoverReady`; after
   this barrier only the candidate route may enqueue business work.
5. Register the candidate. That transaction may retire the prior backend epoch.
   A lost response leaves local `cutoverReady` intact, so candidate callbacks remain
   durably queued and retry while prior callbacks resolve as accepted-before-
   cutover or terminal-after-cutover.
6. Activate or idempotently recover the candidate, then atomically make it the
   sole local active route. Only this transaction retires/tombstones the prior
   local route and appends its physical `pendingStop` work.
7. Stop the prior canonical activity and acknowledge absence before collecting
   its tombstone and handoff envelope.

Horizon fill for a future date is the explicit exception to step 1: it persists
an immutable route with a reserved epoch UUID plus `futurePlanned/pendingStart`,
but no registered daily epoch or registration request. On that canonical date,
backend child state or a registration 200/authoritative 409 supplies
`estimated_minutes` before the full epoch can authorize usage or shield effects.
The app or DAM obtains that state through authenticated `GET /child/state` with
`X-Child-Id`; registration and sample POSTs continue using
`X-Evlin-Child-Device-ID`. A failed/missing runtime fetch leaves the dated route
non-authorizing and cannot be replaced with a local estimate.

The old active route or legacy monitor is never logically retired locally or
physically stopped before the new route is verified and active. A crash at every
numbered boundary reopens into the same IDs and resumes the same phase. App and
DAM may both recover `pendingStart`, so
each install work item carries a claim with a unique token, process role,
process instance ID, `claimedAt`, and `expiresAt`. The claim lease is exactly 60
seconds. Under the Device Epoch Store lock only one process may transition
`pendingStart` to `starting`; a loser performs no Apple call. After expiry an
adopter first compares daemon `activities`, schedule, and events. It acknowledges
an exact existing installation without calling `startMonitoring` again. If the
route is absent it starts once; if the same name exists with mismatched immutable
configuration it replaces and reverifies that route while a prior functioning
monitor remains. It never blindly duplicates a start.

All registration, activation, install, sample, shield-effect, identity-cleanup,
and rollover work uses the retry sequence 0, 5, 15, 60, 300 seconds, with every
later delay capped at 300. New work is due immediately. After failures 1, 2, 3,
and 4, its next delay is 5, 15, 60, and 300 seconds. Due work is ordered by
`(nextAttemptAt, kindPriority, createdAt, lowercaseWorkID)`, with kind priority
identity cleanup, rollover, registration, install, activation, sample, then
shield effect. Virtual-clock tests pin every boundary.

Identity cleanup is owner-independent work persisted before owner replacement;
it captures every old route, epoch, registration, activation, sample, fallback,
install, and shield operation ID, blocks old callbacks immediately, and
acknowledges each terminalized work ID, purged fallback key, released shield
operation ID, stopped activity name, cleared usage date, and owner-mirror
transition before completing. Canonical rollover uses a separate durable effects
envelope containing exact old/new epoch IDs and old/new route IDs plus durable
acknowledgements for earned source reset, per-app reset, task reset, bypass
expiry, registration, install, activation, and old-route stop. No new-day
callback may mutate usage or shielding until that envelope is reconciled.

A route tombstone may be deleted only after every referenced queue/effect is
terminal and Apple stop is acknowledged and the current time is at or after the
later of (a) canonical day end plus 48 hours and (b) stop acknowledgement plus
24 hours. Missing stop acknowledgement makes the tombstone ineligible forever;
polling or restart cannot shorten this retention.

### 6.7 One Callback Trust Function

The production callback ingress is exactly:

```swift
nonisolated struct MeteringAppleCallback: Codable, Equatable, Sendable {
    let activityName: String
    let eventName: String
    let observedAt: Date
}
```

Swift resolves the opaque route ID from both names, loads the immutable route,
then runs the shared pure trust decision. Before every side effect it rechecks
owner, route lifecycle, tombstone, epoch status, canonical date, generation,
policy, event namespace/threshold plan, gate, registration authorization, and
the owner mirrored outside the store. Unknown, malformed, mismatched,
future-prepared, retired, stopped, tombstoned, uncovered, or unregistered
callbacks without explicit current-day `offlinePending` authorization have
exactly zero effects. A fully trusted current-day `offlinePending` callback may
append one durable sample blocked on registration; it has no local estimate,
network, backend, notification, or shield effect until registration succeeds.

For an active registered epoch:

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

A delayed callback has no lower-bound age rejection. The production default is
30 seconds and the hard maximum is 60. Failure happens before local estimate
mutation, queue mutation, network dispatch, backend row/ledger mutation,
notification, or shield application.

### 6.8 Shield Effects And Sample Semantics

Earned shield mutation is coupled to a durable effect envelope under the same
`ActiveLockPersistenceLock` used for shield persistence. The envelope records
operation ID, owner, epoch, generation, route, exact record key, before/intended
after snapshots, and phase (`prepared`, `applied`, `releasePending`,
`released`). Persist `prepared` before mutating the shield, persist `applied`
afterward, and recover by exact compare-and-swap. The Device Epoch Store keeps
only the operation reference. Release removes only the matching `earnedTime`
source and preserves manual, `taskPause`, reflection, block, limit/per-app,
admin, and newer record state byte-for-byte.

Cross-process correctness applies to every app-side lock mutation, not only
`.limit` reconciliation and receipt rollback. Before each mutation,
`ActiveLockStore` acquires `ActiveLockPersistenceLock`, reloads and normalizes
the complete durable shield and block dictionaries, merges no stale actor
snapshot over them, performs the requested mutation, persists and verifies, and
then recomputes ManagedSettings. This must preserve an earned-time envelope
written by DAM when an already-live app actor later performs an unrelated
manual, `taskPause`, `.limit`, block, or third-party-record mutation. Exact CAS
conflicts leave the newer durable record untouched.

`ShieldSource` persistence is forward-compatible without collapsing an unknown
raw source to `.manual`. Known sources retain their named conveniences, while
an unknown future raw value round-trips losslessly through decode, merge, CAS,
and encode. This is provenance compatibility, not a second lock authority.

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

HTTP 200 keeps the existing response fields and adds `epoch_status`:

```json
{
  "status": "registered",
  "epoch_id": "uuid",
  "metering_protocol_version": 2,
  "epoch_status": "active",
  "snapshot": {
    "child_device_id": "uuid",
    "usage_date": "2026-07-15",
    "estimated_minutes": 10,
    "cap_minutes": 60,
    "child_day_state": "available",
    "used_minutes": 10,
    "remaining_minutes": 110,
    "counted": true,
    "warning": null
  }
}
```

`epoch_status` is additive in Pydantic and Codable so old payloads still decode,
but the corrected backend always emits it and new iOS treats absence as
non-activating. The existing `snapshot` is the authoritative snapshot. A 409
`authoritative_base_mismatch` response remains
`{"code", "authoritative_snapshot"}` and creates fresh epoch and route work,
not a blind retry.

After daemon verification, iOS calls
`POST /child/earned-time/epochs/{epoch_id}/activation`:

```json
{
  "protocol_version": 2,
  "device_id": "uuid",
  "route_id": "uuid",
  "verified_at": "2026-07-15T14:00:02Z"
}
```

Its HTTP 200 response has `status` (`activated`, `already_activated`, or
`paused`), `epoch_id`, `epoch_status`, `metering_protocol_version`, and
`snapshot`. A repeated identical route is immutable and idempotent. After
family/profile/device/protocol/not-retired scope and exact route ownership are
verified, non-null `activated_at` returns `already_activated`, protocol 2, and
the current snapshot/mutable epoch status before any current date, policy,
enforcement, gate, or active-status check. This ordering is required when the
activation transaction committed but its response was lost: later gate close,
epoch exhaustion, policy change, or enforcement-set change cannot resurrect v1
or make the committed ratchet unacknowledgeable. The client commits local v2
selection on that acknowledgement, then reconciles the returned mutable state
through the normal replacement path. A different route returns
`detail=activation_route_mismatch`; a retired, wrong-scope, or unregistered
epoch returns `detail=activation_epoch_not_current`. A `paused` response from a
first activation that never committed does not ratchet or authorize local
activation.

### 7.3 Sample Ingest

`POST /api/v1/child/earned-time/sample` keeps the exact common fields
`device_id`, `usage_date`, `timezone`, `activity_name`, `event_name`,
`threshold_minutes`, `estimated_minutes`, `observed_at`, and
`client_sample_id`. Protocol 2 adds the pair `protocol_version`/`epoch_id`.
Protocol 1 may omit both legacy generation fields, matching current production,
or send the complete pair `generation_armed_at`/
`generation_offset_minutes`; a partial pair is invalid. Phase 3 does not invent
`device_to_backend_offset_seconds` or any other field. The v2 activity/event
values are explicit Phase 2 compatibility aliases derived from the verified
route: `evlin.earned.budget.<routeID>` and
`evlin.earned.t<thresholdMinutes>`. The raw Apple callback and durable route
retain the canonical both-name forms from section 6.2; alias projection is a
wire adapter and never callback provenance. The backend's `estimated_minutes` is
the pause-adjusted authoritative cumulative estimate while
`threshold_minutes` is the event threshold parsed from the verified route.
Backend physical trust is evaluated exactly once as
`(estimated_minutes - epoch.base_accepted_minutes) * 60 <=
elapsed_since_epoch_start + jitter`. Namespace and threshold-name consistency
remain independent route checks. The backend must not also treat raw
`threshold_minutes` as cumulative usage from base zero: a conservative-resume
or authoritative-base-correction route may legitimately begin at a raw event
threshold above the minutes elapsed since that fresh route started.
New route-backed work uses deterministic `client_sample_id` value
`earned:<v1|v2>:<lowercase-route-uuid>:t<threshold>` and retains that exact value
across retries.

Protocol-v2 outcomes are explicit:

- active, trustworthy, gate open: `counted=true`;
- gate closed: `counted=false`, `warning=accounting_paused`;
- retired or unknown epoch: `counted=false`, `warning=stale_epoch`;
- physically impossible callback: `counted=false`,
  `warning=implausible_threshold`;
- identity/policy/date mismatch: `counted=false` with the matching stable reason.

Sample ingest never edits or revives epoch/route provenance. Paused, stale,
superseded-route, and implausible sample requests are terminal drops. Recovery
that observes the resume warning first fetches authoritative child state and
then creates fresh registration/install/activation work. A paused epoch observed after the gate reopens returns
`warning=gate_resume_conservative_required`; old clients may still decode the
legacy `gate_resume_rebase_required` warning but new backend code does not emit
it.

### 7.4 Rollout Ratchet

- Backend supports v1 and v2 before the iOS release.
- Wire compatibility does not preserve the unsafe trust allowance. Legacy
  requests that already supply generation metadata use the same strict
  upper-bound check with no `+5` minutes before the v2 rollout begins.
- The durable v1 queue/backfill and recovery driver are installed and exercised
  before any production branch can choose v2.
- A device remains on the legacy lane after v2 advertisement and registration
  HTTP 200. The exact legacy monitor and queue continue while offline and across
  restart. Registration, a 409, a start attempt, and verification alone cannot
  ratchet it.
- The new route is started and daemon-verified before local state durably enters
  `dualActive`. In that state both lanes remain countable without additive
  double counting. The activation endpoint then atomically records the route
  and ratchets the backend device. A lost response cannot create a gap because
  v2 was already accepted locally; recovery repeats activation idempotently.
  On its `activated` result, or same-route `already_activated` result after a
  committed-but-lost response, local state selects v2-only and only then
  retires/stops legacy. Mutable paused/exhausted/policy drift is reconciled after
  this local acknowledgement rather than being allowed to strand the device in
  `dualActive` with terminal v1.
- After activation, the backend never counts a later v1 sample for that device.
  It returns HTTP 200 with `counted=false`, `warning=legacy_after_v2` so downgrade
  cannot create a false lock or retry storm.
- An old client remains functional before the ratchet. A downgraded client on a
  ratcheted device fails open by not advancing time rather than corrupting the
  ledger.
- No existing endpoint or response field is removed in this rollout.

## 8. Event State Machine

### 8.1 Poll

Every 10-second poll may reconcile policy, gate, backend accepted usage, and
lock state. It first recovers nonterminal work, then fills missing dated routes.
It performs zero replacement when the six-field generation key is unchanged.
Advancing accepted usage, changing offset, or changing date cannot replace the
generation.

The churn invariant is:

```text
first real installer reconciliation -> exactly eight startMonitoring calls
next 120 unchanged real poll reconciliations
  -> one generation + the same eight route IDs/installations
  -> zero additional starts and zero stops
```

### 8.2 Policy or Selection Change

Pool/cap revision, timezone, exact persisted selection bytes, or enforcement-set
changes create one new six-field generation and its eight-date plan. The store
persists `pendingStart` before external work, starts and verifies today's
replacement route while the prior route remains active, commits `dualV2`, then
registers and activates the replacement before retiring/stopping old routes.
Future routes use `futurePlanned`; a current route may use `offlinePending`.
Reopen recovery resumes the same route/work IDs. An install error never erases
the last verified active route.

### 8.3 Accounting Pause and Resume

Closing the accounting gate changes epoch status to `paused` but does not tear
down its dated monitor merely because tasks/reflection closed the gate.
Thresholds observed while paused update only that paused epoch's ignored raw
high-water and diagnostics and have no sample, ledger, network, notification,
or shield effects.

This is an explicitly bounded metadata mutation, not a byte-identical
rejection. While the gate remains closed, only `lastRawThresholdMinutes`,
`excludedWhilePausedMinutes`, and the corresponding diagnostic entry may
change. Every business/effect field remains byte-identical. Once the gate is
observed open, callbacks on the old paused route do not advance even those
fields; recovery creates the fresh conservative epoch/route. Likewise, the
first `resumeBoundaryPending` callback may set the new route's excluded
boundary and clear that flag, but creates no business effect.

When authoritative child state first reports the gate open, the app or DAM uses
only `earned_time_runtime.estimated_minutes` to atomically create a new epoch,
fresh route, fresh registration/install/activation work, and
`resumeBoundaryPending=true` with reason `gate_resume_conservative`. The paused
epoch/route remains physically installed until the replacement is registered,
started, verified, and activated. It also remains the prior local route until
the candidate completes `dualV2`, the prior-sample drain/`cutoverReady` barrier,
and local activation. If registration or activation returns paused,
local activation does not occur; recovery after a later open creates another
fresh epoch and route rather than reviving either paused row.

Let `R` be the raw threshold on the new route and `E` its excluded boundary
minutes. The first callback executes `E = R`, clears
`resumeBoundaryPending`, and emits nothing. A later callback computes
`adjusted = baseAcceptedMinutes + max(0, R - E)`. This conservatively discards
one boundary bucket. There is no exact raw query, exact-rebase branch, same-epoch
resume, or manufactured usage.

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

The first trigger atomically writes `RolloverEffectsWork` with old/new dates,
exact `oldEpochID`, `newEpochID`, `oldRouteID`, and `newRouteID`, plus pending
acknowledgements for earned source reset, per-app reset, task state, bypass
expiry, registration, dated install, activation, and old-route stop.
Today's preinstalled route enters exact old→new `dualV2`, drains prior-date
work, and enters `cutoverReady` before current-day registration can cut over
backend authority. A delayed old route remains
attributable only to its old date before cutover and resolves through its
tombstone with zero effects after the new local activation. Manual, reflection,
admin, block, and unrelated sources remain intact.

If Evlin was force-quit, a route already installed for today can receive the
callback and drive the same durable rollover recovery. This guarantee lasts
through the bounded eight-date coverage horizon; it is not an indefinite
foreground-free promise.

### 8.5 Identity Change

Before changing `ownerChildDeviceID`, atomically persist owner-independent
`IdentityCleanupWork` and retire the old active epoch/generation/routes. The
envelope names all canonical old activity names, route tombstones,
registration/sample/fallback work, day state, and earned shield operation
references. Old callbacks are unauthorized immediately. Stop, purge, release,
and acknowledgement proceed idempotently after the owner field changes; a
crash at any boundary reopens into cleanup rather than admitting old mutation.

### 8.6 Coverage Exhaustion And Install Limits

The planner requests exactly today through today + 7. If
`excessiveActivities` prevents a full fill, keep verified routes and mark the
actual `readyThroughUsageDate`. If canonical today is uncovered because the
horizon expired or installation never succeeded, epoch/coverage state becomes
`coverageExhausted`. Known stale and unknown callbacks both produce zero usage,
queue, backend, notification, and earned shield effects. The product shows
monitoring-not-ready/coverage-exhausted, does not guess usage, and does not add
or preserve an earned-time lock solely because coverage is absent. Existing
manual, task-pause, reflection, admin, block, and per-app sources are unchanged.

### 8.7 Exhaustion And Override

- A trustworthy device-cap terminal callback may self-lock that device.
- A trustworthy shared-pool terminal callback may self-lock the reporting
  device; the backend fans out to siblings after durable aggregation.
- Local self-lock uses the prepared/applied effect envelope and exact CAS from
  section 6.8. Backend headroom may request release, but cannot veto the trusted
  callback or remove any newer/non-earned source.
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
- epoch and route IDs, device ID, usage date, policy revision, and lifecycle;
- coverage range, ready-through date, status, and `excessiveActivities` result;
- registration/install/verify/activate/stop phases and attempt counts;
- callback raw threshold, adjusted estimate, elapsed seconds, trust result, and
  rejection reason;
- gate transitions and ignored paused high-water mark;
- backend registration conflict and authoritative base;
- sample queue/ratchet disposition without request secrets;
- shield, identity-cleanup, and rollover envelope phase/acknowledgements;
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
monitoring not ready: coverage exhausted
monitoring limited: ready through <canonical date>
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

1. the first real installer reconciliation makes exactly eight starts; the next
   120 unchanged real poll reconciliations retain one generation and the same
   eight route IDs/installations with no additional start or stop;
2. accepted offset advances without changing generation/epoch identity;
3. identical persisted selection bytes produce one stable digest;
4. immediate `t5` and immediate full per-app budget are rejected with no side
   effects;
5. a delayed but physically possible callback is accepted;
6. progress followed by repeated polls does not freeze;
7. first-launch ready state reaches its first threshold;
8. after rollover, an old-date callback resolves through its route tombstone
   and has zero effects rather than merely failing a current-state comparison;
9. virtual canonical midnight activates the preinstalled dated route exactly
   once and remains measurable without app lifecycle events;
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
    creates exactly one replacement epoch/route, keeps the prior route countable
    through exact `dualV2`, retires it only after replacement activation, rejects
    post-cutover old callbacks before mutation, and evaluates task bypass/override
    state against the new canonical date without migrating prior-date markers;
23. rapid per-app updates converge by authoritative command version even when
    delivered out of order: newer `set` beats older `set`, newer `clear` leaves
    a tombstone that prevents an older `set` from resurrecting the rule, and
    duplicate versions are idempotent.
24. the planner installs exactly canonical today plus seven dates, app relaunch
    appends only the missing tail date, and unchanged reconciliation has no
    replacement churn;
25. force-quit beyond `readyThroughUsageDate` yields `coverageExhausted`; an
    unknown/uncovered callback has zero metering and earned auto-shield effects
    while manual, task-pause, reflection, admin, block, and per-app state is
    byte-identical;
26. `excessiveActivities` preserves verified routes, records the actual
    ready-through date, and never stops the last active route to make room;
27. activity/event route-ID mismatch, malformed names, pre-`dualActive` routes,
    tombstoned routes, and registration-pending callbacks without current-day
    `offlinePending` authorization each have zero effects; an authorized offline
    callback creates only one registration-blocked queue item;
28. crashes after durable pending start, Apple start, verification,
    `dualActive`, backend activation commit before its response, local v2-only
    activation, retirement, Apple stop, and stop acknowledgement recover the
    same IDs and converge without duplicate activation or a zero-metering gap;
29. crashes before/after shield mutation, identity-owner replacement, and each
    rollover acknowledgement converge by exact CAS without losing unrelated
    sources or admitting stale callbacks;
30. a real production v1 callback travels through the Apple DTO and durable v1
    queue; registration alone leaves v1 functional; the v2 route is started,
    verified, and locally committed `dualActive`; v1 and v2 callbacks on both
    sides of the backend activation commit advance one monotonic ledger without
    double counting; after v2-only commit, the next real callback uses v2 and a
    delayed v1 retry ends `legacy_after_v2` without ledger or shield effects;
31. `P3V01` uses production `ShieldRecord` with `.taskPause` and reaches the
    shared effect store/CAS path; vector outputs assert the persisted records,
    not a test-only projection;
32. an authoritative registration conflict uses only
    `authoritative_snapshot.estimated_minutes`, retires/tombstones the rejected
    route, terminalizes its queued samples, and creates fresh corrected epoch,
    route, registration, install, and activation work; corrected install/verify,
    prior-work drain, and `cutoverReady` precede registration, and no old
    functioning monitor is stopped before corrected activation;
33. app and DAM race for one pending start: exactly one 60-second claim wins and
    one start occurs; after winner crashes, the loser no-ops before expiry and
    adopts an exact daemon installation after expiry without another start;
34. virtual-clock retry deadlines are exactly immediate, +5, +15, +60, +300,
    then +300 seconds, and global due ordering is deterministic;
35. a tombstone cannot purge before referenced work is terminal, stop is
    acknowledged, and the later of canonical day end +48h or stop ack +24h;
36. a DAM earned envelope write followed by an unrelated mutation from an
    already-live app actor preserves all earned, manual, `taskPause`, `.limit`,
    block, and unrelated records under both normal and CAS-conflict paths;
37. a gate close injected during conservative registration returns HTTP 200
    with `epoch_status=paused`, does not activate locally, and a later open uses
    another fresh epoch and route;
38. migration preserves exact active, pending, and retiring legacy monitor
    provenance; unadvertised, offline, and restart paths continue real v1 until
    verified v2 activation;
39. a cross-stack V30 orchestrator compiles the production Swift encoders,
    writes nonempty hashed v1/registration/activation/v2/stale-v1 request bytes,
    sends those exact bytes through real guarded disposable-database routes,
    proves `EarnedTimeMeteringEpoch`, `EarnedTimeSample`,
    `EarnedTimeDeviceDay`, `EarnedTimeDay`, `EarnedTimeLockCommand`, and
    `Command` rows, and verifies the separate
    `BigKidStore.get_state(device.id).minutes_left` bank snapshot rather than
    claiming a nonexistent bank table or comparing hand-built fixtures.

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
route/install/tombstone state
coverage and recovery envelopes
```

### 13.2 Virtual Time and Fault Injection

- Swift uses an injected `MeteringClock` and fake `DeviceActivityCenter`.
- Python tests monkeypatch the production `screen_time_clock.now_utc` seam.
  Public routes/services accept no caller-selected clock instant, canonical
  date, or timezone override, and canonical context can only be issuer-created.
- A DEBUG-only App Group clock override drives extension day changes without
  changing the physical device clock. Release builds contain no override.
- Tests advance seconds, five-minute thresholds, midnight, and multiple days in
  milliseconds.
- Fault cases include offline registration, duplicate delivery, out-of-order
  samples, concurrent samples, stale poll snapshots, delayed retired epochs,
  partial sibling fanout, app-process absence, `excessiveActivities`, horizon
  expiry, and identity/rollover/shield changes at every durable/external
  operation boundary.
- The install claim lease is 60 seconds. Retry deadlines are 0, 5, 15, 60, 300,
  then 300 seconds. Tombstone retention uses canonical day end +48h and stop
  acknowledgement +24h exactly. All three are virtual-clock assertions.

### 13.3 Required Build and Regression Gates

- Focused Swift unit/state-machine suites pass.
- Full iOS test target passes except documented unrelated pre-existing failures.
- All touched backend DB suites run through
  `/Users/fred/Desktop/Evlin/code.nosync/Evlin-Backend/.venv/bin/python scripts/run_limits_db_regression.py`
  against its guarded disposable local database. Pure tests may use
  `.venv/bin/python -m pytest`; a skipped DB test is not evidence.
- All six targets compile with `SWIFT_VERSION = 5.0`, deployment target 17.6,
  and iPhone/iPad family `1,2`. Runtime tests use literal installed simulator
  destinations `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1` and
  `platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1` when no 17.6
  runtime exists; that proves deployment compatibility,
  not the minimum-floor runtime behavior.
- Release products are built before scans. The scan fails if the expected
  product count is zero and proves DEBUG clock symbols/keys are absent and the
  Push NSE has no earned monitor-owner call.
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
   bucket advances through the preinstalled dated route without opening Evlin.
5. **iOS/iPadOS 17.6 minimum-floor smoke:** when no local 17.6 simulator runtime
   is installed, run install/start/callback/stop and horizon-fill behavior on a
   physical 17.6 iPhone or iPad. An iOS 26.3 simulator run cannot substitute for
   this gate.

The overnight evidence also records the number of accepted dated activities.
If Apple reports `excessiveActivities`, retain the verified routes and record
the ready-through date. The eight-date product horizon remains definitive
unless that physical evidence requires a later reviewed reduction.

Codex drives builds, installs, launches, App Group capture, backend queries,
and result comparison. The human tester only unlocks/authorizes devices, opens
the named monitored app, force-kills Evlin when requested, and confirms the
visible shield. Two connected devices are required only for gate 3 and the
overnight soak.

No Phase 3 completion or release claim is allowed until the automated matrix
and all five applicable physical gates pass. Planning and automated reports
must label every unrun physical row `PENDING`; a unit-test-only result is
insufficient.

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
  exact canonical-midnight rebase or NSE-primary production ownership. Phase 3
  uses dated app/DAM routes and conservative pause/resume regardless of the
  short spike; only later reviewed physical evidence may change ownership.

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

- Add shared clock and value-adapted `DeviceActivityCenter` injection for app
  and DAM first. The DEBUG App Group override is compile-time absent from
  Release, and the Push NSE remains unable to own earned monitoring.
- Add the one versioned, owner-fenced Device Epoch Store root with exact
  selection bytes, six-field policy generations, full daily epochs, immutable
  routes/tombstones, exact legacy compatibility monitor state,
  registration/activation/sample queues, install claims and acknowledgements,
  eight-date coverage, ratchet, shield references, identity cleanup, and
  rollover effects. Every persisted work item has an owner, retry deadline,
  terminal condition, R-16 row, and app/DAM/Push-appropriate recovery trigger.
- Install non-repeating canonical dated schedules for today plus seven days.
  Register an initial v1-to-v2 route before install except durable
  `offlinePending`; mark future routes `futurePlanned`; arbitrate app/DAM starts
  with the 60-second durable lease. Enter durable `dualActive` before the initial
  backend ratchet and preserve functional v1 until the v2-only local commit after
  activation acknowledgement. For every v2-to-v2 replacement, start and verify
  the candidate while the prior route remains active, enter exact `dualV2`,
  settle prior work and atomically enter `cutoverReady`, then register/activate
  and only afterward retire/tombstone/stop the prior route.
  Recover every nonterminal phase using the same IDs.
- Extend backend schema, registry, routes, migration, and tests additively for
  `gate_resume_conservative`, response `epoch_status`, and the idempotent route
  activation acknowledgement. Registration validates authoritative base/gate;
  activation performs the per-device ratchet only for an active epoch.
- Route the real Apple callback DTO through independent durable provenance,
  strict physical trust, registration/sample delivery, local effects, and the
  Phase 2 v1-to-v2 ratchet. Rejected, stale, unregistered, uncovered, or
  malformed callbacks have zero effects.
- On conservative resume, retire the paused epoch and create a fresh epoch and
  route from backend `estimated_minutes`; discard the first callback on that new
  route. Do not stop the paused monitor until the replacement is active, and do
  not create an exact-rebase or same-epoch resume branch.
- On authoritative-base 409, terminalize only the rejected candidate epoch,
  route, and queued work. Keep the prior functioning route active while the
  corrected candidate completes the explicit dual-v2 handoff.
- Reload/merge all durable shield and block records before every app-side
  `ActiveLockStore` mutation under `ActiveLockPersistenceLock`; recover earned
  shield effects by exact CAS without dropping unrelated sources.
- Make coverage exhaustion explicit and non-locking for earned metering while
  preserving all unrelated lock sources. Exercise `excessiveActivities`
  without destructive replacement.
- **§11/R-16 completion gate:** the Phase 3 completion report must include a
  "本阶段拆除清单 + 向量证据" table for T1, T2, T3, the Phase 3 portion of T4,
  device-side T11 `+5` heuristic, T7, and T8. Backend T5 remains Phase 2
  evidence and cannot be closed by iOS work. Each row names the
  replacement, the commit that removes or
  narrows the old mechanism, and the golden vector that remains green after
  removal. Any deferred row requires a written owner, reason, and later phase;
  silence is a failed gate.
- Phase 3 may not add an unregistered guard, flag, or veto. Before implementation,
  route/tombstone lifecycle, legacy compatibility, install authorization/phase,
  v2 route handoff, install claim/lease, coverage state,
  registration/activation/ratchet state,
  process-role ownership, pause state, base correction, sample queue, retry
  schedule, shield envelope, identity cleanup, and rollover envelope must each
  be entered under rule-book §11/R-16 with replacement, deletion criterion, and
  vector evidence. No ad hoc Boolean may duplicate these registered states.

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
- **§11/R-16 final gate:** the Phase 6 completion report must reconcile every
  T1-T11 row as removed, intentionally retained with Fred-approved written
  waiver, or assigned to a named follow-up with evidence that Phase 6 does not
  depend on it. It must attach the corresponding golden-vector result and the
  independently revertible removal commit for each removed mechanism.
- Recount the earned metering guards at the end of Phase 6. The target is two
  cores (identity match and physical trust) plus gate state. A higher count, an
  unregistered guard, or a missing replacement/deletion criterion fails the
  phase even when functional tests pass.
- C-3 single-writer closure in
  `docs/superpowers/plans/2026-07-15-lock-single-writer-c3.md` is a Phase 6
  prerequisite: reflection web allowance and Home settings locks must route
  through `ActiveLockStore`, then the two dead direct-write methods are removed.

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
- A full unchanged horizon performs exactly eight real starts initially and
  remains one six-field generation and the same eight dated installations with
  zero additional starts/stops across the next 120 real poll reconciliations,
  including after usage advances.
- Immediate physically impossible callbacks and callbacks without durable route
  provenance cannot mutate usage or lock anything.
- Delayed physically possible callbacks remain accepted.
- Task/reflection pauses do not charge time; task bypass resumes the same day;
  a new day expires the bypass.
- Force-killing the main app does not prevent threshold measurement or
  canonical rollover while the preinstalled eight-date horizon covers the
  current day.
- Expired or installation-limited coverage is explicit, never manufactures
  usage, never applies an earned fail-closed lock, and leaves all non-metering
  sources unchanged.
- Route tombstones, not a comparison only to current state, make cross-date and
  replaced-route callbacks zero-effect.
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
- Queue/backfill recovery is active before the first production v2 switch.
- Legacy v1 remains functional through unadvertised, offline, registration-only,
  and restart states and stops only after a started, verified, activated v2 route
  receives backend activation acknowledgement.
- Every paused-epoch resume and authoritative-base correction creates both a
  fresh immutable epoch and a fresh route; neither route nor epoch is revived.
- App/DAM install races produce one 60-second lease winner and no blind duplicate
  start; retries and tombstone retention match the pinned constants.
- Every app-side lock mutation reloads all cross-process durable sources before
  mutation, so a DAM-earned write survives unrelated live-app mutations and CAS
  conflicts.
- Every R-16 demolition follows a committed replacement/vector and the final
  report contains the exact `本阶段拆除清单 + 向量证据` table.
- Automated gates have recorded evidence and all unrun physical gates are
  explicitly `PENDING`; Phase 3 is not complete or releasable until they pass.

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
6. The short DAM/NSE spike establishes process capability only. The 2026-07-17
   correction removes exact resume rebase and NSE-primary ownership from Phase
   3; dated app/DAM routes plus conservative pause/resume are mandatory.
7. Claude's Round-5 final review found no protocol blocker. The implementation
   plan now terminalizes non-base registration 409s, explicitly rejects
   physically impossible nonzero-base deltas with zero effects, and requires a
   repository-wide zero-residual scan for every Phase 3 R-16 demolition task.
