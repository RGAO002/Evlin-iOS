# Metering Identity Convergence Implementation Plan

**Goal:** Stop rejecting legitimate metering work during registration, activation,
policy replacement, gate resume, and canonical-day rollover while preserving strict
fail-closed behavior for genuinely foreign or malformed identities.

**Scope:** iOS metering state machine plus the backend registration, activation,
sample, and policy-reconciliation contracts. No UI work, no deployment, no Render
push, and no TestFlight upload in this plan.

## Global Invariants

1. Identity validity and accounting authorization are separate decisions.
2. A callback with the exact owner, generation, epoch, route, activity, event,
   usage date, and policy lineage is never discarded merely because registration
   or activation is still pending.
3. Wrong owner/family/profile, malformed names, unknown routes, mismatched physical
   names, or impossible policy/date lineage remain zero-side-effect rejects.
4. A physically too-early callback is not credited, but it proves the one-shot
   physical ladder was consumed. The candidate must be durably replaced with fresh
   physical IDs.
5. Policy replacement is make-before-break: the old authority remains countable
   until the successor is activated.
6. Late prior-route callbacks are accepted only when their immutable `observed_at`
   is at or before the persisted input-closure barrier.
7. Registration, activation, and old-route-stop stages have explicit durable
   progress and deadlines. A pre-commit candidate may be replaced; a committed
   candidate may never be rolled back.
8. Restart repeats the same durable operation or replacement identity. It must not
   mint additional routes, registrations, or orphan DeviceActivity activities.
9. `recovery_id` remains disabled until both wire sides persist it atomically.
10. Every production change starts with a failing regression test. Existing
    unrelated red tests are named baseline debt, not silently broadened assertions.

## Task 1: Freeze The Cross-Stack Identity Contract

**iOS tests**
- Add wire tests proving a legal paused registration/activation is retryable or
  accepted consistently, never terminalized as a protocol mismatch.
- Add tests that all known recoverable backend dispositions map to explicit local
  actions: park, retry, replace, or terminal reject.

**Backend tests**
- Add registration and activation cases for gate closed/open transitions.
- Pin one coherent response contract: protocol v2 identity remains v2 while paused;
  paused is a legal lifecycle state, not a foreign identity.

**Implementation**
- Align backend DTOs and iOS disposition mapping.
- Do not treat HTTP 200 plus `paused` as terminal.
- Do not let activation validation report `protocol_mismatch` before reporting the
  legal paused lifecycle.

## Task 2: Preserve Exact Legal Callbacks During Handoff

**RED tests**
- Preparing handoff: exact prior callback is parked, not discarded.
- Cutover-ready: prior callback observed before `priorRouteInputClosedAt` is parked
  exactly once even when delivered later.
- A callback observed after the closure barrier remains rejected.
- Exact dual-v2 candidate bypasses stale coverage metadata and parks for
  registration; unrelated routes remain rejected.
- Pre-registration resume callbacks persist a monotonic high-water and replay once.
- More than 32 legal callbacks collapse by route/high-water without overflow loss.

**Implementation**
- Introduce one disposition function returning `reject`, `park`, `credit`, or
  `consumedPhysicalIdentity`.
- Persist parked observations by immutable route identity and monotonic high-water,
  rather than a fixed-size global callback list.
- Keep accounting effects disabled until registration/activation authorization.

## Task 3: Make Physical-Identity Recovery Crash Idempotent

**RED tests**
- Crash after `physical_identity_recovery_required` but before request rewrite.
- Duplicate rejected registration rows converge to one replacement.
- Restart reuses the same replacement physical identity.
- Owner mirror switched before acknowledgement recovers the current owner and
  rejects the former owner.

**Implementation**
- Make rejected-registration recovery operate on a deterministic rejected set,
  not `count == 1`.
- Persist one recovery operation ID and replacement tuple before network work.
- Repair the owner acknowledgement from the durable owner provider when the mirror
  already matches.

## Task 4: Replace Consumed Candidates Without Nested Handoffs

**RED tests**
- `testDualV2ConsumedCandidateIsTerminalizedAndReplacedWithoutNestedHandoff`
- `testConsumedCandidateReplacementRestartReusesSamePhysicalIdentity`
- Override/gate-closed cases do not self-lock or credit usage.

**Implementation**
- Extract the transaction used by
  `replaceAuthoritativeBaseMismatchCandidate`.
- While an existing handoff owns the bad candidate: terminalize and tombstone that
  candidate, supersede its install/registration work, mint one fresh physical
  tuple, and rewrite the candidate side of the same handoff.
- Preserve prior authority and never remove the existing no-nested-handoff guard.

## Task 5: Add Handoff Completion Guarantees

**RED tests**
- Registration acknowledgement never arrives: replace pre-commit candidate after
  deadline without retiring prior.
- Activation acknowledgement never arrives: replace candidate without stopping
  prior.
- Committed candidate plus missing old-route stop acknowledgement: keep candidate,
  retry stop, and allow next-day rollover.
- Each crash point resumes the same durable stage.

**Implementation**
- Persist stage start/deadline and replacement reason.
- `preparing` and uncommitted `dualV2` may replace the candidate.
- Once candidate is committed, only old-route cleanup retries are legal.

## Task 6: Make Backend Policy Changes Truly Make-Before-Break

**RED tests**
- Old active route samples remain accepted after desired policy revision changes
  but before successor registration.
- They remain accepted while successor is registered but not activated.
- Old authority closes at the successor activation barrier.
- Lost registration response replays idempotently across policy changes.

**Implementation**
- Separate desired policy revision from currently active metering authority.
- Do not retire or invalidate the old epoch at policy-write time.
- Reconciler prepares the successor first; activation atomically advances authority.

## Task 7: Bound Late Samples And Validate Full Scope

**RED tests**
- A 23:59 observation uploaded after midnight is accepted for its exact prior route.
- A callback observed after the closure barrier is rejected.
- Wrong family/profile with a valid device UUID is rejected with zero writes.
- Arbitrary client-supplied old dates remain rejected.

**Implementation**
- Route by persisted immutable identity plus `observed_at`, not server receipt date.
- Accept prior-day work only inside the exact route's durable grace/barrier rules.
- Validate epoch family and profile scope in addition to device ID.

## Task 8: Unblock Canonical Rollover From A Paused Handoff

**RED tests**
- Gate reopen enters dual-v2, prior remains paused, handoff crosses midnight, and
  current-day authority is still created.
- No rollover was prepared: diagnostic verdict records the exact blocking guard.
- Rollover already committed with missing stop acknowledgement does not roll back.

**Implementation**
- Add a pre-rollover verdict describing active epoch status, handoff stage, active
  install phase, route date, and canonical date.
- Let a timed-out pre-commit handoff replace/abort its candidate before rollover.
- Treat a committed candidate as authority for rollover even while old-route stop
  cleanup continues.

## Task 9: Verification And Release Gate

1. Run the iOS callback, conservative resume, ladder invariant, activation,
   rollover, daemon diagnostics, and production integration suites together.
2. Run backend registration, activation, samples, reconciliation, receipts, and
   lock-order regression suites together on real Postgres.
3. Record exact named baseline failures; metering/identity tests get no waiver.
4. Request independent code review over the complete base-to-head range.
5. Build an internal Release diagnostic build only after automated gates pass.
6. Physical gates on both child devices:
   - same-day fresh arm and counting;
   - gate close/reopen;
   - policy replacement;
   - process kill/reopen;
   - midnight rollover;
   - delayed callback delivery;
   - no legal identity rejection in the exported journal.
7. Do not push, deploy, or upload TestFlight without Fred's explicit approval.
