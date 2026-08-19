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

## Reproducibility

Raw files (kept outside the repo, session scratchpad `trace/baseline/`), SHA-256:
    77dc7a60f800c77768377149b4e9cf288b95e0063d8ee01e833013c7730a48b2 ip11.bin
    1a15d041563d5c4cd7925142e24a3c156d8c31869d37bca6d3b274cf4182ab07 xsmax.bin
    584bc762bfc77aa0ad80defded17f8530eed191cb12ec9a79ee9262a25ae0273 ipad.bin
    3d6db35c3b1e306e4472da0936025c4d93cdf545c2f998f5c7afe2da0e6be733 jetsam/ipad-JetsamEvent-2026-08-17-142507.ips
    7f977cc24ffa92d942525069c564f7884eb0fb3115b8d38c901ce32012759445 jetsam/ipad-JetsamEvent-2026-08-17-163734.ips
    49f0959ff8599529ceb1f001023f62bf64699ef351ef66abf1951e704b284009 jetsam/ipad-JetsamEvent-2026-08-18-060915.ips
    5fa2f8101fc3a06a5c27bb0007129a87805d4e1fddb47a3b0b99c66b0f2d32e4 jetsam/xsmax-JetsamEvent-2026-08-16-130927.ips
    0d4376f141c52d87085bf84beac59852bad2d913482a26cd533a04c413660673 jetsam/xsmax-JetsamEvent-2026-08-17-133355.ips
    0e933f059f874f451805729a3d240272dcd69ea1d9d62bd3488ca0cf65f57833 jetsam/xsmax-JetsamEvent-2026-08-18-090113.ips

Extraction (read-only pulls; device UDIDs are the CoreDevice identifiers from `xcrun devicectl list devices`):

    # trace ring (per device)
    xcrun devicectl device copy from --device <UDID> \
      --domain-type appGroupDataContainer --domain-identifier group.com.evlin.ios \
      --source dam-memory-trace-v1.bin --destination <name>.bin
    # crash / jetsam listing and files
    xcrun devicectl device info files --device <UDID> --domain-type systemCrashLogs
    xcrun devicectl device copy from --device <UDID> --domain-type systemCrashLogs \
      --source <JetsamEvent-....ips> --destination <name>-<file>

Decoding: `DAMMemoryTrace` record layout (64B; header 64B; FNV-1a checksum at +60; kind/stage/flags at +5/+6/+7; seq/callbackID at +8/+16; monotonic/wall/avail/footprint/peak/stateBytes/pid/activityHash/eventHash as 9×UInt32 from +24). Group records by callbackID; a callback is "incomplete" when it has no `exit` stage. Post-change windows must be collected separately (ring wraps at ~64 full callbacks) and compared per device.

Devices: iPad = Ruoping's iPad (767F867E-8CA2-59C4-B487-41D55B671095), XS Max = Fred's iPhone (BEBBD1B3-F848-5102-B6B8-26EEACB3BA1B), iPhone 11 = Liam's iPhone (F5946523-B50E-55D4-9305-4690E89929E0).
