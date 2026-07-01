# Screen-Time Stability & Observability — Design

- **Date:** 2026-07-01
- **Status:** Approved (brainstorming) → ready for implementation plan
- **Scope:** iOS (`Evlin-iOS`, incl. `EvlinDeviceActivityMonitor` extension) + backend (`Evlin-Backend`)
- **Related:** memory `evlin-timelimit-remediation-plan` (3-agent audit + 2 collab reviews)

## Goal

Make the three **already-built** screen-time features **stable and predictable** — stop the random "抽风" (glitches). This is a **止血 + 可观测** (stop-the-bleeding + observability) round on the **current architecture**. It is explicitly **not** the larger re-architecture.

The three features:
- **Shared time pool** (earned time) — a family/child daily allowance shared across the child's devices.
- **Device limit** — a per-device daily cap.
- **Per-app limit** — a per-app daily budget.

### Success criteria
1. When a parent sets/changes a limit, the child device reliably reflects it (command emitted → acked), or the gap is **visible**.
2. Locks/unlocks behave predictably: a per-app limit toggle acts as a real lock/unlock switch once the budget is reached.
3. The shared pool counts down smoothly (no "stuck at 20 min") and resets reliably at the day boundary even if the device was off.
4. Usage survives app reinstall (no reset-on-recompile).
5. Numbers shown on the kid device match the parent view.
6. When something misbehaves, the exact chain of events is queryable (in-app, in Xcode/Console, and in the backend) so root cause is obvious instead of guesswork.
7. The "current lock/block list" parent/chat shows matches what is actually enforced on the kid device (device-reported snapshot is authoritative), or is clearly marked **stale/pending** — never silently wrong.

### Non-goals (deferred to a later "structural" round)
- Shared pure decision function + cross-language golden vectors.
- Refactoring the DeviceActivity extension into a testable reducer.
- Full hybrid-authority reconciliation loop / durable outbox.
- Backend-owned per-app-limit **enforcement** (enforcement stays on-device this round).

## Background (root causes being addressed)

From the audit + collab reviews (see memory). This round targets the ones that are (a) live and (b) fixable on the current architecture:
- Too many non-atomic sources of truth for "remaining/used"; device shows persisted value while summary recomputes → mismatch.
- Day-boundary/reset not backstopped; `latestDeviceEstimate`/offsets never cleared at midnight.
- Cascade-clamp mutates DB but emits no device command → device keeps old budget.
- `effective_date` "tomorrow" config supersedes today immediately → future change bleeds into today.
- Multi-device shared-pool exhaustion has no fan-out (auto-lock only acts on the reporting device's own cap).
- Device identity stored in `UserDefaults` → wiped on reinstall → fresh install can't re-attach to backend history.
- No unified, queryable log of lock/time behavior → debugging is guesswork.

## Design

### Part A — Observability spine (the foundation; built first)

A single structured event, emitted at every meaningful point on **both** the parent (P) and kid (K) devices **and** the backend, written to three sinks.

**`ScreenTimeEvent` schema** (identical shape in Swift and backend):
```
ts            ISO8601 with tz
emitter       parent_app | kid_app | kid_extension | backend
device_id     stable device UUID (Keychain-backed, see Fix 1); null for backend
day_key       "YYYY-MM-DD@<tz>"   (canonical day identity)
kind          lock | unlock | sample | command_emit | command_ack
              | cascade | reset | decision | drop
source        manual | perAppLimit | devicePool | earnedPool | deviceCap | taskPause
app           bundle id / name, or "device-wide"
reason        short code (budget_reached, pool_exhausted, interval_reset,
              policy_lowered, usage_counting_disabled, catch_up_reset, …)
nums          { used, budget, pool_used, pool_total, cap, remaining, rounded }
transition    { before, after }   e.g. shielded:false→true
policy_gen    policy/version marker (best-effort this round)
corr_id       id correlating one logical action across P/K/backend
```

**Emission points**
- **Kid extension** (`EvlinDeviceActivityMonitor/DeviceActivityMonitorExtension.swift`): threshold reached; shield write/clear; `intervalDidStart` reset; event dropped when `usageCountingAllowed == false`. **Highest value — the lock bugs live here.**
- **Kid app**: sample post; command received; shield apply/clear.
- **Parent app**: limit/pool/cap change; lock/unlock; toggle flip.
- **Backend**: each ingest; remaining computation; command emit; cascade; exhaustion mark.

**Three sinks** (same schema):
1. **os_log** (unified logging, subsystem `com.evlin.screentime`) — live in Xcode/Console.app; the only reliable way to capture the **extension** process.
2. **App Group ring buffer** → surfaced in an in-app debug screen (extend the existing `CommandDeliveryDiagnosticsView` pattern) — readable on-device without a computer.
3. **Backend `screen_time_events`** — the kid and parent apps POST events (debug/dev builds, batched, behind a debug flag). This is the **cross-device unified timeline** that the developer (and Claude) query via SQL/grep. Doubles as raw material for future analytics.

The App-Group→backend upload is a lightweight batch (not the full durable outbox); good enough for a dev/debug observability tool.

**Build order (so observability doesn't balloon and block 止血):**
- **A0** — the `ScreenTimeEvent` type + **os_log** + **App-Group ring buffer** (+ debug screen). This is enough to diagnose the extension and on-device behavior; it is the prerequisite for the Tier-2 fixes.
- **A1** — the backend `screen_time_events` upload + cross-device unified timeline. Lands *after* the Tier-1 fixes so the safe stability work isn't gated on the upload path.

### Part B — Source-of-truth clarification (small, high-leverage)

Codify the relationship (no big rebuild):
- **Backend Postgres ledger is the durable authority** for historical/aggregate usage (already stored in `evlin_earned_time_*` / `evlin_app_limit_usage_samples`). Survives reinstall; feeds analytics.
- **Device keeps a live working copy** for immediate + offline enforcement (unavoidable — Apple only exposes usage to the on-device extension).
- The device treats the backend's computed "remaining" as authoritative for **display** and reconciles its local counters toward it.
- **Guard rail (must be explicit in the plan):** within the same `day_key`, the device's local usage estimate must **never regress** (be pushed back up / unlock) because of a stale backend `remaining`. Local usage may only be reset on **day reset**, **catch-up reset** (Fix 7), or an **explicit override**. "Display alignment" must not be implemented as "roll back local counters / re-unlock."

### Part B.1 — Restriction-state authority (the "current lock/block list" must reflect reality)

The authoritative "what is currently locked/blocked on the kid device" is the kid device's **`ActiveLockStore` snapshot** — the persisted App-Group dicts `evlin.shieldRecords` + `evlin.blockRecords` (suite `group.com.evlin.ios`) that the DeviceActivity extension actually writes and enforces. Parent/chat "current restrictions" MUST prefer the **latest device-reported snapshot**; command-history replay and `global_effective_state` booleans are only a **pending/optimistic fallback** and MUST be labeled `stale`/`pending`, never presented as authoritative.

- The snapshot carries, per shield: `recordKey`, `tier`, `targetKey`, `displayName`, `sources` (incl. `.earnedTime`), `expiresAt`; per block: `bundleID`, `displayName`; plus `device_id` and `updated_at`.
- Earned-pool locks already live in the same `shieldRecords` system (record `savedList:<lockedSetID>`, source `.earnedTime`) — so the fix is about **reporting/preferring** this snapshot, not building a new lock type.
- **Diagnostic reality:** even on-device, `ActiveLockStore.shared` is an *in-memory* copy loaded at init; when the extension (a separate process) writes a lock while the app is suspended, that in-memory copy can lag the persisted App-Group dict. The App-Group persisted dict is the enforcement truth. Refreshing the in-memory copy from the App-Group dict on foreground is a Tier-2/A1 fix; A0.5 just makes the divergence **visible**.

Scoping across this round:
- **A0.5 (this round, local):** the debug screen shows the *real* current restrictions read directly from the App-Group `evlin.shieldRecords`/`evlin.blockRecords` dicts (enforcement truth), alongside `ActiveLockStore.allCurrent()` so any divergence is visible.
- **A1 (backend pipeline):** the kid device reports a **full** current-restrictions snapshot (shields + blocks with the fields above) on heartbeat / command ack — not just an `isBlocked` bool; the backend stores the full structure in `Device.last_effective_state`.
- **Tier 2 / chat:** parent/chat "current lock/block list" prefers the latest device snapshot, shows `stale` when old, and renders an earned-pool lock explicitly (`Locked set` · source `earnedTime` · reason `pool_exhausted` · device · `updated_at`).

### Part C — Fixes

**Tier 1 — safe, direct (do first, near-zero risk):**
1. **Reinstall keeps usage** — move the device UUID from `UserDefaults` (`OnboardingCoordinator.persistentDeviceID`, key `evlin.parentDeviceID`, and the kid-side equivalent) to the **Keychain** (survives app deletion/reinstall). Migrate existing UserDefaults value on first run.
2. **remaining mismatch** — `ingest_sample` returns the freshly **computed** `remaining` (max(0, pool − used)), not the persisted `remaining_minutes` column; align device-facing snapshot with the summary path.
3. **effective_date bleed** — a "tomorrow" config must not supersede today's immediately (supersede at the new row's effective date, not `now()`). Crucially, **every active-policy/cap read must carry an `as_of_day_key` from its calling context** — there are several read sites that today only filter `superseded_at IS NULL` (`_load_active_config`, `_load_active_cap`, `get_policy`, `get_summary`, and the ingest path). Each must additionally filter `effective_date <= as_of_day_key`, where: sample **ingest** uses `body.usage_date`; **summary** uses the query date; **policy** uses the child-timezone "today". Missing even one read site re-introduces the bleed, so the plan must enumerate all of them.

**Tier 2 — diagnose-then-fix (use the Part-A log to confirm each before/after):**
4. **Pool stuck at ~20 min** — suspected: 10-min bucket rounding (`EarnedSampleReporter`, `bucketMinutes=10`) + `latestDeviceEstimate` never reset at day boundary. Confirm via events, then fix rounding/cap interaction and the estimate reset.
5. **Per-app limit toggle semantics** — once budget is reached, the per-app toggle behaves as a plain lock/unlock switch (on = shielded, off = unshielded) with the highest-precedence source driving the reason. (Define exact behavior in the plan.)
6. **Multi-device pool exhaustion fan-out (minimal)** — when the backend marks the child's pool `exhausted`, emit the earned-time lock command to **all** of the child's devices, not only the reporting one. Minimal targeted version, not the full architectural fan-out.
7. **Catch-up reset** — on app foreground / first event of a new day, compare stored `day_key` vs today; if the midnight `intervalDidStart` reset was missed (device off), perform a catch-up reset (clear stale shields + reset estimate/offset).
8. **Config change emits device command — both directions.** Any pool/cap/app-limit change must push a `set_limit`/re-arm (and earned-config) command so device enforcement matches the DB; log emit + ack.
   - **Lowering** → re-arm / lock at the new (lower) threshold.
   - **Raising** (or clearing) → if current usage is **below** the new threshold, **clear/re-arm** so the child regains access instead of staying stuck-locked at the old limit. (Users test raising a budget to "give back time" — it must actually unlock.)

### Precedence (write it down, used by Fix 5)
`manual > account/admin-disabled > earned-pool-exhausted > device-cap-exhausted > per-app-exhausted > task-pause`. Shields union; the **reason** shown is the highest-precedence hit. Override suppresses only the named automated sources for that `day_key`, never manual.

## User-visible outcome

- **Parent:** limits reliably reach the kid device (or the gap is visible in the log); the per-app toggle is a real lock/unlock switch; "tomorrow" changes apply tomorrow; changing a limit actually takes effect on the device — lowering locks/re-arms, raising/clearing gives time back when usage is below the new threshold; usage history is accurate and survives reinstall.
- **Kid:** pool counts down smoothly and locks at 0; exhausting a shared pool on either device locks both; midnight reset is reliable even after the phone was off; on-device numbers match the parent view.
- **Developer:** when something misbehaves, open the debug screen / query the backend event timeline and see the exact chain (report → exhausted → command → ack → shield); missing links are obvious. Reinstall freely without losing usage.

## Testing

- **Devices:** parent + **two** kid devices. Fix 6 (multi-device pool fan-out) can only be verified when a shared pool is exhausted across *two* kid devices that each stay under their own cap; a single kid device cannot exercise it. The second kid device may be a simulator or an already-registered device if a second physical device isn't available.
- Each Tier-2 fix is validated by reading the Part-A event timeline before/after (the observability spine is the acceptance tool).
- **Automated tests:** no *new* harness (the reducer / golden-vector work is deferred), but the backend fixes get **targeted regression tests in the existing frameworks** — `effective_date` bleed (assert today's pool stays put after a "tomorrow" decrease), `remaining` alignment (ingest-returned == summary-computed), and command emission on lower/raise. iOS reuses existing suites (e.g. `EarnedSampleReporterTests`) for the pool-rounding/reset fix. "No new harness" ≠ "no tests."

## Rough sequencing

1. **A0** — `ScreenTimeEvent` type + os_log + App-Group ring buffer + debug screen (enough to diagnose the extension; prerequisite for Tier 2).
2. **Tier 1** fixes (1–3) — safe, immediate; not gated on the backend upload path.
3. **A1** — backend `screen_time_events` upload + cross-device unified timeline.
4. **Tier 2** fixes (4–8) — each diagnosed and verified via the event timeline.

## Out of scope (next round)

Shared decision function + golden vectors; DeviceActivity reducer harness; full hybrid-authority reconciliation loop / durable outbox; backend-owned per-app enforcement. Tracked in memory `evlin-timelimit-remediation-plan`.
