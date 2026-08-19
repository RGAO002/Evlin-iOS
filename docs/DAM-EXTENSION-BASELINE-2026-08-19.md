# DAM extension baseline (BEFORE P0-1/P0-1b), captured 2026-08-19 01:12 UTC

Source: dam-memory-trace-v1.bin pulled from 3 devices + systemCrashLogs listing/JetsamEvent files.
Ring capacity 512 records; iPad ring wrapped (last_seq 741 → window starts 08-17 21:31).

| device | window (UTC) | callbacks | no-exit | % | re-delivered events | PIDs | fresh entry MB | fp p50/p95/max | peak max | min avail |
|---|---|---|---|---|---|---|---|---|---|---|
| iPhone 11 | 08-16 18:14 → 08-19 00:17 | 20 | 2 (intervalStart×2) | 10% | 0 | 5 | 2.47 | 3.96/5.45/5.56 | 5.99 | 0.44 |
| XS Max | 08-16 18:11 → 08-18 22:25 | 66 | 10 (intervalStart×5, thrPool×5) | 15% | 5 | 25 | 2.16 | 3.58/5.13/5.36 | 5.84 | 0.64 |
| iPad | 08-17 21:31 → 08-19 00:41 | 75 | 34 (thrPool×32, interval×2) | 45% | 26 | 37 | 2.40 | 4.72/4.95/5.97 | 5.97 | 0.03 |

Real jetsam (per-process-limit) kills of EvlinDeviceActivityMonitor from JetsamEvent files:
- iPad: 08-17 14:25 EDT pid 5383; 08-18 06:09 EDT report lists pid 5728 AND pid 5731 (rpages 384 = 6MB). pid 5728 appears in trace dying at beforeDrain 07:11:05 UTC with fp 4.17MB → drain spike pushed it to the cap.
- XS Max: none of the extension in 08-16/17/18 reports (only listed, reason None).
- iPhone 11: none.
Earlier (pre-trace): 08-12 ×1, 08-13 ×2 (from Analytics .synced).

Death modes overlapping at beforeDrain: (a) daemon replaces a blocked extension when another callback is pending → immediate re-delivery in new PID (sub-second) and later retries with backoff; (b) genuine per-process-limit during the drain's memory spike (backlog-sized upload payload). Both are addressed by: no waiting in the callback + budgeted opportunistic drain (P0-1), and later by moving the event ring out of UserDefaults (P0-2).

Acceptance after each cut (separate trace windows, same devices): no-exit ≈ 0; no consecutive re-deliveries; fp p95 down; 30 days without per-process-limit; local minutes / terminal shield / per-app shield not delayed; sample delivery P95 (backend_received_at − callback_observed_at) not worse, with fixed-deadline delivery rate, undelivered-at-deadline count, duplicate-request count (backend duplicate credits must be 0).
