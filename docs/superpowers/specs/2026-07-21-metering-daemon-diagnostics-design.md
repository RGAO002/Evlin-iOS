# Metering Daemon Diagnostics Design

**Status:** Approved investigation scope. This design changes DEBUG observation
only. It does not fix, enable, reset, or publish metering behavior.

## 1. Purpose

Produce physical evidence for the remaining DeviceActivity unknowns before any
production behavior is changed:

1. Does a per-app v2 arm call `startMonitoring` once or repeatedly?
2. What schedule and events did the DeviceActivity daemon actually retain?
3. Does the same fresh token fire under legacy-window topology and v2 per-rule
   topology when every other input is equal?
4. Can one whole-device owner complete the v1 -> dual-active -> v2 activation
   chain against the local backend?

The tool is successful when it can distinguish an Evlin state/receipt claim
from daemon-observed state and preserve enough evidence to reproduce every
start, stop, mismatch, and callback in one physical run.

## 2. Alternatives Considered

### A. Add logs directly throughout production planners

This is easy to start but spreads temporary code across high-risk production
paths and still cannot prove what the daemon retained. Rejected.

### B. Read daemon state on every 10-second poll

This detects drift quickly but repeats synchronous DeviceActivity XPC calls and
can recreate the scene-update watchdog crash. Rejected.

### C. DEBUG scheduler recorder plus rate-limited exact readback (selected)

A DEBUG-only decorator records all DeviceActivity start/stop calls without
changing them. A separate off-main inspector reads schedule/events after an arm,
after an explicit configuration change, on manual refresh, and no more than once
per five-minute audit interval. This isolates call churn from daemon persistence
and does not alter Release behavior.

## 3. Hard Constraints

- Every diagnostic production symbol and composition hook is enclosed in
  `#if DEBUG`; Release binaries contain no recorder, inspector, fixture, or UI.
- No global production-readable feature flag is added.
- No use of the no-argument `stopMonitoring()` is added.
- No changes to `includesPastActivity`, policy math, arm identity, gates,
  reset behavior, shields, acknowledgements, or protocol selection.
- All DeviceActivity daemon reads run off the main actor.
- Automatic full readback is rate-limited to five minutes. Arm/config-change
  readback is event-driven and coalesced single-flight.
- Diagnostics store token counts and stable SHA-256 digests only. Raw opaque
  FamilyControls tokens are never rendered or logged.
- The recorder is a bounded App Group journal so extension/app restarts do not
  erase the experiment and storage cannot grow without bound.
- Existing Claude C1 worktree edits and beta/onboarding WIP are not modified or
  staged with this work.

## 4. Components

### 4.1 `MeteringDaemonDiagnosticJournal`

A DEBUG-only bounded JSON journal in `group.com.evlin.ios`. Each entry includes:

- monotonic sequence and wall-clock timestamp;
- process (`app`, `monitor-extension`, `nse`);
- operation (`start`, `stop-names`, `stop-all`, `readback`, `callback`);
- activity name and namespace classification;
- expected arm/rule/generation identifiers when available;
- expected and actual schedule summary;
- expected and actual event-name sets;
- per-event threshold, `includesPastActivity`, and application/category/web
  token counts and digests;
- result (`success`, `throw`, `match`, `mismatch`, `missing`), error, and mismatch
  reasons.

The journal keeps the newest 400 entries and exposes clear/export operations.

### 4.2 `DiagnosticDeviceActivityScheduler`

A DEBUG-only decorator over `DeviceActivityScheduling`. It records every
`startMonitoring`, named stop, global stop, and monitored-activity query, then
delegates exactly once to the wrapped scheduler. It never retries, suppresses,
or changes an error.

The default DEBUG `ActionExecutor` composition uses the decorator. Release uses
the existing `DeviceActivityCenterScheduler` directly. Tests inject spies as
before and therefore do not acquire hidden global state.

### 4.3 `MeteringDaemonInspector`

A DEBUG-only, non-main-actor service reads `activities`, `schedule(for:)`, and
`events(for:)` from DeviceActivityCenter. It compares complete configurations,
not only names. Event comparison includes thresholds, `includesPastActivity`,
and token-set digests.

Triggers:

- once after a successful start call;
- once after an explicit configuration/identity change;
- manual refresh;
- a coalesced audit no more often than every five minutes.

Concurrent requests collapse into one inspector pass. A failed pass records the
error and remains eligible for the next event-driven or timed pass.

### 4.4 Diagnostic screen

The existing DEBUG diagnostics navigation gains one unframed `Metering daemon`
screen. It shows identity readiness, local protocol ratchet, current App Group
owner, activity namespaces, start/stop counts, the latest exact readback, and a
chronological bounded journal. Controls are Refresh, Export, and Clear only.
They cannot arm, stop, reset, lock, unlock, change protocol, or mutate policy.

### 4.5 Controlled A/B probe

The existing one-minute per-app probe is extended only after the passive
recorder is green. It accepts one freshly selected application token and creates
two mutually exclusive runs:

- **Legacy:** stable per-window activity, one-minute event.
- **V2:** per-rule activity with a stable arm ID, one-minute event.

Both runs use the same token, timezone, schedule, threshold, and
`includesPastActivity`. Starting one explicitly stops only the other probe's
named activity. Each run records expected configuration, daemon readback,
callback, and elapsed time. The UI refuses to start if another probe run is
active or identity is not ready.

## 5. Local v2 Whole-Device Experiment

This is configuration and observation, not a production default change:

1. Start the local backend with `METERING_EPOCH_ADVERTISED_VERSION=2`.
2. Re-pair exactly one K device and verify `appMode=child`, current child-device
   UUID, canonical timezone, authorization, and non-empty measurement selection.
3. Observe registration, verification, dual-active activation acknowledgement,
   route installation, and `ratchet.localSelection == .v2` in order.
4. Abort on owner mismatch, missing route, daemon mismatch, or any global stop.
5. Leave Render unchanged and do not use the second K device until the first
   experiment is complete.

## 6. Experiment Matrix

Each run begins with a clean diagnostic journal and a fresh app with zero usage
that canonical day. No database-only same-day reset is used between runs.

| Run | Protocol/topology | Expected evidence |
|---|---|---|
| A | per-app legacy window | one start, exact daemon match, one callback |
| B | per-app v2 per-rule | one start, stable arm ID across polls, exact daemon match, one callback |
| C | whole-device v1 | establishes legacy control only; no Phase 3 claim |
| D | whole-device locally activated v2 | v2 ratchet, dated route exact match, threshold callback |
| E | v2 gate close/open | one successor replacement, no paused threshold charged |
| F | manual lock/unlock | zero meter start/stop calls and unchanged arm identities |
| G | controlled DEBUG reset generation | new generation and from-now base; ordinary smaller snapshot remains rejected |

Failure is informative. For example, a successful start followed by a missing
daemon activity localizes the defect to daemon persistence; an exact daemon
match with no callback localizes it to schedule/event/token semantics; repeated
start entries localize it to Evlin reconciliation.

## 7. Automated Tests

- recorder delegates each operation exactly once and preserves thrown errors;
- journal is bounded, ordered, identity-labelled, and contains no raw tokens;
- exact comparator detects schedule, event-name, threshold,
  `includesPastActivity`, and token-digest differences independently;
- identical configurations compare equal regardless of Set encoding order;
- inspector is off-main, single-flight, event-driven, and five-minute limited;
- global stop is recorded as a high-severity diagnostic event;
- Release build contains none of the diagnostic types or strings;
- passive diagnostics do not change planner results, receipts, ratchets, or
  DeviceActivity calls.

## 8. Exit Criteria

No production fix is proposed until the journal provides a complete answer for
both per-app runs and the local v2 activation chain. Findings are promoted to
PROVEN only when static flow, daemon readback, and callback/backend evidence
agree. If evidence conflicts, the experiment is repeated with one variable
changed; no additional fix is layered on top.
