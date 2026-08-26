# True-Device Acceptance Runbook — 2026-08-26

One install session verifies everything queued since 08-16. Three devices:
iPad = Ruoping's iPad (`767F867E`), XS Max = Fred's iPhone (`BEBBD1B3`),
iPhone 11 = Liam's iPhone (`F5946523`). Build from a CLEAN COMMIT (worktree
of the tested SHA), install via `devicectl` — never Xcode Run (a debugger
changes extension/termination behaviour).

## 0. Before installing

- Pull each device's `dam-memory-trace-v1.bin` (post-change window starts
  here); record last `seq` per device. Commands + record layout:
  `docs/DAM-EXTENSION-BASELINE-2026-08-19.md`.
- Note current prod counts: pending `metering_rearm` (expect 77 or fewer),
  `internal_cleanup` created last 24h (expect ≈ 0 outside real starvation).

## 1. Metering stack (P0-1 / trio / CAS) — passive, 24–48h

Baseline: iPad 34/75 callbacks incomplete (45%), 26 re-delivered; XS Max
10/66; iPhone 11 2/20 (doc above).

- [ ] Trace rings: `entry`-without-`exit` ≈ 0 per device; no re-delivered
      event hashes (no backoff retries); footprint p95 not worse.
- [ ] No `beforeDrain`/`afterDrainWait` stages on earned/interval callbacks
      (only per-app still waits until P0-3).
- [ ] Day rollover at 04:00 UTC mints + activates the new epoch on all three
      (watch `evlin_earned_time_metering_epochs`).
- [ ] 30 days without extension `per-process-limit` (long tail; JetsamEvent).

## 2. Offset recut (155 early-lock) — active, 15 min

On any device: burn ≥25 min, force a same-callback replacement (change pool
config mid-day), verify in blackbox: `offset=N` in `metering_guard` nums,
shifted terminal rung, and NO lock before `base + raw − offset == pool`.

- [ ] No `v2_callback_discarded:too_early` bursts after the replacement.

## 3. Paused-midnight / task-gate — overnight
Seed an UNFINISHED task on one device before local midnight.

- [ ] Next morning: current-day epoch EXISTS (possibly paused), registered —
      no `deferred:registrationRequired` loop, no
      `gate_resume_requires_paused_predecessor` 409s.
- [ ] Complete the task → unshield arrives; bar resumes within minutes
      (no 5-min repair blind spot).

## 4. Force-quit overnight adoption — GATE for removing dd61ac7's fallback
Force-quit the kid app on one device before midnight (leave device on).

- [ ] Extension's intervalDidStart adopts the preinstalled route at midnight
      WITHOUT the app opening: samples flow next morning pre-open.
- [ ] Only then: backend may retire the remaining `day_rollover` visible
      fallback (currently already retired in dd61ac7 — if this gate FAILS,
      restore the fallback first).

## 5. Notification quiet — passive
- [ ] No "monitoring is being restored" on any healthy device, ever.
- [ ] Hourly sweep ledger stays ≈ 0 kicks (only true starvation).

## 6. Task-ordering / APNs repair (a624902 + ff56c7a)
On the two-device child: complete a task then create a new one within 30s.

- [ ] No lock→unlock→lock flapping on either device; superseded commands
      visible in `evlin_commands` with `superseded_by_command_id`.
- [ ] Invalidate one device's push token (reinstall), verify compare-and-
      clear + foreground token replay heals it on next open.

## 7. Chat fixes (c2e9a10 / 66507b1) — active, 5 min
- [ ] A1 confirm ("Block X") actually executes; A3/B1/E1/F1 likewise.
- [ ] Attach 6 photos to a task: no main-thread stalls scrolling the detail
      view; submit works.

## 8. Master Button (once Tasks 6–10 land) — spec §True-device acceptance
The six spec items, run LAST so metering acceptance above isn't perturbed:
durations + force-quit expiry on two devices; accounting continues during
override (usage still burns the pool) and NO fresh routes are minted;
unfinished tasks re-lock at expiry unmarked; reflection interrupts and
restores remaining override; offline-through-apply and offline-through-
expiry devices converge with honest P-side states; two-parent conflict →
highest revision wins everywhere.

## Escape hatches
- Backend rollback: Render dashboard rollback (code only, never the DB).
- iOS rollback: reinstall previous TestFlight build.
- Master Unlock is itself the field escape hatch if a gate wedges a device.
